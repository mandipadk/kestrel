//! Kestrel private mode: only devices listed in the device file may use this
//! exit. There is no broker, no account and no free tier.

pub mod shield;
pub mod stealth;

use std::{
    collections::BTreeMap,
    io,
    net::IpAddr,
    path::Path,
    pin::Pin,
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::Duration,
};

use anyhow::Context as _;
use dashmap::DashMap;
use ed25519_dalek::VerifyingKey;
use geph5_misc_rpc::{
    exit::{ClientCryptHello, ClientHello},
    kestrel::{DeviceCredential, now_secs},
};
use moka::sync::Cache;
use serde::{Deserialize, Serialize};
use sillad::Pipe;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::{
    CONFIG_FILE,
    bw_accounting::BwAccount,
    ratelimit::RateLimiter,
    session::{RATE_LIMITER_CACHE, SessionKey},
};

/// Failed handshakes allowed per source IP before it is shut out.
const MAX_FAILURES: u32 = 5;

/// The on-disk device list, managed by `kestrelctl`.
#[derive(Serialize, Deserialize, Default)]
pub struct DeviceFile {
    #[serde(default)]
    pub devices: Vec<DeviceEntry>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct DeviceEntry {
    pub name: String,
    pub pubkey: String,
    #[serde(default)]
    pub added: String,
    #[serde(default)]
    pub revoked: bool,
    /// Shield on or off for this device; on when not set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shield: Option<bool>,
}

pub fn load_devices(path: &Path) -> anyhow::Result<DeviceFile> {
    let raw = std::fs::read(path).with_context(|| format!("cannot read {}", path.display()))?;
    Ok(serde_json::from_slice(&raw)?)
}

/// An authorized device for one connection.
pub struct Device {
    pub name: String,
}

/// The status-file key every session of a device carries, so the proxy can
/// apply Shield to it.
pub const METADATA_KEY: &str = "kestrel_device";

/// Tags a session's metadata with its device. Set by the exit, never trusted
/// from the client: any value the client sent under the key is replaced.
pub fn tag_metadata(
    metadata: Option<serde_json::Value>,
    device: &Device,
    link: Link,
) -> serde_json::Value {
    let mut map = match metadata {
        Some(serde_json::Value::Object(map)) => map,
        _ => serde_json::Map::new(),
    };
    map.insert(METADATA_KEY.into(), device.name.clone().into());
    map.insert(
        LINK_KEY.into(),
        serde_json::json!({ "stealth": link.stealth, "quantum_safe": link.quantum_safe }),
    );
    serde_json::Value::Object(map)
}

pub fn device_of(metadata: &serde_json::Value) -> Option<&str> {
    metadata.get(METADATA_KEY).and_then(|v| v.as_str())
}

/// The key under which the exit records how a session came in.
const LINK_KEY: &str = "kestrel_link";

/// How one session reached the exit. A device can hold several sessions at
/// once (an old app and a new one, or a test's probes), so its report speaks
/// for the session asking rather than for whichever connected last.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Link {
    pub stealth: bool,
    pub quantum_safe: bool,
}

/// The asking session's own link, or, for a session from before links were
/// recorded, the device's latest.
fn reported_link(session: Option<Link>, usage: Option<&Usage>) -> Link {
    session.unwrap_or_else(|| Link {
        stealth: usage.is_some_and(|u| u.stealth.load(Ordering::Relaxed)),
        quantum_safe: usage.is_some_and(|u| u.quantum_safe.load(Ordering::Relaxed)),
    })
}

pub fn link_of(metadata: &serde_json::Value) -> Option<Link> {
    let link = metadata.get(LINK_KEY)?;
    Some(Link {
        stealth: link.get("stealth")?.as_bool()?,
        quantum_safe: link.get("quantum_safe")?.as_bool()?,
    })
}

/// Names a device can open through its own tunnel to talk to the exit
/// itself. They never resolve or leave the exit, and only an authorized
/// device's session can reach them.
const INTERNAL_DOMAIN: &str = ".kestrel.internal";
const PAUSE_SECS: u64 = 3600;

/// The only port the internal names answer on. The engine's `kestrel_exit`
/// asks on it; browsers refuse port 1, so a web page the device loads
/// through the system proxy can't pause Shield or allow domains.
const INTERNAL_PORT: &str = "1";

/// Answers a request to one of the exit's internal names, or None if the
/// destination is an ordinary one.
pub fn internal_request(device: &str, link: Option<Link>, dest: &str) -> Option<Vec<u8>> {
    let (host, port) = dest.rsplit_once(':').unwrap_or((dest, ""));
    let what = host
        .to_ascii_lowercase()
        .strip_suffix(INTERNAL_DOMAIN)?
        .to_string();
    if port != INTERNAL_PORT {
        return Some(br#"{"error":"unknown request"}"#.to_vec());
    }
    if !apply_request(device, &what) {
        return Some(br#"{"error":"unknown request"}"#.to_vec());
    }
    Some(device_report(device, link))
}

/// Carries out a device's request to its exit. False if it isn't one.
fn apply_request(device: &str, what: &str) -> bool {
    match what {
        "status" => {}
        "shield-pause" => shield::pause(device, PAUSE_SECS),
        "shield-resume" => shield::resume(device),
        _ => {
            // shield-allow.<domain>, shield-allow-all.<domain>, shield-unallow.<domain>
            let parsed = what
                .split_once('.')
                .and_then(|(verb, domain)| Some((verb, shield::valid_domain(domain)?)));
            match parsed {
                Some(("shield-allow", d)) => shield::allow(device, &d, false),
                Some(("shield-allow-all", d)) => shield::allow(device, &d, true),
                Some(("shield-unallow", d)) => shield::unallow(device, &d),
                _ => return false,
            }
        }
    }
    true
}

/// The owner's exits, as the device should know them (empty if not set).
fn known_exits() -> serde_json::Value {
    CONFIG_FILE
        .wait()
        .kestrel_exits
        .as_ref()
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice::<Vec<geph5_misc_rpc::kestrel::KestrelExit>>(&b).ok())
        .map(|exits| serde_json::json!(exits))
        .unwrap_or_else(|| serde_json::json!([]))
}

/// What a device may learn about itself; `link` is the asking session's own.
fn device_report(device: &str, link: Option<Link>) -> Vec<u8> {
    let usage = USAGE.get(device).map(|u| u.clone());
    let (asn, country) = usage
        .as_ref()
        .and_then(|u| u.network.lock().unwrap().clone())
        .unwrap_or_default();
    let link = reported_link(link, usage.as_deref());
    let cfg = CONFIG_FILE.wait();
    serde_json::to_vec(&serde_json::json!({
        "device": device,
        "stealth": link.stealth,
        "quantum_safe": link.quantum_safe,
        "asn": asn,
        "country": country,
        "exit": { "country": cfg.country.alpha2(), "city": cfg.city },
        "exits": known_exits(),
        "shield": shield::summary(device),
        "now": now_secs(),
    }))
    .unwrap_or_default()
}

static FAILURES: LazyLock<Cache<IpAddr, u32>> = LazyLock::new(|| {
    Cache::builder()
        .time_to_live(Duration::from_secs(900))
        .max_capacity(100_000)
        .build()
});

/// Addresses an enrolled device signed in from in the last day. They are never
/// blocked: a device behind them may leave half-made connections (racing both
/// exits, changing networks) and must not lock itself out of its backup exit.
static TRUSTED: LazyLock<Cache<IpAddr, ()>> = LazyLock::new(|| {
    Cache::builder()
        .time_to_live(Duration::from_secs(86400))
        .max_capacity(10_000)
        .build()
});

pub fn is_banned(ip: IpAddr) -> bool {
    !ip.is_loopback()
        && !TRUSTED.contains_key(&ip)
        && FAILURES.get(&ip).unwrap_or(0) >= MAX_FAILURES
}

/// Whether a peer closed the connection (rather than sending junk or staying silent).
pub fn hung_up(err: &std::io::Error) -> bool {
    matches!(
        err.kind(),
        std::io::ErrorKind::UnexpectedEof
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::BrokenPipe
    )
}

/// After a handshake was refused for its key. A key the owner revoked (an old
/// device still running somewhere, or a lost one) is reported, but doesn't
/// count against its address: that address is usually the owner's own
/// network, and blocking it would lock their current devices out too. It is
/// still refused every time.
pub fn refused_handshake(revoked_device: Option<String>, ip: Option<IpAddr>) {
    match revoked_device {
        Some(name) => {
            count_rejection();
            alert_revoked_key(name, ip);
        }
        None => {
            if let Some(ip) = ip {
                record_failure(ip);
            }
        }
    }
}

pub fn record_failure(ip: IpAddr) {
    if ip.is_loopback() {
        return;
    }
    count_rejection();
    if TRUSTED.contains_key(&ip) {
        return;
    }
    let n = FAILURES.get(&ip).unwrap_or(0) + 1;
    FAILURES.insert(ip, n);
    if n == MAX_FAILURES {
        tracing::warn!(
            ip = display(ip),
            "too many failed handshakes; blocking for 15 minutes"
        );
    }
}

/// Checks the device credential in a client hello. Fails closed.
pub fn authorize(hello: &ClientHello) -> anyhow::Result<Device> {
    match hello.crypt_hello {
        ClientCryptHello::X25519MlKem768(..) => {}
        ClientCryptHello::X25519(_) if !CONFIG_FILE.wait().kestrel_require_pq => {}
        ClientCryptHello::X25519(_) => {
            anyhow::bail!("this exit requires the quantum-safe handshake")
        }
        _ => anyhow::bail!("private mode requires end-to-end encryption"),
    }
    let cred: DeviceCredential =
        stdcode::deserialize(&hello.credentials).context("missing or malformed credential")?;
    let path = CONFIG_FILE
        .wait()
        .kestrel_devices
        .as_ref()
        .context("no device file configured")?;
    let devices = load_devices(path)?;
    let entry = devices
        .devices
        .iter()
        .find(|d| d.name == cred.device && !d.revoked)
        .context("unknown or revoked device")?;
    let pubkey = VerifyingKey::from_bytes(
        &hex::decode(&entry.pubkey)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("bad pubkey length"))?,
    )?;
    cred.verify(&pubkey, &hello.crypt_hello, now_secs())?;
    shield::set_enabled(&entry.name, entry.shield.unwrap_or(true));
    Ok(Device {
        name: entry.name.clone(),
    })
}

/// After a refused handshake: if it was signed by a key the owner revoked
/// (a lost device, or one whose key was replaced), say whose. Anything else
/// is a stranger or a scanner.
pub fn revoked_key_user(hello: &ClientHello) -> Option<String> {
    let cred: DeviceCredential = stdcode::deserialize(&hello.credentials).ok()?;
    let path = CONFIG_FILE.wait().kestrel_devices.as_ref()?;
    let devices = load_devices(path).ok()?;
    devices
        .devices
        .iter()
        .filter(|d| d.revoked && d.name == cred.device)
        .find(|d| {
            let Some(bytes) = hex::decode(&d.pubkey)
                .ok()
                .and_then(|b| <[u8; 32]>::try_from(b).ok())
            else {
                return false;
            };
            VerifyingKey::from_bytes(&bytes)
                .is_ok_and(|pk| cred.verify(&pk, &hello.crypt_hello, now_secs()).is_ok())
        })
        .map(|d| d.name.clone())
}

// ---------------------------------------------------------------- sentinel

/// Something the owner should know about.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Alert {
    pub at: u64,
    pub kind: String,
    pub device: String,
    #[serde(default)]
    pub asn: u32,
    #[serde(default)]
    pub country: String,
}

const ALERTS_KEPT: usize = 20;

static ALERTS: LazyLock<Mutex<Vec<Alert>>> = LazyLock::new(Default::default);
static ALERTED: LazyLock<Cache<String, ()>> = LazyLock::new(|| {
    Cache::builder()
        .time_to_live(Duration::from_secs(3600))
        .build()
});

/// Notes that a revoked key tried to connect from this address (at most once
/// an hour per device).
pub fn alert_revoked_key(device: String, ip: Option<IpAddr>) {
    if ALERTED.get(&device).is_some() {
        return;
    }
    ALERTED.insert(device.clone(), ());
    tracing::warn!(
        device = display(&device),
        ip = debug(ip),
        "a revoked key tried to connect"
    );
    geph5_rt::spawn(async move {
        let (asn, country) = match ip {
            Some(ip) => network_of(ip).await,
            None => (0, String::new()),
        };
        let mut alerts = ALERTS.lock().unwrap();
        alerts.push(Alert {
            at: now_secs(),
            kind: "revoked-key".into(),
            device,
            asn,
            country,
        });
        let excess = alerts.len().saturating_sub(ALERTS_KEPT);
        alerts.drain(..excess);
    })
    .detach();
}

async fn network_of(ip: IpAddr) -> (u32, String) {
    let local = match ip {
        IpAddr::V4(v4) => v4.is_loopback() || v4.is_private() || v4.is_link_local(),
        IpAddr::V6(v6) => v6.is_loopback() || v6.is_unique_local(),
    };
    if local {
        return (0, String::new());
    }
    match geph5_ip_to_asn::ip_to_asn_country(ip).await {
        Ok((asn, country)) => (asn, country),
        Err(err) => {
            tracing::debug!(err = debug(err), "no network for address");
            (0, String::new())
        }
    }
}

/// Notes which network a device is connecting from (ASN and country; the
/// address itself is not kept), whether it came in hidden, and whether its
/// handshake was quantum-safe.
pub fn note_connection(device: &Device, ip: Option<IpAddr>, stealth: bool, quantum_safe: bool) {
    let usage = usage_for(&device.name);
    usage.stealth.store(stealth, Ordering::Relaxed);
    usage.quantum_safe.store(quantum_safe, Ordering::Relaxed);
    // devices only come from this host through the disguised address's edge
    usage
        .disguised
        .store(ip.is_some_and(|ip| ip.is_loopback()), Ordering::Relaxed);
    let Some(ip) = ip else { return };
    TRUSTED.insert(ip, ());
    FAILURES.invalidate(&ip);
    geph5_rt::spawn(async move {
        let network = network_of(ip).await;
        if network.0 != 0 {
            *usage.network.lock().unwrap() = Some(network);
        }
    })
    .detach();
}

static REJECTED: LazyLock<Mutex<std::collections::VecDeque<(u64, u64)>>> =
    LazyLock::new(Default::default);

/// Counts refused connections by hour, for the status page.
fn count_rejection() {
    let hour = now_secs() / 3600;
    let mut r = REJECTED.lock().unwrap();
    match r.back_mut() {
        Some((h, n)) if *h == hour => *n += 1,
        _ => r.push_back((hour, 1)),
    }
    while r.front().is_some_and(|(h, _)| h + 24 <= hour) {
        r.pop_front();
    }
}

fn rejected_24h() -> u64 {
    let hour = now_secs() / 3600;
    REJECTED
        .lock()
        .unwrap()
        .iter()
        .filter(|(h, _)| h + 24 > hour)
        .map(|(_, n)| n)
        .sum()
}

/// One rate limiter per device, shared by all its sessions.
pub async fn device_ratelimiter(device: &Device, key: SessionKey) -> RateLimiter {
    let name = device.name.clone();
    RATE_LIMITER_CACHE
        .get_with(key, async move {
            RateLimiter::new(
                CONFIG_FILE.wait().device_ratelimit,
                BwAccount::unlimited(),
                Some(name),
            )
        })
        .await
}

/// Ports no device may reach through the exit (mail submission, to keep the
/// exit's IP off spam lists).
pub fn port_blocked(port: u16) -> bool {
    CONFIG_FILE.wait().blocked_ports.contains(&port)
}

// ---------------------------------------------------------------- usage

#[derive(Default)]
pub struct Usage {
    pub up: AtomicU64,
    pub down: AtomicU64,
    pub sessions: AtomicU64,
    pub last_seen: AtomicU64,
    pub stealth: AtomicBool,
    pub quantum_safe: AtomicBool,
    pub disguised: AtomicBool,
    pub network: Mutex<Option<(u32, String)>>,
}

static USAGE: LazyLock<DashMap<String, Arc<Usage>>> = LazyLock::new(DashMap::new);

fn usage_for(name: &str) -> Arc<Usage> {
    USAGE.entry(name.to_string()).or_default().clone()
}

#[derive(Serialize, Deserialize, Default)]
struct StatusFile {
    started: u64,
    updated: u64,
    devices: BTreeMap<String, DeviceStatus>,
    #[serde(default)]
    alerts: Vec<Alert>,
    #[serde(default)]
    rejected_24h: u64,
}

#[derive(Serialize, Deserialize, Default, Clone)]
struct DeviceStatus {
    bytes_up: u64,
    bytes_down: u64,
    active_sessions: u64,
    last_seen: u64,
    /// Whether its latest connection came over the stealth link.
    #[serde(default)]
    stealth: bool,
    /// Whether its latest handshake was quantum-safe (X25519 + ML-KEM-768).
    #[serde(default)]
    quantum_safe: bool,
    /// Whether it came through the disguised address.
    #[serde(default)]
    disguised: bool,
    #[serde(default)]
    asn: u32,
    #[serde(default)]
    country: String,
    #[serde(default)]
    shield: Option<shield::Summary>,
}

/// Writes per-device usage to the status file every few seconds, carrying
/// totals across restarts.
pub async fn status_loop() -> anyhow::Result<()> {
    let Some(path) = CONFIG_FILE.wait().kestrel_status.clone() else {
        return std::future::pending().await;
    };
    let previous: StatusFile = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    let started = now_secs();
    ALERTS.lock().unwrap().clone_from(&previous.alerts);
    loop {
        tokio::time::sleep(Duration::from_secs(5)).await;
        let mut devices = previous.devices.clone();
        for d in devices.values_mut() {
            d.active_sessions = 0;
        }
        for entry in USAGE.iter() {
            let u = entry.value();
            let d = devices.entry(entry.key().clone()).or_default();
            let base = previous
                .devices
                .get(entry.key())
                .cloned()
                .unwrap_or_default();
            d.bytes_up = base.bytes_up + u.up.load(Ordering::Relaxed);
            d.bytes_down = base.bytes_down + u.down.load(Ordering::Relaxed);
            d.active_sessions = u.sessions.load(Ordering::Relaxed);
            d.last_seen = u.last_seen.load(Ordering::Relaxed).max(base.last_seen);
            if u.sessions.load(Ordering::Relaxed) > 0 || u.last_seen.load(Ordering::Relaxed) > 0 {
                d.stealth = u.stealth.load(Ordering::Relaxed);
                d.quantum_safe = u.quantum_safe.load(Ordering::Relaxed);
                d.disguised = u.disguised.load(Ordering::Relaxed);
            }
            if let Some((asn, country)) = u.network.lock().unwrap().clone() {
                d.asn = asn;
                d.country = country;
            }
        }
        for (name, summary) in shield::summaries() {
            devices.entry(name).or_default().shield = Some(summary);
        }
        let status = StatusFile {
            started,
            updated: now_secs(),
            devices,
            alerts: ALERTS.lock().unwrap().clone(),
            rejected_24h: rejected_24h(),
        };
        let tmp = path.with_extension("tmp");
        if let Err(err) = std::fs::write(&tmp, serde_json::to_vec_pretty(&status)?)
            .and_then(|_| std::fs::rename(&tmp, &path))
        {
            tracing::warn!(err = debug(err), "cannot write status file");
        }
    }
}

/// Counts bytes for a device's connection and marks it active while open.
pub struct UsagePipe<P> {
    inner: P,
    usage: Arc<Usage>,
}

impl<P: Pipe> UsagePipe<P> {
    pub fn new(inner: P, device: &Device) -> Self {
        let usage = usage_for(&device.name);
        usage.sessions.fetch_add(1, Ordering::Relaxed);
        usage.last_seen.store(now_secs(), Ordering::Relaxed);
        Self { inner, usage }
    }
}

impl<P> Drop for UsagePipe<P> {
    fn drop(&mut self) {
        self.usage.sessions.fetch_sub(1, Ordering::Relaxed);
        self.usage.last_seen.store(now_secs(), Ordering::Relaxed);
    }
}

impl<P: Pipe> AsyncRead for UsagePipe<P> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let res = Pin::new(&mut self.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = &res {
            let n = (buf.filled().len() - before) as u64;
            self.usage.up.fetch_add(n, Ordering::Relaxed);
        }
        res
    }
}

impl<P: Pipe> AsyncWrite for UsagePipe<P> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let res = Pin::new(&mut self.inner).poll_write(cx, buf);
        if let Poll::Ready(Ok(n)) = &res {
            self.usage.down.fetch_add(*n as u64, Ordering::Relaxed);
        }
        res
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

impl<P: Pipe> Pipe for UsagePipe<P> {
    fn shared_secret(&self) -> Option<&[u8]> {
        self.inner.shared_secret()
    }

    fn protocol(&self) -> &str {
        self.inner.protocol()
    }

    fn remote_addr(&self) -> Option<&str> {
        self.inner.remote_addr()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn devices_can_allow_and_unallow_domains_by_request() {
        assert!(apply_request("t-req", "shield-allow.login.example.com"));
        assert!(apply_request("t-req", "shield-unallow.login.example.com"));
        for bad in [
            "shield-allow",
            "shield-allow.",
            "shield-allow.localhost",
            "shield-allow.a..b",
            "shield-allow.x_y.com",
            "shield-block.example.com",
            "rm -rf",
        ] {
            assert!(!apply_request("t-req", bad), "{bad:?} was accepted");
        }
        assert!(apply_request("t-req", "status"));
    }

    #[test]
    fn internal_names_do_nothing_off_their_port() {
        for dest in [
            "shield-pause.kestrel.internal:80",
            "SHIELD-PAUSE.kestrel.internal:443",
            "shield-pause.kestrel.internal",
        ] {
            let body = internal_request("t-port", None, dest).expect("an internal name");
            assert_eq!(body, br#"{"error":"unknown request"}"#, "{dest}");
        }
        assert_eq!(shield::summary("t-port").paused_until, 0);
        assert!(internal_request("t-port", None, "example.com:1").is_none());
    }

    #[test]
    fn a_report_speaks_for_the_session_asking() {
        let device = Device {
            name: "t-link".into(),
        };
        // the device's latest connection was quantum-safe and stealthy...
        note_connection(&device, None, true, true);
        let usage = usage_for("t-link");
        // ...but this older session came in classical over the plain link
        let classical = Link {
            stealth: false,
            quantum_safe: false,
        };
        let meta = tag_metadata(None, &device, classical);
        assert_eq!(link_of(&meta), Some(classical));
        assert_eq!(reported_link(link_of(&meta), Some(&usage)), classical);
        // a session with no recorded link still gets the device's latest
        let latest = Link {
            stealth: true,
            quantum_safe: true,
        };
        assert_eq!(
            reported_link(link_of(&serde_json::json!({})), Some(&usage)),
            latest
        );
        // a client can't claim a link: the exit's value replaces whatever it sent
        let sent = serde_json::json!({ "kestrel_link": { "stealth": true, "quantum_safe": true } });
        assert_eq!(
            link_of(&tag_metadata(Some(sent), &device, classical)),
            Some(classical)
        );
    }

    #[test]
    fn an_owners_revoked_key_never_blocks_its_address() {
        let ip: IpAddr = "203.0.113.77".parse().unwrap();
        for _ in 0..3 * MAX_FAILURES {
            refused_handshake(Some("t-old-laptop".into()), Some(ip));
        }
        assert!(
            !is_banned(ip),
            "an old device of the owner's locked out its network"
        );
        let stranger: IpAddr = "203.0.113.78".parse().unwrap();
        for _ in 0..MAX_FAILURES {
            refused_handshake(None, Some(stranger));
        }
        assert!(is_banned(stranger), "a stranger was not blocked");
    }
}

//! Kestrel private mode: only devices listed in the device file may use this
//! exit. There is no broker, no account and no free tier.

use std::{
    collections::BTreeMap,
    io,
    net::IpAddr,
    path::Path,
    pin::Pin,
    sync::{
        Arc, LazyLock,
        atomic::{AtomicU64, Ordering},
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
}

pub fn load_devices(path: &Path) -> anyhow::Result<DeviceFile> {
    let raw = std::fs::read(path).with_context(|| format!("cannot read {}", path.display()))?;
    Ok(serde_json::from_slice(&raw)?)
}

/// An authorized device for one connection.
pub struct Device {
    pub name: String,
}

static FAILURES: LazyLock<Cache<IpAddr, u32>> = LazyLock::new(|| {
    Cache::builder()
        .time_to_live(Duration::from_secs(900))
        .max_capacity(100_000)
        .build()
});

pub fn is_banned(ip: IpAddr) -> bool {
    !ip.is_loopback() && FAILURES.get(&ip).unwrap_or(0) >= MAX_FAILURES
}

pub fn record_failure(ip: IpAddr) {
    if ip.is_loopback() {
        return;
    }
    let n = FAILURES.get(&ip).unwrap_or(0) + 1;
    FAILURES.insert(ip, n);
    if n == MAX_FAILURES {
        tracing::warn!(ip = display(ip), "too many failed handshakes; blocking for 15 minutes");
    }
}

/// Checks the device credential in a client hello. Fails closed.
pub fn authorize(hello: &ClientHello) -> anyhow::Result<Device> {
    if !matches!(hello.crypt_hello, ClientCryptHello::X25519(_)) {
        anyhow::bail!("private mode requires end-to-end encryption");
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
    Ok(Device {
        name: entry.name.clone(),
    })
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
}

#[derive(Serialize, Deserialize, Default, Clone)]
struct DeviceStatus {
    bytes_up: u64,
    bytes_down: u64,
    active_sessions: u64,
    last_seen: u64,
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
    loop {
        tokio::time::sleep(Duration::from_secs(5)).await;
        let mut devices = previous.devices.clone();
        for d in devices.values_mut() {
            d.active_sessions = 0;
        }
        for entry in USAGE.iter() {
            let u = entry.value();
            let d = devices.entry(entry.key().clone()).or_default();
            let base = previous.devices.get(entry.key()).cloned().unwrap_or_default();
            d.bytes_up = base.bytes_up + u.up.load(Ordering::Relaxed);
            d.bytes_down = base.bytes_down + u.down.load(Ordering::Relaxed);
            d.active_sessions = u.sessions.load(Ordering::Relaxed);
            d.last_seen = u.last_seen.load(Ordering::Relaxed).max(base.last_seen);
        }
        let status = StatusFile {
            started,
            updated: now_secs(),
            devices,
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

//! Kestrel Shield: the exit refuses ad, tracker and malware domains for each
//! device that has it on (the default). Blocked lookups are answered at once
//! with NXDOMAIN, so apps move on instead of waiting; blocked connections by
//! name are refused. The exit counts lookups and blocks per device, by hour,
//! for the status page and the apps.
//!
//! The list is oisd big ("block, don't break"), fetched daily and cached in
//! the state directory so a restart never runs without it. The owner's allow
//! list (`shield-allow.txt`, one domain per line) always wins, and so does a
//! device's own (`shield-allow-devices.json`).
//!
//! Each device can see what was just blocked for it (the last 50 domains,
//! kept in memory only) and allow one from its app when a site breaks.

use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
    sync::{Arc, LazyLock, Mutex, RwLock},
    time::{Duration, SystemTime},
};

use bytes::Bytes;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use simple_dns::{Packet, PacketFlag, RCODE};

use super::now_secs;

const LIST_URL: &str = "https://big.oisd.nl/domainswild2";
const LIST_FILE: &str = "shield-list.txt";
const ALLOW_FILE: &str = "shield-allow.txt";
const DEVICE_ALLOW_FILE: &str = "shield-allow-devices.json";
const STATS_FILE: &str = "shield.json";
/// Recently blocked domains remembered per device.
const RECENT_KEPT: usize = 50;
const REFRESH_SECS: u64 = 24 * 3600;
const HOURS_KEPT: usize = 24;
/// Distinct blocked domains remembered per device per hour.
const TOP_PER_HOUR: usize = 200;

#[derive(Default)]
struct Lists {
    block: HashSet<Box<str>>,
    allow: HashSet<Box<str>>,
}

static LISTS: LazyLock<RwLock<Arc<Lists>>> = LazyLock::new(Default::default);

/// Domains each device allowed for itself from its app.
static DEVICE_ALLOW: LazyLock<RwLock<BTreeMap<String, Vec<String>>>> =
    LazyLock::new(Default::default);

/// Where the allow lists are saved (the exit's state directory).
static STATE_DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// Per-device on/off, from the device file. Devices not listed are on.
static ENABLED: LazyLock<DashMap<String, bool>> = LazyLock::new(DashMap::new);

/// Domains and their parents, most specific first: a.b.c, b.c, c.
fn suffixes(host: &str) -> impl Iterator<Item = &str> {
    std::iter::successors(Some(host), |h| h.split_once('.').map(|(_, rest)| rest))
}

fn normalize(host: &str) -> String {
    host.trim_end_matches('.').to_ascii_lowercase()
}

fn list_blocks(lists: &Lists, host: &str) -> bool {
    if suffixes(host).any(|s| lists.allow.contains(s)) {
        return false;
    }
    suffixes(host).any(|s| lists.block.contains(s))
}

pub fn set_enabled(device: &str, on: bool) {
    ENABLED.insert(device.to_string(), on);
}

/// Devices that paused Shield from their app, until when. Kept in memory
/// only: a restart ends every pause.
static PAUSED: LazyLock<DashMap<String, u64>> = LazyLock::new(DashMap::new);

pub fn pause(device: &str, secs: u64) {
    PAUSED.insert(device.to_string(), now_secs() + secs);
}

pub fn resume(device: &str) {
    PAUSED.remove(device);
}

fn paused_until(device: &str) -> u64 {
    PAUSED
        .get(device)
        .map(|v| *v)
        .filter(|until| *until > now_secs())
        .unwrap_or(0)
}

/// Whether the owner has Shield on for this device (paused or not).
pub fn switched_on(device: &str) -> bool {
    ENABLED.get(device).map(|v| *v).unwrap_or(true)
}

pub fn enabled(device: &str) -> bool {
    switched_on(device) && paused_until(device) == 0
}

fn device_allows(device: &str, host: &str) -> bool {
    DEVICE_ALLOW
        .read()
        .unwrap()
        .get(device)
        .is_some_and(|list| suffixes(host).any(|s| list.iter().any(|d| d == s)))
}

/// Whether Shield stops this device from reaching this host.
pub fn blocks(device: &str, host: &str) -> bool {
    let host = normalize(host);
    enabled(device) && !device_allows(device, &host) && list_blocks(&LISTS.read().unwrap(), &host)
}

// ---------------------------------------------------------------- allowing

/// A domain name a device may allow: letters, digits and hyphens in dotted
/// labels, nothing else.
pub fn valid_domain(domain: &str) -> Option<String> {
    let d = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    let ok = !d.is_empty()
        && d.len() <= 253
        && d.contains('.')
        && d.split('.').all(|l| {
            !l.is_empty() && l.len() <= 63 && l.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        });
    ok.then_some(d)
}

/// Allows a domain for one device, or (`everywhere`) for all of them, and
/// takes it off the device's "just blocked" list.
pub fn allow(device: &str, domain: &str, everywhere: bool) {
    if everywhere {
        let mut lists = LISTS.write().unwrap();
        let mut next = Lists {
            block: lists.block.clone(),
            allow: lists.allow.clone(),
        };
        next.allow.insert(domain.into());
        *lists = Arc::new(next);
        drop(lists);
        save_global_allow(Some(domain), None);
    } else {
        let mut all = DEVICE_ALLOW.write().unwrap();
        let list = all.entry(device.to_string()).or_default();
        if !list.iter().any(|d| d == domain) {
            list.push(domain.to_string());
            list.sort();
        }
        drop(all);
        save_device_allow();
    }
    if let Some(mut recent) = RECENT.get_mut(device) {
        recent.retain(|r| r.domain != domain && !r.domain.ends_with(&format!(".{domain}")));
    }
}

/// Undoes an allow: off this device's list and off the list for all devices.
pub fn unallow(device: &str, domain: &str) {
    let mut all = DEVICE_ALLOW.write().unwrap();
    if let Some(list) = all.get_mut(device) {
        list.retain(|d| d != domain);
    }
    drop(all);
    save_device_allow();
    let global = LISTS.read().unwrap().allow.contains(domain);
    if global {
        let mut lists = LISTS.write().unwrap();
        let mut next = Lists {
            block: lists.block.clone(),
            allow: lists.allow.clone(),
        };
        next.allow.remove(domain);
        *lists = Arc::new(next);
        drop(lists);
        save_global_allow(None, Some(domain));
    }
}

fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data)?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o660))?;
    std::fs::rename(&tmp, path)
}

fn save_device_allow() {
    let Some(dir) = STATE_DIR.get() else { return };
    let raw = serde_json::to_vec_pretty(&*DEVICE_ALLOW.read().unwrap()).unwrap_or_default();
    if let Err(err) = write_atomic(&dir.join(DEVICE_ALLOW_FILE), &raw) {
        tracing::warn!(err = debug(err), "cannot save the devices' allow lists");
    }
}

/// Edits the owner's allow file line by line, keeping what kestrelctl or the
/// page wrote there.
fn save_global_allow(add: Option<&str>, remove: Option<&str>) {
    let Some(dir) = STATE_DIR.get() else { return };
    let path = dir.join(ALLOW_FILE);
    let mut lines: Vec<String> = std::fs::read_to_string(&path)
        .unwrap_or_default()
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && Some(l.as_str()) != remove)
        .collect();
    if let Some(d) = add
        && !lines.iter().any(|l| l == d)
    {
        lines.push(d.to_string());
    }
    lines.sort();
    lines.dedup();
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    if let Err(err) = write_atomic(&path, text.as_bytes()) {
        tracing::warn!(err = debug(err), "cannot save the allow list");
    }
}

fn load_device_allow(dir: &Path) {
    if let Some(all) = std::fs::read(dir.join(DEVICE_ALLOW_FILE))
        .ok()
        .and_then(|b| serde_json::from_slice::<BTreeMap<String, Vec<String>>>(&b).ok())
    {
        *DEVICE_ALLOW.write().unwrap() = all;
    }
}

/// This device's own allowed domains.
fn device_allowed(device: &str) -> Vec<String> {
    DEVICE_ALLOW.read().unwrap().get(device).cloned().unwrap_or_default()
}

/// The domains allowed for every device.
fn allowed_everywhere() -> Vec<String> {
    let mut v: Vec<String> = LISTS.read().unwrap().allow.iter().map(|d| d.to_string()).collect();
    v.sort();
    v
}

// ---------------------------------------------------------------- just blocked

/// A domain recently blocked for a device.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Recent {
    pub domain: String,
    pub count: u64,
    /// When it was last blocked (unix seconds).
    pub last: u64,
}

static RECENT: LazyLock<DashMap<String, VecDeque<Recent>>> = LazyLock::new(DashMap::new);

fn note_recent(device: &str, domain: &str, at: u64) {
    let mut recent = RECENT.entry(device.to_string()).or_default();
    let count = match recent.iter().position(|r| r.domain == domain) {
        Some(i) => recent.remove(i).map(|r| r.count).unwrap_or(0),
        None => 0,
    };
    recent.push_front(Recent {
        domain: domain.to_string(),
        count: count + 1,
        last: at,
    });
    recent.truncate(RECENT_KEPT);
}

fn recent_for(device: &str) -> Vec<Recent> {
    RECENT
        .get(device)
        .map(|r| r.iter().cloned().collect())
        .unwrap_or_default()
}

/// Checks a connection by name ("host:port"); counts it as a lookup.
pub fn check_dial(device: &str, dest: &str) -> anyhow::Result<()> {
    let host = dest.rsplit_once(':').map(|(h, _)| h).unwrap_or(dest);
    let host = host.trim_start_matches('[').trim_end_matches(']');
    if host.parse::<std::net::IpAddr>().is_ok() {
        return Ok(());
    }
    if blocks(device, host) {
        record(device, Some(&normalize(host)));
        anyhow::bail!("blocked by Kestrel Shield");
    }
    record(device, None);
    Ok(())
}

/// For a DNS query from a device: the NXDOMAIN reply if Shield blocks the
/// name, or None to resolve it as usual. Counts the lookup either way.
pub fn dns_reply(device: &str, query: &[u8]) -> Option<Bytes> {
    let packet = Packet::parse(query).ok()?;
    let name = packet
        .questions
        .first()
        .map(|q| normalize(&q.qname.to_string()))?;
    if !blocks(device, &name) {
        record(device, None);
        return None;
    }
    record(device, Some(&name));
    let mut reply = Packet::new_reply(packet.id());
    reply.set_flags(PacketFlag::RECURSION_DESIRED | PacketFlag::RECURSION_AVAILABLE);
    *reply.rcode_mut() = RCODE::NameError;
    reply.questions = packet.questions.clone();
    reply.build_bytes_vec().ok().map(Bytes::from)
}

// ---------------------------------------------------------------- stats

#[derive(Serialize, Deserialize, Default, Clone)]
struct Hour {
    hour: u64,
    lookups: u64,
    blocked: u64,
    #[serde(default)]
    top: HashMap<String, u64>,
}

#[derive(Serialize, Deserialize, Default, Clone)]
struct DeviceStats {
    blocked_total: u64,
    hours: VecDeque<Hour>,
}

static STATS: LazyLock<Mutex<BTreeMap<String, DeviceStats>>> = LazyLock::new(Default::default);

fn record(device: &str, blocked: Option<&str>) {
    record_at(device, blocked, now_secs() / 3600)
}

fn record_at(device: &str, blocked: Option<&str>, hour: u64) {
    let mut stats = STATS.lock().unwrap();
    let dev = stats.entry(device.to_string()).or_default();
    if dev.hours.back().is_none_or(|h| h.hour != hour) {
        dev.hours.push_back(Hour {
            hour,
            ..Default::default()
        });
    }
    while dev
        .hours
        .front()
        .is_some_and(|h| h.hour + HOURS_KEPT as u64 <= hour)
    {
        dev.hours.pop_front();
    }
    let h = dev.hours.back_mut().unwrap();
    h.lookups += 1;
    if let Some(domain) = blocked {
        note_recent(device, domain, now_secs());
        h.blocked += 1;
        dev.blocked_total += 1;
        if let Some(n) = h.top.get_mut(domain) {
            *n += 1;
        } else if h.top.len() < TOP_PER_HOUR {
            h.top.insert(domain.to_string(), 1);
        }
    }
}

/// What the status page shows for one device.
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Summary {
    pub enabled: bool,
    /// Paused from the device's app until this time (0: not paused).
    #[serde(default)]
    pub paused_until: u64,
    pub lookups_24h: u64,
    pub blocked_24h: u64,
    pub blocked_total: u64,
    /// Blocked lookups per hour, oldest first, ending with the current hour.
    pub hourly: Vec<u64>,
    /// The most blocked domains in the last 24 hours.
    pub top: Vec<(String, u64)>,
    /// Just blocked for this device, newest first (since the exit started).
    #[serde(default)]
    pub recent: Vec<Recent>,
    /// Domains this device allowed for itself.
    #[serde(default)]
    pub allowed: Vec<String>,
    /// Domains allowed for every device.
    #[serde(default)]
    pub allowed_everywhere: Vec<String>,
}

pub fn summaries() -> BTreeMap<String, Summary> {
    summaries_at(now_secs() / 3600)
}

/// One device's summary, even before it has made a lookup.
pub fn summary(device: &str) -> Summary {
    summaries().remove(device).unwrap_or_else(|| Summary {
        enabled: switched_on(device),
        paused_until: paused_until(device),
        hourly: vec![0; HOURS_KEPT],
        recent: recent_for(device),
        allowed: device_allowed(device),
        allowed_everywhere: allowed_everywhere(),
        ..Default::default()
    })
}

fn summaries_at(now_hour: u64) -> BTreeMap<String, Summary> {
    let everywhere = allowed_everywhere();
    let stats = STATS.lock().unwrap();
    stats
        .iter()
        .map(|(name, dev)| {
            let recent: Vec<&Hour> = dev
                .hours
                .iter()
                // hours ahead of now (the clock stepped back) wait until they come round
                .filter(|h| h.hour + HOURS_KEPT as u64 > now_hour && h.hour <= now_hour)
                .collect();
            let mut hourly = vec![0u64; HOURS_KEPT];
            for h in &recent {
                let back = (now_hour - h.hour) as usize;
                hourly[HOURS_KEPT - 1 - back] = h.blocked;
            }
            let mut top: HashMap<&str, u64> = HashMap::new();
            for h in &recent {
                for (d, n) in &h.top {
                    *top.entry(d).or_default() += n;
                }
            }
            let mut top: Vec<(String, u64)> =
                top.into_iter().map(|(d, n)| (d.to_string(), n)).collect();
            top.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            top.truncate(10);
            let summary = Summary {
                enabled: switched_on(name),
                paused_until: paused_until(name),
                lookups_24h: recent.iter().map(|h| h.lookups).sum(),
                blocked_24h: recent.iter().map(|h| h.blocked).sum(),
                blocked_total: dev.blocked_total,
                hourly,
                top,
                recent: recent_for(name),
                allowed: device_allowed(name),
                allowed_everywhere: everywhere.clone(),
            };
            (name.clone(), summary)
        })
        .collect()
}

// ---------------------------------------------------------------- upkeep

fn parse_domains(text: &str) -> HashSet<Box<str>> {
    text.lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| normalize(l.trim_start_matches("*.")).into_boxed_str())
        .collect()
}

fn mtime(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

fn age_secs(path: &Path) -> u64 {
    mtime(path)
        .and_then(|t| t.elapsed().ok())
        .map(|d| d.as_secs())
        .unwrap_or(u64::MAX)
}

fn load_lists(dir: &Path) {
    let block = std::fs::read_to_string(dir.join(LIST_FILE))
        .map(|t| parse_domains(&t))
        .unwrap_or_default();
    let allow = std::fs::read_to_string(dir.join(ALLOW_FILE))
        .map(|t| parse_domains(&t))
        .unwrap_or_default();
    tracing::info!(
        block = block.len(),
        allow = allow.len(),
        "Shield lists loaded"
    );
    *LISTS.write().unwrap() = Arc::new(Lists { block, allow });
}

async fn fetch_list(dir: &Path) -> anyhow::Result<()> {
    let text = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()?
        .get(LIST_URL)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let count = parse_domains(&text).len();
    // a truncated or empty download must not replace a good list
    anyhow::ensure!(count > 10_000, "the list only had {count} domains");
    let tmp = dir.join(format!("{LIST_FILE}.tmp"));
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, dir.join(LIST_FILE))?;
    Ok(())
}

fn refresh_enabled(devices: &Path) {
    if let Ok(file) = super::load_devices(devices) {
        for d in file.devices.iter().filter(|d| !d.revoked) {
            set_enabled(&d.name, d.shield.unwrap_or(true));
        }
    }
}

fn load_stats(dir: &Path) {
    if let Some(stats) = std::fs::read(dir.join(STATS_FILE))
        .ok()
        .and_then(|b| serde_json::from_slice::<BTreeMap<String, DeviceStats>>(&b).ok())
    {
        *STATS.lock().unwrap() = stats;
    }
}

fn save_stats(dir: &Path) {
    let raw = serde_json::to_vec(&*STATS.lock().unwrap()).unwrap_or_default();
    let tmp = dir.join(format!("{STATS_FILE}.tmp"));
    if let Err(err) =
        std::fs::write(&tmp, raw).and_then(|_| std::fs::rename(&tmp, dir.join(STATS_FILE)))
    {
        tracing::warn!(err = debug(err), "cannot save Shield stats");
    }
}

/// Keeps the lists, the per-device switches and the saved counts current.
pub async fn shield_loop(dir: PathBuf, devices: PathBuf) -> anyhow::Result<()> {
    let _ = STATE_DIR.set(dir.clone());
    load_device_allow(&dir);
    load_stats(&dir);
    refresh_enabled(&devices);
    load_lists(&dir);
    let mut seen = (
        mtime(&dir.join(LIST_FILE)),
        mtime(&dir.join(ALLOW_FILE)),
        mtime(&devices),
    );
    // the other exit merges its devices' allows in (allow-sync.py)
    let mut seen_device_allow = mtime(&dir.join(DEVICE_ALLOW_FILE));
    let mut last_try = 0u64;
    loop {
        if age_secs(&dir.join(LIST_FILE)) > REFRESH_SECS && now_secs() - last_try > 3600 {
            last_try = now_secs();
            match fetch_list(&dir).await {
                Ok(()) => tracing::info!("Shield list refreshed"),
                Err(err) => tracing::warn!(err = debug(err), "cannot refresh the Shield list"),
            }
        }
        let now = (
            mtime(&dir.join(LIST_FILE)),
            mtime(&dir.join(ALLOW_FILE)),
            mtime(&devices),
        );
        if now.0 != seen.0 || now.1 != seen.1 {
            // parsing 200k domains takes a moment; keep it off the async threads
            let dir = dir.clone();
            geph5_rt::spawn_blocking(move || load_lists(&dir)).await;
        }
        if now.2 != seen.2 {
            refresh_enabled(&devices);
        }
        let device_allow = mtime(&dir.join(DEVICE_ALLOW_FILE));
        if device_allow != seen_device_allow {
            load_device_allow(&dir);
            seen_device_allow = device_allow;
        }
        seen = now;
        save_stats(&dir);
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tests that swap the shared lists take turns.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn lists(block: &[&str], allow: &[&str]) -> Lists {
        Lists {
            block: block.iter().map(|s| Box::from(*s)).collect(),
            allow: allow.iter().map(|s| Box::from(*s)).collect(),
        }
    }

    #[test]
    fn blocks_listed_domains_and_their_subdomains_only() {
        let l = lists(&["doubleclick.net", "tracker.example"], &[]);
        assert!(list_blocks(&l, "doubleclick.net"));
        assert!(list_blocks(&l, "ad.g.doubleclick.net"));
        assert!(list_blocks(&l, "x.tracker.example"));
        assert!(!list_blocks(&l, "example"));
        assert!(!list_blocks(&l, "notdoubleclick.net"));
        assert!(!list_blocks(&l, "doubleclick.net.evil.com"));
    }

    #[test]
    fn allow_list_wins() {
        let l = lists(&["example.com"], &["good.example.com"]);
        assert!(list_blocks(&l, "bad.example.com"));
        assert!(!list_blocks(&l, "good.example.com"));
        assert!(!list_blocks(&l, "a.good.example.com"));
    }

    #[test]
    fn parses_oisd_and_hand_written_lines() {
        let d = parse_domains("# comment\n\nDoubleClick.net\n*.ads.example.\n  spaced.example  \n");
        let mut v: Vec<&str> = d.iter().map(|s| &**s).collect();
        v.sort();
        assert_eq!(v, ["ads.example", "doubleclick.net", "spaced.example"]);
    }

    fn query(name: &str) -> Vec<u8> {
        let mut p = Packet::new_query(4242);
        p.questions.push(simple_dns::Question::new(
            simple_dns::Name::new_unchecked(name),
            simple_dns::QTYPE::TYPE(simple_dns::TYPE::A),
            simple_dns::QCLASS::CLASS(simple_dns::CLASS::IN),
            false,
        ));
        p.build_bytes_vec().unwrap()
    }

    #[test]
    fn blocked_lookups_get_nxdomain_and_are_counted() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        *LISTS.write().unwrap() = Arc::new(lists(&["doubleclick.net"], &[]));
        set_enabled("t-dns", true);
        let reply = dns_reply("t-dns", &query("stats.g.doubleclick.net")).expect("blocked");
        let reply = Packet::parse(&reply).unwrap();
        assert_eq!(reply.id(), 4242);
        assert_eq!(reply.rcode(), RCODE::NameError);
        assert_eq!(reply.questions.len(), 1);
        assert!(dns_reply("t-dns", &query("example.org")).is_none());
        let s = &summaries()["t-dns"];
        assert_eq!((s.lookups_24h, s.blocked_24h, s.blocked_total), (2, 1, 1));
        assert_eq!(s.top, vec![("stats.g.doubleclick.net".to_string(), 1)]);
    }

    #[test]
    fn devices_with_shield_off_are_not_blocked() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        *LISTS.write().unwrap() = Arc::new(lists(&["doubleclick.net"], &[]));
        set_enabled("t-off", false);
        assert!(dns_reply("t-off", &query("doubleclick.net")).is_none());
        assert!(check_dial("t-off", "doubleclick.net:443").is_ok());
        set_enabled("t-on", true);
        assert!(check_dial("t-on", "doubleclick.net:443").is_err());
        assert!(check_dial("t-on", "1.2.3.4:443").is_ok());
        assert!(check_dial("t-on", "[::1]:443").is_ok());
    }

    #[test]
    fn a_pause_lets_lookups_through_until_resumed() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        *LISTS.write().unwrap() = Arc::new(lists(&["doubleclick.net"], &[]));
        set_enabled("t-pause", true);
        pause("t-pause", 3600);
        assert!(dns_reply("t-pause", &query("doubleclick.net")).is_none());
        assert!(summary("t-pause").paused_until > now_secs());
        assert!(summary("t-pause").enabled);
        resume("t-pause");
        assert!(dns_reply("t-pause", &query("doubleclick.net")).is_some());
        assert_eq!(summary("t-pause").paused_until, 0);
    }

    #[test]
    fn hours_roll_over_and_old_hours_drop_out() {
        let base = 1_000_000;
        record_at("t-hours", Some("a.example"), base);
        record_at("t-hours", Some("a.example"), base);
        record_at("t-hours", Some("b.example"), base + 5);
        record_at("t-hours", None, base + 23);
        let s = &summaries_at(base + 23)["t-hours"];
        assert_eq!(s.blocked_24h, 3);
        assert_eq!(s.hourly.len(), 24);
        assert_eq!(s.hourly[0], 2);
        assert_eq!(s.hourly[5], 1);
        assert_eq!(s.top[0], ("a.example".to_string(), 2));
        // a day later the first hour has gone
        record_at("t-hours", None, base + 24);
        let s = &summaries_at(base + 24)["t-hours"];
        assert_eq!(s.blocked_24h, 1);
        assert_eq!(s.blocked_total, 3);
    }

    #[test]
    fn just_blocked_is_newest_first_counted_and_kept_per_device() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        *LISTS.write().unwrap() = Arc::new(lists(&["doubleclick.net"], &[]));
        set_enabled("t-recent", true);
        set_enabled("t-other", true);
        dns_reply("t-recent", &query("a.doubleclick.net"));
        dns_reply("t-recent", &query("b.doubleclick.net"));
        dns_reply("t-recent", &query("a.doubleclick.net"));
        dns_reply("t-recent", &query("example.org"));
        let r = summary("t-recent").recent;
        assert_eq!(
            r.iter().map(|r| (r.domain.as_str(), r.count)).collect::<Vec<_>>(),
            [("a.doubleclick.net", 2), ("b.doubleclick.net", 1)]
        );
        // one device never sees another's
        assert!(summary("t-other").recent.is_empty());
        for i in 0..80 {
            note_recent("t-recent", &format!("x{i}.doubleclick.net"), 1);
        }
        let r = summary("t-recent").recent;
        assert_eq!(r.len(), RECENT_KEPT);
        assert_eq!(r[0].domain, "x79.doubleclick.net");
    }

    #[test]
    fn a_device_allow_lets_only_that_device_through() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        *LISTS.write().unwrap() = Arc::new(lists(&["doubleclick.net"], &[]));
        set_enabled("t-allow-a", true);
        set_enabled("t-allow-b", true);
        assert!(dns_reply("t-allow-a", &query("ads.doubleclick.net")).is_some());
        allow("t-allow-a", "ads.doubleclick.net", false);
        assert!(dns_reply("t-allow-a", &query("ads.doubleclick.net")).is_none());
        assert!(dns_reply("t-allow-a", &query("x.ads.doubleclick.net")).is_none());
        assert!(check_dial("t-allow-a", "ads.doubleclick.net:443").is_ok());
        // a sibling and the other device stay blocked
        assert!(dns_reply("t-allow-a", &query("stats.doubleclick.net")).is_some());
        assert!(dns_reply("t-allow-b", &query("ads.doubleclick.net")).is_some());
        // allowing takes it off the just-blocked list
        assert!(!summary("t-allow-a").recent.iter().any(|r| r.domain == "ads.doubleclick.net"));
        assert_eq!(summary("t-allow-a").allowed, ["ads.doubleclick.net"]);
        unallow("t-allow-a", "ads.doubleclick.net");
        assert!(dns_reply("t-allow-a", &query("ads.doubleclick.net")).is_some());
        assert!(summary("t-allow-a").allowed.is_empty());
    }

    #[test]
    fn allowing_for_every_device_and_undoing_it() {
        let _turn = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        // its own list domain, so the parallel tests' lists don't matter
        set_enabled("t-every-a", true);
        set_enabled("t-every-b", true);
        let before = LISTS.read().unwrap().allow.contains("everywhere.example");
        assert!(!before);
        allow("t-every-a", "everywhere.example", true);
        assert!(LISTS.read().unwrap().allow.contains("everywhere.example"));
        assert!(summary("t-every-b").allowed_everywhere.contains(&"everywhere.example".to_string()));
        unallow("t-every-a", "everywhere.example");
        assert!(!LISTS.read().unwrap().allow.contains("everywhere.example"));
    }

    #[test]
    fn only_domain_names_can_be_allowed() {
        assert_eq!(valid_domain(" Example.COM. ").as_deref(), Some("example.com"));
        for bad in ["", "localhost", "a..b", "x.com/evil", "x.com\nevil.com", "-", "a_b.com"] {
            assert!(valid_domain(bad).is_none(), "{bad:?} was accepted");
        }
    }

    #[test]
    fn a_clock_that_steps_back_does_not_break_the_summary() {
        let base = 2_000_000;
        record_at("t-clock", Some("a.example"), base + 3);
        record_at("t-clock", Some("a.example"), base);
        let s = &summaries_at(base)["t-clock"];
        assert_eq!(s.hourly[23], 1);
    }
}

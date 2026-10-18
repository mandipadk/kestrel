//! Kestrel Shield: the exit refuses ad, tracker and malware domains for each
//! device that has it on (the default). Blocked lookups are answered at once
//! with NXDOMAIN, so apps move on instead of waiting; blocked connections by
//! name are refused. The exit counts lookups and blocks per device, by hour,
//! for the status page and the apps.
//!
//! The list is oisd big ("block, don't break"), fetched daily and cached in
//! the state directory so a restart never runs without it. The owner's allow
//! list (`shield-allow.txt`, one domain per line) always wins.

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
const STATS_FILE: &str = "shield.json";
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

pub fn enabled(device: &str) -> bool {
    ENABLED.get(device).map(|v| *v).unwrap_or(true)
}

/// Whether Shield stops this device from reaching this host.
pub fn blocks(device: &str, host: &str) -> bool {
    enabled(device) && list_blocks(&LISTS.read().unwrap(), &normalize(host))
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
    let name = packet.questions.first().map(|q| normalize(&q.qname.to_string()))?;
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
    pub lookups_24h: u64,
    pub blocked_24h: u64,
    pub blocked_total: u64,
    /// Blocked lookups per hour, oldest first, ending with the current hour.
    pub hourly: Vec<u64>,
    /// The most blocked domains in the last 24 hours.
    pub top: Vec<(String, u64)>,
}

pub fn summaries() -> BTreeMap<String, Summary> {
    summaries_at(now_secs() / 3600)
}

fn summaries_at(now_hour: u64) -> BTreeMap<String, Summary> {
    let stats = STATS.lock().unwrap();
    stats
        .iter()
        .map(|(name, dev)| {
            let recent: Vec<&Hour> = dev
                .hours
                .iter()
                .filter(|h| h.hour + HOURS_KEPT as u64 > now_hour)
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
                enabled: enabled(name),
                lookups_24h: recent.iter().map(|h| h.lookups).sum(),
                blocked_24h: recent.iter().map(|h| h.blocked).sum(),
                blocked_total: dev.blocked_total,
                hourly,
                top,
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
    tracing::info!(block = block.len(), allow = allow.len(), "Shield lists loaded");
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
    load_stats(&dir);
    refresh_enabled(&devices);
    load_lists(&dir);
    let mut seen = (mtime(&dir.join(LIST_FILE)), mtime(&dir.join(ALLOW_FILE)), mtime(&devices));
    let mut last_try = 0u64;
    loop {
        if age_secs(&dir.join(LIST_FILE)) > REFRESH_SECS && now_secs() - last_try > 3600 {
            last_try = now_secs();
            match fetch_list(&dir).await {
                Ok(()) => tracing::info!("Shield list refreshed"),
                Err(err) => tracing::warn!(err = debug(err), "cannot refresh the Shield list"),
            }
        }
        let now = (mtime(&dir.join(LIST_FILE)), mtime(&dir.join(ALLOW_FILE)), mtime(&devices));
        if now.0 != seen.0 || now.1 != seen.1 {
            // parsing 200k domains takes a moment; keep it off the async threads
            let dir = dir.clone();
            geph5_rt::spawn_blocking(move || load_lists(&dir)).await;
        }
        if now.2 != seen.2 {
            refresh_enabled(&devices);
        }
        seen = now;
        save_stats(&dir);
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}

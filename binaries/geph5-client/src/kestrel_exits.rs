//! Kestrel: the owner's exits (Chicago and Frankfurt). All of a device's
//! sessions use one exit at a time, so sites always see one address.
//!
//! Automatic mode races a full, authenticated handshake to every exit and
//! keeps the first to finish (the nearest, in practice). When the active exit
//! stops answering, it gets a short head start on each reconnect; after that
//! the others race it, and whichever finishes first takes over. Sessions on
//! the old exit then close, so new connections all move together.
//!
//! A pinned exit (`exit_choice`) is the only one used, with no failover.
//!
//! Exits tell a device the owner's exit list in its report. The engine takes
//! it at once (no reconnect, no saved settings): new exits are appended, so
//! the indexes sessions carry stay valid, and an automatic device races them
//! once to move to whichever is faster.

use std::{
    sync::{
        RwLock,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use anyctx::AnyCtx;
use anyhow::Context;
use futures_util::{StreamExt, stream::FuturesUnordered};
use geph5_broker_protocol::ExitDescriptor;
use geph5_misc_rpc::kestrel::KestrelExit;
use geph5_rt::TimeoutExt;
use sillad::{Pipe, dialer::Dialer as _};

use crate::{
    client::{Config, CtxField},
    get_dialer::{direct_dialer, disguised_dialer},
    session::client_auth,
};

const NONE: usize = usize::MAX;
/// How long the active exit gets before the others race it.
const HEAD_START: Duration = Duration::from_millis(1500);
/// How long a session's exit may take to answer a ping (sent with every new
/// connection) before the session counts as dead and the device fails over.
pub const PING_TIMEOUT: Duration = Duration::from_secs(3);
/// The most one attempt (dial and handshake) at one exit may take.
const ATTEMPT: Duration = Duration::from_secs(10);

static ACTIVE: CtxField<AtomicUsize> = |_| AtomicUsize::new(NONE);

/// Whether the latest exit connection went over the disguised address.
static DISGUISED: CtxField<std::sync::atomic::AtomicBool> =
    |_| std::sync::atomic::AtomicBool::new(false);
/// How long direct gets before the disguised address joins in (automatic).
const DISGUISE_AFTER: Duration = Duration::from_secs(4);

/// "direct" or "disguised": how this device reached its exit last.
pub fn link(ctx: &AnyCtx<Config>) -> &'static str {
    if ctx.get(DISGUISED).load(Ordering::SeqCst) {
        "disguised"
    } else {
        "direct"
    }
}

/// The exit list learnt from the exits' reports (empty until one arrives).
static LEARNT: CtxField<RwLock<Vec<KestrelExit>>> = |_| RwLock::new(Vec::new());

/// This device's exits: what it was configured with, plus any learnt since.
fn exit_list(ctx: &AnyCtx<Config>) -> Vec<KestrelExit> {
    let learnt = ctx.get(LEARNT).read().unwrap();
    if !learnt.is_empty() {
        return learnt.clone();
    }
    ctx.init()
        .kestrel_device
        .as_ref()
        .map(|d| d.exits.clone())
        .unwrap_or_default()
}

/// The exits this device may use, with their index in its exit list. None
/// when it has no exit list (it then uses `exit_constraint`, as before).
pub fn candidates(ctx: &AnyCtx<Config>) -> Option<Vec<(usize, KestrelExit)>> {
    let device = ctx.init().kestrel_device.as_ref()?;
    if ctx.init().broker.is_some() {
        return None;
    }
    let list = exit_list(ctx);
    if list.is_empty() {
        return None;
    }
    let all: Vec<(usize, KestrelExit)> = list.into_iter().enumerate().collect();
    let pinned: Vec<(usize, KestrelExit)> = match &device.exit_choice {
        Some(city) => all
            .iter()
            .filter(|(_, e)| e.city.eq_ignore_ascii_case(city))
            .cloned()
            .collect(),
        None => vec![],
    };
    // a pin to a city this device doesn't know means automatic
    Some(if pinned.is_empty() { all } else { pinned })
}

/// Whether an exit list entry is well formed: "host:port", a 32-byte key in
/// hex and a short city name.
fn well_formed(e: &KestrelExit) -> bool {
    e.endpoint.rsplit_once(':').is_some_and(|(h, p)| !h.is_empty() && p.parse::<u16>().is_ok())
        && e.pubkey.len() == 64
        && e.pubkey.chars().all(|c| c.is_ascii_hexdigit())
        && !e.city.is_empty()
        && e.city.len() <= 40
}

/// The configured or learnt list with `told`'s new exits appended (by key) and
/// known exits' disguised addresses brought up to date, or None if `told`
/// changes nothing.
fn merged(current: &[KestrelExit], told: &[KestrelExit]) -> Option<Vec<KestrelExit>> {
    let mut next = current.to_vec();
    for e in told.iter().filter(|e| well_formed(e)) {
        match next.iter_mut().find(|c| c.pubkey.eq_ignore_ascii_case(&e.pubkey)) {
            Some(known) => {
                if e.disguise.is_some() {
                    known.disguise.clone_from(&e.disguise);
                }
            }
            None => next.push(e.clone()),
        }
    }
    (next != current).then_some(next)
}

/// Takes the exit list an exit reported (it came through our own tunnel, so it
/// is ours). A device that had no list moves its sessions onto the list; an
/// automatic device races the exits once and moves if another is faster.
pub fn learn(ctx: &AnyCtx<Config>, told: &serde_json::Value) {
    if ctx.init().kestrel_device.is_none() || ctx.init().broker.is_some() {
        return;
    }
    let Ok(told) = serde_json::from_value::<Vec<KestrelExit>>(told.clone()) else {
        return;
    };
    let current = exit_list(ctx);
    let Some(next) = merged(&current, &told) else {
        return;
    };
    let added = next.len() > current.len();
    tracing::info!(
        exits = debug(next.iter().map(|e| e.city.as_str()).collect::<Vec<_>>()),
        "learnt the owner's exits"
    );
    *ctx.get(LEARNT).write().unwrap() = next;
    if current.is_empty() {
        // sessions from before had no exit list: start over on it
        crate::session::close_sessions_without_exit(ctx);
    } else if added {
        let ctx = ctx.clone();
        tokio::spawn(async move {
            if let Err(err) = reconsider(&ctx).await {
                tracing::debug!(err = debug(err), "could not compare the exits");
            }
        });
    }
}

/// Races every exit (automatic mode) and moves to the winner if it isn't the
/// exit in use.
async fn reconsider(ctx: &AnyCtx<Config>) -> anyhow::Result<()> {
    let exits = candidates(ctx).context("no exits")?;
    if exits.len() < 2 {
        return Ok(());
    }
    let mut racing: FuturesUnordered<_> =
        exits.into_iter().map(|(i, e)| attempt(ctx, i, e)).collect();
    let mut winner = None;
    while let Some(r) = racing.next().await {
        if let Ok((_, descriptor, idx)) = r {
            winner = Some((idx, descriptor.city));
            break;
        }
    }
    let (idx, city) = winner.context("no exit answered")?;
    let slot = ctx.get(ACTIVE);
    let now = slot.load(Ordering::SeqCst);
    if now != NONE && now != idx && slot.compare_exchange(now, idx, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
        tracing::info!(exit = city.as_str(), "moving to the faster exit");
    }
    Ok(())
}

/// The index of the exit in use, if one has been chosen.
pub fn active(ctx: &AnyCtx<Config>) -> Option<usize> {
    let i = ctx.get(ACTIVE).load(Ordering::SeqCst);
    (i != NONE).then_some(i)
}

/// Returns once the exit in use is no longer `idx`.
pub async fn until_switched_from(ctx: &AnyCtx<Config>, idx: usize) {
    while ctx.get(ACTIVE).load(Ordering::SeqCst) == idx {
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

type Connected = (Box<dyn Pipe>, ExitDescriptor, usize);

/// Dials an exit directly, over its disguised address, or both: in automatic
/// mode the disguised address joins after `DISGUISE_AFTER` (at once if it was
/// what worked last), and the first link up wins.
async fn dial_link(
    ctx: &AnyCtx<Config>,
    exit: &KestrelExit,
) -> anyhow::Result<(ed25519_dalek::VerifyingKey, ExitDescriptor, Box<dyn Pipe>, bool)> {
    let device = ctx.init().kestrel_device.as_ref().context("not a Kestrel device")?;
    let (pubkey, descriptor, direct) =
        direct_dialer(ctx, &exit.endpoint, &exit.pubkey, &exit.city).await?;
    // the disguise carries the stealth link only
    let disguise = exit.disguise.as_deref().filter(|_| device.stealth);
    let mode = device.link.as_deref().unwrap_or("auto");
    let Some(url) = disguise.filter(|_| mode != "direct") else {
        anyhow::ensure!(mode != "disguised", "the {} exit has no disguised address", exit.city);
        let pipe = direct.dial().await.context("could not dial")?;
        return Ok((pubkey, descriptor, pipe, false));
    };
    let disguised = disguised_dialer(url, &pubkey);
    if mode == "disguised" {
        let pipe = disguised.dial().await.context("could not dial the disguised address")?;
        return Ok((pubkey, descriptor, pipe, true));
    }
    let wait = if ctx.get(DISGUISED).load(Ordering::SeqCst) {
        Duration::ZERO
    } else {
        DISGUISE_AFTER
    };
    let direct = async { direct.dial().await.map(|p| (p, false)) };
    let disguised = async {
        tokio::time::sleep(wait).await;
        disguised.dial().await.map(|p| (p, true))
    };
    let (pipe, was_disguised) = futures_util::future::select_ok([
        Box::pin(direct) as std::pin::Pin<Box<dyn std::future::Future<Output = _> + Send>>,
        Box::pin(disguised),
    ])
    .await
    .context("could not dial directly or disguised")?
    .0;
    Ok((pubkey, descriptor, pipe, was_disguised))
}

async fn attempt(ctx: &AnyCtx<Config>, idx: usize, exit: KestrelExit) -> anyhow::Result<Connected> {
    async {
        let (pubkey, descriptor, pipe, disguised) = dial_link(ctx, &exit).await?;
        let authed = client_auth(ctx, pipe, pubkey)
            .await
            .context("could not client auth")?;
        ctx.get(DISGUISED).store(disguised, Ordering::SeqCst);
        anyhow::Ok((Box::new(authed) as Box<dyn Pipe>, descriptor, idx))
    }
    .timeout(ATTEMPT)
    .await
    .with_context(|| format!("{} did not answer in time", exit.city))?
    .with_context(|| format!("could not reach the {} exit", exit.city))
}

/// Connects one session to the exit in use, or (automatic mode) to whichever
/// exit answers first if none is in use or it has stopped answering.
pub async fn connect(
    ctx: &AnyCtx<Config>,
    exits: Vec<(usize, KestrelExit)>,
) -> anyhow::Result<Connected> {
    anyhow::ensure!(!exits.is_empty(), "no exits");
    let current = active(ctx).filter(|a| exits.iter().any(|(i, _)| i == a));
    let (first, rest): (Vec<_>, Vec<_>) = exits
        .into_iter()
        .partition(|(i, _)| current.is_none() || Some(*i) == current);

    let mut racing = FuturesUnordered::new();
    for (i, e) in first {
        racing.push(attempt(ctx, i, e));
    }
    let mut waiting = rest;
    let mut errors = Vec::new();
    let head_start = tokio::time::sleep(HEAD_START);
    tokio::pin!(head_start);
    let won = loop {
        tokio::select! {
            r = racing.next(), if !racing.is_empty() => match r {
                Some(Ok(v)) => break v,
                Some(Err(e)) => {
                    errors.push(format!("{e:#}"));
                    // the active exit failed outright: don't wait out its head start
                    if racing.is_empty() {
                        for (i, e) in waiting.drain(..) {
                            racing.push(attempt(ctx, i, e));
                        }
                        if racing.is_empty() {
                            anyhow::bail!("no exit answered: {}", errors.join("; "));
                        }
                    }
                }
                None => unreachable!(),
            },
            _ = &mut head_start, if !waiting.is_empty() => {
                for (i, e) in waiting.drain(..) {
                    racing.push(attempt(ctx, i, e));
                }
            }
        }
    };

    // all sessions use one exit: the first choice sticks, a failover moves it
    let idx = won.2;
    let slot = ctx.get(ACTIVE);
    let before = current.unwrap_or(NONE);
    match slot.compare_exchange(before, idx, Ordering::SeqCst, Ordering::SeqCst) {
        Ok(_) if before != idx => {
            tracing::info!(exit = won.1.city.as_str(), "using this exit");
        }
        Ok(_) => {}
        Err(now) if now == idx => {}
        Err(_) => anyhow::bail!("another session moved to a different exit"),
    }
    Ok(won)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exit(city: &str, key: char) -> KestrelExit {
        KestrelExit {
            endpoint: format!("{}.example:443", city.to_lowercase()),
            pubkey: key.to_string().repeat(64),
            city: city.into(),
            disguise: None,
        }
    }

    #[test]
    fn learnt_exits_are_appended_so_indexes_stay_put() {
        let frankfurt = exit("Frankfurt", 'a');
        let chicago = exit("Chicago", 'b');
        let next = merged(&[frankfurt.clone()], &[chicago.clone(), frankfurt.clone()]).unwrap();
        assert_eq!(next, [frankfurt.clone(), chicago.clone()]);
        // nothing new: nothing to do
        assert!(merged(&next, &[chicago.clone()]).is_none());
        // a device with no list takes the whole list
        assert_eq!(merged(&[], &[chicago.clone()]).unwrap(), [chicago.clone()]);
        // a known exit that gains a disguised address gets it, in place
        let mut disguised = chicago.clone();
        disguised.disguise = Some("wss://edge.example.dev/k/abc".into());
        let next2 = merged(&next, &[disguised.clone()]).unwrap();
        assert_eq!(next2, [frankfurt, disguised]);
    }

    #[test]
    fn malformed_exits_are_ignored() {
        let mut bad_key = exit("Chicago", 'b');
        bad_key.pubkey = "zz".repeat(32);
        let mut no_port = exit("Chicago", 'c');
        no_port.endpoint = "chicago.example".into();
        let mut short_key = exit("Chicago", 'd');
        short_key.pubkey = "ab".into();
        let mut no_city = exit("", 'e');
        no_city.city.clear();
        assert!(merged(&[exit("Frankfurt", 'a')], &[bad_key, no_port, short_key, no_city]).is_none());
    }
}

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

use std::{
    sync::atomic::{AtomicUsize, Ordering},
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
    get_dialer::direct_dialer,
    session::client_auth,
};

const NONE: usize = usize::MAX;
/// How long the active exit gets before the others race it.
const HEAD_START: Duration = Duration::from_secs(3);
/// The most one attempt (dial and handshake) at one exit may take.
const ATTEMPT: Duration = Duration::from_secs(10);

static ACTIVE: CtxField<AtomicUsize> = |_| AtomicUsize::new(NONE);

/// The exits this device may use, with their index in its exit list. None
/// when it has no exit list (it then uses `exit_constraint`, as before).
pub fn candidates(ctx: &AnyCtx<Config>) -> Option<Vec<(usize, KestrelExit)>> {
    let device = ctx.init().kestrel_device.as_ref()?;
    if device.exits.is_empty() || ctx.init().broker.is_some() {
        return None;
    }
    let all: Vec<(usize, KestrelExit)> = device.exits.iter().cloned().enumerate().collect();
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

async fn attempt(ctx: &AnyCtx<Config>, idx: usize, exit: KestrelExit) -> anyhow::Result<Connected> {
    async {
        let (pubkey, descriptor, dialer) =
            direct_dialer(ctx, &exit.endpoint, &exit.pubkey, &exit.city).await?;
        let pipe = dialer.dial().await.context("could not dial")?;
        let authed = client_auth(ctx, pipe, pubkey)
            .await
            .context("could not client auth")?;
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

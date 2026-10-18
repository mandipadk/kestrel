//! Kestrel stealth link: one port serves both stealth (sosistab3) and plain
//! (ConnTest) devices.
//!
//! The first bytes of a connection decide which it is. A sosistab3 client
//! opens with a 140-byte handshake sealed with the cookie only devices can
//! derive; a plain client opens with a ConnTest ping (a 2-byte length below
//! 1000, then that many bytes) and waits for the echo. Anything else is held
//! open for a while and dropped without a reply, as sosistab3 itself does, so
//! a prober learns nothing. With `allow_plain` off, plain pings get the same
//! silence instead of an echo.

use std::{
    collections::VecDeque,
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};

use async_trait::async_trait;
use futures_concurrency::future::Race;
use sillad::{
    EitherPipe, Pipe,
    listener::Listener,
    tcp::{TcpListener, TcpPipe},
};
use sillad_sosistab3::{Cookie, SosistabPipe, is_client_handshake, listener::SosistabListener};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};

const HANDSHAKE_LEN: usize = 140;
/// ConnTest pings are 1..1000 bytes long.
const MAX_PING: u16 = 1000;
/// How long a plain client may take to finish its pings.
const SNIFF_TIMEOUT: Duration = Duration::from_secs(10);
/// After a short ping, how long to wait for more bytes before deciding the
/// peer is a plain client waiting for its echo.
const SETTLE: Duration = Duration::from_millis(400);

/// What a connection turned out to be.
#[derive(Debug, PartialEq, Eq)]
enum Sniffed {
    /// A sosistab3 handshake; these bytes were consumed and must be replayed.
    Stealth(Vec<u8>),
    /// A ConnTest ping of this payload; echo it and carry on with ConnTest.
    Plain(Vec<u8>),
    Junk,
}

async fn sniff(conn: &mut (impl AsyncRead + Unpin), cookie: Cookie) -> io::Result<Sniffed> {
    let mut buf = vec![0u8; 2];
    conn.read_exact(&mut buf).await?;
    let size = u16::from_be_bytes([buf[0], buf[1]]);
    if size == 0 || size >= MAX_PING {
        // cannot be a ping: only a handshake is left
        buf.resize(HANDSHAKE_LEN, 0);
        conn.read_exact(&mut buf[2..]).await?;
        return Ok(if matches_handshake(&buf, cookie) {
            Sniffed::Stealth(buf)
        } else {
            Sniffed::Junk
        });
    }
    let ping_end = 2 + size as usize;
    if ping_end >= HANDSHAKE_LEN {
        // Check for a handshake before reading the whole "ping": a stealth
        // client may have sent fewer bytes than this length claims.
        buf.resize(HANDSHAKE_LEN, 0);
        conn.read_exact(&mut buf[2..]).await?;
        if matches_handshake(&buf, cookie) {
            return Ok(Sniffed::Stealth(buf));
        }
        buf.resize(ping_end, 0);
        conn.read_exact(&mut buf[HANDSHAKE_LEN..]).await?;
        return Ok(Sniffed::Plain(buf.split_off(2)));
    }
    buf.resize(ping_end, 0);
    conn.read_exact(&mut buf[2..]).await?;
    // A plain client now waits for its echo; a stealth client keeps
        // sending the rest of its handshake.
        let have = buf.len();
        buf.resize(HANDSHAKE_LEN, 0);
        let mut got = 0;
        let more = tokio::time::timeout(SETTLE, async {
            while have + got < HANDSHAKE_LEN {
                let n = conn.read(&mut buf[have + got..]).await?;
                if n == 0 {
                    break;
                }
                got += n;
            }
            io::Result::Ok(())
        })
        .await;
        if got == 0 {
            if let Ok(Err(err)) = more {
                return Err(err);
            }
            buf.truncate(have);
            return Ok(Sniffed::Plain(buf.split_off(2)));
        }
    if have + got == HANDSHAKE_LEN && matches_handshake(&buf, cookie) {
        return Ok(Sniffed::Stealth(buf));
    }
    Ok(Sniffed::Junk)
}

fn matches_handshake(buf: &[u8], cookie: Cookie) -> bool {
    buf.get(..HANDSHAKE_LEN)
        .and_then(|b| <&[u8; HANDSHAKE_LEN]>::try_from(b).ok())
        .is_some_and(|b| is_client_handshake(cookie, b))
}

/// Finishes the ConnTest exchange for a plain client whose first ping was
/// already read.
async fn finish_conntest(conn: &mut TcpPipe, first: Vec<u8>) -> io::Result<()> {
    conn.write_all(&first).await?;
    loop {
        let mut size = [0u8; 2];
        conn.read_exact(&mut size).await?;
        let size = u16::from_be_bytes(size);
        if size == 0 {
            return Ok(());
        }
        let mut payload = vec![0u8; size as usize];
        conn.read_exact(&mut payload).await?;
        conn.write_all(&payload).await?;
    }
}

/// Holds a connection we will not serve, then lets it go without a word.
async fn hold_and_drop(conn: TcpPipe) {
    let secs = 10.0 + rand::random::<f64>() * 10.0;
    let mut conn = conn;
    let mut sink = [0u8; 1024];
    let _ = tokio::time::timeout(Duration::from_secs_f64(secs), async {
        while conn.read(&mut sink).await.unwrap_or(0) > 0 {}
    })
    .await;
}

pub type KestrelPipe = EitherPipe<TcpPipe, SosistabPipe<PrefixPipe>>;

/// Accepts plain and stealth connections on one TCP port.
pub struct KestrelListener {
    plain: tachyonix::Receiver<TcpPipe>,
    stealth: SosistabListener<PrefixPipe>,
    _task: geph5_rt::Task<()>,
}

impl KestrelListener {
    pub async fn bind(addr: SocketAddr, cookie: Cookie, allow_plain: bool) -> io::Result<Self> {
        let mut tcp = TcpListener::bind(addr).await?;
        let (send_plain, plain) = tachyonix::channel(100);
        let (send_stealth, recv_stealth) = tachyonix::channel(100);
        let task = geph5_rt::spawn(async move {
            loop {
                let mut conn = match tcp.accept().await {
                    Ok(conn) => conn,
                    Err(err) => {
                        tracing::warn!(err = debug(err), "error accepting");
                        tokio::time::sleep(Duration::from_secs(1)).await;
                        continue;
                    }
                };
                let ip = peer_ip(&conn);
                if ip.is_some_and(super::is_banned) {
                    continue;
                }
                let send_plain = send_plain.clone();
                let send_stealth = send_stealth.clone();
                geph5_rt::spawn(async move {
                    let sniffed = tokio::time::timeout(SNIFF_TIMEOUT, sniff(&mut conn, cookie))
                        .await
                        .unwrap_or_else(|_| Err(io::ErrorKind::TimedOut.into()));
                    match sniffed {
                        Ok(Sniffed::Stealth(prefix)) => {
                            let _ = send_stealth.send(PrefixPipe::new(conn, prefix)).await;
                        }
                        Ok(Sniffed::Plain(first)) if allow_plain => {
                            let finished =
                                tokio::time::timeout(SNIFF_TIMEOUT, finish_conntest(&mut conn, first))
                                    .await;
                            if matches!(finished, Ok(Ok(()))) {
                                let _ = send_plain.send(conn).await;
                            }
                        }
                        Ok(_) => {
                            if let Some(ip) = ip {
                                super::record_failure(ip);
                            }
                            hold_and_drop(conn).await;
                        }
                        Err(_) => {
                            if let Some(ip) = ip {
                                super::record_failure(ip);
                            }
                        }
                    }
                })
                .detach();
            }
        });
        Ok(Self {
            plain,
            stealth: SosistabListener::new(ChanListener(recv_stealth), cookie),
            _task: task,
        })
    }
}

fn peer_ip(pipe: &impl Pipe) -> Option<IpAddr> {
    pipe.remote_addr()
        .and_then(|a| a.parse::<SocketAddr>().ok())
        .map(|a| a.ip())
}

#[async_trait]
impl Listener for KestrelListener {
    type P = KestrelPipe;

    async fn accept(&mut self) -> io::Result<Self::P> {
        let plain = &mut self.plain;
        let stealth = &mut self.stealth;
        (
            async {
                plain
                    .recv()
                    .await
                    .map(EitherPipe::Left)
                    .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "listener stopped"))
            },
            async { stealth.accept().await.map(EitherPipe::Right) },
        )
            .race()
            .await
    }
}

/// A listener fed by a channel.
struct ChanListener(tachyonix::Receiver<PrefixPipe>);

#[async_trait]
impl Listener for ChanListener {
    type P = PrefixPipe;

    async fn accept(&mut self) -> io::Result<PrefixPipe> {
        self.0
            .recv()
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "listener stopped"))
    }
}

/// A TCP connection that first gives back the bytes the sniffer read.
pub struct PrefixPipe {
    prefix: VecDeque<u8>,
    inner: TcpPipe,
}

impl PrefixPipe {
    fn new(inner: TcpPipe, prefix: Vec<u8>) -> Self {
        Self {
            prefix: prefix.into(),
            inner,
        }
    }
}

impl AsyncRead for PrefixPipe {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if !self.prefix.is_empty() {
            let n = buf.remaining().min(self.prefix.len());
            let bytes: Vec<u8> = self.prefix.drain(..n).collect();
            buf.put_slice(&bytes);
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for PrefixPipe {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

impl Pipe for PrefixPipe {
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

    fn cookie() -> Cookie {
        Cookie::new(&geph5_misc_rpc::kestrel::stealth_cookie(&[7; 32]))
    }

    /// The opening bytes of a real sosistab3 client handshake: run its dialer
    /// against one end of an in-memory pipe and keep what it sends.
    async fn real_handshake(cookie: Cookie) -> Vec<u8> {
        use sillad::dialer::Dialer;
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let dialer = sillad_sosistab3::dialer::SosistabDialer {
            inner: OnceDialer(std::sync::Mutex::new(Some(client))),
            cookie,
        };
        let _dial = geph5_rt::spawn(async move { dialer.dial().await.map(|_| ()) });
        let mut out = vec![0u8; HANDSHAKE_LEN];
        server.read_exact(&mut out).await.unwrap();
        out
    }

    struct OnceDialer(std::sync::Mutex<Option<tokio::io::DuplexStream>>);

    #[async_trait]
    impl sillad::dialer::Dialer for OnceDialer {
        type P = DuplexPipe;
        async fn dial(&self) -> io::Result<DuplexPipe> {
            Ok(DuplexPipe(self.0.lock().unwrap().take().unwrap()))
        }
    }

    struct DuplexPipe(tokio::io::DuplexStream);

    impl AsyncRead for DuplexPipe {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_read(cx, buf)
        }
    }

    impl AsyncWrite for DuplexPipe {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            Pin::new(&mut self.0).poll_write(cx, buf)
        }
        fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_flush(cx)
        }
        fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_shutdown(cx)
        }
    }

    impl Pipe for DuplexPipe {
        fn protocol(&self) -> &str {
            "duplex"
        }
        fn remote_addr(&self) -> Option<&str> {
            None
        }
    }

    async fn sniff_bytes(bytes: Vec<u8>, keep_open: bool) -> Sniffed {
        let (mut a, mut b) = tokio::io::duplex(1 << 16);
        a.write_all(&bytes).await.unwrap();
        if !keep_open {
            drop(a);
            return sniff(&mut b, cookie()).await.unwrap_or(Sniffed::Junk);
        }
        let res = sniff(&mut b, cookie()).await.unwrap_or(Sniffed::Junk);
        drop(a);
        res
    }

    #[test]
    fn stealth_handshakes_are_recognized() {
        geph5_rt::block_on(async {
            for _ in 0..200 {
                let hs = real_handshake(cookie()).await;
                match sniff_bytes(hs.clone(), true).await {
                    Sniffed::Stealth(prefix) => assert_eq!(prefix, hs),
                    other => panic!("handshake sniffed as {other:?}"),
                }
            }
        })
    }

    #[test]
    fn other_cookies_are_junk_or_plain_never_stealth() {
        geph5_rt::block_on(async {
            let wrong = Cookie::new(&geph5_misc_rpc::kestrel::stealth_cookie(&[8; 32]));
            for _ in 0..200 {
                let hs = real_handshake(wrong).await;
                assert!(!matches!(sniff_bytes(hs, true).await, Sniffed::Stealth(_)));
            }
        })
    }

    #[test]
    fn plain_pings_of_every_size_are_plain() {
        geph5_rt::block_on(async {
            for size in [1u16, 2, 50, 137, 138, 139, 500, 999] {
                let mut ping = size.to_be_bytes().to_vec();
                ping.extend((0..size).map(|i| i as u8));
                match sniff_bytes(ping, true).await {
                    Sniffed::Plain(payload) => assert_eq!(payload.len(), size as usize),
                    other => panic!("ping of {size} sniffed as {other:?}"),
                }
            }
        })
    }

    #[test]
    fn random_bytes_are_never_stealth() {
        geph5_rt::block_on(async {
            for _ in 0..300 {
                let junk: Vec<u8> = (0..HANDSHAKE_LEN + 60).map(|_| rand::random()).collect();
                assert!(!matches!(
                    sniff_bytes(junk, false).await,
                    Sniffed::Stealth(_)
                ));
            }
        })
    }

    #[test]
    fn prefix_pipe_replays_then_reads_on() {
        geph5_rt::block_on(async {
            let listener = TcpListener::bind("127.0.0.1:0".parse().unwrap()).await.unwrap();
            let mut listener = listener;
            let addr = listener.local_addr().await;
            let client = geph5_rt::spawn(async move {
                let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
                s.write_all(b"world").await.unwrap();
                s
            });
            let conn = listener.accept().await.unwrap();
            let _client = client.await;
            let mut pipe = PrefixPipe::new(conn, b"hello ".to_vec());
            let mut out = vec![0u8; 11];
            pipe.read_exact(&mut out).await.unwrap();
            assert_eq!(&out, b"hello world");
        })
    }
}

//! Kestrel: the disguised link. On networks that block the exits' addresses
//! or random-looking traffic, the device reaches its exit inside an ordinary
//! HTTPS WebSocket to a site on the owner's Cloudflare zone, which hands the
//! bytes to the exit. Inside runs the same stealth link and handshake as
//! always, so the site and Cloudflare see only ciphertext, and the exit still
//! checks the device key.
//!
//! The WebSocket sends a ping every 20 seconds: Cloudflare closes WebSockets
//! that stay quiet for 100.

use std::{io, sync::Arc, time::Duration};

use async_trait::async_trait;
use futures_util::{SinkExt, StreamExt};
use sillad::{Pipe, dialer::Dialer};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio_rustls::rustls::{self, pki_types::ServerName};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest, http::HeaderValue};

trait Duplex: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> Duplex for T {}

const PING_EVERY: Duration = Duration::from_secs(20);
/// Bytes buffered between the engine and the WebSocket in each direction.
const BUFFER: usize = 256 * 1024;

/// Dials `wss://host[:port]/path` (or `ws://127.0.0.1:port/path`, for tests).
pub struct DisguiseDialer {
    pub url: String,
}

/// Splits a `wss://` URL into its host, port and path, or None if it is
/// anything else. Plain `ws://` only to this machine's loopback (tests).
pub fn parse_url(url: &str) -> Option<(String, u16, String)> {
    let (rest, tls) = match url.strip_prefix("wss://") {
        Some(rest) => (rest, true),
        None => (url.strip_prefix("ws://127.0.0.1:")?, false),
    };
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match (tls, authority.rsplit_once(':')) {
        (true, Some((h, p))) => (h, p.parse().ok()?),
        (true, None) => (authority, 443),
        (false, _) => ("127.0.0.1", authority.parse().ok()?),
    };
    let ok_host = !host.is_empty()
        && host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.');
    let ok_path = path
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "/-_.~".contains(c));
    (ok_host && ok_path).then(|| (host.to_ascii_lowercase(), port, path.to_string()))
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: std::sync::LazyLock<Arc<rustls::ClientConfig>> =
        std::sync::LazyLock::new(|| {
            let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let mut cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .expect("TLS versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
            cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
            Arc::new(cfg)
        });
    CONFIG.clone()
}

#[async_trait]
impl Dialer for DisguiseDialer {
    type P = DisguisePipe;

    async fn dial(&self) -> io::Result<DisguisePipe> {
        let bad = |e: String| io::Error::new(io::ErrorKind::InvalidInput, e);
        let (host, port, _) = parse_url(&self.url).ok_or_else(|| bad("not a wss:// address".into()))?;
        let addr = tokio::net::lookup_host((host.as_str(), port))
            .await?
            .next()
            .ok_or_else(|| bad(format!("{host} has no address")))?;
        let tcp = tokio::net::TcpStream::connect(addr).await?;
        tcp.set_nodelay(true)?;
        let stream: Box<dyn Duplex> = if self.url.starts_with("wss://") {
            let name = ServerName::try_from(host.clone()).map_err(|e| bad(e.to_string()))?;
            Box::new(
                tokio_rustls::TlsConnector::from(tls_config())
                    .connect(name, tcp)
                    .await?,
            )
        } else {
            Box::new(tcp)
        };
        let mut request = self
            .url
            .as_str()
            .into_client_request()
            .map_err(|e| bad(e.to_string()))?;
        request.headers_mut().insert(
            "User-Agent",
            HeaderValue::from_static("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"),
        );
        let (ws, _) = tokio_tungstenite::client_async(request, stream)
            .await
            .map_err(|e| io::Error::new(io::ErrorKind::ConnectionRefused, e.to_string()))?;
        let (ours, theirs) = tokio::io::duplex(BUFFER);
        tokio::spawn(pump(ws, theirs));
        Ok(DisguisePipe {
            inner: ours,
            remote: addr.to_string(),
        })
    }
}

/// Moves bytes between the engine's end of the pipe and the WebSocket until
/// either side closes.
async fn pump<S>(ws: tokio_tungstenite::WebSocketStream<S>, pipe: DuplexStream)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let (mut sink, mut stream) = ws.split();
    let (mut from_engine, mut to_engine) = tokio::io::split(pipe);
    let mut buf = vec![0u8; 32 * 1024];
    let mut ping = tokio::time::interval(PING_EVERY);
    ping.tick().await;
    loop {
        tokio::select! {
            n = from_engine.read(&mut buf) => match n {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if sink.send(Message::Binary(buf[..n].to_vec().into())).await.is_err() {
                        break;
                    }
                }
            },
            msg = stream.next() => match msg {
                Some(Ok(Message::Binary(data))) => {
                    if to_engine.write_all(&data).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                // pings are answered by the library; text and pongs mean nothing here
                Some(Ok(_)) => {}
            },
            _ = ping.tick() => {
                if sink.send(Message::Ping(Vec::new().into())).await.is_err() {
                    break;
                }
            }
        }
    }
    let _ = sink.close().await;
    let _ = to_engine.shutdown().await;
}

pub struct DisguisePipe {
    inner: DuplexStream,
    remote: String,
}

impl tokio::io::AsyncRead for DisguisePipe {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl tokio::io::AsyncWrite for DisguisePipe {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        std::pin::Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

impl Pipe for DisguisePipe {
    fn protocol(&self) -> &str {
        "kestrel-disguise"
    }

    /// The Cloudflare address it reached (the session code wants an address).
    fn remote_addr(&self) -> Option<&str> {
        Some(&self.remote)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_wss_addresses_with_plain_hosts_and_paths() {
        assert_eq!(
            parse_url("wss://edge.example.dev/k/abc-123"),
            Some(("edge.example.dev".into(), 443, "/k/abc-123".into()))
        );
        assert_eq!(
            parse_url("wss://Edge.example.dev:8443"),
            Some(("edge.example.dev".into(), 8443, "/".into()))
        );
        assert_eq!(
            parse_url("ws://127.0.0.1:8790/k/abc"),
            Some(("127.0.0.1".into(), 8790, "/k/abc".into()))
        );
        for bad in [
            "ws://edge.example.dev/k",
            "ws://localhost:8790/k",
            "ws://127.0.0.1/k",
            "https://edge.example.dev/k",
            "wss:///k",
            "wss://edge.example.dev:x/k",
            "wss://user@edge.example.dev/k",
            "wss://edge.example.dev/k?x=1",
        ] {
            assert!(parse_url(bad).is_none(), "{bad}");
        }
    }
}

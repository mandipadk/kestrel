// Kestrel edge: the server end of the disguised link.
//
// Cloudflare forwards https://<name>.mandip.dev here. One secret path upgrades
// to a WebSocket, and its bytes go to this server's own Kestrel exit
// (127.0.0.1:443) and nowhere else: the exit still checks the device key, so
// this relays nothing for anyone without one. Everything else gets a 404.
//
// The exit sees these connections from loopback, so its per-address limits
// can't tell visitors apart; this does it by the visitor's real address
// (Cloudflare's CF-Connecting-IP): at most 30 new links a minute each and 600
// in all, 200 open at once.
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 8790);
const EXIT = { host: "127.0.0.1", port: Number(process.env.KESTREL_EXIT_PORT || 443) };
const PATH_FILE = process.env.KESTREL_EDGE_PATH_FILE || `${os.homedir()}/.config/kestrel/edge-path`;
const SECRET_PATH = fs.readFileSync(PATH_FILE, "utf8").trim();
if (!/^\/[A-Za-z0-9_-]{16,}$/.test(SECRET_PATH)) throw new Error(`bad path in ${PATH_FILE}`);

const PER_IP_PER_MIN = 30;
const ALL_PER_MIN = 600;
const MAX_OPEN = 200;
const HIGH_WATER = 4 * 1024 * 1024;

let minute = 0, total = 0, open = 0, served = 0, refused = 0;
const perIp = new Map();
function allowed(ip) {
  const now = Math.floor(Date.now() / 60000);
  if (now !== minute) { minute = now; total = 0; perIp.clear(); }
  const n = (perIp.get(ip) || 0) + 1;
  perIp.set(ip, n);
  total += 1;
  return n <= PER_IP_PER_MIN && total <= ALL_PER_MIN && open < MAX_OPEN;
}

function notFound(res) {
  res.writeHead(404, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
  res.end("Not found\n");
}

const server = http.createServer((req, res) => notFound(res));
const wss = new WebSocketServer({ noServer: true, maxPayload: 1 << 20, perMessageDeflate: false });

server.on("upgrade", (req, socket, head) => {
  const ip = String(req.headers["cf-connecting-ip"] || req.socket.remoteAddress || "?");
  if (req.url !== SECRET_PATH || !allowed(ip)) {
    refused += 1;
    socket.end("HTTP/1.1 404 Not Found\r\ncontent-type: text/plain\r\ncontent-length: 10\r\nconnection: close\r\n\r\nNot found\n");
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => bridge(ws));
});

function bridge(ws) {
  open += 1; served += 1;
  const tcp = net.connect(EXIT);
  tcp.setNoDelay(true);
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true; open -= 1;
    tcp.destroy();
    ws.terminate();
  };
  ws.on("message", (data, isBinary) => {
    if (!isBinary) return close();
    if (!tcp.write(data)) ws._socket.pause();
  });
  tcp.on("drain", () => ws._socket.resume());
  tcp.on("data", (chunk) => {
    ws.send(chunk, { binary: true });
    if (ws.bufferedAmount > HIGH_WATER) {
      tcp.pause();
      const wait = setInterval(() => {
        if (closed || ws.bufferedAmount < HIGH_WATER / 4) { clearInterval(wait); tcp.resume(); }
      }, 20);
    }
  });
  ws.on("close", close);
  ws.on("error", close);
  tcp.on("close", close);
  tcp.on("error", close);
}

// one line a minute when something happened, counts only (no addresses)
setInterval(() => {
  if (served || refused) console.log(`edge: ${served} links, ${refused} refused, ${open} open`);
  served = 0; refused = 0;
}, 60000).unref();

server.listen(PORT, "127.0.0.1", () => console.log(`kestrel edge on 127.0.0.1:${PORT}`));

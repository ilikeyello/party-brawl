// Party Brawl relay + matchmaking server.
//  - Serves the web build from ./public (export the Godot "Web" preset there)
//  - WebSocket endpoint /ws relays game packets between players in a room
//  - Quick Play: puts players into open public rooms (up to 5 humans)
//  - Private rooms: 4-letter room codes
//
// Protocol (mirrors scripts/net/relay_peer.gd):
//   text frames = JSON control messages
//     client -> server: {t:"quick",name} | {t:"host",name} | {t:"join",code,name} | {t:"lock"} | {t:"unlock"} | {t:"kick",id}
//     server -> client: {t:"welcome",id,code,host,quick} | {t:"peer_joined",id} | {t:"peer_left",id}
//                       {t:"room_closed",reason} | {t:"error",msg}
//   binary frames = game packets
//     up:   int32LE target (0 = all others, >0 = that peer, <0 = all except -target) + payload
//     down: int32LE sender id + payload

const http = require("http");
const fs = require("fs");
const path = require("path");
const { WebSocketServer } = require("ws");
const zlib = require("zlib");

const PORT = parseInt(process.env.PORT || "8080", 10);
const PUBLIC_DIR = path.join(__dirname, "public");
const MAX_PLAYERS = 5;
const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no I, O, 0, 1
const MAX_PACKET = 1 << 20;

const rooms = new Map(); // code -> room

// ------------------------------------------------------------------ static files

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
};

const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent((req.url || "/").split("?")[0]);
  if (urlPath === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, rooms: rooms.size, players: countPlayers() }));
    return;
  }
  let file = path.normalize(path.join(PUBLIC_DIR, urlPath === "/" ? startPage() : urlPath));
  if (!file.startsWith(PUBLIC_DIR)) {
    res.writeHead(403);
    res.end();
    return;
  }
  // Our own "network first" service worker (server/sw.js) instead of the one Godot exports,
  // so a normal refresh always gets the newest build (no need to clear website data).
  if (urlPath === "/game.service.worker.js") {
    file = path.join(__dirname, "sw.js");
  }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end(urlPath === "/" ? "Web build not found. Export the Godot Web preset into server/public." : "Not found");
      return;
    }
    const ext = path.extname(file).toLowerCase();
    // Always revalidate, so players get a new build right after a deploy.
    const etag = `"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`;
    if (req.headers["if-none-match"] === etag) {
      res.writeHead(304, { ETag: etag, "Cache-Control": "no-cache" });
      res.end();
      return;
    }
    const headers = {
      "Content-Type": MIME[ext] || "application/octet-stream",
      "Cache-Control": "no-cache",
      ETag: etag,
      // Allows SharedArrayBuffer if a threaded export is ever used; harmless otherwise.
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    };
    const wantsGzip = /\bgzip\b/.test(req.headers["accept-encoding"] || "");
    if (wantsGzip && COMPRESSIBLE.has(ext)) {
      const gz = gzipCached(file, st.mtimeMs);
      if (gz) {
        headers["Content-Encoding"] = "gzip";
        headers["Content-Length"] = gz.length;
        headers["Vary"] = "Accept-Encoding";
        res.writeHead(200, headers);
        res.end(gz);
        return;
      }
    }
    res.writeHead(200, headers);
    fs.createReadStream(file).pipe(res);
  });
});

// The game page: game.html (newer builds) or index.html (older builds).
function startPage() {
  return fs.existsSync(path.join(PUBLIC_DIR, "game.html")) ? "game.html" : "index.html";
}

// The engine .wasm is ~40 MB; gzip makes it ~4x smaller. Compressed once, kept in memory.
const COMPRESSIBLE = new Set([".wasm", ".js", ".pck", ".html"]);
const gzCache = new Map();
function gzipCached(file, mtime) {
  const hit = gzCache.get(file);
  if (hit && hit.mtime === mtime) return hit.data;
  try {
    const data = zlib.gzipSync(fs.readFileSync(file), { level: 6 });
    gzCache.set(file, { mtime, data });
    return data;
  } catch (e) {
    return null;
  }
}

// ------------------------------------------------------------------ rooms

function newCode() {
  for (let tries = 0; tries < 1000; tries++) {
    let c = "";
    for (let i = 0; i < 4; i++) c += CODE_CHARS[Math.floor(Math.random() * CODE_CHARS.length)];
    if (!rooms.has(c)) return c;
  }
  throw new Error("no free room codes");
}

function newPeerId(room) {
  let id;
  do {
    id = 2 + Math.floor(Math.random() * 2147483000);
  } while (room.members.has(id));
  return id;
}

function countPlayers() {
  let n = 0;
  for (const r of rooms.values()) n += r.members.size;
  return n;
}

function sendJson(ws, obj) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

function createRoom(ws, quick) {
  const code = newCode();
  const room = { code, quick, locked: false, members: new Map(), created: Date.now() };
  rooms.set(code, room);
  addToRoom(ws, room, 1);
  return room;
}

function addToRoom(ws, room, id) {
  ws.room = room;
  ws.peerId = id;
  room.members.set(id, ws);
  sendJson(ws, { t: "welcome", id, code: room.code, host: id === 1, quick: room.quick });
  if (id !== 1) {
    const host = room.members.get(1);
    if (host) sendJson(host, { t: "peer_joined", id });
  }
}

function findQuickRoom() {
  let best = null;
  for (const r of rooms.values()) {
    if (!r.quick || r.locked || r.members.size >= MAX_PLAYERS || !r.members.has(1)) continue;
    if (!best || r.created < best.created) best = r;
  }
  return best;
}

function leaveRoom(ws, reason) {
  const room = ws.room;
  if (!room) return;
  room.members.delete(ws.peerId);
  if (ws.peerId === 1) {
    // Host left: close the room for everyone.
    for (const other of room.members.values()) {
      sendJson(other, { t: "room_closed", reason: reason || "The host left the game." });
      other.room = null;
      try { other.close(1000, "room closed"); } catch (e) {}
    }
    rooms.delete(room.code);
  } else {
    const host = room.members.get(1);
    if (host) sendJson(host, { t: "peer_left", id: ws.peerId });
    if (room.members.size === 0) rooms.delete(room.code);
  }
  ws.room = null;
}

// ------------------------------------------------------------------ websocket

const wss = new WebSocketServer({ server, path: "/ws", maxPayload: MAX_PACKET });

wss.on("connection", (ws) => {
  ws.isAlive = true;
  ws.room = null;
  ws.peerId = 0;
  ws.on("pong", () => (ws.isAlive = true));

  ws.on("message", (data, isBinary) => {
    if (!isBinary) {
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch (e) {
        return;
      }
      handleControl(ws, msg);
      return;
    }
    const room = ws.room;
    if (!room || data.length < 4) return;
    const target = data.readInt32LE(0);
    const out = Buffer.allocUnsafe(data.length);
    out.writeInt32LE(ws.peerId, 0);
    data.copy(out, 4, 4);
    if (target > 0) {
      const dest = room.members.get(target);
      if (dest && dest.readyState === dest.OPEN) dest.send(out, { binary: true });
    } else {
      const except = target < 0 ? -target : -1;
      for (const [id, dest] of room.members) {
        if (id === ws.peerId || id === except) continue;
        if (dest.readyState === dest.OPEN) dest.send(out, { binary: true });
      }
    }
  });

  ws.on("close", () => leaveRoom(ws, "The host left the game."));
  ws.on("error", () => {});
});

function handleControl(ws, msg) {
  switch (msg.t) {
    case "quick": {
      if (ws.room) return;
      const room = findQuickRoom();
      if (room) addToRoom(ws, room, newPeerId(room));
      else createRoom(ws, true);
      break;
    }
    case "host": {
      if (ws.room) return;
      createRoom(ws, false);
      break;
    }
    case "join": {
      if (ws.room) return;
      const code = String(msg.code || "").trim().toUpperCase();
      const room = rooms.get(code);
      if (!room || !room.members.has(1)) return sendJson(ws, { t: "error", msg: `Room ${code} not found.` });
      if (room.locked) return sendJson(ws, { t: "error", msg: "That game already started." });
      if (room.members.size >= MAX_PLAYERS) return sendJson(ws, { t: "error", msg: "That room is full (5 players)." });
      addToRoom(ws, room, newPeerId(room));
      break;
    }
    case "lock":
      if (ws.room && ws.peerId === 1) ws.room.locked = true;
      break;
    case "unlock":
      if (ws.room && ws.peerId === 1) ws.room.locked = false;
      break;
    case "kick": {
      if (!ws.room || ws.peerId !== 1) return;
      const victim = ws.room.members.get(Number(msg.id));
      if (victim && victim !== ws) {
        sendJson(victim, { t: "room_closed", reason: "Removed by host." });
        leaveRoom(victim);
        try { victim.close(1000, "kicked"); } catch (e) {}
      }
      break;
    }
  }
}

// Drop dead connections every 20s.
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    try { ws.ping(); } catch (e) {}
  }
}, 20000);

server.listen(PORT, () => console.log(`Party Brawl server on :${PORT}  (web build: ${PUBLIC_DIR})`));

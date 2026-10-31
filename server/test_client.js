// Protocol test for server.js. Run: PORT=8099 node server.js & node test_client.js
const WebSocket = require("ws");
const URL = process.env.URL || "ws://127.0.0.1:" + (process.env.PORT || "8099") + "/ws";

function client(name) {
  return new Promise((resolve) => {
    const ws = new WebSocket(URL);
    const c = { ws, name, msgs: [], bins: [] };
    ws.on("message", (data, isBinary) => {
      if (isBinary) c.bins.push({ from: data.readInt32LE(0), body: data.slice(4).toString() });
      else c.msgs.push(JSON.parse(data.toString()));
    });
    ws.on("open", () => resolve(c));
  });
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const send = (c, o) => c.ws.send(JSON.stringify(o));
function bin(c, target, text) {
  const b = Buffer.alloc(4 + Buffer.byteLength(text));
  b.writeInt32LE(target, 0);
  b.write(text, 4);
  c.ws.send(b, { binary: true });
}
let fails = 0;
function check(cond, label) {
  console.log((cond ? "PASS " : "FAIL ") + label);
  if (!cond) fails++;
}
const last = (c, t) => [...c.msgs].reverse().find((m) => m.t === t);

(async () => {
  // Private room
  const a = await client("A");
  send(a, { t: "host", name: "A" });
  await wait(150);
  const wa = last(a, "welcome");
  check(wa && wa.id === 1 && wa.host && wa.code.length === 4, "host gets id 1 + room code");

  const b = await client("B");
  send(b, { t: "join", code: wa.code.toLowerCase(), name: "B" });
  await wait(150);
  const wb = last(b, "welcome");
  check(wb && wb.id > 1 && !wb.host, "join by code (case-insensitive)");
  check(!!a.msgs.find((m) => m.t === "peer_joined" && m.id === wb.id), "host told about new peer");

  bin(b, 1, "hello-host");
  bin(a, 0, "hello-all");
  bin(a, wb.id, "hello-b");
  await wait(150);
  check(a.bins.some((x) => x.from === wb.id && x.body === "hello-host"), "client -> host relay with sender id");
  check(b.bins.some((x) => x.from === 1 && x.body === "hello-all"), "host broadcast relay");
  check(b.bins.some((x) => x.from === 1 && x.body === "hello-b"), "host -> specific peer relay");

  const bad = await client("X");
  send(bad, { t: "join", code: "ZZZZ", name: "X" });
  await wait(150);
  check(!!last(bad, "error"), "unknown room code -> error");

  send(a, { t: "lock" });
  await wait(50);
  const late = await client("L");
  send(late, { t: "join", code: wa.code, name: "L" });
  await wait(150);
  check(!!last(late, "error") && !last(late, "welcome"), "locked room refuses joins");

  b.ws.close();
  await wait(150);
  check(!!a.msgs.find((m) => m.t === "peer_left" && m.id === wb.id), "host told when peer leaves");

  // Quick play matchmaking
  const q = [];
  for (let i = 0; i < 7; i++) {
    const c = await client("Q" + i);
    send(c, { t: "quick", name: "Q" + i });
    await wait(60);
    q.push(c);
  }
  await wait(200);
  const codes = q.map((c) => last(c, "welcome").code);
  check(codes.slice(0, 5).every((c) => c === codes[0]), "first 5 quick players share a room");
  check(codes[5] !== codes[0] && codes[6] === codes[5], "6th quick player starts a new room, 7th joins it");
  check(last(q[0], "welcome").host && last(q[5], "welcome").host, "first in each quick room is host");

  // Host leaves -> room closed for the others
  q[0].ws.close();
  await wait(200);
  check(q.slice(1, 5).every((c) => !!last(c, "room_closed")), "host leaving closes room for everyone");

  const h = await (await fetch(URL.replace("ws://", "http://").replace("/ws", "/health"))).json();
  check(h.ok === true, "health endpoint");

  for (const c of [a, bad, late, ...q]) try { c.ws.close(); } catch (e) {}
  console.log(fails === 0 ? "ALL TESTS PASSED" : fails + " TEST(S) FAILED");
  process.exit(fails ? 1 : 0);
})();

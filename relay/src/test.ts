// Relay guarantees, checked rather than assumed.
import { WebSocket } from "ws";

const URL = "ws://localhost:8080";
const ROOM = "a".repeat(64);
const OTHER = "b".repeat(64);
let failures = 0;

const check = (name: string, cond: boolean, detail = "") => {
  console.log(`${cond ? "  ok  " : "  FAIL"}  ${name}${detail ? " — " + detail : ""}`);
  if (!cond) failures++;
};

function client(): Promise<{ ws: WebSocket; frames: any[] }> {
  return new Promise((res) => {
    const ws = new WebSocket(URL);
    const frames: any[] = [];
    ws.on("message", (d) => frames.push(JSON.parse(d.toString())));
    ws.on("open", () => res({ ws, frames }));
  });
}
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
const hello = (ws: WebSocket, room: string, v = 1) =>
  ws.send(JSON.stringify({ t: "hello", v, room }));

(async () => {
  console.log("relay guarantees:");

  // 1. hello -> ready, and presence is false while alone.
  const a = await client();
  hello(a.ws, ROOM); await wait(150);
  check("hello is accepted", a.frames.some((f) => f.t === "ready"));
  check("alone means peer offline",
    a.frames.filter((f) => f.t === "peer").at(-1)?.online === false);

  // 2. Second client flips presence for both.
  const b = await client();
  hello(b.ws, ROOM); await wait(150);
  check("second arrival flips presence for the first",
    a.frames.filter((f) => f.t === "peer").at(-1)?.online === true);
  check("second client sees peer online",
    b.frames.filter((f) => f.t === "peer").at(-1)?.online === true);

  // 3. msg is forwarded byte-for-byte and never echoed to the sender.
  const payload = { t: "msg", n: "bm9uY2U=", c: "Y2lwaGVydGV4dA==" };
  const beforeA = a.frames.length;
  b.ws.send(JSON.stringify(payload)); await wait(150);
  const got = a.frames.find((f) => f.t === "msg");
  check("msg reaches the peer", !!got);
  check("msg is forwarded verbatim",
    got?.n === payload.n && got?.c === payload.c,
    got ? `n=${got.n} c=${got.c}` : "no frame");
  check("sender does not receive its own msg",
    !b.frames.some((f) => f.t === "msg"));
  check("no extra frames invented", a.frames.length === beforeA + 1);

  // 4. A third connection is refused — this is the "only two Macs" rule.
  const c = await client();
  hello(c.ws, ROOM); await wait(150);
  check("third connection is refused",
    c.frames.some((f) => f.t === "error" && f.code === "room_full"));
  check("third connection never gets ready", !c.frames.some((f) => f.t === "ready"));

  // 5. Rooms are isolated.
  const d = await client();
  hello(d.ws, OTHER); await wait(150);
  check("a different room is a different pair",
    d.frames.filter((f) => f.t === "peer").at(-1)?.online === false);

  // 6. Malformed hello is rejected.
  const e = await client();
  hello(e.ws, "not-a-room"); await wait(150);
  check("malformed room id is rejected",
    e.frames.some((f) => f.t === "error" && f.code === "bad_hello"));
  const f2 = await client();
  hello(f2.ws, ROOM, 99); await wait(150);
  check("wrong protocol version is rejected",
    f2.frames.some((x) => x.t === "error" && x.code === "bad_hello"));

  // 7. ping/pong.
  const beforeB = b.frames.length;
  b.ws.send(JSON.stringify({ t: "ping" })); await wait(120);
  check("ping is answered", b.frames.length > beforeB &&
    b.frames.some((x) => x.t === "pong"));

  // 8. Disconnect flips presence back.
  b.ws.close(); await wait(250);
  check("departure flips presence back to offline",
    a.frames.filter((x) => x.t === "peer").at(-1)?.online === false);

  // 9. Rate limiting kicks in.
  const g = await client();
  hello(g.ws, "c".repeat(64)); await wait(100);
  for (let i = 0; i < 200; i++) g.ws.send(JSON.stringify({ t: "ping" }));
  await wait(400);
  check("a firehose is rate limited",
    g.frames.some((x) => x.t === "error" && x.code === "rate_limited"));

  a.ws.close(); c.ws.close(); d.ws.close(); e.ws.close(); f2.ws.close(); g.ws.close();
  console.log(failures === 0 ? "\nall relay guarantees hold" : `\n${failures} FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})();

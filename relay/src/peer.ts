// Scripted peer — speaks the protocol as the other side.
//
// Exists so the tedious cases are testable without a second Mac and without a
// human: flooding the cloud to its cap, dropping mid-drag to exercise `state`
// reconciliation, and waiting out expiry.
//
// The crypto here must match Crypto/Keys.swift exactly. It is the reference
// implementation for the wire format.

import { WebSocket } from "ws";
import { hkdfSync, randomBytes, createCipheriv, createDecipheriv } from "crypto";

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford: no I, L, O, U
const SALT = "live-pet/v1";

export function decodeKey(key: string): Buffer {
  const clean = key.toUpperCase().replace(/[^0-9A-Z]/g, "")
    .replace(/O/g, "0").replace(/[IL]/g, "1").replace(/U/g, "V");
  let bits = 0, value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const idx = ALPHABET.indexOf(ch);
    if (idx < 0) throw new Error(`bad character in key: ${ch}`);
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return Buffer.from(out);
}

const derive = (ikm: Buffer, info: string) =>
  Buffer.from(hkdfSync("sha256", ikm, Buffer.from(SALT), Buffer.from(info), 32));

export const roomId = (ikm: Buffer) => derive(ikm, "room").toString("hex");
export const msgKey = (ikm: Buffer) => derive(ikm, "msg");

export function seal(key: Buffer, plaintext: string) {
  const n = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", key, n);
  const body = Buffer.concat([c.update(plaintext, "utf8"), c.final()]);
  return { n: n.toString("base64"),
           c: Buffer.concat([body, c.getAuthTag()]).toString("base64") };
}

export function open(key: Buffer, nB64: string, cB64: string): string {
  const n = Buffer.from(nB64, "base64");
  const blob = Buffer.from(cB64, "base64");
  const body = blob.subarray(0, blob.length - 16);
  const tag = blob.subarray(blob.length - 16);
  const d = createDecipheriv("aes-256-gcm", key, n);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(body), d.final()]).toString("utf8");
}

const uuid = () =>
  "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (ch) => {
    const r = (Math.random() * 16) | 0;
    return (ch === "x" ? r : (r & 0x3) | 0x8).toString(16);
  });

export class Peer {
  private ws!: WebSocket;
  private key: Buffer;
  private room: string;
  onMessage: (inner: any) => void = () => {};
  onPeer: (online: boolean) => void = () => {};

  constructor(pairingKey: string, private url = "ws://localhost:8080") {
    const ikm = decodeKey(pairingKey);
    this.room = roomId(ikm);
    this.key = msgKey(ikm);
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);
      this.ws.on("open", () =>
        this.ws.send(JSON.stringify({ t: "hello", v: 1, room: this.room })));
      this.ws.on("message", (d) => {
        const f = JSON.parse(d.toString());
        if (f.t === "ready") resolve();
        else if (f.t === "peer") this.onPeer(f.online);
        else if (f.t === "msg") this.onMessage(JSON.parse(open(this.key, f.n, f.c)));
        else if (f.t === "error") reject(new Error(f.code));
      });
      this.ws.on("error", reject);
    });
  }

  private send(inner: object) {
    const body = { id: uuid(), ts: Date.now(), ...inner };
    this.ws.send(JSON.stringify({ t: "msg", ...seal(this.key, JSON.stringify(body)) }));
  }

  text(body: string) { this.send({ k: "text", body }); }
  action(action: string) { this.send({ k: "action", action }); }
  move(x: number, y: number) { this.send({ k: "move", x, y }); }
  state(x: number, y: number, pos_ts: number) { this.send({ k: "state", x, y, pos_ts }); }
  close() { this.ws.close(); }
}

// CLI:  node dist/peer.js <KEY> [flood N | text "..." | move x y]
if (require.main === module) {
  const [key, cmd = "listen", ...rest] = process.argv.slice(2);
  if (!key) { console.error('usage: peer <PAIRING-KEY> [listen|text "…"|flood N|move x y]'); process.exit(1); }
  const p = new Peer(key);
  p.onPeer = (o) => console.log(`peer online: ${o}`);
  p.onMessage = (m) => console.log("recv:", JSON.stringify(m));
  if (cmd === "greet") {
    // Wait until the other side is actually there, then speak. Delivery is
    // presence-gated: sending into an empty room is a no-op by design.
    p.onPeer = (online) => {
      console.log(`peer online: ${online}`);
      if (online) {
        p.text("hello from node");
        p.action("pet");
        p.move(0.25, 0.75);
        p.state(0.25, 0.75, Date.now());
      }
    };
    // Echo text back, so the other side can prove its own send round-tripped
    // without scraping this process's stdout (which is block-buffered on a pipe).
    p.onMessage = (m) => {
      console.log("recv:", JSON.stringify(m));
      if (m.k === "text" && !String(m.body).startsWith("echo:")) p.text(`echo:${m.body}`);
    };
  }
  p.connect().then(async () => {
    console.log("ready");
    if (cmd === "text") p.text(rest.join(" "));
    else if (cmd === "flood") {
      const n = Number(rest[0] ?? 10);
      for (let i = 1; i <= n; i++) { p.text(`flood ${i}/${n}`); await new Promise(r => setTimeout(r, 120)); }
    } else if (cmd === "move") p.move(Number(rest[0]), Number(rest[1]));
    else if (cmd === "state") {
      // state <x> <y> <pos_ts>  — pos_ts may be older or newer than the peer's.
      p.state(Number(rest[0]), Number(rest[1]), Number(rest[2]));
      setTimeout(() => process.exit(0), 600);
    }
  }).catch((e) => { console.error("failed:", e.message); process.exit(1); });
}

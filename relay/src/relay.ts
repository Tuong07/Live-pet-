// Live-pet relay.
//
// Presence and live forwarding only. It knows that two anonymous connections
// share a room and passes bytes between them. There is no inbox, no database
// and no disk write anywhere in this file — if both parties are not connected
// at the same instant, the message is never created at all.
//
// It must never parse the `c` field of a msg frame, and must never log a room
// id: the id is derived from the pairing key, and logging it would hand an
// operator the one piece of metadata this design exists to avoid.

import { WebSocketServer, WebSocket } from "ws";

const PORT = Number(process.env.PORT ?? 8080);
const ROOM_CAPACITY = 2;
const HEARTBEAT_MS = 20_000;

// Rate limiting: a room must not be usable as a firehose.
const RATE_WINDOW_MS = 10_000;
const RATE_MAX_FRAMES = 120;

type Client = WebSocket & {
  room?: string;
  frames?: number[];
  alive?: boolean;
};

/** roomId -> the (at most two) sockets in it. Memory only. */
const rooms = new Map<string, Client[]>();

const send = (ws: WebSocket, obj: unknown) => {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
};

/** Tell everyone in a room how many peers each of them can see. */
function announce(room: string) {
  const peers = rooms.get(room) ?? [];
  for (const ws of peers) {
    send(ws, { t: "peer", online: peers.length > 1 });
  }
}

function leave(ws: Client) {
  const room = ws.room;
  if (!room) return;
  const peers = (rooms.get(room) ?? []).filter((p) => p !== ws);
  if (peers.length === 0) rooms.delete(room);
  else rooms.set(room, peers);
  ws.room = undefined;
  announce(room);
}

/** Returns false when the client has exceeded its budget. */
function withinRate(ws: Client): boolean {
  const now = Date.now();
  ws.frames = (ws.frames ?? []).filter((t) => now - t < RATE_WINDOW_MS);
  ws.frames.push(now);
  return ws.frames.length <= RATE_MAX_FRAMES;
}

const wss = new WebSocketServer({ port: PORT });

wss.on("connection", (raw) => {
  const ws = raw as Client;
  ws.alive = true;
  ws.on("pong", () => { ws.alive = true; });

  ws.on("message", (data) => {
    if (!withinRate(ws)) {
      send(ws, { t: "error", code: "rate_limited" });
      return;
    }

    let frame: any;
    try {
      frame = JSON.parse(data.toString());
    } catch {
      send(ws, { t: "error", code: "bad_hello" });
      return;
    }

    switch (frame?.t) {
      case "hello": {
        const room = frame.room;
        const valid = frame.v === 1 && typeof room === "string" &&
          /^[0-9a-f]{64}$/.test(room);
        if (!valid) {
          send(ws, { t: "error", code: "bad_hello" });
          ws.close();
          return;
        }
        const peers = rooms.get(room) ?? [];
        // This is where "exactly two Macs" is actually enforced.
        if (peers.length >= ROOM_CAPACITY) {
          send(ws, { t: "error", code: "room_full" });
          ws.close();
          return;
        }
        ws.room = room;
        rooms.set(room, [...peers, ws]);
        send(ws, { t: "ready" });
        announce(room);
        return;
      }

      case "msg": {
        if (!ws.room) return;
        // Forwarded verbatim. `c` is never inspected.
        for (const peer of rooms.get(ws.room) ?? []) {
          if (peer !== ws) send(peer, frame);
        }
        return;
      }

      case "ping":
        send(ws, { t: "pong" });
        return;
    }
  });

  ws.on("close", () => leave(ws));
  ws.on("error", () => leave(ws));
});

// Drop sockets that stop answering, so presence does not go stale.
const heartbeat = setInterval(() => {
  for (const raw of wss.clients) {
    const ws = raw as Client;
    if (ws.alive === false) { ws.terminate(); continue; }
    ws.alive = false;
    ws.ping();
  }
}, HEARTBEAT_MS);

wss.on("close", () => clearInterval(heartbeat));

// Deliberately logs a count, never a room id.
console.log(`live-pet relay on ws://localhost:${PORT}`);
setInterval(() => {
  if (rooms.size > 0) console.log(`rooms: ${rooms.size}`);
}, 60_000).unref();

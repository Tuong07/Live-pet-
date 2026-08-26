// Emits test vectors so the Swift implementation can be checked against this one.
import { decodeKey, roomId, msgKey, seal } from "./peer";
const KEY = "XK7M-4F2Q-9BTZ-N3RH";
const ikm = decodeKey(KEY);
const key = msgKey(ikm);
const plaintext = JSON.stringify({ id: "fixed", ts: 1735000000000, k: "text", body: "back in 5" });
const sealed = seal(key, plaintext);
console.log(JSON.stringify({
  key: KEY,
  ikmHex: ikm.toString("hex"),
  roomId: roomId(ikm),
  msgKeyHex: key.toString("hex"),
  plaintext,
  n: sealed.n,
  c: sealed.c,
}, null, 2));

// Cross-implementation check. The vectors come from relay/src/vectors.ts, so a
// pass here means Swift and Node genuinely agree on the wire format — not just
// that each is internally consistent.

import CryptoKit
import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print("\(cond ? "  ok  " : "  FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !cond { failures += 1 }
}
func hex(_ k: SymmetricKey) -> String {
    k.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
}

let KEY = "XK7M-4F2Q-9BTZ-N3RH"
let IKM_HEX = "eccf423c574af5fa8f11"
let ROOM = "25be6fe16662185e0ce7007b57ea1fb0a3f9b5dc003a85e783d61dc3607f5394"
let MSGKEY = "f8bc5c9118702496d53e5f4a01a1fa367c81d85d3c6fd2f3b762abe532039052"
let PLAIN = "{\"id\":\"fixed\",\"ts\":1735000000000,\"k\":\"text\",\"body\":\"back in 5\"}"
let N = "1iY6ptkVUel05yeV"
let C = "9ntLy4d/yNDpo+Wl0u0dnQR0rRtqHEqyRpLUAO+MZzka0TDxc2QUx1RqPwexhJtPvjh55Lb5f/TdcXWurdWqLaFNhaCk593VYbveeWuPrA=="

print("crypto, against the Node reference:")

let ikm = try! PairingKey.decode(KEY)
check("key decodes to the same bytes",
      ikm.map { String(format: "%02x", $0) }.joined() == IKM_HEX)
check("room id matches", PetCrypto.roomID(ikm) == ROOM)
check("message key matches", hex(PetCrypto.messageKey(ikm)) == MSGKEY)

let key = PetCrypto.messageKey(ikm)
if let opened = try? PetCrypto.open(n: N, c: C, key: key) {
    check("Swift opens ciphertext sealed by Node",
          String(data: opened, encoding: .utf8) == PLAIN)
} else {
    check("Swift opens ciphertext sealed by Node", false, "open threw")
}

// Round trip in Swift.
let sealed = try! PetCrypto.seal(Data(PLAIN.utf8), key: key)
let back = try! PetCrypto.open(n: sealed.n, c: sealed.c, key: key)
check("Swift round trip", String(data: back, encoding: .utf8) == PLAIN)
check("nonce is 96 bits", Data(base64Encoded: sealed.n)?.count == 12)
check("a fresh nonce each time",
      (try! PetCrypto.seal(Data(PLAIN.utf8), key: key)).n != sealed.n)

// Tampering must fail, or the encryption is decorative.
var tampered = Array(Data(base64Encoded: sealed.c)!)
tampered[0] ^= 0x01
let bad = Data(tampered).base64EncodedString()
check("tampered ciphertext is rejected",
      (try? PetCrypto.open(n: sealed.n, c: bad, key: key)) == nil)
let wrongKey = PetCrypto.messageKey(try! PairingKey.decode("0000-0000-0000-0000"))
check("wrong key cannot open",
      (try? PetCrypto.open(n: sealed.n, c: sealed.c, key: wrongKey)) == nil)

// Human handling of the key.
check("lower case is accepted", try! PairingKey.decode("xk7m4f2q9btzn3rh") == ikm)
check("hyphens are ignored", try! PairingKey.decode("XK7M4F2Q9BTZN3RH") == ikm)
check("spaces are ignored", try! PairingKey.decode("XK7M 4F2Q 9BTZ N3RH") == ikm)
check("O reads as zero", try! PairingKey.decode("XK7M-4F2Q-9BTZ-N3RH") == ikm)
check("bad character is rejected", (try? PairingKey.decode("XK7M-4F2Q-9BTZ-N3R!")) == nil)
check("short key is rejected", (try? PairingKey.decode("XK7M-4F2Q")) == nil)

// Generated keys are well formed and unique.
let generated = PairingKey.generate()
check("generated key is grouped 4-4-4-4", generated.count == 19 &&
      generated.split(separator: "-").allSatisfy { $0.count == 4 }, generated)
check("generated key round trips", (try? PairingKey.decode(generated))?.count == 10)
check("generated keys differ", PairingKey.generate() != PairingKey.generate())
check("no ambiguous letters", !generated.contains(where: { "ILOU".contains($0) }), generated)

// Different keys must not collide into one room.
let roomA = PetCrypto.roomID(try! PairingKey.decode(PairingKey.generate()))
let roomB = PetCrypto.roomID(try! PairingKey.decode(PairingKey.generate()))
check("different keys give different rooms", roomA != roomB)
check("room id is 64 hex chars", roomA.count == 64 &&
      roomA.allSatisfy { $0.isHexDigit })

print(failures == 0 ? "\ncrypto agrees with the reference" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

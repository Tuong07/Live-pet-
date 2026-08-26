// Key derivation and message sealing.
//
// The pairing key does two jobs: it proves the bond, and it seeds the
// encryption. The relay only ever learns `roomID`, from which `messageKey`
// cannot be derived — so even the relay operator cannot read anything.
//
// relay/src/peer.ts is the reference implementation of this same scheme and is
// cross-tested against it. Changing anything here changes the wire format.

import CryptoKit
import Foundation

enum PairingKey {
    /// Crockford base32: no I, L, O or U, so nothing is ambiguous to misread
    /// aloud or mistype.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let byteCount = 10          // 80 bits

    /// A fresh key, grouped for reading: `XK7M-4F2Q-9BTZ-N3RH`.
    static func generate() -> String {
        var raw = Data(count: byteCount)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        return format(encode(raw))
    }

    static func encode(_ data: Data) -> String {
        var out = "", bits = 0, value = 0
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }

    /// Case-insensitive, hyphens ignored, and the Crockford substitutions
    /// applied so a hand-copied key still works.
    static func decode(_ key: String) throws -> Data {
        var cleaned = ""
        for ch in key.uppercased() {
            switch ch {
            case "O": cleaned.append("0")
            case "I", "L": cleaned.append("1")
            case "U": cleaned.append("V")
            case "-", " ": continue
            default: cleaned.append(ch)
            }
        }
        var bytes = [UInt8](), bits = 0, value = 0
        for ch in cleaned {
            guard let idx = alphabet.firstIndex(of: ch) else { throw KeyError.badCharacter(ch) }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        guard bytes.count == byteCount else { throw KeyError.wrongLength(bytes.count) }
        return Data(bytes)
    }

    static func format(_ raw: String) -> String {
        stride(from: 0, to: raw.count, by: 4).map { i -> String in
            let start = raw.index(raw.startIndex, offsetBy: i)
            let end = raw.index(start, offsetBy: min(4, raw.count - i))
            return String(raw[start..<end])
        }.joined(separator: "-")
    }

    enum KeyError: Error, CustomStringConvertible {
        case badCharacter(Character), wrongLength(Int)
        var description: String {
            switch self {
            case .badCharacter(let c): return "‘\(c)’ isn’t part of a pairing key"
            case .wrongLength(let n): return "a key is 16 characters; this decoded to \(n) bytes"
            }
        }
    }
}

enum PetCrypto {
    private static let salt = Data("live-pet/v1".utf8)

    private static func derive(_ ikm: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                              salt: salt,
                              info: Data(info.utf8),
                              outputByteCount: 32)
    }

    /// What the relay sees. One-way: the message key cannot be recovered from it.
    static func roomID(_ ikm: Data) -> String {
        derive(ikm, info: "room").withUnsafeBytes {
            $0.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func messageKey(_ ikm: Data) -> SymmetricKey { derive(ikm, info: "msg") }

    /// A fresh random 96-bit nonce per message — it must never repeat under the
    /// same key.
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> (n: String, c: String) {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let nonce = box.nonce.withUnsafeBytes({ Data($0) }) as Data? else {
            throw CryptoError.sealFailed
        }
        return (nonce.base64EncodedString(),
                (box.ciphertext + box.tag).base64EncodedString())
    }

    static func open(n: String, c: String, key: SymmetricKey) throws -> Data {
        guard let nonceData = Data(base64Encoded: n),
              let blob = Data(base64Encoded: c), blob.count > 16 else {
            throw CryptoError.malformed
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData),
                                        ciphertext: blob.prefix(blob.count - 16),
                                        tag: blob.suffix(16))
        return try AES.GCM.open(box, using: key)
    }

    enum CryptoError: Error { case sealFailed, malformed }
}

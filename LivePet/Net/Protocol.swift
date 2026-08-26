// The wire format, in two layers: an outer envelope the relay reads, and an
// inner envelope only the two clients can read.

import Foundation

/// Exactly these states. Do not invent others.
enum ConnectionState: String {
    case unpaired      // no key in the Keychain
    case connecting    // dialing, or backing off
    case waiting       // connected, peer offline — sending is disabled
    case live          // both online
}

enum PetActionKind: String, CaseIterable {
    case pet, sleep, poke, feed, kiss
}

/// The decrypted payload. `move` and `state` carry the pet's position as a
/// fraction of the screen, never pixels.
enum InnerFrame {
    case text(id: String, ts: Int64, body: String)
    case action(id: String, ts: Int64, action: PetActionKind)
    case move(id: String, ts: Int64, x: Double, y: Double)
    case state(id: String, ts: Int64, x: Double, y: Double, posTS: Int64)

    var id: String {
        switch self {
        case .text(let id, _, _), .action(let id, _, _),
             .move(let id, _, _, _), .state(let id, _, _, _, _): return id
        }
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func text(_ body: String) -> InnerFrame {
        .text(id: UUID().uuidString, ts: now(), body: body)
    }
    static func action(_ kind: PetActionKind) -> InnerFrame {
        .action(id: UUID().uuidString, ts: now(), action: kind)
    }
    static func move(x: Double, y: Double) -> InnerFrame {
        .move(id: UUID().uuidString, ts: now(), x: x, y: y)
    }
    static func state(x: Double, y: Double, posTS: Int64) -> InnerFrame {
        .state(id: UUID().uuidString, ts: now(), x: x, y: y, posTS: posTS)
    }

    func encoded() throws -> Data {
        var dict: [String: Any]
        switch self {
        case .text(let id, let ts, let body):
            dict = ["id": id, "ts": ts, "k": "text", "body": body]
        case .action(let id, let ts, let action):
            dict = ["id": id, "ts": ts, "k": "action", "action": action.rawValue]
        case .move(let id, let ts, let x, let y):
            dict = ["id": id, "ts": ts, "k": "move", "x": x, "y": y]
        case .state(let id, let ts, let x, let y, let posTS):
            dict = ["id": id, "ts": ts, "k": "state", "x": x, "y": y, "pos_ts": posTS]
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// Unknown kinds return nil rather than throwing: a future version sending
    /// something new must not take the connection down.
    static func decode(_ data: Data) -> InnerFrame? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let k = obj["k"] as? String else { return nil }
        let ts = (obj["ts"] as? Int64) ?? Int64((obj["ts"] as? Double) ?? 0)
        switch k {
        case "text":
            guard let body = obj["body"] as? String else { return nil }
            return .text(id: id, ts: ts, body: body)
        case "action":
            guard let raw = obj["action"] as? String,
                  let kind = PetActionKind(rawValue: raw) else { return nil }
            return .action(id: id, ts: ts, action: kind)
        case "move":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
            return .move(id: id, ts: ts, x: x, y: y)
        case "state":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
            let p = (obj["pos_ts"] as? Int64) ?? Int64((obj["pos_ts"] as? Double) ?? 0)
            return .state(id: id, ts: ts, x: x, y: y, posTS: p)
        default:
            return nil
        }
    }
}

// The thirty-minute window. In memory only — quit the app and it empties,
// because there is nothing written down to recover.

import Foundation

struct Msg: Identifiable, Equatable {
    let id: String
    let text: String
    let mine: Bool
    let born: Date

    /// When this message was first seen. **The clock runs from here, not from
    /// `born`** — you get a full half hour with everything, rather than losing
    /// time to being away from the desk.
    ///
    /// nil means parked: it has arrived but has not been read, so no clock is
    /// running at all. Your own messages are read the moment you send them.
    var firstSeen: Date?

    init(id: String = UUID().uuidString, text: String, mine: Bool,
         born: Date = Date(), firstSeen: Date? = nil) {
        self.id = id; self.text = text; self.mine = mine; self.born = born
        self.firstSeen = mine ? (firstSeen ?? born) : firstSeen
    }

    var isParked: Bool { firstSeen == nil }

    /// 1 when fresh, 0 at expiry. Bubbles dim as they age so expiry reads as
    /// deliberate rather than as messages randomly vanishing. A parked message
    /// shows at full strength — its half hour has not started.
    func life(now: Date, ttl: TimeInterval) -> Double {
        guard let seen = firstSeen, ttl > 0 else { return 1 }
        return max(0, min(1, 1 - now.timeIntervalSince(seen) / ttl))
    }

    /// Parked messages never expire. Nothing is on disk, so the real ceiling is
    /// the life of the app process.
    func hasExpired(now: Date, ttl: TimeInterval) -> Bool {
        guard let seen = firstSeen else { return false }
        return now.timeIntervalSince(seen) >= ttl
    }
}

enum Mood: Equatable { case idle, petted, sleeping, dozing, alert }

/// The action row is a list, not hardcoded buttons, so poke/feed/kiss slot in
/// later without a rewrite. `move` is not here — it is a drag handle.
struct PetAction: Identifiable {
    let id: String
    let kind: PetActionKind
    let mood: Mood
    let holdFor: Double

    static let enabled: [PetAction] = [
        PetAction(id: "pet", kind: .pet, mood: .petted, holdFor: 0.5),
        PetAction(id: "sleep", kind: .sleep, mood: .sleeping, holdFor: 2.5),
        // Phase 4, once the sprites exist:
        // PetAction(id: "poke", kind: .poke, mood: .startled, holdFor: 0.4),
    ]

    static func forKind(_ kind: PetActionKind) -> PetAction? {
        enabled.first { $0.kind == kind }
    }
}

// One pet, two windows onto it. Everything the UI shows and everything that
// crosses the wire meets here.

import AppKit
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class Session: ObservableObject, RelayClientDelegate {
    // Connection
    @Published private(set) var connection: ConnectionState = .unpaired
    @Published var partnerName: String

    // The thirty-minute window
    @Published var messages: [Msg] = []
    @Published var now = Date()

    // Interaction
    @Published var composerOpen = false
    @Published var expanded = false
    @Published var pinned = false
    @Published var hovering = false
    @Published var dragging = false
    @Published var unread = false
    @Published var draft = ""
    @Published var mood: Mood = .idle

    let store: Store
    let ttl: TimeInterval
    private(set) var client: RelayClient?
    var window: PetWindow?

    /// Click-through is off while any of these hold. `dragging` is load-bearing:
    /// a fast drag outruns the window, the cursor leaves the pet, and without it
    /// click-through would switch back on mid-drag.
    var solid: Bool { hovering || composerOpen || unread || dragging || pinned }
    var showsCloud: Bool { expanded && !messages.isEmpty }
    var canSend: Bool { connection == .live }

    init(store: Store, ttl: TimeInterval) {
        self.store = store
        self.ttl = ttl
        self.partnerName = store.partnerName
    }

    // MARK: - Connection

    func start() {
        guard let key = store.pairingKey, let ikm = try? PairingKey.decode(key) else {
            connection = .unpaired
            return
        }
        partnerName = store.partnerName
        let c = RelayClient(roomID: PetCrypto.roomID(ikm),
                            key: PetCrypto.messageKey(ikm),
                            url: store.relayURL)
        c.delegate = self
        client = c
        // RelayClient starts at .connecting and only notifies on change, so
        // without this the UI stays on "not paired yet" while actually dialing.
        connection = .connecting
        c.connect()
    }

    func relay(_ client: RelayClient, didChangeState state: ConnectionState) {
        connection = state
        Trace.write("state \(state.rawValue)")
        // The cat wakes and dozes off the peer frame. Away is a mood, not a
        // disappearance — the pet is never absent or hidden.
        if state == .live {
            if mood == .dozing { mood = .idle }
            sendStateForReconciliation()
        } else if state == .waiting {
            mood = .dozing
        }
        // If they go away mid-conversation the assembly stays as it is — the
        // composer simply renders disabled. Yanking it shut under the cursor
        // would be worse than letting it sit there saying why it cannot send.
    }

    func relay(_ client: RelayClient, didReceive frame: InnerFrame) {
        switch frame {
        case .text(let id, _, let body):
            Trace.write("recv text \(body)")
            messages.append(Msg(id: id, text: body, mine: false))
            trim()
            // An arriving message does not pop the cloud open by itself; it
            // shows a pip and solidifies the pet.
            if !expanded { unread = true }
            flash(.alert, for: 0.6)

        case .action(_, _, let kind):
            Trace.write("recv action \(kind.rawValue)")
            if let a = PetAction.forKind(kind) { flash(a.mood, for: a.holdFor) }

        case .move(_, _, let x, let y):
            Trace.write("recv move \(x),\(y)")
            window?.setRelative(x: x, y: y, animated: true)
            window?.markMoved()
            window?.save()

        case .state(_, _, let x, let y, let posTS):
            // Newest pos_ts wins; the loser animates to match.
            guard let w = window else { return }
            Trace.write("recv state \(x),\(y) posTS=\(posTS) mine=\(w.posTS)")
            if posTS > w.posTS {
                w.setRelative(x: x, y: y, animated: true)
                w.markMoved(ts: posTS)
                w.save()
            }
        }
    }

    /// Both clients send this on entering `live`, so a move made while the other
    /// was away is reconciled rather than silently diverging.
    private func sendStateForReconciliation() {
        guard let w = window else { return }
        let r = w.relative
        client?.send(.state(x: r.x, y: r.y, posTS: w.posTS))
    }

    // MARK: - Sending

    @discardableResult
    func send() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return false }
        let frame = InnerFrame.text(text)
        guard client?.send(frame) == true else { return false }
        Trace.write("sent text \(text)")
        messages.append(Msg(id: frame.id, text: text, mine: true))
        trim()
        draft = ""              // the composer stays open for rapid back-and-forth
        expanded = true
        return true
    }

    /// Mirrored actions are blocked when the peer is away — there is nobody to
    /// mirror to.
    func perform(_ action: PetAction) {
        guard canSend else { return }
        client?.send(.action(action.kind))
        flash(action.mood, for: action.holdFor)
    }

    func didDrop() {
        guard let w = window else { return }
        w.markMoved()
        w.save()
        let r = w.relative
        Trace.write("sent move \(r.x),\(r.y)")
        client?.send(.move(x: r.x, y: r.y))   // one frame on drop, not during
    }

    // MARK: - UI state

    /// Opening is refused while the peer is away: the pet stirs and dozes off
    /// again instead. Returns false when it declined.
    @discardableResult
    func open(focusKeyboard: Bool) -> Bool {
        guard connection == .live else { stir(); return false }
        markVisibleAsRead()
        unread = false
        withAnimation(.easeOut(duration: 0.16)) {
            expanded = true
            composerOpen = true
        }
        if focusKeyboard { window?.panel.makeKey() }
        return true
    }

    /// The pet wakes for a moment, then falls back to dozing — it acknowledges
    /// you without pretending it can carry a message.
    func stir() {
        guard connection != .live else { return }
        Trace.write("stir")
        mood = .idle
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if connection != .live { mood = .dozing }
        }
    }

    /// The clock starts when the cloud opens with the message in it. A message
    /// scrolled out of view above the fold still counts — it was on screen.
    private func markVisibleAsRead() {
        let stamp = Date()
        for i in messages.indices where messages[i].firstSeen == nil {
            messages[i].firstSeen = stamp
        }
    }

    func collapse() {
        pinned = false
        withAnimation(.easeOut(duration: 0.14)) {
            expanded = false
            composerOpen = false
            draft = ""
        }
    }

    func flash(_ m: Mood, for seconds: Double) {
        mood = m
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if mood == m { mood = connection == .waiting ? .dozing : .idle }
        }
    }

    /// A safety valve, not a product rule. Expiry is what ends a message —
    /// scrolled-away messages stay alive until their half hour is up, and a
    /// parked one never expires at all, so the list needs *some* ceiling.
    /// It should never be reached in normal use.
    private static let memoryCeiling = 200

    private func trim() {
        if messages.count > Self.memoryCeiling {
            messages.removeFirst(messages.count - Self.memoryCeiling)
        }
    }

    func expire() {
        now = Date()
        let before = messages.count
        messages.removeAll { $0.hasExpired(now: now, ttl: ttl) }
        if messages.isEmpty && before > 0 { unread = false }
    }
}

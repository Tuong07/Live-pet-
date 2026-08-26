// WebSocket client: presence, heartbeat, reconnect.
//
// Delivery is presence-gated. Nothing is queued — if the peer is not connected
// at the moment you press send, the message is never created. That is the whole
// reason the relay can have no database.

import CryptoKit
import Foundation

@MainActor
protocol RelayClientDelegate: AnyObject {
    func relay(_ client: RelayClient, didChangeState state: ConnectionState)
    func relay(_ client: RelayClient, didReceive frame: InnerFrame)
}

@MainActor
final class RelayClient: NSObject {
    private let roomID: String
    private let key: SymmetricKey
    private let url: URL

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var retry: Timer?

    private var missedPongs = 0
    private var attempt = 0
    private var stopped = true

    weak var delegate: RelayClientDelegate?

    private(set) var state: ConnectionState = .connecting {
        didSet {
            guard state != oldValue else { return }
            delegate?.relay(self, didChangeState: state)
        }
    }

    private static let heartbeatInterval: TimeInterval = 20
    private static let maxBackoff: TimeInterval = 30

    init(roomID: String, key: SymmetricKey, url: URL) {
        self.roomID = roomID
        self.key = key
        self.url = url
        super.init()
        session = URLSession(configuration: .ephemeral)
    }

    // MARK: - Lifecycle

    func connect() {
        stopped = false
        openSocket()
    }

    func disconnect() {
        stopped = true
        teardown()
        state = .connecting
    }

    private func openSocket() {
        teardown()
        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
        send(outer: ["t": "hello", "v": 1, "room": roomID])
    }

    private func teardown() {
        heartbeat?.invalidate(); heartbeat = nil
        retry?.invalidate(); retry = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        missedPongs = 0
    }

    /// Exponential backoff capped at ~30s, so a relay outage does not become a
    /// reconnect storm.
    private func scheduleRetry() {
        guard !stopped, retry == nil else { return }
        teardown()
        state = .connecting
        let delay = min(pow(2, Double(attempt)), Self.maxBackoff)
        attempt += 1
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.retry = nil
                self.openSocket()
            }
        }
    }

    // MARK: - Frames

    private func send(outer: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: outer),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// Sending is refused unless both are online — never queued for later.
    @discardableResult
    func send(_ frame: InnerFrame) -> Bool {
        guard state == .live else { return false }
        guard let plaintext = try? frame.encoded(),
              let sealed = try? PetCrypto.seal(plaintext, key: key) else { return false }
        send(outer: ["t": "msg", "n": sealed.n, "c": sealed.c])
        return true
    }

    /// URLSession delivers completions on a background queue, so this must hop
    /// to the main actor explicitly. `MainActor.assumeIsolated` here is a
    /// runtime trap, not a shortcut — it crashed on the first socket read.
    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.scheduleRetry()
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    else if case .data(let d) = message,
                            let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String else { return }

        switch t {
        case "ready":
            attempt = 0
            state = .waiting          // until the relay says the peer is there
            startHeartbeat()

        case "peer":
            let online = (obj["online"] as? Bool) ?? false
            state = online ? .live : .waiting

        case "msg":
            guard let n = obj["n"] as? String, let c = obj["c"] as? String,
                  let plaintext = try? PetCrypto.open(n: n, c: c, key: key),
                  let frame = InnerFrame.decode(plaintext) else { return }
            delegate?.relay(self, didReceive: frame)

        case "pong":
            missedPongs = 0

        case "error":
            let code = (obj["code"] as? String) ?? "unknown"
            // room_full means a third machine tried this room; retrying is
            // pointless and would hammer the relay.
            if code == "room_full" { stopped = true; teardown(); state = .waiting }
            else { scheduleRetry() }

        default:
            break
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval,
                                         repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.missedPongs += 1
                if self.missedPongs >= 2 { self.scheduleRetry(); return }  // socket is dead
                self.send(outer: ["t": "ping"])
            }
        }
    }
}

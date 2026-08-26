// End-to-end: the Swift client against the real relay and the Node peer.
// Proves the state machine, presence, and that both sides can read each other.

import CryptoKit
import Foundation

let KEY = "XK7M-4F2Q-9BTZ-N3RH"
var failures = 0
var log: [String] = []

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print("\(cond ? "  ok  " : "  FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !cond { failures += 1 }
}

@MainActor
final class Probe: NSObject, RelayClientDelegate {
    var states: [ConnectionState] = []
    var received: [InnerFrame] = []
    func relay(_ c: RelayClient, didChangeState s: ConnectionState) { states.append(s) }
    func relay(_ c: RelayClient, didReceive f: InnerFrame) { received.append(f) }
}

func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

MainActor.assumeIsolated {
    let ikm = try! PairingKey.decode(KEY)
    let client = RelayClient(roomID: PetCrypto.roomID(ikm),
                             key: PetCrypto.messageKey(ikm),
                             url: URL(string: "ws://localhost:8080")!)
    let probe = Probe()
    client.delegate = probe

    print("client against the live relay:")

    // Alone in the room.
    client.connect()
    spin(1.2)
    check("reaches waiting while alone", probe.states.contains(.waiting),
          probe.states.map(\.rawValue).joined(separator: "→"))
    check("sending is refused when the peer is away",
          client.send(.text("into the void")) == false)

    // The Node peer joins and speaks.
    let node = Process()
    node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    node.arguments = ["node", "relay/dist/peer.js", KEY, "greet"]
    node.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let pipe = Pipe(); node.standardOutput = pipe; node.standardError = pipe
    try! node.run()
    spin(2.5)

    check("goes live when the peer arrives", probe.states.last == .live,
          probe.states.map(\.rawValue).joined(separator: "→"))
    check("sending is allowed once live", client.send(.text("hello from swift")))

    // Everything the peer sent should have arrived and decrypted.
    let texts = probe.received.compactMap { if case .text(_, _, let b) = $0 { return b } else { return nil } }
    check("receives text from the peer", texts.contains("hello from node"),
          texts.joined(separator: ","))
    let actions = probe.received.compactMap { if case .action(_, _, let a) = $0 { return a } else { return nil } }
    check("receives an action", actions.contains(.pet))
    let moves = probe.received.compactMap { f -> String? in
        if case .move(_, _, let x, let y) = f { return "\(x),\(y)" } else { return nil }
    }
    check("receives a move with relative coordinates", moves.contains("0.25,0.75"), moves.joined())
    let states = probe.received.compactMap { f -> Int64? in
        if case .state(_, _, _, _, let p) = f { return p } else { return nil }
    }
    check("receives a state frame carrying pos_ts", states.first != nil)

    // The peer echoes text back, which proves Swift's own send arrived and
    // decrypted on the far side.
    spin(1.5)
    let echoed = probe.received.compactMap { f -> String? in
        if case .text(_, _, let b) = f, b.hasPrefix("echo:") { return b } else { return nil }
    }
    check("Swift's send arrived at the peer and came back",
          echoed.contains("echo:hello from swift"), echoed.joined(separator: ","))

    // Peer leaves.
    node.terminate()
    spin(2.0)
    check("drops back to waiting when the peer leaves", probe.states.last == .waiting,
          probe.states.map(\.rawValue).joined(separator: "→"))
    check("sending is refused again", client.send(.text("gone")) == false)

    client.disconnect()
    print(failures == 0 ? "\nclient and relay agree" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

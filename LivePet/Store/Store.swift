// The only things that persist. "Nothing on disk" governs *message content* —
// these three are not message data:
//
//   pairing key       → Keychain
//   partner nickname  → Keychain, alongside it
//   pet position      → UserDefaults
//
// Everything is namespaced by profile so two instances on one Mac can be
// strangers who pair with each other.

import Foundation

struct Store {
    let profile: String
    private let service = "dev.livepet"
    private let defaults: UserDefaults

    init(profile: String) {
        self.profile = profile
        self.defaults = UserDefaults(suiteName: "live-pet-\(profile)") ?? .standard
    }

    // MARK: - Keychain

    private func account(_ name: String) -> String { "\(profile).\(name)" }

    private func read(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(name),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ name: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(name),
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private func delete(_ name: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(name),
        ]
        SecItemDelete(base as CFDictionary)
    }

    var pairingKey: String? {
        get { read("pairingKey") }
        nonmutating set { newValue.map { write("pairingKey", $0) } ?? delete("pairingKey") }
    }

    /// Named locally during pairing. Never crosses the wire, so the relay never
    /// learns a name.
    var partnerName: String {
        get { read("partnerName") ?? "them" }
        nonmutating set { write("partnerName", newValue) }
    }

    var isPaired: Bool { pairingKey != nil }

    // MARK: - Position (relative, never pixels)

    func savePosition(x: Double, y: Double, at ts: Int64) {
        defaults.set(x, forKey: "fx")
        defaults.set(y, forKey: "fy")
        defaults.set(Double(ts), forKey: "posTS")
    }

    var position: (x: Double, y: Double, ts: Int64) {
        let x = defaults.object(forKey: "fx") as? Double ?? 0.86
        let y = defaults.object(forKey: "fy") as? Double ?? 0.40
        let ts = Int64(defaults.object(forKey: "posTS") as? Double ?? 0)
        return (x, y, ts)
    }

    /// Development only — lets one machine point at a local relay.
    var relayURL: URL {
        if let override = CommandLine.arguments.first(where: { $0.hasPrefix("--relay=") }) {
            let raw = String(override.dropFirst("--relay=".count))
            if let url = URL(string: raw) { return url }
        }
        return URL(string: "ws://localhost:8080")!
    }
}

// First run. One key, exchanged out-of-band, bonds two installs.
//
// The key is never transmitted. The nickname never leaves this machine either,
// so the relay never learns a name.

import AppKit
import SwiftUI

@MainActor
final class PairingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: Store
    private let onPaired: () -> Void

    init(store: Store, onPaired: @escaping () -> Void) {
        self.store = store
        self.onPaired = onPaired
    }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = PairingView(store: store) { [weak self] in
            self?.close()
            self?.onPaired()
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Live-pet"
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct PairingView: View {
    let store: Store
    let done: () -> Void

    @State private var generated = PairingKey.generate()
    @State private var entered = ""
    @State private var nickname = ""
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Bond with one person")
                    .font(.system(size: 17, weight: .semibold))
                Text("Send them this key, or type in theirs. Whoever goes second uses the other's key — you both end up with the same one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR KEY").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                HStack {
                    Text(generated)
                        .font(.system(size: 17, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generated, forType: .string)
                        copied = true
                    }
                    Button("New") { generated = PairingKey.generate(); copied = false }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("THEIR KEY").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                TextField("XXXX-XXXX-XXXX-XXXX", text: $entered)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, design: .monospaced))
                Text("Leave this empty to use your own key above.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT SHOULD I CALL THEM?").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Sam", text: $nickname).textFieldStyle(.roundedBorder)
                Text("Stays on this Mac. It never crosses the wire.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Pair") { pair() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420, height: 430)
    }

    private func pair() {
        let candidate = entered.trimmingCharacters(in: .whitespaces).isEmpty
            ? generated : entered
        do {
            _ = try PairingKey.decode(candidate)
        } catch {
            self.error = "\(error)"
            return
        }
        store.pairingKey = PairingKey.format(
            PairingKey.encode(try! PairingKey.decode(candidate)))
        let name = nickname.trimmingCharacters(in: .whitespaces)
        store.partnerName = name.isEmpty ? "them" : name
        done()
    }
}

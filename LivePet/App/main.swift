// Entry point. Menu bar only, no Dock icon.

import AppKit
import ApplicationServices
import SwiftUI

/// Append-only trace, so two instances can be checked against each other
/// without a human watching.
@MainActor
enum Trace {
    private static var handle: FileHandle?
    static func open(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }
    static func write(_ line: String) {
        guard let h = handle, let d = (line + "\n").data(using: .utf8) else { return }
        h.write(d); try? h.synchronize()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var session: Session!
    private var win: PetWindow!
    private var pairing: PairingWindow?
    private var status: NSStatusItem!

    private var tick: Timer?
    private var dwellSince: Date?
    private var leftAt: Date?
    private var escMonitor: Any?
    private var expiryCounter = 0

    static func argValue(_ key: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let profile = Self.argValue("--profile=") ?? "default"
        let ttl = Double(Self.argValue("--expiry=") ?? "") ?? 1800
        store = Store(profile: profile)

        // Development only: pair without the first-run screen, so two instances
        // can be driven headlessly.
        if let key = Self.argValue("--pair=") {
            store.pairingKey = key
            store.partnerName = Self.argValue("--name=") ?? "them"
        }
        if let path = Self.argValue("--trace=") { Trace.open(path) }

        session = Session(store: store, ttl: ttl)

        win = PetWindow(store: store)
        session.window = win
        // Mirrored relative coordinates put two instances on one screen exactly
        // on top of each other, so the second profile is nudged aside in dev.
        win.restore(devOffset: profile == "default" || profile == "a" ? 0 : -280)

        let host = NSHostingView(rootView: Assembly(session: session, win: win))
        host.frame = NSRect(x: 0, y: 0, width: L.width, height: win.height)
        win.panel.contentView = host
        win.panel.orderFrontRegardless()

        buildStatusItem()

        if store.isPaired { session.start() } else { showPairing() }
        Trace.write("launched profile=\(profile) paired=\(store.isPaired)")

        tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53, self.session.expanded {
                self.session.collapse(); return nil
            }
            return e
        }

        if let script = Self.argValue("--drive=") { runScript(script) }
        if let prefix = Self.argValue("--snapshot=") { snapshot(prefix) }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: win.panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session.pinned else { return }
                    self.session.collapse()      // clicking outside collapses it
                }
            }
    }

    /// Renders from inside the process, so no Screen Recording grant is needed.
    private func snapshot(_ prefix: String) {
        Task { @MainActor in
            tick?.invalidate()          // freeze hover, or the capture races it
            session.messages = [
                Msg(text: "hey — lunch soon?", mine: false),
                Msg(text: "yeah, give me ten", mine: true),
                Msg(text: "the cat is sitting on my keyboard again and flatly refuses to move", mine: false),
            ]
            session.expanded = true
            session.composerOpen = true
            session.draft = "on my way"
            session.hovering = true

            let pairView = NSHostingView(rootView: PairingView(store: store, done: {}))
            pairView.frame = NSRect(x: 0, y: 0, width: 420, height: 430)
            let holder = NSWindow(contentRect: pairView.frame,
                                  styleMask: [.titled], backing: .buffered, defer: false)
            holder.contentView = pairView

            for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
                win.panel.appearance = NSAppearance(named: appearance)
                win.panel.backgroundColor = NSColor(calibratedWhite: 0.55, alpha: 1)
                holder.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(600))
                capture(win.panel.contentView, to: "\(prefix)-pet-\(name).png")
                capture(pairView, to: "\(prefix)-pairing-\(name).png")
            }
            print("snapshots written")
            NSApp.terminate(nil)
        }
    }

    private func capture(_ view: NSView?, to path: String) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// Development only. `--drive=wait:2,text:hi,action:pet,move:0.3:0.6,quit`
    private func runScript(_ script: String) {
        Task { @MainActor in
            for step in script.split(separator: ",") {
                let parts = step.split(separator: ":").map(String.init)
                switch parts.first {
                case "wait":
                    let s = Double(parts.count > 1 ? parts[1] : "1") ?? 1
                    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                case "text":
                    session.draft = parts.dropFirst().joined(separator: ":")
                    let ok = session.send()
                    Trace.write("drive text sent=\(ok)")
                case "action":
                    if let kind = PetActionKind(rawValue: parts[1]),
                       let a = PetAction.forKind(kind) {
                        session.perform(a)
                        Trace.write("drive action \(kind.rawValue) canSend=\(session.canSend)")
                    }
                case "move":
                    let x = Double(parts[1]) ?? 0.5, y = Double(parts[2]) ?? 0.5
                    win.setRelative(x: x, y: y)
                    session.didDrop()
                case "pos":
                    let r = win.relative
                    Trace.write("pos \(r.x),\(r.y)")
                case "quit":
                    Trace.write("drive done")
                    NSApp.terminate(nil)
                default: break
                }
            }
            Trace.write("drive done")
        }
    }

    // MARK: - Hover, dwell, linger

    private func poll() {
        if session.dragging {
            win.panel.ignoresMouseEvents = false     // never interrupt a drag
            return
        }
        let mouse = NSEvent.mouseLocation
        let inside = win.hitAssembly(mouse, expanded: session.expanded)

        if inside {
            leftAt = nil
            if dwellSince == nil { dwellSince = Date() }
            let held = Date().timeIntervalSince(dwellSince!)
            if held >= L.dwell {
                session.hovering = true
                // Hover opens it. No click required.
                if !session.expanded { session.open(focusKeyboard: false) }
            }
            // Keyboard focus is a later, deliberate step — a cursor drifting
            // over the pet mid-sentence must not swallow the rest of the line.
            if held >= L.focusDwell, session.composerOpen, !win.panel.isKeyWindow {
                win.panel.makeKey()
            }
        } else {
            dwellSince = nil
            session.hovering = false
            if session.expanded && !session.pinned {
                if leftAt == nil { leftAt = Date() }
                else if Date().timeIntervalSince(leftAt!) >= L.linger {
                    leftAt = nil
                    session.collapse()
                }
            }
        }
        win.panel.ignoresMouseEvents = !session.solid

        expiryCounter += 1
        if expiryCounter >= 20 {            // once a second
            expiryCounter = 0
            session.expire()
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "◍"
        let menu = NSMenu()

        let key = NSMenuItem(title: "Copy pairing key", action: #selector(copyKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)

        let pair = NSMenuItem(title: "Pair…", action: #selector(showPairingMenu), keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)

        menu.addItem(.separator())
        let info = NSMenuItem(title: "Profile: \(store.profile)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Live-pet",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
    }

    @objc private func copyKey() {
        guard let k = store.pairingKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(k, forType: .string)
    }

    @objc private func showPairingMenu() { showPairing() }

    private func showPairing() {
        pairing = PairingWindow(store: store) { [weak self] in
            guard let self else { return }
            self.session.start()
            NSApp.setActivationPolicy(.accessory)
        }
        pairing?.show()
    }
}

// NSApplication.delegate is weak, so the delegate needs an owner that outlives
// this scope.
nonisolated(unsafe) var retained: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let d = AppDelegate()
    retained = d
    app.delegate = d
    app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
    app.run()
}

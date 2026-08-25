// Live-pet — window behaviour demo.
// DISPOSABLE. Proves macOS panel behaviour only: no relay, no pairing,
// no encryption, no mirroring, no art. See CLAUDE.md "Working mode: demo first".

import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Configuration

struct Config {
    var profile: String = "a"
    var expiry: TimeInterval = 1800   // 30 minutes, per spec

    static func parse() -> Config {
        var c = Config()
        for arg in CommandLine.arguments.dropFirst() {
            if arg.hasPrefix("--profile=") {
                c.profile = String(arg.dropFirst("--profile=".count))
            } else if arg.hasPrefix("--expiry=") {
                c.expiry = Double(arg.dropFirst("--expiry=".count)) ?? c.expiry
            }
        }
        return c
    }
}

// MARK: - Layout

enum L {
    static let width: CGFloat = 320
    static let pet: CGFloat = 72
    static let gap: CGFloat = 10
    static let bottom: CGFloat = 210
    static let dwell: TimeInterval = 0.2
    /// Cloud is capped at a third of the screen, per spec.
    static func cloudCap(_ screen: NSScreen) -> CGFloat {
        min(260, screen.frame.height / 3)
    }
}

// MARK: - Model

struct Msg: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let mine: Bool
    let born = Date()
}

enum Mood: Equatable { case idle, petted, sleeping }

@MainActor final class PetState: ObservableObject {
    @Published var composerOpen = false
    @Published var draft = ""
    @Published var messages: [Msg] = []
    @Published var mood: Mood = .idle
    @Published var hovering = false     // cursor dwelling on the pet
    @Published var unread = false

    /// The pet accepts clicks when it is hovered, open, or wants attention.
    var solid: Bool { hovering || composerOpen || unread }

    func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        messages.append(Msg(text: t, mine: true))
        draft = ""                      // composer stays open, per spec
    }

    func receive(_ text: String) {
        messages.append(Msg(text: text, mine: false))
        if !composerOpen { unread = true }
        flash(.petted)
    }

    func flash(_ m: Mood, for seconds: Double = 0.45) {
        mood = m
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if mood == m { mood = .idle }
        }
    }

    func expire(_ ttl: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-ttl)
        let before = messages.count
        messages.removeAll { $0.born < cutoff }
        if messages.isEmpty && before > 0 { unread = false }
    }
}

// MARK: - Panel

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The spec says the pet lives on the **main display**. `NSScreen.main` is the
/// screen holding keyboard focus, which moves as you switch windows — on a
/// two-display setup it drifts. The primary display is always `screens[0]`.
@MainActor func primaryScreen() -> NSScreen {
    NSScreen.screens.first ?? NSScreen.main!
}

// MARK: - Window geometry

@MainActor final class PetWindow {
    let panel: PetPanel
    let defaults: UserDefaults
    let cloudCap: CGFloat
    let height: CGFloat

    /// Distance from the top of the panel down to the pet's centre.
    let petFromTop: CGFloat

    init(config: Config) {
        let screen = primaryScreen()
        cloudCap = L.cloudCap(screen)
        petFromTop = cloudCap + L.gap + L.pet / 2
        height = cloudCap + L.gap + L.pet + L.gap + L.bottom

        defaults = UserDefaults(suiteName: "live-pet-demo-\(config.profile)")
            ?? .standard

        panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: L.width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
    }

    /// Pet centre in screen coordinates (origin bottom-left).
    var petCenter: CGPoint {
        let o = panel.frame.origin
        return CGPoint(x: o.x + L.width / 2,
                       y: o.y + height - petFromTop)
    }

    func setPetCenter(_ p: CGPoint) {
        let f = primaryScreen().frame
        // Spec: clamp so the assembly stays on screen, not just the pet.
        // Horizontally the full panel width is kept on screen, so the cloud and
        // composer never hang off the edge.
        let halfW = L.width / 2
        // Vertically the pet and everything below it (composer + action row)
        // must fit. The cloud is capped and only present when there are live
        // messages, so it is allowed to clip rather than creating a large dead
        // zone at the bottom of the screen where the pet cannot go.
        let below = L.pet / 2 + L.gap + L.bottom
        let above = L.pet / 2 + 4
        let x = min(max(p.x, f.minX + halfW), f.maxX - halfW)
        let y = min(max(p.y, f.minY + below), f.maxY - above)
        panel.setFrameOrigin(NSPoint(x: x - L.width / 2,
                                     y: y - height + petFromTop))
    }

    func save() {
        let screen = primaryScreen()
        let f = screen.frame
        let c = petCenter
        defaults.set(Double((c.x - f.minX) / f.width), forKey: "fx")
        defaults.set(Double((c.y - f.minY) / f.height), forKey: "fy")
    }

    func restore(offset: CGFloat) {
        let screen = primaryScreen()
        let f = screen.frame
        let fx = defaults.object(forKey: "fx") as? Double ?? 0.86
        let fy = defaults.object(forKey: "fy") as? Double ?? 0.30
        setPetCenter(CGPoint(x: f.minX + CGFloat(fx) * f.width + offset,
                             y: f.minY + CGFloat(fy) * f.height))
    }

    func hit(_ mouse: CGPoint) -> Bool {
        let c = petCenter
        return hypot(mouse.x - c.x, mouse.y - c.y) <= L.pet / 2 + 4
    }
}

// MARK: - Views

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct Bubble: View {
    let msg: Msg
    var body: some View {
        HStack {
            if msg.mine { Spacer(minLength: 24) }
            Text(msg.text)
                .font(.system(size: 12.5))
                .foregroundStyle(msg.mine ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(msg.mine ? Color.accentColor
                                       : Color.primary.opacity(0.11)))
            if !msg.mine { Spacer(minLength: 24) }
        }
    }
}

struct Cloud: View {
    let messages: [Msg]
    let cap: CGFloat
    @State private var content: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if !messages.isEmpty {
                VStack(spacing: 4) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(messages) { Bubble(msg: $0).id($0.id) }
                            }
                            .padding(10)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: HeightKey.self,
                                                       value: g.size.height)
                            })
                        }
                        .scrollIndicators(.never)
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: messages.count) {
                            if let last = messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                    .frame(height: min(max(content, 34), cap))
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.regularMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10)))

                    // thinking-cloud tail
                    HStack(spacing: 3) {
                        Circle().frame(width: 7, height: 7)
                        Circle().frame(width: 4, height: 4)
                    }
                    .foregroundStyle(.regularMaterial)
                    .padding(.leading, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onPreferenceChange(HeightKey.self) { content = $0 }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            }
        }
        .frame(height: cap, alignment: .bottom)
        .animation(.easeOut(duration: 0.18), value: messages.count)
    }
}

struct Pet: View {
    let mood: Mood
    let solid: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(mood == .sleeping ? 0.18 : 0.30))
                .overlay(Circle().strokeBorder(
                    Color.accentColor.opacity(solid ? 0.85 : 0),
                    lineWidth: 2))
                .frame(width: L.pet, height: L.pet)
                .scaleEffect(mood == .petted ? 1.10 : 1.0)
            if mood == .sleeping {
                Text("z z")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .offset(x: 26, y: -22)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: mood)
        .animation(.easeOut(duration: 0.14), value: solid)
        .contentShape(Circle())
    }
}

struct Assembly: View {
    @ObservedObject var state: PetState
    let win: PetWindow
    @FocusState private var focused: Bool
    @State private var dragStart: CGPoint?

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if dragStart == nil { dragStart = win.petCenter }
                guard let s = dragStart else { return }
                win.setPetCenter(CGPoint(x: s.x + v.translation.width,
                                         y: s.y - v.translation.height))
            }
            .onEnded { _ in dragStart = nil; win.save() }
    }

    var body: some View {
        VStack(spacing: L.gap) {
            Cloud(messages: state.messages, cap: win.cloudCap)

            Pet(mood: state.mood, solid: state.solid)
                .gesture(drag)
                .onTapGesture { open() }

            VStack(spacing: 8) {
                if state.composerOpen {
                    HStack(spacing: 6) {
                        TextField("say something…", text: $state.draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .focused($focused)
                            .onSubmit { state.send() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
                    .frame(width: 236)

                    HStack(spacing: 6) {
                        action("pet") { state.flash(.petted) }
                        action("sleep") { state.flash(.sleeping, for: 2.5) }
                        moveHandle()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: L.bottom, alignment: .top)
        }
        .frame(width: L.width, height: win.height)
        .onChange(of: state.composerOpen) { _, open in focused = open }
    }

    private func action(_ title: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Text(title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private func moveHandle() -> some View {
        Text("move")
            .font(.system(size: 11.5))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
            .gesture(drag)
    }

    private func open() {
        state.unread = false
        state.composerOpen = true
        win.panel.makeKey()
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.parse()
    let state = PetState()
    var win: PetWindow!
    var status: NSStatusItem!
    var dwellSince: Date?
    var timer: Timer?
    var escMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        win = PetWindow(config: config)
        win.restore(offset: config.profile == "a" ? 0 : -260)

        let host = NSHostingView(rootView: Assembly(state: state, win: win))
        host.frame = NSRect(x: 0, y: 0, width: L.width, height: win.height)
        win.panel.contentView = host
        win.panel.orderFrontRegardless()

        buildStatusItem()
        if CommandLine.arguments.contains("--diag") { startDiagnostics() }

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53, self.state.composerOpen {
                self.closeComposer(); return nil
            }
            return e
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: win.panel, queue: .main) { _ in
                MainActor.assumeIsolated { self.closeComposer() }
            }
    }

    /// Self-reporting for verification: screen-recording permission is not
    /// granted here, so the app describes its own window state.
    private func startDiagnostics() {
        let screen = primaryScreen()
        let p = win.panel
        print("--- live-pet diag ---")
        print("screens: \(NSScreen.screens.count)")
        print("main screen frame: \(screen.frame)")
        print("panel frame: \(p.frame)")
        print("pet centre: \(win.petCenter)")
        print("level: \(p.level.rawValue) (statusBar=\(NSWindow.Level.statusBar.rawValue))")
        print("canJoinAllSpaces: \(p.collectionBehavior.contains(.canJoinAllSpaces))")
        print("fullScreenAuxiliary: \(p.collectionBehavior.contains(.fullScreenAuxiliary))")
        print("nonactivatingPanel: \(p.styleMask.contains(.nonactivatingPanel))")
        print("borderless: \(p.styleMask.contains(.borderless))")
        print("opaque: \(p.isOpaque)  visible: \(p.isVisible)")
        print("ignoresMouseEvents: \(p.ignoresMouseEvents)")
        print("activationPolicy: \(NSApp.activationPolicy().rawValue) (accessory=1)")
        print("statusItem visible: \(status.isVisible)")
        print("cloudCap: \(win.cloudCap)  panelHeight: \(win.height)")
        print("primary screen is screens[0]: \(screen == NSScreen.screens.first)")
        // CLAUDE.md open item: does cursor polling need Accessibility?
        print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        print("mouseLocation: \(NSEvent.mouseLocation)")
        print("modifierFlags readable: \(NSEvent.modifierFlags.rawValue)")
        // Clamping must survive an absurd request.
        let saved = win.petCenter
        win.setPetCenter(CGPoint(x: -9999, y: -9999))
        print("clamp low  -> \(win.petCenter)")
        win.setPetCenter(CGPoint(x: 99999, y: 99999))
        print("clamp high -> \(win.petCenter)")
        win.setPetCenter(saved)

        // Exercise the state machine without a human.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            state.receive("diagnostic message one")
            state.receive("diagnostic message two")
            try? await Task.sleep(for: .milliseconds(300))
            print("after receive -> messages=\(state.messages.count) unread=\(state.unread) solid=\(state.solid) ignoresMouse=\(p.ignoresMouseEvents)")

            state.composerOpen = true
            state.draft = "typed by diagnostics"
            state.send()
            try? await Task.sleep(for: .milliseconds(200))
            print("after send -> messages=\(state.messages.count) draft=\"\(state.draft)\" composerOpen=\(state.composerOpen)")

            // Movement persists as relative coordinates.
            let before = win.petCenter
            win.setPetCenter(CGPoint(x: before.x - 300, y: before.y - 120))
            win.save()
            print("moved -> \(win.petCenter)  saved fx=\(win.defaults.double(forKey: "fx")) fy=\(win.defaults.double(forKey: "fy"))")

            // Expiry.
            state.expire(0)
            print("after expire(0) -> messages=\(state.messages.count) unread=\(state.unread)")
            print("--- diag complete ---")
            exit(0)
        }
    }

    private var expiryCounter = 0

    private func tick() {
        // Dwell-to-solidify: poll the cursor rather than rely on hover, which a
        // click-through window never receives.
        let inside = win.hit(NSEvent.mouseLocation)
        if inside {
            if dwellSince == nil { dwellSince = Date() }
            if let s = dwellSince, Date().timeIntervalSince(s) >= L.dwell {
                state.hovering = true
            }
        } else {
            dwellSince = nil
            state.hovering = false
        }
        win.panel.ignoresMouseEvents = !state.solid

        expiryCounter += 1
        if expiryCounter >= 20 {          // once a second
            expiryCounter = 0
            state.expire(config.expiry)
        }
    }

    private func closeComposer() {
        guard state.composerOpen else { return }
        state.composerOpen = false
        state.draft = ""
    }

    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "◍"
        let m = NSMenu()
        let sim = NSMenuItem(title: "Simulate incoming message",
                             action: #selector(simulate), keyEquivalent: "")
        sim.target = self
        m.addItem(sim)
        let reset = NSMenuItem(title: "Reset position",
                               action: #selector(resetPos), keyEquivalent: "")
        reset.target = self
        m.addItem(reset)
        m.addItem(.separator())
        let info = NSMenuItem(title: "Profile: \(config.profile)",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        m.addItem(info)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit Live-pet",
                             action: #selector(NSApplication.terminate(_:)),
                             keyEquivalent: "q"))
        status.menu = m
    }

    private static let samples = [
        "lunch?", "look outside 🌤", "call me when you're free",
        "i'm stuck on this bug", "miss you"
    ]

    @objc private func simulate() {
        state.receive(Self.samples.randomElement() ?? "hello")
    }

    @objc private func resetPos() {
        win.defaults.removeObject(forKey: "fx")
        win.defaults.removeObject(forKey: "fy")
        win.restore(offset: config.profile == "a" ? 0 : -260)
    }
}

// NSApplication.delegate is a weak reference, so the delegate needs an owner
// that outlives this scope.
nonisolated(unsafe) var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let d = AppDelegate()
    retainedDelegate = d
    app.delegate = d
    app.setActivationPolicy(.accessory)
    app.run()
}

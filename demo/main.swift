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

/// Spec: the action row is "a list, not three hardcoded buttons" so poke, feed
/// and kiss can slot in later without a rewrite. `move` is not here — it is a
/// drag handle rather than a fired action, and unlike these it is not mirrored.
struct PetAction: Identifiable {
    let id: String
    let run: @MainActor (PetState) -> Void

    static let enabled: [PetAction] = [
        PetAction(id: "pet")   { $0.flash(.petted) },
        PetAction(id: "sleep") { $0.flash(.sleeping, for: 2.5) },
        // Phase 4, once the sprites exist:
        // PetAction(id: "poke")  { $0.flash(.startled) },
        // PetAction(id: "feed")  { $0.flash(.eating) },
        // PetAction(id: "kiss")  { $0.flash(.blushing) },
    ]
}

@MainActor final class PetState: ObservableObject {
    @Published var composerOpen = false
    @Published var draft = ""
    @Published var messages: [Msg] = []
    @Published var mood: Mood = .idle
    @Published var hovering = false     // cursor dwelling on the pet
    @Published var unread = false
    @Published var dragging = false
    /// The cloud and composer collapse together; messages stay alive underneath.
    @Published var expanded = false

    /// The pet accepts clicks when it is hovered, open, dragged, or wants
    /// attention. `dragging` is load-bearing: without it a fast drag outruns
    /// the window, the cursor leaves the pet, click-through switches back on
    /// mid-drag and the pet stops receiving the events moving it.
    var solid: Bool { hovering || composerOpen || unread || dragging }

    var showsCloud: Bool { expanded && !messages.isEmpty }

    func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        messages.append(Msg(text: t, mine: true))
        draft = ""                      // composer stays open, per spec
    }

    func collapse() {
        expanded = false
        composerOpen = false
        draft = ""
    }

    func receive(_ text: String) {
        messages.append(Msg(text: text, mine: false))
        if !composerOpen { unread = true }
        expanded = true                 // an arriving message shows itself
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
        panel.animationBehavior = .none
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

    /// One definition, used both as the plain stack and as the scroller's
    /// content, so the two can never drift apart.
    private var stack: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(messages) { Bubble(msg: $0).id($0.id) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if !messages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Hug the content until it reaches the cap, then scroll.
                    // The cap belongs on the scrolling branch, not the
                    // container: `.frame(maxHeight:)` *grows* to whatever the
                    // parent offers, which pinned the cloud open at full cap.
                    // Neither `fixedSize` nor measuring inside the ScrollView
                    // works: a ScrollView is greedy, and a GeometryReader placed
                    // within one measures the height the scroller already
                    // imposed, settling at a single row.
                    ViewThatFits(in: .vertical) {
                        stack
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) { stack }
                                .scrollIndicators(.never)
                                .defaultScrollAnchor(.bottom)
                                .onChange(of: messages.count) {
                                    if let last = messages.last {
                                        withAnimation {
                                            proxy.scrollTo(last.id, anchor: .bottom)
                                        }
                                    }
                                }
                        }
                        .frame(height: cap)
                    }
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
                }
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
                .fill(Color.primary.opacity(mood == .sleeping ? 0.22 : 0.42))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25),
                                               lineWidth: 1))
                .overlay(Circle().strokeBorder(
                    Color.accentColor.opacity(solid ? 0.9 : 0),
                    lineWidth: 2.5))
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
    /// Offset from the cursor to the pet's centre, captured when the drag starts.
    @State private var grab: CGSize?

    /// Driven by the absolute cursor position, never by `translation`.
    /// `translation` is measured in the window's own coordinate space, so
    /// moving the window shifts the baseline the next translation is measured
    /// against — the pet chases the cursor and overshoots. Reading
    /// `NSEvent.mouseLocation` is in screen space and cannot feed back.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in
                let m = NSEvent.mouseLocation
                if grab == nil {
                    let c = win.petCenter
                    grab = CGSize(width: c.x - m.x, height: c.y - m.y)
                    state.dragging = true
                }
                guard let g = grab else { return }
                win.setPetCenter(CGPoint(x: m.x + g.width, y: m.y + g.height))
            }
            .onEnded { _ in
                grab = nil
                state.dragging = false
                win.save()
            }
    }

    var body: some View {
        VStack(spacing: L.gap) {
            Cloud(messages: state.showsCloud ? state.messages : [],
                  cap: win.cloudCap)

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
                    .onExitCommand { close() }

                    HStack(spacing: 6) {
                        ForEach(PetAction.enabled) { a in
                            action(a.id) { a.run(state) }
                        }
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

    private func close() {
        withAnimation(.easeOut(duration: 0.14)) { state.collapse() }
    }

    private func open() {
        state.unread = false
        // Cloud and composer appear in the same step, not one before the other.
        withAnimation(.easeOut(duration: 0.16)) {
            state.expanded = true
            state.composerOpen = true
        }
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
        if let prefix = Self.argValue("--snapshot=") { startSnapshot(prefix) }

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

    static func argValue(_ key: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(key) }
            .map { String($0.dropFirst(key.count)) }
    }

    /// Renders the assembly to PNG from inside the app. This is the view's own
    /// bitmap, not a screen capture, so it needs no Screen Recording grant.
    private func startSnapshot(_ prefix: String) {
        let n = CommandLine.arguments.contains("--idle")
            ? 0 : (Int(Self.argValue("--msgs=") ?? "3") ?? 3)
        Task { @MainActor in
            let script = ["hey — lunch soon?", "yeah, give me ten",
                          "look outside 🌤",
                          "the cat is sitting on my keyboard again and flatly refuses to move, send help",
                          "ok back in 5"]
            for i in 0..<n {
                let text = script[i % script.count]
                if i % 2 == 0 { state.receive(text) }
                else { state.messages.append(Msg(text: text, mine: true)) }
            }
            if !CommandLine.arguments.contains("--idle") {
                state.expanded = true
                state.composerOpen = true
                state.draft = "on my way"
            }
            if CommandLine.arguments.contains("--collapsed") {
                state.collapse()        // messages survive; the UI hides
            }
            win.panel.backgroundColor = NSColor(calibratedWhite: 0.55, alpha: 1)
            try? await Task.sleep(for: .milliseconds(700))
            print("capture: msgs=\(state.messages.count) expanded=\(state.expanded) composerOpen=\(state.composerOpen) showsCloud=\(state.showsCloud)")
            for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
                win.panel.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(450))
                capture(to: "\(prefix)-\(name).png")
            }
            print("snapshots written")
            exit(0)
        }
    }

    /// `cacheDisplay` paints the window's background into the bitmap, which is
    /// why an earlier light-mode capture came out white-on-white. Setting the
    /// panel's background to grey for the capture makes both schemes readable.
    /// `ImageRenderer` is not an option: it renders `ScrollView` contents empty
    /// and `TextField` as an unsupported-view placeholder.
    private func capture(to path: String) {
        guard let view = win.panel.contentView else { return }
        let r = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: r) else { return }
        view.cacheDisplay(in: r, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// Self-reporting for verification: screen-recording permission is not
    /// granted here, so the app describes its own window state.
    private func startDiagnostics() {
        let screen = primaryScreen()
        let p = win.panel
        if let out = Self.argValue("--diagout=") {
            freopen(out, "w", stdout)
            setvbuf(stdout, nil, _IONBF, 0)
        }
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
        state.dragging = true
        tickForDiagnostics()
        print("during drag -> solid=\(state.solid) ignoresMouseEvents=\(p.ignoresMouseEvents)")
        state.dragging = false
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

    func tickForDiagnostics() { tick() }

    private func tick() {
        // Dwell-to-solidify: poll the cursor rather than rely on hover, which a
        // click-through window never receives.
        if state.dragging {                 // never interrupt a drag
            win.panel.ignoresMouseEvents = false
            return
        }
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

    /// Clicking away collapses the whole assembly back to just the pet.
    /// Messages stay alive underneath and reappear when it is opened again.
    private func closeComposer() {
        guard state.composerOpen || state.expanded else { return }
        withAnimation(.easeOut(duration: 0.14)) { state.collapse() }
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

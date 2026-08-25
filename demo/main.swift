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
    static let dwell: TimeInterval = 0.2      // show the assembly
    static let focusDwell: TimeInterval = 0.6 // and only then take the keyboard
    static let linger: TimeInterval = 0.5     // countdown after the cursor leaves
    static let line: CGFloat = 18             // one line of text
    static let bubbleRow: CGFloat = 33        // one short message plus spacing
    static let maxBubbles = 5                 // the cloud stops growing here
    /// Five bubbles tall — plus one line of slack, so five still fit when one
    /// of them wraps — and never more than a third of the screen.
    static func cloudCap(_ screen: NSScreen) -> CGFloat {
        min(CGFloat(maxBubbles) * bubbleRow + 24 + line,
            screen.frame.height / 3 - 2 * line)
    }
    /// Space the composer and action row need beneath the pet.
    static let stackBelow: CGFloat = pet / 2 + gap + bottom
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
    /// Raised when the composer should take the keyboard.
    @Published var focusRequested = false
    @Published var draft = ""
    @Published var messages: [Msg] = []
    @Published var mood: Mood = .idle
    @Published var hovering = false     // cursor dwelling on the pet
    @Published var unread = false
    @Published var dragging = false
    /// The cloud and composer collapse together; messages stay alive underneath.
    @Published var expanded = false
    /// A click pins the assembly open; hovering alone does not.
    @Published var pinned = false
    /// Ticked once a second so ageing bubbles redraw.
    @Published var now = Date()

    /// The pet accepts clicks when it is hovered, open, dragged, or wants
    /// attention. `dragging` is load-bearing: without it a fast drag outruns
    /// the window, the cursor leaves the pet, click-through switches back on
    /// mid-drag and the pet stops receiving the events moving it.
    var solid: Bool { hovering || expanded || unread || dragging }

    var showsCloud: Bool { expanded && !messages.isEmpty }

    func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        messages.append(Msg(text: t, mine: true))
        draft = ""                      // composer stays open, per spec
    }

    /// Opening always reads the pip, however it was opened.
    func expand() {
        expanded = true
        unread = false
    }

    func collapse() {
        Trace.write("collapse msgs=\(messages.count)")
        pinned = false
        expanded = false
        focusRequested = false
        draft = ""
    }

    /// An arriving message shows a pip on the pet. It deliberately does **not**
    /// pop the cloud open — that is unwelcome mid-meeting or mid-screenshare.
    func receive(_ text: String) {
        messages.append(Msg(text: text, mine: false))
        if !expanded { unread = true }
        flash(.petted)
    }

    func flash(_ m: Mood, for seconds: Double = 0.45) {
        mood = m
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if mood == m { mood = .idle }
        }
    }

    /// 1 while fresh, falling towards 0 as the message approaches expiry.
    func life(_ m: Msg, _ ttl: TimeInterval) -> Double {
        let age = now.timeIntervalSince(m.born)
        return max(0, min(1, 1 - age / ttl))
    }

    func expire(_ ttl: TimeInterval) {
        now = Date()
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

    /// AppKit keeps windows on screen by rewriting their frame, which silently
    /// undoes positioning near an edge — the pet would jump back towards the
    /// middle after being placed at the bottom. The assembly is mostly
    /// transparent and clamps its own visible parts, so opt out entirely.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

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
        defer {
            let m = NSEvent.mouseLocation
            Trace.write("move cursor=\(Int(m.x)),\(Int(m.y)) pet=\(Int(petCenter.x)),\(Int(petCenter.y))")
        }
        let f = primaryScreen().frame
        let halfW = L.width / 2
        // The composer and action row need room beneath the pet, so the pet
        // cannot sit right against the bottom edge.
        let below = L.stackBelow
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

    func hitPet(_ mouse: CGPoint) -> Bool {
        let c = petCenter
        return hypot(mouse.x - c.x, mouse.y - c.y) <= L.pet / 2 + 6
    }

    /// While the assembly is open the cursor must be able to travel from the pet
    /// to the composer without counting as "left". Anything inside the panel's
    /// visible column counts.
    func hitAssembly(_ mouse: CGPoint, expanded: Bool) -> Bool {
        if hitPet(mouse) { return true }
        guard expanded else { return false }
        let c = petCenter
        let x = abs(mouse.x - c.x) <= L.width / 2
        let reach = L.gap + L.bottom
        let y = mouse.y <= c.y + cloudCap + L.gap && mouse.y >= c.y - reach
        return x && y
    }
}

// MARK: - Views

struct Bubble: View {
    let msg: Msg
    var life: Double = 1
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
        // Fades across its thirty minutes, so expiry reads as deliberate.
        .opacity(0.35 + 0.65 * life)
    }
}

private struct CloudHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct Cloud: View {
    let messages: [Msg]
    let cap: CGFloat
    let life: (Msg) -> Double
    @State private var content: CGFloat = 0

    /// Inset between the scrolling area and the rounded container. It lives
    /// *outside* the ScrollView so it cannot scroll away — padding placed on the
    /// content itself disappears once you scroll, letting the top bubble run
    /// flush to the edge and square off the corner.
    ///
    /// No fade at the top edge: overflow simply clips at the rounded inner
    /// shape, the way any chat window behaves. The container reads identically
    /// rounded from the first message through to the cap.
    private static let inset: CGFloat = 12
    private static let radius: CGFloat = 18
    /// The tail dots and their spacing sit below the box and come out of the
    /// same budget. Forgetting them made the assembly taller than its region,
    /// so the box overflowed above the panel and its rounded top was sliced off
    /// flat by the window edge.
    private static let tail: CGFloat = 7
    private static let tailGap: CGFloat = 4

    private var rows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(messages) {
                Bubble(msg: $0, life: life($0)).id($0.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A hidden copy at its natural height, purely to measure.
    /// `ViewThatFits` cannot do this job: inside a VStack that also holds a
    /// Spacer it is handed a proposal well short of the cap, so it fell through
    /// to scrolling while the content still had room to grow. Measuring inside
    /// the ScrollView is equally useless — the scroller constrains the very
    /// height it reports back.
    private var ruler: some View {
        rows
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear.preference(key: CloudHeight.self, value: g.size.height)
            })
            .hidden()
            .frame(height: cap, alignment: .top)
            .clipped()
    }

    private var scrollHeight: CGFloat {
        let budget = cap - 2 * Self.inset - Self.tail - Self.tailGap
        return min(max(content, 22), budget)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if !messages.isEmpty {
                VStack(alignment: .leading, spacing: Self.tailGap) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) { rows }
                            .scrollIndicators(.never)
                            .defaultScrollAnchor(.bottom)
                            .onChange(of: messages.count) {
                                if let last = messages.last {
                                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                    }
                    // Grows a bubble at a time, then stops at the cap.
                    .frame(height: scrollHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Self.radius - Self.inset,
                                                style: .continuous))
                    .padding(.vertical, Self.inset)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .fill(.regularMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10)))

                    HStack(spacing: 3) {
                        Circle().frame(width: Self.tail, height: Self.tail)
                        Circle().frame(width: 4, height: 4)
                    }
                    .foregroundStyle(.regularMaterial)
                    .padding(.leading, 22)
                }
            }
        }
        .frame(height: cap, alignment: .bottom)
        .background(ruler)
        .onPreferenceChange(CloudHeight.self) { content = $0 }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: content)
    }
}

struct Pet: View {
    let mood: Mood
    let solid: Bool
    let unread: Bool
    let dragging: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(mood == .sleeping ? 0.22 : 0.42))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25),
                                               lineWidth: 1))
                .overlay(Circle().strokeBorder(
                    Color.accentColor.opacity(solid ? 0.9 : 0), lineWidth: 2.5))
                .frame(width: L.pet, height: L.pet)
                .scaleEffect(mood == .petted ? 1.10 : (dragging ? 1.06 : 1.0))
                // Lifts off the desktop while carried.
                .shadow(color: .black.opacity(dragging ? 0.32 : 0),
                        radius: dragging ? 12 : 0, y: dragging ? 6 : 0)

            if unread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                    .offset(x: L.pet / 2 - 5, y: -L.pet / 2 + 5)
                    .transition(.scale)
            }
            if mood == .sleeping {
                Text("z z")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .offset(x: 26, y: -22)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: mood)
        .animation(.easeOut(duration: 0.14), value: solid)
        .animation(.easeOut(duration: 0.16), value: dragging)
        .contentShape(Circle())
    }
}

struct Assembly: View {
    @ObservedObject var state: PetState
    let win: PetWindow
    let ttl: TimeInterval
    @FocusState private var focused: Bool
    @State private var grab: CGSize?

    /// Driven by the absolute cursor position, never by `translation`.
    /// `translation` is measured in the window's own coordinate space, so moving
    /// the window shifts the baseline the next translation is measured against —
    /// the pet chases the cursor and overshoots.
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

    private func cloud(cap: CGFloat) -> some View {
        Cloud(messages: state.expanded ? state.messages : [],
              cap: cap) { state.life($0, ttl) }
    }

    private var pet: some View {
        Pet(mood: state.mood, solid: state.solid,
            unread: state.unread, dragging: state.dragging)
            .gesture(drag)
            .onTapGesture { pin() }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
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
    }

    var body: some View {
        VStack(spacing: L.gap) {
            cloud(cap: win.cloudCap)
            pet
            VStack(spacing: 0) {
                if state.expanded { controls }
                Spacer(minLength: 0)
            }
            .frame(height: L.bottom, alignment: .top)
        }
        .frame(width: L.width, height: win.height)
        .onChange(of: state.focusRequested) { _, want in focused = want }
        .onChange(of: state.expanded) { _, open in if !open { focused = false } }
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

    /// Clicking pins the assembly open, so it survives the cursor leaving.
    private func pin() {
        Trace.write("pin")
        state.pinned = true
        withAnimation(.easeOut(duration: 0.16)) { state.expand() }
        win.panel.makeKey()
        state.focusRequested = true
    }
}

/// Append-only trace so a synthesised UI drive can be checked afterwards.
@MainActor final class Trace {
    static var handle: FileHandle?
    static func open(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }
    static func write(_ line: String) {
        guard let h = handle, let d = (line + "\n").data(using: .utf8) else { return }
        h.write(d); try? h.synchronize()
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.parse()
    let state = PetState()
    var win: PetWindow!
    var status: NSStatusItem!
    var dwellSince: Date?
    var leftSince: Date?
    var snapshotting = false
    var timer: Timer?
    var escMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        win = PetWindow(config: config)
        win.restore(offset: config.profile == "a" ? 0 : -260)


        let host = NSHostingView(rootView: Assembly(state: state, win: win, ttl: config.expiry))
        host.frame = NSRect(origin: .zero, size: win.panel.frame.size)
        win.panel.contentView = host
        win.panel.orderFrontRegardless()

        buildStatusItem()
        if let t = Self.argValue("--trace=") {
            Trace.open(t)
            Trace.write("start pet=\(Int(win.petCenter.x)),\(Int(win.petCenter.y))")
        }
        if CommandLine.arguments.contains("--diag") { startDiagnostics() }
        if let prefix = Self.argValue("--snapshot=") { startSnapshot(prefix) }

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53, self.state.expanded {
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
        snapshotting = true
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
                state.pinned = true      // pin first: an unpinned assembly
                state.draft = "on my way" // starts the linger countdown
                state.expand()
            }
            if CommandLine.arguments.contains("--collapsed") {
                state.collapse()        // messages survive; the UI hides
            }
            win.panel.backgroundColor = NSColor(calibratedWhite: 0.55, alpha: 1)
            try? await Task.sleep(for: .milliseconds(700))
            print("capture: msgs=\(state.messages.count) expanded=\(state.expanded) pinned=\(state.pinned) draft=\"\(state.draft)\" cap=\(win.cloudCap)")
            for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
                win.panel.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(800))
                print("  \(name): expanded=\(state.expanded) msgs=\(state.messages.count)")
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
        // SwiftUI lays out asynchronously; without forcing a pass the bitmap can
        // catch a frame before the state has been applied.
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        view.displayIfNeeded()
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

            state.draft = "typed by diagnostics"
            state.send()
            try? await Task.sleep(for: .milliseconds(200))
            print("after send -> messages=\(state.messages.count) draft=\"\(state.draft)\" pinned=\(state.pinned)")

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
        // Snapshots stage state directly; the live hover/linger machinery would
        // race them and occasionally capture a collapsed frame.
        if snapshotting { return }
        if state.dragging {                 // never interrupt a drag
            win.panel.ignoresMouseEvents = false
            return
        }
        let inside = win.hitAssembly(NSEvent.mouseLocation, expanded: state.expanded)
        if inside {
            leftSince = nil
            if dwellSince == nil { dwellSince = Date() }
            let held = Date().timeIntervalSince(dwellSince!)
            if held >= L.dwell {
                state.hovering = true
                if !state.expanded {
                    Trace.write("hoverOpen")
                    withAnimation(.easeOut(duration: 0.16)) { state.expand() }
                }
            }
            // Focus is a later, separate step: showing the composer must not
            // swallow a sentence being typed into the user's editor.
            if held >= L.focusDwell && !state.focusRequested {
                win.panel.makeKey()
                state.focusRequested = true
            }
        } else {
            dwellSince = nil
            state.hovering = false
            state.focusRequested = false
            if state.expanded && !state.pinned {
                if leftSince == nil { leftSince = Date() }
                if Date().timeIntervalSince(leftSince!) >= L.linger {
                    Trace.write("lingerCollapse")
                    withAnimation(.easeOut(duration: 0.14)) { state.collapse() }
                    leftSince = nil
                }
            }
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
        Trace.write("outsideClick expandedBefore=\(state.expanded)")
        guard state.expanded else { return }
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

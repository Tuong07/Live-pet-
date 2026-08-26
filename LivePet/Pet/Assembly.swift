// The assembly: thinking cloud above, pet, composer and action row below.
// It is not several windows — the whole thing lives in the one NSPanel.

import AppKit
import SwiftUI

struct Bubble: View {
    let msg: Msg
    let life: Double

    var body: some View {
        HStack(spacing: 0) {
            if msg.mine { Spacer(minLength: 26) }
            Text(msg.text)
                .font(.system(size: 12.5))
                .foregroundStyle(msg.mine ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(msg.mine ? Color.accentColor : Color.primary.opacity(0.12)))
            if !msg.mine { Spacer(minLength: 26) }
        }
        // Dims across its thirty minutes, so expiry reads as deliberate.
        .opacity(0.35 + 0.65 * life)
    }
}

struct Cloud: View {
    let messages: [Msg]
    let cap: CGFloat
    let life: (Msg) -> Double
    @State private var content: CGFloat = 0
    @State private var bottomEdge: CGFloat = 0

    /// Within a few points of the bottom counts as "following the conversation".
    private var isAtBottom: Bool { bottomEdge - scrollHeight < 12 }

    /// The inset lives *outside* the ScrollView so it cannot scroll away.
    /// Padding on the content itself disappears once you scroll, letting the top
    /// message run flush to the edge and square off the corner.
    private static let inset: CGFloat = 12
    private static let radius: CGFloat = 18
    /// The tail dots and their gap come out of the same budget. Forgetting them
    /// made the assembly taller than its region, so the box overflowed above the
    /// panel and its rounded top was sliced flat by the window edge.
    private static let tail: CGFloat = 7
    private static let tailGap: CGFloat = 4

    private var rows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(messages) { Bubble(msg: $0, life: life($0)).id($0.id) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An invisible copy at natural height, purely to measure. Measuring inside
    /// the ScrollView is circular — the scroller constrains the height it
    /// reports back, so the layout settles at a single row.
    ///
    /// The height is read straight from the GeometryReader's callbacks rather
    /// than through a PreferenceKey: a preference set inside a `.background`
    /// does not propagate, so the measurement never arrived and the cloud stayed
    /// stuck at one row.
    private var ruler: some View {
        rows.fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { report(g.size.height) }
                    .onChange(of: g.size.height) { _, h in report(h) }
            })
            .opacity(0)
            .allowsHitTesting(false)
            .frame(height: cap, alignment: .top)
            .clipped()
    }

    private func reportBottom(_ v: CGFloat) {
        guard abs(v - bottomEdge) > 0.5 else { return }
        DispatchQueue.main.async { bottomEdge = v }
    }

    private func report(_ h: CGFloat) {
        guard abs(h - content) > 0.5 else { return }
        DispatchQueue.main.async { content = h }   // never mutate during layout
    }

    private var scrollHeight: CGFloat {
        min(max(content, 22), cap - 2 * Self.inset - Self.tail - Self.tailGap)
    }

    var body: some View {
        // The ruler is a ZStack sibling, not a `.background`: a background does
        // not propagate preferences, so the measurement never reached
        // onPreferenceChange and the cloud stayed stuck at one row.
        ZStack(alignment: .bottom) {
            ruler
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !messages.isEmpty {
                    VStack(alignment: .leading, spacing: Self.tailGap) {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                rows.background(GeometryReader { g in
                                    Color.clear
                                        .onAppear { reportBottom(g.frame(in: .named("cloud")).maxY) }
                                        .onChange(of: g.frame(in: .named("cloud")).maxY) { _, v in
                                            reportBottom(v)
                                        }
                                })
                            }
                            .coordinateSpace(name: "cloud")
                            .scrollIndicators(.never)
                            .defaultScrollAnchor(.bottom)
                            .onChange(of: messages.count) {
                                // If you have scrolled up to reread something, a
                                // new message must not yank you back down. The
                                // pet still animates, so you know it arrived.
                                Trace.write("autoscroll atBottom=\(isAtBottom) edge=\(Int(bottomEdge)) viewport=\(Int(scrollHeight))")
                                guard isAtBottom, let last = messages.last else { return }
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .frame(height: scrollHeight)
                        .clipShape(RoundedRectangle(cornerRadius: Self.radius - Self.inset,
                                                    style: .continuous))
                        .padding(.vertical, Self.inset)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .fill(.regularMaterial))
                        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
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
        }
        .frame(height: cap, alignment: .bottom)
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
                .fill(Color.primary.opacity(mood == .dozing || mood == .sleeping ? 0.22 : 0.42))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(solid ? 0.9 : 0),
                                               lineWidth: 2.5))
                .frame(width: L.pet, height: L.pet)
                .scaleEffect(scale)
                // Lifts while dragged, so it reads as picked up by an invisible
                // hand rather than sliding along the desktop.
                .shadow(color: .black.opacity(dragging ? 0.30 : 0),
                        radius: dragging ? 12 : 0, y: dragging ? 6 : 0)

            if mood == .sleeping || mood == .dozing {
                Text(mood == .sleeping ? "z z" : "z")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .offset(x: 26, y: -22)
            }
            if unread {
                Circle().fill(Color.accentColor)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    .offset(x: L.pet / 2 - 6, y: -L.pet / 2 + 6)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: mood)
        .animation(.easeOut(duration: 0.14), value: solid)
        .animation(.easeOut(duration: 0.16), value: dragging)
        .contentShape(Circle())
    }

    private var scale: CGFloat {
        if dragging { return 1.08 }
        return mood == .petted || mood == .alert ? 1.10 : 1.0
    }
}

struct Assembly: View {
    @ObservedObject var session: Session
    let win: PetWindow
    @FocusState private var focused: Bool
    @State private var grab: CGSize?

    /// Driven by the absolute cursor position, never by `translation`, which is
    /// measured in the window's own coordinate space — moving the window shifts
    /// the baseline and the pet chases the cursor.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in
                let m = NSEvent.mouseLocation
                if grab == nil {
                    let c = win.petCenter
                    grab = CGSize(width: c.x - m.x, height: c.y - m.y)
                    session.dragging = true
                }
                guard let g = grab else { return }
                win.setPetCenter(CGPoint(x: m.x + g.width, y: m.y + g.height))
            }
            .onEnded { _ in
                grab = nil
                session.dragging = false
                session.didDrop()          // syncs on drop, not during the drag
            }
    }

    var body: some View {
        VStack(spacing: L.gap) {
            Cloud(messages: session.showsCloud ? session.messages : [],
                  cap: win.cloudCap,
                  life: { $0.life(now: session.now, ttl: session.ttl) })

            Pet(mood: session.mood, solid: session.solid,
                unread: session.unread, dragging: session.dragging)
                .gesture(drag)
                .onTapGesture {
                    // Clicking pins it open — but only if it opened at all.
                    if session.open(focusKeyboard: true) { session.pinned = true }
                }

            VStack(spacing: 8) {
                if session.composerOpen {
                    composer
                    HStack(spacing: 6) {
                        ForEach(PetAction.enabled) { a in
                            pill(a.id) { session.perform(a) }
                                .opacity(session.canSend ? 1 : 0.4)
                        }
                        pill("move") {}.gesture(drag)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: L.bottom, alignment: .top)
        }
        .frame(width: L.width, height: win.height)
        .onChange(of: session.composerOpen) { _, open in
            if !open { focused = false }
        }
    }

    private var composer: some View {
        Group {
            if session.canSend {
                TextField("say something…", text: $session.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { session.send() }
            } else {
                // You cannot type into the void.
                Text(session.connection == .unpaired
                     ? "not paired yet"
                     : "\(session.partnerName) is away")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
        .frame(width: 236)
        .onExitCommand { session.collapse() }
    }

    private func pill(_ title: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Text(title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    /// Called by the app when a deliberate hover should take the keyboard.
    func takeFocus() { focused = true }
}

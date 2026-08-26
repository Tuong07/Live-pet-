// The window. Borderless, non-activating, above fullscreen apps, on every
// Space, main display only.

import AppKit
import SwiftUI

enum L {
    static let width: CGFloat = 320
    static let pet: CGFloat = 72
    static let gap: CGFloat = 10
    static let bottom: CGFloat = 210
    static let dwell: TimeInterval = 0.2      // hover opens
    static let focusDwell: TimeInterval = 0.6 // deliberate hover takes the keyboard
    static let linger: TimeInterval = 0.5     // countdown after the cursor leaves
    static let maxBubbles = 5

    static func cloudCap(_ screen: NSScreen) -> CGFloat {
        min(207, screen.frame.height / 3)
    }
}

/// The spec says the pet lives on the **main display**. `NSScreen.main` is the
/// screen holding keyboard focus, which drifts as you switch windows.
@MainActor func primaryScreen() -> NSScreen { NSScreen.screens.first ?? NSScreen.main! }

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetWindow {
    let panel: PetPanel
    let store: Store
    let cloudCap: CGFloat
    let height: CGFloat
    let petFromTop: CGFloat

    /// When the last local move happened. Newer `pos_ts` wins on reconnect.
    private(set) var posTS: Int64

    init(store: Store) {
        self.store = store
        let screen = primaryScreen()
        cloudCap = L.cloudCap(screen)
        petFromTop = cloudCap + L.gap + L.pet / 2
        height = cloudCap + L.gap + L.pet + L.gap + L.bottom
        posTS = store.position.ts

        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: L.width, height: height),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
    }

    var petCenter: CGPoint {
        let o = panel.frame.origin
        return CGPoint(x: o.x + L.width / 2, y: o.y + height - petFromTop)
    }

    /// Clamped so the assembly stays on screen — the full panel width, and the
    /// composer's room below the pet.
    func setPetCenter(_ p: CGPoint) {
        let f = primaryScreen().frame
        let halfW = L.width / 2
        let below = L.pet / 2 + L.gap + L.bottom
        let above = L.pet / 2 + 4
        let x = min(max(p.x, f.minX + halfW), f.maxX - halfW)
        let y = min(max(p.y, f.minY + below), f.maxY - above)
        panel.setFrameOrigin(NSPoint(x: x - halfW, y: y - height + petFromTop))
    }

    /// Position is a fraction of the screen, so it lands in the same relative
    /// spot on a 13" laptop and a 27" display.
    var relative: (x: Double, y: Double) {
        let f = primaryScreen().frame
        let c = petCenter
        return (Double((c.x - f.minX) / f.width), Double((c.y - f.minY) / f.height))
    }

    func setRelative(x: Double, y: Double, animated: Bool = false) {
        let f = primaryScreen().frame
        let target = CGPoint(x: f.minX + CGFloat(x) * f.width,
                             y: f.minY + CGFloat(y) * f.height)
        guard animated else { setPetCenter(target); return }
        // The peer's pet animates from its old spot to the new one, so it reads
        // as "someone moved it" rather than teleporting.
        let from = petCenter
        let steps = 26
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.012 * Double(i)) { [weak self] in
                self?.setPetCenter(CGPoint(x: from.x + (target.x - from.x) * eased,
                                           y: from.y + (target.y - from.y) * eased))
            }
        }
    }

    func markMoved(ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) { posTS = ts }

    func save() {
        let r = relative
        store.savePosition(x: r.x, y: r.y, at: posTS)
    }

    func restore(devOffset: CGFloat) {
        let p = store.position
        let f = primaryScreen().frame
        setPetCenter(CGPoint(x: f.minX + CGFloat(p.x) * f.width + devOffset,
                             y: f.minY + CGFloat(p.y) * f.height))
    }

    func hit(_ mouse: CGPoint) -> Bool {
        let c = petCenter
        return hypot(mouse.x - c.x, mouse.y - c.y) <= L.pet / 2 + 4
    }

    /// The hit test must cover the whole visible assembly, or moving the cursor
    /// from the pet down to the composer counts as leaving.
    func hitAssembly(_ mouse: CGPoint, expanded: Bool) -> Bool {
        if hit(mouse) { return true }
        guard expanded else { return false }
        return panel.frame.insetBy(dx: -6, dy: -6).contains(mouse)
    }
}

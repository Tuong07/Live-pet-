// Posts real scroll-wheel events over the cloud, so the "don't yank the scroll"
// guard can be checked end to end rather than by reading the code.
import CoreGraphics
import Foundation

let a = CommandLine.arguments
let petX = Double(a[1])!, petY = Double(a[2])!   // screen coords, bottom-left origin
let H = CGDisplayBounds(CGMainDisplayID()).height
// The cloud sits above the pet; aim well inside it.
let point = CGPoint(x: petX, y: H - (petY + 110))

CGWarpMouseCursorPosition(point)
CGAssociateMouseAndMouseCursorPosition(1)
usleep(700_000)

for _ in 0..<12 {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0)
    e?.location = point
    e?.post(tap: .cghidEventTap)
    usleep(40_000)
}
print("scrolled up at \(point)")

// GestureEvent -> CGEvent. The "what does it feel like" layer; every constant
// here is a tuning knob to calibrate on hardware, not derived truth.
#if os(macOS)
import CoreGraphics
import T650Kit

final class Output {
    var cursorGain = 1.6        // device units -> pixels
    var scrollGain = 0.35
    var buttonDown = false

    func post(_ e: GestureEvent) {
        switch e {
        case let .move(dx, dy):
            let cur = CGEvent(source: nil)?.location ?? .zero
            let p = CGPoint(x: cur.x + dx * cursorGain, y: cur.y + dy * cursorGain)
            let type: CGEventType = buttonDown ? .leftMouseDragged : .mouseMoved
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        case let .scroll(dx, dy):
            let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: Int32(-dy * scrollGain), wheel2: Int32(-dx * scrollGain), wheel3: 0)
            ev?.post(tap: .cghidEventTap)
        case .buttonDown:
            click(down: true)          // held: enables physical click-and-drag
        case .buttonUp:
            click(down: false)
        case .tap(fingers: 1):
            click(down: true); click(down: false)
        case .tap(fingers: 2):
            rightClick()
        case .tap:
            break
        case let .swipe(fingers, dx, dy):
            swipeAction(fingers: fingers, dx: dx, dy: dy)
        case let .pinch(scale):
            key(scale > 1 ? 0x18 : 0x1B, flags: .maskCommand)  // cmd-= / cmd--
        }
    }

    private func click(down: Bool) {
        buttonDown = down
        let cur = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: cur, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func rightClick() {
        let cur = CGEvent(source: nil)?.location ?? .zero
        for t in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: cur,
                    mouseButton: .right)?.post(tap: .cghidEventTap)
        }
    }

    private func swipeAction(fingers: Int, dx: Double, dy: Double) {
        let horizontal = abs(dx) > abs(dy)
        switch (fingers, horizontal) {
        case (3, true):  key(dx > 0 ? 0x7C : 0x7B, flags: .maskControl)  // ctrl-arrow: switch space
        case (3, false): key(dy < 0 ? 0x7E : 0x7D, flags: .maskControl)  // ctrl-up/down: Mission Control / App Exposé
        case (4, _), (5, _): key(0x7E, flags: .maskControl)
        default: break
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
        }
    }
}
#endif

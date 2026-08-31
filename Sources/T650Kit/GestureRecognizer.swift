import Foundation

/// Contact frames -> gesture intents. Pure logic, host-agnostic.
///
/// Model: a touch "session" runs from first contact down to all contacts up.
/// Within a session the finger count may ramp (fingers land one frame apart),
/// so classification uses the max simultaneous count seen.

public enum GestureEvent: Equatable {
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double)
    case pinch(scale: Double)               // multiplicative per-event factor
    case tap(fingers: Int)
    case swipe(fingers: Int, dx: Double, dy: Double)  // one event per session
    case buttonDown
    case buttonUp
}

public struct GestureRecognizer {
    // Tunables — calibration knobs, not device constants (spec §5.4).
    public var tapMaxDuration = 300.0        // ms, hardware-clock units
    public var tapMaxTravel = 60.0           // device units (~2.6 mm)
    public var swipeMinTravel = 250.0        // device units (~11 mm)
    public var pinchMinRatio = 0.015         // per-frame distance change to call it a pinch

    private var session: Session?
    private var buttonHeld = false

    private struct Session {
        var startTimestamp: Int
        var maxFingers = 0
        var totalDX = 0.0, totalDY = 0.0
        var swipeSent = false
        var last: [Int: Contact] = [:]       // keyed by fingerID — ids are sparse (spec §3.5)
        var lastPairDistance: Double?
    }

    public init() {}

    public mutating func handle(_ frame: TouchFrame) -> [GestureEvent] {
        var events: [GestureEvent] = []

        if frame.button != buttonHeld {
            buttonHeld = frame.button
            events.append(buttonHeld ? .buttonDown : .buttonUp)
        }

        guard !frame.contacts.isEmpty else {
            if let s = session { events += endSession(s, at: frame.timestamp) }
            session = nil
            return events
        }

        var s = session ?? Session(startTimestamp: frame.timestamp)
        s.maxFingers = max(s.maxFingers, frame.contacts.count)

        // Mean delta over contacts tracked since last frame.
        var dx = 0.0, dy = 0.0, tracked = 0
        for c in frame.contacts {
            if let p = s.last[c.fingerID] {
                dx += Double(c.x - p.x); dy += Double(c.y - p.y); tracked += 1
            }
        }
        if tracked > 0 { dx /= Double(tracked); dy /= Double(tracked) }
        s.totalDX += dx; s.totalDY += dy

        switch (s.maxFingers, frame.contacts.count) {
        case (1, _):
            if tracked > 0 { events.append(.move(dx: dx, dy: dy)) }
        case (2, 2):
            let a = frame.contacts[0], b = frame.contacts[1]
            let dist = Double(((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))).squareRoot()
            if let prev = s.lastPairDistance, prev > 0 {
                let ratio = dist / prev
                if abs(ratio - 1) > pinchMinRatio {
                    events.append(.pinch(scale: ratio))
                } else if tracked > 0 {
                    events.append(.scroll(dx: dx, dy: dy))
                }
            }
            s.lastPairDistance = dist
        default:
            // 3+ fingers: emit one swipe when travel crosses the threshold.
            if !s.swipeSent, (s.totalDX * s.totalDX + s.totalDY * s.totalDY).squareRoot() >= swipeMinTravel {
                s.swipeSent = true
                events.append(.swipe(fingers: s.maxFingers, dx: s.totalDX, dy: s.totalDY))
            }
        }

        s.last = Dictionary(uniqueKeysWithValues: frame.contacts.map { ($0.fingerID, $0) })
        session = s
        return events
    }

    private func endSession(_ s: Session, at timestamp: Int) -> [GestureEvent] {
        let duration = Double((timestamp - s.startTimestamp + 65536) % 65536)
        let travel = (s.totalDX * s.totalDX + s.totalDY * s.totalDY).squareRoot()
        if duration <= tapMaxDuration, travel <= tapMaxTravel, !buttonHeld {
            return [.tap(fingers: s.maxFingers)]
        }
        return []
    }
}

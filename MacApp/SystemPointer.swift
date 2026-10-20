import AppKit
import CoreGraphics
import WristCore

/// The single native pointer/click output. `eligible` must recheck authentication,
/// system scope, permission and protected data immediately before every submission.
final class SystemPointer {
    enum Event: Equatable {
        case move(PointerPoint)
        case down(PointerButton, PointerPoint, Int)
        case up(PointerButton, PointerPoint, Int)
    }
    var eligible: () -> Bool
    var interval: () -> Double
    var cursor: () -> PointerPoint
    private let submit: (Event) -> Bool
    private let preparePair: ((PointerButton, PointerPoint, Int) -> (() -> Bool, () -> Bool)?)?
    private var clicks = ClickSequence()
    private let journal: Journal
    private(set) var movementPosts = 0
    private(set) var clickPosts = 0
    init(journal: Journal, eligible: @escaping () -> Bool = { false },
         interval: @escaping () -> Double = { NSEvent.doubleClickInterval },
         cursor: @escaping () -> PointerPoint = {
             let p = CGEvent(source: nil)?.location ?? .zero
             return PointerPoint(x: p.x, y: p.y)
         }, submit: ((Event) -> Bool)? = nil) {
        self.journal = journal; self.eligible = eligible; self.interval = interval
        self.cursor = cursor; self.submit = submit ?? SystemPointer.submitEvent
        preparePair = submit == nil ? SystemPointer.prepareNativePair : nil
    }
    func reset(session: UInt64) { clicks.reset(session: session) }
    func breakClickPair() { clicks.breakPair() }
    func move(to point: PointerPoint) -> Bool {
        guard point.isFinite, eligible() else { return false }
        clicks.breakPair()
        guard submit(.move(point)) else { return false }
        movementPosts += 1; return true
    }
    func click(_ request: ClickRequest, session: UInt64, at point: PointerPoint, now: Double) -> Bool {
        guard let count = clicks.consume(request, session: session, at: point, macTime: now, interval: interval()) else { return false }
        let pair: (() -> Bool, () -> Bool)
        if let preparePair {
            guard let prepared = preparePair(request.button, point, count) else { clicks.breakPair(); return false }
            pair = prepared
        } else {
            pair = ({ self.submit(.down(request.button, point, count)) },
                    { self.submit(.up(request.button, point, count)) })
        }
        guard eligible() else { clicks.breakPair(); return false }
        guard pair.0() else { clicks.breakPair(); return false }
        // A gate change cannot leave a button held. Recheck, then issue exactly one
        // matching release as bounded cleanup even when permission was just revoked.
        let stillEligible = eligible()
        let released = pair.1()
        if !released || !stillEligible { clicks.breakPair() }
        clickPosts += 1
        journal.record("click_submitted", detail: "request=\(request.id);count=\(count);release=\(released);eligible_at_release=\(stillEligible);recipient_not_observed")
        return released && stillEligible
    }
    private static func prepareNativePair(_ button: PointerButton, _ point: PointerPoint, _ count: Int) -> (() -> Bool, () -> Bool)? {
        let position = CGPoint(x: point.x, y: point.y)
        let nativeButton: CGMouseButton = button == .left ? .left : .right
        guard let down = CGEvent(mouseEventSource: nil, mouseType: button == .left ? .leftMouseDown : .rightMouseDown,
                                 mouseCursorPosition: position, mouseButton: nativeButton),
              let up = CGEvent(mouseEventSource: nil, mouseType: button == .left ? .leftMouseUp : .rightMouseUp,
                               mouseCursorPosition: position, mouseButton: nativeButton) else { return nil }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        return ({ down.post(tap: .cghidEventTap); return true }, { up.post(tap: .cghidEventTap); return true })
    }
    private static func submitEvent(_ action: Event) -> Bool {
        let kind: CGEventType; let button: CGMouseButton; let point: PointerPoint; let count: Int
        switch action {
        case .move(let p): kind = .mouseMoved; button = .left; point = p; count = 0
        case .down(let b, let p, let c):
            kind = b == .left ? .leftMouseDown : .rightMouseDown; button = b == .left ? .left : .right; point = p; count = c
        case .up(let b, let p, let c):
            kind = b == .left ? .leftMouseUp : .rightMouseUp; button = b == .left ? .left : .right; point = p; count = c
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: kind,
                                 mouseCursorPosition: CGPoint(x: point.x, y: point.y), mouseButton: button) else { return false }
        if count > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(count)) }
        event.post(tap: .cghidEventTap); return true
    }
}

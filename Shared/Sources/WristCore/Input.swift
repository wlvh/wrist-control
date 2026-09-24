import Foundation

public struct CrownDelta {
    public static let lower = -1000.0
    public static let upper = 1000.0
    private var previous: Double?
    public init() {}
    public mutating func rebase(to position: Double? = nil) {
        previous = position.flatMap { $0.isFinite && (Self.lower...Self.upper).contains($0) ? $0 : nil }
    }
    public mutating func update(_ position: Double) -> Double? {
        guard position.isFinite, (Self.lower...Self.upper).contains(position) else {
            previous = nil; return nil
        }
        defer { previous = position }
        guard let old = previous else { return nil }
        var delta = position - old
        let period = Self.upper - Self.lower
        if delta > period / 2 { delta -= period }
        if delta < -period / 2 { delta += period }
        // Focus resets and discontinuities must never become page-sized jumps.
        guard abs(delta) <= 4 else { return nil }
        return delta
    }
}

/// At most one unsent scroll intent. No backlog survives a reversal, idle, or disconnect.
public struct ScrollBuffer {
    private var value: Int64 = 0
    private var began: TimeInterval?
    public static let maxAge: TimeInterval = 0.08
    public init() {}
    public mutating func clear() { value = 0; began = nil }
    public mutating func add(_ amount: Int32, now: TimeInterval) {
        guard amount != 0 else { return }
        if let start = began, now < start || now - start > Self.maxAge { clear() }
        if value != 0 && (value > 0) != (amount > 0) { clear() }
        if began == nil { began = now }
        value = max(-737_280, min(737_280, value + Int64(amount))) // 720 points maximum
    }
    public mutating func take(now: TimeInterval) -> Int32? {
        defer { clear() }
        guard let start = began, now >= start, now - start <= Self.maxAge, value != 0 else { return nil }
        return Int32(value)
    }
}

/// Mac-issued tickets expire on the MAC clock. No clock synchronization is assumed.
/// Limits delayed BLE actions even if the connection stays nominally alive.
public struct SessionGate {
    public private(set) var session: UInt64 = 0
    public private(set) var lastSequence: UInt32 = 0
    public private(set) var currentTicket: UInt16 = 0
    private var tickets: [UInt16: TimeInterval] = [:]
    public static let lifetime: TimeInterval = 0.35
    public init() {}
    public mutating func begin(_ session: UInt64) {
        self.session = session; lastSequence = 0; tickets = [:]; currentTicket = 0
    }
    public mutating func revoke() { begin(0) }
    public mutating func issue(now: TimeInterval) -> UInt16 {
        tickets = tickets.filter { now >= $0.value && now - $0.value <= Self.lifetime }
        currentTicket = currentTicket == UInt16.max ? 1 : currentTicket + 1
        tickets[currentTicket] = now
        return currentTicket
    }
    public mutating func accept(_ frame: Frame, now: TimeInterval, targetReady: Bool) -> String? {
        // Pause/resume must remain reachable while output is paused. Authentication
        // is checked by the transport before this gate is called.
        guard targetReady || frame.kind == .setControl else { return "target_unavailable" }
        guard session != 0, frame.session == session else { return "old_session" }
        guard [.scroll, .idle, .setControl].contains(frame.kind) else { return "invalid_action" }
        guard frame.sequence > lastSequence else { return "duplicate_or_reordered" }
        guard let issued = tickets[frame.ticket], now >= issued, now - issued <= Self.lifetime else { return "expired_ticket" }
        guard frame.kind != .scroll || abs(Int64(frame.value)) <= 737_280 else { return "oversized_scroll" }
        guard frame.kind == .scroll || (frame.kind == .setControl ? (0...1).contains(frame.value) : frame.value == 0) else { return "invalid_value" }
        lastSequence = frame.sequence
        return nil
    }
}

/// CGEvent takes integer pixels. Preserve fractions during a stroke, discard the
/// previous direction's remainder immediately on reversal, and never drain later.
public struct WheelAccumulator {
    private var remainder = 0.0
    private var direction = 0
    public init() {}
    public mutating func reset() { remainder = 0; direction = 0 }
    public mutating func consume(points: Double) -> Int32? {
        guard points.isFinite, abs(points) <= 720 else { reset(); return nil }
        guard points != 0 else { return 0 }
        let next = points > 0 ? 1 : -1
        if next != direction { remainder = 0 }
        direction = next
        let amount = points + remainder
        let whole = amount.rounded(.towardZero)
        remainder = amount - whole
        return Int32(whole)
    }
}

public struct ControlState: OptionSet, Equatable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let enabled = Self(rawValue: 1)
    public static let permission = Self(rawValue: 2)
    public static let interactive = Self(rawValue: 4)
    public static let ready: Self = [.enabled, .permission, .interactive]
    public var canScroll: Bool { contains(.ready) }
}

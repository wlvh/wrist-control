import AppKit
import CoreGraphics
import WristCore

/// The only system-input output. No event tap, target PID, cursor movement,
/// keyboard events, app activation, or page inspection.
final class SystemWheel {
    var enabled = false
    var awake = true
    var displayAwake = true
    var sessionActive = true
    var protectionAvailable = true
    var onEligibilityLost: (() -> Void)?
    let journal: Journal
    private let permission: () -> Bool
    private let protectedData: () -> (available: Bool, status: Int32)
    private let submit: (Int32) -> Bool
    private var accumulator = WheelAccumulator()
    private var previousState: ControlState = []
    private(set) var postedCount = 0
    private(set) var lastKeyStatus: Int32 = 0

    init(journal: Journal,
         permission: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         protectedData: @escaping () -> (available: Bool, status: Int32) = {
             let key = PairingKeyStore.read()
             return (NSApp.isProtectedDataAvailable && key.data != nil, key.status)
         }, submit: @escaping (Int32) -> Bool = SystemWheel.submitEvent) {
        self.journal = journal; self.permission = permission
        self.protectedData = protectedData; self.submit = submit
    }

    func state() -> ControlState {
        var state: ControlState = []
        if enabled { state.insert(.enabled) }
        if permission() { state.insert(.permission) }
        let protected = protectedData()
        lastKeyStatus = protected.status
        if awake, displayAwake, sessionActive, protectionAvailable, protected.available {
            state.insert(.interactive)
        }
        if state != previousState {
            accumulator.reset()
            let lost = previousState.canScroll && !state.canScroll
            journal.record("output_eligibility", detail: "flags=\(state.rawValue);key_status=\(protected.status);protected_data=\(protected.available)")
            previousState = state
            // Publish after storing the state: the callback can synchronously
            // recheck it while replacing the BLE control session.
            if lost { onEligibilityLost?() }
        }
        return state
    }

    func reset() { accumulator.reset() }

    func setEnabled(_ value: Bool) {
        enabled = value; reset()
        journal.record("control_enabled", detail: String(value))
    }

    func post(points: Double) -> Bool {
        // Recheck at each output, including the actual protected data read. No
        // cached permission or unlock result can authorize a later action.
        let began = ProcessInfo.processInfo.systemUptime
        guard state().canScroll, let pixels = accumulator.consume(points: points) else {
            reset(); return false
        }
        guard pixels != 0 else { return true }
        guard submit(pixels) else {
            reset(); return false
        }
        postedCount += 1
        journal.record("system_scroll_posted", detail: "pixels=\(pixels);check_to_post_ms=\((ProcessInfo.processInfo.systemUptime - began) * 1000);recipient_not_observed")
        return true // submitted to macOS, not proof of a visible scroll
    }

    func requestPermission() { _ = CGRequestPostEventAccess() }

    private static func submitEvent(_ pixels: Int32) -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0) else { return false }
        // Current pointer location, no pointer warp or phase/momentum events.
        event.post(tap: .cghidEventTap)
        return true
    }
}

/// The live WatchModel uses this state for acknowledgements. A rejected earlier
/// action cannot consume a later total-pause request or strand "preparing".
public struct WatchIntentState {
    public var cycle: UInt32 = 0
    public var phase: PointerPhase = .paused
    public var desiredControl: Bool?
    public init() {}
    public mutating func confirm(cycle incoming: UInt32, phase: PointerPhase) {
        guard desiredControl == nil, incoming >= cycle else { return }
        cycle = incoming; self.phase = phase
    }
    public mutating func reject(kind: MessageKind, actionCycle: UInt32, controlEnabled: Bool) {
        if kind == .setControl { desiredControl = nil }
        if kind == .startMovement, actionCycle == cycle {
            phase = desiredControl == false || !controlEnabled ? .paused : .reading
        }
    }
}

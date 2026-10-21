import Foundation

/// Runs in the real output path. Consuming an ID precedes posting, so an uncertain
/// or partially submitted click is never retried. A second tap adds one pair only.
public struct ClickSequence {
    private var session: UInt64 = 0
    private var highestID: UInt64 = 0
    private var candidate: (watch: Double, mac: Double, point: PointerPoint)?
    public init() {}
    public mutating func reset(session: UInt64) {
        self.session = session; highestID = 0; candidate = nil
    }
    public mutating func breakPair() { candidate = nil }
    public mutating func consume(_ request: ClickRequest, session: UInt64, at point: PointerPoint,
                                 macTime: Double, interval: Double) -> Int? {
        guard session != 0, session == self.session, request.id > highestID else { return nil }
        highestID = request.id
        guard point.isFinite, request.watchTime.isFinite, request.watchTime >= 0,
              macTime.isFinite, interval.isFinite, interval > 0, interval <= 3 else {
            candidate = nil; return nil
        }
        guard request.button == .left else { candidate = nil; return 1 }
        let old = candidate
        candidate = (request.watchTime, macTime, point)
        if let old, request.watchTime > old.watch,
           request.watchTime - old.watch <= interval, macTime > old.mac,
           macTime - old.mac <= interval, point == old.point {
            candidate = nil // third tap starts a new pair, never a generated triple
            return 2
        }
        return 1
    }
}

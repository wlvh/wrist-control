import CoreMotion
import WatchKit
import WristCore

/// One foreground sensor stream shared by all modes. UI/BLE take the newest
/// orientation snapshot; no relative displacement is discarded in this buffer.
final class WatchMotion {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .userInteractive
        return q
    }()
    private let lock = NSLock()
    private var newest: AttitudeSample?
    private var generation: UInt64 = 0
    private var sequence: UInt32 = 0
    private(set) var wear = WearConfiguration()
    private var callbackCount = 0
    private var invalidCount = 0
    var available: Bool { manager.isDeviceMotionAvailable }

    func start() {
        let device = WKInterfaceDevice.current()
        let config = WearConfiguration(wrist: device.wristLocation == .left ? .left : .right,
                                       crown: device.crownOrientation == .left ? .left : .right)
        if manager.isDeviceMotionActive, config == wear { return }
        stop(); wear = config
        guard available, CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) else { return }
        let reference = UInt64.random(in: 1...UInt64.max)
        lock.lock(); generation = reference; sequence = 0; lock.unlock()
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let q = motion.attitude.quaternion
            let orientation = AttitudeQuaternion(w: q.w, x: q.x, y: q.y, z: q.z)
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.generation == reference else { return }
            self.callbackCount += 1
            guard orientation.normalized != nil, self.sequence < UInt32.max else {
                self.invalidCount += 1; self.newest = nil; return
            }
            self.sequence += 1
            self.newest = AttitudeSample(reference: .arbitraryZVertical, referenceID: reference,
                sequence: self.sequence, watchTime: motion.timestamp, attitude: orientation, wear: config)
        }
    }
    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock(); generation = 0; newest = nil; lock.unlock()
    }
    func latest() -> AttitudeSample? {
        lock.lock(); defer { lock.unlock() }; return newest
    }
    func statistics() -> (samples: Int, invalid: Int) {
        lock.lock(); defer { lock.unlock() }
        let counts = (callbackCount, invalidCount); callbackCount = 0; invalidCount = 0; return counts
    }
}

import AppKit
import WristCore

/// Own-window capture only. The host must enter OutputScope.calibration before
/// showing this controller, forward its existing pose stream, and return to
/// reading after completion/cancellation. No BLE, motion source, or CGEvent here.
@MainActor
public final class CalibrationWindowController: NSWindowController, NSWindowDelegate {
    public let pointerScreen: PointerScreen
    public private(set) var cancellationReason: String?
    private let canvas: CalibrationCanvas
    private var onCompletion: ((PointingCalibration?) -> Void)?
    private var draft: PointingCalibrationDraft
    private var binding: CalibrationBinding?
    private var collector: StableAttitudeCollector?
    private var model: PointingCalibration?
    private var latestSample: AttitudeSample?
    private var lastReceivedAtMac: Double?
    private var timer: Timer?
    private var currentPoint = 0
    private var phase = Phase.waiting
    private var countdownMessage = "对准目标，保持手臂支撑"
    private var finished = false

    private enum Phase { case waiting, countdown(Double), collecting, feedback(Double), completed }

    /// appKitFrame is the selected NSScreen.frame, whereas pointerScreen contains
    /// CGDisplayBounds logical coordinates. Do not multiply either by scale.
    public init(screen: PointerScreen, appKitFrame: NSRect,
                onCompletion: @escaping (PointingCalibration?) -> Void) {
        pointerScreen = screen; draft = PointingCalibrationDraft(screen: screen)
        canvas = CalibrationCanvas(frame: NSRect(origin: .zero, size: appKitFrame.size))
        self.onCompletion = onCompletion
        let window = CalibrationCaptureWindow(contentRect: appKitFrame, styleMask: [.borderless],
                                               backing: .buffered, defer: false)
        window.title = "腕控 · D 五点标定"
        window.isReleasedWhenClosed = false; window.backgroundColor = .windowBackgroundColor
        window.contentView = canvas; window.setFrame(appKitFrame, display: false)
        super.init(window: window)
        window.delegate = self
        canvas.cancelButton.target = self; canvas.cancelButton.action = #selector(cancelPressed)
        canvas.restartButton.target = self; canvas.restartButton.action = #selector(restartPressed)
        canvas.completeButton.target = self; canvas.completeButton.action = #selector(completePressed)
        canvas.status.stringValue = "等待手表传来新的姿态；全程无需触碰手表确认"
        canvas.target = PointingCalibration.targets[0]
        if !screen.isValid || abs(appKitFrame.width-screen.width) > 1 || abs(appKitFrame.height-screen.height) > 1 {
            cancellationReason = "屏幕逻辑尺寸不一致，请重新选择标定屏幕"
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func showWindow(_ sender: Any?) {
        guard !finished else { return }
        if let reason = cancellationReason { invalidate(reason: reason); return }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        if timer == nil {
            let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }

    /// receivedAtMac must be a Mac monotonic timestamp, taken on reception.
    /// It is never subtracted from sample.watchTime.
    public func ingest(sample: AttitudeSample, receivedAtMac: Double) {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard receivedAtMac.isFinite, now-receivedAtMac >= -0.005,
              now-receivedAtMac <= MotionLimits.maxQueueAge else {
            retryCurrent(reason: "姿态在电脑队列中过期，等待新的采样"); return
        }
        guard sample.isValid, DirectionFeatures(sample: sample) != nil else {
            retryCurrent(reason: CalibrationFailure.invalidSample.description); return
        }
        if let binding, !binding.matches(screen: pointerScreen, sample: sample) {
            invalidate(reason: CalibrationFailure.contextChanged.description); return
        }
        if let lastReceivedAtMac, receivedAtMac < lastReceivedAtMac {
            retryCurrent(reason: "电脑接收顺序发生变化，重采当前点"); return
        }
        if binding == nil { binding = CalibrationBinding(screen: pointerScreen, sample: sample) }
        latestSample = sample; lastReceivedAtMac = receivedAtMac
        switch phase {
        case .waiting:
            startCountdown(message: countdownMessage)
        case .collecting:
            do {
                guard let window = try collector?.append(sample: sample, screen: pointerScreen) else {
                    updateSamplingProgress(); return
                }
                try draft.record(window: window, at: currentPoint)
                collector = nil
                canvas.acceptedPoints = draft.observations.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
                canvas.sampleProgress = 1
                canvas.status.stringValue = String(format: "第 %d 点已采集 · %.1f Hz · 最大偏离 %.2f°",
                    currentPoint+1, window.sampleRateHz, window.maxDeviationRadians*180/Double.pi)
                // Feedback starts only after the accepted window is locked.
                canvas.feedback = true; canvas.needsDisplay = true
                if draft.observations.allSatisfy({ $0 != nil }) {
                    do { showCompleted(try draft.fit()) }
                    catch { handleFitFailure(error) }
                } else {
                    phase = .feedback(now+0.8)
                }
            } catch let error as CalibrationFailure {
                if error == .contextChanged || error == .cancelled { invalidate(reason: error.description) }
                else { retryCurrent(reason: error.description) }
            } catch { retryCurrent(reason: "采集未完成，请重采当前点") }
        case .countdown, .feedback, .completed:
            break
        }
    }

    /// Host calls this for disconnect, loss of qualification, lock, reference
    /// restart, screen/layout changes, or when another capture window takes over.
    public func invalidate(reason: String) {
        guard !finished else { return }
        cancellationReason = reason
        finish(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        if !finished { cancellationReason = "用户关闭标定"; finish(nil) }
    }

    @objc private func cancelPressed() { invalidate(reason: "用户取消标定，返回阅读态") }

    @objc private func restartPressed() {
        guard !finished else { return }
        draft.cancel(); draft = PointingCalibrationDraft(screen: pointerScreen)
        collector = nil; model = nil; binding = nil; latestSample = nil; lastReceivedAtMac = nil
        currentPoint = 0; phase = .waiting; countdownMessage = "对准中心，保持手臂支撑"
        canvas.acceptedPoints = []; canvas.target = PointingCalibration.targets[0]
        canvas.feedback = false; canvas.sampleProgress = 0; canvas.completeButton.isHidden = true
        canvas.status.stringValue = "重新采五点：等待新的姿态"; canvas.quality.stringValue = ""
        canvas.needsDisplay = true
    }

    @objc private func completePressed() {
        guard let model, let latestSample, let lastReceivedAtMac,
              ProcessInfo.processInfo.systemUptime-lastReceivedAtMac <= MotionLimits.streamTimeout,
              model.isValid(sample: latestSample, screen: pointerScreen) else {
            invalidate(reason: "标定结束后姿态或上下文已失效，请重新标定"); return
        }
        finish(model)
    }

    private func finish(_ result: PointingCalibration?) {
        guard !finished else { return }
        finished = true; timer?.invalidate(); timer = nil; collector = nil
        if result == nil { draft.cancel(); model = nil }
        let completion = onCompletion; onCompletion = nil
        window?.orderOut(nil); window?.close()
        completion?(result)
    }

    private func startCountdown(message: String) {
        collector = nil; countdownMessage = message
        canvas.feedback = false; canvas.sampleProgress = 0
        canvas.target = PointingCalibration.targets[currentPoint]; canvas.needsDisplay = true
        phase = .countdown(ProcessInfo.processInfo.systemUptime+3)
    }

    private func retryCurrent(reason: String) {
        guard !finished else { return }
        if case .completed = phase { return }
        collector = nil; canvas.sampleProgress = 0; canvas.feedback = false
        countdownMessage = reason + "；已完成点保留"
        canvas.status.stringValue = countdownMessage
        canvas.needsDisplay = true; phase = .waiting
    }

    private func handleFitFailure(_ error: Error) {
        let failure = error as? CalibrationFailure
        if failure == .contextChanged { invalidate(reason: error.localizedDescription); return }
        let retryIndex = failure?.suggestedPointIndex ?? currentPoint
        currentPoint = min(4, max(0, retryIndex))
        draft.removePoint(at: currentPoint)
        canvas.acceptedPoints = draft.observations.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
        canvas.quality.stringValue = "其他已采点保留；若改变了坐姿或支撑点，请使用“重新采五点”。"
        retryCurrent(reason: (failure?.description ?? "拟合未通过") + "，仅重采第 \(currentPoint+1) 点")
    }

    private func showCompleted(_ result: PointingCalibration) {
        model = result; phase = .completed
        canvas.status.stringValue = "五点拟合通过。下一步使用未参加拟合的新目标验证。"
        canvas.quality.stringValue = String(format:
            "训练残差：均方根 %.1f pt，最大 %.1f pt · 方向覆盖 %.1f° × %.1f°\n这只描述五个训练点；盲指准确度尚未测量。",
            result.quality.trainingRMSPoints, result.quality.trainingMaximumPoints,
            result.quality.headingSpan*180/Double.pi, result.quality.elevationSpan*180/Double.pi)
        canvas.completeButton.isHidden = false; canvas.needsDisplay = true
    }

    private func updateSamplingProgress() {
        guard let samples = collector?.samples, let first = samples.first, let last = samples.last else { return }
        canvas.sampleProgress = min(1, (last.watchTime-first.watchTime)/0.5)
        canvas.status.stringValue = "第 \(currentPoint+1)/5 点 · 正在自动采样，请保持姿态"
        canvas.needsDisplay = true
    }

    @objc private func tick() {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch phase {
        case let .countdown(deadline):
            guard let lastReceivedAtMac, now-lastReceivedAtMac <= MotionLimits.streamTimeout else {
                retryCurrent(reason: "姿态流暂时中断，等待恢复后重采"); return
            }
            if now >= deadline, let binding {
                collector = StableAttitudeCollector(binding: binding); phase = .collecting
                canvas.status.stringValue = "第 \(currentPoint+1)/5 点 · 自动采样约 0.5 秒，请保持姿态"
            } else {
                canvas.status.stringValue = "第 \(currentPoint+1)/5 点 · \(countdownMessage) · \(max(1, Int(ceil(deadline-now))))"
            }
        case .collecting:
            if let lastReceivedAtMac, now-lastReceivedAtMac > MotionLimits.streamTimeout {
                retryCurrent(reason: "采样中断，当前点已丢弃")
            }
        case let .feedback(deadline):
            if now >= deadline, let next = draft.observations.firstIndex(where: { $0 == nil }) {
                currentPoint = next; startCountdown(message: "对准新目标，保持手臂支撑")
            }
        case .waiting, .completed:
            break
        }
    }
}

@MainActor
private final class CalibrationCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Flipped coordinates match the selected screen's local Quartz coordinates:
/// (0,0) is upper-left and y grows down. Retina backing pixels are irrelevant.
@MainActor
private final class CalibrationCanvas: NSView {
    override var isFlipped: Bool { true }
    var target = PointerPoint(x: 0.5, y: 0.5)
    var acceptedPoints: [Int] = []
    var sampleProgress: Double = 0
    var feedback = false
    let status = NSTextField(wrappingLabelWithString: "")
    let quality = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton(title: "取消并返回阅读", target: nil, action: nil)
    let restartButton = NSButton(title: "重新采五点", target: nil, action: nil)
    let completeButton = NSButton(title: "继续独立目标验证", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "D · 固定坐姿五点标定")
    private let instructions = NSTextField(wrappingLabelWithString:
        "用戴表的手指向目标，手指与手掌关系保持稳定。倒数后自动采样，无需点手表。\n改变坐姿、手臂支撑点或屏幕角度后请重校。这里观察的是手腕朝向。")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        status.font = .systemFont(ofSize: 17, weight: .medium)
        instructions.font = .systemFont(ofSize: 13); instructions.textColor = .secondaryLabelColor
        quality.font = .systemFont(ofSize: 13); quality.textColor = .secondaryLabelColor
        for label in [title, instructions, status, quality] { label.alignment = .center; addSubview(label) }
        for button in [cancelButton, restartButton, completeButton] {
            button.bezelStyle = .rounded; addSubview(button)
        }
        completeButton.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, contentWidth = min(w-80, 1000)
        title.frame = NSRect(x: (w-contentWidth)/2, y: 20, width: contentWidth, height: 30)
        instructions.frame = NSRect(x: (w-contentWidth)/2, y: 58, width: contentWidth, height: 44)
        status.frame = NSRect(x: (w-contentWidth)/2, y: 116, width: contentWidth, height: 55)
        quality.frame = NSRect(x: (w-contentWidth)/2, y: h-138, width: contentWidth, height: 48)
        cancelButton.frame = NSRect(x: w/2-265, y: h-64, width: 165, height: 34)
        restartButton.frame = NSRect(x: w/2-85, y: h-64, width: 150, height: 34)
        completeButton.frame = NSRect(x: w/2+80, y: h-64, width: 185, height: 34)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = NSPoint(x: target.x*bounds.width, y: target.y*bounds.height)
        let color = feedback ? NSColor.systemGreen : NSColor.controlAccentColor
        color.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x-28, y: center.y-28, width: 56, height: 56)).fill()
        color.setStroke()
        let outer = NSBezierPath(ovalIn: NSRect(x: center.x-20, y: center.y-20, width: 40, height: 40))
        outer.lineWidth = 2; outer.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: center.x-11, y: center.y)); cross.line(to: NSPoint(x: center.x+11, y: center.y))
        cross.move(to: NSPoint(x: center.x, y: center.y-11)); cross.line(to: NSPoint(x: center.x, y: center.y+11))
        cross.lineWidth = 2; cross.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x-3, y: center.y-3, width: 6, height: 6)).fill()
        if sampleProgress > 0 {
            let progress = NSBezierPath()
            progress.appendArc(withCenter: center, radius: 27, startAngle: -90,
                               endAngle: -90+CGFloat(sampleProgress*360), clockwise: false)
            progress.lineWidth = 4; progress.stroke()
        }
        for index in 0..<5 {
            let marker = NSRect(x: bounds.midX-40+CGFloat(index)*20, y: bounds.height-85, width: 10, height: 10)
            (acceptedPoints.contains(index) ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: marker).fill()
        }
    }
}

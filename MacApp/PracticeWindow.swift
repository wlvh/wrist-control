import AppKit
import UniformTypeIdentifiers
import WristCore

/// Input is supplied by the common controller after it has entered the isolated
/// output scope. This window has no event-posting, sampling or Bluetooth code.
@MainActor
final class PracticeWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onSelectMode: ((PointerMode) -> Void)?
    var onScopeChange: ((OutputScope) -> Void)?
    var onStartMovement: (() -> Void)?
    var onFreezeMovement: (() -> Void)?
    var metadata = PracticeMetadata()
    private(set) var regularResults: [PracticeRunResult] = []
    private(set) var blindResults: [BlindPracticeResult] = []
    let screen: PointerScreen
    private let canvas = PracticeCanvas()
    private let settings = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "仅练习窗口；不向其他应用提交动作。")
    private let orderLabel = NSTextField(labelWithString: "")
    private let sourcePicker = NSPopUpButton()
    private let kindPicker = NSPopUpButton()
    private let sessionField = NSTextField(string: "0")
    private let seedField = NSTextField(string: "1")
    private let postureField = NSTextField(string: "固定坐姿 / 支撑点待记录")
    private let effortPicker = NSPopUpButton()
    private let feedbackField = NSTextField(string: "")
    private let nextButton = NSButton(title: "下一个盲指目标", target: nil, action: nil)
    private let lockButton = NSButton(title: "已指向，锁定稳定样本", target: nil, action: nil)
    private let skipButton = NSButton(title: "记录跳过", target: nil, action: nil)
    private var practice: PointerPracticeRun?
    private var blind: BlindPointerPractice?
    private var collector: StableAttitudeCollector?
    private var blindBinding: CalibrationBinding?
    private var blindCalibrationID: UUID?
    private var trainingTargets: [PointerPoint] = []
    private var predictBlind: ((AttitudeSample, PointerScreen) throws -> PointerPoint)?
    private var collectingBlind = false
    private var blindCollectionStart: Double?
    private var nextTargetAt: Double?
    private var cursor = PointerPoint.zero
    private var timer: Timer?
    private var currentFile: URL?
    private var savedMessage = ""
    private var closing = false
    private var requestedMode: PointerMode?
    private var feedbackTarget: Int?
    private var region: PracticeRegion {
        PracticeRegion(origin: screen.origin + PointerPoint(x: 24, y: 68), width: screen.width - 48, height: screen.height - 150)
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var source: PracticeSource { PracticeSource.allCases[max(0, sourcePicker.indexOfSelectedItem)] }
    private var active: Bool { practice != nil || blind != nil }

    init(screen: PointerScreen, appKitFrame: NSRect) {
        self.screen = screen
        let window = PracticeHostWindow(contentRect: appKitFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "腕控 0.3 · 隔离练习与独立盲指"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self; window.contentView = canvas; window.acceptsMouseMovedEvents = true
        canvas.screen = screen
        cursor = screen.point(normalized: PointerPoint(x: 0.5, y: 0.5)); canvas.pointer = cursor
        canvas.onMouseMove = { [weak self] point in
            guard let self, self.source == .mouseReference, self.blind == nil else { return }
            self.move(to: point)
        }
        canvas.onMouseClick = { [weak self] point, button, count in
            guard let self, self.source == .mouseReference, self.blind == nil else { return }
            self.click(at: point, button: button, clickCount: count)
        }
        makeControls()
        let tick = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tick, forMode: .common); timer = tick
        updateOrder()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Reuses the D module's binding and stable collector. prediction MUST be
    /// PointingCalibration.predictRaw, so out-of-screen errors are not concealed.
    func configureBlind(binding: CalibrationBinding, calibrationID: UUID, trainingTargets: [PointerPoint],
                        prediction: @escaping (AttitudeSample, PointerScreen) throws -> PointerPoint) {
        guard !active else { return }
        blindBinding = binding; blindCalibrationID = calibrationID
        self.trainingTargets = trainingTargets; predictBlind = prediction
        status.stringValue = "D 模型已接入。原姿势与姿势扰动分别记录；测试点与五个训练点分离。"
    }
    func move(to point: PointerPoint) {
        guard point.isFinite else { return }
        cursor = point
        if blind == nil {
            practice?.move(to: point, at: now)
            canvas.pointer = point; canvas.needsDisplay = true
        }
    }
    func freeze() { practice?.freeze(at: now) }
    func click(at point: PointerPoint, button: PointerButton, clickCount: Int) {
        if blind != nil {
            // A Watch left click can request the lock, but can never revise an
            // already-revealed prediction or advance to the next target.
            if button == .left, clickCount == 1, blind?.currentTarget != nil, !collectingBlind { lockBlind() }
            return
        }
        guard practice != nil else { return }
        let before = practice?.trials.count
        practice?.click(at: point, button: button, clickCount: clickCount, time: now)
        if practice?.trials.count != before { regularTrialEnded() }
    }
    func ingest(sample: AttitudeSample) {
        guard collectingBlind, blind?.currentTarget != nil, let predictBlind else { return }
        do {
            guard let stable = try collector?.append(sample: sample, screen: screen) else { return }
            let prediction = try predictBlind(stable.meanSample, screen)
            let locked = blind?.lockPrediction(prediction, at: now, sampleCount: stable.samples.count,
                sampleRateHz: stable.sampleRateHz, rmsRadians: stable.rmsRadians,
                maxDeviationRadians: stable.maxDeviationRadians) == true
            guard locked else { failBlind(.predictionRejected, message: "预测未能锁定，本目标记失败。"); return }
            collectingBlind = false; blindCollectionStart = nil
            // Result is immutable BEFORE any prediction becomes visible.
            canvas.revealedPrediction = prediction; canvas.needsDisplay = true
            let trial = blind!.trials.last!
            status.stringValue = "已锁定后显示：误差 \(String(format: "%.1f", trial.errorPoints!)) 逻辑单位；\(trial.hit == true ? "命中" : "未命中")。不能修正这一成绩。"
            nextButton.isHidden = false; lockButton.isHidden = true
            persistCurrent()
        } catch {
            let failure: BlindPracticeFailure
            if let error = error as? CalibrationFailure, error == .contextChanged { failure = .invalidContext }
            else if let error = error as? CalibrationFailure, case .unstable = error { failure = .unstable }
            else { failure = .predictionRejected }
            failBlind(failure, message: "本目标记失败：\(error)。参考变化需退出并重新标定。")
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }; closing = true
        stopRun(); timer?.invalidate(); timer = nil; onClose?()
    }

    private func makeControls() {
        settings.orientation = .vertical; settings.alignment = .leading; settings.spacing = 12
        settings.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(settings)
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 28),
            settings.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -28),
            settings.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 82)
        ])
        let title = NSTextField(labelWithString: "少量练习 → 同版比较 → 独立盲指")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        settings.addArrangedSubview(title)
        let explanation = NSTextField(wrappingLabelWithString: "目标直径 24 / 48 / 96 逻辑单位；练习 4 个、正式 20 个。每次先开启移动，对准后冻结，再左击。成绩包含看表、冻结和修正的时间。普通鼠标可做同任务参照。")
        explanation.preferredMaxLayoutWidth = max(400, min(900, screen.width - 80)); settings.addArrangedSubview(explanation)
        sourcePicker.addItems(withTitles: ["A 转向跟手", "B 翻转跟手", "C 倾斜摇杆", "D 指向定位", "鼠标 / 触控板参照"])
        sourcePicker.target = self; sourcePicker.action = #selector(selectSource)
        kindPicker.addItems(withTitles: ["练习（4 个）", "正式（20 个）", "D 盲指 · 原姿势（9 个）", "D 盲指 · 姿势扰动（9 个）"])
        sessionField.frame.size.width = 55; seedField.frame.size.width = 90
        sessionField.target = self; sessionField.action = #selector(orderChanged)
        settings.addArrangedSubview(row([sourcePicker, kindPicker,
            NSTextField(labelWithString: "比较轮次"), sessionField, NSTextField(labelWithString: "随机种子"), seedField]))
        settings.addArrangedSubview(orderLabel)
        postureField.placeholderString = "坐姿、手臂支撑点、模式参数调整"; postureField.widthAnchor.constraint(equalToConstant: 580).isActive = true
        settings.addArrangedSubview(row([NSTextField(labelWithString: "姿势记录"), postureField]))
        settings.addArrangedSubview(row([button("开始所选任务", #selector(beginRun)), button("导出全部记录…", #selector(exportEvidence))]))
        effortPicker.addItem(withTitle: "费力程度待填写")
        effortPicker.addItems(withTitles: (0...10).map { "\($0) / 10" })
        feedbackField.placeholderString = "哪里费力、是否看表偏移、失败原因、是否打断阅读"; feedbackField.widthAnchor.constraint(equalToConstant: 520).isActive = true
        settings.addArrangedSubview(row([effortPicker, feedbackField, button("保存本轮反馈", #selector(saveFeedback))]))
        settings.addArrangedSubview(NSTextField(labelWithString: "0 = 很轻松，10 = 很费力。未填写会保留为空，不代替你选择默认模式。"))
        let evidence = NSTextField(wrappingLabelWithString: "每轮记录自动保存在本机 Application Support/WristControl/PracticeEvidence；可另行导出。单纯练习不证明真实 Finder / 浏览器任务通过。")
        evidence.preferredMaxLayoutWidth = max(400, min(900, screen.width - 80)); settings.addArrangedSubview(evidence)

        status.font = .systemFont(ofSize: 14, weight: .medium); status.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(status)
        let close = button("退出练习", #selector(closeWindow)); close.translatesAutoresizingMaskIntoConstraints = false; canvas.addSubview(close)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 28),
            status.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 18),
            status.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -18),
            close.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -24),
            close.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 16)
        ])
        nextButton.target = self; nextButton.action = #selector(nextBlind); nextButton.isHidden = true
        lockButton.target = self; lockButton.action = #selector(lockBlind); lockButton.isHidden = true
        skipButton.target = self; skipButton.action = #selector(skipTarget); skipButton.isHidden = true
        let footer = row([button("开启移动", #selector(startMovement)), button("冻结", #selector(freezeMovement)),
                          lockButton, nextButton, skipButton, button("结束本轮 / 保留失败", #selector(stopRun))])
        footer.translatesAutoresizingMaskIntoConstraints = false; canvas.addSubview(footer)
        NSLayoutConstraint.activate([footer.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
                                     footer.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -22)])
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; stack.alignment = .centerY; return stack
    }
    @objc private func orderChanged() { updateOrder() }
    private func updateOrder() {
        let order = PointerPracticeSchedule.modeOrder(sessionIndex: sessionField.integerValue)
        orderLabel.stringValue = "本轮建议正式顺序：\(order.map { String(describing: $0).uppercased() }.joined(separator: " → "))；每个模式先练习，完成后按此顺序切换。"
    }
    @objc private func selectSource() {
        guard !active else { return }
        if let mode = source.mode { requestedMode = mode; onSelectMode?(mode) }
    }
    @objc private func startMovement() { guard active, blind == nil, source != .mouseReference else { return }; onStartMovement?() }
    @objc private func freezeMovement() { onFreezeMovement?() }
    @objc private func closeWindow() { window?.close() }

    @objc private func beginRun() {
        guard !active else { return }
        let seed = UInt64(seedField.stringValue) ?? 1
        var context = metadata; context.posture = postureField.stringValue
        context.runID = metadata.runID // Keep the common controller's run identifier.
        effortPicker.selectItem(at: 0); feedbackField.stringValue = ""
        currentFile = newEvidenceFile()
        do {
            if kindPicker.indexOfSelectedItem >= 2 {
                guard let binding = blindBinding, let calibrationID = blindCalibrationID, predictBlind != nil else {
                    status.stringValue = "先完成 D 五点标定，再由主线接入同一模型。"; return
                }
                guard binding.screen == screen else { status.stringValue = "标定屏幕已改变，请重新标定。"; return }
                context.calibrationID = calibrationID; context.referenceID = binding.referenceID
                sourcePicker.selectItem(at: 3); onSelectMode?(.d); requestedMode = .d
                onScopeChange?(.blindValidation)
                blind = try BlindPointerPractice(screen: screen, region: region, calibrationID: calibrationID,
                    posture: kindPicker.indexOfSelectedItem == 2 ? .original : .perturbed,
                    trainingTargetsNormalized: trainingTargets, seed: seed, metadata: context)
                collector = StableAttitudeCollector(binding: binding)
                settings.isHidden = true; canvas.hidePointer = true; skipButton.isHidden = false
                nextBlind()
            } else {
                if let mode = source.mode { requestedMode = mode; onSelectMode?(mode) }
                onScopeChange?(.practice)
                practice = try PointerPracticeRun(configuration: PracticeConfiguration(screen: screen, region: region,
                    source: source, stage: kindPicker.indexOfSelectedItem == 0 ? .warmup : .formal,
                    seed: seed, sessionIndex: sessionField.integerValue, metadata: context))
                settings.isHidden = true; canvas.hidePointer = false; skipButton.isHidden = false
                practice?.beginNext(at: now, initialPointer: cursor); canvas.target = practice?.currentTarget; canvas.pointer = cursor
                status.stringValue = "\(sourcePicker.titleOfSelectedItem ?? "") · \(kindPicker.titleOfSelectedItem ?? "") · 目标 1 / \(practice!.targets.count)；开启 → 对准 → 冻结 → 左击。"
            }
            canvas.revealedPrediction = nil; canvas.needsDisplay = true; persistCurrent()
        } catch { status.stringValue = "无法开始：\(error)" }
    }
    private func tick() {
        if var run = practice, run.isActive {
            let previous = run.trials.count; run.tick(at: now); practice = run
            if run.trials.count != previous { regularTrialEnded() }
        }
        if let next = nextTargetAt, now >= next, practice != nil {
            nextTargetAt = nil
            if practice?.beginNext(at: now, initialPointer: cursor) == true {
                canvas.target = practice?.currentTarget; canvas.revealedPrediction = nil; canvas.needsDisplay = true
                status.stringValue = "目标 \(practice!.trials.count + 1) / \(practice!.targets.count) · 再次明确开启移动；每个目标最多 30 秒。"
            }
        }
        if collectingBlind, let began = blindCollectionStart, now - began >= 5 {
            failBlind(.unstable, message: "5 秒内未得到完整稳定样本，本目标记失败。")
        }
    }
    private func regularTrialEnded() {
        guard let practice, let last = practice.trials.last else { return }
        onFreezeMovement?(); canvas.target = nil; canvas.needsDisplay = true
        status.stringValue = "\(last.outcome == .hit ? "完成" : "失败已保留") · \(String(format: "%.2f", last.totalSeconds)) 秒 · 首击\(last.firstClickHit == true ? "命中" : "未命中/未点击") · 误击 \(last.missedClicks)"
        persistCurrent()
        if practice.isComplete { completeRegular() }
        else { nextTargetAt = now + 0.8 }
    }
    @objc private func nextBlind() {
        guard blind != nil, blind?.currentTarget == nil else { return }
        if blind?.isComplete == true { completeBlind(); return }
        collector?.reset(); collectingBlind = false; blindCollectionStart = nil
        canvas.revealedPrediction = nil
        blind?.beginNext(at: now); canvas.target = blind?.currentTarget
        canvas.hidePointer = true; canvas.needsDisplay = true
        nextButton.isHidden = true; lockButton.isHidden = false
        status.stringValue = "盲指 \(blind!.trials.count + 1) / 9：指向目标、保持支撑，然后锁定。练习指针已隐藏。"
    }
    @objc private func lockBlind() {
        guard blind?.currentTarget != nil, !collectingBlind else { return }
        onFreezeMovement?(); collector?.reset(); collectingBlind = true; blindCollectionStart = now
        lockButton.isHidden = true
        status.stringValue = "保持姿势，采集至少 0.5 秒稳定样本。预测锁定后才显示落点。"
    }
    private func failBlind(_ reason: BlindPracticeFailure, message: String) {
        blind?.fail(reason, at: now); collectingBlind = false; blindCollectionStart = nil
        canvas.revealedPrediction = nil; canvas.needsDisplay = true
        lockButton.isHidden = true; nextButton.isHidden = false; status.stringValue = message; persistCurrent()
    }
    @objc private func skipTarget() {
        if practice?.isActive == true { practice?.finish(.skipped, at: now); regularTrialEnded() }
        else if blind?.currentTarget != nil { failBlind(.skipped, message: "本目标跳过，已作为失败保留；选择下一个目标。") }
    }
    @objc private func stopRun() {
        onFreezeMovement?(); nextTargetAt = nil
        if practice != nil {
            if practice?.isActive == true { practice?.finish(.aborted, at: now) }
            completeRegular()
        }
        if blind != nil {
            if blind?.currentTarget != nil { blind?.fail(.aborted, at: now) }
            completeBlind()
        }
    }
    private func completeRegular() {
        guard let value = practice else { return }
        regularResults.append(value.result); feedbackTarget = regularResults.count - 1
        practice = nil; persistLatestCompleted(); restoreControls()
        let summary = value.result.summary
        status.stringValue = "本轮完成 \(summary.completed) / \(value.targets.count)，失败 \(summary.failures)，已尝试 \(summary.attempted)。请填费力程度与失败观察。\(savedMessage)"
    }
    private func completeBlind() {
        guard let value = blind else { return }
        blindResults.append(value.result); feedbackTarget = nil
        blind = nil; collectingBlind = false; blindCollectionStart = nil
        persistLatestCompleted(); restoreControls()
        let result = value.result
        status.stringValue = "盲指命中 \(result.hits) / \(result.trials.count) 已尝试目标（计划 9）；中位误差 \(format(result.errors.median))，最大 \(format(result.errors.maximum)) 逻辑单位。\(savedMessage)"
    }
    private func restoreControls() {
        settings.isHidden = false; canvas.target = nil; canvas.revealedPrediction = nil; canvas.hidePointer = false
        skipButton.isHidden = true; lockButton.isHidden = true; nextButton.isHidden = true
        canvas.needsDisplay = true
        onScopeChange?(.practice) // Never resumes system output or movement.
    }
    @objc private func saveFeedback() {
        guard !active, let feedbackTarget, regularResults.indices.contains(feedbackTarget) else { status.stringValue = "先完成普通练习/正式一轮，再记录主观费力。"; return }
        let old = regularResults[feedbackTarget]
        // Feedback is attached to the actual last regular run; changing UI mode
        // selectors afterward does not relabel its source or trial results.
        regularResults[feedbackTarget] = old.withFeedback(effort: effortPicker.indexOfSelectedItem > 0 ? effortPicker.indexOfSelectedItem - 1 : nil,
            text: feedbackField.stringValue)
        if let url = regularEvidenceFiles[feedbackTarget] {
            writeEvidence(PointerPracticeEvidence(regularRuns: [regularResults[feedbackTarget]], blindRuns: []), to: url)
        }
        status.stringValue = "费力程度与观察已记录。\(savedMessage)"
    }
    private var regularEvidenceFiles: [Int: URL] = [:]
    private func persistCurrent() {
        guard let currentFile else { return }
        let evidence = PointerPracticeEvidence(regularRuns: practice.map { [$0.result] } ?? [], blindRuns: blind.map { [$0.result] } ?? [])
        writeEvidence(evidence, to: currentFile)
    }
    private func persistLatestCompleted() {
        guard let currentFile else { return }
        if kindPicker.indexOfSelectedItem < 2, let last = regularResults.last {
            regularEvidenceFiles[regularResults.count - 1] = currentFile
            writeEvidence(PointerPracticeEvidence(regularRuns: [last], blindRuns: []), to: currentFile)
        } else if let last = blindResults.last {
            writeEvidence(PointerPracticeEvidence(regularRuns: [], blindRuns: [last]), to: currentFile)
        }
        self.currentFile = nil
    }
    private func newEvidenceFile() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("WristControl/PracticeEvidence", isDirectory: true).appendingPathComponent("result-\(UUID().uuidString).json")
    }
    private func writeEvidence(_ value: PointerPracticeEvidence, to url: URL) {
        do {
            let data = try value.encoded(), folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            var total = 0
            for file in files where file.lastPathComponent.hasPrefix("result-") && file != url {
                total += (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            }
            guard total + data.count <= 20 * 1024 * 1024 else {
                savedMessage = "自动记录已达 20 MB；本轮仍在内存，请导出后自行整理旧文件。"; return
            }
            try data.write(to: url, options: .atomic); savedMessage = "记录已保存本机。"
        } catch { savedMessage = "保存失败：\(error.localizedDescription)。请导出记录。" }
    }
    @objc private func exportEvidence() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "wrist-practice-\(Date().ISO8601Format().replacingOccurrences(of: ":", with: "-" )).json"
        panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let evidence = PointerPracticeEvidence(regularRuns: regularResults + (practice.map { [$0.result] } ?? []),
                                                   blindRuns: blindResults + (blind.map { [$0.result] } ?? []))
            try evidence.encoded().write(to: url, options: .atomic)
            status.stringValue = "已导出全部记录。真实应用任务与主观偏好仍需单独反馈。"
        } catch { status.stringValue = "导出失败：\(error.localizedDescription)" }
    }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "无有效预测" }
}

@MainActor
private final class PracticeHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class PracticeCanvas: NSView {
    var screen: PointerScreen?
    var target: PracticeTarget?
    var pointer: PointerPoint?
    var revealedPrediction: PointerPoint?
    var hidePointer = false
    var onMouseMove: ((PointerPoint) -> Void)?
    var onMouseClick: ((PointerPoint, PointerButton, Int) -> Void)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let value = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(value); tracking = value; super.updateTrackingAreas()
    }
    private func global(_ event: NSEvent) -> PointerPoint {
        let point = convert(event.locationInWindow, from: nil), origin = screen?.origin ?? .zero
        return PointerPoint(x: origin.x + point.x, y: origin.y + point.y)
    }
    override func mouseMoved(with event: NSEvent) { onMouseMove?(global(event)) }
    override func mouseDown(with event: NSEvent) { onMouseClick?(global(event), .left, event.clickCount) }
    override func rightMouseDown(with event: NSEvent) { onMouseClick?(global(event), .right, event.clickCount) }
    private func local(_ point: PointerPoint) -> NSPoint {
        let origin = screen?.origin ?? .zero; return NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        if let target {
            let center = local(target.center), diameter = target.diameter
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - diameter/2, y: center.y - diameter/2, width: diameter, height: diameter))
            NSColor.systemTeal.withAlphaComponent(0.22).setFill(); circle.fill()
            NSColor.systemTeal.setStroke(); circle.lineWidth = 2; circle.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)); dot.fill()
            let text = "\(Int(diameter))"
            text.draw(at: NSPoint(x: center.x - 10, y: center.y + diameter/2 + 5), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
        if !hidePointer, let pointer { drawCross(at: local(pointer), color: .labelColor) }
        if let revealedPrediction {
            let point = local(revealedPrediction)
            if let target {
                let line = NSBezierPath(); line.move(to: local(target.center)); line.line(to: point)
                NSColor.systemOrange.setStroke(); line.lineWidth = 1.5; line.stroke()
            }
            drawCross(at: point, color: .systemOrange)
        }
    }
    private func drawCross(at point: NSPoint, color: NSColor) {
        color.setStroke(); let cross = NSBezierPath()
        cross.move(to: NSPoint(x: point.x - 9, y: point.y)); cross.line(to: NSPoint(x: point.x + 9, y: point.y))
        cross.move(to: NSPoint(x: point.x, y: point.y - 9)); cross.line(to: NSPoint(x: point.x, y: point.y + 9))
        cross.lineWidth = 2; cross.stroke()
    }
}

import AppKit
import WristCore

@main
@MainActor
enum WristControlMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = MacApplication()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class MacApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let bluetooth = MacBluetooth()
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var article: NSTextView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "准备蓝牙测试")
    private let outputLabel = NSTextField(labelWithString: "滚轮已暂停")
    private var pauseButton: NSButton!
    private lazy var wheel = SystemWheel(journal: bluetooth.journal)
    private lazy var pointer = PointerCoordinator(journal: bluetooth.journal)
    private lazy var nativePointer = SystemPointer(journal: bluetooth.journal)
    private let geometry = DisplayGeometry()
    private var calibrationWindow: CalibrationWindowController?
    private var practiceWindow: PracticeWindowController?
    private var closingTool = false
    private var applyingSessionBoundary = false
    private var isolatedClicks = ClickSequence()
    private var modePicker: NSPopUpButton!
    private var parameterButton: NSButton!
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private var diagnosticsVisible = false
    private var observers: [NSObjectProtocol] = []
    private var uiTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu(); createWindow()
        let keyStatus = PairingKeyStore.importBootstrapIfPresent()
        bluetooth.journal.record("pair_key_load", detail: "status=\(keyStatus)")
        bluetooth.controlState = { [weak self] in self?.wheel.state() ?? [] }
        bluetooth.onStatus = { [weak self] in self?.statusLabel.stringValue = $0 }
        pointer.allowed = { [weak self] in
            guard let self else { return false }
            return self.bluetooth.identityVerified && self.wheel.state().canScroll
        }
        nativePointer.eligible = { [weak self] in
            guard let self else { return false }
            return self.pointer.scope == .system && self.bluetooth.identityVerified && self.wheel.state().canScroll
        }
        wheel.authority = { [weak self] in
            guard let self else { return false }
            return self.pointer.scope == .system && self.bluetooth.identityVerified
        }
        pointer.cursor = { [weak self] in self?.nativePointer.cursor() ?? .zero }
        pointer.screenAt = { [weak self] in self?.geometry.screen(at: $0) }
        pointer.onMove = { [weak self] point, scope in
            guard let self else { return false }
            if scope == .system { return self.nativePointer.move(to: point) }
            guard scope == .practice, let practice = self.practiceWindow, practice.acceptsWatchInput else { return false }
            practice.move(to: point); return true
        }
        pointer.onClick = { [weak self] request, session, point, now, scope in
            guard let self else { return false }
            if scope == .system { return self.nativePointer.click(request, session: session, at: point, now: now) }
            guard scope == .practice || scope == .blindValidation, let practice = self.practiceWindow, practice.acceptsWatchInput,
                  let count = self.isolatedClicks.consume(request, session: session, at: point,
                                                          macTime: now, interval: NSEvent.doubleClickInterval) else { return false }
            practice.click(at: point, button: request.button, clickCount: count); return true
        }
        pointer.onWheel = { [weak self] points, scope in
            guard let self else { return false }
            if scope != .system { return true } // isolated tools never send external wheel events
            return self.wheel.post(points: points)
        }
        pointer.onBreakClickPair = { [weak self] in self?.nativePointer.breakClickPair(); self?.isolatedClicks.breakPair() }
        pointer.onFreeze = { [weak self] in self?.practiceWindow?.freeze() }
        pointer.onModeChange = { [weak self] in self?.practiceWindow?.actualModeChanged(to: $0) }
        pointer.onSample = { [weak self] sample, received in
            self?.calibrationWindow?.ingest(sample: sample, receivedAtMac: received)
            self?.practiceWindow?.ingest(sample: sample)
        }
        pointer.onInvalidation = { [weak self] reason in
            guard let self, !self.closingTool else { return }
            self.closeTools(reason: reason)
            // A packet sent to the isolated tool must never become a system
            // click just because invalidation closed that tool meanwhile.
            if self.applyingSessionBoundary { self.pointer.setScope(.system) }
            else { self.enterScope(.system) }
        }
        pointer.onSettings = { [weak self] settings in
            self?.practiceWindow?.parametersDidChange()
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "pointerSettings.v3") }
        }
        if let data = UserDefaults.standard.data(forKey: "pointerSettings.v3"),
           let saved = try? JSONDecoder().decode(PointerSettings.self, from: data) { _ = pointer.configure(saved) }
        bluetooth.onPointerAction = { [weak self] wire, time in self?.pointer.handle(wire, now: time) ?? false }
        bluetooth.onSession = { [weak self] session, enabled, preserveCalibration in
            guard let self else { return }
            self.applyingSessionBoundary = true
            defer { self.applyingSessionBoundary = false }
            self.pointer.newSession(session, enabled: enabled, preserveCalibration: preserveCalibration)
            self.nativePointer.reset(session: self.pointer.lease.session)
            self.isolatedClicks.reset(session: self.pointer.lease.session)
        }
        bluetooth.calibrationAvailable = { [weak self] in self?.pointer.calibration != nil }
        bluetooth.pointerState = { [weak self] in
            guard let p = self?.pointer else { return (0, .paused, .a, .system) }
            return (p.lease.cycle, p.lease.phase, p.mode, p.scope)
        }
        bluetooth.onTick = { [weak self] in self?.pointer.tick(now: $0) }
        bluetooth.onResetOutput = { [weak self] in self?.wheel.reset(); self?.pointer.freeze(reason: "transport_boundary") }
        wheel.onEligibilityLost = { [weak self] in self?.bluetooth.targetDidChange("output_eligibility_lost") }
        bluetooth.onSetEnabled = { [weak self] in self?.wheel.setEnabled($0) }
        bluetooth.onExport = { [weak self] in self?.saveDiagnostics(watch: $0, reason: $1) }
        observeLifecycle()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        bluetooth.start()
        let pulse = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDiagnostics() }
        }
        RunLoop.main.add(pulse, forMode: .common); uiTimer = pulse
    }

    private func createMenu() {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(); app.addItem(withTitle: "退出腕控", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; NSApp.mainMenu = menu
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "腕控 0.3 · 四模式指针与通用滚轮"; window.minSize = NSSize(width: 650, height: 500)
        window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let container = NSStackView(); container.orientation = .vertical; container.alignment = .leading
        container.spacing = 12; container.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 18, right: 28)
        container.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); window.contentView = root; root.addSubview(container)
        NSLayoutConstraint.activate([container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor), container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let title = NSTextField(labelWithString: "沿着一条河，慢慢读下去")
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        container.addArrangedSubview(title)
        statusLabel.font = .systemFont(ofSize: 13); statusLabel.textColor = .secondaryLabelColor
        container.addArrangedSubview(statusLabel)
        let hint = NSTextField(wrappingLabelWithString: "手表点“开启移动”，停稳片刻，再转动手腕。点左击／右击或转表冠会冻结移动；左击连点两次是双击。手表上的“暂停腕控”暂停全部输入。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        container.addArrangedSubview(hint)
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 18
        pauseButton = NSButton(title: "继续腕控", target: self, action: #selector(toggleControl))
        row.addArrangedSubview(pauseButton)
        row.addArrangedSubview(NSButton(title: "允许输入权限", target: self, action: #selector(requestPermission)))
        let export = NSButton(title: "导出诊断", target: self, action: #selector(exportDiagnostics))
        row.addArrangedSubview(export)
        row.addArrangedSubview(NSButton(title: "展开诊断", target: self, action: #selector(toggleDiagnostics(_:))))
        container.addArrangedSubview(row)
        let modes = NSStackView(); modes.orientation = .horizontal; modes.spacing = 10
        modePicker = NSPopUpButton(); modePicker.addItems(withTitles: ["A 转向跟手", "B 翻转跟手", "C 倾斜摇杆", "D 指向定位"])
        modePicker.target = self; modePicker.action = #selector(changeMode)
        parameterButton = NSButton(title: "模式参数", target: self, action: #selector(editParameters))
        for item: NSView in [modePicker, parameterButton,
            NSButton(title: "停止移动", target: self, action: #selector(stopPointer)),
            NSButton(title: "D 五点标定 / 重校", target: self, action: #selector(startCalibration)),
            NSButton(title: "练习与同版比较", target: self, action: #selector(openPractice))] { modes.addArrangedSubview(item) }
        container.addArrangedSubview(modes)
        outputLabel.font = .systemFont(ofSize: 12); outputLabel.textColor = .secondaryLabelColor
        container.addArrangedSubview(outputLabel)
        diagnosticsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsLabel.textColor = .secondaryLabelColor; diagnosticsLabel.isHidden = true
        container.addArrangedSubview(diagnosticsLabel)
        scroll = ReadingScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        article = NSTextView(frame: NSRect(x: 0, y: 0, width: 780, height: 500))
        article.isEditable = false; article.isSelectable = true; article.isRichText = true
        article.isVerticallyResizable = true; article.isHorizontallyResizable = false
        article.autoresizingMask = [.width]; article.textContainer?.widthTracksTextView = true
        article.textContainerInset = NSSize(width: 24, height: 20)
        article.minSize = NSSize(width: 0, height: 0); article.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 9; paragraph.paragraphSpacing = 24
        article.textStorage?.setAttributedString(NSAttributedString(string: ReadingArticle.numbered,
            attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]))
        scroll.documentView = article; container.addArrangedSubview(scroll)
        for view in [title, statusLabel, hint, row, modes, outputLabel, diagnosticsLabel, scroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -56).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }

    private func closeTools(reason: String) {
        closingTool = true
        calibrationWindow?.invalidate(reason: reason); calibrationWindow = nil
        practiceWindow?.onClose = nil; practiceWindow?.onFreezeMovement = nil; practiceWindow?.onScopeChange = nil
        practiceWindow?.close(); practiceWindow = nil
        closingTool = false
    }
    private func enterScope(_ scope: OutputScope, screen: PointerScreen? = nil) {
        bluetooth.intentBoundary("scope_\(scope)") { pointer.setScope(scope, screen: screen) }
    }
    @objc private func changeMode() {
        guard let mode = PointerMode(rawValue: UInt8(modePicker.indexOfSelectedItem + 1)) else { return }
        selectMode(mode)
    }
    private func selectMode(_ mode: PointerMode) {
        bluetooth.intentBoundary("mac_mode_changed") { pointer.selectMode(mode) }; refreshDiagnostics()
    }
    @objc private func stopPointer() {
        bluetooth.intentBoundary("mac_stop") { pointer.freeze(reason: "mac_stop") }; refreshDiagnostics()
    }
    private func toolScreen() -> (PointerScreen, NSRect)? {
        guard bluetooth.identityVerified, wheel.state().canScroll else {
            statusLabel.stringValue = "先连接手表并继续腕控，再打开标定或练习。"; return nil
        }
        guard let screen = geometry.screen(at: nativePointer.cursor()), let frame = geometry.appKitFrame(for: screen.displayID) else {
            statusLabel.stringValue = "未取得鼠标所在屏幕，请先把鼠标放入一块显示器。"; return nil
        }
        return (screen, frame)
    }
    @objc private func startCalibration() {
        guard let (screen, frame) = toolScreen() else { return }
        closeTools(reason: "recalibration")
        pointer.invalidateCalibration("recalibration_requested")
        enterScope(.calibration, screen: screen)
        let controller = CalibrationWindowController(screen: screen, appKitFrame: frame) { [weak self] model in
            guard let self, !self.closingTool else { return }
            self.calibrationWindow = nil
            self.enterScope(.system)
            if let model {
                self.pointer.installCalibration(model)
                self.saveCalibrationEvidence(model)
                self.bluetooth.journal.record("calibration_fitted", detail: "id=\(model.calibrationID);training_rms_pt=\(model.quality.trainingRMSPoints);training_max_pt=\(model.quality.trainingMaximumPoints);independent_accuracy_unmeasured")
                self.showPractice(screen: screen, frame: frame, preferBlind: true)
            } else { self.statusLabel.stringValue = "标定已取消；移动保持停止。" }
        }
        calibrationWindow = controller; controller.showWindow(nil)
    }
    private func saveCalibrationEvidence(_ model: PointingCalibration) {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = support.appendingPathComponent("WristControl/CalibrationEvidence", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let evidence = CalibrationEvidence(model: model,
                macBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                watchBuild: bluetooth.watchBuild + ";sha=" + bluetooth.watchRevision,
                sourceRevision: Bundle.main.object(forInfoDictionaryKey: "WristSourceRevision") as? String ?? "unknown")
            let data = try evidence.encoded()
            guard size + data.count <= 20_000_000 else {
                bluetooth.journal.record("calibration_evidence_not_saved", detail: "local_record_limit;model_in_memory_only"); return
            }
            try data.write(to: folder.appendingPathComponent("calibration-\(model.calibrationID).json"), options: .atomic)
        } catch { bluetooth.journal.record("calibration_evidence_not_saved", detail: "local_io_error;model_in_memory_only") }
    }
    @objc private func openPractice() {
        if pointer.mode == .d, let model = pointer.calibration,
           let current = geometry.screen(at: model.binding.screen.point(normalized: PointerPoint(x: 0.5, y: 0.5))),
           current == model.binding.screen, let frame = geometry.appKitFrame(for: current.displayID),
           bluetooth.identityVerified, wheel.state().canScroll {
            closeTools(reason: "open_practice"); showPractice(screen: current, frame: frame); return
        }
        guard let (screen, frame) = toolScreen() else { return }
        closeTools(reason: "open_practice"); showPractice(screen: screen, frame: frame)
    }
    private func showPractice(screen: PointerScreen, frame: NSRect, preferBlind: Bool = false) {
        enterScope(.practice, screen: screen)
        let controller = PracticeWindowController(screen: screen, appKitFrame: frame)
        controller.metadataProvider = { [weak self] in
            guard let self else { return PracticeMetadata() }
            return PracticeMetadata(runID: self.bluetooth.journal.runID,
                macBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                watchBuild: self.bluetooth.watchBuild + ";sha=" + self.bluetooth.watchRevision,
                sourceSHA: Bundle.main.object(forInfoDictionaryKey: "WristSourceRevision") as? String ?? "unknown",
                transport: "BLE authenticated v3;pose latest<=30Hz;control ACK",
                modeParameters: self.pointer.settings.description, referenceID: self.pointer.latestSample?.referenceID,
                calibrationID: self.pointer.calibration?.calibrationID)
        }
        controller.onSelectMode = { [weak self] mode in self?.selectMode(mode) }
        controller.onScopeChange = { [weak self] scope in self?.enterScope(scope, screen: screen) }
        controller.onFreezeMovement = { [weak self] in self?.stopPointer() }
        controller.onClose = { [weak self] in
            guard let self, !self.closingTool else { return }
            self.practiceWindow = nil; self.enterScope(.system); self.window.makeKeyAndOrderFront(nil)
        }
        if let model = pointer.calibration, model.binding.screen == screen {
            controller.configureBlind(binding: model.binding, calibrationID: model.calibrationID,
                trainingTargets: PointingCalibration.targets, prediction: { sample, screen in try model.predictRaw(sample: sample, screen: screen) })
        }
        if preferBlind { controller.selectBlindValidation() }
        practiceWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func editParameters() {
        guard pointer.mode != .d else { return }
        stopPointer()
        let mode = pointer.mode, current = pointer.settings
        let alert = NSAlert(); alert.messageText = "\(String(describing: mode).uppercased()) 模式参数"
        alert.informativeText = "保存后仍保持停止；在手表重新开启移动。数值是自用实验起点。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading
        let values: [(String, Double)] = mode == .c
            ? [("中立区（度）", current.joystick.deadZoneRadians * 180 / .pi),
               ("满速角（度）", current.joystick.fullSpeedRadians * 180 / .pi),
               ("曲线指数", current.joystick.exponent),
               ("最高速度（屏宽 / 秒）", current.joystick.maxScreenWidthsPerSecond)]
            : [("每弧度移动逻辑点（100～8000）", mode == .a ? current.aGain : current.bGain)]
        var fields: [NSTextField] = []
        for (label, number) in values {
            column.addArrangedSubview(NSTextField(labelWithString: label))
            let field = NSTextField(string: String(format: "%.2f", number)); field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            column.addArrangedSubview(field); fields.append(field)
        }
        column.frame = NSRect(x: 0, y: 0, width: 320, height: values.count * 52)
        alert.accessoryView = column
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            let parsed = fields.compactMap { Double($0.stringValue) }
            guard parsed.count == fields.count else { self.statusLabel.stringValue = "参数须为有效数字，未保存。"; return }
            var next = current
            if mode == .c {
                next.joystick = JoystickParameters(deadZoneRadians: parsed[0] * .pi / 180,
                    fullSpeedRadians: parsed[1] * .pi / 180, exponent: parsed[2], maxScreenWidthsPerSecond: parsed[3])
            } else if mode == .a { next.aGain = parsed[0] } else { next.bGain = parsed[0] }
            self.bluetooth.intentBoundary("parameters_changed") {
                self.statusLabel.stringValue = self.pointer.configure(next) ? "参数已保存，移动保持停止。" : "参数超出合法范围，未保存。"
            }
        }
    }

    @objc private func toggleControl() {
        wheel.setEnabled(!wheel.enabled)
        if wheel.enabled { bluetooth.start() } // retry a launch deferred by locked protected data
        bluetooth.targetDidChange("mac_user_control"); refreshDiagnostics()
    }

    @objc private func requestPermission() {
        wheel.requestPermission(); bluetooth.targetDidChange("permission_request")
    }

    private func refreshDiagnostics() {
        let state = wheel.state()
        pauseButton.title = wheel.enabled ? "暂停腕控" : "继续腕控"
        if !state.contains(.permission) { outputLabel.stringValue = "需要在系统设置 → 隐私与安全性 → 辅助功能中允许腕控。" }
        else if !state.contains(.interactive) { outputLabel.stringValue = "电脑不可交互，或设备密钥不可用；系统输出已停止。" }
        else { outputLabel.stringValue = "\(String(describing: pointer.mode).uppercased()) · \(pointer.scope == .system ? "系统输出" : "自有窗口隔离") · 移动：\(pointer.lease.phase) · 整个腕控：\(wheel.enabled ? "启用" : "暂停") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")" }
        modePicker.selectItem(at: Int(pointer.mode.rawValue) - 1); parameterButton.isEnabled = pointer.mode != .d
        diagnosticsLabel.stringValue = "处理 \(bluetooth.acceptedCount) · 拒绝 \(bluetooth.rejectedCount) · 系统发送 \(wheel.postedCount) · 本窗口位置 \(Int(scroll.contentView.bounds.minY)) pt\n设备认证：\(bluetooth.identityVerified ? "通过" : "未通过") / 资格：\(state.rawValue) / 钥匙串状态：\(wheel.lastKeyStatus)\n日志中的发送成功不代表目标窗口已滚动；设备时钟不能直接相减。"
    }

    @objc private func toggleDiagnostics(_ button: NSButton) {
        diagnosticsVisible.toggle(); diagnosticsLabel.isHidden = !diagnosticsVisible
        button.title = diagnosticsVisible ? "收起诊断" : "展开诊断"
        refreshDiagnostics()
    }

    @objc private func exportDiagnostics() { bluetooth.exportDiagnostics() }

    private func saveDiagnostics(watch: Data?, reason: String) {
        do {
            let macObject = try JSONSerialization.jsonObject(with: bluetooth.journal.snapshot())
            let watchObject: Any = try watch.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 2, "scope": "authenticated_system_wheel", "export_result": reason,
                "identity_verified": bluetooth.identityVerified, "mac": macObject, "watch": watchObject,
                "measurement_note": "Device uptimes are separate clocks. Handler completion is not a display measurement.",
                "manual_test_notes": ["watch_model": "", "always_on": "", "return_to_clock": "", "wrist_wake": "", "posture": "", "debugger_detached": "", "observations": ""]
            ], options: [.prettyPrinted, .sortedKeys])
            // App-owned export directory; Finder reveals the exact file for sharing.
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = support.appendingPathComponent("WristControl/Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "腕控诊断-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            statusLabel.stringValue = watch == nil
                ? "已保存电脑诊断（缺少手表日志）"
                : "已保存两端诊断"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error); alert.beginSheetModal(for: window)
        }
    }

    private func observeLifecycle() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self else { return }
            self.geometry.invalidate(); self.bluetooth.targetDidChange("display_layout_changed")
            self.pointer.invalidateCalibration("display_layout_changed")
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        let changes: [(Notification.Name, (SystemWheel) -> Void)] = [
            (NSWorkspace.willSleepNotification, { $0.awake = false }),
            (NSWorkspace.didWakeNotification, { $0.awake = true }),
            (NSWorkspace.screensDidSleepNotification, { $0.displayAwake = false }),
            (NSWorkspace.screensDidWakeNotification, { $0.displayAwake = true }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true })
        ]
        for (name, update) in changes {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                guard let self else { return }
                update(self.wheel); self.wheel.reset()
                self.bluetooth.journal.record("mac_lifecycle", detail: name.rawValue)
                self.bluetooth.targetDidChange(name.rawValue); self.bluetooth.journal.persist()
                }
            })
        }
        for name in [Notification.Name.NSApplicationProtectedDataWillBecomeUnavailable, Notification.Name.NSApplicationProtectedDataDidBecomeAvailable] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                guard let self else { return }
                self.wheel.protectionAvailable = name == Notification.Name.NSApplicationProtectedDataDidBecomeAvailable
                if self.wheel.protectionAvailable { self.bluetooth.start() }
                self.wheel.reset(); self.bluetooth.journal.record("protected_data_changed", detail: name.rawValue)
                self.bluetooth.targetDidChange(name.rawValue); self.bluetooth.journal.persist()
                }
            })
        }
    }

    // Minimization and ordinary frontmost-app changes deliberately do not affect output.
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { uiTimer?.invalidate(); bluetooth.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

}

private final class ReadingScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView else { return }
        let width = contentView.bounds.width
        guard width > 0, abs(text.frame.width - width) > 0.01 else { return }
        text.setFrameSize(NSSize(width: width, height: text.frame.height))
        text.textContainer?.containerSize = NSSize(width: max(1, width - 2 * text.textContainerInset.width),
                                                   height: CGFloat.greatestFiniteMagnitude)
    }
}

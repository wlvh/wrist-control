import AppKit
import WristCore

@main
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

final class MacApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let bluetooth = MacBluetooth()
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var article: NSTextView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "准备蓝牙测试")
    private let markerLabel = NSTextField(labelWithString: "阅读标记 0")
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private var diagnosticsVisible = false
    private var screenAvailable = true
    private var observers: [NSObjectProtocol] = []
    private var uiTimer: Timer?
    private var marks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu(); createWindow()
        bluetooth.targetReady = { [weak self] in
            guard let self else { return false }
            return self.screenAvailable && self.window.isVisible && !self.window.isMiniaturized
        }
        bluetooth.onStatus = { [weak self] in self?.statusLabel.stringValue = $0 }
        bluetooth.onScroll = { [weak self] in self?.applyScroll($0) ?? false }
        bluetooth.onMark = { [weak self] in self?.mark() ?? false }
        bluetooth.onExport = { [weak self] in self?.saveDiagnostics(watch: $0, reason: $1) }
        observeLifecycle()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.arguments.contains("--output-self-check") {
            runOutputSelfCheck()
        } else {
            bluetooth.start()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshDiagnostics() }
    }

    private func createMenu() {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(); app.addItem(withTitle: "退出腕控", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; NSApp.mainMenu = menu
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "腕控 · 阅读验证"; window.minSize = NSSize(width: 650, height: 500)
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
        let hint = NSTextField(wrappingLabelWithString: "转动表冠阅读；手表按钮在这里留下标记。当前只影响本窗口，尚未验证连接设备身份。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        container.addArrangedSubview(hint)
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 18
        markerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(markerLabel)
        let export = NSButton(title: "导出诊断", target: self, action: #selector(exportDiagnostics))
        row.addArrangedSubview(export)
        row.addArrangedSubview(NSButton(title: "展开诊断", target: self, action: #selector(toggleDiagnostics(_:))))
        container.addArrangedSubview(row)
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
        for view in [title, statusLabel, hint, row, diagnosticsLabel, scroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -56).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }

    private func applyScroll(_ points: Double) -> Bool {
        guard bluetooth.targetReady(), points.isFinite else { return false }
        article.layoutManager?.ensureLayout(for: article.textContainer!)
        let clip = scroll.contentView
        let maximum = max(0, article.bounds.height - clip.bounds.height)
        let origin = NSPoint(x: clip.bounds.minX, y: min(maximum, max(0, clip.bounds.minY + points)))
        // Direct position update: no animation, momentum, or system input injection.
        clip.scroll(to: origin); scroll.reflectScrolledClipView(clip)
        return true
    }

    private func mark() -> Bool {
        guard bluetooth.targetReady() else { return false }
        marks += 1
        markerLabel.stringValue = "阅读标记 \(marks) · 位置 \(Int(scroll.contentView.bounds.minY)) pt"
        return true
    }

    private func refreshDiagnostics() {
        diagnosticsLabel.stringValue = "处理 \(bluetooth.acceptedCount) · 拒绝 \(bluetooth.rejectedCount) · 窗口位置 \(Int(scroll.contentView.bounds.minY)) pt\n身份：未验证 / 输出：仅测试窗口 / 速度：180 pt 每坐标单位\n日志仅测本机收到到处理的耗时，不能代表跨设备或画面延迟。"
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
                "schema": 1, "scope": "phase_1_test_window_only", "export_result": reason,
                "identity_verified": false, "mac": macObject, "watch": watchObject,
                "measurement_note": "Device uptimes are separate clocks. Handler completion is not a display measurement.",
                "manual_test_notes": ["watch_model": "", "always_on": "", "return_to_clock": "", "wrist_wake": "", "posture": "", "debugger_detached": "", "observations": ""]
            ], options: [.prettyPrinted, .sortedKeys])
            // Keep export independent of a cloud-backed save panel. The app owns
            // this sandbox directory; Finder reveals the exact file for sharing.
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
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screenAvailable = false; self?.bluetooth.journal.record("mac_inactive", detail: name.rawValue)
                self?.bluetooth.targetDidChange(name.rawValue)
                self?.bluetooth.journal.persist()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screenAvailable = true; self?.bluetooth.journal.record("mac_active", detail: name.rawValue)
                self?.bluetooth.targetDidChange(name.rawValue)
            })
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func windowDidMiniaturize(_ notification: Notification) { bluetooth.targetDidChange("window_minimized") }
    func windowDidDeminiaturize(_ notification: Notification) { bluetooth.targetDidChange("window_restored") }
    func applicationWillTerminate(_ notification: Notification) { uiTimer?.invalidate(); bluetooth.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Developer-only invocation; labels its evidence and never starts Bluetooth.
    private func runOutputSelfCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let start = scroll.contentView.bounds.minY
            let forward = applyScroll(120.5)
            let middle = scroll.contentView.bounds.minY
            let reverse = applyScroll(-40.25)
            let end = scroll.contentView.bounds.minY
            for _ in 0..<10 { _ = applyScroll(0.1) }
            let tiny = scroll.contentView.bounds.minY - end
            let marked = mark()
            let passed = forward && reverse && marked && middle > start && end < middle && end > start && abs(tiny - 1) < 0.01
            let record = "MAC_OUTPUT_SELF_CHECK \(passed ? "PASS" : "FAIL") start=\(start) forward=\(middle) reverse=\(end) ten_tiny_inputs=\(tiny) marks=\(marks) clip_width=\(scroll.contentSize.width) document_width=\(article.frame.width) text_width=\(article.textContainer!.containerSize.width) BLE_NOT_TESTED\n"
            FileHandle.standardOutput.write(Data(record.utf8))
            statusLabel.stringValue = "本地输出自检：\(passed ? "通过" : "失败") · 未测试蓝牙或手表"
            if !ProcessInfo.processInfo.arguments.contains("--keep-open") { NSApp.terminate(nil) }
        }
    }
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

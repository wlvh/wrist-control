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
    private let outputLabel = NSTextField(labelWithString: "滚轮已暂停")
    private var pauseButton: NSButton!
    private lazy var wheel = SystemWheel(journal: bluetooth.journal)
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
        bluetooth.onScroll = { [weak self] in self?.wheel.post(points: $0) ?? false }
        bluetooth.onResetOutput = { [weak self] in self?.wheel.reset() }
        wheel.onEligibilityLost = { [weak self] in self?.bluetooth.targetDidChange("output_eligibility_lost") }
        bluetooth.onSetEnabled = { [weak self] in self?.wheel.setEnabled($0) }
        bluetooth.onExport = { [weak self] in self?.saveDiagnostics(watch: $0, reason: $1) }
        observeLifecycle()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        bluetooth.start()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshDiagnostics() }
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
        window.title = "腕控 · 通用滚轮"; window.minSize = NSSize(width: 650, height: 500)
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
        let hint = NSTextField(wrappingLabelWithString: "把鼠标留在需要滚动的区域，表冠就像普通鼠标滚轮。腕控窗口可以最小化；手表按钮可暂停／继续。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        container.addArrangedSubview(hint)
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 18
        pauseButton = NSButton(title: "继续滚轮", target: self, action: #selector(toggleControl))
        row.addArrangedSubview(pauseButton)
        row.addArrangedSubview(NSButton(title: "允许滚轮权限", target: self, action: #selector(requestPermission)))
        let export = NSButton(title: "导出诊断", target: self, action: #selector(exportDiagnostics))
        row.addArrangedSubview(export)
        row.addArrangedSubview(NSButton(title: "展开诊断", target: self, action: #selector(toggleDiagnostics(_:))))
        container.addArrangedSubview(row)
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
        for view in [title, statusLabel, hint, row, outputLabel, diagnosticsLabel, scroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -56).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }

    @objc private func toggleControl() {
        wheel.setEnabled(!wheel.enabled); bluetooth.targetDidChange("mac_user_control"); refreshDiagnostics()
    }

    @objc private func requestPermission() {
        wheel.requestPermission(); bluetooth.targetDidChange("permission_request")
    }

    private func refreshDiagnostics() {
        let state = wheel.state()
        pauseButton.title = wheel.enabled ? "暂停滚轮" : "继续滚轮"
        if !state.contains(.permission) { outputLabel.stringValue = "需要在系统设置 → 隐私与安全性 → 辅助功能中允许腕控。" }
        else if !state.contains(.interactive) { outputLabel.stringValue = "电脑不可交互，或设备密钥不可用；系统输出已停止。" }
        else { outputLabel.stringValue = wheel.enabled ? "滚轮已启用 · 鼠标位置决定接收区域" : "滚轮已暂停 · 点继续或使用手表按钮" }
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
                guard let self else { return }
                update(self.wheel); self.wheel.reset()
                self.bluetooth.journal.record("mac_lifecycle", detail: name.rawValue)
                self.bluetooth.targetDidChange(name.rawValue); self.bluetooth.journal.persist()
            })
        }
        for name in [Notification.Name.NSApplicationProtectedDataWillBecomeUnavailable, Notification.Name.NSApplicationProtectedDataDidBecomeAvailable] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.wheel.protectionAvailable = name == Notification.Name.NSApplicationProtectedDataDidBecomeAvailable
                self.wheel.reset(); self.bluetooth.journal.record("protected_data_changed", detail: name.rawValue)
                self.bluetooth.targetDidChange(name.rawValue); self.bluetooth.journal.persist()
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

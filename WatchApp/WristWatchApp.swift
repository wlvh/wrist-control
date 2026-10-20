import SwiftUI
import WatchKit
import WristCore

@main
struct WristWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene { WindowGroup { CrownView(model: model) } }
}

private struct CrownView: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var crownFocused: Bool
    @AppStorage("pointerGestureEnabled.v3") private var gestureEnabled = false

    private var modeTitle: String {
        switch model.mode { case .a: return "A 转向跟手"; case .b: return "B 翻转跟手"; case .c: return "C 倾斜摇杆"; case .d: return "D 指向定位" }
    }
    private var movementButton: some View {
        Button(model.phase == .moving || model.phase == .preparing ? "停止移动" : "开启移动") {
                model.toggleMovement(); crownFocused = true
            }.tint(model.phase == .moving ? .orange : .blue)
                .disabled(!model.isReady || !model.motionAvailable || (model.mode == .d && !model.calibrationReady))
    }
    @ViewBuilder private var movementControl: some View {
        if #available(watchOS 11.0, *) {
            movementButton.handGestureShortcut(.primaryAction,
                isEnabled: gestureEnabled && model.isReady && !model.settingsOpen && (model.mode != .d || model.calibrationReady))
        } else { movementButton }
    }
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(modeTitle).font(.caption).bold()
                Spacer()
                Button { model.setSettings(true) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).accessibilityLabel("设置")
            }
            Text(model.statusText).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(model.isReady ? Color.green : Color.secondary)
            movementControl
            HStack(spacing: 5) {
                Button("左击") { model.click(.left); crownFocused = true }
                Button("右击") { model.click(.right); crownFocused = true }
            }.disabled(!model.isReady)
            Text("双击：连续点两次左击").font(.system(size: 10)).foregroundStyle(.secondary)
            Button(model.controlEnabled ? "暂停腕控" : "继续腕控") { model.toggleControl(); crownFocused = true }
                .buttonStyle(.plain).font(.system(size: 12)).disabled(!model.canToggle)
        }
        .focusable(!model.settingsOpen)
        .focused($crownFocused)
        .digitalCrownRotation(
            Binding(get: { model.crownPosition }, set: { model.crownMoved(to: $0) }),
            from: CrownDelta.lower, through: CrownDelta.upper,
            sensitivity: .low, isContinuous: true, isHapticFeedbackEnabled: false,
            onChange: { _ in }, onIdle: { model.crownIdle() })
        .padding(.horizontal, 5)
        .sheet(isPresented: Binding(get: { model.settingsOpen }, set: { model.setSettings($0) })) {
            List {
                Text("0.3 四模式实验").font(.caption)
                Picker("模式", selection: Binding(get: { model.mode }, set: { model.selectMode($0) })) {
                    Text("A 转向跟手").tag(PointerMode.a)
                    Text("B 翻转跟手").tag(PointerMode.b)
                    Text("C 倾斜摇杆").tag(PointerMode.c)
                    Text("D 指向定位").tag(PointerMode.d)
                }
                if model.mode == .a || model.mode == .b {
                    Text("本模式速度：")
                    Button("慢 · 800 点/弧度") { model.setSensitivity(800) }
                    Button("初值 · 1600 点/弧度") { model.setSensitivity(1600) }
                    Button("快 · 2400 点/弧度") { model.setSensitivity(2400) }
                } else if model.mode == .c { Text("偏着持续走，回中停止。速度与中立区可在电脑“模式参数”调整。") }
                else { Text("先在电脑点 D 五点标定。D 保留标定关系；参考、屏幕或佩戴改变后须重校。") }
                if #available(watchOS 11.0, *) {
                    Text("先验证屏幕按钮能移动和停止，再启用互点实验。")
                    Toggle("互点两下启停移动", isOn: $gestureEnabled)
                }
                Text("总暂停影响滚轮、移动和点击。停止移动仍能滚轮和点击。")
                Text("当前双击间隔 \(model.doubleClickInterval, specifier: "%.2f") 秒")
                Button("返回控制") { model.setSettings(false) }
            }.navigationTitle("设置")
        }
        .onAppear { model.setActive(scenePhase == .active); crownFocused = true }
        .onDisappear { model.setFocused(false) }
        .onChange(of: scenePhase) { phase in
            model.setActive(phase == .active); crownFocused = phase == .active && !model.settingsOpen
        }
        .onChange(of: crownFocused) { model.setFocused($0) }
        .onChange(of: model.settingsOpen) { open in crownFocused = !open; model.setFocused(!open) }
        .onChange(of: model.focusGeneration) { _ in
            crownFocused = !model.settingsOpen; model.setFocused(!model.settingsOpen)
        }
        .onChange(of: gestureEnabled) { enabled in
            model.journal.record("primary_gesture_enabled", detail: String(enabled)); model.journal.persist()
        }
        .onChange(of: model.isReady) { ready in
            // No movement-start haptic: it would disturb the captured baseline.
            if ready, scenePhase == .active { WKInterfaceDevice.current().play(.success) }
        }
    }
}

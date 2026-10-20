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

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("A 转向跟手").font(.caption).bold()
                Spacer()
                Button { model.setSettings(true) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).accessibilityLabel("设置")
            }
            Text(model.statusText).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(model.isReady ? Color.green : Color.secondary)
            Button(model.phase == .moving || model.phase == .preparing ? "停止移动" : "开启移动") {
                model.toggleMovement(); crownFocused = true
            }.tint(model.phase == .moving ? .orange : .blue).disabled(!model.isReady || !model.motionAvailable)
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
                Text("0.3 build 3 · A 首轮").font(.caption)
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
        .onChange(of: model.isReady) { ready in
            // No movement-start haptic: it would disturb the captured baseline.
            if ready, scenePhase == .active { WKInterfaceDevice.current().play(.success) }
        }
    }
}

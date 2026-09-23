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
        VStack(spacing: 10) {
            Text("腕控").font(.headline)
            Text(model.statusText).font(.caption).multilineTextAlignment(.center)
                .foregroundStyle(model.isReady ? Color.green : Color.secondary)
            Image(systemName: "digitalcrown.horizontal.arrow.clockwise")
                .font(.system(size: 29)).foregroundStyle(model.isReady ? .green : .gray)
                .focusable(true)
                .focused($crownFocused)
                .digitalCrownRotation(
                    Binding(get: { model.crownPosition }, set: { model.crownMoved(to: $0) }),
                    from: CrownDelta.lower, through: CrownDelta.upper,
                    sensitivity: .low, isContinuous: true, isHapticFeedbackEnabled: false,
                    onChange: { _ in }, onIdle: { model.crownIdle() })
            Text(model.inputText).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
            Button(model.controlEnabled ? "暂停滚轮" : "继续滚轮") {
                model.toggleControl(); crownFocused = true
            }.disabled(!model.canToggle)
            Text("鼠标放在哪里，就滚动哪里").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .onAppear {
            model.setActive(scenePhase == .active)
            crownFocused = true
        }
        .onDisappear { model.setFocused(false); model.setActive(false) }
        .onChange(of: scenePhase) { phase in
            model.setActive(phase == .active)
            crownFocused = phase == .active
        }
        .onChange(of: crownFocused) { model.setFocused($0) }
        .onChange(of: model.focusGeneration) { _ in
            crownFocused = true
            model.setFocused(true)
        }
        .onChange(of: model.isReady) { ready in
            if ready, scenePhase == .active { WKInterfaceDevice.current().play(.success) }
        }
    }
}

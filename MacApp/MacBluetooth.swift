import AppKit
import CoreBluetooth
import WristCore

/// All callbacks and UI output execute on the main queue.
final class MacBluetooth: NSObject, CBPeripheralManagerDelegate {
    let journal = Journal(source: "mac")
    var onStatus: ((String) -> Void)?
    var onScroll: ((Double) -> Bool)?
    var onMark: (() -> Bool)?
    var onExport: ((Data?, String) -> Void)?
    var targetReady: () -> Bool = { false }
    private var manager: CBPeripheralManager?
    private var input: CBMutableCharacteristic?
    private var status: CBMutableCharacteristic?
    private var diagnostics: CBMutableCharacteristic?
    private var peer: CBCentral?
    private var gate = SessionGate()
    private var timer: Timer?
    private var pendingAck: Frame?
    private var pendingStatus: Frame?
    private var assembler: DiagnosticAssembler?
    private var exportID: UInt32 = 0
    private var exportStarted = 0.0
    private var exportProgress = 0.0
    private var previousTarget = false
    private(set) var acceptedCount = 0
    private(set) var rejectedCount = 0
    private(set) var markCount = 0
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard manager == nil else { return }
        journal.record("app_launch", detail: "test_window_only; identity_unverified")
        manager = CBPeripheralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        manager?.stopAdvertising(); manager?.removeAllServices()
        onExport = nil
        reset("app_stop"); manager = nil; journal.persist()
    }

    private func reset(_ reason: String) {
        gate.revoke(); peer = nil; pendingAck = nil; pendingStatus = nil
        if assembler != nil { finishExport(nil, reason: reason) }
        journal.record("session_revoked", detail: reason)
    }

    private func report(_ text: String) { onStatus?(text) }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        journal.record("bluetooth_state", detail: String(peripheral.state.rawValue))
        guard peripheral.state == .poweredOn else {
            reset("bluetooth_unavailable")
            switch peripheral.state {
            case .unauthorized: report("蓝牙未授权：在系统设置的隐私与安全性中允许腕控使用蓝牙")
            case .poweredOff: report("蓝牙已关闭")
            case .unsupported: report("当前设备不支持所需蓝牙能力")
            default: report("蓝牙正在准备")
            }
            return
        }
        peripheral.removeAllServices()
        let service = CBMutableService(type: CBUUID(string: BLEIDs.service), primary: true)
        input = CBMutableCharacteristic(type: CBUUID(string: BLEIDs.input), properties: [.write],
                                        value: nil, permissions: [.writeable])
        status = CBMutableCharacteristic(type: CBUUID(string: BLEIDs.status), properties: [.read, .notify],
                                         value: nil, permissions: [.readable])
        diagnostics = CBMutableCharacteristic(type: CBUUID(string: BLEIDs.diagnostics), properties: [.write],
                                              value: nil, permissions: [.writeable])
        service.characteristics = [input!, status!, diagnostics!]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { report("发布蓝牙服务失败"); journal.record("service_failed"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BLEIDs.service)],
                                     CBAdvertisementDataLocalNameKey: "WristControl Test"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        report(error == nil ? "等待手表：请在手表前台打开腕控" : "蓝牙广播失败")
        journal.record(error == nil ? "advertising" : "advertising_failed")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == status?.uuid else { return }
        guard peer == nil || peer?.identifier == central.identifier else {
            journal.record("additional_central_ignored"); return
        }
        peer = central
        peripheral.setDesiredConnectionLatency(.low, for: central)
        journal.record("subscribed", detail: "identity_unverified; awaiting_hello")
        report("已连接，等待协议确认 · 未验证身份")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peer?.identifier == central.identifier, characteristic.uuid == status?.uuid else { return }
        reset("unsubscribed"); report("已断开，等待手表返回")
    }

    private func beginSession() {
        gate.begin(UInt64.random(in: 1...UInt64.max))
        pendingAck = nil; pendingStatus = nil
        previousTarget = targetReady()
        journal.record("session_started", detail: String(gate.session, radix: 16))
        publishStatus()
    }

    private func tick() {
        if assembler != nil, now - exportStarted > 120 || now - exportProgress > 6 {
            finishExport(nil, reason: "watch_export_timeout")
        }
        guard peer != nil, gate.session != 0 else { return }
        let ready = targetReady()
        if ready != previousTarget {
            // Window closure, minimization, screen lock, and restoration isolate old intents.
            if assembler != nil { finishExport(nil, reason: "target_changed") }
            beginSession()
        }
        publishStatus()
    }

    func targetDidChange(_ reason: String) {
        journal.record("target_changed", detail: reason)
        if assembler != nil { finishExport(nil, reason: "target_changed") }
        else if peer != nil, gate.session != 0 { beginSession() }
    }

    private func statusFrame() -> Frame {
        Frame(assembler == nil ? .ready : .exportRequest, session: gate.session,
              sequence: assembler == nil ? gate.lastSequence : exportID,
              value: targetReady() && assembler == nil ? 1 : 0,
              ticket: gate.issue(now: now))
    }

    private func publishStatus() {
        guard gate.session != 0 else { return }
        pendingStatus = statusFrame(); flushNotifications()
        if assembler != nil { report("正在导出两端诊断，控制暂时暂停") }
        else { report(targetReady() ? "测试窗口可控制 · 未验证身份" : "测试窗口不可用，控制已暂停") }
    }

    private func acknowledge(_ frame: Frame, accepted: Bool) {
        pendingAck = Frame(accepted ? .ack : .rejected, session: frame.session,
                           sequence: frame.sequence, ticket: gate.currentTicket)
        flushNotifications()
    }

    private func flushNotifications() {
        guard let manager, let status, let peer else { return }
        if let ack = pendingAck {
            guard manager.updateValue(ack.data, for: status, onSubscribedCentrals: [peer]) else { return }
            pendingAck = nil
        }
        if let latest = pendingStatus,
           manager.updateValue(latest.data, for: status, onSubscribedCentrals: [peer]) { pendingStatus = nil }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flushNotifications() }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peer?.identifier == request.central.identifier, request.characteristic.uuid == status?.uuid,
              gate.session != 0, request.offset == 0 else {
            peripheral.respond(to: request, withResult: .readNotPermitted); return
        }
        request.value = statusFrame().data
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // No partial/multi-write transaction may execute a prefix of actions.
        guard requests.count == 1, let request = requests.first else {
            if let first = requests.first { peripheral.respond(to: first, withResult: .invalidAttributeValueLength) }
            return
        }
        guard request.offset == 0, peer?.identifier == request.central.identifier, let data = request.value else {
            peripheral.respond(to: request, withResult: .writeNotPermitted); return
        }
        if request.characteristic.uuid == diagnostics?.uuid {
            guard var collected = assembler, let chunk = DiagnosticChunk(data: data), collected.append(chunk) else {
                peripheral.respond(to: request, withResult: .unlikelyError); return
            }
            assembler = collected
            exportProgress = now
            peripheral.respond(to: request, withResult: .success)
            if collected.complete {
                let validJSON = (try? JSONSerialization.jsonObject(with: collected.bytes)) != nil
                finishExport(validJSON ? collected.bytes : nil, reason: validJSON ? "watch_and_mac" : "invalid_watch_json")
            }
            return
        }
        guard request.characteristic.uuid == input?.uuid, let frame = Frame(data: data) else {
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength); return
        }
        journal.record("received", frame: frame, detail: "kind=\(frame.kind);value=\(frame.value)")
        if frame.kind == .hello {
            guard assembler == nil, frame.session == 0, frame.sequence == 0, frame.value == 0 else {
                peripheral.respond(to: request, withResult: .unlikelyError); return
            }
            beginSession(); peripheral.respond(to: request, withResult: .success); return
        }
        if let reason = gate.accept(frame, now: now, targetReady: targetReady() && assembler == nil) {
            rejectedCount += 1; journal.record("rejected", frame: frame, detail: reason)
            peripheral.respond(to: request, withResult: .success); acknowledge(frame, accepted: false); return
        }
        let receiveTime = now
        let applied: Bool
        switch frame.kind {
        case .scroll: applied = onScroll?(LinearScroll.points(frame.value)) ?? false
        case .mark:
            applied = onMark?() ?? false
            if applied { markCount += 1 }
        case .idle: applied = true
        default: applied = false
        }
        if applied { acceptedCount += 1 } else { rejectedCount += 1 }
        journal.record(applied ? "handled" : "output_rejected", frame: frame,
                       detail: "receive_to_handler_ms=\((now - receiveTime) * 1000);not_display_latency")
        peripheral.respond(to: request, withResult: .success)
        acknowledge(frame, accepted: applied)
    }

    func exportDiagnostics() {
        guard assembler == nil else { return }
        journal.record("export_requested"); journal.persist()
        guard peer != nil, gate.session != 0 else { onExport?(nil, "watch_unavailable_mac_only"); return }
        exportID = exportID == UInt32.max ? 1 : exportID + 1
        assembler = DiagnosticAssembler(session: gate.session); exportStarted = now; exportProgress = now
        publishStatus()
    }

    private func finishExport(_ data: Data?, reason: String) {
        assembler = nil
        journal.record("export_finished", detail: reason)
        // Fresh session after export: no prior pending action is allowed to execute.
        if peer != nil { beginSession() }
        onExport?(data, reason)
    }
}

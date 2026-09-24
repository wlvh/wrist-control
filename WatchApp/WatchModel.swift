import Foundation
import CoreBluetooth
import Combine
import WristCore
import CryptoKit

/// Main-queue only. No background mode, phone companion, or network transport.
final class WatchModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var statusText = "打开电脑腕控"
    @Published var isReady = false
    @Published var controlEnabled = false
    @Published var canToggle = false
    @Published var crownPosition = 0.0
    @Published var focusGeneration = 0
    @Published var inputText = "等待连接"
    let journal = Journal(source: "watch")
    private var link: AuthenticatedLink?
    private var hello: Frame?
    private var pendingProof: Data?
    private var desiredControl: Bool?
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var status: CBCharacteristic?
    private var diagnostics: CBCharacteristic?
    private var active = false
    private var focused = false
    private var session: UInt64 = 0
    private var sequence: UInt32 = 0
    private var ticket: UInt16 = 0
    private var delta = CrownDelta()
    private var mapping = LinearScroll()
    private var buffer = ScrollBuffer()
    private var writeInFlight: Frame?
    private var awaitingAck: Frame?
    private var sentAt = 0.0
    private var lastStatus = 0.0
    private var connectingAt = 0.0
    private var retryAfter = 0.0
    private var timer: Timer?
    private var idlePending = false
    private var exportData: Data?
    private var exportOffset = 0
    private var exportIndex: UInt16 = 0
    private var exportWriting = false
    private var lastExportID: UInt32?
    private var lastExportProgress = 0.0
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        journal.record("app_launch", detail: "system_wheel_v2;foreground_only")
        journal.persist()
        let keyStatus = PairingKeyStore.importBootstrapIfPresent()
        journal.record("pair_key_load", detail: "key_status=\(keyStatus)")
        journal.persist()
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value; journal.record(value ? "scene_active" : "scene_inactive")
        journal.persist()
        clearIntent(); delta.rebase(to: crownPosition)
        if value {
            if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
            timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
            scanIfPossible()
        } else {
            timer?.invalidate(); timer = nil; manager?.stopScan()
            invalidateConnection(reason: "app_policy_disconnect_nonactive")
            statusText = "待唤醒后重新连接"; journal.persist()
        }
    }

    func setFocused(_ value: Bool) {
        focused = value; delta.rebase(to: crownPosition); buffer.clear(); mapping.reset()
        journal.record("crown_focus", detail: String(value))
    }

    func crownMoved(to position: Double) {
        crownPosition = position
        journal.record("crown_callback", detail: "coordinate=\(position);active=\(active);focus=\(focused);ready=\(isReady)")
        guard let amount = delta.update(position) else {
            journal.record("crown_dropped", detail: "baseline_or_discontinuity"); return
        }
        guard active, focused, isReady, exportData == nil else {
            journal.record("crown_dropped", detail: "input_not_eligible"); return
        }
        guard let fixed = mapping.convert(delta: amount), fixed != 0 else { return }
        journal.record("crown_generated", detail: "coordinate=\(position);delta=\(amount);fixed=\(fixed)")
        inputText = amount > 0 ? "向下阅读" : "向上阅读"
        idlePending = false; buffer.add(fixed, now: now); flushIntent()
    }

    func crownIdle() {
        // Never drain a buffer after the user has stopped turning.
        buffer.clear(); mapping.reset(); idlePending = true
        inputText = isReady ? "已停手" : "等待连接"
        journal.record("crown_idle"); flushIntent(); journal.persist()
    }

    func toggleControl() {
        guard canToggle, active, exportData == nil else { return }
        desiredControl = !controlEnabled
        buffer.clear(); mapping.reset(); idlePending = false; isReady = false; canToggle = false
        inputText = "等待电脑确认"
        flushIntent()
    }

    private func clearIntent() {
        isReady = false; canToggle = false; desiredControl = nil; buffer.clear(); mapping.reset(); idlePending = false
        delta.rebase(to: crownPosition); awaitingAck = nil
    }

    private func invalidateConnection(reason: String) {
        clearIntent(); link = nil; hello = nil; pendingProof = nil; controlEnabled = false; session = 0; sequence = 0; ticket = 0
        writeInFlight = nil; exportData = nil; exportWriting = false; lastExportID = nil
        input = nil; status = nil; diagnostics = nil
        if let old = peripheral { manager?.cancelPeripheralConnection(old) }
        peripheral = nil; retryAfter = now + 1
        journal.record("connection_invalidated", detail: reason)
    }

    private func scanIfPossible() {
        guard active, manager?.state == .poweredOn, peripheral == nil, now >= retryAfter else { return }
        guard manager?.isScanning == false else { return }
        guard PairingKeyStore.read().data != nil else {
            statusText = "尚未配置设备密钥"; return
        }
        statusText = "寻找已授权的电脑"
        manager?.scanForPeripherals(withServices: [CBUUID(string: BLEIDs.service)], options: nil)
        journal.record("scan_started")
    }

    private func tick() {
        guard active else { return }
        scanIfPossible()
        if exportData != nil {
            if now - lastExportProgress > 6 { reconnect("diagnostic_write_timeout") }
            return
        }
        if (awaitingAck != nil || writeInFlight != nil), now - sentAt > 0.65 {
            reconnect("action_ack_timeout"); return
        }
        if session == 0, peripheral != nil, now - connectingAt > 10 {
            reconnect("connection_setup_timeout"); return
        }
        if session != 0, now - lastStatus > 0.6 {
            reconnect("status_timeout"); return
        }
        flushIntent()
    }

    private func reconnect(_ reason: String) {
        statusText = "连接中断，正在重新寻找"
        invalidateConnection(reason: reason); journal.persist()
    }

    private func flushIntent() {
        guard active, link != nil, session != 0, exportData == nil, writeInFlight == nil, awaitingAck == nil else { return }
        if let enabled = desiredControl { sendAction(.setControl, value: enabled ? 1 : 0); return }
        guard focused, isReady else { return }
        if let amount = buffer.take(now: now) { sendAction(.scroll, value: amount) }
        else if idlePending { idlePending = false; sendAction(.idle) }
    }

    private func sendAction(_ kind: MessageKind, value: Int32 = 0) {
        guard sequence < UInt32.max else { reconnect("sequence_exhausted"); return }
        sequence += 1
        let frame = Frame(kind, session: session, sequence: sequence, value: value, ticket: ticket)
        awaitingAck = frame; write(frame)
    }

    private func write(_ frame: Frame, handshake: Data? = nil) {
        guard let peripheral, let input,
              peripheral.maximumWriteValueLength(for: .withoutResponse) >= AuthenticatedLink.frameSize,
              let packet = handshake ?? link?.seal(frame.data, purpose: .input) else {
            reconnect("missing_input_key_or_small_mtu"); return
        }
        writeInFlight = frame; sentAt = now
        journal.record("transmit", frame: frame, detail: "kind=\(frame.kind);value=\(frame.value)")
        peripheral.writeValue(packet, for: input, type: .withResponse)
    }

    private func sendProofIfPossible() {
        guard writeInFlight == nil, let packet = pendingProof,
              let frame = Frame(data: packet.prefix(Frame.size)) else { return }
        pendingProof = nil; write(frame, handshake: packet)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        journal.record("bluetooth_state", detail: String(central.state.rawValue))
        guard central.state == .poweredOn else {
            invalidateConnection(reason: "bluetooth_unavailable")
            statusText = central.state == .unauthorized ? "请在设置允许蓝牙" : "蓝牙尚不可用"
            return
        }
        scanIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didDiscover candidate: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, peripheral == nil else { return }
        central.stopScan(); peripheral = candidate; candidate.delegate = self
        connectingAt = now; statusText = "已找到，正在连接"
        journal.record("discovered", detail: "rssi=\(RSSI)")
        central.connect(candidate, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        guard active, connected === peripheral else { central.cancelPeripheralConnection(connected); return }
        statusText = "连接成功，验证电脑身份"
        journal.record("connected"); connected.discoverServices([CBUUID(string: BLEIDs.service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect candidate: CBPeripheral, error: Error?) {
        guard candidate === peripheral else { return }; reconnect("connect_failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral candidate: CBPeripheral, error: Error?) {
        guard candidate === peripheral else { return }; reconnect("disconnected")
    }

    func peripheral(_ candidate: CBPeripheral, didDiscoverServices error: Error?) {
        guard active, candidate === peripheral else { return }
        guard error == nil, let service = candidate.services?.first(where: { $0.uuid == CBUUID(string: BLEIDs.service) }) else {
            reconnect("service_missing"); return
        }
        candidate.discoverCharacteristics([CBUUID(string: BLEIDs.input), CBUUID(string: BLEIDs.status),
                                          CBUUID(string: BLEIDs.diagnostics)], for: service)
    }

    func peripheral(_ candidate: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active, candidate === peripheral else { return }
        guard error == nil else { reconnect("characteristic_discovery_failed"); return }
        input = service.characteristics?.first { $0.uuid == CBUUID(string: BLEIDs.input) }
        status = service.characteristics?.first { $0.uuid == CBUUID(string: BLEIDs.status) }
        diagnostics = service.characteristics?.first { $0.uuid == CBUUID(string: BLEIDs.diagnostics) }
        guard let input, input.properties.contains(.write), let status,
              status.properties.contains(.notify), let diagnostics, diagnostics.properties.contains(.write) else {
            reconnect("incompatible_characteristics"); return
        }
        candidate.setNotifyValue(true, for: status)
    }

    func peripheral(_ candidate: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active, candidate === peripheral, characteristic.uuid == status?.uuid else { return }
        guard error == nil, characteristic.isNotifying else { reconnect("subscribe_failed"); return }
        let nonce = PairAuthentication.nonce(.hello); hello = nonce
        journal.record("subscribed", detail: "mtu=\(candidate.maximumWriteValueLength(for: .withoutResponse))")
        write(nonce, handshake: nonce.data)
    }

    func peripheral(_ candidate: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, candidate === peripheral, characteristic.uuid == status?.uuid else { return }
        guard error == nil, let data = characteristic.value else { reconnect("invalid_status"); return }
        if let hello, link == nil {
            guard let bytes = PairingKeyStore.read().data else { reconnect("pair_key_unavailable"); return }
            let secret = SymmetricKey(data: bytes)
            guard let challenge = PairAuthentication.verifiedChallenge(data, secret: secret, hello: hello) else {
                reconnect("computer_authentication_failed"); return
            }
            link = AuthenticatedLink(key: PairAuthentication.sessionKey(secret: secret, hello: hello, challenge: challenge), role: .watch)
            pendingProof = PairAuthentication.proofPacket(secret: secret, hello: hello, challenge: challenge)
            self.hello = nil; sendProofIfPossible(); return
        }
        guard let payload = link?.open(data, purpose: .status), let frame = Frame(data: payload) else {
            journal.record("status_authentication_or_replay_rejected"); return
        }
        switch frame.kind {
        case .ready, .exportRequest:
            guard frame.session != 0 else { reconnect("zero_session"); return }
            lastStatus = now; ticket = frame.ticket
            if frame.session != session {
                clearIntent(); session = frame.session; sequence = 0
                exportData = nil; lastExportID = nil; exportWriting = false
                focusGeneration += 1
                journal.record("new_session", frame: frame, detail: "authenticated_transport")
            }
            if frame.kind == .exportRequest {
                clearIntent(); statusText = "正在导出诊断"
                if lastExportID != frame.sequence {
                    lastExportID = frame.sequence
                    journal.record("diagnostic_snapshot"); journal.persist()
                    exportData = journal.snapshot(); exportOffset = 0; exportIndex = 0
                    lastExportProgress = now
                }
                sendDiagnosticChunk(); return
            }
            let state = ControlState(rawValue: frame.value)
            controlEnabled = state.contains(.enabled); canToggle = desiredControl == nil
            let ready = state.canScroll && desiredControl == nil
            if ready != isReady {
                buffer.clear(); mapping.reset(); delta.rebase(to: crownPosition)
                isReady = ready; focusGeneration += 1
                journal.record(ready ? "system_output_ready" : "system_output_unavailable", frame: frame)
            }
            if !state.contains(.permission) { statusText = "请在电脑允许滚轮权限" }
            else if !state.contains(.interactive) { statusText = "电脑锁定或暂不可用" }
            else { statusText = ready ? "滚动鼠标所在区域" : "已暂停" }
        case .ack:
            guard frame.session == session, let pending = awaitingAck, frame.acknowledges(pending) else { return }
            journal.record("application_ack", frame: frame, detail: "round_trip_ms=\((now - sentAt) * 1000);not_one_way_latency")
            if pending.kind == .setControl { desiredControl = nil; inputText = pending.value == 1 ? "已请求继续" : "已暂停" }
            awaitingAck = nil; flushIntent()
        case .rejected:
            guard frame.session == session, let pending = awaitingAck, frame.acknowledges(pending) else { return }
            journal.record("action_rejected", frame: frame)
            buffer.clear(); awaitingAck = nil; desiredControl = nil; inputText = "本次未执行，请重试"
            if let status { candidate.readValue(for: status) }
        default: reconnect("unexpected_status_kind")
        }
    }

    func peripheral(_ candidate: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, candidate === peripheral else { return }
        guard error == nil else { reconnect("att_write_failed"); return }
        if characteristic.uuid == diagnostics?.uuid {
            exportWriting = false; lastExportProgress = now; sendDiagnosticChunk()
        } else if characteristic.uuid == input?.uuid {
            if let frame = writeInFlight { journal.record("att_ack", frame: frame, detail: "transport_only") }
            writeInFlight = nil
            if pendingProof != nil { sendProofIfPossible(); return }
            if exportData != nil { sendDiagnosticChunk() } else { flushIntent() }
        }
    }

    private func sendDiagnosticChunk() {
        guard let data = exportData, !exportWriting, writeInFlight == nil,
              let peripheral, let diagnostics else { return }
        if exportOffset >= data.count { exportData = nil; return }
        let capacity = peripheral.maximumWriteValueLength(for: .withoutResponse) - DiagnosticChunk.headerSize - AuthenticatedLink.overhead
        guard capacity > 0, data.count / capacity < Int(UInt16.max) else { reconnect("diagnostic_mtu_too_small"); return }
        let end = min(data.count, exportOffset + capacity)
        let chunk = DiagnosticChunk(session: session, index: exportIndex, final: end == data.count,
                                    payload: data.subdata(in: exportOffset..<end))
        exportOffset = end; exportIndex += 1; exportWriting = true
        guard let packet = link?.seal(chunk.data, purpose: .diagnostic) else { reconnect("diagnostic_key_missing"); return }
        peripheral.writeValue(packet, for: diagnostics, type: .withResponse)
    }
}

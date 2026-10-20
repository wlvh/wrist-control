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
    @Published private var intentState = WatchIntentState()
    var phase: PointerPhase {
        get { intentState.phase }
        set { intentState.phase = newValue }
    }
    @Published var mode: PointerMode = .a
    @Published var settingsOpen = false
    @Published var doubleClickInterval = 0.5
    @Published var motionAvailable = false
    @Published var calibrationReady = false
    private let motion = WatchMotion()
    private var scope: OutputScope = .system
    private var intentCycle: UInt32 {
        get { intentState.cycle }
        set { intentState.cycle = newValue }
    }
    private var confirmedCycle: UInt32 = 0
    private var confirmedPhase: PointerPhase = .paused
    private var clickID: UInt64 = 0
    private var lastSentSample: UInt32 = 0
    private var lastSentReference: UInt64 = 0
    private var poseTransmits = 0
    private var lastPoseSentAt = 0.0
    private var lastStatistics = 0.0
    private var lastPersisted = 0.0
    private struct PendingAction {
        let kind: MessageKind
        let value: Int32
        let cycle: UInt32
        let click: ClickRequest?
        let generatedAt: Double
    }
    private var pendingActions: [PendingAction] = []
    private var clientInfoPending = true
    private var pageSyncPending = true
    let journal = Journal(source: "watch")
    private var link: AuthenticatedLink?
    private var hello: Frame?
    private var pendingProof: Data?
    private var desiredControl: Bool? {
        get { intentState.desiredControl }
        set { intentState.desiredControl = newValue }
    }
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
        journal.record("app_launch", detail: "pointer_v3;foreground_only;sample50_send30")
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
            lastStatistics = now; poseTransmits = 0; _ = motion.statistics()
            motion.start(); motionAvailable = motion.available
            let pulse = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(pulse, forMode: .common); timer = pulse
            scanIfPossible()
        } else {
            timer?.invalidate(); timer = nil; manager?.stopScan(); motion.stop()
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
        guard active, focused, !settingsOpen, isReady, exportData == nil else {
            journal.record("crown_dropped", detail: "input_not_eligible"); return
        }
        guard amount != 0 else { return }
        // First real Crown intent closes the movement cycle even if its fractional
        // wheel amount has not yet produced a fixed-point unit.
        let fixed = mapping.convert(delta: amount) ?? 0
        if phase == .moving || phase == .preparing {
            guard let cycle = nextCycle() else { return }
            phase = .reading; pendingActions.removeAll()
            // A nonzero wheel packet carries the barrier itself. No extra
            // stop/ACK round trip delays the first wheel movement.
            if fixed == 0 {
                pendingActions.append(PendingAction(kind: .stopMovement, value: 0, cycle: cycle, click: nil, generatedAt: now))
                flushIntent()
            }
        }
        guard fixed != 0 else { return }
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
        phase = desiredControl == true ? .reading : .paused
        pendingActions.removeAll()
        buffer.clear(); mapping.reset(); idlePending = false; isReady = false; canToggle = false
        inputText = "等待电脑确认"
        flushIntent()
    }

    private func nextCycle() -> UInt32? {
        let previous = max(intentCycle, confirmedCycle)
        guard previous < UInt32.max else { reconnect("cycle_exhausted"); return nil }
        intentCycle = previous + 1; return intentCycle
    }

    func toggleMovement() {
        guard active, isReady, !settingsOpen, exportData == nil else { return }
        if phase == .moving || phase == .preparing { stopMovement(reason: "button"); return }
        guard motionAvailable, let cycle = nextCycle() else { return }
        buffer.clear(); pendingActions.removeAll(); phase = .preparing
        pendingActions.append(PendingAction(kind: .startMovement, value: 0, cycle: cycle, click: nil, generatedAt: now))
        inputText = "手腕停稳片刻"; journal.record("movement_toggle", detail: "request_start;cycle=\(cycle)")
        flushIntent()
    }

    func stopMovement(reason: String) {
        guard session != 0, let cycle = nextCycle() else { return }
        phase = .reading; pendingActions.removeAll(); buffer.clear()
        pendingActions.append(PendingAction(kind: .stopMovement, value: 0, cycle: cycle, click: nil, generatedAt: now))
        journal.record("movement_toggle", detail: "stop;cycle=\(cycle);reason=\(reason)")
        flushIntent()
    }

    func click(_ button: PointerButton) {
        guard active, isReady, !settingsOpen, exportData == nil, clickID < UInt64.max,
              let cycle = nextCycle() else { return }
        phase = .reading; buffer.clear(); idlePending = false
        pendingActions.removeAll { $0.kind != .leftClick && $0.kind != .rightClick }
        guard pendingActions.count < 2 else { stopMovement(reason: "click_queue_full"); return }
        clickID += 1
        let request = ClickRequest(id: clickID, button: button, watchTime: now, cycle: cycle)
        pendingActions.append(PendingAction(kind: button == .left ? .leftClick : .rightClick, value: 0,
                                           cycle: cycle, click: request, generatedAt: now))
        inputText = button == .left ? "左击 · 移动已冻结" : "右击 · 移动已冻结"
        journal.record("click_generated", detail: "request=\(request.id);cycle=\(cycle)")
        flushIntent()
    }

    func setSettings(_ open: Bool) {
        settingsOpen = open; delta.rebase(to: crownPosition); buffer.clear(); mapping.reset()
        guard session != 0, let cycle = nextCycle() else { return }
        phase = controlEnabled ? .reading : .paused
        if open { pendingActions.removeAll() }
        pendingActions.append(PendingAction(kind: .mainPage, value: open ? 0 : 1, cycle: cycle, click: nil, generatedAt: now))
        focusGeneration += 1; flushIntent()
    }

    func selectMode(_ value: PointerMode) {
        guard session != 0, let cycle = nextCycle() else { return }
        phase = controlEnabled ? .reading : .paused; pendingActions.removeAll { $0.kind != .mainPage }; buffer.clear()
        pendingActions.append(PendingAction(kind: .setMode, value: Int32(value.rawValue), cycle: cycle, click: nil, generatedAt: now))
        flushIntent()
    }

    func setSensitivity(_ value: Int) {
        guard session != 0, let cycle = nextCycle() else { return }
        pendingActions.removeAll { ![.mainPage, .setMode].contains($0.kind) }; buffer.clear(); phase = .reading
        pendingActions.append(PendingAction(kind: .setSensitivity, value: Int32(value), cycle: cycle, click: nil, generatedAt: now))
        flushIntent()
    }

    private func clearIntent() {
        phase = .paused; pendingActions.removeAll(); intentCycle = 0; confirmedCycle = 0; confirmedPhase = .paused
        clickID = 0; lastSentSample = 0; lastSentReference = 0
        clientInfoPending = true
        pageSyncPending = true
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
        motion.start() // restarts only if the system wrist/crown setting changed
        if now - lastStatistics >= 1 {
            let counts = motion.statistics()
            journal.record("motion_transport_window", detail: "seconds=\(now-lastStatistics);samples=\(counts.samples);invalid=\(counts.invalid);pose_transmit=\(poseTransmits)")
            lastStatistics = now; poseTransmits = 0
            if now - lastPersisted >= 5 { journal.persist(); lastPersisted = now }
        }
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
        if clientInfoPending {
            clientInfoPending = false
            if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
               let number = Int32(build), let revision = Bundle.main.object(forInfoDictionaryKey: "WristSourceRevision") as? String,
               revision.utf8.count == 40 {
                sendAction(.clientInfo, value: number, revision: revision); return
            }
        }
        if pageSyncPending {
            guard let cycle = nextCycle() else { return }
            pageSyncPending = false
            sendAction(.mainPage, value: settingsOpen ? 0 : 1, cycle: cycle); return
        }
        while !pendingActions.isEmpty {
            let pending = pendingActions.removeFirst()
            // Reliable does not mean replay indefinitely; only stop/page changes
            // can outlive the short user-action queue.
            if now - pending.generatedAt > (pending.click == nil ? 0.35 : 0.15),
               ![.stopMovement, .mainPage].contains(pending.kind) {
                journal.record("queued_action_expired", detail: String(describing: pending.kind))
                phase = .reading; continue
            }
            sendAction(pending.kind, value: pending.value, cycle: pending.cycle, click: pending.click,
                       age: now - pending.generatedAt); return
        }
        guard focused, isReady, !settingsOpen else { return }
        if let amount = buffer.take(now: now) { sendAction(.scroll, value: amount, cycle: intentCycle) }
        else if idlePending { idlePending = false; sendAction(.idle) }
        else { sendPoseIfPossible() }
    }

    private func sendAction(_ kind: MessageKind, value: Int32 = 0, cycle: UInt32 = 0,
                            click: ClickRequest? = nil, age: Double = 0, revision: String? = nil) {
        guard sequence < UInt32.max else { reconnect("sequence_exhausted"); return }
        sequence += 1
        let frame = Frame(kind, session: session, sequence: sequence, value: value, ticket: ticket)
        let wire = PointerWire(frame: frame, cycle: cycle, click: click, sourceAge: age, revision: revision)
        let payload = wire.data
        guard !payload.isEmpty else {
            journal.record("invalid_local_packet", detail: String(describing: kind))
            if kind != .clientInfo { reconnect("invalid_local_action") }
            return
        }
        awaitingAck = wire.frame; write(wire.frame, payload: payload)
    }

    private func sendPoseIfPossible() {
        let observing = scope == .calibration || scope == .blindValidation
        guard observing || (intentCycle == confirmedCycle && (confirmedPhase == .preparing || confirmedPhase == .moving)
                            && (phase == .preparing || phase == .moving)),
              let sample = motion.latest(), (sample.referenceID != lastSentReference || sample.sequence > lastSentSample),
              now - lastPoseSentAt >= 1.0 / 30,
              now >= sample.watchTime, now - sample.watchTime <= MotionLimits.maxSampleAge,
              let peripheral, let input, peripheral.canSendWriteWithoutResponse,
              input.properties.contains(.writeWithoutResponse) else { return }
        guard sequence < UInt32.max else { reconnect("sequence_exhausted"); return }
        sequence += 1
        let frame = Frame(.pose, session: session, sequence: sequence, ticket: ticket)
        let body = PointerWire(frame: frame, cycle: max(1, intentCycle), sample: sample, sourceAge: now-sample.watchTime).data
        guard body.count == PointerWire.posePayloadSize, let packet = link?.seal(body, purpose: .input) else { return }
        // One characteristic, one serialization order and authentication counter.
        // Only replace unsent absolute snapshots; Crown deltas use ScrollBuffer.
        peripheral.writeValue(packet, for: input, type: .withoutResponse)
        lastSentSample = sample.sequence; lastSentReference = sample.referenceID; lastPoseSentAt = now; poseTransmits += 1
    }

    private func write(_ frame: Frame, handshake: Data? = nil, payload: Data? = nil) {
        guard let peripheral, let input,
              peripheral.maximumWriteValueLength(for: .withoutResponse) >= PointerWire.maximumInputSize,
              let packet = handshake ?? link?.seal(payload ?? frame.data, purpose: .input) else {
            reconnect("missing_input_key_or_small_mtu"); return
        }
        writeInFlight = frame; sentAt = now
        journal.record("transmit", frame: frame, detail: "kind=\(frame.kind);value=\(frame.value)")
        peripheral.writeValue(packet, for: input, type: .withResponse)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }; flushIntent()
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
        guard candidate === peripheral else { return }
        if let e = error as NSError? { journal.record("connect_error", detail: "domain=\(e.domain);code=\(e.code);\(e.localizedDescription)") }
        reconnect("connect_failed")
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
        guard let payload = link?.open(data, purpose: .status),
              let frame = Frame(data: payload.prefix(Frame.size)) else {
            journal.record("status_authentication_or_replay_rejected"); return
        }
        switch frame.kind {
        case .ready, .exportRequest:
            guard let pointerStatus = PointerStatus(data: payload) else { reconnect("invalid_pointer_status"); return }
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
            confirmedCycle = pointerStatus.cycle; confirmedPhase = pointerStatus.phase
            scope = pointerStatus.scope; mode = pointerStatus.mode; doubleClickInterval = pointerStatus.doubleClickInterval
            calibrationReady = frame.value & 8 != 0
            intentState.confirm(cycle: confirmedCycle, phase: confirmedPhase)
            let state = ControlState(rawValue: frame.value)
            controlEnabled = state.contains(.enabled); canToggle = desiredControl == nil
            let ready = state.canScroll && desiredControl == nil && !pageSyncPending && awaitingAck?.kind != .mainPage
            if ready != isReady {
                buffer.clear(); mapping.reset(); delta.rebase(to: crownPosition)
                isReady = ready; focusGeneration += 1
                journal.record(ready ? "system_output_ready" : "system_output_unavailable", frame: frame)
            }
            if !state.contains(.permission) { statusText = "请在电脑允许滚轮权限" }
            else if !state.contains(.interactive) { statusText = "电脑锁定或暂不可用" }
            else if scope == .calibration { statusText = "标定中 · 只看电脑目标" }
            else if scope == .blindValidation { statusText = "独立指向验证" }
            else if ready, mode == .d, !calibrationReady { statusText = "D 待标定 · 滚轮点击可用" }
            else { statusText = ready ? (phase == .moving ? "手腕移动中" : phase == .preparing ? "请停稳手腕" : "滚轮和点击可用") : "整个腕控已暂停" }
            flushIntent()
        case .ack:
            guard frame.session == session, let pending = awaitingAck, frame.acknowledges(pending) else { return }
            journal.record("application_ack", frame: frame, detail: "round_trip_ms=\((now - sentAt) * 1000);not_one_way_latency")
            if pending.kind == .setControl { desiredControl = nil; inputText = pending.value == 1 ? "已请求继续" : "已暂停" }
            awaitingAck = nil; flushIntent()
        case .rejected:
            guard frame.session == session, let pending = awaitingAck, frame.acknowledges(pending) else { return }
            journal.record("action_rejected", frame: frame)
            buffer.clear(); awaitingAck = nil
            intentState.reject(kind: pending.kind, actionCycle: UInt32(bitPattern: pending.value), controlEnabled: controlEnabled)
            if pending.kind == .mainPage { pageSyncPending = true }
            inputText = "本次未执行，请重试"
            if let status { candidate.readValue(for: status) }
        default: reconnect("unexpected_status_kind")
        }
    }

    func peripheral(_ candidate: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, candidate === peripheral else { return }
        guard error == nil else {
            if let e = error as NSError? { journal.record("att_error", detail: "domain=\(e.domain);code=\(e.code);\(e.localizedDescription)") }
            reconnect("att_write_failed"); return
        }
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

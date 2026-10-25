import CoreBluetooth
import Foundation

/// BLE 只搬运 Link 字节流；握手、加密、音频序号与补发仍由 LinkClient 处理。
final class BLELinkClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: IMicLink.bleServiceUUID)
    static let uplink = CBUUID(string: IMicLink.bleUplinkUUID)
    static let downlink = CBUUID(string: IMicLink.bleDownlinkUUID)
    static let identity = CBUUID(string: IMicLink.bleIdentityUUID)

    private struct Write {
        let data: Data
        let type: CBCharacteristicWriteType
        let completion: ((Bool) -> Void)?
        var offset = 0
    }

    // 600 秒 PCM16、逐帧加密开销及整段重发仍可容纳；超限整条链路失败，绝不丢帧后继续。
    private static let maximumQueuedBytes = 64 * 1024 * 1024
    private let queue = DispatchQueue(label: "imic.ble.client")
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var uplink: CBCharacteristic?
    private var downlink: CBCharacteristic?
    private var pending: [Write?] = []
    private var head = 0
    private var queuedBytes = 0
    private var pendingPreviewIndex: Int?
    private var coalescedPreviews = 0
    private var acknowledgedWriteBytes = 0
    private var connected = false
    private var lost = false
    private var generation: UInt64 = 0
    private var targetMacID: String?
    private var rejected: Set<UUID> = []
    private var timeout: DispatchWorkItem?
    private var transferredBytes = 0
    private var reportedBytes = 0
    private var reportTime = ProcessInfo.processInfo.systemUptime

    var onConnected: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onLost: (() -> Void)?

    func start(targetMacID: String? = nil) {
        queue.async { [self] in
            guard self.manager == nil else { return }
            self.generation &+= 1
            let generation = self.generation
            self.lost = false
            self.targetMacID = targetMacID
            self.rejected.removeAll()
            self.transferredBytes = 0
            self.reportedBytes = 0
            self.reportTime = ProcessInfo.processInfo.systemUptime
            self.manager = CBCentralManager(delegate: self, queue: self.queue)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation, !self.connected else { return }
                self.fail("connection timeout")
            }
            self.timeout = work
            self.queue.asyncAfter(deadline: .now() + 12, execute: work)
        }
    }

    func stop() {
        queue.async { self.reset() }
    }

    /// completion 始终在 BLE 队列调用一次；控制帧最后一个分片收到 ATT 确认才成功。
    func send(_ data: Data, replacingPreview: Bool = false, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            guard self.connected, !self.lost else { completion?(false); return }
            guard !data.isEmpty else { completion?(true); return }
            let kindIndex = data.index(data.startIndex, offsetBy: min(4, data.count))
            let isAudio = data.count > 4 && data[kindIndex] == LinkFrameKind.sealedAudio.rawValue
            let replaceable = replacingPreview && completion == nil
            let replacement: Int?
            if replaceable, let index = self.pendingPreviewIndex,
               index >= self.head, index < self.pending.count,
               let old = self.pending[index], old.offset == 0,
               index != self.head || self.acknowledgedWriteBytes == 0 {
                replacement = index
            } else {
                replacement = nil
            }
            let replacedBytes = replacement.flatMap { self.pending[$0]?.data.count } ?? 0
            guard data.count <= Self.maximumQueuedBytes - self.queuedBytes + replacedBytes else {
                completion?(false)
                self.fail("uplink queue capacity exceeded queued=\(self.queuedBytes) incoming=\(data.count)")
                return
            }
            let write = Write(data: data, type: isAudio ? .withoutResponse : .withResponse, completion: completion)
            if let replacement {
                // 只替换一字节也尚未发送的临时预览；音频和已开始的帧绝不改变。
                self.pending[replacement] = write
                self.coalescedPreviews += 1
            } else {
                if replaceable { self.pendingPreviewIndex = self.pending.count }
                else if !isAudio { self.pendingPreviewIndex = nil }
                self.pending.append(write)
            }
            self.queuedBytes += data.count - replacedBytes
            self.pump()
            self.reportTransfer()
        }
    }

    private func pump() {
        guard connected, !lost, acknowledgedWriteBytes == 0,
              let peripheral, let uplink else { return }
        // canSend 为 true 时不会保证再回调 ready，必须在本次持续排空。
        while head < pending.count, let item = pending[head] {
            if item.type == .withoutResponse, !peripheral.canSendWriteWithoutResponse { return }
            let limit = peripheral.maximumWriteValueLength(for: item.type)
            guard limit > 0 else { fail("invalid uplink MTU"); return }
            let size = min(limit, item.data.count - item.offset)
            let start = item.data.index(item.data.startIndex, offsetBy: item.offset)
            let end = item.data.index(start, offsetBy: size)
            let part = item.data.subdata(in: start..<end)
            if pendingPreviewIndex == head { pendingPreviewIndex = nil }
            if item.type == .withResponse {
                acknowledgedWriteBytes = size
                peripheral.writeValue(part, for: uplink, type: .withResponse)
                return
            }
            peripheral.writeValue(part, for: uplink, type: .withoutResponse)
            consume(size)
        }
        reportTransfer(force: true)
    }

    private func consume(_ size: Int) {
        guard head < pending.count, var item = pending[head] else { return }
        item.offset += size
        queuedBytes -= size
        transferredBytes += size
        if item.offset == item.data.count {
            pending[head] = nil
            head += 1
            compact()
            item.completion?(true)
        } else {
            pending[head] = item
        }
        reportTransfer()
    }

    private func compact() {
        if head == pending.count {
            pending.removeAll(keepingCapacity: true)
            head = 0
            pendingPreviewIndex = nil
        } else if head >= 1024, head >= pending.count / 2 {
            let consumed = head
            pending.removeFirst(consumed)
            head = 0
            if let index = pendingPreviewIndex {
                pendingPreviewIndex = index >= consumed ? index - consumed : nil
            }
        }
    }

    private func reportTransfer(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - reportTime
        guard elapsed >= 2 || (force && queuedBytes == 0 && transferredBytes - reportedBytes >= 32_768) else { return }
        let rate = Int(Double(transferredBytes - reportedBytes) / max(elapsed, 0.001))
        IMicLog.write("iphone.ble", "uplink bytes=\(transferredBytes) queued=\(queuedBytes) bytesPerSecond=\(rate) coalescedPreviews=\(coalescedPreviews)")
        reportTime = now
        reportedBytes = transferredBytes
    }

    private func reset() {
        generation &+= 1
        connected = false
        timeout?.cancel()
        timeout = nil
        manager?.stopScan()
        peripheral?.delegate = nil
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        manager?.delegate = nil
        manager = nil
        peripheral = nil
        uplink = nil
        downlink = nil
        acknowledgedWriteBytes = 0
        let completions = pending[head...].compactMap { $0?.completion }
        pending.removeAll()
        head = 0
        queuedBytes = 0
        pendingPreviewIndex = nil
        coalescedPreviews = 0
        for completion in completions { completion(false) }
    }

    private func fail(_ reason: String) {
        guard !lost else { return }
        lost = true
        IMicLog.write("iphone.ble", "lost reason=\(reason) queued=\(queuedBytes)")
        reset()
        onLost?()
    }

    private func rejectCandidate(_ reason: String) {
        guard let peripheral else { return }
        IMicLog.write("iphone.ble", "candidate rejected reason=\(reason)")
        rejected.insert(peripheral.identifier)
        peripheral.delegate = nil
        manager?.cancelPeripheralConnection(peripheral)
        self.peripheral = nil
        uplink = nil
        downlink = nil
        manager?.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        IMicLog.write("iphone.ble", "state=\(central.state.rawValue)")
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.service], options: nil)
        } else if central.state != .unknown && central.state != .resetting {
            fail("Bluetooth unavailable state=\(central.state.rawValue)")
        } else if connected {
            fail("Bluetooth reset")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, self.peripheral == nil, !rejected.contains(peripheral.identifier) else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        IMicLog.write("iphone.ble", "connecting candidate")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, peripheral === self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === manager, peripheral === self.peripheral else { return }
        rejectCandidate("connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === manager, peripheral === self.peripheral else { return }
        if connected { fail(error?.localizedDescription ?? "Bluetooth disconnected") }
        else { rejectCandidate("disconnected before identity") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            rejectCandidate("service unavailable"); return
        }
        peripheral.discoverCharacteristics([Self.uplink, Self.downlink, Self.identity], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == Self.service else { return }
        guard error == nil else { rejectCandidate("characteristics unavailable"); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.uplink { uplink = characteristic }
            if characteristic.uuid == Self.downlink { downlink = characteristic }
        }
        guard uplink != nil, downlink != nil,
              let identity = service.characteristics?.first(where: { $0.uuid == Self.identity }) else {
            rejectCandidate("identity or transport characteristic missing"); return
        }
        peripheral.readValue(for: identity)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === downlink else { return }
        guard error == nil, characteristic.isNotifying else { fail("downlink subscription failed"); return }
        connected = true
        timeout?.cancel()
        timeout = nil
        IMicLog.write("iphone.ble", "connected uplinkMTU=\(peripheral.maximumWriteValueLength(for: .withoutResponse)) controlMTU=\(peripheral.maximumWriteValueLength(for: .withResponse))")
        onConnected?()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if characteristic.uuid == Self.identity {
            if let error {
                let error = error as NSError
                rejectCandidate("identity read failed domain=\(error.domain) code=\(error.code)")
                return
            }
            guard let value = characteristic.value,
                  let text = String(data: value, encoding: .utf8),
                  let macID = UUID(uuidString: text) else {
                rejectCandidate("invalid Mac identity bytes=\(characteristic.value?.count ?? 0)")
                return
            }
            guard targetMacID == nil || targetMacID.flatMap(UUID.init(uuidString:)) == macID else {
                rejectCandidate("Mac identity mismatch")
                return
            }
            guard let downlink else { rejectCandidate("downlink missing"); return }
            peripheral.setNotifyValue(true, for: downlink)
            return
        }
        guard connected, characteristic === downlink else { return }
        guard error == nil else { fail("downlink read failed"); return }
        if let value = characteristic.value, !value.isEmpty { onData?(value) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === uplink,
              connected, acknowledgedWriteBytes > 0 else { return }
        guard error == nil else { fail("uplink ATT write failed"); return }
        let count = acknowledgedWriteBytes
        acknowledgedWriteBytes = 0
        consume(count)
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        pump()
    }
}

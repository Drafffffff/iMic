import CoreBluetooth
import Foundation
import Network

/// BLE 字节隧道；配对、AES-GCM 与音频校验仍复用本机 LinkServer。
/// CoreBluetooth delegate、Network 回调和所有缓冲状态都只在 queue 上访问。
final class BLEBridge: NSObject, CBPeripheralManagerDelegate {
    static let service = CBUUID(string: IMicLink.bleServiceUUID)
    static let uplink = CBUUID(string: IMicLink.bleUplinkUUID)
    static let downlink = CBUUID(string: IMicLink.bleDownlinkUUID)
    static let identity = CBUUID(string: IMicLink.bleIdentityUUID)

    private struct Incoming {
        let data: Data
        // 一个 ATT 批次只回复第一个请求，且必须等该批次最后的 loopback 写入完成。
        let acknowledgement: CBATTRequest?
    }

    private static let maximumQueuedBytes = 64 * 1024 * 1024
    private let queue = DispatchQueue(label: "imic.ble.bridge")
    private let port: UInt16
    private let macID: String
    private var manager: CBPeripheralManager?
    private var local: NWConnection?
    private var central: CBCentral?
    private var downlinkCharacteristic: CBMutableCharacteristic?
    private var incoming: [Incoming?] = []
    private var incomingHead = 0
    private var incomingBytes = 0
    private var outgoing: [Data?] = []
    private var outgoingHead = 0
    private var outgoingOffset = 0
    private var outgoingBytes = 0
    private var notificationBlocked = false
    private var localReady = false
    private var localWriting = false
    private var localReceiving = false
    private var localEndReason: String?
    private var failed = false
    private var generation: UInt64 = 0
    private var uploadedBytes = 0
    private var downloadedBytes = 0
    private var reportedUpload = 0
    private var reportedDownload = 0
    private var reportTime = ProcessInfo.processInfo.systemUptime

    init(port: UInt16, macID: String) {
        self.port = port
        self.macID = macID
        super.init()
    }

    func start() {
        queue.async {
            guard self.manager == nil else { return }
            IMicLog.write("mac.ble", "authorization=\(CBManager.authorization.rawValue)")
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.closeLocal()
            self.central = nil
            self.downlinkCharacteristic = nil
            self.manager?.stopAdvertising()
            self.manager?.removeAllServices()
            self.manager?.delegate = nil
            self.manager = nil
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        IMicLog.write("mac.ble", "state=\(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else {
            closeLocal()
            central = nil
            downlinkCharacteristic = nil
            return
        }
        let uplink = CBMutableCharacteristic(
            type: Self.uplink, properties: [.write, .writeWithoutResponse],
            value: nil, permissions: [.writeable]
        )
        let downlink = CBMutableCharacteristic(
            type: Self.downlink, properties: [.notify], value: nil, permissions: []
        )
        // 静态只读值由 CoreBluetooth 处理读取；这是 PairingStore 的 Mac ID，不是外设 UUID。
        let identity = CBMutableCharacteristic(
            type: Self.identity, properties: [.read], value: Data(macID.utf8), permissions: [.readable]
        )
        downlinkCharacteristic = downlink
        let service = CBMutableService(type: Self.service, primary: true)
        service.characteristics = [uplink, downlink, identity]
        peripheral.removeAllServices()
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        if let error {
            IMicLog.write("mac.ble", "add service failed=\(error.localizedDescription)")
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.service],
            CBAdvertisementDataLocalNameKey: "iMic · BLE"
        ])
        IMicLog.write("mac.ble", "advertising")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager, let first = requests.first else { return }
        guard localEndReason == nil else {
            peripheral.respond(to: first, withResult: .unlikelyError)
            return
        }
        guard !failed, let central, requests.allSatisfy({ $0.central.identifier == central.identifier }) else {
            peripheral.respond(to: first, withResult: .insufficientAuthorization)
            return
        }
        guard requests.allSatisfy({ $0.characteristic.uuid == Self.uplink && $0.offset == 0 && $0.value != nil }) else {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
            failBridge("invalid ATT write")
            return
        }
        var size = 0
        for request in requests {
            let count = request.value?.count ?? 0
            guard count <= Self.maximumQueuedBytes - incomingBytes - size else {
                peripheral.respond(to: first, withResult: .insufficientResources)
                failBridge("uplink queue capacity exceeded")
                return
            }
            size += count
        }
        guard size > 0 else {
            peripheral.respond(to: first, withResult: .success)
            return
        }
        // 不在入队时假装成功；有响应写直到最后一片到 loopback 后才回复。
        for (index, request) in requests.enumerated() {
            incoming.append(Incoming(data: request.value ?? Data(), acknowledgement: index == requests.count - 1 ? first : nil))
        }
        incomingBytes += size
        openLocal()
        flushIncoming()
        reportTransfer()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == Self.downlink else { return }
        guard self.central == nil || self.central?.identifier == central.identifier else {
            IMicLog.write("mac.ble", "additional subscriber rejected")
            return
        }
        guard self.central == nil else { return }
        self.central = central
        failed = false
        notificationBlocked = false
        uploadedBytes = 0
        downloadedBytes = 0
        reportedUpload = 0
        reportedDownload = 0
        reportTime = ProcessInfo.processInfo.systemUptime
        IMicLog.write("mac.ble", "subscribed downlinkMTU=\(central.maximumUpdateValueLength)")
        openLocal()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == Self.downlink,
              self.central?.identifier == central.identifier else { return }
        IMicLog.write("mac.ble", "unsubscribed")
        closeLocal()
        self.central = nil
        failed = false
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager, !failed else { return }
        notificationBlocked = false
        flushOutgoing()
    }

    private func openLocal() {
        guard !failed, central != nil, local == nil else { return }
        generation &+= 1
        let generation = generation
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? 47844,
            using: .tcp
        )
        local = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.generation == generation,
                  self.local === connection else { return }
            switch state {
            case .ready:
                self.localReady = true
                IMicLog.write("mac.ble", "loopback ready")
                self.flushIncoming()
                self.receiveLocal()
            case .failed(let error):
                self.failBridge("loopback failed=\(error.localizedDescription)")
            case .cancelled:
                self.failBridge("loopback cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func flushIncoming() {
        guard !failed, localReady, !localWriting, let local,
              incomingHead < incoming.count, let item = incoming[incomingHead] else { return }
        let generation = generation
        localWriting = true
        local.send(content: item.data, completion: .contentProcessed { [weak self, weak local] error in
            guard let self, let local, self.generation == generation, self.local === local else { return }
            self.localWriting = false
            if let error {
                self.failBridge("loopback write failed=\(error.localizedDescription)")
                return
            }
            if let request = item.acknowledgement { self.manager?.respond(to: request, withResult: .success) }
            self.incomingBytes -= item.data.count
            self.uploadedBytes += item.data.count
            self.incoming[self.incomingHead] = nil
            self.incomingHead += 1
            self.compactIncoming()
            self.reportTransfer()
            self.flushIncoming()
        })
    }

    private func receiveLocal() {
        guard !failed, localEndReason == nil, localReady, !localReceiving, let local else { return }
        let generation = generation
        localReceiving = true
        local.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak local] data, _, complete, error in
            guard let self, let local, self.generation == generation, self.local === local else { return }
            self.localReceiving = false
            if let data, !data.isEmpty {
                guard data.count <= Self.maximumQueuedBytes - self.outgoingBytes else {
                    self.failBridge("downlink queue capacity exceeded")
                    return
                }
                self.outgoing.append(data)
                self.outgoingBytes += data.count
            }
            if complete || error != nil {
                // 先排空已收到的末尾控制帧；不能把完整错误/结果帧在 MTU 背压时清掉。
                self.localEndReason = error.map { "loopback read failed=\($0.localizedDescription)" } ?? "loopback closed"
                self.flushOutgoing()
                return
            }
            self.flushOutgoing()
            self.receiveLocal()
        }
    }

    private func flushOutgoing() {
        guard !failed, !notificationBlocked, let manager, let central,
              let downlink = downlinkCharacteristic else { return }
        let mtu = central.maximumUpdateValueLength
        guard mtu > 0 else { failBridge("invalid downlink MTU"); return }
        while outgoingHead < outgoing.count, let chunk = outgoing[outgoingHead] {
            let size = min(chunk.count - outgoingOffset, mtu)
            let start = chunk.index(chunk.startIndex, offsetBy: outgoingOffset)
            let end = chunk.index(start, offsetBy: size)
            guard manager.updateValue(chunk.subdata(in: start..<end), for: downlink, onSubscribedCentrals: [central]) else {
                notificationBlocked = true
                return
            }
            outgoingBytes -= size
            downloadedBytes += size
            outgoingOffset += size
            if outgoingOffset == chunk.count {
                outgoing[outgoingHead] = nil
                outgoingHead += 1
                outgoingOffset = 0
                compactOutgoing()
            }
        }
        reportTransfer()
        if let reason = localEndReason { failBridge(reason) }
    }

    private func compactIncoming() {
        if incomingHead == incoming.count {
            incoming.removeAll(keepingCapacity: true)
            incomingHead = 0
        } else if incomingHead >= 1024, incomingHead >= incoming.count / 2 {
            incoming.removeFirst(incomingHead)
            incomingHead = 0
        }
    }

    private func compactOutgoing() {
        if outgoingHead == outgoing.count {
            outgoing.removeAll(keepingCapacity: true)
            outgoingHead = 0
        } else if outgoingHead >= 1024, outgoingHead >= outgoing.count / 2 {
            outgoing.removeFirst(outgoingHead)
            outgoingHead = 0
        }
    }

    private func reportTransfer() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - reportTime
        guard elapsed >= 2 else { return }
        let uploadRate = Int(Double(uploadedBytes - reportedUpload) / elapsed)
        let downloadRate = Int(Double(downloadedBytes - reportedDownload) / elapsed)
        IMicLog.write("mac.ble", "uplink bytes=\(uploadedBytes) queued=\(incomingBytes) bytesPerSecond=\(uploadRate) downlinkBytes=\(downloadedBytes) downlinkQueued=\(outgoingBytes) downlinkBytesPerSecond=\(downloadRate)")
        reportedUpload = uploadedBytes
        reportedDownload = downloadedBytes
        reportTime = now
    }

    private func failBridge(_ reason: String) {
        guard !failed else { return }
        failed = true
        IMicLog.write("mac.ble", "failed reason=\(reason) uplinkQueued=\(incomingBytes) downlinkQueued=\(outgoingBytes)")
        closeLocal()
        // CoreBluetooth 没有外设端主动断连 API；保持失败状态，后续有响应写明确拒绝，
        // 直到中心取消订阅/重连才允许新 loopback，不能静默丢帧后继续成功。
    }

    private func closeLocal() {
        generation &+= 1
        local?.stateUpdateHandler = nil
        local?.cancel()
        local = nil
        localReady = false
        localWriting = false
        localReceiving = false
        notificationBlocked = false
        localEndReason = nil
        for item in incoming[incomingHead...] {
            if let request = item?.acknowledgement { manager?.respond(to: request, withResult: .unlikelyError) }
        }
        incoming.removeAll()
        incomingHead = 0
        incomingBytes = 0
        outgoing.removeAll()
        outgoingHead = 0
        outgoingOffset = 0
        outgoingBytes = 0
    }
}

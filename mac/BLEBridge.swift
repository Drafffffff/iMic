import CoreBluetooth
import Foundation
import Network

/// 纯 BLE GATT 兜底：Mac 作为外设，iPhone 作为中心。
/// 这里只做字节隧道，把 iPhone 发来的 iMic Link 字节流转发到本机 LinkServer，
/// 因此握手、AES-GCM、音频校验和补发逻辑完全复用，不另开一套协议。
final class BLEBridge: NSObject, CBPeripheralManagerDelegate {
    static let service = CBUUID(string: "7E570000-7F4A-4C7E-9A2B-1C0D5E6F7A80")
    static let uplink = CBUUID(string: "7E570001-7F4A-4C7E-9A2B-1C0D5E6F7A80")
    static let downlink = CBUUID(string: "7E570002-7F4A-4C7E-9A2B-1C0D5E6F7A80")

    private let queue = DispatchQueue(label: "imic.ble.bridge")
    private let port: UInt16
    private var manager: CBPeripheralManager?
    private var local: NWConnection?
    private var central: CBCentral?
    private var downlinkCharacteristic: CBMutableCharacteristic?
    private var pending: [Data] = []
    private var outgoing: [Data] = []
    private var updating = false
    private var localReady = false

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        DispatchQueue.main.async {
            guard self.manager == nil else { return }
            IMicLog.write("mac.ble", "authorization=\(CBManager.authorization.rawValue)")
            IMicLog.write("mac.ble", "creating peripheral manager")
            self.manager = CBPeripheralManager(delegate: self, queue: .main)
            IMicLog.write("mac.ble", "peripheral manager created state=\(self.manager?.state.rawValue ?? -1)")
        }
    }

    func stop() {
        queue.async {
            self.manager?.stopAdvertising()
            self.manager?.removeAllServices()
            self.manager = nil
            self.closeLocal()
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        IMicLog.write("mac.ble", "state=\(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else { return }
        let uplink = CBMutableCharacteristic(
            type: Self.uplink,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let downlink = CBMutableCharacteristic(
            type: Self.downlink,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        downlinkCharacteristic = downlink
        let service = CBMutableService(type: Self.service, primary: true)
        service.characteristics = [uplink, downlink]
        peripheral.removeAllServices()
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.service],
            CBAdvertisementDataLocalNameKey: "iMic · BLE"
        ])
        IMicLog.write("mac.ble", "advertising")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            IMicLog.write("mac.ble", "add service failed=\(error.localizedDescription)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            central = request.central
            if let value = request.value, !value.isEmpty {
                if localReady, let local {
                    local.send(content: value, completion: .contentProcessed { error in
                        if let error { IMicLog.write("mac.ble", "local write error=\(error.localizedDescription)") }
                    })
                } else if pending.count < 128 {
                    pending.append(value)
                }
            }
            peripheral.respond(to: request, withResult: .success)
        }
        if !localReady {
            openLocal()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        self.central = central
        IMicLog.write("mac.ble", "subscribed mtu=\(central.maximumUpdateValueLength)")
        openLocal()
        flushOutgoing()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        IMicLog.write("mac.ble", "unsubscribed")
        self.central = nil
        closeLocal()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        updating = false
        flushOutgoing()
    }

    private func openLocal() {
        guard local == nil else { return }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? 47844,
            using: .tcp
        )
        local = connection
        localReady = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.localReady = true
                IMicLog.write("mac.ble", "local ready port=\(self.port)")
                self.flushPending()
                self.receiveLocal()
            case .failed(let error):
                IMicLog.write("mac.ble", "local failed=\(error.localizedDescription)")
                self.closeLocal()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func flushPending() {
        guard localReady, let local else { return }
        let items = pending
        pending.removeAll(keepingCapacity: true)
        for item in items {
            local.send(content: item, completion: .contentProcessed { error in
                if let error { IMicLog.write("mac.ble", "local write error=\(error.localizedDescription)") }
            })
        }
    }

    private func receiveLocal() {
        guard let local else { return }
        local.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.enqueueOutgoing(data)
            }
            if complete || error != nil {
                self.closeLocal()
                return
            }
            self.queue.async { self.receiveLocal() }
        }
    }

    private func enqueueOutgoing(_ data: Data) {
        outgoing.append(data)
        flushOutgoing()
    }

    private func flushOutgoing() {
        guard !updating, let manager, let central, let downlink = downlinkCharacteristic else { return }
        while !outgoing.isEmpty {
            let chunk = outgoing[0]
            let size = min(chunk.count, 180)
            let part = chunk.prefix(size)
            let ok = manager.updateValue(Data(part), for: downlink, onSubscribedCentrals: [central])
            if !ok {
                updating = true
                return
            }
            if size == chunk.count {
                outgoing.removeFirst()
            } else {
                outgoing[0] = Data(chunk.dropFirst(size))
            }
        }
    }

    private func closeLocal() {
        local?.stateUpdateHandler = nil
        local?.cancel()
        local = nil
        localReady = false
        pending.removeAll()
        outgoing.removeAll()
    }
}

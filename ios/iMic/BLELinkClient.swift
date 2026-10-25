import CoreBluetooth
import Foundation

/// 纯 BLE GATT 中心端。它只负责把 iMic Link 字节流搬过 BLE；
/// 握手、加密、音频序号与补发仍由 LinkClient 处理。
final class BLELinkClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "7E570000-7F4A-4C7E-9A2B-1C0D5E6F7A80")
    static let uplink = CBUUID(string: "7E570001-7F4A-4C7E-9A2B-1C0D5E6F7A80")
    static let downlink = CBUUID(string: "7E570002-7F4A-4C7E-9A2B-1C0D5E6F7A80")

    private let queue = DispatchQueue(label: "imic.ble.client")
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var uplink: CBCharacteristic?
    private var downlink: CBCharacteristic?
    private var pending: [(Data, CBCharacteristicWriteType)] = []
    private var writing = false
    private var connected = false
    private var lost = false
    private var timeout: DispatchWorkItem?

    var onConnected: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onLost: (() -> Void)?

    func start() {
        queue.async {
            guard self.manager == nil else { return }
            self.lost = false
            self.manager = CBCentralManager(delegate: self, queue: self.queue)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, !self.connected else { return }
                self.fail("蓝牙连接超时")
            }
            self.timeout = work
            self.queue.asyncAfter(deadline: .now() + 12, execute: work)
        }
    }

    func stop() {
        queue.async {
            self.timeout?.cancel()
            self.timeout = nil
            if let peripheral = self.peripheral {
                self.manager?.cancelPeripheralConnection(peripheral)
            }
            self.manager?.stopScan()
            self.manager = nil
            self.peripheral = nil
            self.uplink = nil
            self.downlink = nil
            self.pending.removeAll()
            self.writing = false
            self.connected = false
        }
    }

    func send(_ data: Data) {
        queue.async {
            guard self.connected, let peripheral = self.peripheral, let uplink = self.uplink else { return }
            // LinkWire 第 5 个字节是帧类型；音频用无响应写入提高吞吐，其余控制帧要确认。
            let isAudio = data.count > 4 && data[4] == LinkFrameKind.sealedAudio.rawValue
            let type: CBCharacteristicWriteType = isAudio ? .withoutResponse : .withResponse
            let limit = max(20, peripheral.maximumWriteValueLength(for: type))
            var offset = 0
            while offset < data.count {
                let end = min(offset + limit, data.count)
                self.pending.append((data.subdata(in: offset..<end), type))
                offset = end
            }
            self.pump()
        }
    }

    private func pump() {
        guard !writing, !pending.isEmpty, let peripheral = peripheral, let uplink = uplink else { return }
        let (data, type) = pending.removeFirst()
        if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            pending.insert((data, type), at: 0)
            return
        }
        writing = type == .withResponse
        peripheral.writeValue(data, for: uplink, type: type)
    }

    private func fail(_ reason: String) {
        guard !lost else { return }
        lost = true
        IMicLog.write("iphone.ble", "lost reason=\(reason)")
        timeout?.cancel()
        timeout = nil
        manager?.stopScan()
        if let peripheral = peripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        uplink = nil
        downlink = nil
        pending.removeAll()
        writing = false
        connected = false
        onLost?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        IMicLog.write("iphone.ble", "state=\(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        IMicLog.write("iphone.ble", "connecting name=\(peripheral.name ?? "-")")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        fail(error?.localizedDescription ?? "无法连接蓝牙")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        fail(error?.localizedDescription ?? "蓝牙已断开")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { fail("读取蓝牙服务失败"); return }
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.uplink, Self.downlink], for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else { fail("读取蓝牙通道失败"); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.uplink { uplink = characteristic }
            if characteristic.uuid == Self.downlink { downlink = characteristic }
        }
        guard let downlink else { fail("缺少蓝牙下行通道"); return }
        peripheral.setNotifyValue(true, for: downlink)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.isNotifying else { fail("无法订阅蓝牙下行"); return }
        connected = true
        timeout?.cancel()
        timeout = nil
        IMicLog.write("iphone.ble", "connected mtu=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")
        onConnected?()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        onData?(value)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        writing = false
        if let error {
            IMicLog.write("iphone.ble", "write error=\(error.localizedDescription)")
            fail("蓝牙写入失败")
            return
        }
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }
}

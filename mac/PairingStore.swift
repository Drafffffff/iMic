import Foundation

struct PairedDevice: Codable, Equatable {
    let id: String
    var name: String
    var token: Data
    var pairedAt: Date
}

/// 配对状态只保存在本机。令牌是 32 字节随机秘密，配对码只用于首次换令牌。
final class PairingStore {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iMic", isDirectory: true)
    }

    private struct Stored: Codable {
        var version: Int
        var macID: String
        var devices: [String: PairedDevice]
    }

    private let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private var stored: Stored
    private var activeCode: String
    private var codeExpiresAt: Date
    private var lastLoadedName: String
    private var throttle = PairingThrottle()

    /// 任何 UI 刷新都通过此回调，服务端只负责状态。
    var onChange: (() -> Void)?

    init(directory: URL = PairingStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("paired.json")
        self.lastLoadedName = Self.machineName()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data),
           decoded.version == 1,
           UUID(uuidString: decoded.macID) != nil {
            stored = decoded
        } else {
            stored = Stored(version: 1, macID: UUID().uuidString, devices: [:])
        }
        activeCode = PairingCode.make()
        codeExpiresAt = Date().addingTimeInterval(IMicLink.pairingCodeLifetime)
        try? save()
    }

    var macID: String {
        lock.lock(); defer { lock.unlock() }
        return stored.macID
    }

    var macName: String {
        lock.lock(); defer { lock.unlock() }
        return lastLoadedName
    }

    /// 仅用于无界面联调：把配对码固定一段时间，避免测试与 UI 轮换竞争。
    func overrideCode(_ code: String) {
        guard PairingCode.isValid(code) else { return }
        lock.lock()
        throttle.reset()
        activeCode = code
        codeExpiresAt = Date().addingTimeInterval(3600)
        lock.unlock()
    }

    var devices: [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return stored.devices.values.sorted { $0.pairedAt > $1.pairedAt }
    }

    var isPaired: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stored.devices.isEmpty
    }

    /// 当前展示的配对码；过期后自动轮换。
    func currentCode() -> String {
        lock.lock(); defer { lock.unlock() }
        refreshCodeIfNeededLocked()
        return activeCode
    }

    /// 用户在 Mac 上手动换码：同时解除配对冷却。
    func rotateCode() {
        lock.lock()
        throttle.reset()
        activeCode = PairingCode.make()
        codeExpiresAt = Date().addingTimeInterval(IMicLink.pairingCodeLifetime)
        lock.unlock()
        notify()
    }

    /// 配对冷却剩余秒数；未锁定返回 nil。冷却期间不尝试解密任何配对请求。
    func pairingLockRemaining() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return throttle.remainingLock(at: Date())
    }

    /// 记录一次配对码错误。达到上限时立即轮换配对码并进入冷却，返回冷却剩余秒数。
    func recordPairFailure() -> TimeInterval? {
        lock.lock()
        let now = Date()
        let locked = throttle.recordFailure(at: now)
        if locked {
            activeCode = PairingCode.make()
            codeExpiresAt = now.addingTimeInterval(IMicLink.pairingCodeLifetime)
        }
        let remaining = locked ? throttle.remainingLock(at: now) : nil
        lock.unlock()
        if locked { notify() }
        return remaining
    }

    func token(for deviceID: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored.devices[deviceID]?.token
    }

    func device(for deviceID: String) -> PairedDevice? {
        lock.lock(); defer { lock.unlock() }
        return stored.devices[deviceID]
    }

    /// 只有配对码正确时服务端才会调用；成功后立即作废旧码。
    func trust(deviceID: String, name: String, token: Data) throws {
        guard token.count == 32, UUID(uuidString: deviceID) != nil else {
            throw LinkError.invalidToken
        }
        lock.lock()
        stored.devices[deviceID] = PairedDevice(
            id: deviceID,
            name: String(name.prefix(64)),
            token: token,
            pairedAt: Date()
        )
        throttle.reset()
        activeCode = PairingCode.make()
        codeExpiresAt = Date().addingTimeInterval(IMicLink.pairingCodeLifetime)
        lock.unlock()
        try save()
        notify()
    }

    func forgetAll() {
        lock.lock()
        stored.devices.removeAll()
        throttle.reset()
        activeCode = PairingCode.make()
        codeExpiresAt = Date().addingTimeInterval(IMicLink.pairingCodeLifetime)
        lock.unlock()
        try? save()
        notify()
    }

    func forget(deviceID: String) {
        lock.lock()
        stored.devices.removeValue(forKey: deviceID)
        lock.unlock()
        try? save()
        notify()
    }

    private func refreshCodeIfNeededLocked() {
        guard Date() >= codeExpiresAt else { return }
        throttle.codeRotated()
        activeCode = PairingCode.make()
        codeExpiresAt = Date().addingTimeInterval(IMicLink.pairingCodeLifetime)
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func machineName() -> String {
        var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(6) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : String(trimmed.prefix(48))
    }
}

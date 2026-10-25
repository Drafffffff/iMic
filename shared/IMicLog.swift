import Foundation
#if canImport(os)
import os
#endif

/// 轻量会话日志：同时写入统一日志和可回收的文本文件。
/// 只记录状态、序号、字节数等元数据，绝不记录令牌、音频内容或识别正文。
public enum IMicLog {
    private static let queue = DispatchQueue(label: "imic.session.log", qos: .utility)
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.drafffffff.imic", category: "session")
    #endif

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/iMic/iMic.log", isDirectory: false)
    }

    public static func write(_ tag: String, _ message: String) {
        let safeTag = tag.prefix(32)
        let safeMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(2_000)
        #if canImport(os)
        logger.info("\(String(safeTag), privacy: .public) \(String(safeMessage), privacy: .public)")
        #endif

        queue.async {
            let url = fileURL
            let fm = FileManager.default
            do {
                try fm.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let attributes = try? fm.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? NSNumber,
                   size.intValue > 2_000_000 {
                    let old = url.deletingPathExtension().appendingPathExtension("1.log")
                    try? fm.removeItem(at: old)
                    try? fm.moveItem(at: url, to: old)
                }
                if !fm.fileExists(atPath: url.path) {
                    fm.createFile(atPath: url.path, contents: nil)
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let line = "\(formatter.string(from: Date())) [\(safeTag)] \(safeMessage)\n"
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                #if canImport(os)
                logger.error("log write failed: \(String(describing: error), privacy: .public)")
                #endif
            }
        }
    }
}

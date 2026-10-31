import Foundation
import CryptoKit

// Verify against the public key actually embedded by build-mac.sh, not just the
// signing tool's selected Keychain account (which could belong to another app).
do {
    guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
    let key = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let publicBytes = Data(base64Encoded: key), let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: archive) else { throw CocoaError(.fileReadCorruptFile) }
    print("PASS: 最终 DMG 的 Ed25519 签名与 App 公钥一致。")
} catch {
    fputs("更新签名校验失败：\(error)\n", stderr)
    exit(1)
}

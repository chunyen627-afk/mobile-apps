import CryptoKit
import Foundation

/// The phone's approval of an administrator command: HMAC-SHA256, with a key only this phone and
/// the PC's elevated companion hold, over "<id>\n<sha256 of content>\n<cwd>\n<expires>".
/// The hash is computed here from the content shown on screen, so if anything between the PC
/// and the phone changed the content, the companion refuses the approval.
public enum ElevateSigner {
    /// The 32-byte key from a 64-character hex string (spaces allowed), or nil.
    public static func key(fromHex text: String) -> SymmetricKey? {
        let hex = text.filter { !$0.isWhitespace }.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return SymmetricKey(data: bytes)
    }

    public static func signature(key: SymmetricKey, id: String, content: String, cwd: String, expires: Int) -> String {
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        let message = "\(id)\n\(digest)\n\(cwd)\n\(expires)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    public static func signature(key: SymmetricKey, for request: ElevateRequest) -> String {
        signature(key: key, id: request.id, content: request.content, cwd: request.cwd, expires: request.expires)
    }
}

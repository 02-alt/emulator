import CryptoKit
import Foundation

extension Data {
    /// Lowercase hex of the SHA-256 digest, truncated to `count` characters.
    func sha256Hex(prefix count: Int = 16) -> String {
        let hex = SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(count))
    }
}

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A digest of a document's bytes, used ONLY to answer "did this file's content move?".
///
/// This is a change DETECTOR, not a security primitive: nothing authenticates or authorizes on it, and
/// a collision costs a missed refresh rather than a vulnerability. So the non-CryptoKit path is a plain
/// FNV-1a, which keeps the Linux daemon building without pulling in a crypto dependency for a job that
/// does not need one.
public enum DocumentContentHash {
    public static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 36)
        #endif
    }
}

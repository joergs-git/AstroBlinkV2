import Foundation
import CryptoKit

/// Compute SHA256 file hash from first 64KB of file content.
/// Used for unique file identification in Frame History Database.
/// Standalone utility to avoid GRDB dependency in PrefetchCache.
enum FileHasher {
    /// Compute SHA256 hash of the first 64KB of a file.
    /// Returns lowercase hex string, or nil if file can't be read.
    static func hash(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 65536)
        guard !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

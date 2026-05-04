// v0.8.0
import Foundation

// Manages local caching of image files from network volumes
// Files are copied to ~/Library/Caches/AstroBlinkV2/ on session load
// so that browsing/decoding operates on fast local I/O.
// Thread-safe: uses a lock for concurrent access from parallel copy tasks.
// Marked @unchecked Sendable so it can be captured into background download
// workers (concurrentPerform). All mutable state is guarded by `lock`.
final class SessionCache: @unchecked Sendable {

    // Session-specific cache directory
    private var sessionCacheDir: URL?
    // Maps original network URL → local cached URL (protected by lock)
    private var cache: [URL: URL] = [:]
    private let lock = NSLock()

    private static let cacheRoot: URL = {
        // Caches dir is system-guaranteed on macOS; fallback to tmp keeps the static init nil-safe.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("AstroBlinkV2", isDirectory: true)
    }()

    // Check if a URL is on a network volume (NAS, SMB, AFP, NFS)
    static func isNetworkVolume(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        return !(values?.volumeIsLocal ?? true)
    }

    // Prepare a session cache directory for the given root URL
    func prepareSession(rootURL: URL) {
        let hash = abs(rootURL.path.hashValue)
        let dirName = "\(hash)_\(rootURL.lastPathComponent)"
        let dir = Self.cacheRoot.appendingPathComponent(dirName, isDirectory: true)
        sessionCacheDir = dir

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // Cache a single file and return the local URL.
    // Thread-safe: can be called from multiple concurrent tasks.
    // Returns nil on failure (entry should fallback to original URL).
    func cacheFile(sourceURL: URL) -> URL? {
        // Check cache first (under lock)
        lock.lock()
        if let cached = cache[sourceURL] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let cacheDir = sessionCacheDir else { return nil }

        // Preserve subfolder structure to avoid filename collisions
        let localFile = cacheDir.appendingPathComponent(sourceURL.lastPathComponent)

        // If already on disk from a previous session, reuse
        if FileManager.default.fileExists(atPath: localFile.path) {
            lock.lock()
            cache[sourceURL] = localFile
            lock.unlock()
            return localFile
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: localFile)
            lock.lock()
            cache[sourceURL] = localFile
            lock.unlock()
            return localFile
        } catch {
            return nil
        }
    }

    // Remove the current session's cache directory
    func cleanupCurrentSession() {
        lock.lock()
        cache.removeAll()
        lock.unlock()

        if let dir = sessionCacheDir {
            try? FileManager.default.removeItem(at: dir)
            sessionCacheDir = nil
        }
    }

    // Remove only session-cache directories — preserves named sibling caches
    // like dss_thumbnails/ that are designed to live across launches.
    // Session caches are named "<absHash>_<basename>" (see prepareSession), so
    // we filter on a leading numeric segment followed by an underscore.
    static func cleanupAllCaches() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for entry in contents {
            let name = entry.lastPathComponent
            guard let underscore = name.firstIndex(of: "_") else { continue }
            let prefix = name[name.startIndex..<underscore]
            guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // Clean up old session caches (keep only most recent 3)
    static func cleanupOldCaches() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = contents.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }

        for dir in sorted.dropFirst(3) {
            try? fm.removeItem(at: dir)
        }
    }
}

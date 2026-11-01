// PlateSolveCache.swift
// Disk cache for the in-memory plate solves of "Plate-Solve on Load" (6.11.0).
//
// The on-load solve deliberately writes nothing into the user's files, so without a cache every
// re-opened session would pay the full ASTAP run again (~0.3 s per frame). A solution is nine
// doubles; even the 50 000-frame cap stays far below 10 MB of JSON in the app container.
//
// Thread-safety: `store` is called from the solve's completion on the main actor and
// `solution(for:)` from the load path, but a lock keeps it correct wherever it is called from.

import Foundation

final class PlateSolveCache: @unchecked Sendable {
    static let shared = PlateSolveCache()

    struct Record: Codable {
        let solution: WCSSolution
        let solvedAt: Date
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var loaded = false
    private let fileURL: URL
    /// Upper bound on cached frames; the oldest solves go first.
    private let maxRecords: Int

    /// - Parameter fileURL: where the JSON lives. Defaults to the app's Application Support
    ///   folder (next to FrameHistory.sqlite); tests pass a temporary file.
    init(fileURL: URL? = nil, maxRecords: Int = 50_000) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AstroBlinkV2", isDirectory: true)
            self.fileURL = support.appendingPathComponent("platesolve_cache.json")
        }
        self.maxRecords = max(1, maxRecords)
    }

    /// Cache key: file name plus size. Both are known from the directory scan, long before the
    /// content hash arrives from the prefetch pipeline, and a light-frame name carries the
    /// capture timestamp, so collisions are not a practical concern. A frame whose file changed
    /// size (re-solved and written, re-exported) simply misses and is solved again.
    static func key(for entry: ImageEntry) -> String {
        "\(entry.filename)|\(entry.fileSize ?? 0)"
    }

    func solution(for entry: ImageEntry) -> WCSSolution? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return records[Self.key(for: entry)]?.solution
    }

    /// Remember fresh solves and persist. Replaces an older record for the same key.
    func store(_ frames: [SolvedFrame]) {
        guard !frames.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let now = Date()
        for frame in frames {
            records[Self.key(for: frame.entry)] = Record(solution: frame.solution, solvedAt: now)
        }
        if records.count > maxRecords {
            let surplus = records.count - maxRecords
            let oldest = records.sorted { $0.value.solvedAt < $1.value.solvedAt }.prefix(surplus)
            for (key, _) in oldest { records.removeValue(forKey: key) }
        }
        save()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return records.count
    }

    // MARK: - Disk

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

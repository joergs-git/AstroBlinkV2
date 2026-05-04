// AIsaac Remote Knowledge Service
// Fetches and caches knowledge snippets from Supabase for dynamic AIsaac updates
// without requiring app releases. Falls back to embedded knowledge gracefully.

import Foundation

/// Manages remote knowledge snippets for AIsaac's system prompt.
/// Table: `aisaac_knowledge` in Supabase with columns:
///   id (uuid), topic (text), content (text), priority (int),
///   min_app_version (text), max_app_version (text),
///   is_active (bool), updated_at (timestamptz)
class AIsaacKnowledgeService {
    static let shared = AIsaacKnowledgeService()

    /// Cached snippets keyed by topic
    private var cache: [String: KnowledgeSnippet] = [:]
    private var lastFetch: Date?
    private let cacheFile: URL
    private let refreshInterval: TimeInterval = 3600  // 1 hour

    struct KnowledgeSnippet: Codable {
        let id: String
        let topic: String
        let content: String
        let priority: Int          // Higher priority = shown first in prompt
        let minAppVersion: String? // nil = all versions
        let maxAppVersion: String? // nil = all versions
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id, topic, content, priority
            case minAppVersion = "min_app_version"
            case maxAppVersion = "max_app_version"
            case updatedAt = "updated_at"
        }
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AstroBlinkV2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheFile = dir.appendingPathComponent("aisaac_knowledge_cache.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// Get all active knowledge snippets for the current app version, sorted by priority.
    /// Returns cached data immediately; fetches from Supabase in background if stale.
    func activeSnippets() -> [KnowledgeSnippet] {
        // Trigger background refresh if stale
        if shouldRefresh() {
            Task.detached(priority: .utility) { [weak self] in
                await self?.fetchFromSupabase()
            }
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return cache.values
            .filter { snippet in
                // Version range check
                if let min = snippet.minAppVersion, appVersion.compare(min, options: .numeric) == .orderedAscending {
                    return false
                }
                if let max = snippet.maxAppVersion, appVersion.compare(max, options: .numeric) == .orderedDescending {
                    return false
                }
                return true
            }
            .sorted { $0.priority > $1.priority }
    }

    /// Build a knowledge block string for inclusion in AIsaac's system prompt.
    /// Returns nil if no remote snippets available.
    func buildRemoteKnowledgeBlock() -> String? {
        let snippets = activeSnippets()
        guard !snippets.isEmpty else { return nil }

        var lines = ["REMOTE KNOWLEDGE UPDATES (latest from server — may override embedded knowledge):"]
        for snippet in snippets {
            lines.append("")
            lines.append("[\(snippet.topic.uppercased())]")
            lines.append(snippet.content)
        }
        return lines.joined(separator: "\n")
    }

    /// Force refresh from Supabase (e.g., after user action).
    func forceRefresh() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchFromSupabase()
        }
    }

    // MARK: - Network

    private func shouldRefresh() -> Bool {
        guard let last = lastFetch else { return true }
        return Date().timeIntervalSince(last) > refreshInterval
    }

    private func fetchFromSupabase() async {
        guard let url = SupabaseClient.restURL(
            table: "aisaac_knowledge",
            query: "select=*&is_active=eq.true&order=priority.desc"
        ) else { return }

        var request = SupabaseClient.makeRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            // 15s timeout preserved — quick fail-back to embedded knowledge if server slow.
            let (data, response) = try await SupabaseClient.send(request, timeout: 15, retries: 2)
            guard response.statusCode == 200 else {
                return
            }
            let decoder = JSONDecoder()
            let snippets = try decoder.decode([KnowledgeSnippet].self, from: data)

            // Update cache
            var newCache: [String: KnowledgeSnippet] = [:]
            for snippet in snippets {
                newCache[snippet.topic] = snippet
            }
            // Freeze before crossing into MainActor.run (strict concurrency).
            let frozenCache = newCache

            await MainActor.run {
                self.cache = frozenCache
                self.lastFetch = Date()
            }

            // Persist to disk
            saveToDisk()
        } catch {
            // Silent failure — embedded knowledge is the fallback
        }
    }

    // MARK: - Disk Cache

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFile.path) else { return }
        do {
            let data = try Data(contentsOf: cacheFile)
            let decoded = try JSONDecoder().decode(DiskCache.self, from: data)
            cache = Dictionary(uniqueKeysWithValues: decoded.snippets.map { ($0.topic, $0) })
            lastFetch = decoded.lastFetch
        } catch {
            // Corrupted cache — will be rebuilt on next fetch
        }
    }

    private func saveToDisk() {
        let diskCache = DiskCache(snippets: Array(cache.values), lastFetch: lastFetch ?? Date())
        do {
            let data = try JSONEncoder().encode(diskCache)
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            // Non-critical — cache will be rebuilt on next launch
        }
    }

    private struct DiskCache: Codable {
        let snippets: [KnowledgeSnippet]
        let lastFetch: Date
    }
}

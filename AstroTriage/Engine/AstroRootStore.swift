// Thin facade for CRUD over astro_root that handles the AppKit-y concerns
// (NSOpenPanel for folder picking, security-scoped bookmark resolution).
// The raw DB access lives on FrameHistoryDatabase to keep all SQL co-located.
//
// Bookmark lifecycle:
//   - addRoot(picking:): runs an NSOpenPanel, creates a security-scoped
//     bookmark from the chosen URL, and persists it.
//   - resolve(_:): re-creates a URL from a stored bookmark and starts a
//     security scope. The caller is responsible for stopAccessingSecurityScopedResource()
//     when done. If the bookmark is stale (e.g. DB synced from another Mac),
//     resolution returns nil and the caller falls through to re-pick.
import Foundation
import AppKit

@MainActor
final class AstroRootStore {
    static let shared = AstroRootStore()

    private var db: FrameHistoryDatabase { FrameHistoryDatabase.shared }

    // MARK: - Read

    func allRoots() -> [AstroRoot] {
        (try? db.allAstroRoots()) ?? []
    }

    func root(id: Int64) -> AstroRoot? {
        try? db.astroRoot(id: id)
    }

    func root(matchingSetupTag tag: String) -> AstroRoot? {
        try? db.astroRoot(matchingSetupTag: tag)
    }

    // MARK: - Write

    /// Present an NSOpenPanel and persist the chosen folder as a new root.
    /// Returns nil if the user cancels.
    func addRoot(picking title: String = "Choose an astro files folder",
                 setupTag: String? = nil,
                 nickname: String? = nil) -> AstroRoot? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return addRoot(at: url, setupTag: setupTag, nickname: nickname)
    }

    /// Persist a folder URL as a new root. The URL must currently be accessible
    /// (e.g. came from an NSOpenPanel response or an already-resolved bookmark).
    func addRoot(at url: URL, setupTag: String?, nickname: String?) -> AstroRoot? {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        var record = AstroRoot(
            id: nil,
            path: url.path,
            bookmark: bookmark,
            setupTag: setupTag?.isEmpty == true ? nil : setupTag,
            nickname: nickname?.isEmpty == true ? nil : nickname,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            lastUsedAt: nil
        )
        do {
            try db.insertAstroRoot(&record)
            return record
        } catch {
            // Most likely a UNIQUE constraint violation on path — return the existing row.
            return allRoots().first { $0.path == url.path }
        }
    }

    func update(_ root: AstroRoot) {
        try? db.updateAstroRoot(root)
    }

    func delete(id: Int64) {
        try? db.deleteAstroRoot(id: id)
    }

    // MARK: - Bookmark resolution

    /// Resolve the stored security-scoped bookmark to a usable URL and start
    /// accessing it. Returns nil if no bookmark, the bookmark is stale, or
    /// the underlying folder is no longer reachable.
    ///
    /// **The caller MUST call `url.stopAccessingSecurityScopedResource()`**
    /// once it's done with the URL — otherwise the security scope leaks.
    func resolve(_ root: AstroRoot) -> URL? {
        guard let bookmark = root.bookmark else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else { return nil }
            if isStale {
                if let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
                    var updated = root
                    updated.bookmark = fresh
                    update(updated)
                }
            }
            var touched = root
            touched.lastUsedAt = ISO8601DateFormatter().string(from: Date())
            update(touched)
            return url
        } catch {
            return nil
        }
    }
}

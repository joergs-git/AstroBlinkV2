// ASTAPLocator — finds the user's ASTAP installation and its star database, and holds the
// one-time permission grant the star database needs.
//
// ASTAP is GPL-3 and its star databases carry non-commercial terms, so neither may ship
// with AstroBlink. The user installs both; this type locates them.
//
// SANDBOX (measured 2026-09-14, see the spike notes in tasks/todo.md):
//   - The binary under /Applications is readable AND executable straight from the sandbox —
//     `application.sb` grants `file-read* process-exec (subpath "/Applications")`. No
//     entitlement change, no user grant, works in the App Store build too.
//   - The star database under /usr/local is NOT reachable: no sandbox rule covers
//     /usr/local. The user grants that folder once via NSOpenPanel; the resulting
//     security-scoped bookmark is persisted and — crucially — is inherited by the ASTAP
//     child process we spawn, so the 1.1 GB database does not have to be copied anywhere.
//
// v6.9.0

import Foundation
import AppKit

// MARK: - Readiness

/// What the solver can and cannot do right now. Every failure names its own remedy so the
/// UI never has to guess why plate solving is unavailable.
enum ASTAPReadiness: Equatable {
    /// Everything resolved; both URLs are usable right now.
    case ready(binary: URL, database: URL)
    /// No ASTAP installation found in any known location.
    case binaryMissing
    /// ASTAP is installed but no star database was found. The user has to download one.
    case databaseMissing
    /// A database folder is known but the sandbox cannot read it — needs the one-time grant.
    case databaseNeedsPermission(path: String)

    var isReady: Bool { if case .ready = self { return true }; return false }

    /// Short, actionable explanation for menus, tooltips and error dialogs.
    var explanation: String {
        switch self {
        case .ready:
            return "ASTAP is ready."
        case .binaryMissing:
            return "ASTAP was not found. Install it from hnsky.org — AstroBlink cannot bundle "
                 + "it (ASTAP is GPL-3 licensed)."
        case .databaseMissing:
            return "ASTAP is installed but no star database was found. Download one from "
                 + "hnsky.org (the H18 or V50 database covers most focal lengths)."
        case .databaseNeedsPermission(let path):
            return "AstroBlink needs your permission to read the ASTAP star database at "
                 + "\(path). macOS blocks this folder until you grant access once — "
                 + "run the command again to do that."
        }
    }
}

// MARK: - Locator

final class ASTAPLocator {

    static let shared = ASTAPLocator()

    private let fm = FileManager.default

    /// Security scope opened by `resolvePersistedDatabase()`. Held for the lifetime of the
    /// grant so the solver's child processes inherit it; released in `releaseDatabase()`.
    private var scopedDatabaseURL: URL?

    private init() {}

    // MARK: Binary

    /// Known ASTAP install locations, in the order we prefer them. The GUI bundle doubles as
    /// the CLI (it runs headless when given `-f`); `astap_cli` is the separate headless build.
    private static let binaryCandidates = [
        "/Applications/ASTAP.app/Contents/MacOS/astap",
        "/usr/local/bin/astap_cli",
        "/opt/homebrew/bin/astap_cli",
        "/usr/local/bin/astap",
        "/opt/homebrew/bin/astap"
    ]

    /// The ASTAP executable, or nil if none is installed.
    func findBinary() -> URL? {
        for path in Self.binaryCandidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: Star database

    /// Where ASTAP installers put the star database. `/usr/local/opt/astap` is the standard
    /// location on macOS and is exactly the one the sandbox blocks.
    private static let databaseCandidates = [
        "/usr/local/opt/astap",
        "/usr/local/share/astap",
        "/opt/homebrew/opt/astap",
        "/Applications/ASTAP.app/Contents/MacOS"
    ]

    /// A directory counts as a star database if it holds at least one database file.
    /// Extensions: `.1476` (V50/D80 generation), `.290` (H17/H18/G17 generation).
    func isStarDatabase(_ url: URL) -> Bool {
        guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        return entries.contains { $0.hasSuffix(".1476") || $0.hasSuffix(".290") }
    }

    /// Resolve the persisted grant, if there is one, and keep the security scope open.
    /// Returns a usable URL whose scope the spawned ASTAP process will inherit.
    ///
    /// The caller pairs this with `releaseDatabase()`.
    func resolvePersistedDatabase() -> URL? {
        if let existing = scopedDatabaseURL { return existing }

        guard let bookmark = AppSettings.defaults.data(
            forKey: AppSettings.Key.astapDatabaseBookmark.rawValue
        ) else { return nil }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else { return nil }

        // The folder can have been removed or replaced since the grant.
        guard isStarDatabase(url) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }

        if isStale, let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
            AppSettings.defaults.set(fresh, forKey: AppSettings.Key.astapDatabaseBookmark.rawValue)
        }

        scopedDatabaseURL = url
        return url
    }

    /// Release the security scope. Call when a solve run is finished.
    func releaseDatabase() {
        scopedDatabaseURL?.stopAccessingSecurityScopedResource()
        scopedDatabaseURL = nil
    }

    /// A database folder we can see without any grant (rare — only if ASTAP put it somewhere
    /// the sandbox already allows, e.g. inside /Applications).
    private func findReachableDatabase() -> URL? {
        for path in Self.databaseCandidates {
            let url = URL(fileURLWithPath: path)
            if isStarDatabase(url) { return url }
        }
        return nil
    }

    /// A database folder that exists but that we cannot read — the case that needs a grant.
    /// `isReadableFile` is false under the sandbox, so probe by path existence instead: the
    /// folder is reported by the filesystem even where its contents are denied.
    private func findBlockedDatabasePath() -> String? {
        if let remembered = AppSettings.defaults.string(
            forKey: AppSettings.Key.astapDatabasePath.rawValue
        ) { return remembered }

        for path in Self.databaseCandidates where fm.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: Readiness

    /// Current state, without prompting the user for anything.
    func readiness() -> ASTAPReadiness {
        guard let binary = findBinary() else { return .binaryMissing }

        if let granted = resolvePersistedDatabase() {
            return .ready(binary: binary, database: granted)
        }
        if let reachable = findReachableDatabase() {
            return .ready(binary: binary, database: reachable)
        }
        if let blocked = findBlockedDatabasePath() {
            return .databaseNeedsPermission(path: blocked)
        }
        return .databaseMissing
    }

    // MARK: Permission

    /// Ask for the star-database folder and persist the grant. Main thread only (NSOpenPanel).
    ///
    /// Returns the new readiness. The grant survives relaunches, so this is asked once —
    /// verified end to end: after a restart the restored bookmark alone let the spawned
    /// ASTAP process read the database and solve.
    @MainActor
    func requestDatabasePermission(suggestedPath: String?) -> ASTAPReadiness {
        // Explain BEFORE the file panel. The star database lives under /usr/local, which
        // Finder hides entirely — dropped into an open panel with no explanation, most people
        // cannot navigate there at all and have no idea what they are looking for.
        let path = suggestedPath ?? "/usr/local/opt/astap"
        let intro = NSAlert()
        intro.messageText = "One-time permission needed"
        intro.informativeText = """
            ASTAP keeps its star database in a system folder that macOS blocks apps from \
            reading. Grant AstroBlink access once and it will remember — you will not be \
            asked again.

            The folder is almost certainly:
                \(path)

            In the next dialog it is already selected. If you need to navigate there \
            yourself, press ⌘⇧G and paste the path — the folder is hidden in Finder.

            You are looking for the folder that CONTAINS the database files (they end in \
            .1476 or .290), not an individual file.
            """
        intro.alertStyle = .informational
        intro.addButton(withTitle: "Choose Folder…")
        intro.addButton(withTitle: "Cancel")
        guard intro.runModal() == .alertFirstButtonReturn else { return readiness() }

        let panel = NSOpenPanel()
        panel.title = "Choose the ASTAP star database folder"
        panel.message = "Select the folder holding ASTAP's star database files (.1476 or .290) — "
                      + "usually \(path). Press ⌘⇧G to type a path."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        // Pre-select the folder itself, so "Grant Access" works without any navigation.
        if fm.fileExists(atPath: path) {
            panel.directoryURL = URL(fileURLWithPath: path)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return readiness() }

        guard isStarDatabase(url) else {
            let alert = NSAlert()
            alert.messageText = "No star database in that folder"
            alert.informativeText = "\(url.lastPathComponent) contains no ASTAP database files "
                                  + "(.1476 or .290). Pick the folder those files live in — "
                                  + "usually /usr/local/opt/astap."
            alert.alertStyle = .warning
            alert.runModal()
            return readiness()
        }

        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            AppSettings.defaults.set(bookmark, forKey: AppSettings.Key.astapDatabaseBookmark.rawValue)
            AppSettings.defaults.set(url.path, forKey: AppSettings.Key.astapDatabasePath.rawValue)
        }

        // Drop any scope opened earlier so the next resolve picks up the new grant.
        releaseDatabase()
        return readiness()
    }

    /// Readiness, asking for the grant if that is the only thing missing.
    @MainActor
    func readinessRequestingPermissionIfNeeded() -> ASTAPReadiness {
        let current = readiness()
        guard case .databaseNeedsPermission(let path) = current else { return current }
        return requestDatabasePermission(suggestedPath: path)
    }

    /// Forget the stored grant (Settings → "Choose again").
    func forgetDatabasePermission() {
        releaseDatabase()
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.astapDatabaseBookmark.rawValue)
        AppSettings.defaults.removeObject(forKey: AppSettings.Key.astapDatabasePath.rawValue)
    }
}

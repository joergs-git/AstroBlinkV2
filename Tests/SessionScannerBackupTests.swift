// The session scanner must never load AstroBlink's own safety backups back in.
//
// Reported from live use: after plate solving six XISF frames and saving the result, reopening
// the folder still showed a difference. The frames were loaded TWICE — once current, once from
// `_platesolve_backup_<ts>` — and the untouched copies legitimately disagreed with the new
// WCS, forever. The same flaw applied to `_batch_backup_` and `_filter_backup_` since 6.5.0.
//
// v6.9.0

import XCTest
@testable import AstroTriage

final class SessionScannerBackupTests: XCTestCase {

    // MARK: - Folder classification

    func testAstroBlinkBackupFoldersAreRecognised() {
        for name in ["_platesolve_backup_2026-09-15T12-00-00Z",
                     "_batch_backup_2026-07-01T09-30-00Z",
                     "_filter_backup_2026-06-25T20-15-00Z",
                     "_PLATESOLVE_BACKUP_X"] {
            XCTAssertTrue(SessionScanner.isBackupFolder(name), "not recognised: \(name)")
        }
    }

    func testUserFoldersAreNotMistakenForBackups() {
        // The leading underscore is what marks these as ours. A user's own "Backups" folder,
        // or a target whose name happens to contain the word, must still be scanned.
        for name in ["Backups", "backup", "My Backup Frames", "_predel",
                     "NGC7000", "Lights", "_masters"] {
            XCTAssertFalse(SessionScanner.isBackupFolder(name), "wrongly treated as backup: \(name)")
        }
    }

    // MARK: - Scanning

    func testFramesInsideABackupFolderAreNotLoaded() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent("_platesolve_backup_2026-09-15T12-00-00Z",
                                                 isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Same filename in both places — exactly what a write-back produces.
        let name = "Light_M42_300s_0001.fit"
        let payload = Data("not a real FITS, the scanner only looks at extensions".utf8)
        try payload.write(to: root.appendingPathComponent(name))
        try payload.write(to: backup.appendingPathComponent(name))

        let entries = SessionScanner.scan(rootURL: root)

        XCTAssertEqual(entries.count, 1,
                       "the backup copy was loaded as a session frame — the session doubles and "
                       + "the stale copies disagree with their own headers forever")
        XCTAssertEqual(entries.first?.url.deletingLastPathComponent().path, root.path,
                       "the loaded frame must be the current one, not the backup")
    }

    func testNormalSubfoldersAreStillScanned() throws {
        // The exclusion must not be so broad that it swallows ordinary session structure.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        let night = root.appendingPathComponent("2026-09-14", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: night, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let payload = Data("x".utf8)
        try payload.write(to: root.appendingPathComponent("Light_A_0001.fit"))
        try payload.write(to: night.appendingPathComponent("Light_B_0002.fit"))

        let entries = SessionScanner.scan(rootURL: root)
        XCTAssertEqual(entries.count, 2, "a normal subfolder was skipped")
    }
}

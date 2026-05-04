// iCloud rotating-backup helper for FrameHistoryDatabase.
//
// Owns the iCloud directory resolution, the export-with-rotation flow,
// the freshness-check (compare iCloud meta against local), and the
// import-and-reopen flow. The host database keeps the SQLite queue and
// storage URL; the helper holds the iCloud-side state (resolved URL,
// resolution flags, ready-callback queue) and reaches into the host via
// a weak reference for the few operations it can't do alone:
//   - read the local DB file as a copy source (storageURL is private to
//     the host; the helper receives it once at init time so it doesn't
//     have to widen visibility)
//   - read live database stats for the meta.json sidecar
//   - swap the local DB file + reopen the queue after import
//
// This is the third Patch 2 slice and the cleanest one: no @Published
// state moves, no SwiftUI bindings touched, no public API change. The
// host keeps thin forwarders so all four call sites
// (AstroTriageApp.swift, ArchiveScanner.swift,
// SessionOrchestrator+Scoring.swift) stay untouched.
import Foundation

/// Encapsulates iCloud rotating backup + freshness check + import for the
/// frame-history database. Owned by FrameHistoryDatabase as a long-lived
/// reference (singleton lifetime) and reached through forwarder methods
/// on the database for backwards-compatible call sites.
final class FrameHistoryICloudSync {
    /// Weak back-reference to the database. Used to call databaseStats() for
    /// the meta.json sidecar and reopenAfterImport(at:) when the file swap
    /// completes. Weak because the database owns this helper strongly.
    private weak var database: FrameHistoryDatabase?

    /// Local SQLite file URL — injected at init so the helper never needs to
    /// peek at the host's private storageURL.
    private let localDBURL: URL

    /// SQLite filename (e.g. "FrameHistory.sqlite") — used to derive paths
    /// inside the iCloud container.
    private let localDBFilename: String

    /// Subdirectory inside the iCloud ubiquity container where the rotating
    /// backup lives (e.g. "Documents/FrameHistory").
    private let iCloudSubdir: String

    /// Ubiquity container identifier (e.g. "iCloud.com.joergsflow.AstroBlinkV2").
    private let containerIdentifier: String

    // iCloud directory resolved once on a background thread.
    // FileManager.url(forUbiquityContainerIdentifier:) can block 10-30s,
    // so we resolve it asynchronously and notify via callback when ready.
    private var iCloudDirectory: URL?
    private var resolutionStarted = false
    private var resolved = false
    private var readyCallbacks: [(URL?) -> Void] = []

    init(database: FrameHistoryDatabase?,
         localDBURL: URL,
         localDBFilename: String,
         iCloudSubdir: String,
         containerIdentifier: String) {
        self.database = database
        self.localDBURL = localDBURL
        self.localDBFilename = localDBFilename
        self.iCloudSubdir = iCloudSubdir
        self.containerIdentifier = containerIdentifier
    }

    /// Wire up the back-reference to FrameHistoryDatabase after self has been
    /// fully initialized. The DB owns this helper as a `let` stored property,
    /// so the helper has to be constructed before `self` is available — pass
    /// `nil` at init and call attach immediately afterward.
    func attach(database: FrameHistoryDatabase) {
        self.database = database
    }

    // MARK: - Resolution

    /// Register a callback for when iCloud directory resolution completes.
    /// If already resolved, callback fires immediately. Must be called from main thread.
    func onResolved(_ callback: @escaping (URL?) -> Void) {
        if resolved {
            callback(iCloudDirectory)
            return
        }
        readyCallbacks.append(callback)
    }

    /// Kick off background resolution of the ubiquity container. Idempotent —
    /// safe to call from FrameHistoryDatabase.init() once.
    func startResolution() {
        guard !resolutionStarted else { return }
        resolutionStarted = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let container = FileManager.default.url(forUbiquityContainerIdentifier: self.containerIdentifier)
            let dir: URL?
            if let container {
                let d = container.appendingPathComponent(self.iCloudSubdir, isDirectory: true)
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                dir = d
                print("FrameHistoryDatabase: iCloud resolved → \(d.path)")
            } else {
                dir = nil
                print("FrameHistoryDatabase: iCloud not available (not signed in or Drive not enabled)")
            }
            DispatchQueue.main.async {
                self.iCloudDirectory = dir
                self.resolved = true
                let callbacks = self.readyCallbacks
                self.readyCallbacks.removeAll()
                for cb in callbacks {
                    cb(dir)
                }
            }
        }
    }

    // MARK: - Export

    /// Export database to iCloud container with rotating backup.
    func exportToICloud() {
        // If iCloud hasn't resolved yet (e.g. quick quit), try synchronous resolution as fallback
        if iCloudDirectory == nil && !resolved {
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) {
                let dir = container.appendingPathComponent(iCloudSubdir, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                iCloudDirectory = dir
                print("FrameHistoryDatabase: iCloud resolved synchronously during export")
            }
        }
        guard let iDir = iCloudDirectory else {
            print("FrameHistoryDatabase: skipping iCloud export — iCloud not available")
            return
        }

        let latestURL = iDir.appendingPathComponent(localDBFilename)
        let backupURL = iDir.appendingPathComponent("FrameHistory_backup1.sqlite")
        let metaURL = iDir.appendingPathComponent("FrameHistory_meta.json")

        do {
            // Rotate: current → backup1. Both steps logged on failure so a quietly
            // broken rotation surfaces in Console.app instead of looking like success.
            if FileManager.default.fileExists(atPath: latestURL.path) {
                do {
                    try FileManager.default.removeItem(at: backupURL)
                } catch CocoaError.fileNoSuchFile {
                    // First-time export — no previous backup to remove. Expected.
                } catch {
                    print("FrameHistoryDatabase: iCloud rotation — failed to remove old backup: \(error)")
                }
                do {
                    try FileManager.default.moveItem(at: latestURL, to: backupURL)
                } catch {
                    print("FrameHistoryDatabase: iCloud rotation — failed to move latest to backup1: \(error)")
                }
            }

            // Copy current DB to iCloud
            try FileManager.default.copyItem(at: localDBURL, to: latestURL)

            // Write metadata sidecar
            guard let database = database else { return }
            let stats = try database.databaseStats()
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: localDBURL.path)[.size] as? Int64) ?? 0
            let meta = FrameHistoryMeta(
                lastModified: ISO8601DateFormatter().string(from: Date()),
                frameCount: stats.frameCount,
                sessionCount: stats.sessionCount,
                dbSizeBytes: fileSize
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(meta)
            try data.write(to: metaURL, options: .atomic)
            print("FrameHistoryDatabase: exported to iCloud — \(stats.frameCount) frames (\(String(format: "%.1f MB", Double(fileSize) / (1024*1024))))")
        } catch {
            print("FrameHistoryDatabase: iCloud export failed: \(error)")
        }
    }

    // MARK: - Freshness check

    /// Async check if iCloud has a newer/larger database than local.
    /// Handles evicted (cloud-only) files by triggering download via NSFileCoordinator.
    /// Completion is called on main thread.
    func checkICloudForNewerDBAsync(completion: @escaping ((local: FrameHistoryMeta, iCloud: FrameHistoryMeta)?) -> Void) {
        guard let iDir = iCloudDirectory else {
            print("FrameHistoryDatabase: sync check skipped — iCloud directory not available")
            completion(nil)
            return
        }
        let metaURL = iDir.appendingPathComponent("FrameHistory_meta.json")

        // Trigger download if file is evicted (cloud-only placeholder on new Mac)
        try? FileManager.default.startDownloadingUbiquitousItem(at: metaURL)

        let localDBURL = self.localDBURL
        let database = self.database

        // Read on background thread — NSFileCoordinator waits for download if needed
        DispatchQueue.global(qos: .utility).async {
            var coordinatorError: NSError?
            var result: (local: FrameHistoryMeta, iCloud: FrameHistoryMeta)?

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: metaURL, options: [], error: &coordinatorError) { readURL in
                guard let data = try? Data(contentsOf: readURL),
                      let iCloudMeta = try? JSONDecoder().decode(FrameHistoryMeta.self, from: data) else {
                    print("FrameHistoryDatabase: failed to read iCloud meta.json at \(readURL.path)")
                    return
                }

                guard let database = database, let localStats = try? database.databaseStats() else { return }
                let localSize = (try? FileManager.default.attributesOfItem(atPath: localDBURL.path)[.size] as? Int64) ?? 0
                let localMeta = FrameHistoryMeta(
                    lastModified: ISO8601DateFormatter().string(from: Date()),
                    frameCount: localStats.frameCount,
                    sessionCount: localStats.sessionCount,
                    dbSizeBytes: localSize
                )

                if iCloudMeta.frameCount != localMeta.frameCount {
                    result = (local: localMeta, iCloud: iCloudMeta)
                    print("FrameHistoryDatabase: iCloud differs — local \(localMeta.frameCount), iCloud \(iCloudMeta.frameCount) frames")
                } else {
                    print("FrameHistoryDatabase: iCloud in sync (\(localMeta.frameCount) frames)")
                }
            }

            if let error = coordinatorError {
                print("FrameHistoryDatabase: NSFileCoordinator error reading meta: \(error)")
            }

            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Destroy

    /// Delete every file inside the iCloud subdirectory. Used by the
    /// "Destroy all DB data" advanced menu in the host app — wipes backups
    /// before / after the local database is erased so the next iCloud
    /// freshness check doesn't immediately re-seed from the cloud.
    func destroyAllData() {
        guard let iDir = iCloudDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: iDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Import

    /// Import database from iCloud (replaces local DB). Call after user confirmation.
    /// Handles evicted files via download trigger + NSFileCoordinator.
    /// Completion is called on main thread with imported frame count or error.
    func importFromICloudAsync(completion: @escaping (Result<Int, Error>) -> Void) {
        guard let iDir = iCloudDirectory else {
            completion(.failure(NSError(domain: "FrameHistoryDatabase", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "iCloud not available"])))
            return
        }
        let iCloudDB = iDir.appendingPathComponent(localDBFilename)

        // Trigger download if evicted
        try? FileManager.default.startDownloadingUbiquitousItem(at: iCloudDB)

        let database = self.database

        DispatchQueue.global(qos: .utility).async {
            var coordinatorError: NSError?
            var importResult: Result<Int, Error> = .failure(NSError(domain: "FrameHistoryDatabase", code: 3,
                                                                     userInfo: [NSLocalizedDescriptionKey: "Import did not complete"]))

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: iCloudDB, options: [], error: &coordinatorError) { readURL in
                guard let database = database else {
                    importResult = .failure(NSError(domain: "FrameHistoryDatabase", code: 4,
                                                    userInfo: [NSLocalizedDescriptionKey: "Database deallocated during import"]))
                    return
                }
                do {
                    let count = try database.reopenAfterImport(replacingWith: readURL)
                    print("FrameHistoryDatabase: imported \(count) frames from iCloud, DB reopened")
                    importResult = .success(count)
                } catch {
                    print("FrameHistoryDatabase: import failed: \(error)")
                    importResult = .failure(error)
                }
            }

            if let error = coordinatorError {
                print("FrameHistoryDatabase: NSFileCoordinator error on import: \(error)")
                importResult = .failure(error)
            }

            DispatchQueue.main.async {
                // Notify UI to reload Frame History data
                NotificationCenter.default.post(name: .frameHistoryDidImport, object: nil)
                completion(importResult)
            }
        }
    }
}

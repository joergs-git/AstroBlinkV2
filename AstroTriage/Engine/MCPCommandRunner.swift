// Bridges astroblink:// URL-scheme verbs (scan, mark-garbage) to the actual
// work inside the app, and writes progress/completion back to the
// mcp_command_status table so the MCP server can poll for status.
//
// Architecture:
//   URL handler in AstroTriageApp parses the URL, inserts a status row with
//   state=pending, and posts a notification. This runner observes those
//   notifications, kicks off the work, and writes status updates.
//
// Why not a Combine subscription on ArchiveScanner's @Published state?
//   Combine subscriptions add lifecycle complexity (cancellable storage,
//   re-subscription on cancel/restart). A plain polling Task that checks
//   ArchiveScanner.isScanning is much simpler and gives the same precision.
import Foundation
import AppKit

@MainActor
final class MCPCommandRunner {
    static let shared = MCPCommandRunner()

    private var activeScanCommandId: String?
    private var activeScanBookmarkURL: URL?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .mcpScanRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let info = note.userInfo,
               let rootPath = info["rootPath"] as? String,
               let commandId = info["commandId"] as? String {
                Task { @MainActor in self.startScan(rootPath: rootPath, commandId: commandId) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .mcpMarkGarbageRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let info = note.userInfo,
               let commandId = info["commandId"] as? String {
                let setupHash = info["setupHash"] as? String
                let night = info["night"] as? String
                let dryRun = (info["dryRun"] as? Bool) ?? true
                Task { @MainActor in self.markGarbage(
                    commandId: commandId, setupHash: setupHash, night: night, dryRun: dryRun
                ) }
            }
        }
    }

    // MARK: - Scan

    /// Resolve the astro_root bookmark for the given path, start ArchiveScanner,
    /// and watch its published state until it completes. Updates the status row
    /// continuously so the MCP server's poller sees progress.
    func startScan(rootPath: String, commandId: String) {
        let db = FrameHistoryDatabase.shared

        // 1. Lookup astro_root by path. Required so we can resolve the
        //    security-scoped bookmark — a CLI tool cannot synthesize one for
        //    the sandboxed app.
        guard let root = (try? db.allAstroRoots())?.first(where: { $0.path == rootPath }) else {
            writeFailure(commandId: commandId, error: "Folder not registered. Add it under AstroBlink → Window → Astrofile Locations first.")
            return
        }
        guard let url = AstroRootStore.shared.resolve(root) else {
            writeFailure(commandId: commandId, error: "Could not resolve security-scoped bookmark for \(rootPath). Re-add the folder in Astrofile Locations.")
            return
        }

        // Don't overlap scans — would corrupt progress tracking.
        if ArchiveScanner.shared.isScanning {
            url.stopAccessingSecurityScopedResource()
            writeFailure(commandId: commandId, error: "Another scan is already running. Wait for it to finish or cancel it in the app.")
            return
        }

        activeScanCommandId = commandId
        activeScanBookmarkURL = url

        writeRunning(commandId: commandId)
        ArchiveScanner.shared.startScan(rootURL: url)

        // Poll loop — checks scanner state every 1s. On the @MainActor so we
        // can read @Published values directly without isolation hops.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()  // allow startScan() to flip isScanning before first check
            while ArchiveScanner.shared.isScanning {
                try? db.updateMCPProgress(
                    commandId: commandId,
                    current: ArchiveScanner.shared.totalProcessed,
                    total: ArchiveScanner.shared.totalFound
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // Scanner finished — write final summary.
            let summary: [String: Any] = [
                "framesScanned": ArchiveScanner.shared.totalProcessed,
                "framesFound": ArchiveScanner.shared.totalFound,
                "scanSessionId": ArchiveScanner.shared.scanSessionId,
                "rootPath": rootPath
            ]
            self.writeCompleted(commandId: commandId, summary: summary)
            self.activeScanBookmarkURL?.stopAccessingSecurityScopedResource()
            self.activeScanBookmarkURL = nil
            self.activeScanCommandId = nil
        }
    }

    // MARK: - Mark Garbage

    /// Returns the list of trash-tier frames matching the filter. If dryRun is
    /// false AND the active session has those frames loaded, posts a
    /// notification asking the view model to apply marks; otherwise reports
    /// what *would* have been marked.
    func markGarbage(commandId: String, setupHash: String?, night: String?, dryRun: Bool) {
        writeRunning(commandId: commandId)

        // Build candidate list. We always include this in the summary even
        // for dryRun=false so the caller knows exactly what changed.
        let candidates: [(fileHash: String, filePath: String, filename: String)]
        do {
            candidates = try FrameHistoryDatabase.shared.autoGarbageCandidates(
                setupHash: setupHash, night: night)
        } catch {
            writeFailure(commandId: commandId, error: "Query failed: \(error.localizedDescription)")
            return
        }

        if dryRun {
            let summary: [String: Any] = [
                "dryRun": true,
                "matchCount": candidates.count,
                "files": candidates.prefix(50).map { $0.filename }
            ]
            writeCompleted(commandId: commandId, summary: summary)
            return
        }

        // dryRun=false → ask the active TriageViewModel to mark these frames.
        // For V1 the TriageViewModel observes a notification and reports back
        // via mcp_command_status. If no session is loaded, the model writes
        // failure with a helpful message.
        NotificationCenter.default.post(
            name: .mcpApplyGarbageMarks,
            object: nil,
            userInfo: [
                "commandId": commandId,
                "fileHashes": candidates.map { $0.fileHash }
            ]
        )
    }

    // MARK: - Status writes

    private func writeRunning(commandId: String) {
        let verb = (try? FrameHistoryDatabase.shared.mcpCommandStatus(commandId: commandId))?.verb ?? "unknown"
        let status = MCPCommandStatus(
            commandId: commandId, verb: verb, state: "running",
            startedAt: MCPCommandStatus.nowISO8601(), completedAt: nil,
            progressCurrent: 0, progressTotal: 0, resultSummary: nil, errorMessage: nil
        )
        try? FrameHistoryDatabase.shared.saveMCPCommandStatus(status)
    }

    private func writeCompleted(commandId: String, summary: [String: Any]) {
        let verb = (try? FrameHistoryDatabase.shared.mcpCommandStatus(commandId: commandId))?.verb ?? "unknown"
        let json = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        let status = MCPCommandStatus(
            commandId: commandId, verb: verb, state: "completed",
            startedAt: nil, completedAt: MCPCommandStatus.nowISO8601(),
            progressCurrent: nil, progressTotal: nil,
            resultSummary: json, errorMessage: nil
        )
        try? FrameHistoryDatabase.shared.saveMCPCommandStatus(status)
    }

    private func writeFailure(commandId: String, error: String) {
        let verb = (try? FrameHistoryDatabase.shared.mcpCommandStatus(commandId: commandId))?.verb ?? "unknown"
        let status = MCPCommandStatus(
            commandId: commandId, verb: verb, state: "failed",
            startedAt: nil, completedAt: MCPCommandStatus.nowISO8601(),
            progressCurrent: nil, progressTotal: nil,
            resultSummary: nil, errorMessage: error
        )
        try? FrameHistoryDatabase.shared.saveMCPCommandStatus(status)
    }
}

extension Notification.Name {
    static let mcpScanRequested = Notification.Name("mcpScanRequested")
    static let mcpMarkGarbageRequested = Notification.Name("mcpMarkGarbageRequested")
    static let mcpApplyGarbageMarks = Notification.Name("mcpApplyGarbageMarks")
}

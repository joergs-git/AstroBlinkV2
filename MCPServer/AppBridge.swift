// Bridges read-only DB polling with astroblink:// URL-scheme launches so the
// MCP server can drive operations that require the running app (scan, mark).
//
// Flow used by app-delegating tools:
//   1. AppBridge.run(verb:params:) generates a UUID command_id.
//   2. Fires `open astroblink://<verb>?id=<uuid>&...` via /usr/bin/open. This
//      either passes the URL to the already-running app or launches it cold.
//   3. The app's URL handler inserts mcp_command_status with state=pending,
//      then dispatches the work to MCPCommandRunner.
//   4. AppBridge polls mcp_command_status every 1s until state is completed
//      or failed, or until timeoutSeconds elapse.
//   5. Returns the final row.
//
// No AppKit dep needed — the bridge calls /usr/bin/open as a subprocess. That
// keeps this binary small and avoids dragging in NSWorkspace.
import Foundation

enum AppBridge {

    struct OutcomeJSON: Codable {
        let ok: Bool
        let state: String          // "completed" | "failed" | "timeout" | "noResponse"
        let commandId: String
        let progressCurrent: Int?
        let progressTotal: Int?
        /// Raw JSON string written by the app — already a JSON object. We splice
        /// it into the response below to preserve structure.
        let resultSummary: String?
        let error: String?
    }

    /// Fire an astroblink:// URL and poll the status row until terminal or timeout.
    static func run(
        verb: String,
        params: [String: String],
        db: ReadOnlyFrameHistoryDB,
        timeoutSeconds: Int
    ) async -> OutcomeJSON {
        let commandId = UUID().uuidString
        var allParams = params
        allParams["id"] = commandId

        let url = buildURL(verb: verb, params: allParams)

        // Fire the URL. /usr/bin/open is sync-fire-and-forget — it returns once
        // LaunchServices has dispatched the URL, NOT when the app finishes.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return OutcomeJSON(
                ok: false, state: "failed", commandId: commandId,
                progressCurrent: nil, progressTotal: nil, resultSummary: nil,
                error: "Failed to launch astroblink:// URL: \(error.localizedDescription)"
            )
        }

        // Poll loop.
        let pollIntervalNs: UInt64 = 1_000_000_000
        let start = Date()
        var sawAnyRow = false
        while Date().timeIntervalSince(start) < Double(timeoutSeconds) {
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            let status: (state: String, progressCurrent: Int?, progressTotal: Int?, resultSummary: String?, errorMessage: String?)?
            do {
                status = try db.commandStatus(commandId: commandId)
            } catch {
                return OutcomeJSON(
                    ok: false, state: "failed", commandId: commandId,
                    progressCurrent: nil, progressTotal: nil, resultSummary: nil,
                    error: "DB poll failed: \(error.localizedDescription)"
                )
            }
            guard let s = status else { continue }
            sawAnyRow = true
            if s.state == "completed" {
                return OutcomeJSON(
                    ok: true, state: "completed", commandId: commandId,
                    progressCurrent: s.progressCurrent, progressTotal: s.progressTotal,
                    resultSummary: s.resultSummary, error: nil
                )
            }
            if s.state == "failed" {
                return OutcomeJSON(
                    ok: false, state: "failed", commandId: commandId,
                    progressCurrent: s.progressCurrent, progressTotal: s.progressTotal,
                    resultSummary: s.resultSummary, error: s.errorMessage
                )
            }
            // Otherwise "pending" or "running" — keep polling.
        }

        // Timed out. If we never even saw a row, the URL probably didn't reach
        // the app's handler (app not installed? URL scheme not registered?).
        return OutcomeJSON(
            ok: false,
            state: sawAnyRow ? "timeout" : "noResponse",
            commandId: commandId,
            progressCurrent: nil, progressTotal: nil, resultSummary: nil,
            error: sawAnyRow
                ? "Operation did not complete within \(timeoutSeconds)s. Check the app's UI for an in-progress scan or error."
                : "AstroBlinkV2 did not respond to the URL. Verify the app is installed and the astroblink:// scheme is registered."
        )
    }

    private static func buildURL(verb: String, params: [String: String]) -> String {
        var comps = URLComponents()
        comps.scheme = "astroblink"
        comps.host = verb
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url?.absoluteString ?? "astroblink://\(verb)"
    }
}

// App-delegating MCP tools — these need AstroBlinkV2.app to be running
// (or launchable) because the actual ingestion / scoring / marking logic
// lives in the app. Communication is one-way URL-scheme + DB-polled status.
//
// Tools:
//   scan_for_new_frames(root?, setupTag?, timeoutSeconds=600)
//     — triggers ArchiveScanner on the resolved folder; waits for completion.
//   mark_auto_garbage_for_predelete(setup?, night?, dryRun=true, timeoutSeconds=60)
//     — dryRun=true: returns the list of trash candidates without touching UI.
//       dryRun=false: asks the running session to mark these files; the user
//       still has to press Cmd+Backspace to move them to PRE-DELETE
//       (non-negotiable rule #1: no silent deletion).
import Foundation
import MCP

enum ActionTools {

    static func toolList() -> [Tool] {
        [
            Tool(
                name: "scan_for_new_frames",
                description: "Trigger AstroBlinkV2.app to scan a folder for new astro files, decode + score them, and write results to the Frame History database. The app must be running or installed (LaunchServices will launch it). Resolves the folder by setupTag (e.g. \"RC12\", looked up via list_astro_roots) or by explicit root path. Blocks until the scan completes or timeoutSeconds elapses (default 600s — scans of 100s of frames take 2-5 minutes).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "root": .object([
                            "type": .string("string"),
                            "description": .string("Absolute folder path. Must be registered in astro_root (Window → Astrofile Locations).")
                        ]),
                        "setupTag": .object([
                            "type": .string("string"),
                            "description": .string("Setup tag to resolve to a root path via astro_root.")
                        ]),
                        "timeoutSeconds": .object([
                            "type": .string("integer"),
                            "description": .string("How long to wait for completion before returning a timeout outcome (60-3600, default 600).")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "mark_auto_garbage_for_predelete",
                description: "Identify frames that AstroBlinkV2's algorithm classified as trash (qualityTier=0) and either return them as a recommendation list (dryRun=true, default) or ask the running app to mark them as PRE-DELETE candidates (dryRun=false). Marking only affects frames currently loaded in the active session; the user still has to press Cmd+Backspace in the app to actually move files to the PRE-DELETE folder.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "setupHash": .object([
                            "type": .string("string"),
                            "description": .string("Filter to one setup (from list_setups).")
                        ]),
                        "night": .object([
                            "type": .string("string"),
                            "description": .string("Filter to one observing night (YYYY-MM-DD).")
                        ]),
                        "dryRun": .object([
                            "type": .string("boolean"),
                            "description": .string("If true (default), only return the candidate list. If false, ask the app to mark them.")
                        ]),
                        "timeoutSeconds": .object([
                            "type": .string("integer"),
                            "description": .string("Wait time for app response (10-300, default 60). dryRun=true usually completes in <1s.")
                        ])
                    ])
                ])
            )
        ]
    }

    static func handle(name: String, arguments: [String: Value]?) async -> CallTool.Result? {
        let db: ReadOnlyFrameHistoryDB
        do {
            db = try ReadOnlyFrameHistoryDB()
        } catch {
            return errorResult("Cannot open FrameHistory DB: \(error.localizedDescription)")
        }

        switch name {
        case "scan_for_new_frames":
            return await handleScan(arguments: arguments, db: db)
        case "mark_auto_garbage_for_predelete":
            return await handleMarkGarbage(arguments: arguments, db: db)
        default:
            return nil
        }
    }

    // MARK: - scan_for_new_frames

    private static func handleScan(arguments: [String: Value]?, db: ReadOnlyFrameHistoryDB) async -> CallTool.Result {
        let timeout = clamp(intArg(arguments, "timeoutSeconds") ?? 600, low: 60, high: 3600)

        // Resolve root path: explicit `root` takes precedence; else `setupTag` → astro_root lookup.
        let resolvedRoot: String
        if let r = stringArg(arguments, "root") {
            resolvedRoot = r
        } else if let tag = stringArg(arguments, "setupTag") {
            do {
                let roots = try db.listAstroRoots()
                guard let match = roots.first(where: {
                    ($0.setupTag ?? "").caseInsensitiveCompare(tag) == .orderedSame
                }) else {
                    return errorResult("No astro_root registered with setupTag=\(tag). Configure it under Window → Astrofile Locations.")
                }
                resolvedRoot = match.path
            } catch {
                return errorResult("Lookup failed: \(error.localizedDescription)")
            }
        } else {
            return errorResult("Provide either `root` (absolute path) or `setupTag` (matches a registered astro_root).")
        }

        let outcome = await AppBridge.run(
            verb: "scan",
            params: ["root": resolvedRoot],
            db: db,
            timeoutSeconds: timeout
        )
        return jsonResult(outcome)
    }

    // MARK: - mark_auto_garbage_for_predelete

    private static func handleMarkGarbage(arguments: [String: Value]?, db: ReadOnlyFrameHistoryDB) async -> CallTool.Result {
        let timeout = clamp(intArg(arguments, "timeoutSeconds") ?? 60, low: 10, high: 300)
        let dryRun = boolArg(arguments, "dryRun") ?? true

        var params: [String: String] = ["dry_run": dryRun ? "true" : "false"]
        if let s = stringArg(arguments, "setupHash") { params["setup"] = s }
        if let n = stringArg(arguments, "night") { params["night"] = n }

        let outcome = await AppBridge.run(
            verb: "mark-garbage", params: params, db: db, timeoutSeconds: timeout)
        return jsonResult(outcome)
    }

    // MARK: - Helpers

    private static func jsonResult(_ outcome: AppBridge.OutcomeJSON) -> CallTool.Result {
        // Splice resultSummary back as a JSON object so the LLM sees nested
        // structure, not a stringified JSON blob.
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(outcome), var text = String(data: data, encoding: .utf8)
        else {
            return errorResult("Encoding outcome failed")
        }
        // Inline `resultSummary` if it's a JSON string — replace the quoted JSON with the parsed object form.
        if let summary = outcome.resultSummary,
           let summaryData = summary.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: summaryData),
           let reEncoded = try? JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys, .prettyPrinted]),
           let reText = String(data: reEncoded, encoding: .utf8) {
            let escaped = summary
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            text = text.replacingOccurrences(of: "\"\(escaped)\"", with: reText)
        }
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private static func errorResult(_ msg: String) -> CallTool.Result {
        let payload = "{\"ok\":false,\"error\":\(jsonString(msg))}"
        return .init(content: [.text(text: payload, annotations: nil, _meta: nil)], isError: false)
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private static func stringArg(_ args: [String: Value]?, _ key: String) -> String? {
        guard let v = args?[key] else { return nil }
        if case .string(let s) = v, !s.isEmpty { return s }
        return nil
    }

    private static func intArg(_ args: [String: Value]?, _ key: String) -> Int? {
        guard let v = args?[key] else { return nil }
        switch v {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private static func boolArg(_ args: [String: Value]?, _ key: String) -> Bool? {
        guard let v = args?[key] else { return nil }
        switch v {
        case .bool(let b): return b
        case .string(let s):
            if s.caseInsensitiveCompare("true") == .orderedSame { return true }
            if s.caseInsensitiveCompare("false") == .orderedSame { return false }
            return nil
        default: return nil
        }
    }

    private static func clamp(_ v: Int, low: Int, high: Int) -> Int {
        max(low, min(v, high))
    }
}

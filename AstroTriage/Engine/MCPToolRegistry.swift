// Defines the 13 MCP tools exposed by AstroBlinkV2's in-app HTTP server and
// registers them on a Server instance.
//
// All tools call directly into FrameHistoryDatabase / AstroRootStore /
// ArchiveScanner / TriageViewModel (via MCPViewModelBridge). No URL scheme,
// no helper subprocess, no command_status polling.
import Foundation
import MCP
import GRDB

enum MCPToolRegistry {

    static func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in
            return .init(tools: Self.toolList)
        }

        await server.withMethodHandler(CallTool.self) { params in
            return await Self.dispatch(name: params.name, arguments: params.arguments)
        }
    }

    // MARK: - Tool list

    static let toolList: [Tool] = [
        Tool(
            name: "ping",
            description: "Health check. Returns 'pong' plus server version and a snapshot of the active session (image count, current folder).",
            inputSchema: emptyObject
        ),
        Tool(
            name: "list_setups",
            description: "Equipment setups known to AstroBlinkV2 (aggregated from frame_record). Each entry has a setupHash, nickname (if any), telescope, camera, focal length, frame count, and first/last observing night. Use the setupHash to filter other tools.",
            inputSchema: emptyObject
        ),
        Tool(
            name: "list_astro_roots",
            description: "User-configured default astro file folders (configured in Window → Astrofile Locations). Each entry has a path, optional setupTag (e.g. \"RC12\"), and a nickname. The setupTag can be used by scan tools to resolve human-friendly references.",
            inputSchema: emptyObject
        ),
        Tool(
            name: "list_nights",
            description: "Distinct observing nights (newest first). Optional filters: setupHash, target (canonical name).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "setupHash": .object(["type": .string("string")]),
                    "target": .object(["type": .string("string")])
                ])
            ])
        ),
        Tool(
            name: "night_summary",
            description: "Per-(target, filter) aggregates for a specific observing night: frame count, trash count, median FWHM/HFR/stars/noise/trailing, total integration seconds, ambient temp, moon illumination.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("date")]),
                "properties": .object([
                    "date": .object(["type": .string("string"), "description": .string("Observing night in YYYY-MM-DD form")]),
                    "setupHash": .object(["type": .string("string")]),
                    "target": .object(["type": .string("string")])
                ])
            ])
        ),
        Tool(
            name: "recent_sessions",
            description: "Last N sessions (newest first). Each entry includes setup, target, frame/trash/deleted counts, observing night. Default 5, max 50.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "count": .object(["type": .string("integer")]),
                    "setupHash": .object(["type": .string("string")])
                ])
            ])
        ),
        Tool(
            name: "target_integration",
            description: "Total integration time per filter for a canonical target across all sessions. Excludes deleted frames.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("target")]),
                "properties": .object([
                    "target": .object(["type": .string("string")])
                ])
            ])
        ),
        Tool(
            name: "frames",
            description: "Per-frame detail rows. Optional filters: night, target, filter, qualityMin (0=trash, 1=borderline, 2=good, 3=excellent, 4=uncertain), setupHash. Hard limit 500 rows.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "night": .object(["type": .string("string")]),
                    "target": .object(["type": .string("string")]),
                    "filter": .object(["type": .string("string")]),
                    "qualityMin": .object(["type": .string("integer")]),
                    "setupHash": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")])
                ])
            ])
        ),
        Tool(
            name: "setup_summary",
            description: "Aggregate stats for one setup: total frames, session count, distinct targets, first/last night, median FWHM/HFR, trash rate.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("setupHash")]),
                "properties": .object([
                    "setupHash": .object(["type": .string("string")])
                ])
            ])
        ),
        Tool(
            name: "quality_summary",
            description: "Quality breakdown for a scope: per-filter aggregates, tier counts, top 10 garbage reasons, top 10 worst frames by combinedZScore. Scope is set by exactly one of: setupHash | night | sessionId. Empty = global.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "setupHash": .object(["type": .string("string")]),
                    "night": .object(["type": .string("string")]),
                    "sessionId": .object(["type": .string("string")])
                ])
            ])
        ),
        Tool(
            name: "filter_advice",
            description: "Integration time per filter for a target, plus a heuristic 'next filter' recommendation (least good/excellent hours, capped at 5h).",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("target")]),
                "properties": .object([
                    "target": .object(["type": .string("string")])
                ])
            ])
        ),
        Tool(
            name: "scan_for_new_frames",
            description: "Trigger AstroBlinkV2 to scan a folder for new astro files, decode + score, and write to Frame History. Resolves the folder by setupTag (looked up via list_astro_roots) or by explicit absolute path. Returns when the scan completes (typically 2-5 minutes for a few hundred frames).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "root": .object(["type": .string("string")]),
                    "setupTag": .object(["type": .string("string")]),
                    "timeoutSeconds": .object(["type": .string("integer")])
                ])
            ])
        ),
        Tool(
            name: "mark_auto_garbage_for_predelete",
            description: "Identify frames algorithmically classified as trash (qualityTier=0). dryRun=true (default): just return the list. dryRun=false: ask the active session to set the PRE-DELETE checkboxes. Move-to-trash still requires the user to press Cmd+Backspace.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "setupHash": .object(["type": .string("string")]),
                    "night": .object(["type": .string("string")]),
                    "dryRun": .object(["type": .string("boolean")])
                ])
            ])
        )
    ]

    private static let emptyObject: Value = .object([
        "type": .string("object"), "properties": .object([:])
    ])

    // MARK: - Dispatch

    @MainActor
    static func dispatch(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        switch name {
        case "ping":              return await ping()
        case "list_setups":       return runJSON { try setupsListData() }
        case "list_astro_roots":  return runJSON { astroRootsListData() }
        case "list_nights":       return runJSON {
            try FrameHistoryDatabase.shared.availableNightsForMCP(
                setupHash: stringArg(arguments, "setupHash"),
                target: stringArg(arguments, "target"))
        }
        case "night_summary":
            guard let date = stringArg(arguments, "date") else { return errorJSON("Missing required: date (YYYY-MM-DD)") }
            return runJSON {
                try FrameHistoryDatabase.shared.nightSummaryForMCP(
                    date: date,
                    setupHash: stringArg(arguments, "setupHash"),
                    target: stringArg(arguments, "target"))
            }
        case "recent_sessions":
            let count = max(1, min(intArg(arguments, "count") ?? 5, 50))
            return runJSON {
                try FrameHistoryDatabase.shared.recentSessionsForMCP(
                    limit: count, setupHash: stringArg(arguments, "setupHash"))
            }
        case "target_integration":
            guard let target = stringArg(arguments, "target") else { return errorJSON("Missing required: target") }
            return runJSON { try FrameHistoryDatabase.shared.targetIntegrationForMCP(target: target) }
        case "frames":
            let limit = max(1, min(intArg(arguments, "limit") ?? 500, 500))
            return runJSON {
                try FrameHistoryDatabase.shared.framesForMCP(
                    night: stringArg(arguments, "night"),
                    target: stringArg(arguments, "target"),
                    filter: stringArg(arguments, "filter"),
                    qualityMin: intArg(arguments, "qualityMin"),
                    setupHash: stringArg(arguments, "setupHash"),
                    limit: limit)
            }
        case "setup_summary":
            guard let setup = stringArg(arguments, "setupHash") else { return errorJSON("Missing required: setupHash") }
            return runJSON { try FrameHistoryDatabase.shared.setupSummaryForMCP(setupHash: setup) }
        case "quality_summary":
            return runJSON {
                try FrameHistoryDatabase.shared.qualitySummaryForMCP(
                    setupHash: stringArg(arguments, "setupHash"),
                    night: stringArg(arguments, "night"),
                    sessionId: stringArg(arguments, "sessionId"))
            }
        case "filter_advice":
            guard let target = stringArg(arguments, "target") else { return errorJSON("Missing required: target") }
            return runJSON { try FrameHistoryDatabase.shared.filterAdviceForMCP(target: target) }
        case "scan_for_new_frames":
            return await scanForNewFrames(arguments: arguments)
        case "mark_auto_garbage_for_predelete":
            return await markAutoGarbage(arguments: arguments)
        default:
            return errorJSON("Unknown tool: \(name)")
        }
    }

    // MARK: - ping

    @MainActor
    private static func ping() async -> CallTool.Result {
        let vm = MCPViewModelBridge.shared.viewModel
        let count = vm?.images.count ?? 0
        let folder = vm?.sessionRootURL?.path ?? "(no session loaded)"
        let port = MCPHTTPServer.shared.boundPort.map(String.init) ?? "?"
        let msg = "pong — AstroBlinkV2 MCP 6.3.0, port=\(port), session=\(count) images, folder=\(folder)"
        return .init(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: false)
    }

    // MARK: - read helpers

    @MainActor
    private static func setupsListData() throws -> [[String: AnyEncodable]] {
        let rows = try FrameHistoryDatabase.shared.listSetupsForMCP()
        return rows.map { row in
            [
                "setupHash": AnyEncodable(row.setupHash),
                "nickname": AnyEncodable(row.nickname),
                "telescope": AnyEncodable(row.telescope),
                "camera": AnyEncodable(row.camera),
                "focalLengthMm": AnyEncodable(row.focalLengthMm),
                "frameCount": AnyEncodable(row.frameCount),
                "firstNight": AnyEncodable(row.firstNight),
                "lastNight": AnyEncodable(row.lastNight)
            ]
        }
    }

    @MainActor
    private static func astroRootsListData() -> [[String: AnyEncodable]] {
        AstroRootStore.shared.allRoots().map { r in
            [
                "id": AnyEncodable(r.id),
                "path": AnyEncodable(r.path),
                "setupTag": AnyEncodable(r.setupTag),
                "nickname": AnyEncodable(r.nickname),
                "displayName": AnyEncodable(r.displayName),
                "createdAt": AnyEncodable(r.createdAt),
                "lastUsedAt": AnyEncodable(r.lastUsedAt)
            ]
        }
    }

    // MARK: - scan_for_new_frames

    @MainActor
    private static func scanForNewFrames(arguments: [String: Value]?) async -> CallTool.Result {
        let timeoutSeconds = max(60, min(intArg(arguments, "timeoutSeconds") ?? 600, 3600))

        // Resolve folder.
        let url: URL
        var rootRecord: AstroRoot?
        if let path = stringArg(arguments, "root") {
            rootRecord = AstroRootStore.shared.allRoots().first { $0.path == path }
            if rootRecord == nil {
                return errorJSON("Folder not registered. Add it in Window → Astrofile Locations: \(path)")
            }
            guard let resolved = AstroRootStore.shared.resolve(rootRecord!) else {
                return errorJSON("Bookmark resolve failed for \(path). Re-add the folder.")
            }
            url = resolved
        } else if let tag = stringArg(arguments, "setupTag") {
            guard let r = AstroRootStore.shared.root(matchingSetupTag: tag) else {
                return errorJSON("No astro_root registered with setupTag=\(tag). Configure in Window → Astrofile Locations.")
            }
            rootRecord = r
            guard let resolved = AstroRootStore.shared.resolve(r) else {
                return errorJSON("Bookmark resolve failed for \(r.path). Re-add the folder.")
            }
            url = resolved
        } else {
            return errorJSON("Provide either `root` (absolute path) or `setupTag` (matches a registered astro_root).")
        }

        defer { url.stopAccessingSecurityScopedResource() }

        if ArchiveScanner.shared.isScanning {
            return errorJSON("Another scan is already running. Wait for it to finish or cancel in the app.")
        }

        // Kick off scan and poll @MainActor state until done or timeout.
        ArchiveScanner.shared.startScan(rootURL: url)
        await Task.yield()

        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while ArchiveScanner.shared.isScanning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let timedOut = ArchiveScanner.shared.isScanning
        let summary: [String: AnyEncodable] = [
            "framesScanned": AnyEncodable(ArchiveScanner.shared.totalProcessed),
            "framesFound": AnyEncodable(ArchiveScanner.shared.totalFound),
            "rootPath": AnyEncodable(rootRecord?.path ?? url.path),
            "setupTag": AnyEncodable(rootRecord?.setupTag),
            "timedOut": AnyEncodable(timedOut),
            "scanSessionId": AnyEncodable(ArchiveScanner.shared.scanSessionId)
        ]
        return successJSON(summary)
    }

    // MARK: - mark_auto_garbage_for_predelete

    @MainActor
    private static func markAutoGarbage(arguments: [String: Value]?) async -> CallTool.Result {
        let dryRun = boolArg(arguments, "dryRun") ?? true
        let setupHash = stringArg(arguments, "setupHash")
        let night = stringArg(arguments, "night")

        let candidates: [(fileHash: String, filePath: String, filename: String)]
        do {
            candidates = try FrameHistoryDatabase.shared.autoGarbageCandidates(
                setupHash: setupHash, night: night)
        } catch {
            return errorJSON("Query failed: \(error.localizedDescription)")
        }

        if dryRun {
            let summary: [String: AnyEncodable] = [
                "dryRun": AnyEncodable(true),
                "matchCount": AnyEncodable(candidates.count),
                "files": AnyEncodable(candidates.prefix(50).map { $0.filename })
            ]
            return successJSON(summary)
        }

        // Apply marks via the active view model.
        guard let vm = MCPViewModelBridge.shared.viewModel else {
            return errorJSON("App is not fully started. Open AstroBlink and try again.")
        }
        let hashes = Set(candidates.map { $0.fileHash })
        let result = vm.markByFileHashes(hashes)
        let summary: [String: AnyEncodable] = [
            "dryRun": AnyEncodable(false),
            "markedCount": AnyEncodable(result.marked),
            "notFoundInSession": AnyEncodable(result.notFound),
            "totalRequested": AnyEncodable(candidates.count),
            "hint": AnyEncodable(result.marked == 0
                ? "No matching frames in the active session. Open the relevant folder in AstroBlink first or call scan_for_new_frames."
                : "Press Cmd+Backspace in AstroBlink to move the marked frames to PRE-DELETE.")
        ]
        return successJSON(summary)
    }

    // MARK: - JSON helpers

    private static func runJSON<T: Encodable>(_ work: () throws -> T) -> CallTool.Result {
        do {
            let value = try work()
            return successJSON(["ok": AnyEncodable(true), "data": AnyEncodable(value)])
        } catch {
            return errorJSON("Query failed: \(error.localizedDescription)")
        }
    }

    private static func successJSON(_ payload: [String: AnyEncodable]) -> CallTool.Result {
        var full = payload
        full["ok"] = AnyEncodable(true)
        return jsonText(["ok": AnyEncodable(true), "data": AnyEncodable(payload)])
    }

    private static func jsonText(_ payload: [String: AnyEncodable]) -> CallTool.Result {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text: String
        if let data = try? enc.encode(payload), let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = "{\"ok\":false,\"error\":\"JSON encoding failed\"}"
        }
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private static func errorJSON(_ msg: String) -> CallTool.Result {
        let escaped = (try? String(data: JSONEncoder().encode(msg), encoding: .utf8)) ?? "\"\""
        let text = "{\"ok\":false,\"error\":\(escaped)}"
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
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
}

/// Type-erased Encodable wrapper for heterogeneous dictionaries.
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T?) {
        self._encode = { encoder in
            if let value {
                try value.encode(to: encoder)
            } else {
                var c = encoder.singleValueContainer()
                try c.encodeNil()
            }
        }
    }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

// MCP tool definitions + dispatch for the read-only family.
//
// Each tool returns a single text content carrying a JSON string. Schema follows
// the simple MCP `inputSchema` JSON-Schema-lite convention. Errors are surfaced
// via MCPToolResponse.failure(...) so callers can detect them programmatically;
// the SDK's `isError` flag is reserved for *protocol* errors (unknown tool, etc.).
import Foundation
import MCP

enum ReadTools {

    // MARK: - Schema definitions

    static func toolList() -> [Tool] {
        [
            Tool(
                name: "list_setups",
                description: "Equipment setups known to AstroBlinkV2 (aggregated from frame_record). Each entry has a setupHash, nickname (if any), telescope, camera, focal length, frame count, and first/last observing night. Use the setupHash to filter other tools.",
                inputSchema: emptyObject
            ),
            Tool(
                name: "list_astro_roots",
                description: "User-configured default astro file folders (configured in AstroBlinkV2 → Window → Astrofile Locations). Each entry has a path, optional setupTag (e.g. \"RC12\"), and a nickname. The setupTag can be used by scan tools to resolve human-friendly references.",
                inputSchema: emptyObject
            ),
            Tool(
                name: "list_nights",
                description: "Distinct observing nights (newest first). Optional filters: setupHash, target (canonical name).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "setupHash": .object(["type": .string("string"), "description": .string("Filter to this setup")]),
                        "target": .object(["type": .string("string"), "description": .string("Filter to this canonical target name")])
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
                description: "Last N sessions (newest first). Each entry includes setup, target, frame/trash/deleted counts, observing night. Use this for quick \"what did I image lately\" queries.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "count": .object(["type": .string("integer"), "description": .string("How many sessions (default 5, max 50)")]),
                        "setupHash": .object(["type": .string("string")])
                    ])
                ])
            ),
            Tool(
                name: "target_integration",
                description: "Total integration time per filter for a canonical target across all sessions. Excludes deleted frames. Also reports the count of good-or-excellent quality frames.",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("target")]),
                    "properties": .object([
                        "target": .object(["type": .string("string"), "description": .string("Canonical target name, e.g. \"NGC 7635\", \"M 42\"")])
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
            )
        ]
    }

    private static let emptyObject: Value = .object([
        "type": .string("object"),
        "properties": .object([:])
    ])

    // MARK: - Dispatch

    /// Returns nil if the tool name isn't handled here. Otherwise returns the result
    /// (success or failure), already encoded as JSON text content.
    static func handle(name: String, arguments: [String: Value]?) -> CallTool.Result? {
        let db: ReadOnlyFrameHistoryDB
        do {
            db = try ReadOnlyFrameHistoryDB()
        } catch {
            return Self.errorText("Cannot open FrameHistory DB: \(error.localizedDescription)")
        }

        switch name {
        case "list_setups":
            return runTool { try db.listSetups() }
        case "list_astro_roots":
            return runTool { try db.listAstroRoots() }
        case "list_nights":
            let setup = stringArg(arguments, "setupHash")
            let target = stringArg(arguments, "target")
            return runTool { try db.availableNights(setupHash: setup, target: target) }
        case "night_summary":
            guard let date = stringArg(arguments, "date") else {
                return errorText("Missing required argument: date (YYYY-MM-DD)")
            }
            let setup = stringArg(arguments, "setupHash")
            let target = stringArg(arguments, "target")
            return runTool { try db.nightSummary(date: date, setupHash: setup, target: target) }
        case "recent_sessions":
            let count = intArg(arguments, "count") ?? 5
            let clamped = max(1, min(count, 50))
            let setup = stringArg(arguments, "setupHash")
            return runTool { try db.recentSessions(limit: clamped, setupHash: setup) }
        case "target_integration":
            guard let target = stringArg(arguments, "target") else {
                return errorText("Missing required argument: target")
            }
            return runTool { try db.targetIntegration(target: target) }
        case "frames":
            let limit = intArg(arguments, "limit") ?? 500
            return runTool {
                try db.frames(
                    night: stringArg(arguments, "night"),
                    target: stringArg(arguments, "target"),
                    filter: stringArg(arguments, "filter"),
                    qualityMin: intArg(arguments, "qualityMin"),
                    setupHash: stringArg(arguments, "setupHash"),
                    limit: max(1, min(limit, 500))
                )
            }
        case "setup_summary":
            guard let setup = stringArg(arguments, "setupHash") else {
                return errorText("Missing required argument: setupHash")
            }
            return runTool { try db.setupSummary(setupHash: setup) }
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static func runTool<T: Codable>(_ work: () throws -> T) -> CallTool.Result {
        do {
            let data = try work()
            return successJSON(MCPToolResponse.success(data))
        } catch {
            return errorText("DB query failed: \(error.localizedDescription)")
        }
    }

    private static func successJSON<T: Codable>(_ value: T) -> CallTool.Result {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text: String
        if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = "{\"ok\":false,\"error\":\"JSON encoding failed\"}"
        }
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private static func errorText(_ msg: String) -> CallTool.Result {
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
}

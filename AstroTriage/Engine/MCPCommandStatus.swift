// Persisted state of an async command coming from the MCP server.
//
// Flow:
//   1. MCP server inserts a row with a fresh commandId, state=pending.
//   2. MCP server fires astroblink://<verb>?id=<commandId>&… via NSWorkspace/open.
//   3. App's URL handler reads the row, flips state→running, dispatches the work.
//   4. As work progresses, app updates progressCurrent/progressTotal.
//   5. On completion, app writes state=completed with a JSON resultSummary.
//      On error, state=failed with errorMessage.
//   6. MCP server polls the row every ~2s until state ∈ {completed, failed}.
//
// All timestamps are ISO8601.
import Foundation
import GRDB

struct MCPCommandStatus: Codable, FetchableRecord, PersistableRecord {
    var commandId: String
    var verb: String
    var state: String   // "pending" | "running" | "completed" | "failed"
    var startedAt: String?
    var completedAt: String?
    var progressCurrent: Int?
    var progressTotal: Int?
    var resultSummary: String?
    var errorMessage: String?

    static let databaseTableName = "mcp_command_status"

    static func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

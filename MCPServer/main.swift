// AstroBlinkMCPServer — entry point.
//
// Exposes AstroBlinkV2 to LLM clients (Claude Desktop, Claude Code, …) over
// stdio JSON-RPC using the official Model Context Protocol Swift SDK.
//
// Tool categories:
//   • Read-only (ReadTools.swift): query the FrameHistory SQLite directly.
//     App does NOT need to be running for these.
//   • App-delegating (not yet wired): fire astroblink:// URL scheme verbs and
//     poll the mcp_command_status table. App must be running.
//
// A file literally named main.swift is treated by Swift as a script with
// top-level code, so @main is not used here — execution runs through these
// statements directly.
import Foundation
import MCP

let server = Server(
    name: "AstroBlinkMCPServer",
    version: "0.2.0",
    capabilities: .init(tools: .init(listChanged: false))
)

// List tools — `ping` (health check) plus the 8 read-only tools.
await server.withMethodHandler(ListTools.self) { _ in
    var tools: [Tool] = [
        Tool(
            name: "ping",
            description: "Health check. Returns 'pong' plus server version, user, and the FrameHistory DB path being read.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        )
    ]
    tools.append(contentsOf: ReadTools.toolList())
    return .init(tools: tools)
}

// Dispatch tool calls.
await server.withMethodHandler(CallTool.self) { params in
    // Health check.
    if params.name == "ping" {
        let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        let path = ReadOnlyFrameHistoryDB.resolveDBPath()
        let exists = FileManager.default.fileExists(atPath: path) ? "present" : "MISSING"
        let msg = "pong — AstroBlinkMCPServer 0.2.0, user=\(user), db=\(path) (\(exists))"
        return .init(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: false)
    }

    // Read-only tools.
    if let result = ReadTools.handle(name: params.name, arguments: params.arguments) {
        return result
    }

    return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
}

// Stdio transport — the standard for local subprocess MCP servers.
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()

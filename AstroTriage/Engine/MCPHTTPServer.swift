// In-process HTTP MCP server.
//
// Replaces the helper-binary architecture (v6.1.0 stdio) with an HTTP server
// that runs inside AstroBlinkV2.app itself. Listens on 127.0.0.1:<port> at the
// /mcp endpoint. External MCP clients (Claude Code, future Claude Desktop
// versions, custom integrations) connect via http://127.0.0.1:<port>/mcp.
//
// Why this is the right architecture:
//   • Tools call FrameHistoryDatabase, AstroRootStore, ArchiveScanner, and the
//     active TriageViewModel DIRECTLY — no URL-scheme/polling dance.
//   • Works for the App Store version with just the network.server entitlement.
//   • No helper binary to bundle, sign, or version-skew.
//
// Trade-off vs. the old stdio helper: the app must be running. For the small
// number of "answer questions about my history" workflows that used to work
// without the app open, the user can launch the app first.
//
// Pattern cribbed from modelcontextprotocol/swift-sdk
// Sources/MCPConformance/Server/HTTPApp.swift (Apache-2.0).
import Foundation
import MCP
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

@MainActor
final class MCPHTTPServer {
    static let shared = MCPHTTPServer()

    struct Configuration: Sendable {
        var host: String = "127.0.0.1"     // localhost only — never bind to all interfaces
        var port: Int = 8765               // fixed default; if busy, server retries up to maxPortRetries higher
        var maxPortRetries: Int = 16
        var endpoint: String = "/mcp"
        var sessionTimeout: TimeInterval = 3600
    }

    private(set) var configuration = Configuration()
    private(set) var boundPort: Int?       // actual port we ended up on (may differ from configuration.port)
    private(set) var isRunning = false

    private var coordinator: HTTPCoordinator?
    private let logger = Logger(label: "mcp.http.server", factory: { _ in SwiftLogNoOpLogHandler() })

    /// Start the server. Idempotent: subsequent calls are no-ops if already running.
    func start(configuration: Configuration = Configuration()) {
        guard !isRunning else { return }
        self.configuration = configuration

        let coord = HTTPCoordinator(configuration: configuration, logger: logger)
        self.coordinator = coord

        Task.detached(priority: .utility) {
            do {
                let port = try await coord.start()
                await MainActor.run {
                    self.boundPort = port
                    self.isRunning = true
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.coordinator = nil
                }
                NSLog("MCPHTTPServer failed to start: \(error.localizedDescription)")
            }
        }
    }

    /// The URL clients should connect to (e.g. http://127.0.0.1:8765/mcp).
    /// Returns nil if the server hasn't successfully bound yet.
    var endpointURL: String? {
        guard let port = boundPort else { return nil }
        return "http://\(configuration.host):\(port)\(configuration.endpoint)"
    }
}

// MARK: - Coordinator (non-isolated, runs the NIO loop)

private actor HTTPCoordinator {
    let configuration: MCPHTTPServer.Configuration
    let logger: Logger
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    private var group: MultiThreadedEventLoopGroup?

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    init(configuration: MCPHTTPServer.Configuration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
    }

    /// Start the server, returning the port we actually bound to. If the
    /// configured port is busy, increments and retries up to maxPortRetries.
    func start() async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(coordinator: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        var lastError: Error?
        for attempt in 0..<configuration.maxPortRetries {
            let port = configuration.port + attempt
            do {
                let channel = try await bootstrap.bind(host: configuration.host, port: port).get()
                self.channel = channel
                Task { await self.sessionCleanupLoop() }
                return port
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "MCPHTTPServer", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "No free port in range"])
    }

    var endpoint: String { configuration.endpoint }

    private static func isInitializeBody(_ body: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return (obj["method"] as? String) == "initialize"
    }

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return response
        }

        // New session: requires a POST with initialize body. We can't use
        // the SDK's internal JSONRPCMessageKind from outside the package, so
        // parse the method string ourselves — `"method": "initialize"` is the
        // only signal we need.
        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeBody(body) {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(statusCode: 400,
                      .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            logger: logger
        )

        do {
            let server = Server(
                name: "AstroBlinkV2",
                version: "6.2.0",
                capabilities: .init(tools: .init(listChanged: false))
            )
            await MCPToolRegistry.register(on: server)
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server, transport: transport,
                createdAt: Date(), lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500,
                          .internalError("Failed to create session: \(error.localizedDescription)"))
        }
    }

    private func sessionCleanupLoop() async {
        while true {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            let now = Date()
            let expired = sessions.filter { _, ctx in
                now.timeIntervalSince(ctx.lastAccessedAt) > configuration.sessionTimeout
            }
            for (id, _) in expired {
                if let ctx = sessions.removeValue(forKey: id) {
                    await ctx.transport.disconnect()
                }
            }
        }
    }
}

// MARK: - NIO handler

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let coordinator: HTTPCoordinator

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }
    private var requestState: RequestState?

    init(coordinator: HTTPCoordinator) {
        self.coordinator = coordinator
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buf):
            requestState?.bodyBuffer.writeBuffer(&buf)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            nonisolated(unsafe) let ctx = context
            Task {
                await self.handle(state: state, context: ctx)
            }
        }
    }

    private func handle(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await coordinator.endpoint

        guard path == endpoint else {
            await writeResponse(.error(statusCode: 404, .invalidRequest("Not Found")),
                                version: head.version, context: context)
            return
        }
        let req = makeRequest(state)
        let res = await coordinator.handleHTTPRequest(req)
        await writeResponse(res, version: head.version, context: context)
    }

    private func makeRequest(_ state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes) {
            body = Data(bytes)
        } else {
            body = nil
        }
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(method: state.head.method.rawValue,
                           headers: headers, body: body, path: path)
    }

    private func writeResponse(_ response: HTTPResponse, version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buf = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buf.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                    }
                }
            } catch { /* stream ended with error → close */ }
            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body = bodyData {
                    var buf = ctx.channel.allocator.buffer(capacity: body.count)
                    buf.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

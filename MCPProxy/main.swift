// AstroBlinkMCPProxy — bridges stdio MCP clients (Claude Desktop) to the
// HTTPS MCP server running inside AstroBlinkV2.app.
//
// Why this exists: Claude Desktop's claude_desktop_config.json only accepts
// stdio MCP server entries — it can't yet point at a URL directly. So we
// bundle this dumb byte-pump in AstroBlinkV2.app/Contents/Helpers/, point
// the user's claude_desktop_config at it, and let it forward each JSON-RPC
// line to https://127.0.0.1:8765/mcp.
//
// Architecturally: this is NOT the v6.1.0 helper binary. That one was a
// full MCP server with DB access and business logic. This one has zero
// app state — it just reads stdin, POSTs to localhost, writes the SSE
// `data:` payload back to stdout. ~120 LOC, sandbox-safe (only needs
// network.client to talk to localhost), App Store compatible.
//
// Override the default URL via env var MCP_PROXY_URL for development.
import Foundation

let serverURL: URL = {
    let raw = ProcessInfo.processInfo.environment["MCP_PROXY_URL"]
        ?? "https://127.0.0.1:8765/mcp"
    return URL(string: raw)!
}()

let stderr = FileHandle.standardError
let stdout = FileHandle.standardOutput

func log(_ message: String) {
    stderr.write(Data("AstroBlinkMCPProxy: \(message)\n".utf8))
}

/// Localhost-only TLS handler.
///
/// The server cert is self-signed and scoped to 127.0.0.1 + localhost.
/// If the user installed it via the in-app "Install Certificate" button,
/// default URLSession validation succeeds. If not, we still accept on
/// localhost — there is no meaningful MITM threat for a 127.0.0.1 socket
/// (any malware running as this user can already do worse).
final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.host == "127.0.0.1"
                || challenge.protectionSpace.host == "localhost" else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

let urlSession = URLSession(configuration: .ephemeral,
                            delegate: LocalhostTrustDelegate(),
                            delegateQueue: nil)

var sessionID: String? = nil

/// Forward a single JSON-RPC message line to the HTTPS server. Capture the
/// session ID from the first response. Parse SSE `data:` payloads and write
/// each one to stdout as its own line.
func forward(_ jsonLine: String) {
    var req = URLRequest(url: serverURL)
    req.httpMethod = "POST"
    req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let sid = sessionID {
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
    }
    req.httpBody = Data(jsonLine.utf8)
    req.timeoutInterval = 3600  // long-poll friendly

    let sem = DispatchSemaphore(value: 0)
    var bodyData: Data?
    var responseHeaders: [AnyHashable: Any]?
    var statusCode = 0
    var requestError: Error?

    let task = urlSession.dataTask(with: req) { data, response, error in
        bodyData = data
        if let http = response as? HTTPURLResponse {
            responseHeaders = http.allHeaderFields
            statusCode = http.statusCode
        }
        requestError = error
        sem.signal()
    }
    task.resume()
    sem.wait()

    if let error = requestError {
        log("Upstream error: \(error.localizedDescription)")
        return
    }

    // Capture session id on first response (header name is case-insensitive).
    if sessionID == nil, let headers = responseHeaders {
        for (key, value) in headers {
            if let name = key as? String, name.lowercased() == "mcp-session-id",
               let stringValue = value as? String, !stringValue.isEmpty {
                sessionID = stringValue
                break
            }
        }
    }

    // 202 Accepted = notification, no body to forward.
    guard statusCode == 200, let data = bodyData,
          let text = String(data: data, encoding: .utf8) else { return }

    // Streamable-HTTP responses are SSE frames separated by blank lines.
    // We only care about lines starting with "data:" — those carry the
    // JSON-RPC payload Claude Desktop expects on its stdin.
    for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
        let l = String(line)
        if l.hasPrefix("data: ") {
            let payload = String(l.dropFirst(6))
            guard !payload.isEmpty else { continue }
            stdout.write(Data((payload + "\n").utf8))
        } else if l.hasPrefix("data:") {
            // tolerate "data:" without trailing space
            let payload = String(l.dropFirst(5))
            guard !payload.isEmpty else { continue }
            stdout.write(Data((payload + "\n").utf8))
        }
    }
    try? stdout.synchronize()
}

// Make stdout line-buffered so Claude Desktop sees each response as soon as
// we write it, not in chunks after the OS pipe buffer fills.
setvbuf(__stdoutp, nil, _IOLBF, 0)

log("started, forwarding stdio ↔ \(serverURL.absoluteString)")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    forward(trimmed)
}

log("stdin closed, exiting")

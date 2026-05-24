// "MCP Connector" — one-click install of AstroBlink's in-process HTTPS MCP
// server into Claude Desktop / Claude Code config. v6.3.0 adds TLS termination
// (Claude Desktop refuses plain http://), so the user has to trust the
// self-signed cert once via Keychain.
//
// Two-step UX:
//   1. Click "Install Certificate" — adds the self-signed cert to the user's
//      login keychain as trusted for SSL on 127.0.0.1. macOS shows ONE
//      "Allow AstroBlinkV2 to access your keychain" prompt the first time.
//   2. Click "Install to Claude Desktop" — writes the URL config to
//      claude_desktop_config.json. No more dependencies.
//
// What the install does:
//   1. Reads ~/Library/Application Support/Claude/claude_desktop_config.json
//   2. Backs up the current file with a timestamp suffix
//   3. Merges (or replaces) the "astroblink" entry under "mcpServers"
//   4. Writes back atomically
//
// Existing keys (preferences, other mcpServers entries) are preserved.
import SwiftUI
import AppKit
import Security

@MainActor
class MCPConnectorWindowController {
    static let shared = MCPConnectorWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let nightMode = AppSettings.loadBool(for: .nightMode) == true
        let model = MCPConnectorModel()
        let rootView = MCPConnectorView(model: model, nightMode: nightMode)
        let hostingView = NSHostingView(rootView: rootView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "MCP Connector — Drive AstroBlink from Claude"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 560, height: 420)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Model

@MainActor
final class MCPConnectorModel: ObservableObject {
    @Published var status: String = ""
    @Published var statusIsError = false
    @Published var endpointURL: String = "(server starting…)"

    let claudeConfigPath: String

    private var refreshTimer: Timer?

    init() {
        self.claudeConfigPath = (NSString(string: "~/Library/Application Support/Claude/claude_desktop_config.json")
            .expandingTildeInPath)
        refreshEndpoint()
        refreshCertificateTrust()
        // Poll the server endpoint every 500 ms until it's bound (server starts
        // async at launch; usually ready in <1s but can take longer on cold disk).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshEndpoint()
                self?.refreshCertificateTrust()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refreshEndpoint() {
        if let url = MCPHTTPServer.shared.endpointURL {
            endpointURL = url
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    var serverReady: Bool {
        MCPHTTPServer.shared.isRunning && MCPHTTPServer.shared.endpointURL != nil
    }

    var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: (NSString(string: "~/Applications/Claude.app").expandingTildeInPath))
    }

    /// True if our self-signed cert is already present in the user's keychain
    /// AND marked as trusted for SSL. We re-check on each panel show.
    @Published var certificateTrusted: Bool = false

    func refreshCertificateTrust() {
        certificateTrusted = checkCertificateTrust()
    }

    private func checkCertificateTrust() -> Bool {
        guard let der = MCPHTTPServer.shared.tlsCertificateDER,
              let cert = SecCertificateCreateWithData(nil, der as CFData) else { return false }
        // Probe: does an SSL trust eval against this cert succeed?
        let policy = SecPolicyCreateSSL(true, "127.0.0.1" as CFString)
        var trust: SecTrust?
        let createStatus = SecTrustCreateWithCertificates(cert, policy, &trust)
        guard createStatus == errSecSuccess, let trust else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    func installCertificate() {
        guard let der = MCPHTTPServer.shared.tlsCertificateDER,
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            status = "Certificate not yet generated. Try again in a moment."
            statusIsError = true
            return
        }

        // 1. Add the cert to the user's login keychain.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: "AstroBlinkV2 MCP (localhost)"
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            status = "Couldn't add cert to keychain (OSStatus \(addStatus)). Try again or contact support."
            statusIsError = true
            return
        }

        // 2. Mark it trusted for the SSL policy in the user's trust settings.
        //    Writing to .user (not .admin) avoids the admin password prompt.
        let trustSettings: [[String: Any]] = [[
            kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil)
        ]]
        let trustStatus = SecTrustSettingsSetTrustSettings(cert, .user, trustSettings as CFArray)
        if trustStatus != errSecSuccess {
            status = "Cert added to keychain but trust setting failed (OSStatus \(trustStatus)). Open Keychain Access → login → Certificates → 'AstroBlinkV2 MCP' and mark it 'Always Trust' for SSL."
            statusIsError = true
            certificateTrusted = false
            return
        }

        certificateTrusted = true
        status = "Certificate installed and trusted. You can now click Install to Claude Desktop."
        statusIsError = false
    }

    var configSnippet: String {
        let url = MCPHTTPServer.shared.endpointURL ?? "http://127.0.0.1:8765/mcp"
        return """
        {
          "mcpServers": {
            "astroblink": {
              "url": "\(url)"
            }
          }
        }
        """
    }

    func installToClaudeDesktop() {
        guard let url = MCPHTTPServer.shared.endpointURL else {
            status = "Server is not running yet — wait a moment and try again."
            statusIsError = true
            return
        }
        let fm = FileManager.default
        let cfgURL = URL(fileURLWithPath: claudeConfigPath)
        let cfgDir = cfgURL.deletingLastPathComponent()

        do {
            try fm.createDirectory(at: cfgDir, withIntermediateDirectories: true)

            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: cfgURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
                let stamp = DateFormatter.backupStamp.string(from: Date())
                let backupURL = cfgURL.appendingPathExtension("bak.\(stamp)")
                try? data.write(to: backupURL)
            }

            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            servers["astroblink"] = ["url": url]
            json["mcpServers"] = servers

            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: cfgURL, options: .atomic)

            status = "Installed. Quit and restart Claude Desktop (Cmd+Q, then re-open) to activate the connector."
            statusIsError = false
        } catch {
            status = "Install failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    func revealConfig() {
        let url = URL(fileURLWithPath: claudeConfigPath)
        if FileManager.default.fileExists(atPath: claudeConfigPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func copySnippet() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(configSnippet, forType: .string)
        status = "Snippet copied to clipboard."
        statusIsError = false
    }

    func testEndpoint() {
        guard let url = MCPHTTPServer.shared.endpointURL else {
            status = "Server is not running yet."
            statusIsError = true
            return
        }
        // Probe via curl-equivalent — initialize MCP request expecting an error
        // response (we're not sending Mcp-Session-Id) which proves the port is live.
        Task {
            do {
                var req = URLRequest(url: URL(string: url)!)
                req.httpMethod = "POST"
                req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#.data(using: .utf8)
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    let preview = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                    status = "HTTP \(code) — \(preview)"
                    statusIsError = code >= 500
                }
            } catch {
                await MainActor.run {
                    status = "Connection failed: \(error.localizedDescription)"
                    statusIsError = true
                }
            }
        }
    }
}

private extension DateFormatter {
    static let backupStamp: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()
}

// MARK: - View

struct MCPConnectorView: View {
    @ObservedObject var model: MCPConnectorModel
    let nightMode: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                preflight
                Divider()
                actions
                Divider()
                manualSection
                if !model.status.isEmpty {
                    statusBox
                }
            }
            .padding()
        }
        .background(AppColors.bg(nightMode))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect AstroBlink to Claude Desktop / Claude Code")
                .font(.title3).fontWeight(.semibold)
            Text("AstroBlink runs an HTTP MCP server inside the app itself. Once installed in your client's MCP config, you can ask things like \"Welche Setups habe ich?\" or \"Verarbeite die Aufnahmen der letzten Nacht vom RC12 Teleskop\" and the client will call back into this app to get the answer.")
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 6) {
            preflightRow(ok: model.serverReady,
                         okText: "MCP server is running at \(model.endpointURL)",
                         badText: "MCP server is not yet bound — give it a moment.")
            preflightRow(ok: model.certificateTrusted,
                         okText: "TLS certificate is installed and trusted",
                         badText: "TLS certificate not yet trusted — click \"Install Certificate\" below.")
            preflightRow(ok: model.claudeInstalled,
                         okText: "Claude Desktop is installed",
                         badText: "Claude Desktop is not installed. Download from claude.ai/download. (Claude Code also works — write to ~/.claude/mcp.json or your project's .mcp.json.)")
        }
    }

    private func preflightRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(ok ? .green : .orange)
            Text(ok ? okText : badText)
                .font(.callout)
                .foregroundColor(ok ? .primary : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Two-step install").font(.headline)
            HStack(spacing: 10) {
                Button {
                    model.installCertificate()
                } label: {
                    Label(model.certificateTrusted ? "Certificate Installed ✓" : "1. Install Certificate",
                          systemImage: "lock.shield")
                }
                .controlSize(.large)
                .disabled(model.certificateTrusted || !model.serverReady)

                Button {
                    model.installToClaudeDesktop()
                } label: {
                    Label("2. Install to Claude Desktop", systemImage: "wand.and.stars")
                }
                .controlSize(.large)
                .disabled(!model.serverReady)
            }
            HStack(spacing: 10) {
                Button {
                    model.revealConfig()
                } label: {
                    Label("Show Config in Finder", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    model.testEndpoint()
                } label: {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!model.serverReady || !model.certificateTrusted)
            }
            Text("The certificate is a self-signed cert valid for 10 years, scoped to localhost only. macOS may show a one-time keychain prompt the first time. Existing config entries are preserved; a timestamped .bak file is written next to the Claude config before any change.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or paste this manually").font(.headline)
            Text("If you maintain your client config yourself (Claude Desktop, Claude Code, custom), copy the snippet below and merge it under \"mcpServers\".")
                .font(.caption).foregroundColor(.secondary)
            Text(model.configSnippet)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button("Copy Snippet") { model.copySnippet() }
            }
        }
    }

    private var statusBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.statusIsError ? "xmark.octagon.fill" : "info.circle.fill")
                .foregroundColor(model.statusIsError ? .red : .accentColor)
            Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(6)
    }
}

// "MCP Connector" — sets up Claude Desktop / Claude Code to talk to the
// in-app MCP HTTPS server.
//
// Why two paths:
//   • Claude Desktop accepts ONLY stdio MCP servers in claude_desktop_config.json
//     ({"command":…,"args":…}). It can't reference URL endpoints from JSON.
//     So we ship a tiny bundled proxy (AstroBlinkMCPProxy in Contents/Helpers/)
//     that pumps bytes between stdin and https://127.0.0.1:8765/mcp, and the
//     user's config points at that proxy.
//   • Other MCP clients (Claude Code, custom integrations) can connect to
//     the HTTPS URL directly. For those, the TLS cert install button below
//     adds our self-signed cert to the user's keychain.
//
// Sandbox reality check:
//   AstroBlinkV2 is sandboxed. `~/Library/Application Support/Claude/` is
//   NOT in our container, so writing claude_desktop_config.json directly
//   from this app either silently writes a sandbox-shadowed copy (which
//   Claude never sees) or throws. We sidestep the whole problem: copy the
//   snippet to clipboard + open the config file in the user's default
//   JSON editor (TextEdit by default). User pastes, saves, done.
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "MCP Connector — Drive AstroBlink from Claude"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 480)
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
    @Published var certificateTrusted: Bool = false

    let claudeConfigPath: String
    let proxyBinaryPath: String

    private var refreshTimer: Timer?

    init() {
        self.claudeConfigPath = (NSString(string: "~/Library/Application Support/Claude/claude_desktop_config.json")
            .expandingTildeInPath)
        self.proxyBinaryPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/AstroBlinkMCPProxy", isDirectory: false)
            .path

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { refreshTimer?.invalidate() }

    func refresh() {
        if let url = MCPHTTPServer.shared.endpointURL {
            endpointURL = url
            refreshTimer?.invalidate(); refreshTimer = nil
        }
        certificateTrusted = checkCertificateTrust()
    }

    var serverReady: Bool {
        MCPHTTPServer.shared.isRunning && MCPHTTPServer.shared.endpointURL != nil
    }

    var proxyAvailable: Bool {
        FileManager.default.fileExists(atPath: proxyBinaryPath)
    }

    var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: (NSString(string: "~/Applications/Claude.app").expandingTildeInPath))
    }

    var stdioConfigSnippet: String {
        let escaped = proxyBinaryPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "astroblink": {
              "command": "\(escaped)"
            }
          }
        }
        """
    }

    var urlConfigSnippet: String {
        let url = MCPHTTPServer.shared.endpointURL ?? "https://127.0.0.1:8765/mcp"
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

    // MARK: - TLS cert (optional, for direct-URL clients)

    private func checkCertificateTrust() -> Bool {
        guard let der = MCPHTTPServer.shared.tlsCertificateDER,
              let cert = SecCertificateCreateWithData(nil, der as CFData) else { return false }
        let policy = SecPolicyCreateSSL(true, "127.0.0.1" as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, policy, &trust) == errSecSuccess,
              let trust else { return false }
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
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: "AstroBlinkV2 MCP (localhost)"
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            status = "Couldn't add cert to keychain (OSStatus \(addStatus))."
            statusIsError = true
            return
        }
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
        status = "Certificate installed. URL-based MCP clients (Claude Code, custom integrations) can now connect directly to \(endpointURL)."
        statusIsError = false
    }

    // MARK: - Install to Claude Desktop (clipboard + open file)

    /// Copies the stdio config snippet to the clipboard, opens the Claude
    /// Desktop config file in the default editor, and gives the user
    /// instructions. This sidesteps the sandbox-write-block on the user's
    /// non-container Application Support directory.
    func installToClaudeDesktop() {
        // 1. Pre-flight checks the user needs to act on.
        guard proxyAvailable else {
            status = "AstroBlinkMCPProxy helper not found in the .app bundle. Rebuild the app from Xcode."
            statusIsError = true
            return
        }

        // 2. Copy snippet to clipboard.
        let snippet = stdioConfigSnippet
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)

        // 3. Open the Claude config file (or its parent folder if file doesn't exist).
        let cfgURL = URL(fileURLWithPath: claudeConfigPath)
        let fm = FileManager.default

        if fm.fileExists(atPath: claudeConfigPath) {
            NSWorkspace.shared.open(cfgURL)
            status = "Snippet copied to clipboard. The Claude config file just opened — replace its contents (or merge under \"mcpServers\") with the clipboard contents, save (⌘S), then quit and re-open Claude Desktop."
        } else {
            let cfgDir = cfgURL.deletingLastPathComponent()
            // Open the directory in Finder so the user can create the file themselves.
            // (Sandbox blocks us from creating it on their behalf.)
            NSWorkspace.shared.open(cfgDir)
            status = "Snippet copied to clipboard. Claude Desktop hasn't created its config file yet — the folder just opened in Finder. Create \"claude_desktop_config.json\" there (right-click → New File), paste the snippet, save, then quit/restart Claude Desktop."
        }
        statusIsError = false
    }

    func copyStdioSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stdioConfigSnippet, forType: .string)
        status = "Stdio config snippet copied to clipboard."
        statusIsError = false
    }

    func copyURLSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlConfigSnippet, forType: .string)
        status = "URL config snippet copied to clipboard."
        statusIsError = false
    }

    func revealConfig() {
        let url = URL(fileURLWithPath: claudeConfigPath)
        if FileManager.default.fileExists(atPath: claudeConfigPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func revealProxy() {
        guard proxyAvailable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: proxyBinaryPath)])
    }

    func testEndpoint() {
        guard let url = MCPHTTPServer.shared.endpointURL else {
            status = "Server is not running yet."
            statusIsError = true
            return
        }
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
                    let preview = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
                    status = "HTTP \(code) — \(preview)"
                    statusIsError = code >= 500
                }
            } catch {
                await MainActor.run {
                    status = "Connection failed: \(error.localizedDescription) (cert may not be installed yet)"
                    statusIsError = true
                }
            }
        }
    }
}

// MARK: - View

struct MCPConnectorView: View {
    @ObservedObject var model: MCPConnectorModel
    let nightMode: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                preflight
                Divider()
                claudeDesktopSection
                Divider()
                urlClientSection
                if !model.status.isEmpty { statusBox }
            }
            .padding()
        }
        .background(AppColors.bg(nightMode))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect AstroBlink to Claude")
                .font(.title3).fontWeight(.semibold)
            Text("AstroBlink runs an HTTPS MCP server inside the app on \(model.endpointURL). For Claude Desktop, a tiny bundled proxy bridges its stdio MCP protocol to that URL. For Claude Code or other URL-aware MCP clients, you can also connect directly.")
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 6) {
            preflightRow(ok: model.serverReady,
                         okText: "MCP server is running at \(model.endpointURL)",
                         badText: "MCP server is not yet bound — give it a moment.")
            preflightRow(ok: model.proxyAvailable,
                         okText: "stdio proxy is bundled at Contents/Helpers/AstroBlinkMCPProxy",
                         badText: "stdio proxy is missing from the .app bundle — rebuild the app from Xcode.")
            preflightRow(ok: model.claudeInstalled,
                         okText: "Claude Desktop is installed (optional — Claude Code also works)",
                         badText: "Claude Desktop is not installed. Download from claude.ai/download, or use Claude Code instead.")
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

    private var claudeDesktopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Desktop").font(.headline)
            Text("Claude Desktop only accepts stdio MCP servers in its config file. The bundled proxy bridges stdio → our HTTPS endpoint.")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button {
                    model.installToClaudeDesktop()
                } label: {
                    Label("Install to Claude Desktop", systemImage: "wand.and.stars")
                }
                .controlSize(.large)
                .disabled(!model.serverReady || !model.proxyAvailable)

                Button {
                    model.copyStdioSnippet()
                } label: {
                    Label("Copy Snippet", systemImage: "doc.on.clipboard")
                }
                Button {
                    model.revealProxy()
                } label: {
                    Label("Reveal Proxy", systemImage: "magnifyingglass")
                }
                .disabled(!model.proxyAvailable)
            }
            Text("Click \"Install to Claude Desktop\". The snippet goes to your clipboard and the Claude config file opens in your default editor. Paste, save (⌘S), then quit and re-open Claude Desktop.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.stdioConfigSnippet)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var urlClientSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("URL-aware MCP clients (Claude Code, custom integrations)").font(.headline)
            Text("If your MCP client accepts URL endpoints directly, point it at the in-app HTTPS server. You'll need to trust the self-signed TLS cert once.")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button {
                    model.installCertificate()
                } label: {
                    Label(model.certificateTrusted ? "Certificate Trusted ✓" : "Install Certificate",
                          systemImage: "lock.shield")
                }
                .disabled(model.certificateTrusted || !model.serverReady)

                Button {
                    model.copyURLSnippet()
                } label: {
                    Label("Copy URL Config", systemImage: "doc.on.clipboard")
                }

                Button {
                    model.testEndpoint()
                } label: {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!model.serverReady || !model.certificateTrusted)

                Button {
                    model.revealConfig()
                } label: {
                    Label("Show Claude Config", systemImage: "doc.text.magnifyingglass")
                }
            }
            Text(model.urlConfigSnippet)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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

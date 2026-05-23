// "MCP Connector" — one-click install of the bundled AstroBlinkMCPServer into
// Claude Desktop's config file. Reads the current bundled-helper path from
// Bundle.main so it works whether the .app lives in /Applications/, Xcode's
// DerivedData, or anywhere else.
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

    let helperPath: String
    let claudeConfigPath: String
    let configSnippet: String

    init() {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/AstroBlinkMCPServer", isDirectory: false)
            .path
        self.helperPath = bundled

        let cfg = (NSString(string: "~/Library/Application Support/Claude/claude_desktop_config.json")
            .expandingTildeInPath)
        self.claudeConfigPath = cfg

        let escaped = bundled.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
        self.configSnippet = """
        {
          "mcpServers": {
            "astroblink": {
              "command": "\(escaped)"
            }
          }
        }
        """
    }

    var helperExists: Bool {
        FileManager.default.fileExists(atPath: helperPath)
    }

    var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: (NSString(string: "~/Applications/Claude.app").expandingTildeInPath))
    }

    func installToClaudeDesktop() {
        let fm = FileManager.default
        let cfgURL = URL(fileURLWithPath: claudeConfigPath)
        let cfgDir = cfgURL.deletingLastPathComponent()

        do {
            try fm.createDirectory(at: cfgDir, withIntermediateDirectories: true)

            // Load existing or start fresh.
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: cfgURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
                // Backup with timestamp.
                let stamp = DateFormatter.backupStamp.string(from: Date())
                let backupURL = cfgURL.appendingPathExtension("bak.\(stamp)")
                try? data.write(to: backupURL)
            }

            // Merge mcpServers.astroblink.
            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            servers["astroblink"] = ["command": helperPath]
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

    func revealHelper() {
        let url = URL(fileURLWithPath: helperPath)
        if FileManager.default.fileExists(atPath: helperPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            status = "Helper binary not found at \(helperPath). Re-build the app to embed it."
            statusIsError = true
        }
    }

    func copySnippet() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(configSnippet, forType: .string)
        status = "Snippet copied to clipboard."
        statusIsError = false
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
            Text("Connect AstroBlink to Claude Desktop")
                .font(.title3)
                .fontWeight(.semibold)
            Text("This installs the bundled AstroBlinkMCPServer helper into Claude Desktop's MCP configuration. Once installed, you can ask Claude things like “Which setups do I have?” or “Verarbeite die Aufnahmen der letzten Nacht vom RC12” and Claude will call back into AstroBlink to get the answer.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 6) {
            preflightRow(ok: model.helperExists,
                         okText: "Helper binary embedded in this app bundle",
                         badText: "Helper binary not found — re-build the app once.")
            preflightRow(ok: model.claudeInstalled,
                         okText: "Claude Desktop is installed",
                         badText: "Claude Desktop is not installed. Download from claude.ai/download — the connector only works with the desktop app, not the web version.")
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
            Text("One-click install")
                .font(.headline)
            HStack(spacing: 10) {
                Button {
                    model.installToClaudeDesktop()
                } label: {
                    Label("Install to Claude Desktop", systemImage: "wand.and.stars")
                }
                .controlSize(.large)
                .disabled(!model.helperExists)

                Button {
                    model.revealConfig()
                } label: {
                    Label("Show Config in Finder", systemImage: "doc.text.magnifyingglass")
                }
            }
            Text("Existing entries in the config are preserved. A timestamped .bak file is written next to the config before any change.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or paste this manually")
                .font(.headline)
            Text("If you maintain your Claude config yourself, copy the snippet below and merge it under \"mcpServers\".")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(model.configSnippet)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button("Copy Snippet") { model.copySnippet() }
                Button("Reveal Helper Binary…") { model.revealHelper() }
            }
        }
    }

    private var statusBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.statusIsError ? "xmark.octagon.fill" : "info.circle.fill")
                .foregroundColor(model.statusIsError ? .red : .accentColor)
            Text(model.status)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(6)
    }
}

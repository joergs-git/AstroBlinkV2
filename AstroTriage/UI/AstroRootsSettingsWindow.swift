// "Astrofile Locations" — user-configured default folders that the MCP server
// can resolve by tag (e.g. "RC12") to drive headless scans. List of roots with
// per-row inline edit of nickname + setup tag.
//
// Follows the pattern of TargetDatabaseWindowController: singleton @MainActor
// controller, opened via NotificationCenter from the Window menu.
import SwiftUI
import AppKit

@MainActor
class AstroRootsSettingsWindowController {
    static let shared = AstroRootsSettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let nightMode = AppSettings.loadBool(for: .nightMode) == true
        let model = AstroRootsSettingsModel()

        let rootView = AstroRootsSettingsView(model: model, nightMode: nightMode)
            .environment(\.fontScale, savedScale)
        let hostingView = NSHostingView(rootView: rootView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Astrofile Locations"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 360)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Model

@MainActor
final class AstroRootsSettingsModel: ObservableObject {
    @Published var roots: [AstroRoot] = []

    init() {
        reload()
    }

    func reload() {
        roots = AstroRootStore.shared.allRoots()
    }

    func addRoot() {
        if AstroRootStore.shared.addRoot() != nil {
            reload()
        }
    }

    func delete(_ root: AstroRoot) {
        guard let id = root.id else { return }
        AstroRootStore.shared.delete(id: id)
        reload()
    }

    func update(_ root: AstroRoot) {
        AstroRootStore.shared.update(root)
        // Don't reload — would clobber in-progress text-field edits in sibling rows.
    }
}

// MARK: - View

struct AstroRootsSettingsView: View {
    @ObservedObject var model: AstroRootsSettingsModel
    let nightMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.roots.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.roots) { root in
                        AstroRootRow(root: root, onUpdate: model.update, onDelete: { model.delete(root) })
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            footer
        }
        .background(AppColors.bg(nightMode))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default Astrofile Folders")
                .font(.headline)
            Text("Folders listed here can be referenced by name when driving AstroBlink from an external tool (e.g. via the MCP server: \"scan the RC12 folder\"). Adding a folder also persists a security-scoped bookmark so the sandboxed app can re-access it across launches.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No folders configured yet.")
                .foregroundColor(.secondary)
            Button("Add Folder…") {
                model.addRoot()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                model.addRoot()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            Spacer()
            Text("\(model.roots.count) folder\(model.roots.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Row

private struct AstroRootRow: View {
    let root: AstroRoot
    let onUpdate: (AstroRoot) -> Void
    let onDelete: () -> Void

    @State private var nickname: String = ""
    @State private var setupTag: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                    Text(root.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    TextField("Nickname (optional)", text: $nickname, onCommit: commitNickname)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    TextField("Setup Tag (e.g. RC12)", text: $setupTag, onCommit: commitSetupTag)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }

                if let last = root.lastUsedAt {
                    Text("Last used: \(last)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .onAppear {
            nickname = root.nickname ?? ""
            setupTag = root.setupTag ?? ""
        }
    }

    private func commitNickname() {
        var copy = root
        copy.nickname = nickname.isEmpty ? nil : nickname
        onUpdate(copy)
    }

    private func commitSetupTag() {
        var copy = root
        copy.setupTag = setupTag.isEmpty ? nil : setupTag
        onUpdate(copy)
    }
}

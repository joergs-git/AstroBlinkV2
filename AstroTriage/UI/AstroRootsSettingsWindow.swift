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
            // Hard-cap the SwiftUI proposal so NSHostingView can't compute a
            // tall+narrow intrinsic size from long unbreakable strings (was
            // the root cause of "window goes off-screen, all white").
            .frame(width: 620, height: 480)

        // NSHostingController owns the SwiftUI lifecycle and reports a sane
        // preferredContentSize to AppKit. Plain NSHostingView + setContentSize
        // is racey: the first layout pass picks up SwiftUI's intrinsic size
        // before our setContentSize call, and the window snaps to that.
        let controller = NSHostingController(rootView: rootView)
        controller.preferredContentSize = NSSize(width: 620, height: 480)

        let win = NSWindow(contentViewController: controller)
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.title = "Astrofile Locations"
        win.isRestorable = false
        win.setContentSize(NSSize(width: 620, height: 480))
        win.minSize = NSSize(width: 540, height: 380)
        win.center()
        win.isReleasedWhenClosed = false
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
        VStack(alignment: .leading, spacing: 0) {
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
            Text("Astrofile Locations").font(.title3).fontWeight(.semibold)
            Text("These are tag→path shortcuts for the MCP server, **not** where AstroBlink learns about your data. Tag a NAS or local folder here (e.g. \"RC12\" → /Volumes/NAS/RC12), then say things like \"scan the RC12 folder from last night\" to Claude — instead of typing the full path.")
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("To open a single session for triage, use Cmd+O. To bulk-import an existing archive, use Window → Frame History → Scan Archive. Neither needs anything configured here.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private var emptyState: some View {
        // Bounded height (no maxHeight: .infinity) so the window doesn't
        // look giant-and-blank on first open — the empty state sits right
        // under the header instead of being centered in a sea of space.
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundColor(.accentColor.opacity(0.7))
            Text("No folders tagged yet").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add the root folder of one or more of your astro setups. Each gets a setup tag (e.g. \"RC12\", \"RASA\") and an optional nickname.")
                Text("Example: register \"/Volumes/NAS/Astro/RC12_imaging\" with tag **RC12**. Then in Claude you can ask \"verarbeite die Aufnahmen der letzten Nacht vom RC12\" and AstroBlink resolves the tag automatically.")
            }
            .font(.callout).foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32)
            Button {
                model.addRoot()
            } label: {
                Label("Add Your First Folder…", systemImage: "plus.circle.fill")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
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

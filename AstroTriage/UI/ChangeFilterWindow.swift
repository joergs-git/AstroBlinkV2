// Change Filter — dedicated, footgun-free filter rename window.
// Sets ONLY the FITS/XISF FILTER keyword (exact value) and renames ONLY the parsed filter
// token in the filename. The rest of the name can never be touched. Mandatory backup,
// read-back verification, per-file restore-on-failure, and undo (shared with batch rename).

import SwiftUI

// MARK: - View Modifier (opens the window on the menu notification)

// Kept as a standalone modifier with its own type-check budget so it doesn't bloat the
// already-large ContentView modifier chains (which hit the SwiftUI type-checker limit).
struct ChangeFilterModifier: ViewModifier {
    @ObservedObject var viewModel: TriageViewModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .changeFilterRequest)) { _ in
            ChangeFilterWindowController.shared.show(viewModel: viewModel)
        }
    }
}

// MARK: - Window Controller

class ChangeFilterWindowController {
    static let shared = ChangeFilterWindowController()
    private var window: NSWindow?

    func show(viewModel: TriageViewModel) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let view = ChangeFilterView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Change Filter"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 620, height: 420)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Main View

struct ChangeFilterView: View {
    @ObservedObject var viewModel: TriageViewModel

    @State private var newFilter: String = ""
    @State private var oldFilter: String = ""        // optional guard
    @State private var previewItems: [BatchPreviewItem] = []
    @State private var hasPreview: Bool = false
    @State private var isExecuting: Bool = false
    @State private var resultMessage: String = ""
    @State private var showResult: Bool = false

    /// Files to operate on: the highlighted rows in the file list (never the pre-delete marks).
    private var targetEntries: [ImageEntry] {
        viewModel.selectedEntries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Explanation
            Text("Sets the FITS/XISF FILTER keyword and renames the filter token in the filename — "
                 + "e.g. Lextr → L. Nothing else in the name is touched. A full backup is made before "
                 + "any change, every write is verified, and the operation is undoable.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Inputs
            HStack(spacing: 16) {
                HStack {
                    Text("New filter:")
                    TextField("e.g. L", text: $newFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                HStack {
                    Text("Only change current:")
                    TextField("optional, e.g. Lextr", text: $oldFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                Spacer()
            }
            Text("Leave \u{201C}Only change current\u{201D} empty to set every highlighted file to the new filter. "
                 + "Fill it in to safely touch only files currently on that filter (handy for mixed selections).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Action row
            HStack {
                Button("Preview Changes") { generatePreview() }
                    .disabled(newFilter.trimmingCharacters(in: .whitespaces).isEmpty)

                if hasPreview {
                    let affected = previewItems.filter(\.willChange).count
                    Text("Affects \(affected) of \(targetEntries.count) selected file(s)")
                        .foregroundColor(.secondary)
                }

                Spacer()

                if viewModel.canUndoBatch {
                    Button("Undo Last Change") {
                        viewModel.undoBatchRename()
                        hasPreview = false
                        resultMessage = viewModel.statusMessage
                        showResult = true
                    }
                }

                if hasPreview {
                    Button("Apply Changes") { executeChanges() }
                        .disabled(previewItems.filter(\.willChange).isEmpty || isExecuting)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }

            Divider()

            // Preview list
            if hasPreview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            Text("Original").frame(maxWidth: .infinity, alignment: .leading).font(.caption.bold())
                            Text("New").frame(maxWidth: .infinity, alignment: .leading).font(.caption.bold())
                        }
                        .padding(.horizontal, 4)
                        .background(Color.gray.opacity(0.1))

                        ForEach(previewItems.filter(\.willChange)) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                if let newName = item.newFilename {
                                    HStack(spacing: 0) {
                                        Text(item.originalFilename)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.red).lineLimit(1).truncationMode(.middle)
                                        Text(newName)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.green).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                ForEach(Array(item.headerChanges.enumerated()), id: \.offset) { _, change in
                                    HStack(spacing: 0) {
                                        Text("\(change.key): \(change.oldValue)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.orange).lineLimit(1)
                                        Text("\(change.key): \(change.newValue)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.cyan).lineLimit(1)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            Divider()
                        }
                    }
                }
                .border(Color.gray.opacity(0.3))
            } else {
                Spacer()
                Text("Highlight files in the list, enter a new filter, then Preview.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }

            if isExecuting {
                ProgressView("Applying changes...").progressViewStyle(.linear)
            }
            if showResult {
                Text(resultMessage)
                    .font(.callout)
                    .foregroundColor(resultMessage.localizedCaseInsensitiveContains("fail")
                                     || resultMessage.localizedCaseInsensitiveContains("error") ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 420)
    }

    // MARK: - Actions

    private func buildSpec() -> ChangeFilterSpec {
        let trimmedOld = oldFilter.trimmingCharacters(in: .whitespaces)
        return ChangeFilterSpec(
            newFilter: newFilter.trimmingCharacters(in: .whitespaces),
            oldFilter: trimmedOld.isEmpty ? nil : trimmedOld
        )
    }

    private func generatePreview() {
        let entries = targetEntries
        guard !entries.isEmpty else {
            resultMessage = "No files selected. Highlight files in the file list first."
            showResult = true
            return
        }
        previewItems = BatchOperations.previewChangeFilter(spec: buildSpec(), entries: entries)
        hasPreview = true
        showResult = false
    }

    private func executeChanges() {
        let entries = targetEntries
        guard !entries.isEmpty else {
            resultMessage = "No files selected. Highlight files in the file list first."
            showResult = true
            return
        }
        // Resolve a WRITABLE, security-scoped root (may prompt for folder access on NAS /
        // external volumes where the reconstructed session root carries no write scope).
        guard let sessionRoot = viewModel.ensureWritableSessionRoot() else {
            resultMessage = "Error: no writable session folder — folder access not granted"
            showResult = true
            return
        }
        let spec = buildSpec()
        let newFilterValue = spec.newFilter
        isExecuting = true
        showResult = false

        DispatchQueue.global(qos: .userInitiated).async {
            let result = BatchOperations.executeChangeFilter(spec: spec, entries: entries, sessionRoot: sessionRoot)
            DispatchQueue.main.async {
                isExecuting = false
                viewModel.applyChangeFilterResult(result, newFilter: newFilterValue)

                if result.failed.isEmpty {
                    resultMessage = "\(result.succeeded) file(s) changed to \(newFilterValue). "
                        + "Backup in \(result.backupDirectory.lastPathComponent)"
                } else {
                    resultMessage = "\(result.succeeded) succeeded, \(result.failed.count) failed. "
                        + "First error: \(result.failed.first?.error ?? "")"
                }
                showResult = true
                hasPreview = false
            }
        }
    }
}

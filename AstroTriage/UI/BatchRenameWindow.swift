// v3.11.0 — Batch Rename & Header Edit window
// Floating NSWindow with SwiftUI content for batch file/header modifications.
// Safety: mandatory preview before apply, full backup, verification after write.

import SwiftUI

// MARK: - Window Controller

class BatchRenameWindowController {
    static let shared = BatchRenameWindowController()
    private var window: NSWindow?

    func show(viewModel: TriageViewModel) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let view = BatchRenameView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Batch Rename & Header Edit"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 650, height: 450)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Scope Selection

enum BatchScopeSelection: String, CaseIterable {
    case filenameOnly = "Filename"
    case headerOnly = "Header"
    case both = "Both"
}

// MARK: - Main View

struct BatchRenameView: View {
    @ObservedObject var viewModel: TriageViewModel

    @State private var scopeSelection: BatchScopeSelection = .filenameOnly
    @State private var headerKeyword: String = "FILTER"
    @State private var searchText: String = ""
    @State private var replaceText: String = ""
    @State private var useRegex: Bool = false
    @State private var previewItems: [BatchPreviewItem] = []
    @State private var hasPreview: Bool = false
    @State private var isExecuting: Bool = false
    @State private var resultMessage: String = ""
    @State private var showResult: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Scope selector
            HStack {
                Text("Scope:")
                    .font(.headline)
                Picker("", selection: $scopeSelection) {
                    ForEach(BatchScopeSelection.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
            }

            // Header keyword field (visible for header/both scope)
            if scopeSelection != .filenameOnly {
                HStack {
                    Text("Header keyword:")
                    TextField("e.g. FILTER", text: $headerKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Spacer()
                }
            }

            // Search & Replace
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Search:")
                            .frame(width: 60, alignment: .trailing)
                        TextField("Pattern to find", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Replace:")
                            .frame(width: 60, alignment: .trailing)
                        TextField("Replacement", text: $replaceText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Toggle("Regex", isOn: $useRegex)
                    .toggleStyle(.checkbox)
                    .padding(.leading, 8)
            }

            // Preview button
            HStack {
                Button("Preview Changes") {
                    generatePreview()
                }
                .disabled(searchText.isEmpty)

                if hasPreview {
                    let affected = previewItems.filter(\.willChange).count
                    let total = previewItems.count
                    Text("Affects \(affected) of \(total) files")
                        .foregroundColor(.secondary)
                }

                Spacer()

                if hasPreview {
                    Button("Apply Changes") {
                        executeChanges()
                    }
                    .disabled(previewItems.filter(\.willChange).isEmpty || isExecuting)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }

            Divider()

            // Preview table
            if hasPreview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Header row
                        HStack(spacing: 0) {
                            Text("#")
                                .frame(width: 40, alignment: .center)
                                .font(.caption.bold())
                            Text("Original")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.caption.bold())
                            Text("New")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 4)
                        .background(Color.gray.opacity(0.1))

                        ForEach(previewItems.filter(\.willChange)) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                // Filename change
                                if let newName = item.newFilename {
                                    HStack(spacing: 0) {
                                        Text("\(item.entry.frameNumber.map { String($0) } ?? "—")")
                                            .frame(width: 40, alignment: .center)
                                            .font(.caption)
                                        Text(item.originalFilename)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.red)
                                            .lineLimit(1)
                                        Text(newName)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.green)
                                            .lineLimit(1)
                                    }
                                }

                                // Header changes
                                ForEach(Array(item.headerChanges.enumerated()), id: \.offset) { _, change in
                                    HStack(spacing: 0) {
                                        Text("")
                                            .frame(width: 40)
                                        Text("\(change.key): \(change.oldValue)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.orange)
                                            .lineLimit(1)
                                        Text("\(change.key): \(change.newValue)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.cyan)
                                            .lineLimit(1)
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
                Text("Enter a search pattern and click Preview to see changes")
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Progress / result
            if isExecuting {
                ProgressView("Applying changes...")
                    .progressViewStyle(.linear)
            }
            if showResult {
                Text(resultMessage)
                    .font(.callout)
                    .foregroundColor(resultMessage.contains("Error") ? .red : .green)
                    .padding(4)
            }
        }
        .padding()
        .frame(minWidth: 650, minHeight: 450)
    }

    // MARK: - Actions

    private func generatePreview() {
        let spec = buildSpec()
        previewItems = BatchOperations.preview(spec: spec, entries: viewModel.images)
        hasPreview = true
        showResult = false
    }

    private func executeChanges() {
        let spec = buildSpec()
        isExecuting = true
        showResult = false

        guard let sessionRoot = viewModel.sessionRootURL else {
            resultMessage = "Error: No session folder open"
            showResult = true
            isExecuting = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = BatchOperations.execute(spec: spec, entries: viewModel.images, sessionRoot: sessionRoot)

            DispatchQueue.main.async {
                isExecuting = false

                // Mark affected entries as batch-modified
                viewModel.applyBatchResult(result)

                if result.failed.isEmpty {
                    resultMessage = "\(result.succeeded) files modified successfully. Backup in \(result.backupDirectory.lastPathComponent)"
                } else {
                    resultMessage = "\(result.succeeded) succeeded, \(result.failed.count) failed. First error: \(result.failed.first?.error ?? "")"
                }
                showResult = true
                hasPreview = false
            }
        }
    }

    private func buildSpec() -> BatchRenameSpec {
        let scope: BatchScope
        switch scopeSelection {
        case .filenameOnly:
            scope = .filenameOnly
        case .headerOnly:
            scope = .headerOnly(keyword: headerKeyword)
        case .both:
            scope = .both(keyword: headerKeyword)
        }
        return BatchRenameSpec(
            searchPattern: searchText,
            replacement: replaceText,
            isRegex: useRegex,
            scope: scope
        )
    }
}

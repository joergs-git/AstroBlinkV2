// v3.2.0
import SwiftUI
import AppKit

// Floating window showing all FITS/XISF header keywords for the current image.
// Updates automatically when navigating between images.
// Important keywords (EXPOSURE, FILTER, GAIN, etc.) are highlighted in red and shown on top.
// Toggle with 'I' key.

// Keywords to highlight in the inspector (case-insensitive match)
private let highlightedKeywords: Set<String> = [
    "INSTRUME",
    "EXPOSURE", "EXPTIME", "FILTER", "GAIN", "OFFSET",
    "FOCUSPOS", "FOCPOS", "FOCTEMP",
    "CCD-TEMP", "SET-TEMP",
    "OBJECT", "IMAGETYP",
    "BAYERPAT", "XBINNING", "YBINNING",
]

// MARK: - Window Controller (singleton, reusable)

class HeaderInspectorController: NSWindowController {
    static let shared = HeaderInspectorController()

    private let inspectorModel = HeaderInspectorModel()

    init() {
        // Use up to 80% of screen height, minimum 500
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let windowH = min(screenH * 0.8, max(500, screenH * 0.7))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: windowH),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Header Inspector"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.titlebarAppearsTransparent = false

        // Position near the right edge of the main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 460
            let y = screenFrame.maxY - windowH - 40
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        super.init(window: window)

        let hostingView = NSHostingView(rootView: HeaderInspectorContentView(model: inspectorModel))
        window.contentView = hostingView

        // Float above AstroBlinkV2 windows only — drop to normal when app loses focus
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        window?.level = .floating
    }

    @objc private func appDidResignActive() {
        window?.level = .normal
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // Update displayed headers for a new image
    func updateHeaders(for url: URL, filename: String) {
        inspectorModel.filename = filename
        inspectorModel.isLoading = true

        let targetURL = url
        Task.detached(priority: .userInitiated) {
            let headers = MetadataExtractor.readHeaders(from: targetURL)

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // Sort: highlighted keywords first, then alphabetical
                let entries = headers
                    .map { HeaderEntry(key: $0.key, value: $0.value) }
                    .sorted { a, b in
                        if a.isHighlighted != b.isHighlighted {
                            return a.isHighlighted
                        }
                        return a.key < b.key
                    }
                self.inspectorModel.headers = entries
                self.inspectorModel.isLoading = false
            }
        }
    }

    func toggle() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            showWindow(nil)
        }
    }
}

// MARK: - Data Model

struct HeaderEntry: Identifiable {
    let id = UUID()
    let key: String
    let value: String

    var isHighlighted: Bool {
        highlightedKeywords.contains(key.uppercased())
    }
}

class HeaderInspectorModel: ObservableObject {
    @Published var headers: [HeaderEntry] = []
    @Published var filename: String = ""
    @Published var isLoading: Bool = false
    @Published var searchText: String = ""

    var filteredHeaders: [HeaderEntry] {
        if searchText.isEmpty { return headers }
        let query = searchText.lowercased()
        return headers.filter {
            $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
        }
    }

    // Update headers for a new image (can be called directly without the window controller)
    func update(for url: URL, filename: String) {
        self.filename = filename
        self.isLoading = true
        let targetURL = url
        Task.detached(priority: .userInitiated) { [weak self] in
            let headers = MetadataExtractor.readHeaders(from: targetURL)
            await MainActor.run {
                guard let self = self else { return }
                let entries = headers
                    .map { HeaderEntry(key: $0.key, value: $0.value) }
                    .sorted { a, b in
                        if a.isHighlighted != b.isHighlighted { return a.isHighlighted }
                        return a.key < b.key
                    }
                self.headers = entries
                self.isLoading = false
            }
        }
    }
}

// MARK: - NSScrollView wrapper that preserves scroll position across data updates
// AppKit's NSScrollView keeps its contentOffset when the content changes,
// unlike SwiftUI's ScrollView which resets on every @Published change.

struct HeaderScrollView: NSViewRepresentable {
    let entries: [HeaderEntry]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false

        let keyCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyCol.width = 120
        keyCol.minWidth = 80
        keyCol.maxWidth = 160
        tableView.addTableColumn(keyCol)

        let valCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valCol.width = 280
        valCol.minWidth = 100
        tableView.addTableColumn(valCol)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Save scroll position before reload
        let savedOffset = scrollView.contentView.bounds.origin

        context.coordinator.entries = entries
        context.coordinator.tableView?.reloadData()

        // Restore scroll position after reload (AppKit preserves this naturally,
        // but explicit restore handles edge cases with content size changes)
        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: savedOffset)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var entries: [HeaderEntry] = []
        weak var tableView: NSTableView?

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < entries.count else { return nil }
            let entry = entries[row]
            let isImportant = entry.isHighlighted
            let isEven = row % 2 == 0

            let cell = NSTextField(labelWithString: "")
            cell.font = NSFont.monospacedSystemFont(ofSize: 13, weight: isImportant ? .semibold : .regular)
            cell.drawsBackground = true
            cell.isSelectable = true
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1

            if tableColumn?.identifier.rawValue == "key" {
                cell.stringValue = entry.key
                cell.alignment = .right
                cell.textColor = isImportant ? .systemRed : .controlAccentColor
                cell.backgroundColor = isImportant ? NSColor.systemRed.withAlphaComponent(0.06) : (isEven ? .clear : NSColor.controlBackgroundColor.withAlphaComponent(0.3))
            } else {
                cell.stringValue = entry.value
                cell.alignment = .left
                cell.textColor = isImportant ? .systemRed : .labelColor
                cell.backgroundColor = isImportant ? NSColor.systemRed.withAlphaComponent(0.06) : (isEven ? .clear : NSColor.controlBackgroundColor.withAlphaComponent(0.3))
                cell.maximumNumberOfLines = 2
                cell.lineBreakMode = .byWordWrapping
            }

            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            24
        }
    }
}

// MARK: - SwiftUI View

struct HeaderInspectorContentView: View {
    @ObservedObject var model: HeaderInspectorModel

    var body: some View {
        VStack(spacing: 0) {
            // Filename header
            HStack {
                Text(model.filename)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(model.headers.count) keywords")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))

                TextField("Filter keywords...", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))

                if !model.searchText.isEmpty {
                    Button(action: { model.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            // Header list — uses AppKit NSScrollView to preserve scroll position.
            // Always mounted (never conditionally removed) so scroll position persists
            // across image navigation. Loading/empty states overlay on top.
            ZStack {
                HeaderScrollView(entries: model.filteredHeaders)

                if model.isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Reading headers...")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                } else if model.filteredHeaders.isEmpty {
                    VStack {
                        Spacer()
                        Text(model.searchText.isEmpty ? "No headers found" : "No matching keywords")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                }
            }
        }
    }
}

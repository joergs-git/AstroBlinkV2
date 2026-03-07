// v0.9.4
import SwiftUI
import AppKit

// Floating window showing all FITS/XISF header keywords for the current image.
// Updates automatically when navigating between images.
// Important keywords (EXPOSURE, FILTER, GAIN, etc.) are highlighted in red and shown on top.
// Toggle with 'I' key.

// Keywords to highlight in the inspector (case-insensitive match)
private let highlightedKeywords: Set<String> = [
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

            // Header list
            if model.isLoading {
                Spacer()
                ProgressView("Reading headers...")
                    .font(.system(size: 13))
                Spacer()
            } else if model.filteredHeaders.isEmpty {
                Spacer()
                Text(model.searchText.isEmpty ? "No headers found" : "No matching keywords")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredHeaders) { entry in
                            headerRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func headerRow(_ entry: HeaderEntry) -> some View {
        let isImportant = entry.isHighlighted

        return HStack(alignment: .top, spacing: 8) {
            // Keyword name
            Text(entry.key)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(isImportant ? .red : .accentColor)
                .frame(width: 120, alignment: .trailing)
                .lineLimit(1)

            // Value
            Text(entry.value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(isImportant ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(
            isImportant
                ? Color.red.opacity(0.06)
                : Color(NSColor.controlBackgroundColor).opacity(
                    model.filteredHeaders.firstIndex(where: { $0.id == entry.id })?.isMultiple(of: 2) == true ? 0.0 : 0.3
                )
        )
    }
}

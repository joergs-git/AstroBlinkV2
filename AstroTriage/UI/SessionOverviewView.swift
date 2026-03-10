// v3.3.0
import SwiftUI
import AppKit

// Floating window: per-object/filter/exposure session statistics + fact sheet generator
// Groups by (Object, Filter, Exposure) so H 30s and H 60s appear as separate lines

class SessionOverviewController: NSWindowController {
    static let shared = SessionOverviewController()

    let overviewModel = SessionOverviewModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 750),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Session Overview"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 400, height: 240)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.minX + 20
            let y = screenFrame.midY - 170
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        super.init(window: window)

        let hostingView = NSHostingView(rootView: SessionOverviewContentView(model: overviewModel))
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

    // Toggle visibility — re-opens if closed
    func toggleWindow() {
        if let w = window, w.isVisible {
            w.orderOut(nil)
        } else {
            showWindow(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func updateStats(from images: [ImageEntry]) {
        struct GroupKey: Hashable {
            let object: String
            let filter: String
            let exposure: Double
        }

        var grouped: [GroupKey: Int] = [:]
        var totalExposure: Double = 0
        var totalCount = 0

        var sessionCamera: String?
        var sessionTelescope: String?
        var sessionMount: String?
        var sessionTemp: Double?
        var sessionGain: Int?
        var sessionOffset: Int?
        var sessionBinning: String?

        var allDateTimes: [String] = []

        for entry in images {
            let obj = entry.target ?? "unknown"
            let f = entry.filter ?? "none"
            let exp = entry.exposure ?? 0

            let key = GroupKey(object: obj, filter: f, exposure: exp)
            grouped[key, default: 0] += 1
            totalExposure += exp
            totalCount += 1

            if let dt = entry.dateTime { allDateTimes.append(dt) }

            if sessionCamera == nil { sessionCamera = entry.camera }
            if sessionTelescope == nil { sessionTelescope = entry.telescope }
            if sessionMount == nil { sessionMount = entry.mount }
            if sessionTemp == nil { sessionTemp = entry.sensorTemp }
            if sessionGain == nil { sessionGain = entry.gain }
            if sessionOffset == nil { sessionOffset = entry.offset }
            if sessionBinning == nil { sessionBinning = entry.binning }
        }

        allDateTimes.sort()

        let objects = Set(images.compactMap { $0.target }).sorted()

        let rows = grouped
            .sorted { a, b in
                if a.key.object != b.key.object { return a.key.object < b.key.object }
                if a.key.filter != b.key.filter { return a.key.filter < b.key.filter }
                return a.key.exposure < b.key.exposure
            }
            .map { (key, count) in
                FilterRow(
                    object: key.object,
                    filter: key.filter,
                    exposurePerShot: key.exposure,
                    shotCount: count,
                    totalSeconds: key.exposure * Double(count)
                )
            }

        overviewModel.rows = rows
        overviewModel.totalExposure = totalExposure
        overviewModel.totalShots = totalCount
        overviewModel.sessionObjects = objects.isEmpty ? nil : objects.joined(separator: ", ")
        overviewModel.firstAcquisition = allDateTimes.first
        overviewModel.lastAcquisition = allDateTimes.last
        overviewModel.sessionCamera = sessionCamera
        overviewModel.sessionTelescope = sessionTelescope
        overviewModel.sessionMount = sessionMount
        overviewModel.sessionTemp = sessionTemp
        overviewModel.sessionGain = sessionGain
        overviewModel.sessionOffset = sessionOffset
        overviewModel.sessionBinning = sessionBinning
    }
}

// MARK: - Data Model

struct FilterRow: Identifiable {
    let id = UUID()
    let object: String
    let filter: String
    let exposurePerShot: Double
    let shotCount: Int
    let totalSeconds: Double
}

// Quality statistics for a group of images (grouped by filter + date)
struct QualityRow: Identifiable {
    let id = UUID()
    let filter: String
    let date: String?          // nil = all dates combined, non-nil = specific night
    let count: Int             // Number of images with noise data
    let minNoise: Float        // Min normalizedMAD
    let maxNoise: Float        // Max normalizedMAD
    let avgNoise: Float        // Mean normalizedMAD
    let minBackground: Float   // Min median background
    let maxBackground: Float   // Max median background
    let avgBackground: Float   // Mean median background
    let avgSNR: Float          // Mean SNR (median / normalizedMAD)
}

class SessionOverviewModel: ObservableObject {
    @Published var rows: [FilterRow] = []
    @Published var totalExposure: Double = 0
    @Published var totalShots: Int = 0

    @Published var sessionObjects: String?
    @Published var firstAcquisition: String?
    @Published var lastAcquisition: String?
    @Published var sessionCamera: String?
    @Published var sessionTelescope: String?
    @Published var sessionMount: String?
    @Published var sessionTemp: Double?
    @Published var sessionGain: Int?
    @Published var sessionOffset: Int?

    // Update stats from image entries (can be called directly without window controller)
    func updateStats(from images: [ImageEntry]) {
        struct GroupKey: Hashable {
            let object: String
            let filter: String
            let exposure: Double
        }

        var grouped: [GroupKey: Int] = [:]
        var total: Double = 0
        var count = 0

        var camera: String?
        var telescope: String?
        var mount: String?
        var temp: Double?
        var gain: Int?
        var offset: Int?
        var binning: String?

        var allDateTimes: [String] = []

        for entry in images {
            let obj = entry.target ?? "unknown"
            let f = entry.filter ?? "none"
            let exp = entry.exposure ?? 0

            let key = GroupKey(object: obj, filter: f, exposure: exp)
            grouped[key, default: 0] += 1
            total += exp
            count += 1

            if let dt = entry.dateTime { allDateTimes.append(dt) }

            if camera == nil { camera = entry.camera }
            if telescope == nil { telescope = entry.telescope }
            if mount == nil { mount = entry.mount }
            if temp == nil { temp = entry.sensorTemp }
            if gain == nil { gain = entry.gain }
            if offset == nil { offset = entry.offset }
            if binning == nil { binning = entry.binning }
        }

        allDateTimes.sort()

        let objects = Set(images.compactMap { $0.target }).sorted()

        let newRows = grouped
            .sorted { a, b in
                if a.key.object != b.key.object { return a.key.object < b.key.object }
                if a.key.filter != b.key.filter { return a.key.filter < b.key.filter }
                return a.key.exposure < b.key.exposure
            }
            .map { (key, cnt) in
                FilterRow(
                    object: key.object,
                    filter: key.filter,
                    exposurePerShot: key.exposure,
                    shotCount: cnt,
                    totalSeconds: key.exposure * Double(cnt)
                )
            }

        rows = newRows
        totalExposure = total
        totalShots = count
        sessionObjects = objects.isEmpty ? nil : objects.joined(separator: ", ")
        firstAcquisition = allDateTimes.first
        lastAcquisition = allDateTimes.last
        sessionCamera = camera
        sessionTelescope = telescope
        sessionMount = mount
        sessionTemp = temp
        sessionGain = gain
        sessionOffset = offset
        sessionBinning = binning

        // Update quality stats (noise/SNR) from images that have been measured
        updateQualityStats(from: images)
    }
    @Published var sessionBinning: String?

    // Quality statistics grouped by filter (+ date for multi-night sessions)
    @Published var qualityRows: [QualityRow] = []

    // Compute quality statistics from images with noise data.
    // Groups by filter, and by date if multiple dates detected.
    func updateQualityStats(from images: [ImageEntry]) {
        // Only process images with noise measurements
        let withNoise = images.filter { $0.noiseMedian != nil && $0.noiseMAD != nil }
        guard !withNoise.isEmpty else {
            qualityRows = []
            return
        }

        struct GroupKey: Hashable {
            let filter: String
            let date: String?
        }

        // Check if we have multiple dates (multi-night session)
        let uniqueDates = Set(withNoise.compactMap { $0.date })
        let useDate = uniqueDates.count > 1

        var grouped: [GroupKey: [(median: Float, mad: Float)]] = [:]

        for entry in withNoise {
            guard let median = entry.noiseMedian, let mad = entry.noiseMAD else { continue }
            let filter = entry.filter ?? "none"
            let date = useDate ? entry.date : nil
            let key = GroupKey(filter: filter, date: date)
            grouped[key, default: []].append((median: median, mad: mad))
        }

        qualityRows = grouped
            .sorted { a, b in
                if a.key.filter != b.key.filter { return a.key.filter < b.key.filter }
                return (a.key.date ?? "") < (b.key.date ?? "")
            }
            .map { (key, values) in
                let noises = values.map { $0.mad }
                let backgrounds = values.map { $0.median }
                let snrs = values.compactMap { $0.mad > 0 ? $0.median / $0.mad : nil }

                return QualityRow(
                    filter: key.filter,
                    date: key.date,
                    count: values.count,
                    minNoise: noises.min() ?? 0,
                    maxNoise: noises.max() ?? 0,
                    avgNoise: noises.reduce(0, +) / Float(noises.count),
                    minBackground: backgrounds.min() ?? 0,
                    maxBackground: backgrounds.max() ?? 0,
                    avgBackground: backgrounds.reduce(0, +) / Float(backgrounds.count),
                    avgSNR: snrs.isEmpty ? 0 : snrs.reduce(0, +) / Float(snrs.count)
                )
            }
    }

    func generateFactSheet() -> String {
        var lines: [String] = []

        if let obj = sessionObjects, !obj.isEmpty {
            lines.append("Target: \(obj)")
        }
        if let first = firstAcquisition {
            lines.append("First acquisition: \(first)")
        }
        if let last = lastAcquisition {
            lines.append("Last acquisition: \(last)")
        }
        if let scope = sessionTelescope, !scope.isEmpty {
            lines.append("Telescope: \(scope)")
        }
        if let mount = sessionMount, !mount.isEmpty {
            lines.append("Mount: \(mount)")
        }
        if let cam = sessionCamera, !cam.isEmpty {
            lines.append("Camera: \(cam)")
        }
        if let temp = sessionTemp {
            lines.append("Sensor Temp: \(String(format: "%.1f", temp))°C")
        }
        if let gain = sessionGain {
            lines.append("Gain: \(gain)")
        }
        if let offset = sessionOffset {
            lines.append("Offset: \(offset)")
        }
        if let bin = sessionBinning, !bin.isEmpty {
            lines.append("Binning: \(bin)")
        }

        if !rows.isEmpty {
            lines.append("")
            lines.append("Integration:")

            let objects = Set(rows.map { $0.object }).sorted()
            var currentObject = ""
            for row in rows {
                if row.object != currentObject && objects.count > 1 {
                    if row.object != "unknown" {
                        lines.append("  \(row.object):")
                    }
                    currentObject = row.object
                }
                let expStr = formatExposure(row.exposurePerShot)
                let totalStr = formatHours(row.totalSeconds)
                let prefix = objects.count > 1 ? "    " : "  "
                let filterLabel = row.filter == "none" ? "(no filter)" : row.filter
                lines.append("\(prefix)\(filterLabel): \(row.shotCount) x \(expStr) = \(totalStr)")
            }
            lines.append("  Total: \(totalShots) subs, \(formatHours(totalExposure))")
        }

        // Hashtags for social media — strip all non-alphanumeric characters
        lines.append("")
        var hashtags: [String] = []
        if let obj = sessionObjects {
            for name in obj.components(separatedBy: ", ") where name != "unknown" {
                let tag = sanitizeHashtag(name)
                if !tag.isEmpty { hashtags.append("#\(tag)") }
            }
        }
        if let cam = sessionCamera, !cam.isEmpty {
            let tag = sanitizeHashtag(cam)
            if !tag.isEmpty { hashtags.append("#\(tag)") }
        }
        if let scope = sessionTelescope, !scope.isEmpty {
            let tag = sanitizeHashtag(scope)
            if !tag.isEmpty { hashtags.append("#\(tag)") }
        }
        if let mount = sessionMount, !mount.isEmpty {
            let tag = sanitizeHashtag(mount)
            if !tag.isEmpty { hashtags.append("#\(tag)") }
        }
        hashtags.append(contentsOf: [
            "#astrophotography", "#astronomy", "#space",
            "#deepsky", "#nightsky", "#astro"
        ])
        lines.append(hashtags.joined(separator: " "))

        return lines.joined(separator: "\n")
    }

    private func formatExposure(_ seconds: Double) -> String {
        if seconds == seconds.rounded() && seconds >= 1 {
            return String(format: "%.0fs", seconds)
        }
        return String(format: "%.1fs", seconds)
    }

    private func formatHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        if hours >= 1.0 {
            return String(format: "%.1fh", hours)
        } else {
            let minutes = seconds / 60.0
            return String(format: "%.0fm", minutes)
        }
    }

    // Strip everything except letters and numbers for clean hashtags
    private func sanitizeHashtag(_ input: String) -> String {
        return String(input.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

// MARK: - SwiftUI View

struct SessionOverviewContentView: View {
    @ObservedObject var model: SessionOverviewModel
    @State private var copied = false

    private var hasMultipleObjects: Bool {
        Set(model.rows.map { $0.object }).count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // TOP: Session stats + integration table
            VStack(spacing: 0) {
                // Session info header (compact)
                VStack(alignment: .leading, spacing: 2) {
                    if let obj = model.sessionObjects, !obj.isEmpty {
                        infoRow("Object:", obj)
                    }
                    if let scope = model.sessionTelescope, !scope.isEmpty {
                        infoRow("Scope:", scope)
                    }
                    if let cam = model.sessionCamera, !cam.isEmpty {
                        infoRow("Camera:", cam)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
                .textSelection(.enabled)

                Divider()

                if model.rows.isEmpty {
                    Text("No session loaded")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                } else {
                    // Column headers
                    HStack(spacing: 0) {
                        if hasMultipleObjects {
                            Text("Object")
                                .frame(minWidth: 50, alignment: .leading)
                            Spacer(minLength: 4)
                        }
                        Text("Fi")
                            .frame(width: 50, alignment: .leading)
                        Text("Shots")
                            .frame(width: 45, alignment: .trailing)
                        Text("Exp")
                            .frame(width: 45, alignment: .trailing)
                        Text("Total")
                            .frame(width: 55, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)

                    Divider()

                    // Scrollable rows (limited height, grows with content)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.rows) { row in
                                filterRow(row)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)

                    // Totals row
                    HStack(spacing: 0) {
                        if hasMultipleObjects {
                            Text("")
                                .frame(minWidth: 50, alignment: .leading)
                            Spacer(minLength: 4)
                        }
                        Text("TOTAL")
                            .frame(width: 50, alignment: .leading)
                            .fontWeight(.bold)
                        Text("\(model.totalShots)")
                            .frame(width: 45, alignment: .trailing)
                            .fontWeight(.bold)
                        Text("")
                            .frame(width: 45, alignment: .trailing)
                        Text(formatHours(model.totalExposure))
                            .frame(width: 55, alignment: .trailing)
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }

            // QUALITY STATS: noise/SNR table grouped by filter (+ date for multi-night)
            if !model.qualityRows.isEmpty {
                Divider()

                VStack(spacing: 0) {
                    // Section header with help button
                    HStack {
                        Text("Quality Overview")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Button(action: showQualityHelp) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("What do these values mean?")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)

                    // Column headers — full width, matching integration table font size
                    // All columns right-aligned for clean numeric alignment
                    let hasDate = model.qualityRows.contains(where: { $0.date != nil })
                    HStack(spacing: 0) {
                        Text("Fi")
                            .frame(width: 28, alignment: .leading)
                        if hasDate {
                            Text("Date")
                                .frame(width: 50, alignment: .leading)
                        }
                        Text("#")
                            .frame(width: 24, alignment: .trailing)
                        Text("Noise")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Bkg")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("SNR")
                            .frame(width: 34, alignment: .trailing)
                        Text("N")
                            .frame(width: 36)
                            .padding(.leading, 2)
                        Text("B")
                            .frame(width: 36)
                        Text("S")
                            .frame(width: 36)
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)

                    Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.qualityRows.enumerated()), id: \.element.id) { index, row in
                                qualityRow(row)
                                // Horizontal separator between rows
                                if index < model.qualityRows.count - 1 {
                                    Rectangle().fill(Color.gray.opacity(0.15)).frame(height: 1)
                                        .padding(.horizontal, 10)
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 250)

                    // Summary row: totals and averages across all filter groups
                    if model.qualityRows.count > 0 {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)

                        let totalCount = model.qualityRows.reduce(0) { $0 + $1.count }
                        let avgNoise = model.qualityRows.reduce(Float(0)) { $0 + $1.avgNoise } / Float(model.qualityRows.count)
                        let avgBkg = model.qualityRows.reduce(Float(0)) { $0 + $1.avgBackground } / Float(model.qualityRows.count)
                        let avgSNR = model.qualityRows.reduce(Float(0)) { $0 + $1.avgSNR } / Float(model.qualityRows.count)

                        HStack(spacing: 0) {
                            Text("All")
                                .frame(width: 28, alignment: .leading)
                                .fontWeight(.bold)
                            if hasDate {
                                Text("")
                                    .frame(width: 50, alignment: .leading)
                            }
                            Text("\(totalCount)")
                                .frame(width: 24, alignment: .trailing)
                                .fontWeight(.bold)
                            Text(formatSci(avgNoise))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .foregroundColor(noiseColor(avgNoise))
                                .fontWeight(.bold)
                            Text(formatSci(avgBkg))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .fontWeight(.bold)
                            Text(String(format: "%.0f", avgSNR))
                                .frame(width: 34, alignment: .trailing)
                                .foregroundColor(snrColor(avgSNR))
                                .fontWeight(.bold)
                            // Empty bar placeholders for alignment
                            Text("")
                                .frame(width: 36)
                                .padding(.leading, 2)
                            Text("")
                                .frame(width: 36)
                            Text("")
                                .frame(width: 36)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                    }
                }
            }

            Divider()

            // BOTTOM: Fact sheet + copy button (compact, scrollable)
            HStack(alignment: .top, spacing: 6) {
                ScrollView {
                    Text(model.generateFactSheet())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)

                Button(action: copyFactSheet) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(copied ? .green : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied!" : "Copy Fact Sheet")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))

            // Push all content to the top when panel has extra vertical space
            Spacer(minLength: 0)
        }
    }

    // Show a floating help window explaining all quality overview columns with real-world examples
    private func showQualityHelp() {
        // Reuse existing window if already open
        if let existing = NSApp.windows.first(where: { $0.title == "Quality Overview — Help" }),
           existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let helpText = NSAttributedString.qualityHelpContent()

        let contentWidth: CGFloat = 600
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 750))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 750))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: contentWidth - 40, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(helpText)

        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 750),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quality Overview — Help"
        window.contentView = scrollView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
    }

    // Key-value info row with wrapping value text
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func filterRow(_ row: FilterRow) -> some View {
        // Strip quotes from filter name (FITS may wrap in single quotes)
        let cleanFilter = row.filter
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 0) {
            if hasMultipleObjects {
                Text(row.object)
                    .frame(minWidth: 50, alignment: .leading)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            Text(cleanFilter)
                .frame(width: 50, alignment: .leading)
                .foregroundColor(cleanFilter == "none" ? .secondary : .green)
                .fontWeight(.semibold)
            Text("\(row.shotCount)")
                .frame(width: 45, alignment: .trailing)
            Text(formatExposure(row.exposurePerShot))
                .frame(width: 45, alignment: .trailing)
            Text(formatHours(row.totalSeconds))
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(.primary)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    // Quality stats row: filter, date, count, noise avg, noise range, background, SNR + bar
    // All numeric columns right-aligned, matching header layout
    private func qualityRow(_ row: QualityRow) -> some View {
        let hasDate = model.qualityRows.contains(where: { $0.date != nil })
        // Strip quotes from filter name (FITS may wrap in single quotes)
        let filterName = row.filter
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Compute bar fractions relative to worst/best in session
        let maxNoise = model.qualityRows.map { $0.avgNoise }.max() ?? 1
        let noiseFraction = maxNoise > 0 ? CGFloat(row.avgNoise / maxNoise) : 0
        let maxBkg = model.qualityRows.map { $0.avgBackground }.max() ?? 1
        let bkgFraction = maxBkg > 0 ? CGFloat(row.avgBackground / maxBkg) : 0
        let maxSNR = model.qualityRows.map { $0.avgSNR }.max() ?? 1
        let snrFraction = maxSNR > 0 ? CGFloat(row.avgSNR / maxSNR) : 0

        return HStack(spacing: 0) {
            Text(filterName == "none" ? "—" : filterName)
                .frame(width: 28, alignment: .leading)
                .foregroundColor(filterName == "none" ? .secondary : .green)
                .fontWeight(.semibold)
            if hasDate {
                Text(row.date.map { String($0.suffix(5)) } ?? "all")
                    .frame(width: 50, alignment: .leading)
                    .foregroundColor(.secondary)
            }
            Text("\(row.count)")
                .frame(width: 24, alignment: .trailing)
            Text(formatSci(row.avgNoise))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundColor(noiseColor(row.avgNoise))
            Text(formatSci(row.avgBackground))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(String(format: "%.0f", row.avgSNR))
                .frame(width: 34, alignment: .trailing)
                .foregroundColor(snrColor(row.avgSNR))

            // Noise bar (shorter = better)
            miniBar(fraction: noiseFraction, color: noiseColor(row.avgNoise))
                .frame(width: 36)
                .padding(.leading, 2)
            // Background bar
            miniBar(fraction: bkgFraction, color: bkgColor(row.avgBackground))
                .frame(width: 36)
            // SNR bar (longer = better, inverted color logic)
            miniBar(fraction: snrFraction, color: snrColor(row.avgSNR))
                .frame(width: 36)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    // Compact horizontal bar chart for quality metrics
    private func miniBar(fraction: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * fraction), height: 5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    // Short scientific notation for small float values (e.g. "3.2e-3")
    private func formatSci(_ value: Float) -> String {
        if value == 0 { return "0" }
        if value >= 1.0 { return String(format: "%.1f", value) }
        if value >= 0.1 { return String(format: "%.2f", value) }
        // Use compact scientific notation
        let exp = Int(floor(log10(value)))
        let mantissa = value / powf(10, Float(exp))
        return String(format: "%.1fe%d", mantissa, exp)
    }

    // Color-code noise: green = low (good), yellow = medium, red = high (bad)
    private func noiseColor(_ noise: Float) -> Color {
        if noise < 0.003 { return .green }
        if noise < 0.008 { return .brown }
        return .orange
    }

    // Color-code background: blue tones (lower = darker sky = better)
    private func bkgColor(_ bkg: Float) -> Color {
        if bkg < 0.05 { return .cyan }
        if bkg < 0.15 { return .blue }
        return .purple
    }

    // Color-code SNR: green = high (good), yellow = medium, red = low (bad)
    private func snrColor(_ snr: Float) -> Color {
        if snr > 50 { return .green }
        if snr > 20 { return .brown }
        return .orange
    }

    private func copyFactSheet() {
        let text = model.generateFactSheet()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func formatExposure(_ seconds: Double) -> String {
        if seconds == seconds.rounded() && seconds >= 1 {
            return String(format: "%.0fs", seconds)
        }
        return String(format: "%.1fs", seconds)
    }

    private func formatHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        if hours >= 1.0 {
            return String(format: "%.1fh", hours)
        } else {
            let minutes = seconds / 60.0
            return String(format: "%.0fm", minutes)
        }
    }
}

// MARK: - Quality Help Content (NSAttributedString with large readable font)

extension NSAttributedString {
    /// Builds the rich-text help content for the Quality Overview help window.
    /// Uses large fonts for readability with section headers, color explanations,
    /// and a real-world example based on actual session data.
    static func qualityHelpContent() -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleFont = NSFont.boldSystemFont(ofSize: 18)
        let headingFont = NSFont.boldSystemFont(ofSize: 15)
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let bodyColor = NSColor.labelColor
        let dimColor = NSColor.secondaryLabelColor

        func addTitle(_ text: String) {
            result.append(NSAttributedString(string: text + "\n\n",
                attributes: [.font: titleFont, .foregroundColor: bodyColor]))
        }
        func addHeading(_ text: String) {
            result.append(NSAttributedString(string: "\n" + text + "\n",
                attributes: [.font: headingFont, .foregroundColor: bodyColor]))
        }
        func addBody(_ text: String) {
            result.append(NSAttributedString(string: text + "\n",
                attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        }
        func addDim(_ text: String) {
            result.append(NSAttributedString(string: text + "\n",
                attributes: [.font: bodyFont, .foregroundColor: dimColor]))
        }
        func addMono(_ text: String) {
            result.append(NSAttributedString(string: text + "\n",
                attributes: [.font: monoFont, .foregroundColor: bodyColor]))
        }
        func addMonoColored(_ text: String, color: NSColor) {
            result.append(NSAttributedString(string: text,
                attributes: [.font: monoBold, .foregroundColor: color]))
        }

        addTitle("Quality Overview — What does it all mean?")

        addBody("This table measures the quality of your sub-exposures grouped by filter and date. It helps you spot bad data, compare nights, and decide which subs to keep or discard.")

        // Embed the example screenshot from the asset catalog
        if let exampleImage = NSImage(named: "QualityHelpExample") {
            // Scale image to fit within the text column width (~520px with padding)
            let maxWidth: CGFloat = 520
            let scale = min(maxWidth / exampleImage.size.width, 1.0)
            let scaledSize = NSSize(
                width: exampleImage.size.width * scale,
                height: exampleImage.size.height * scale
            )

            let attachment = NSTextAttachment()
            let cell = NSTextAttachmentCell(imageCell: exampleImage)
            cell.image?.size = scaledSize
            attachment.attachmentCell = cell

            result.append(NSAttributedString(string: "\n"))
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            addDim("Example: Multi-target session with IC1848 (SHO + Lextr), NGC 6960, and LRG 3-757.")
            result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        }

        addBody("The upper table shows the integration summary grouped by object, filter, and exposure. The lower \"Quality Overview\" table adds noise, background, and SNR measurements with color-coded mini bar charts for quick comparison.")

        addHeading("Columns")
        addMono("Fi     Filter name (Ha, OIII, SII, L, R, G, B ...)")
        addMono("Date   Acquisition date (shown if multi-night session)")
        addMono("#      Number of subs measured in this group")
        addMono("Noise  Average noise level — lower = cleaner image")
        addMono("Bkg    Average sky background — lower = darker sky")
        addMono("SNR    Signal-to-Noise Ratio — higher = better data")

        addHeading("Mini Bar Charts (N, B, S)")
        addBody("These show a quick visual comparison within your session:")
        addMono("N  Noise bar    — shorter = less noise = better")
        addMono("B  Background   — shorter = darker sky  = better")
        addMono("S  SNR bar      — longer  = higher SNR  = better")
        addDim("Bars are relative to the worst/best value in your session. If one filter has much worse noise, its bar fills the column and others look tiny.")

        addHeading("Color Coding")
        result.append(NSAttributedString(string: "Noise:  ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("green", color: .systemGreen)
        result.append(NSAttributedString(string: " = excellent (<0.003)   ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("brown", color: .brown)
        result.append(NSAttributedString(string: " = moderate   ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("orange", color: .orange)
        result.append(NSAttributedString(string: " = noisy\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))

        result.append(NSAttributedString(string: "Bkg:    ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("cyan", color: .cyan)
        result.append(NSAttributedString(string: " = very dark sky   ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("blue", color: .systemBlue)
        result.append(NSAttributedString(string: " = moderate   ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("purple", color: .purple)
        result.append(NSAttributedString(string: " = bright/LP\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))

        result.append(NSAttributedString(string: "SNR:    ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("green", color: .systemGreen)
        result.append(NSAttributedString(string: " = excellent (>50)   ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("brown", color: .brown)
        result.append(NSAttributedString(string: " = decent (>20)   ", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))
        addMonoColored("orange", color: .orange)
        result.append(NSAttributedString(string: " = poor\n", attributes: [.font: bodyFont, .foregroundColor: bodyColor]))

        addHeading("Real-World Example")
        addDim("Refer to the screenshot above — this is from a real multi-target, multi-night session with IC1848 (SHO + Lextr), NGC 6960, and LRG 3-757. Here is what the numbers tell us:")

        addMono("  Fi    Date   #   Noise     Bkg      SNR")
        addMono("  H     11-12  4   1.8e-4    6.2e-4     3")
        addMono("  H     03-03  28  3.2e-4    9.1e-3    28")
        addMono("  H     03-06  1   1.2e-3    2.0e-2    17")
        addMono("  L     01-24  6   2.1e-2    0.32      17")
        addMono("  Lextr 03-05  5   5.7e-3    1.9e-2     3")
        addMono("  O     11-12  5   1.9e-4    6.7e-4     3")
        addMono("  O     03-03  28  4.3e-4    1.0e-2    24")
        addMono("  S     03-03  25  2.9e-4    8.8e-3    31")
        addMono("  —     02-27  6   4.4e-3    9.4e-2    22")
        addMono("  All   108       3.7e-3    5.4e-2    17")

        addHeading("What can we learn from this?")

        addBody("1. H (Ha) from Nov 12 has only 4 subs with excellent noise (1.8e-4, green) but SNR of just 3. Compare this to H from Mar 03 (28 subs, SNR 28) — same filter, vastly different results. The Nov data was likely a very short run or poor conditions.")

        addBody("2. H from Mar 03 is solid: 28 subs, low noise (3.2e-4, green), and SNR 28 (brown = decent). The long S bar confirms this is your strongest Ha dataset. The single H sub from Mar 06 (SNR 17) is an outlier — possibly an aborted sequence.")

        addBody("3. L (Luminance) from Jan 24 has the worst data: very high noise (2.1e-2, orange) and extremely bright background (0.32, purple bar!). This was likely a moonlit or cloudy night. SNR is only 17 despite broadband luminance collecting more photons.")

        addBody("4. Lextr (Extreme narrowband) on Mar 05 has moderate noise (5.7e-3) but very low SNR of only 3 — this filter passes so little light that even 300s exposures struggle. These subs need many more frames to be useful.")

        addBody("5. OIII from Nov 12 (5 subs) has excellent noise (1.9e-4, green) and very dark sky (6.7e-4), but SNR is only 3. Compare with OIII from Mar 03 (28 subs, SNR 24) — the Nov data was too short for meaningful signal.")

        addBody("6. SII from Mar 03 is the best narrowband data: lowest noise (2.9e-4), SNR 31. The long S bar confirms it visually.")

        addBody("7. The \"—\" row (no filter name, Feb 27, 6 subs) shows SNR 22 but higher background (9.4e-2, blue dot). Check if these are test frames or a missing filter assignment in NINA.")

        addBody("8. The \"All\" summary (108 subs, avg SNR 17) is dragged down by the poor L data and short Nov runs. The Mar 03 narrowband data alone averages much higher.")

        addHeading("Quick Rules of Thumb")
        addMono("  SNR > 50   Excellent — keep all subs")
        addMono("  SNR 20-50  Good — keep, maybe toss worst outliers")
        addMono("  SNR 10-20  Mediocre — inspect individually")
        addMono("  SNR < 10   Poor — consider discarding or needs")
        addMono("             many more integration time")

        result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        addDim("Tip: Use the search filter in the main file list (e.g. \"snr:<10\") to quickly find and mark your worst subs for deletion.")

        return result
    }
}

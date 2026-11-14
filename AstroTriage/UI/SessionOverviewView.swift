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
            let night: String?
            let exposure: Double
        }

        // Detect multi-night session (uses observingNight to handle midnight crossings)
        let uniqueNights = Set(images.compactMap { $0.observingNight })
        let useNight = uniqueNights.count > 1

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
            let night = useNight ? entry.observingNight : nil

            let key = GroupKey(object: obj, filter: f, night: night, exposure: exp)
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
                let fa = FrameHistoryModel.filterSortOrder(a.key.filter)
                let fb = FrameHistoryModel.filterSortOrder(b.key.filter)
                if fa != fb { return fa < fb }
                if a.key.night != b.key.night { return (a.key.night ?? "") > (b.key.night ?? "") }
                return a.key.exposure < b.key.exposure
            }
            .map { (key, count) in
                FilterRow(
                    object: key.object,
                    filter: key.filter,
                    night: key.night,
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
    let night: String?            // observingNight (nil = single-night session)
    let exposurePerShot: Double
    let shotCount: Int
    let totalSeconds: Double
}

// Quality statistics for a group of images (grouped by filter + date)
/// Bar length and green/yellow/red rating of one Quality Overview value, relative to its
/// peers (the same filter's other nights). Pure functions, GUI-free — covered by
/// Tests/QualityBarScaleTests.swift.
enum QualityBarScale {
    enum Rating { case good, medium, bad }
    struct Bar: Equatable {
        let fraction: CGFloat   // 0…1 of the column width (1 = highest value among the peers)
        let rating: Rating
    }

    /// Noise, background: the lowest peer is the reference. Within 1.3× of it = good,
    /// within 2× = medium, beyond = bad.
    static func lowerIsBetter(_ value: Float, peers: [Float]) -> Bar {
        let positive = peers.filter { $0 > 0 }
        guard value > 0, let best = positive.min(), let worst = positive.max() else {
            return Bar(fraction: 0, rating: .good)
        }
        let ratio = value / best
        let rating: Rating = ratio <= 1.3 ? .good : (ratio <= 2.0 ? .medium : .bad)
        return Bar(fraction: CGFloat(min(1, value / worst)), rating: rating)
    }

    /// SNR: the highest peer is the reference. At least 60% of it = good, at least 35% =
    /// medium, below = bad.
    static func higherIsBetter(_ value: Float, peers: [Float]) -> Bar {
        guard let best = peers.max(), best > 0, value > 0 else {
            return Bar(fraction: 0, rating: .bad)
        }
        let ratio = value / best
        let rating: Rating = ratio >= 0.6 ? .good : (ratio >= 0.35 ? .medium : .bad)
        return Bar(fraction: CGFloat(min(1, ratio)), rating: rating)
    }

    /// Power of ten that makes the largest value of a column read as "d.d" (0.0032 → -3).
    static func exponent(forMax maxValue: Float) -> Int {
        guard maxValue > 0 else { return 0 }
        return Int(floor(log10(maxValue)))
    }

    /// "e-3" for the column header; empty when the values need no scaling.
    static func unitLabel(exponent: Int) -> String {
        exponent == 0 ? "" : "e\(exponent)"
    }

    /// The value in units of 10^exponent with one decimal ("1.4").
    static func label(_ value: Float, exponent: Int) -> String {
        String(format: "%.1f", value / powf(10, Float(exponent)))
    }
}

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
    // Callback: navigate to first image of tapped object in file list
    var onObjectTapped: ((String) -> Void)?
    // Callback: navigate to first image of tapped filter+exposure+night within an object
    // Parameters: (object, filter, exposure, night?)
    var onFilterTapped: ((String, String, Double, String?) -> Void)?
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
            let night: String?
            let exposure: Double
        }

        // Detect multi-night session (uses observingNight to handle midnight crossings)
        let uniqueNights = Set(images.compactMap { $0.observingNight })
        let useNight = uniqueNights.count > 1

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
            let night = useNight ? entry.observingNight : nil

            let key = GroupKey(object: obj, filter: f, night: night, exposure: exp)
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
                let fa = FrameHistoryModel.filterSortOrder(a.key.filter)
                let fb = FrameHistoryModel.filterSortOrder(b.key.filter)
                if fa != fb { return fa < fb }
                if a.key.night != b.key.night { return (a.key.night ?? "") > (b.key.night ?? "") }
                return a.key.exposure < b.key.exposure
            }
            .map { (key, cnt) in
                FilterRow(
                    object: key.object,
                    filter: key.filter,
                    night: key.night,
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

        // Check if we have multiple observing nights (multi-night session)
        // Uses astronomical night (evening date) so sessions spanning midnight stay grouped
        let uniqueNights = Set(withNoise.compactMap { $0.observingNight })
        let useDate = uniqueNights.count > 1

        var grouped: [GroupKey: [(median: Float, mad: Float)]] = [:]

        for entry in withNoise {
            guard let median = entry.noiseMedian, let mad = entry.noiseMAD else { continue }
            let filter = entry.filter ?? "none"
            let date = useDate ? entry.observingNight : nil
            let key = GroupKey(filter: filter, date: date)
            grouped[key, default: []].append((median: median, mad: mad))
        }

        qualityRows = grouped
            .sorted { a, b in
                let fa = FrameHistoryModel.filterSortOrder(a.key.filter)
                let fb = FrameHistoryModel.filterSortOrder(b.key.filter)
                if fa != fb { return fa < fb }
                return (a.key.date ?? "") > (b.key.date ?? "")
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
            lines.append("Session sumup:")

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
    @Environment(\.fontScale) private var fontScale

    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

    private var hasMultipleObjects: Bool {
        Set(model.rows.map { $0.object }).count > 1
    }

    private var hasMultipleNights: Bool {
        model.rows.contains(where: { $0.night != nil })
    }

    @State private var showSessionDetail = false

    var body: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                Text("No session loaded")
                    .font(.system(size: fs(12)))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
            } else {
                // Everything in one unified ScrollView
                ScrollView {
                    VStack(spacing: 0) {

                        // ── FILTER TOTALS (top — quick glance) ──
                        let filterTotals = filterSummary(from: model.rows, totalExposure: model.totalExposure, totalShots: model.totalShots)
                        if filterTotals.count > 1 {
                            Text("Filter Totals")
                                .font(.system(size: fs(11), weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                                .padding(.bottom, 2)

                            // Header
                            HStack {
                                Text("")
                                    .frame(width: 11)
                                Text("Filter")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("Hours")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Text("%")
                                    .frame(width: 40, alignment: .trailing)
                                Text("Files")
                                    .frame(width: 45, alignment: .trailing)
                                Text("")
                                    .frame(maxWidth: .infinity)
                            }
                            .font(.system(size: fs(10), weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                            .padding(.horizontal, 10)

                            ForEach(filterTotals, id: \.filter) { ft in
                                HStack {
                                    Circle()
                                        .fill(FrameHistoryContentView.filterColor(for: ft.filter))
                                        .frame(width: 7, height: 7)
                                    Text(ft.filter)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fontWeight(.medium)
                                    Text(formatHours(ft.totalSeconds))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .fontWeight(.bold)
                                    Text(String(format: "%.0f%%", ft.pctOfTotal))
                                        .frame(width: 40, alignment: .trailing)
                                        .foregroundColor(.secondary)
                                    Text("\(ft.shotCount)")
                                        .frame(width: 45, alignment: .trailing)
                                        .foregroundColor(.secondary)
                                    GeometryReader { geo in
                                        Rectangle()
                                            .fill(FrameHistoryContentView.filterColor(for: ft.filter).opacity(0.4))
                                            .frame(width: geo.size.width * CGFloat(ft.pctOfTotal / 100.0), height: 7)
                                            .cornerRadius(2)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: 7)
                                }
                                .font(.system(size: fs(11), design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                            }

                            // Total line
                            Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 1)
                                .padding(.horizontal, 10).padding(.top, 2)
                            HStack {
                                Text("")
                                    .frame(width: 7)
                                Text("Total")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fontWeight(.bold)
                                Text(formatHours(model.totalExposure))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .fontWeight(.bold)
                                Text("")
                                    .frame(width: 40)
                                Text("\(model.totalShots)")
                                    .frame(width: 45, alignment: .trailing)
                                    .fontWeight(.bold)
                                Text("")
                                    .frame(maxWidth: .infinity)
                            }
                            .font(.system(size: fs(11), design: .monospaced))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)

                            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                                .padding(.vertical, 2)
                        }

                        // ── SESSION DETAIL (collapsible, collapsed by default) ──
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showSessionDetail.toggle() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: showSessionDetail ? "chevron.down" : "chevron.right")
                                    .font(.system(size: fs(9)))
                                Text("Session Detail")
                                    .font(.system(size: fs(11), weight: .bold, design: .monospaced))
                                Spacer()
                                Text("\(model.rows.count) rows")
                                    .font(.system(size: fs(10), design: .monospaced))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showSessionDetail {
                            HStack(spacing: 0) {
                                if hasMultipleObjects {
                                    Text("Object")
                                        .frame(minWidth: 50, alignment: .leading)
                                    Spacer(minLength: 4)
                                }
                                Text("Filter")
                                    .frame(width: 50, alignment: .leading)
                                if hasMultipleNights {
                                    Text("Date")
                                        .frame(width: 50, alignment: .leading)
                                }
                                Text("Shots")
                                    .frame(width: 45, alignment: .trailing)
                                Text("Exp")
                                    .frame(width: 45, alignment: .trailing)
                                Text("Total")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.system(size: fs(11), weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)

                            Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 1)

                            ForEach(model.rows) { row in
                                filterRow(row)
                            }

                            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                                .padding(.vertical, 2)
                        }

                        // ── QUALITY OVERVIEW (noise/SNR per filter+date) ──
                        if !model.qualityRows.isEmpty {
                            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                                .padding(.vertical, 2)

                            HStack {
                                Text("Quality Overview")
                                    .font(.system(size: fs(11), weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Button(action: showQualityHelp) {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: fs(12)))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("What do these values mean?")
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)

                            let hasDate = model.qualityRows.contains(where: { $0.date != nil })
                            HStack(spacing: 0) {
                                Text("Fi")
                                    .frame(width: 28, alignment: .leading)
                                if hasDate {
                                    Text("Date")
                                        .frame(width: 50, alignment: .leading)
                                }
                                Text("#")
                                    .frame(width: 28, alignment: .trailing)
                                // One bar column per metric; the unit of the small number
                                // next to each bar is part of the header (e.g. "Noise e-3").
                                Text("Noise " + QualityBarScale.unitLabel(exponent: qualityScales.noiseExp))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 8)
                                Text("Bkg " + QualityBarScale.unitLabel(exponent: qualityScales.bkgExp))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 8)
                                Text("SNR")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 8)
                            }
                            .help("Each row is compared with the other nights of the SAME filter.\nGreen = close to that filter's best night, yellow = clearly worse, red = far worse.\nNoise and Bkg: shorter bar = better. SNR: longer bar = better.")
                            .font(.system(size: fs(11), weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)

                            Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 1)

                            ForEach(Array(model.qualityRows.enumerated()), id: \.element.id) { index, row in
                                qualityRow(row)
                                if index < model.qualityRows.count - 1 {
                                    Rectangle().fill(Color.gray.opacity(0.15)).frame(height: 1)
                                        .padding(.horizontal, 10)
                                }
                            }

                            // Summary row
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
                                        .frame(width: 28, alignment: .trailing)
                                        .fontWeight(.bold)
                                    // Session averages as plain numbers in the bar columns' units
                                    // (no bar, no colour: an average over filters is not a verdict).
                                    Text(QualityBarScale.label(avgNoise, exponent: qualityScales.noiseExp))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    Text(QualityBarScale.label(avgBkg, exponent: qualityScales.bkgExp))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    Text(String(format: "%.0f", avgSNR))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .font(.system(size: fs(11), design: .monospaced))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Color(NSColor.controlBackgroundColor))
                            }
                        }
                    }
                    .textSelection(.enabled)
                }

                Divider()

                // ── FACT SHEET (compact, max 120pt) ──
                HStack(alignment: .top, spacing: 6) {
                    ScrollView {
                        Text(model.generateFactSheet())
                            .font(.system(size: fs(10), design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    Button(action: copyFactSheet) {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: fs(13)))
                            .foregroundColor(copied ? .green : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied!" : "Copy Fact Sheet")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
            }
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
                Button(action: { model.onObjectTapped?(row.object) }) {
                    Text(row.object).lineLimit(1).foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 50, alignment: .leading)
                Spacer(minLength: 4)
            }
            Button(action: { model.onFilterTapped?(row.object, cleanFilter, row.exposurePerShot, row.night) }) {
                Text(cleanFilter).fontWeight(.semibold)
                    .foregroundColor(cleanFilter == "none" ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .frame(width: 50, alignment: .leading)
            if hasMultipleNights {
                // Show MM-DD from observing night (last 5 chars of YYYY-MM-DD)
                Button(action: { model.onFilterTapped?(row.object, cleanFilter, row.exposurePerShot, row.night) }) {
                    Text(row.night.map { String($0.suffix(5)) } ?? "")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .frame(width: 50, alignment: .leading)
            }
            Text("\(row.shotCount)")
                .frame(width: 45, alignment: .trailing)
            Text(formatExposure(row.exposurePerShot))
                .frame(width: 45, alignment: .trailing)
            Text(formatHours(row.totalSeconds))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundColor(.primary)
        }
        .font(.system(size: fs(11), design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    // MARK: - Filter Summary (per-filter totals across all nights/objects)

    struct FilterTotal {
        let filter: String
        let shotCount: Int
        let totalSeconds: Double
        let pctOfTotal: Double   // % of total integration time
    }

    private func filterSummary(from rows: [FilterRow], totalExposure: Double, totalShots: Int) -> [FilterTotal] {
        var byFilter: [String: (shots: Int, seconds: Double)] = [:]
        for row in rows {
            let filter = FrameHistoryModel.normalizeFilterForChart(row.filter)
            var v = byFilter[filter] ?? (0, 0)
            v.shots += row.shotCount
            v.seconds += row.totalSeconds
            byFilter[filter] = v
        }
        return byFilter.map { filter, data in
            let pct = totalExposure > 0 ? (data.seconds / totalExposure) * 100 : 0
            return FilterTotal(filter: filter, shotCount: data.shots, totalSeconds: data.seconds, pctOfTotal: pct)
        }.sorted { FrameHistoryModel.filterSortOrder($0.filter) < FrameHistoryModel.filterSortOrder($1.filter) }
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
        // Compare the row with the other nights of the SAME filter: a luminance night is
        // naturally brighter and noisier than a blue one, so a session-wide scale would only
        // show the filter. A filter with a single row is compared with the whole session.
        let sameFilter = model.qualityRows.filter { $0.filter == row.filter }
        let peers = sameFilter.count >= 2 ? sameFilter : model.qualityRows
        let noise = QualityBarScale.lowerIsBetter(row.avgNoise, peers: peers.map { $0.avgNoise })
        let bkg = QualityBarScale.lowerIsBetter(row.avgBackground, peers: peers.map { $0.avgBackground })
        let snr = QualityBarScale.higherIsBetter(row.avgSNR, peers: peers.map { $0.avgSNR })

        return HStack(spacing: 0) {
            Button(action: {
                // Navigate to first image of this filter (+ date if available)
                let obj = model.sessionObjects?.components(separatedBy: ", ").first ?? ""
                model.onFilterTapped?(obj, filterName, 0, row.date)
            }) {
                Text(filterName == "none" ? "—" : filterName)
                    .foregroundColor(filterName == "none" ? .secondary : .accentColor)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .frame(width: 28, alignment: .leading)
            if hasDate {
                Button(action: {
                    let obj = model.sessionObjects?.components(separatedBy: ", ").first ?? ""
                    model.onFilterTapped?(obj, filterName, 0, row.date)
                }) {
                    Text(row.date.map { String($0.suffix(5)) } ?? "all")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .frame(width: 50, alignment: .leading)
                    .foregroundColor(.secondary)
            }
            Text("\(row.count)")
                .frame(width: 28, alignment: .trailing)

            // Noise (shorter = better), background (shorter = better), SNR (longer = better).
            // One colour language for all three: green good, yellow medium, red bad.
            valueBar(noise, label: QualityBarScale.label(row.avgNoise, exponent: qualityScales.noiseExp))
            valueBar(bkg, label: QualityBarScale.label(row.avgBackground, exponent: qualityScales.bkgExp))
            valueBar(snr, label: String(format: "%.0f", row.avgSNR))
        }
        .font(.system(size: fs(12), design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    /// Units of the small numbers next to the bars, chosen once per session from the largest
    /// value of each column, so every number reads as "d.d".
    private var qualityScales: (noiseExp: Int, bkgExp: Int) {
        (QualityBarScale.exponent(forMax: model.qualityRows.map { $0.avgNoise }.max() ?? 0),
         QualityBarScale.exponent(forMax: model.qualityRows.map { $0.avgBackground }.max() ?? 0))
    }

    /// One metric cell of the Quality Overview: a bar whose length and colour come from the
    /// comparison with the same filter's other nights, and the value in tiny digits behind it.
    private func valueBar(_ bar: QualityBarScale.Bar, label: String) -> some View {
        let color: Color = {
            switch bar.rating {
            case .good: return .green
            case .medium: return .yellow
            case .bad: return .red
            }
        }()
        return HStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 7)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * bar.fraction), height: 7)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            Text(label)
                .font(.system(size: fs(9), design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: fs(22), alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 8)
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

        addDim("The picture shows the layout before 6.12.3 (number columns and narrow bars); the bars below replace it.")
        result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))

        addBody("The upper table shows the integration summary grouped by object, filter, and exposure. The lower \"Quality Overview\" table shows noise, sky background and SNR of every filter and night as three bars.")

        addHeading("Columns")
        addMono("Fi     Filter name (Ha, OIII, SII, L, R, G, B ...)")
        addMono("Date   Acquisition date (shown if multi-night session)")
        addMono("#      Number of subs measured in this group")
        addMono("Noise  Average noise level       — shorter bar = cleaner image")
        addMono("Bkg    Average sky background    — shorter bar = darker sky")
        addMono("SNR    Signal-to-noise ratio     — longer bar  = better data")
        addDim("The small number behind each bar is the value itself. Its unit is in the column header: \"Noise e-3\" means the number 1.4 stands for 1.4e-3 (normalized 0–1 pixel scale).")

        addHeading("What a row is compared with")
        addBody("Every row is compared with the other nights of the SAME filter — luminance is naturally brighter and noisier than blue or narrowband, so comparing across filters would only show the filter. A full bar is that filter's highest value. A filter that appears only once is compared with the whole session.")

        addHeading("One colour language")
        addMonoColored("green ", color: .systemGreen)
        addBody(" close to the filter's best night (noise/background within 1.3× of the lowest, SNR at least 60% of the highest)")
        addMonoColored("yellow", color: .systemYellow)
        addBody(" clearly worse (up to 2× the lowest noise/background, SNR 35–60% of the highest)")
        addMonoColored("red   ", color: .systemRed)
        addBody(" far worse — look at that night first")

        addHeading("Reading it")
        addBody("A night whose Bkg bar is long and red while its Noise bar is red too was bright: moon, haze, thin cloud or a low object. Watch out for a long green SNR bar on exactly such a night — SNR here is background ÷ noise, and a bright, smooth sky raises it. Background and noise are the honest pair; SNR only confirms them.")

        result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        addDim("Tip: Use the search filter in the main file list (e.g. \"snr:<10\") to quickly find and mark your worst subs for deletion.")

        return result
    }
}

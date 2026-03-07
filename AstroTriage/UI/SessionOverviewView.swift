// v0.9.4
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
    }
    @Published var sessionBinning: String?

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
                        Text("Filter")
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

            Divider()

            // BOTTOM: Fact sheet + copy button
            HStack(alignment: .top, spacing: 6) {
                ScrollView {
                    Text(model.generateFactSheet())
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: copyFactSheet) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(copied ? .green : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied!" : "Copy Fact Sheet")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
        }
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
        HStack(spacing: 0) {
            if hasMultipleObjects {
                Text(row.object)
                    .frame(minWidth: 50, alignment: .leading)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            Text(row.filter)
                .frame(width: 50, alignment: .leading)
                .foregroundColor(row.filter == "none" ? .secondary : .green)
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

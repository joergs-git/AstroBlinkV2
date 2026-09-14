// Plate-solve result window — a scannable per-frame table, and the place where saving is
// decided.
//
// Two things shape this window:
//
//  1. The interesting information after a batch solve is per frame and comparative: which
//     frames solved, what each is pointing at, and — for re-solved frames — whether the fresh
//     solution agrees with the WCS the file already carried. A table with a status glyph per
//     row makes an outlier findable at a glance; a paragraph does not. Clicking a row jumps to
//     that frame in the main file list.
//
//  2. Writing is chosen HERE, after the run, not in the dialog before it. Before solving there
//     is nothing to base the decision on; afterwards the user can see which frames actually
//     changed and write only those.
//
// Window plumbing mirrors GoldenSetCoverageWindowController (singleton + contentRect-capped
// NSHostingView + isRestorable=false — see the NSHostingView intrinsic-size pitfall).
//
// v6.9.0

import SwiftUI
import AppKit

// MARK: - Row model

/// One table row. Built once from the report so the view does no work while scrolling.
struct PlateSolveResultRow: Identifiable {
    enum Status {
        case solved            // solved, nothing to compare against
        case confirmed         // re-solved and agrees with the existing WCS
        case disagrees         // re-solved and does NOT agree — the row worth looking at
        case failed
        case skipped

        var glyph: String {
            switch self {
            case .solved:    return "checkmark.circle.fill"
            case .confirmed: return "checkmark.seal.fill"
            case .disagrees: return "exclamationmark.triangle.fill"
            case .failed:    return "xmark.octagon.fill"
            case .skipped:   return "minus.circle"
            }
        }

        var tint: Color {
            switch self {
            case .solved:    return .green
            case .confirmed: return .green
            case .disagrees: return .orange
            case .failed:    return .red
            case .skipped:   return .secondary
            }
        }

        var label: String {
            switch self {
            case .solved:    return "Solved"
            case .confirmed: return "Confirmed"
            case .disagrees: return "Differs"
            case .failed:    return "Failed"
            case .skipped:   return "Skipped"
            }
        }
    }

    let id = UUID()
    /// Identity of the frame this row describes, so a click can jump to it in the file list.
    let entryID: ImageEntry.ID
    let status: Status
    let filename: String
    let object: String          // identified object, or ""
    let ra: String              // solved centre, sexagesimal
    let dec: String
    /// Measured scale + the focal length it implies, e.g. `1.66" · 467mm`.
    let scaleAndFL: String
    /// Nil when there was nothing to check against; false when the header contradicts the solve.
    let opticsConsistent: Bool?
    let opticsTooltip: String
    let centre: String          // centre offset vs the previous solve, or ""
    let scale: String
    let rotation: String
    let detail: String          // failure reason / skip reason, or ""
}

// MARK: - Controller

final class PlateSolveResultWindowController {
    static let shared = PlateSolveResultWindowController()
    private var window: NSWindow?

    /// - Parameters:
    ///   - onSelectFrame: jump to a frame in the main file list; false when it is gone.
    ///   - onSave: perform the write-back and hand back the updated report. Nil disables the
    ///     save controls (nothing writable, e.g. an unwritable session root).
    @MainActor
    func show(report: PlateSolveReport,
              unsupportedCount: Int,
              onSelectFrame: @escaping (ImageEntry.ID) -> Bool,
              onSave: ((PlateSolveSaveScope, Bool) async -> PlateSolveReport)?) {

        // A FLEXIBLE frame, not the hard `.frame(width:height:)` the settings windows use.
        // Those are fixed-size panels; this one is a table the user needs to resize. The cap
        // that matters is the minimum — without it NSHostingView derives a tall, narrow
        // intrinsic size from the unbreakable monospaced rows and the window becomes
        // unresizable (the v6.4.1 pitfall).
        let rootView = PlateSolveResultView(report: report,
                                            unsupportedCount: unsupportedCount,
                                            onSelectFrame: onSelectFrame,
                                            onSave: onSave)
            .frame(minWidth: 720, idealWidth: 900, maxWidth: .infinity,
                   minHeight: 360, idealHeight: 620, maxHeight: .infinity)

        // Reuse the window whenever we still hold one — NOT only when it is currently
        // visible. `isReleasedWhenClosed = false` keeps a closed window alive, so the old
        // visibility check meant every solve after the user closed the panel created another
        // window and leaked the previous one.
        if let w = window {
            (w.contentViewController as? NSHostingController<AnyView>)?
                .rootView = AnyView(rootView)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // NSHostingController reports a sane preferredContentSize to AppKit; a plain
        // NSHostingView races its own first layout pass and the window snaps to whatever
        // SwiftUI computed, which is what made this window unmovable and unresizable.
        let controller = NSHostingController(rootView: AnyView(rootView))
        controller.preferredContentSize = NSSize(width: 900, height: 620)

        let win = NSWindow(contentViewController: controller)
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.title = "Plate Solve Results"
        win.isRestorable = false
        win.setContentSize(NSSize(width: 900, height: 620))
        win.minSize = NSSize(width: 720, height: 360)
        win.isReleasedWhenClosed = false
        // Floating: the whole point is to click rows here and watch the main window follow.
        // At normal level this panel would sit on top of the very thing it is driving.
        win.level = .floating
        win.isMovableByWindowBackground = false
        // Offset from centre so it does not sit squarely over the image viewer.
        win.center()
        var frame = win.frame
        frame.origin.x = min(frame.origin.x + 180, (NSScreen.main?.visibleFrame.maxX ?? frame.maxX) - frame.width - 20)
        win.setFrameOrigin(frame.origin)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

// MARK: - View

private struct PlateSolveResultView: View {

    /// Report plus everything derived from it, recomputed only when the report actually
    /// changes (i.e. after a save) rather than on every body evaluation.
    private struct Model {
        let report: PlateSolveReport
        let rows: [PlateSolveResultRow]
        let hasComparison: Bool

        init(_ report: PlateSolveReport) {
            self.report = report
            self.rows = PlateSolveResultBuilder.rows(from: report)
            self.hasComparison = report.solved.contains { $0.comparison != nil }
        }
    }

    let unsupportedCount: Int
    let onSelectFrame: (ImageEntry.ID) -> Bool
    let onSave: ((PlateSolveSaveScope, Bool) async -> PlateSolveReport)?

    @State private var model: Model
    @State private var copied = false
    @State private var selectedRowID: UUID?
    @State private var missingFrameName: String?
    @State private var writeObjectName = true
    @State private var isSaving = false
    @State private var didSave = false

    init(report: PlateSolveReport,
         unsupportedCount: Int,
         onSelectFrame: @escaping (ImageEntry.ID) -> Bool,
         onSave: ((PlateSolveSaveScope, Bool) async -> PlateSolveReport)?) {
        self.unsupportedCount = unsupportedCount
        self.onSelectFrame = onSelectFrame
        self.onSave = onSave
        _model = State(initialValue: Model(report))
    }

    private var report: PlateSolveReport { model.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // No separate column header here: it lives INSIDE the table's scroll view as a
            // pinned section header, so it scrolls horizontally in step with the rows. Placing
            // a copy out here also forced the whole window to the table's full width — the
            // content then no longer fit, the window could not be resized, and everything was
            // clipped on the left.
            table
            Divider()
            saveBar
            Divider()
            footer
        }
        // Let every part shrink to whatever the window offers; only the table scrolls.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.headline)
                .font(.system(size: 14, weight: .bold, design: .monospaced))

            HStack(spacing: 14) {
                if let field = PlateSolveResultBuilder.dominantField(report) {
                    tag("field", field, .blue)
                }
                if report.confirmations > 0 {
                    tag("confirmed", "\(report.confirmations)", .green)
                }
                if !report.disagreements.isEmpty {
                    tag("differs", "\(report.disagreements.count)", .orange)
                }
                if !report.failed.isEmpty {
                    tag("failed", "\(report.failed.count)", .red)
                }
                if !report.opticsMismatches.isEmpty {
                    tag("FOCALLEN off", "\(report.opticsMismatches.count)", .orange)
                }
                if unsupportedCount > 0 {
                    tag("skipped", "\(unsupportedCount) non-FITS", .secondary)
                }
            }

            if let missingFrameName {
                Text("\(missingFrameName) is no longer in the loaded session.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.orange)
            }
        }
        .padding(14)
    }

    private func tag(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // MARK: Table

    /// Header and rows share ONE scroll view so they cannot drift apart horizontally; the
    /// header is pinned so it stays visible while scrolling down.
    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index)
                    }
                } header: {
                    tableHeader
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            cell("", width: 22)
            cell("FRAME", width: 200)
            cell("OBJECT", width: 130)
            cell("RA (J2000)", width: 100)
            cell("DEC", width: 95)
            cell("SCALE · FL", width: 120)
            cell("OPT", width: 28)
            if model.hasComparison {
                cell("Δ CENTRE", width: 80, align: .trailing)
                cell("Δ SCALE", width: 72, align: .trailing)
                cell("Δ ROT", width: 62, align: .trailing)
            }
            cell("NOTE", width: 150)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func rowView(_ row: PlateSolveResultRow, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.status.glyph)
                .foregroundColor(row.status.tint)
                .font(.system(size: 11))
                .frame(width: 22, alignment: .leading)
                .help(row.status.label)

            cell(row.filename, width: 200).help(row.filename)
            cell(row.object, width: 130)
            cell(row.ra, width: 100)
            cell(row.dec, width: 95)
            cell(row.scaleAndFL, width: 120).help(row.opticsTooltip)
            opticsBadge(row).frame(width: 28, alignment: .leading)
            if model.hasComparison {
                cell(row.centre, width: 80, align: .trailing)
                cell(row.scale, width: 72, align: .trailing)
                cell(row.rotation, width: 62, align: .trailing)
            }
            cell(row.detail, width: 150).help(row.detail)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(row.status == .failed ? .red
                         : (row.status == .disagrees ? .orange : .primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .background(rowBackground(row: row, index: index))
        .contentShape(Rectangle())          // the whole row is the hit target, not just the text
        .onTapGesture { jump(to: row) }
    }

    /// Select the frame in the main window. The result panel deliberately stays open and
    /// floating — the point is to walk down the list of outliers and look at each one.
    private func jump(to row: PlateSolveResultRow) {
        selectedRowID = row.id
        missingFrameName = onSelectFrame(row.entryID) ? nil : row.filename
    }

    /// Does FOCALLEN agree with the scale the solve measured? Blank when the header does not
    /// say enough to check — an absent value is not a mismatch.
    @ViewBuilder
    private func opticsBadge(_ row: PlateSolveResultRow) -> some View {
        switch row.opticsConsistent {
        case .some(true):
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.green)
                .help(row.opticsTooltip)
        case .some(false):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .help(row.opticsTooltip)
        case nil:
            Text("")
        }
    }

    private func rowBackground(row: PlateSolveResultRow, index: Int) -> Color {
        if selectedRowID == row.id { return Color.accentColor.opacity(0.25) }
        switch row.status {
        case .disagrees: return Color.orange.opacity(0.12)
        case .failed:    return Color.red.opacity(0.10)
        default:         return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035)
        }
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment = .leading) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: align)
    }

    // MARK: Save bar

    @ViewBuilder
    private var saveBar: some View {
        if report.written > 0 || !report.writeFailures.isEmpty || didSave {
            savedState
        } else if let onSave, !report.solved.isEmpty {
            saveControls(onSave)
        } else if report.solved.isEmpty {
            EmptyView()
        } else {
            Text("Results apply to this session only — the session folder is not writable.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private func saveControls(_ save: @escaping (PlateSolveSaveScope, Bool) async -> PlateSolveReport) -> some View {
        let changed = report.changedFrames.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Save into the files? Without saving, these solutions are lost when the "
                 + "session is reloaded. A backup folder is always created first.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Toggle("Also name the object in OBJECT", isOn: $writeObjectName)
                    .font(.system(size: 10, design: .monospaced))
                    .toggleStyle(.checkbox)

                Spacer()

                if isSaving {
                    ProgressView().controlSize(.small)
                }

                Button("Save All (\(report.solved.count))") {
                    perform(.all, save)
                }
                .disabled(isSaving)

                Button("Save Changed (\(changed))") {
                    perform(.changedOnly, save)
                }
                // Nothing changed → nothing to write; the button would rewrite files for no gain.
                .disabled(isSaving || changed == 0)
                .help(changed == 0
                      ? "Every solved frame confirmed the WCS it already had — nothing would change."
                      : "Write only the frames that had no WCS or whose solve disagrees with it")

                Button("Don't Save") { didSave = true }
                    .disabled(isSaving)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func perform(_ scope: PlateSolveSaveScope,
                         _ save: @escaping (PlateSolveSaveScope, Bool) async -> PlateSolveReport) {
        isSaving = true
        Task {
            let updated = await save(scope, writeObjectName)
            await MainActor.run {
                model = Model(updated)
                isSaving = false
                didSave = true
            }
        }
    }

    private var savedState: some View {
        VStack(alignment: .leading, spacing: 3) {
            if report.written > 0 {
                Text("Wrote WCS into \(report.written) file(s)"
                     + (report.objectNamesWritten > 0
                        ? ", named the object in \(report.objectNamesWritten)." : "."))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            } else if didSave {
                Text("Nothing written — the solutions apply to this session only.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let backup = report.backupDirectory {
                Text("Backup: \(backup.path)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !report.objectNamesKept.isEmpty {
                Text("\(report.objectNamesKept.count) file(s) kept their existing OBJECT "
                     + "(e.g. \"\(report.objectNamesKept[0].existing)\" vs identified "
                     + "\(report.objectNamesKept[0].identified)) — existing names are never overwritten.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !report.writeFailures.isEmpty {
                Text("\(report.writeFailures.count) file(s) could not be written and were "
                     + "restored from their backup: \(report.writeFailures[0].reason)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("✓ solved · ⚠ differs · ✗ failed · click a row to show it")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button(copied ? "Copied" : "Copy to Clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    PlateSolveResultBuilder.clipboardText(report: report,
                                                          unsupportedCount: unsupportedCount),
                    forType: .string
                )
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .disabled(model.rows.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Row + clipboard construction

enum PlateSolveResultBuilder {

    /// Build the table rows. Disagreements first — they are the reason to open this window at
    /// all, and would otherwise be buried under a hundred confirmations.
    static func rows(from report: PlateSolveReport) -> [PlateSolveResultRow] {
        var rows: [PlateSolveResultRow] = []

        let solvedRows = report.solved.map { frame -> PlateSolveResultRow in
            let status: PlateSolveResultRow.Status
            if let comparison = frame.comparison {
                status = comparison.isSignificant ? .disagrees : .confirmed
            } else {
                status = .solved
            }
            let c = frame.comparison
            let optics = frame.optics
            return PlateSolveResultRow(
                entryID: frame.entry.id,
                status: status,
                filename: frame.entry.filename,
                object: frame.identification?.displayName ?? "—",
                ra: SkyCoordinateFormatter.rightAscension(degrees: frame.solution.crval1),
                dec: SkyCoordinateFormatter.declination(degrees: frame.solution.crval2),
                scaleAndFL: optics.scaleAndFocalLength,
                opticsConsistent: optics.deviationPercent == nil ? nil : optics.isConsistent,
                opticsTooltip: optics.explanation,
                centre: c.map { String(format: "%.2f'", $0.centreOffsetArcmin) } ?? "",
                scale: c.map { String(format: "%+.2f%%", $0.scaleDifferencePercent) } ?? "",
                rotation: c.map { String(format: "%.2f°", $0.rotationDifferenceDegrees) } ?? "",
                detail: status == .disagrees ? "differs from stored WCS" : ""
            )
        }
        rows += solvedRows.filter { $0.status == .disagrees }
        rows += solvedRows.filter { $0.status != .disagrees }

        rows += report.failed.map {
            PlateSolveResultRow(entryID: $0.entry.id, status: .failed,
                                filename: $0.entry.filename, object: "—",
                                ra: "", dec: "", scaleAndFL: "",
                                opticsConsistent: nil, opticsTooltip: "",
                                centre: "", scale: "", rotation: "", detail: $0.reason)
        }
        rows += report.skippedUnsupported.map {
            PlateSolveResultRow(entryID: $0.id, status: .skipped,
                                filename: $0.filename, object: "—",
                                ra: "", dec: "", scaleAndFL: "",
                                opticsConsistent: nil, opticsTooltip: "",
                                centre: "", scale: "", rotation: "", detail: "not FITS")
        }
        return rows
    }

    /// The object most frames agree on, with a count when they do not all agree.
    static func dominantField(_ report: PlateSolveReport) -> String? {
        let names = report.solved.compactMap { $0.identification?.displayName }
        guard !names.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        guard let (name, count) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return count == names.count ? name : "\(name) (\(count)/\(names.count))"
    }

    /// Tab-separated text for the clipboard — pastes straight into a spreadsheet or an issue.
    static func clipboardText(report: PlateSolveReport, unsupportedCount: Int) -> String {
        var lines: [String] = []
        lines.append("AstroBlink plate solve — \(report.headline)")
        if let field = dominantField(report) { lines.append("Field: \(field)") }
        if report.confirmations > 0 { lines.append("Confirmed existing solve: \(report.confirmations)") }
        if !report.disagreements.isEmpty { lines.append("Disagree with existing solve: \(report.disagreements.count)") }
        if report.written > 0 { lines.append("WCS written into files: \(report.written)") }
        if report.objectNamesWritten > 0 { lines.append("OBJECT named in files: \(report.objectNamesWritten)") }
        if let backup = report.backupDirectory { lines.append("Backup: \(backup.path)") }
        if unsupportedCount > 0 { lines.append("Skipped as non-FITS: \(unsupportedCount)") }
        lines.append("")
        lines.append(["STATUS", "FRAME", "OBJECT", "RA", "DEC", "SCALE_FL", "OPTICS",
                      "D_CENTRE_ARCMIN", "D_SCALE_PCT", "D_ROT_DEG", "NOTE"]
                     .joined(separator: "\t"))

        for row in rows(from: report) {
            let opticsFlag: String
            switch row.opticsConsistent {
            case .some(true):  opticsFlag = "ok"
            case .some(false): opticsFlag = "MISMATCH"
            case nil:          opticsFlag = ""
            }
            lines.append([
                row.status.label,
                row.filename,
                row.object,
                row.ra,
                row.dec,
                row.scaleAndFL,
                opticsFlag,
                row.centre.replacingOccurrences(of: "'", with: ""),
                row.scale.replacingOccurrences(of: "%", with: ""),
                row.rotation.replacingOccurrences(of: "°", with: ""),
                row.detail
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }
}

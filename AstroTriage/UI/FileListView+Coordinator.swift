// FileListView Coordinator — NSTableViewDelegate + DataSource + NSMenuDelegate.
// Lives in an extension so the SwiftUI struct stays readable but the type stays
// nested (FileListView.Coordinator) — same name SwiftUI's makeCoordinator returns.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension FileListView {

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var viewModel: TriageViewModel
        weak var tableView: NSTableView?
        var lastNightMode: Bool = false
        var lastFontScale: CGFloat = 1.0

        init(viewModel: TriageViewModel) {
            self.viewModel = viewModel
        }

        // Snapshot of displayed images and cached URLs, updated from main actor in updateNSView
        var displayedImages: [ImageEntry] = []
        var cachedURLs: Set<URL> = []
        var rotatedURLs: Set<URL> = []

        // Per-group min/max ranges for metric bar indicators
        // Group key = "target|filter|exposure" (same grouping as quality scoring)
        // Each group has its own min/max per metric column
        private var groupMetricRanges: [String: [String: (min: Double, max: Double)]] = [:]
        private static let barColumns: Set<String> = ["snr", "hfr", "fwhm", "starCount", "snrContrib", "eccentricity"]

        private func groupKey(for entry: ImageEntry) -> String {
            let t = (entry.target ?? "").trimmingCharacters(in: .whitespaces)
            let f = (entry.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
            let e = entry.exposure.map { String(Int($0.rounded())) } ?? "0"
            return "\(t)|\(f)|\(e)"
        }

        func updateMetricRanges() {
            groupMetricRanges.removeAll()

            // Group images
            var groups: [String: [ImageEntry]] = [:]
            for entry in displayedImages {
                let key = groupKey(for: entry)
                groups[key, default: []].append(entry)
            }

            // Compute min/max per metric per group
            for (gKey, entries) in groups {
                var ranges: [String: (min: Double, max: Double)] = [:]
                for colId in Self.barColumns {
                    let values = entries.compactMap { ColumnDefinition.numericValue(for: colId, from: $0) }
                    guard let minV = values.min(), let maxV = values.max(), maxV > minV else { continue }
                    ranges[colId] = (minV, maxV)
                }
                groupMetricRanges[gKey] = ranges
            }
        }

        /// Returns 0.0–1.0 fraction for how good this value is within its group.
        /// Higher fraction = better. Longer bar = better.
        func metricFraction(colId: String, value: Double, entry: ImageEntry) -> CGFloat? {
            let gKey = groupKey(for: entry)
            guard let ranges = groupMetricRanges[gKey],
                  let range = ranges[colId], range.max > range.min else { return nil }
            let normalized = (value - range.min) / (range.max - range.min)
            // fwhm, hfr, eccentricity: lower = better → invert so longer bar = better
            if colId == "fwhm" || colId == "hfr" || colId == "eccentricity" {
                return CGFloat(1.0 - normalized)
            }
            return CGFloat(normalized)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayedImages.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let colId = tableColumn?.identifier.rawValue,
                  row < displayedImages.count else { return nil }

            let entry = displayedImages[row]
            let isNight = viewModel.nightMode

            if colId == "marked" {
                return makeCheckboxCell(for: row, isMarked: entry.isMarkedForDeletion, in: tableView)
            }

            // For the filename column, prepend a cache indicator
            if colId == "filename" {
                return makeFilenameCellWithCacheIndicator(entry: entry, isNight: isNight, in: tableView)
            }

            // Quality column: SF Symbol icon with semantic color
            if colId == "quality" {
                return makeQualityCell(for: entry, in: tableView)
            }

            // Quality feedback column: agree/disagree/partly icons
            if colId == "goldenLabel" {
                return makeGoldenCell(for: entry, in: tableView)
            }
            if colId == "qualityFeedback" {
                return makeFeedbackCell(for: entry, in: tableView)
            }

            // User confidence rating: 1-3 star icons
            if colId == "userConfidence" {
                return makeConfidenceCell(for: entry, in: tableView)
            }

            // Regular text column
            let value = ColumnDefinition.value(for: colId, from: entry)
            let isMetricCol = Self.barColumns.contains(colId)
            let identifier = NSUserInterfaceItemIdentifier(isMetricCol ? "MetricCell_\(colId)" : "Cell_\(colId)")
            let cellView: NSTableCellView

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cellView = reused
            } else {
                cellView = NSTableCellView()
                cellView.identifier = identifier
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                textField.font = .monospacedSystemFont(ofSize: round(11 * lastFontScale), weight: .regular)
                textField.isSelectable = true
                cellView.addSubview(textField)
                cellView.textField = textField

                if isMetricCol {
                    // Add a tiny bar indicator below the text
                    let bar = NSView()
                    bar.translatesAutoresizingMaskIntoConstraints = false
                    bar.identifier = NSUserInterfaceItemIdentifier("metricBar")
                    bar.wantsLayer = true
                    cellView.addSubview(bar)

                    NSLayoutConstraint.activate([
                        textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                        textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                        textField.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 1),
                        bar.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                        bar.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -1),
                        bar.heightAnchor.constraint(equalToConstant: 2),
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                        textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                        textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    ])
                }
            }

            cellView.textField?.stringValue = value

            // Cell-level tooltip for "!" indicator (FWHM/HFR unmeasurable)
            if value == "!" && (colId == "fwhm" || colId == "hfr") {
                cellView.toolTip = "Measurement not possible — all bright star candidates are saturated in full resolution.\nCommon with broadband filters + high gain + bright targets (open clusters) + moonlight.\nQuality scoring uses other available metrics (stars, SNR, noise, trailing).\nAsk AIsaac for a detailed explanation of this frame."
            } else if isMetricCol {
                cellView.toolTip = nil  // Clear tooltip on reused cells
            }

            // Update font size for scale changes (reused cells keep old font)
            let scaledFontSize = round(11 * lastFontScale)
            if cellView.textField?.font?.pointSize != scaledFontSize {
                cellView.textField?.font = .monospacedSystemFont(ofSize: scaledFontSize, weight: .regular)
            }

            // Update metric bar: longer = better, red (bad) → green (good)
            if isMetricCol, let numVal = ColumnDefinition.numericValue(for: colId, from: entry),
               let fraction = metricFraction(colId: colId, value: numVal, entry: entry) {
                let bar = cellView.subviews.first { $0.identifier?.rawValue == "metricBar" }
                if let bar = bar {
                    // Remove old proportional width constraint before adding new one.
                    // The constraint bar.width = cellView.width * multiplier is owned by
                    // cellView (common ancestor), NOT by bar — so bar.constraints won't find it.
                    for c in cellView.constraints where c.firstAttribute == .width {
                        if c.firstItem === bar || c.secondItem === bar {
                            c.isActive = false
                        }
                    }
                    let widthConstraint = bar.widthAnchor.constraint(equalTo: cellView.widthAnchor, multiplier: max(0.02, fraction), constant: -4 * fraction)
                    widthConstraint.isActive = true
                    // Red (0%) → Orange (50%) → Green (100%)
                    let hue: CGFloat = fraction * 0.33
                    let color = NSColor(calibratedHue: hue, saturation: 0.75, brightness: 0.75, alpha: 0.85)
                    bar.layer?.backgroundColor = color.cgColor
                    bar.isHidden = false
                }
            } else {
                let bar = cellView.subviews.first { $0.identifier?.rawValue == "metricBar" }
                if let bar = bar {
                    // Also clean up stale constraints when hiding the bar
                    for c in cellView.constraints where c.firstAttribute == .width {
                        if c.firstItem === bar || c.secondItem === bar {
                            c.isActive = false
                        }
                    }
                    bar.isHidden = true
                }
            }

            // Color logic: marked rows get red text, but use white when row is selected
            let isSelected = tableView.selectedRowIndexes.contains(row)
            if isNight {
                cellView.textField?.textColor = entry.isMarkedForDeletion
                    ? NSColor(red: 0.5, green: 0, blue: 0, alpha: 1)
                    : NSColor.systemRed
            } else if entry.isMarkedForDeletion && isSelected {
                cellView.textField?.textColor = .white
            } else {
                cellView.textField?.textColor = entry.isMarkedForDeletion ? .systemRed : .labelColor
            }

            return cellView
        }

        // Quality column cell: centered SF Symbol icon with semantic color.
        // good=green checkmark, uncertain=orange dash, trash=red xmark, nil=empty.
        private func makeQualityCell(for entry: ImageEntry, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_quality")
            let cellView: NSTableCellView

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cellView = reused
            } else {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 14),
                    imageView.heightAnchor.constraint(equalToConstant: 14),
                    imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                cellView = cell
            }

            // Pick icon + color + tooltip based on tier + severity
            let (symbolName, color, tooltip): (String?, NSColor?, String) = {
                guard let bd = entry.qualityBreakdown else {
                    return (nil, nil, "No quality score — needs ≥\(QualityEstimator.minGroupSize) images per group")
                }
                let richTooltip = Self.qualityTooltip(for: bd)
                switch bd.tier {
                case .excellent:
                    return ("circle.fill", .systemGreen, richTooltip)
                case .good:
                    return ("circle.lefthalf.filled", .systemGreen, richTooltip)
                case .borderline:
                    // Orange gradient: 4 sub-tiers from light amber to deep orange
                    let (icon, tint) = Self.borderlineIconAndColor(severity: bd.borderlineSeverity)
                    return (icon, tint, richTooltip)
                case .trash:
                    return ("xmark.circle.fill", .systemRed, richTooltip)
                case .uncertain:
                    return ("questionmark.circle", .systemBlue, richTooltip)
                }
            }()

            cellView.toolTip = tooltip

            if let name = symbolName, let color = color,
               let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                cellView.imageView?.image = image.withSymbolConfiguration(config)
                cellView.imageView?.contentTintColor = color
            } else {
                cellView.imageView?.image = nil
            }

            // Lock badge overlay for calibration-locked or community-locked KEEP frames
            let lockTag = 999
            cellView.viewWithTag(lockTag)?.removeFromSuperview()
            let bd = entry.qualityBreakdown
            if bd?.isLockedKeep == true || bd?.isCommunityFloorLocked == true {
                let lockView = NSImageView()
                lockView.tag = lockTag
                lockView.translatesAutoresizingMaskIntoConstraints = false
                let isLocal = bd?.isLockedKeep == true
                let symbolName = isLocal ? "lock.circle.fill" : "lock.circle.fill"
                let description = isLocal ? "Calibration locked" : "Community baseline locked"
                if let lockImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
                    let lockConfig = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                    lockView.image = lockImg.withSymbolConfiguration(lockConfig)
                    // Blue for local calibration, gray for community baseline
                    lockView.contentTintColor = isLocal ? .systemBlue : .systemGray
                }
                cellView.addSubview(lockView)
                NSLayoutConstraint.activate([
                    lockView.widthAnchor.constraint(equalToConstant: 8),
                    lockView.heightAnchor.constraint(equalToConstant: 8),
                    lockView.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -1),
                    lockView.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -1),
                ])
            }

            return cellView
        }

        // User confidence rating cell: 1-3 filled stars in yellow, empty if unrated
        private func makeConfidenceCell(for entry: ImageEntry, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_userConfidence")
            let cellView: NSTableCellView

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cellView = reused
            } else {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.alignment = .center
                label.font = .systemFont(ofSize: round(10 * lastFontScale))
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                cellView = cell
            }

            let conf = entry.userConfidence
            // 1-star uses outline ☆ to visually distinguish garbage from real ratings
            cellView.textField?.stringValue = conf == 1 ? "☆" : (conf > 1 ? String(repeating: "★", count: conf) : "")
            cellView.textField?.textColor = conf > 0 ? .systemYellow : .secondaryLabelColor
            cellView.toolTip = conf > 0
                ? "\(conf)-star confidence (press 1/2/3 to change, same key to clear)\(conf == 1 ? " — garbage, auto-marked for deletion" : "")"
                : "Unrated (press 1/2/3 to rate)"

            return cellView
        }

        // Quality feedback cell: thumbs up (agree), thumbs down (disagree),
        // sideways thumb/pointing hand (partly), empty (none).
        // Hand gestures chosen over abstract marks for at-a-glance semantics.
        private func makeFeedbackCell(for entry: ImageEntry, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_qualityFeedback")
            let cellView: NSTableCellView

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cellView = reused
            } else {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 14),
                    imageView.heightAnchor.constraint(equalToConstant: 14),
                    imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                cellView = cell
            }

            cellView.toolTip = Self.feedbackTooltip(for: entry.qualityFeedback)
            cellView.imageView?.image = Self.feedbackIcon(for: entry.qualityFeedback)
            cellView.imageView?.contentTintColor = Self.feedbackTint(for: entry.qualityFeedback)
            return cellView
        }

        // Feedback icon factory: returns an SF Symbol configured at the cell size.
        // Used by makeFeedbackCell and the right-click context menu so both stay in sync.
        fileprivate static func feedbackIcon(for feedback: QualityFeedback) -> NSImage? {
            let symbolName: String
            switch feedback {
            case .none:     return nil
            case .agree:    symbolName = "hand.thumbsup.fill"
            case .disagree: symbolName = "hand.thumbsdown.fill"
            case .partly:   symbolName = "hand.point.right.fill"  // sideways-pointing hand reads as "horizontal/neutral"
            }
            guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
                return nil
            }
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            return image.withSymbolConfiguration(config)
        }

        fileprivate static func feedbackTint(for feedback: QualityFeedback) -> NSColor? {
            switch feedback {
            case .none:     return nil
            case .agree:    return .systemGreen
            case .disagree: return .systemRed
            case .partly:   return .systemOrange
            }
        }

        fileprivate static func feedbackTooltip(for feedback: QualityFeedback) -> String {
            switch feedback {
            case .none:     return "No feedback (press A to cycle)"
            case .agree:    return "Agree with quality assessment (press A to change)"
            case .disagree: return "Disagree with quality assessment (press A to change)"
            case .partly:   return "Partly agree — neutral (press A to change)"
            }
        }

        // Orange gradient icon and color for borderline sub-tiers.
        // 4 levels from light amber (nearly good) to deep orange (nearly trash).
        private static func borderlineIconAndColor(severity: Int) -> (String, NSColor) {
            switch severity {
            case 0:  // Nearly good — lightest warm amber
                return ("exclamationmark.circle", NSColor(calibratedHue: 0.14, saturation: 0.45, brightness: 1.0, alpha: 1.0))
            case 1:  // Middle borderline — light orange
                return ("exclamationmark.circle", NSColor(calibratedHue: 0.12, saturation: 0.55, brightness: 0.95, alpha: 1.0))
            case 2:  // Leaning trash — filled, warm orange
                return ("exclamationmark.circle.fill", NSColor(calibratedHue: 0.09, saturation: 0.70, brightness: 0.92, alpha: 1.0))
            default: // Nearly trash — filled, deep orange (distinct from red)
                return ("exclamationmark.circle.fill", NSColor(calibratedHue: 0.06, saturation: 0.80, brightness: 0.88, alpha: 1.0))
            }
        }

        // Rich multi-line quality tooltip with per-metric z-score breakdown,
        // SNR contribution, and smart recommendation label.
        /// Convert plain ASCII to Unicode Mathematical Bold (U+1D400 range).
        /// Works in plain-text NSTableView tooltips — no attributed strings needed.
        private static func boldText(_ text: String) -> String {
            text.unicodeScalars.map { scalar -> String in
                let v = scalar.value
                if v >= 0x41 && v <= 0x5A {       // A-Z → 𝐀-𝐙
                    return String(UnicodeScalar(v - 0x41 + 0x1D400)!)
                } else if v >= 0x61 && v <= 0x7A { // a-z → 𝐚-𝐳
                    return String(UnicodeScalar(v - 0x61 + 0x1D41A)!)
                }
                return String(scalar)
            }.joined()
        }

        private static func qualityTooltip(for bd: QualityBreakdown) -> String {
            let tierName: String = {
                switch bd.tier {
                case .excellent:  return boldText("Excellent")
                case .good:       return boldText("Good")
                case .borderline: return boldText("Borderline")
                case .trash:      return boldText("Poor")
                case .uncertain:  return boldText("Uncertain")
                }
            }()

            var lines = ["\(tierName)  (z = \(String(format: "%+.2f", bd.combinedZScore)))"]

            if bd.isLockedKeep {
                lines.append("  [LOCKED] Within calibrated baseline for this setup")
            } else if bd.isCommunityFloorLocked {
                lines.append("  [COMMUNITY] Within community baseline (similar setups)")
            }

            if !bd.garbageReasons.isEmpty {
                lines.append("")
                for reason in bd.garbageReasons {
                    lines.append("  Reason: \(reason.rawValue)")
                }
            } else {
                // Section header for metrics
                lines.append("")
                lines.append("  \u{2500}\u{2500} Metrics \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}")

                // Per-metric z-score breakdown
                // fwhm/hfr/noise: raw z is positive when worse (higher value = worse)
                // Display convention: positive = above avg (good for stars), negative = below avg
                // For FWHM/HFR/noise we invert the display so positive = good
                func metricLine(_ name: String, _ z: Double?, lowerIsBetter: Bool) -> String? {
                    guard let z = z else { return nil }
                    let displayZ = lowerIsBetter ? -z : z
                    let arrow = displayZ < -0.5 ? " \u{2193}" : (displayZ > 0.5 ? " \u{2191}" : "")
                    let label: String
                    if displayZ < -1.0 {
                        label = "dragging down"
                    } else if displayZ < -0.5 {
                        label = "below avg"
                    } else if displayZ > 1.0 {
                        label = "well above avg"
                    } else if displayZ > 0.5 {
                        label = "above avg"
                    } else {
                        label = "normal"
                    }
                    let padded = name.padding(toLength: 7, withPad: " ", startingAt: 0)
                    let zStr = String(format: "%+.1f\u{03C3}", displayZ).padding(toLength: 6, withPad: " ", startingAt: 0)
                    return "  \(padded) \(zStr)  \(label)\(arrow)"
                }

                if let l = metricLine("Stars", bd.starsZ, lowerIsBetter: false) { lines.append(l) }
                if let l = metricLine("PSFFlux", bd.psfFluxZ, lowerIsBetter: false) { lines.append(l) }
                if let l = metricLine("FWHM", bd.fwhmZ, lowerIsBetter: true) { lines.append(l) }
                if let l = metricLine("HFR", bd.hfrZ, lowerIsBetter: true) { lines.append(l) }
                if let l = metricLine("Noise", bd.noiseZ, lowerIsBetter: true) { lines.append(l) }
                if let l = metricLine("Trail", bd.trailingZ, lowerIsBetter: false) { lines.append(l) }
            }

            if let contrib = bd.snrContribution {
                lines.append("")
                lines.append("  SNR contribution: \(String(format: "%.0f", contrib))%")
            }

            let recommendation = bd.recommendationLabel
            if !recommendation.isEmpty {
                lines.append("")
                lines.append("  \u{2500}\u{2500} Recommendation \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}")
                // Bold the key action words (DELETE, KEEP, REVIEW)
                let boldRec = recommendation
                    .replacingOccurrences(of: "DELETE", with: boldText("DELETE"))
                    .replacingOccurrences(of: "KEEP", with: boldText("KEEP"))
                    .replacingOccurrences(of: "REVIEW", with: boldText("REVIEW"))
                lines.append("  \u{2192} \(boldRec)")
            }

            if let reasoning = bd.reasoningText, !reasoning.isEmpty {
                lines.append("")
                lines.append("  \u{2500}\u{2500} Why? \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}")
                lines.append("  \(reasoning)")
            }

            // Legend explaining z-scores and metrics
            lines.append("")
            lines.append("  \u{2500}\u{2500} Legend \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}")
            lines.append("  \u{03C3} = standard deviation from group average")
            lines.append("  +1.0\u{03C3} = one \u{03C3} better than average")
            lines.append("  -1.0\u{03C3} = one \u{03C3} worse than average")
            lines.append("  Stars  : detected star count (more = better)")
            lines.append("  FWHM   : star width in px (lower = sharper)")
            lines.append("  HFR    : half-flux radius (lower = tighter)")
            lines.append("  Noise  : background noise level (lower = cleaner)")
            lines.append("  Trail  : star elongation score (lower = rounder, penalty reduced for narrowband)")
            lines.append("  Group  : compared within same filter+target+exposure")

            return lines.joined(separator: "\n")
        }

        // Filename cell with tiny cache indicator checkmark
        private func makeFilenameCellWithCacheIndicator(entry: ImageEntry, isNight: Bool, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_filename_cached")
            let isCached = cachedURLs.contains(entry.url)

            let cellView: NSView
            let textField: NSTextField
            let indicator: NSTextField

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) {
                cellView = reused
                textField = reused.viewWithTag(100) as! NSTextField
                indicator = reused.viewWithTag(101) as! NSTextField
            } else {
                let container = NSView()
                container.identifier = identifier

                let ind = NSTextField(labelWithString: "")
                ind.translatesAutoresizingMaskIntoConstraints = false
                ind.font = .systemFont(ofSize: 9)
                ind.alignment = .center
                ind.tag = 101
                container.addSubview(ind)

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                tf.isSelectable = true
                tf.tag = 100
                container.addSubview(tf)

                NSLayoutConstraint.activate([
                    ind.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
                    ind.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    ind.widthAnchor.constraint(equalToConstant: 14),
                    tf.leadingAnchor.constraint(equalTo: ind.trailingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])

                cellView = container
                textField = tf
                indicator = ind
            }

            textField.stringValue = entry.filename
            // Update font for scale changes
            let scaledFilenameFont = round(12 * lastFontScale)
            if textField.font?.pointSize != scaledFilenameFont {
                textField.font = .monospacedSystemFont(ofSize: scaledFilenameFont, weight: .regular)
                indicator.font = .systemFont(ofSize: round(9 * lastFontScale))
            }

            // Status indicator: batch-modified > rotated > cached
            let isRotated = rotatedURLs.contains(entry.url)
            if entry.batchModified {
                indicator.stringValue = "\u{21C4}"  // Left-right arrow (batch modified)
                indicator.textColor = isNight ? NSColor(red: 0, green: 0, blue: 0.5, alpha: 1) : .systemBlue
                indicator.toolTip = "Modified by batch rename/header edit"
            } else if isCached && isRotated {
                indicator.stringValue = "\u{21BB}"  // Clockwise arrow (rotated indicator)
                indicator.textColor = isNight ? NSColor(red: 0.35, green: 0, blue: 0.2, alpha: 1) : .systemPurple
                indicator.toolTip = "Cached · AutoRotate applied"
            } else if isRotated {
                indicator.stringValue = "\u{21BB}"  // Clockwise arrow
                indicator.textColor = isNight ? NSColor(red: 0.35, green: 0, blue: 0.2, alpha: 1) : .systemPurple
                indicator.toolTip = "AutoRotate applied (aligned to reference frame)"
            } else if isCached {
                indicator.stringValue = "\u{2713}"  // Checkmark
                indicator.textColor = isNight ? NSColor(red: 0.4, green: 0, blue: 0, alpha: 1) : .systemGray
                indicator.toolTip = "Cached for instant display"
            } else {
                indicator.stringValue = ""
                indicator.toolTip = nil
            }

            // Color logic: marked rows get red text, but use white when selected
            let isSelected = tableView.selectedRowIndexes.contains(
                displayedImages.firstIndex(where: { $0.url == entry.url }) ?? -1
            )
            if isNight {
                textField.textColor = entry.isMarkedForDeletion
                    ? NSColor(red: 0.5, green: 0, blue: 0, alpha: 1)
                    : NSColor.systemRed
            } else if entry.isMarkedForDeletion && isSelected {
                textField.textColor = .white
            } else {
                textField.textColor = entry.isMarkedForDeletion ? .systemRed : .labelColor
            }

            return cellView
        }

        // Custom row view for all rows: fixes red-on-blue readability and night mode
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = TriageRowView()
            rowView.isNightMode = viewModel.nightMode
            if viewModel.nightMode {
                rowView.backgroundColor = row % 2 == 0
                    ? .black
                    : NSColor(red: 0.06, green: 0, blue: 0, alpha: 1)
            }
            return rowView
        }

        private func makeCheckboxCell(for row: Int, isMarked: Bool, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_marked")

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self),
               let button = reused.subviews.first as? NSButton {
                button.state = isMarked ? .on : .off
                button.tag = row
                return reused
            }

            let container = NSView()
            container.identifier = identifier

            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.state = isMarked ? .on : .off
            button.tag = row
            container.addSubview(button)

            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])

            return container
        }

        @objc private func checkboxToggled(_ sender: NSButton) {
            let row = sender.tag
            Task { @MainActor in
                if viewModel.hideMarked || viewModel.showOnlyMarked || !viewModel.filterText.isEmpty {
                    let visible = viewModel.visibleImages
                    guard row < visible.count else { return }
                    let url = visible[row].url
                    if let realIdx = viewModel.images.firstIndex(where: { $0.url == url }) {
                        viewModel.togglePreDelete(at: realIdx)
                    }
                } else {
                    viewModel.togglePreDelete(at: row)
                }
            }
        }

        // Track previously selected rows to refresh text colors on deselection
        private var previousSelectedRows = IndexSet()

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRows = tableView.selectedRowIndexes

            // Update text color for rows that changed selection state.
            // Only marked rows need color updates (white when selected, red when deselected).
            // Use lightweight textColor update instead of reloadData to avoid stutter during
            // rapid arrow key navigation (reloadData rebuilds entire cell views).
            let deselected = previousSelectedRows.subtracting(selectedRows)
            let newlySelected = selectedRows.subtracting(previousSelectedRows)
            let changed = deselected.union(newlySelected)
            if !changed.isEmpty {
                let isNight = viewModel.nightMode
                for row in changed where row >= 0 && row < displayedImages.count {
                    let entry = displayedImages[row]
                    let isSelected = selectedRows.contains(row)
                    // Update text color on all visible cells for this row
                    for col in 0..<tableView.numberOfColumns {
                        if let cellView = tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? NSTableCellView {
                            if isNight {
                                cellView.textField?.textColor = entry.isMarkedForDeletion
                                    ? NSColor(red: 0.5, green: 0, blue: 0, alpha: 1)
                                    : NSColor.systemRed
                            } else if entry.isMarkedForDeletion && isSelected {
                                cellView.textField?.textColor = .white
                            } else {
                                cellView.textField?.textColor = entry.isMarkedForDeletion ? .systemRed : .labelColor
                            }
                        }
                    }
                }
            }
            previousSelectedRows = selectedRows

            // Track selected indices in ViewModel for Quick Stack and other multi-select operations
            viewModel.selectedTableIndices = selectedRows

            // Determine which row to display: for multi-select (shift+click/arrow),
            // show the image at the cursor position (the row the user just navigated to).
            // For single select, show the selected row as before.
            let targetRow: Int
            if selectedRows.count == 1, let row = selectedRows.first {
                targetRow = row
            } else if selectedRows.count > 1 {
                if !newlySelected.isEmpty, let newest = newlySelected.last {
                    // Selection is growing — show the most recently added row
                    targetRow = newest
                } else if !deselected.isEmpty, let removed = deselected.max(),
                          let first = selectedRows.first, let last = selectedRows.last {
                    // Selection is shrinking (shift+arrow back toward anchor) —
                    // show whichever selection end is closest to the removed row
                    targetRow = abs(removed - last) < abs(removed - first) ? last : first
                } else if let last = selectedRows.last {
                    targetRow = last
                } else {
                    return
                }
            } else {
                return
            }

            Task { @MainActor in
                if viewModel.hideMarked || viewModel.showOnlyMarked || !viewModel.filterText.isEmpty {
                    let visible = viewModel.visibleImages
                    guard targetRow < visible.count else { return }
                    let url = visible[targetRow].url
                    if let realIdx = viewModel.images.firstIndex(where: { $0.url == url }) {
                        if realIdx != viewModel.selectedIndex {
                            viewModel.selectImage(at: realIdx)
                        }
                    }
                } else if targetRow != viewModel.selectedIndex {
                    viewModel.selectImage(at: targetRow)
                }
            }
        }

        // MARK: - Right-Click Context Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()

            guard let tableView = tableView else { return }
            let clickedRow = tableView.clickedRow
            guard clickedRow >= 0, clickedRow < displayedImages.count else { return }

            let entry = displayedImages[clickedRow]

            let copyFilename = NSMenuItem(title: "Copy Filename", action: #selector(copyFilename(_:)), keyEquivalent: "")
            copyFilename.target = self
            copyFilename.representedObject = entry.filename
            menu.addItem(copyFilename)

            let copyPath = NSMenuItem(title: "Copy File Path", action: #selector(copyFilePath(_:)), keyEquivalent: "")
            copyPath.target = self
            copyPath.representedObject = entry.url.deletingLastPathComponent().path
            menu.addItem(copyPath)

            let copyFullPath = NSMenuItem(title: "Copy Full Path + Filename", action: #selector(copyFullPath(_:)), keyEquivalent: "")
            copyFullPath.target = self
            copyFullPath.representedObject = entry.url.path
            menu.addItem(copyFullPath)

            menu.addItem(NSMenuItem.separator())

            // Show in Finder
            let showInFinder = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
            showInFinder.target = self
            showInFinder.representedObject = entry.url
            menu.addItem(showInFinder)

            // Open With submenu
            let openWithMenu = NSMenu(title: "Open With...")
            let fileURL = entry.url

            // Get apps that can open this file type
            if let uti = UTType(filenameExtension: fileURL.pathExtension) {
                let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                let sortedApps = appURLs
                    .compactMap { url -> (name: String, url: URL)? in
                        let name = url.deletingPathExtension().lastPathComponent
                        return (name, url)
                    }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                for app in sortedApps {
                    let item = NSMenuItem(title: app.name, action: #selector(openWithApp(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = (fileURL, app.url)
                    if let icon = NSWorkspace.shared.icon(forFile: app.url.path) as NSImage? {
                        icon.size = NSSize(width: 16, height: 16)
                        item.image = icon
                    }
                    openWithMenu.addItem(item)
                }
            }

            if openWithMenu.items.isEmpty {
                let noApps = NSMenuItem(title: "No compatible apps found", action: nil, keyEquivalent: "")
                noApps.isEnabled = false
                openWithMenu.addItem(noApps)
            }

            let openWithItem = NSMenuItem(title: "Open With...", action: nil, keyEquivalent: "")
            openWithItem.submenu = openWithMenu
            menu.addItem(openWithItem)

            // Compare with Best (only if quality tier exists and is not excellent)
            if let tier = entry.qualityTier, tier != .excellent {
                let compareItem = NSMenuItem(title: "Compare with Best", action: #selector(compareWithBest(_:)), keyEquivalent: "")
                compareItem.target = self
                compareItem.tag = clickedRow
                menu.addItem(compareItem)
            }

            // Quality Feedback submenu (only when frame has quality score)
            if entry.qualityTier != nil {
                let feedbackMenu = NSMenu(title: "Quality Feedback")

                let agreeItem = NSMenuItem(title: "Agree", action: #selector(setFeedbackAgree(_:)), keyEquivalent: "")
                agreeItem.target = self
                agreeItem.tag = clickedRow
                agreeItem.image = Self.feedbackIcon(for: .agree)
                if entry.qualityFeedback == .agree { agreeItem.state = .on }
                feedbackMenu.addItem(agreeItem)

                let disagreeItem = NSMenuItem(title: "Disagree", action: #selector(setFeedbackDisagree(_:)), keyEquivalent: "")
                disagreeItem.target = self
                disagreeItem.tag = clickedRow
                disagreeItem.image = Self.feedbackIcon(for: .disagree)
                if entry.qualityFeedback == .disagree { disagreeItem.state = .on }
                feedbackMenu.addItem(disagreeItem)

                let partlyItem = NSMenuItem(title: "Partly Agree", action: #selector(setFeedbackPartly(_:)), keyEquivalent: "")
                partlyItem.target = self
                partlyItem.tag = clickedRow
                partlyItem.image = Self.feedbackIcon(for: .partly)
                if entry.qualityFeedback == .partly { partlyItem.state = .on }
                feedbackMenu.addItem(partlyItem)

                feedbackMenu.addItem(NSMenuItem.separator())

                let clearItem = NSMenuItem(title: "Clear Feedback", action: #selector(clearFeedback(_:)), keyEquivalent: "")
                clearItem.target = self
                clearItem.tag = clickedRow
                clearItem.isEnabled = entry.qualityFeedback != .none
                feedbackMenu.addItem(clearItem)

                let feedbackMenuItem = NSMenuItem(title: "Quality Feedback", action: nil, keyEquivalent: "")
                feedbackMenuItem.submenu = feedbackMenu
                menu.addItem(feedbackMenuItem)
            }

            // Golden Set curation submenu — the human's ground-truth verdict for building a
            // calibration set. Available for ALL frames (even unscored dark/dome frames).
            let goldenMenu = NSMenu(title: "Golden Set")
            let goodItem = NSMenuItem(title: GoldenLabel.good.displayName,
                                      action: #selector(setGoldenLabelFromMenu(_:)), keyEquivalent: "")
            goodItem.target = self; goodItem.tag = clickedRow; goodItem.representedObject = GoldenLabel.good.rawValue
            goodItem.image = Self.goldenIcon(for: .good)
            if entry.goldenLabel == .good { goodItem.state = .on }
            goldenMenu.addItem(goodItem)
            goldenMenu.addItem(NSMenuItem.separator())
            for label: GoldenLabel in [.trailing, .cloud, .gradient, .defocus, .lowSNR, .darkFrame, .badStar] {
                let it = NSMenuItem(title: label.displayName,
                                    action: #selector(setGoldenLabelFromMenu(_:)), keyEquivalent: "")
                it.target = self; it.tag = clickedRow; it.representedObject = label.rawValue
                it.image = Self.goldenIcon(for: label)
                if entry.goldenLabel == label { it.state = .on }
                goldenMenu.addItem(it)
            }
            goldenMenu.addItem(NSMenuItem.separator())
            let clearGolden = NSMenuItem(title: "Clear Golden Label",
                                         action: #selector(setGoldenLabelFromMenu(_:)), keyEquivalent: "")
            clearGolden.target = self; clearGolden.tag = clickedRow; clearGolden.representedObject = GoldenLabel.none.rawValue
            clearGolden.isEnabled = entry.goldenLabel != .none
            goldenMenu.addItem(clearGolden)
            let goldenMenuItem = NSMenuItem(title: "Golden Set", action: nil, keyEquivalent: "")
            goldenMenuItem.submenu = goldenMenu
            menu.addItem(goldenMenuItem)

            menu.addItem(NSMenuItem.separator())

            // Mark/Unmark option
            let markTitle = entry.isMarkedForDeletion ? "Unmark" : "Mark for Deletion"
            let markItem = NSMenuItem(title: markTitle, action: #selector(toggleMarkFromMenu(_:)), keyEquivalent: "")
            markItem.target = self
            markItem.tag = clickedRow
            menu.addItem(markItem)
        }

        @objc private func copyFilename(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func copyFilePath(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        // Double-click: open image in a floating preview window with stretch controls
        @objc func tableViewDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < displayedImages.count else { return }
            let entry = displayedImages[row]
            Task { @MainActor in
                guard let device = viewModel.renderer?.device else { return }
                ImagePreviewWindowController.open(
                    entry: entry,
                    device: device,
                    nightMode: viewModel.nightMode,
                    debayerEnabled: viewModel.debayerEnabled
                )
            }
        }

        @objc private func copyFullPath(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func compareWithBest(_ sender: NSMenuItem) {
            let row = sender.tag
            guard row >= 0, row < displayedImages.count else { return }
            let entry = displayedImages[row]
            Task { @MainActor in
                guard let device = viewModel.renderer?.device else { return }
                // Find the best image in the same group (target + filter + exposure)
                let targetKey = (entry.target ?? "").trimmingCharacters(in: .whitespaces)
                let filterKey = (entry.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                let expKey = entry.exposure.map { Int($0.rounded()) } ?? 0

                let groupImages = viewModel.images.filter { img in
                    let t = (img.target ?? "").trimmingCharacters(in: .whitespaces)
                    let f = (img.filter ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                    let e = img.exposure.map { Int($0.rounded()) } ?? 0
                    return t == targetKey && f == filterKey && e == expKey
                }

                // Find the one with the highest quality z-score (fine-grained, matches TriageViewModel)
                let best = groupImages.max { a, b in
                    (a.qualityZScore ?? -100) < (b.qualityZScore ?? -100)
                }

                guard let bestEntry = best, bestEntry.url != entry.url else { return }

                CompareWindowController.open(
                    selectedEntry: entry,
                    bestEntry: bestEntry,
                    device: device,
                    nightMode: viewModel.nightMode,
                    debayerEnabled: viewModel.debayerEnabled,
                    rotateSelected: viewModel.shouldRotateForMeridian(entry),
                    rotateBest: viewModel.shouldRotateForMeridian(bestEntry)
                )
            }
        }

        @objc private func showInFinder(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc private func openWithApp(_ sender: NSMenuItem) {
            guard let pair = sender.representedObject as? (URL, URL) else { return }
            let (fileURL, appURL) = pair
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }

        @objc private func toggleMarkFromMenu(_ sender: NSMenuItem) {
            let row = sender.tag
            Task { @MainActor in
                if viewModel.hideMarked || viewModel.showOnlyMarked || !viewModel.filterText.isEmpty {
                    let visible = viewModel.visibleImages
                    guard row < visible.count else { return }
                    let url = visible[row].url
                    if let realIdx = viewModel.images.firstIndex(where: { $0.url == url }) {
                        viewModel.togglePreDelete(at: realIdx)
                    }
                } else {
                    viewModel.togglePreDelete(at: row)
                }
            }
        }

        // MARK: - Quality Feedback Context Menu Actions

        @objc private func setFeedbackAgree(_ sender: NSMenuItem) {
            applyFeedback(.agree, row: sender.tag)
        }
        @objc private func setFeedbackDisagree(_ sender: NSMenuItem) {
            applyFeedback(.disagree, row: sender.tag)
        }
        @objc private func setFeedbackPartly(_ sender: NSMenuItem) {
            applyFeedback(.partly, row: sender.tag)
        }
        @objc private func clearFeedback(_ sender: NSMenuItem) {
            applyFeedback(.none, row: sender.tag)
        }

        // MARK: - Golden Set Context Menu Action

        @objc private func setGoldenLabelFromMenu(_ sender: NSMenuItem) {
            let label = GoldenLabel(rawValue: (sender.representedObject as? Int) ?? 0) ?? .none
            applyGolden(label, row: sender.tag)
        }

        /// Apply a golden label to the clicked row (or the whole selection if the clicked row is
        /// part of it), mapping visible→real indices when the list is filtered. Mirrors applyFeedback
        /// but routes through the session-transient setGoldenLabel (no DB side effects).
        private func applyGolden(_ label: GoldenLabel, row: Int) {
            guard let tableView = tableView else { return }
            let selectedRows = tableView.selectedRowIndexes
            let targetRows = selectedRows.contains(row) ? selectedRows : IndexSet(integer: row)
            Task { @MainActor in
                let isFiltered = viewModel.hideMarked || viewModel.showOnlyMarked || !viewModel.filterText.isEmpty
                let realIndices: IndexSet
                if isFiltered {
                    let visible = viewModel.visibleImages
                    var ri = IndexSet()
                    for r in targetRows where r < visible.count {
                        if let idx = viewModel.images.firstIndex(where: { $0.url == visible[r].url }) { ri.insert(idx) }
                    }
                    realIndices = ri
                } else {
                    realIndices = targetRows
                }
                viewModel.setGoldenLabel(label, forRows: realIndices)
            }
        }

        /// SF Symbol for a golden label (menu + badge cell). Shared so both stay in sync.
        static func goldenIcon(for label: GoldenLabel) -> NSImage? {
            let name: String
            switch label {
            case .none:      return nil
            case .good:      name = "star.fill"
            case .trailing:  name = "line.diagonal"
            case .cloud:     name = "cloud.fill"
            case .gradient:  name = "sun.horizon.fill"
            case .defocus:   name = "circle.dashed"
            case .lowSNR:    name = "chart.line.downtrend.xyaxis"
            case .darkFrame: name = "moon.fill"
            case .badStar:   name = "sparkle"
            }
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label.displayName) else { return nil }
            return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        }

        static func goldenTint(for label: GoldenLabel) -> NSColor? {
            switch label {
            case .none:      return nil
            case .good:      return .systemYellow   // gold star = keeper
            default:         return .systemRed      // any defect = bad
            }
        }

        /// Badge cell for the hideable "GS" (golden-label) column. Clones makeFeedbackCell.
        private func makeGoldenCell(for entry: ImageEntry, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_goldenLabel")
            let cellView: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cellView = reused
            } else {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 14),
                    imageView.heightAnchor.constraint(equalToConstant: 14),
                    imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                cellView = cell
            }
            cellView.toolTip = entry.goldenLabel == .none ? "No golden label (right-click → Golden Set)" : "Golden: \(entry.goldenLabel.displayName)"
            cellView.imageView?.image = Self.goldenIcon(for: entry.goldenLabel)
            cellView.imageView?.contentTintColor = Self.goldenTint(for: entry.goldenLabel)
            return cellView
        }

        private func applyFeedback(_ feedback: QualityFeedback, row: Int) {
            guard let tableView = tableView else { return }
            let selectedRows = tableView.selectedRowIndexes
            // If clicked row is in selection, apply to all selected; otherwise just clicked row
            let targetRows = selectedRows.contains(row) ? selectedRows : IndexSet(integer: row)

            Task { @MainActor in
                let isFiltered = viewModel.hideMarked || viewModel.showOnlyMarked || !viewModel.filterText.isEmpty
                if isFiltered {
                    let visible = viewModel.visibleImages
                    var realIndices = IndexSet()
                    for r in targetRows where r < visible.count {
                        if let realIdx = viewModel.images.firstIndex(where: { $0.url == visible[r].url }) {
                            realIndices.insert(realIdx)
                        }
                    }
                    if feedback == .none {
                        // Clear: set to none directly
                        for idx in realIndices where idx >= 0 && idx < viewModel.images.count {
                            viewModel.images[idx].qualityFeedback = .none
                            if let hash = viewModel.images[idx].fileHash {
                                try? FrameHistoryDatabase.shared.updateQualityFeedback(fileHash: hash, feedback: 0)
                            }
                        }
                        viewModel.needsTableRefresh = true
                    } else {
                        viewModel.setQualityFeedback(feedback, forRows: realIndices)
                    }
                } else {
                    if feedback == .none {
                        for idx in targetRows where idx >= 0 && idx < viewModel.images.count {
                            viewModel.images[idx].qualityFeedback = .none
                            if let hash = viewModel.images[idx].fileHash {
                                try? FrameHistoryDatabase.shared.updateQualityFeedback(fileHash: hash, feedback: 0)
                            }
                        }
                        viewModel.needsTableRefresh = true
                    } else {
                        viewModel.setQualityFeedback(feedback, forRows: targetRows)
                    }
                }
            }
        }

        // MARK: - Column-Order Sorting

        @objc func columnDidMove(_ notification: Notification) {
            guard let tableView = tableView else { return }

            let columnIds = (0..<tableView.numberOfColumns).compactMap { i in
                tableView.tableColumns[i].identifier.rawValue
            }

            // Persist column order
            AppSettings.saveStrings(columnIds, for: .columnOrder)

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.viewModel.applySortByColumnOrder(columnIds)
                tableView.reloadData()

                let idx = self.viewModel.selectedIndex
                if idx >= 0 && idx < self.viewModel.images.count {
                    tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    tableView.scrollRowToVisible(idx)
                }
            }
        }

        // MARK: - Column Visibility Toggle (header right-click menu)

        @objc func toggleColumnVisibility(_ sender: NSMenuItem) {
            guard let tableView = tableView,
                  let colId = sender.representedObject as? String else { return }

            let identifier = NSUserInterfaceItemIdentifier(colId)

            if let existingCol = tableView.tableColumns.first(where: { $0.identifier == identifier }) {
                // Column is visible → remove it
                tableView.removeTableColumn(existingCol)
                sender.state = .off
            } else {
                // Column is hidden → add it back
                guard let colDef = ColumnDefinition.allColumns.first(where: { $0.identifier == colId }) else { return }
                let column = NSTableColumn(identifier: identifier)
                column.title = colDef.title
                column.headerToolTip = ColumnDefinition.headerToolTip(for: colDef.identifier)
                column.width = colDef.defaultWidth
                column.minWidth = colDef.minWidth
                column.sortDescriptorPrototype = NSSortDescriptor(key: colDef.identifier, ascending: true)
                column.resizingMask = .userResizingMask
                tableView.addTableColumn(column)
                sender.state = .on
            }

            // Persist current visible columns
            let visibleIds = tableView.tableColumns.map { $0.identifier.rawValue }
            AppSettings.saveStrings(visibleIds, for: .visibleColumns)

            tableView.reloadData()
        }

        // MARK: - Click-to-Sort (ascending/descending toggle)

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let descriptors = tableView.sortDescriptors
            guard !descriptors.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.viewModel.applySortDescriptors(descriptors)
                tableView.reloadData()

                let idx = self.viewModel.selectedIndex
                if idx >= 0 && idx < self.viewModel.images.count {
                    tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    tableView.scrollRowToVisible(idx)
                }
            }
        }
    }
}

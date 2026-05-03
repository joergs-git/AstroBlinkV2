// Right-side panel of the Target Catalog browser. Shows a single deep-sky
// target with metadata, alt/az curves, weather forecast, and FOV simulation.
// Hover-card and inline charts live here too.
import SwiftUI
import AppKit
import Charts

// MARK: - Detail View

struct TargetDetailView: View {
    let target: TargetCatalogService.CatalogTarget
    @ObservedObject var viewModel: TargetDatabaseViewModel
    let nightMode: Bool
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            // "Part of" — show parent complex if this is a sub-target
            if let parent = TargetCatalog.majorTarget(target.canonicalName) {
                partOfSection(parent: parent)
            }
            // "Sub-targets" — show children if this target has known sub-targets
            let children = TargetCatalog.subTargets(of: target.canonicalName)
            if !children.isEmpty {
                subTargetsSection(children: children)
            }
            Divider().background(AppColors.divider(nightMode))
            coordinatesSection
            Divider().background(AppColors.divider(nightMode))
            visibilitySection
            Divider().background(AppColors.divider(nightMode))
            sizeAndFOVSection
            Divider().background(AppColors.divider(nightMode))
            photometrySection
            Divider().background(AppColors.divider(nightMode))
            filterSection
            if viewModel.targetHistory[target.canonicalName] != nil {
                Divider().background(AppColors.divider(nightMode))
                historySection
            }
            if let desc = target.description ?? target.imagingNotes {
                Divider().background(AppColors.divider(nightMode))
                notesSection(desc)
            }
            if let aliases = target.aliases, !aliases.isEmpty {
                Divider().background(AppColors.divider(nightMode))
                aliasSection(aliases)
            }
            scoringWeightsSection
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                // DSS thumbnail — enlarges on hover
                ZoomableDSSThumbnail(url: target.dssThumbnailURL)

                VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(target.canonicalName)
                    .font(.system(size: 22 * fontScale, weight: .bold, design: .monospaced))
                    .foregroundColor(AppColors.fg(nightMode))

                if viewModel.sessionTargets.contains(target.canonicalName) {
                    Text("IN SESSION")
                        .font(.system(size: 9 * fontScale, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppColors.accent(nightMode))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }

            if let common = target.commonName {
                Text(common)
                    .font(.system(size: 15 * fontScale))
                    .foregroundColor(AppColors.fgDim(nightMode))
            }

            HStack(spacing: 8) {
                // Type badge
                let (icon, color) = typeIconInfo(target.targetType)
                Label(target.typeDisplayName, systemImage: icon)
                    .font(.system(size: 11 * fontScale, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((nightMode ? Color.red : color).opacity(0.15))
                    .foregroundColor(nightMode ? .red : color)
                    .cornerRadius(8)

                // Difficulty badge
                if let diff = target.difficulty {
                    Text(diff.capitalized)
                        .font(.system(size: 10 * fontScale, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(difficultyColor(diff).opacity(0.15))
                        .foregroundColor(difficultyColor(diff))
                        .cornerRadius(6)
                }
            }
                } // inner VStack (text content)
            } // HStack (thumbnail + text)
        }
    }

    // MARK: - Coordinates

    private var coordinatesSection: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RA").font(.system(size: 10 * fontScale, weight: .medium)).foregroundColor(AppColors.fgDim(nightMode))
                Text(formatRA(target.raJ2000))
                    .font(.system(size: 13 * fontScale, design: .monospaced))
                    .foregroundColor(AppColors.fg(nightMode))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Dec").font(.system(size: 10 * fontScale, weight: .medium)).foregroundColor(AppColors.fgDim(nightMode))
                Text(formatDec(target.decJ2000))
                    .font(.system(size: 13 * fontScale, design: .monospaced))
                    .foregroundColor(AppColors.fg(nightMode))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Constellation").font(.system(size: 10 * fontScale, weight: .medium)).foregroundColor(AppColors.fgDim(nightMode))
                Text(target.constellation)
                    .font(.system(size: 13 * fontScale, weight: .medium))
                    .foregroundColor(AppColors.fg(nightMode))
            }
            Spacer()
        }
    }

    // MARK: - Visibility Chart

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tonight's Visibility")
                .font(.system(size: 12 * fontScale, weight: .semibold))
                .foregroundColor(AppColors.fg(nightMode))

            if let info = viewModel.tonightVisibility[target.canonicalName] {
                HStack(spacing: 16) {
                    Label("Max: \(Int(info.maxAltitude))°", systemImage: "arrow.up")
                    Label(String(format: "%.1fh above 30°", info.hoursAbove30), systemImage: "clock")
                    let formatter = DateFormatter()
                    let _ = formatter.dateFormat = "HH:mm"
                    Label("Transit: \(formatter.string(from: info.transitTime))", systemImage: "sun.max")
                    if let moonDist = viewModel.moonDistance[target.canonicalName] {
                        Label(String(format: "Moon: %d° away (%d%%)", Int(moonDist), Int(viewModel.moonIllumination * 100)),
                              systemImage: "moon.fill")
                            .foregroundColor(moonDist < 30 ? .red.opacity(0.8) :
                                             moonDist < 60 ? AppColors.orange(nightMode) :
                                             AppColors.fgDim(nightMode))
                    }
                }
                .font(.system(size: 11 * fontScale))
                .foregroundColor(AppColors.fgDim(nightMode))

                // Altitude chart with moon altitude overlay
                if !info.curve.isEmpty {
                    visibilityChart(info.curve, moonCurve: viewModel.moonAltitudeCurve)
                        .frame(height: 140)
                }
            } else if viewModel.observerLocation == nil {
                Text("Load a session with SITELAT/SITELONG headers to enable visibility")
                    .font(.system(size: 11 * fontScale))
                    .foregroundColor(AppColors.fgVeryDim(nightMode))
            } else {
                Text("Computing...")
                    .font(.system(size: 11 * fontScale))
                    .foregroundColor(AppColors.fgVeryDim(nightMode))
            }
        }
    }

    private func visibilityChart(_ curve: [AltAzCalculator.VisibilityPoint],
                                  moonCurve: [AltAzCalculator.VisibilityPoint] = []) -> some View {
        Chart {
            // Green zone: above 30°
            RuleMark(y: .value("Good", 30))
                .foregroundStyle(AppColors.green(nightMode).opacity(0.3))
                .lineStyle(StrokeStyle(dash: [4, 4]))

            // Target altitude area fill
            ForEach(curve) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    yStart: .value("Base", 0),
                    yEnd: .value("Altitude", max(0, point.altitude))
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [AppColors.accent(nightMode).opacity(0.15), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }

            // Target altitude line
            ForEach(curve) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Altitude", max(0, point.altitude)),
                    series: .value("Series", "Target")
                )
                .foregroundStyle(AppColors.accent(nightMode))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // Moon altitude line (dashed, yellow/gray)
            ForEach(moonCurve) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Altitude", max(0, point.altitude)),
                    series: .value("Series", "Moon")
                )
                .foregroundStyle(nightMode ? Color.red.opacity(0.4) : Color.yellow.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }

            // Current time marker (red dot on target curve + vertical rule)
            let now = Date()
            if let nearest = curve.min(by: { Swift.abs($0.time.timeIntervalSince(now)) < Swift.abs($1.time.timeIntervalSince(now)) }),
               Swift.abs(nearest.time.timeIntervalSince(now)) < 1800 { // within 30 min of chart range
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("Time", nearest.time),
                    y: .value("Altitude", max(0, nearest.altitude))
                )
                .foregroundStyle(.red)
                .symbolSize(50)
            }
        }
        .chartYScale(domain: 0...90)
        .chartYAxis {
            AxisMarks(values: [0, 15, 30, 45, 60, 75, 90]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppColors.chartGrid(nightMode))
                AxisValueLabel()
                    .font(.system(size: 9 * fontScale))
                    .foregroundStyle(AppColors.fgVeryDim(nightMode))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppColors.chartGrid(nightMode))
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: 9 * fontScale))
                    .foregroundStyle(AppColors.fgVeryDim(nightMode))
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.background(AppColors.chartBg(nightMode))
        }
    }

    // MARK: - Size & FOV

    private var sizeAndFOVSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Angular size
            if let major = target.angularSizeMajor, let minor = target.angularSizeMinor {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Angular Size")
                            .font(.system(size: 10 * fontScale, weight: .medium))
                            .foregroundColor(AppColors.fgDim(nightMode))
                        Text("\(formatArcmin(major)) x \(formatArcmin(minor))")
                            .font(.system(size: 13 * fontScale, design: .monospaced))
                            .foregroundColor(AppColors.fg(nightMode))
                    }

                    // Proportional rectangle visualization
                    fovVisualization(targetMajor: major, targetMinor: minor)
                }
            }

            // FOV simulation with selected equipment
            if let setup = viewModel.currentSetup,
               let fov = viewModel.fovArcmin(setup: setup),
               let major = target.angularSizeMajor, let minor = target.angularSizeMinor {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FOV with \(viewModel.setupDisplayName(for: setup))")
                        .font(.system(size: 10 * fontScale, weight: .medium))
                        .foregroundColor(AppColors.fgDim(nightMode))

                    fovSimulation(targetMajor: major, targetMinor: minor,
                                  fovWidth: fov.width, fovHeight: fov.height)

                    if let fl = setup.focalLength, let px = setup.pixelSize {
                        Text(String(format: "%.2f\"/px  •  FOV: %.0f' x %.0f'", 206.265 * px / fl, fov.width, fov.height))
                            .font(.system(size: 10 * fontScale, design: .monospaced))
                            .foregroundColor(AppColors.fgVeryDim(nightMode))
                    }
                }
            }

            // FL recommendation
            if let minFL = target.minFocalLength, let maxFL = target.maxFocalLength {
                Text("Recommended FL: \(Int(minFL))–\(Int(maxFL)) mm")
                    .font(.system(size: 11 * fontScale))
                    .foregroundColor(AppColors.fgDim(nightMode))
            }
        }
    }

    private func fovVisualization(targetMajor: Double, targetMinor: Double) -> some View {
        let maxDim: CGFloat = 60
        let ratio = CGFloat(targetMinor / targetMajor)
        let w = maxDim
        let h = maxDim * ratio
        return RoundedRectangle(cornerRadius: 2)
            .stroke(AppColors.accent(nightMode), lineWidth: 1.5)
            .frame(width: w, height: max(h, 4))
            .overlay(
                Text(formatSize(targetMajor, targetMinor))
                    .font(.system(size: 8 * fontScale))
                    .foregroundColor(AppColors.fgVeryDim(nightMode))
            )
    }

    private func fovSimulation(targetMajor: Double, targetMinor: Double,
                               fovWidth: Double, fovHeight: Double) -> some View {
        let boxSize: CGFloat = 100
        let scaleX = boxSize / CGFloat(fovWidth)
        let scaleY = boxSize / CGFloat(fovHeight)
        let scale = min(scaleX, scaleY)

        let sensorW = CGFloat(fovWidth) * scale
        let sensorH = CGFloat(fovHeight) * scale
        let targetW = CGFloat(targetMajor) * scale
        let targetH = CGFloat(targetMinor) * scale

        return ZStack {
            // Sensor FOV (outer)
            Rectangle()
                .stroke(AppColors.fgDim(nightMode), lineWidth: 1)
                .frame(width: sensorW, height: sensorH)

            // Target extent (inner)
            Ellipse()
                .stroke(AppColors.accent(nightMode), lineWidth: 1.5)
                .frame(width: max(targetW, 2), height: max(targetH, 2))

            // Fill ratio text
            let fill = (targetMajor * targetMinor) / (fovWidth * fovHeight) * 100
            Text(String(format: "%.0f%% fill", min(fill, 100)))
                .font(.system(size: 9 * fontScale))
                .foregroundColor(AppColors.fgVeryDim(nightMode))
                .offset(y: sensorH / 2 + 8)
        }
        .frame(width: boxSize + 20, height: boxSize + 24)
    }

    // MARK: - Photometry

    private var photometrySection: some View {
        HStack(spacing: 24) {
            if let mag = target.magnitudeV {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mag V").font(.system(size: 10 * fontScale, weight: .medium)).foregroundColor(AppColors.fgDim(nightMode))
                    Text(String(format: "%.1f", mag))
                        .font(.system(size: 13 * fontScale, design: .monospaced))
                        .foregroundColor(AppColors.fg(nightMode))
                }
            }
            if let sb = target.surfaceBrightness {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Surface Brightness").font(.system(size: 10 * fontScale, weight: .medium)).foregroundColor(AppColors.fgDim(nightMode))
                    Text(String(format: "%.1f mag/arcsec²", sb))
                        .font(.system(size: 13 * fontScale, design: .monospaced))
                        .foregroundColor(AppColors.fg(nightMode))
                }
            }
            if let minH = target.minIntegrationHours {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Est. Min Integration").font(.system(size: 10 * fontScale, weight: .medium)).foregroundColor(AppColors.fgDim(nightMode))
                    Text(String(format: "~%.0fh+", minH))
                        .font(.system(size: 13 * fontScale, design: .monospaced))
                        .foregroundColor(AppColors.fg(nightMode))
                        .help("Rough estimate based on surface brightness and difficulty. Actual time depends on your f-ratio, Bortle class, and camera sensitivity.")
                }
            }
            Spacer()
        }
    }

    // MARK: - Filter Recommendations

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter Recommendations")
                .font(.system(size: 12 * fontScale, weight: .semibold))
                .foregroundColor(AppColors.fg(nightMode))

            if let primary = target.primaryFilter {
                filterSetView(primary, label: "Primary")
            }
            if let secondary = target.secondaryFilter {
                filterSetView(secondary, label: "Secondary")
            }
            if let notes = target.filterNotes {
                Text(notes)
                    .font(.system(size: 11 * fontScale).italic())
                    .foregroundColor(AppColors.fgDim(nightMode))
            }
        }
    }

    private func filterSetView(_ filter: TargetCatalogService.FilterInfo, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10 * fontScale, weight: .medium))
                .foregroundColor(AppColors.fgDim(nightMode))

            HStack(spacing: 4) {
                // Filter chips with ratio bars
                let totalRatio = filter.ratios.values.reduce(0, +)
                let order = ["L", "R", "G", "B", "Ha", "OIII", "SII", "Hbeta", "NII"]
                let sorted = filter.ratios.sorted { a, b in
                    let ia = order.firstIndex(of: a.key) ?? 99
                    let ib = order.firstIndex(of: b.key) ?? 99
                    return ia < ib
                }
                ForEach(sorted, id: \.key) { entry in
                    let proportion = CGFloat(entry.value) / CGFloat(max(totalRatio, 1))
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(filterColor(entry.key, nightMode: nightMode))
                            .frame(width: max(proportion * 80, 12), height: 16)
                            .overlay(
                                Text("\(entry.value)")
                                    .font(.system(size: 9 * fontScale, weight: .bold))
                                    .foregroundColor(.white)
                            )
                        Text(entry.key)
                            .font(.system(size: 9 * fontScale))
                            .foregroundColor(AppColors.fgDim(nightMode))
                    }
                }
            }
        }
    }

    // MARK: - Your Imaging History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Imaging History")
                .font(.system(size: 12 * fontScale, weight: .semibold))
                .foregroundColor(AppColors.fg(nightMode))

            if let history = viewModel.targetHistory[target.canonicalName] {
                // Summary line
                HStack(spacing: 16) {
                    Label(String(format: "%.1fh total", history.totalHours), systemImage: "clock")
                    Label("\(history.sessionCount) sessions", systemImage: "calendar")
                    if let last = history.lastImaged {
                        Label("Last: \(last)", systemImage: "clock.arrow.circlepath")
                    }
                }
                .font(.system(size: 11 * fontScale))
                .foregroundColor(AppColors.fgDim(nightMode))

                // Per-filter hours
                HStack(spacing: 8) {
                    ForEach(history.perFilterHours.sorted(by: { $0.key < $1.key }), id: \.key) { filter, hours in
                        VStack(spacing: 2) {
                            Text(String(format: "%.1fh", hours))
                                .font(.system(size: 11 * fontScale, weight: .medium, design: .monospaced))
                                .foregroundColor(AppColors.fg(nightMode))
                            Text(filter)
                                .font(.system(size: 9 * fontScale))
                                .foregroundColor(filterColor(filter, nightMode: nightMode))
                        }
                    }
                }

                // Quality
                if let fwhm = history.medianFWHM {
                    Text(String(format: "Median FWHM: %.1f px", fwhm))
                        .font(.system(size: 10 * fontScale))
                        .foregroundColor(AppColors.fgDim(nightMode))
                }

                // Filter gap analysis
                if let gap = viewModel.filterGapAnalysis(target: target) {
                    filterGapView(gap)
                }
            }
        }
    }

    private func filterGapView(_ gap: FilterGapResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(gap.filters, id: \.filter) { status in
                HStack(spacing: 6) {
                    Text(status.filter)
                        .font(.system(size: 10 * fontScale, weight: .medium))
                        .foregroundColor(filterColor(status.filter, nightMode: nightMode))
                        .frame(width: 35, alignment: .trailing)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppColors.bgControl(nightMode))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(gapLevelColor(status.level))
                                .frame(width: geo.size.width * min(CGFloat(status.completion), 1.0))
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.1fh / %.1fh", status.actualHours, status.expectedHours))
                        .font(.system(size: 9 * fontScale, design: .monospaced))
                        .foregroundColor(AppColors.fgDim(nightMode))
                        .frame(width: 80, alignment: .trailing)
                }
            }

            if let worst = gap.worstGap, worst.level == .gap {
                Text("Need ~\(String(format: "%.1f", worst.gapHours))h more \(worst.filter)")
                    .font(.system(size: 11 * fontScale, weight: .medium))
                    .foregroundColor(AppColors.orange(nightMode))
            }
        }
    }

    // MARK: - Notes

    private func notesSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Imaging Notes")
                .font(.system(size: 12 * fontScale, weight: .semibold))
                .foregroundColor(AppColors.fg(nightMode))
            Text(text)
                .font(.system(size: 11 * fontScale))
                .foregroundColor(AppColors.fgDim(nightMode))
        }
    }

    // MARK: - Part of (Parent Complex)

    private func partOfSection(parent: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: 11 * fontScale))
                .foregroundColor(.blue.opacity(0.7))
            Text("Part of")
                .font(.system(size: 10 * fontScale, weight: .medium))
                .foregroundColor(AppColors.fgDim(nightMode))
            Text(TargetCatalog.displayName(parent))
                .font(.system(size: 11 * fontScale, weight: .semibold, design: .monospaced))
                .foregroundColor(.blue)
                .underline()
                .onTapGesture { navigateToTarget(parent) }
        }
        .padding(.vertical, 2)
    }

    /// Navigate to a target by canonical name — finds it in the catalog list and selects it.
    private func navigateToTarget(_ canonicalName: String) {
        let normalized = TargetCatalog.canonicalName(canonicalName)
        // Search in all targets (not just filtered) — match by canonical name or common name
        if let match = viewModel.allTargets.first(where: {
            TargetCatalog.canonicalName($0.canonicalName) == normalized
        }) {
            viewModel.selectedTarget = match
        }
    }

    // MARK: - Sub-targets (Children)

    private func subTargetsSection(children: [(canonical: String, display: String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.circle.fill")
                    .font(.system(size: 11 * fontScale))
                    .foregroundColor(.orange.opacity(0.7))
                Text("Sub-targets (\(children.count))")
                    .font(.system(size: 10 * fontScale, weight: .medium))
                    .foregroundColor(AppColors.fgDim(nightMode))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(children, id: \.canonical) { child in
                        Text(child.display)
                            .font(.system(size: 10 * fontScale, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(AppColors.fg(nightMode))
                            .cornerRadius(4)
                            .onTapGesture { navigateToTarget(child.canonical) }
                            .help("Click to view \(child.display)")
                    }
                }
            }
        }
    }

    // MARK: - Aliases

    private func aliasSection(_ aliases: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Also known as")
                .font(.system(size: 10 * fontScale, weight: .medium))
                .foregroundColor(AppColors.fgDim(nightMode))
            // Simple horizontal scroll for aliases
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(aliases, id: \.self) { alias in
                        Text(alias)
                            .font(.system(size: 10 * fontScale, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppColors.bgControl(nightMode))
                            .foregroundColor(AppColors.fgDim(nightMode))
                            .cornerRadius(4)
                    }
                }
            }
        }
    }

    // MARK: - Scoring Weights

    private var scoringWeightsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality Scoring Weights")
                .font(.system(size: 12 * fontScale, weight: .semibold))
                .foregroundColor(AppColors.fg(nightMode))
            Text("How this target type affects quality scoring emphasis")
                .font(.system(size: 10 * fontScale))
                .foregroundColor(AppColors.fgVeryDim(nightMode))

            let weights: [(String, Double)] = [
                ("FWHM", target.fwhmWeight ?? 1.0),
                ("Stars", target.starWeight ?? 1.0),
                ("Noise", target.noiseWeight ?? 1.0),
                ("Trailing", target.trailingWeight ?? 1.0),
            ]

            ForEach(weights, id: \.0) { label, value in
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 10 * fontScale, weight: .medium))
                        .foregroundColor(AppColors.fgDim(nightMode))
                        .frame(width: 50, alignment: .trailing)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppColors.bgControl(nightMode))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(weightColor(value))
                                .frame(width: geo.size.width * min(CGFloat(value / 2.0), 1.0))
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.1f×", value))
                        .font(.system(size: 10 * fontScale, design: .monospaced))
                        .foregroundColor(AppColors.fg(nightMode))
                        .frame(width: 30)
                }
            }
        }
    }
}

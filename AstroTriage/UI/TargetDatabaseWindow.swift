// Target Database Catalog Browser — browsable deep-sky object catalog
// with alt/az visibility, FOV simulation, filter gap analysis, and Frame History integration.
// Supabase-backed with offline disk cache (TargetCatalogService).
// v5.15.0

import SwiftUI
import Charts

// MARK: - Window Controller

@MainActor
class TargetDatabaseWindowController {
    static let shared = TargetDatabaseWindowController()
    private var window: NSWindow?

    func show(sessionTargets: Set<String> = []) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let nightMode = AppSettings.loadBool(for: .nightMode) == true
        let vm = TargetDatabaseViewModel(sessionTargets: sessionTargets)
        vm.loadData()

        let rootView = TargetDatabaseContentView(viewModel: vm, nightMode: nightMode)
            .environment(\.fontScale, savedScale)
        let hostingView = NSHostingView(rootView: rootView)

        let count = vm.totalCount
        // 80% of full display width
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = screenW * 0.8
        let winH = screenH * 0.8

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Target Catalog — \(count) Deep-Sky Objects"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 800, height: 500)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Root View

struct TargetDatabaseContentView: View {
    @ObservedObject var viewModel: TargetDatabaseViewModel
    let nightMode: Bool
    @Environment(\.fontScale) private var fontScale
    @State private var hoveredTarget: TargetCatalogService.CatalogTarget?
    @State private var hoverPoint: CGPoint = .zero  // mouse position in list coordinate space

    var body: some View {
        HSplitView {
            // Left pane: search + filters + list (~75%)
            leftPane
                .frame(minWidth: 600, idealWidth: 900)

            // Right pane: detail panel (~30%)
            rightPane
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 500)
        }
        .background(AppColors.bg(nightMode))
    }

    // MARK: - Left Pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            // Search bar + pickers
            searchBar
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Location & setup picker row
            if !viewModel.allLocations.isEmpty || !viewModel.equipmentSetups.isEmpty {
                locationSetupBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            // Weather bar (tonight's conditions)
            if viewModel.weatherForecast != nil || viewModel.isLoadingWeather {
                weatherBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            // Type filter chips
            typeFilterBar
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            // Toggle row
            toggleRow
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            // Count label
            HStack {
                Text("\(viewModel.targetCount) of \(viewModel.totalCount) targets")
                    .font(.system(size: 11 * fontScale, weight: .medium))
                    .foregroundColor(AppColors.fg(nightMode))
                if viewModel.historyCount > 0 {
                    Text("· \(viewModel.historyCount) in your history")
                        .font(.system(size: 11 * fontScale))
                        .foregroundColor(AppColors.fgDim(nightMode))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)

            // Target list with pinned column headers (no gap)
            targetList
                .overlay {
                    GeometryReader { geo in
                        // Floating hover card — follows mouse pointer
                        if let target = hoveredTarget {
                            let cardW: CGFloat = 340
                            let cardH: CGFloat = 220
                            // Position card to the right of cursor, clamped within bounds
                            let x = min(hoverPoint.x + 20, geo.size.width - cardW / 2 - 8)
                            let y = min(max(hoverPoint.y, cardH / 2 + 8), geo.size.height - cardH / 2 - 8)
                            hoverCard(target)
                                .position(x: x + cardW / 2, y: y)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        hoverPoint = loc
                    case .ended:
                        break
                    }
                }
        }
        .background(AppColors.bg(nightMode))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.fgDim(nightMode))
                TextField("Search name, catalog ID, or constellation...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13 * fontScale))
                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.fgDim(nightMode))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(AppColors.bgInput(nightMode))
            .cornerRadius(6)

            // Difficulty picker
            Picker("Diff", selection: $viewModel.selectedDifficulty) {
                Text("All").tag(nil as String?)
                Text("Beginner").tag("beginner" as String?)
                Text("Intermediate").tag("intermediate" as String?)
                Text("Advanced").tag("advanced" as String?)
                Text("Expert").tag("expert" as String?)
            }
            .frame(width: 110)
            .font(.system(size: 11 * fontScale))
        }
    }

    private var weatherBar: some View {
        VStack(spacing: 4) {
        HStack(spacing: 14) {
            if viewModel.isLoadingWeather {
                ProgressView()
                    .controlSize(.small)
                Text("Loading weather...")
                    .font(.system(size: 12 * fontScale))
                    .foregroundColor(AppColors.fgDim(nightMode))
            } else if let w = viewModel.weatherSummary {
                Image(systemName: w.cloud < 30 ? "moon.stars" : w.cloud < 60 ? "cloud.moon" : "cloud.fill")
                    .font(.system(size: 16))
                    .foregroundColor(w.cloud < 30 ? AppColors.green(nightMode) :
                                    w.cloud < 60 ? AppColors.orange(nightMode) :
                                    AppColors.fg(nightMode))

                Text("Tonight")
                    .font(.system(size: 12 * fontScale, weight: .semibold))
                    .foregroundColor(AppColors.fg(nightMode))

                Label("Cloud \(w.cloud)%", systemImage: "cloud")
                    .font(.system(size: 12 * fontScale, weight: .medium))
                    .foregroundColor(w.cloud < 30 ? AppColors.green(nightMode) :
                                    w.cloud < 60 ? AppColors.orange(nightMode) :
                                    .red)

                // Seeing: absolute value + location-relative quality
                VStack(alignment: .leading, spacing: 0) {
                    Label("Seeing \(w.seeing)", systemImage: "eye")
                        .font(.system(size: 12 * fontScale, weight: .medium))
                    Text(w.seeingQuality + " for your location")
                        .font(.system(size: 9 * fontScale))
                        .foregroundColor(AppColors.fgDim(nightMode))
                }
                .foregroundColor(AppColors.fg(nightMode))

                if let temp = w.temp {
                    Label("\(temp)°C", systemImage: "thermometer.medium")
                        .font(.system(size: 12 * fontScale, weight: .medium))
                        .foregroundColor(AppColors.fg(nightMode))
                }

                if let hum = w.humidity {
                    Label("\(hum)%", systemImage: "humidity")
                        .font(.system(size: 12 * fontScale))
                        .foregroundColor(AppColors.fgDim(nightMode))
                }

                if let wind = w.wind {
                    Label("\(wind) km/h", systemImage: "wind")
                        .font(.system(size: 12 * fontScale))
                        .foregroundColor(AppColors.fgDim(nightMode))
                }

                // Moon info
                let moonPct = Int(viewModel.moonIllumination * 100)
                Label("Moon \(moonPct)%", systemImage: moonPct < 30 ? "moon.fill" :
                      moonPct < 70 ? "moon.haze.fill" : "moon.circle.fill")
                    .font(.system(size: 12 * fontScale, weight: .medium))
                    .foregroundColor(moonPct < 30 ? AppColors.green(nightMode) :
                                    moonPct < 70 ? AppColors.orange(nightMode) :
                                    .red.opacity(0.8))
            }
            Spacer()
        }

        // Hourly cloud cover mini-chart (nighttime hours only)
        if let forecast = viewModel.weatherForecast {
            let tz = TimeZone.current
            let cal = Calendar.current
            // Use Open-Meteo 1-hourly cloud data, filtered to nighttime
            let nightCloud = forecast.hourlyCloud.filter { entry in
                let comps = cal.dateComponents(in: tz, from: entry.time)
                let h = comps.hour ?? 12
                return h >= 18 || h <= 6
            }

            if !nightCloud.isEmpty {
                let now = Date()
                // Only highlight current hour if it's actually nighttime right now
                let nowComps = cal.dateComponents(in: tz, from: now)
                let nowH = nowComps.hour ?? 12
                let isNightNow = nowH >= 18 || nowH <= 6
                let currentHourIdx: Int? = isNightNow ? nightCloud.enumerated().min(by: {
                    Swift.abs($0.element.time.timeIntervalSince(now)) < Swift.abs($1.element.time.timeIntervalSince(now))
                })?.offset : nil

                HStack(spacing: 1) {
                    ForEach(Array(nightCloud.enumerated()), id: \.offset) { idx, hour in
                        let df = DateFormatter()
                        let _ = df.dateFormat = "HH"
                        let _ = df.timeZone = tz
                        let isCurrent = idx == currentHourIdx
                        let hourComps = cal.dateComponents(in: tz, from: hour.time)
                        let isGap = (hourComps.hour ?? 0) == 0  // midnight gap indicator

                        HStack(spacing: 0) {
                            // Gap between evening and morning
                            if isGap && idx > 0 {
                                Rectangle()
                                    .fill(AppColors.divider(nightMode))
                                    .frame(width: 1, height: 32)
                                    .padding(.horizontal, 2)
                            }

                            VStack(spacing: 0) {
                                // Bar with % label floating on top
                                let barH = CGFloat(max(hour.cloudCover, 4)) / 100 * 24
                                ZStack(alignment: .top) {
                                    VStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(hour.cloudCover < 30 ? AppColors.green(nightMode) :
                                                  hour.cloudCover < 60 ? AppColors.orange(nightMode) :
                                                  Color.red.opacity(0.6))
                                            .frame(width: 20, height: barH)
                                            .overlay(
                                                isCurrent ? RoundedRectangle(cornerRadius: 1.5)
                                                    .stroke(AppColors.accent(nightMode), lineWidth: 2) : nil
                                            )
                                    }
                                    .frame(height: 24)

                                    // % label floats above bar
                                    Text("\(hour.cloudCover)")
                                        .font(.system(size: 7 * fontScale, weight: isCurrent ? .bold : .regular))
                                        .foregroundColor(isCurrent ? AppColors.accent(nightMode) : AppColors.fgVeryDim(nightMode))
                                        .offset(y: -10)
                                }
                                .frame(height: 28)

                                // Hour label
                                Text(df.string(from: hour.time))
                                    .font(.system(size: 7 * fontScale, weight: isCurrent ? .bold : .regular))
                                    .foregroundColor(isCurrent ? AppColors.accent(nightMode) : AppColors.fgDim(nightMode))
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(AppColors.bgControl(nightMode).opacity(0.5))
        .cornerRadius(6)
    }

    private var locationSetupBar: some View {
        HStack(spacing: 12) {
            // Location picker
            if !viewModel.allLocations.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.fgDim(nightMode))
                    Picker("Location", selection: $viewModel.selectedLocationIndex) {
                        ForEach(Array(viewModel.allLocations.enumerated()), id: \.offset) { index, loc in
                            Text(loc.description).tag(index)
                        }
                    }
                    .frame(width: 120)
                    .font(.system(size: 11 * fontScale))
                }
            }

            // Equipment setup picker
            if !viewModel.equipmentSetups.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "camera.metering.spot")
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.fgDim(nightMode))
                    Picker("Setup", selection: $viewModel.selectedSetupIndex) {
                        ForEach(Array(viewModel.equipmentSetups.enumerated()), id: \.offset) { index, setup in
                            Text(setup.description).tag(index)
                        }
                    }
                    .frame(minWidth: 160)
                    .font(.system(size: 11 * fontScale))
                }
            }

            Spacer()

            // Show current location coordinates
            if let loc = viewModel.observerLocation {
                Text(String(format: "%.1f°N  %.1f°E", loc.lat, loc.lon))
                    .font(.system(size: 10 * fontScale, design: .monospaced))
                    .foregroundColor(AppColors.fgVeryDim(nightMode))
            }
        }
        .foregroundColor(AppColors.fg(nightMode))
    }

    private var typeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                typeChip(label: "All", type: nil, count: viewModel.totalCount)
                ForEach(viewModel.allTypes, id: \.type) { item in
                    typeChip(label: typeDisplayName(item.type), type: item.type, count: item.count)
                }
            }
        }
    }

    private func typeChip(label: String, type: String?, count: Int) -> some View {
        let isSelected = viewModel.selectedType == type
        return Button(action: {
            viewModel.selectedType = isSelected ? nil : type
        }) {
            HStack(spacing: 3) {
                if let type { typeIcon(type) }
                Text("\(label) (\(count))")
                    .font(.system(size: 10 * fontScale, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? AppColors.accent(nightMode).opacity(0.3) : AppColors.bgControl(nightMode))
            .foregroundColor(isSelected ? AppColors.accent(nightMode) : AppColors.fg(nightMode))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var toggleRow: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $viewModel.showTonightOnly) {
                Label("Tonight visible", systemImage: "moon.stars")
                    .font(.system(size: 11 * fontScale))
            }
            .toggleStyle(.checkbox)
            .disabled(viewModel.observerLocation == nil)
            .help(viewModel.observerLocation == nil ? "No observer location — load a session first" : "Show only targets above 30° tonight")

            Toggle(isOn: $viewModel.showGapsOnly) {
                Label("Has filter gap", systemImage: "camera.filters")
                    .font(.system(size: 11 * fontScale))
            }
            .toggleStyle(.checkbox)
            .help("Show targets where you need more integration in some filters")

            Toggle(isOn: $viewModel.showOptimalFOV) {
                Label("Optimal FOV (≥30%)", systemImage: "viewfinder")
                    .font(.system(size: 11 * fontScale))
            }
            .toggleStyle(.checkbox)
            .disabled(viewModel.currentSetup == nil)
            .help(viewModel.currentSetup == nil ? "No equipment profile — load a session first" : "Show targets that fill at least 30% of your sensor FOV")

            Spacer()
        }
        .foregroundColor(AppColors.fg(nightMode))
    }

    // Column widths — shared between header and rows for alignment
    private let colW = (
        dot: CGFloat(8), icon: CGFloat(16), name: CGFloat(160), spark: CGFloat(400),
        mag: CGFloat(42), size: CGFloat(62), alt: CGFloat(34),
        moon: CGFloat(50), hours: CGFloat(46), gap: CGFloat(14), filter: CGFloat(62)
    )

    private var columnHeaders: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: colW.dot)
            Color.clear.frame(width: colW.icon)
            sortableHeader("Name", field: .name, width: colW.name, alignment: .leading)
            sortableHeader("Alt / Az Tonight", field: .altitude, width: colW.spark, alignment: .leading)
            Spacer()
            sortableHeader("Mag", field: .magnitude, width: colW.mag, alignment: .trailing)
            sortableHeader("Size", field: .size, width: colW.size, alignment: .trailing)
            sortableHeader("Alt", field: .altitude, width: colW.alt, alignment: .trailing)
            Text("🌙").frame(width: colW.moon, alignment: .trailing)
            sortableHeader("Hrs", field: .integration, width: colW.hours, alignment: .trailing)
            Color.clear.frame(width: colW.gap)
            Text("Filt").font(.system(size: 9 * fontScale, weight: .medium))
                .foregroundColor(AppColors.fgDim(nightMode))
                .frame(width: colW.filter, alignment: .center)
        }
        .padding(.vertical, 3)
    }

    /// Floating hover card — appears on mouse hover over a row, shows all key parameters
    private func hoverCard(_ target: TargetCatalogService.CatalogTarget) -> some View {
        let history = viewModel.targetHistory[target.canonicalName]
        let visInfo = viewModel.tonightVisibility[target.canonicalName]
        let moonDist = viewModel.moonDistance[target.canonicalName]
        let fovFill = viewModel.fovFillRatios[target.canonicalName]
        let fs: CGFloat = 11

        return VStack(alignment: .leading, spacing: 6) {
            // Header: name + type
            HStack {
                Text(target.canonicalName)
                    .font(.system(size: (fs + 3) * fontScale, weight: .bold, design: .monospaced))
                if let common = target.commonName {
                    Text(common).font(.system(size: (fs + 1) * fontScale)).foregroundColor(.secondary)
                }
                Spacer()
                let (icon, color) = typeIconInfo(target.targetType)
                Label(target.typeDisplayName, systemImage: icon)
                    .font(.system(size: fs * fontScale, weight: .medium))
                    .foregroundColor(nightMode ? .red : color)
            }

            Divider()

            // Grid of key parameters
            HStack(spacing: 16) {
                // Left column
                VStack(alignment: .leading, spacing: 3) {
                    paramRow("RA", formatRA(target.raJ2000), fs)
                    paramRow("Dec", formatDec(target.decJ2000), fs)
                    paramRow("Con", target.constellation, fs)
                    paramRow("Mag", target.magnitudeV != nil ? String(format: "%.1f", target.magnitudeV!) : "—", fs)
                    paramRow("SB", target.surfaceBrightness != nil ? String(format: "%.1f", target.surfaceBrightness!) : "—", fs)
                    paramRow("Size", target.angularSizeMajor != nil ? formatSize(target.angularSizeMajor!, target.angularSizeMinor) : "—", fs)
                }

                // Right column — tonight + history
                VStack(alignment: .leading, spacing: 3) {
                    if let vis = visInfo {
                        paramRow("Alt", "\(Int(vis.maxAltitude))°", fs,
                                 color: vis.maxAltitude >= 30 ? .green : .orange)
                        paramRow(">30°", String(format: "%.1fh", vis.hoursAbove30), fs)
                    }
                    if let md = moonDist {
                        paramRow("Moon", "\(Int(md))° (\(Int(viewModel.moonIllumination * 100))%)", fs,
                                 color: md < 30 ? .red : nil)
                    }
                    if let fill = fovFill {
                        paramRow("FOV", String(format: "%.0f%%", fill * 100), fs,
                                 color: fill >= 0.3 ? .green : nil)
                    }
                    if let hist = history {
                        paramRow("Hours", String(format: "%.1fh", hist.totalHours), fs, color: .accentColor)
                        let filters = hist.perFilterHours.sorted(by: { $0.key < $1.key })
                            .map { "\($0.key):\(String(format: "%.0f", $0.value))h" }.joined(separator: " ")
                        Text(filters)
                            .font(.system(size: (fs - 2) * fontScale, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Filter recommendation
            if let primary = target.primaryFilter {
                HStack(spacing: 4) {
                    Text("Filter:")
                        .font(.system(size: (fs - 1) * fontScale, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(primary.formatted)
                        .font(.system(size: (fs - 1) * fontScale, weight: .medium))
                        .foregroundColor(filterSetColor(primary.set, nightMode: nightMode))
                }
            }
        }
        .padding(10)
        .frame(width: 340)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    private func paramRow(_ label: String, _ value: String, _ fs: CGFloat, color: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: (fs - 1) * fontScale, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(value)
                .font(.system(size: fs * fontScale, design: .monospaced))
                .foregroundColor(color ?? AppColors.fg(nightMode))
                .lineLimit(1)
        }
    }

    private func sortableHeader(_ title: String, field: TargetDatabaseViewModel.SortField,
                                width: CGFloat, alignment: Alignment) -> some View {
        Button(action: {
            if viewModel.sortBy == field {
                viewModel.sortAscending.toggle()
            } else {
                viewModel.sortBy = field
                viewModel.sortAscending = true
            }
        }) {
            HStack(spacing: 2) {
                Text(title)
                if viewModel.sortBy == field {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                }
            }
            .font(.system(size: 10 * fontScale, weight: viewModel.sortBy == field ? .bold : .medium))
            .foregroundColor(viewModel.sortBy == field ? AppColors.accent(nightMode) : AppColors.fgDim(nightMode))
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
    }

    // MARK: - Target List

    private var targetList: some View {
        List(selection: $viewModel.selectedTarget) {
            Section {
                ForEach(viewModel.filteredTargets) { target in
                    targetRow(target)
                        .tag(target)
                        .listRowBackground(
                            viewModel.sessionTargets.contains(target.canonicalName)
                                ? AppColors.accent(nightMode).opacity(0.08) : Color.clear
                        )
                }
            } header: {
                columnHeaders
                    .textCase(nil)  // prevent uppercase transformation
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListHeaderHeight, 0)
    }

    private func targetRow(_ target: TargetCatalogService.CatalogTarget) -> some View {
        let fs: CGFloat = 13  // larger base font for readability
        let history = viewModel.targetHistory[target.canonicalName]
        let visInfo = viewModel.tonightVisibility[target.canonicalName]
        let moonDist = viewModel.moonDistance[target.canonicalName]
        let hasHistory = history != nil

        return HStack(spacing: 6) {
            // Session dot
            Circle()
                .fill(viewModel.sessionTargets.contains(target.canonicalName) ? AppColors.accent(nightMode) : .clear)
                .frame(width: colW.dot, height: 6)

            // Type icon
            typeIcon(target.targetType)
                .frame(width: colW.icon)
                .help(target.typeDisplayName)

            // Name + common name (single line) — hover here triggers info card
            HStack(spacing: 4) {
                Text(target.canonicalName)
                    .font(.system(size: fs * fontScale, weight: .semibold, design: .monospaced))
                    .foregroundColor(AppColors.fg(nightMode))
                if let common = target.commonName {
                    Text(common)
                        .font(.system(size: (fs - 2) * fontScale))
                        .foregroundColor(AppColors.fgDim(nightMode))
                }
            }
            .lineLimit(1)
            .frame(width: colW.name, alignment: .leading)
            .onHover { isHovered in
                hoveredTarget = isHovered ? target : nil
            }

            // Altitude + Azimuth diagrams side by side (split sparkline width)
            HStack(spacing: 2) {
                if let info = visInfo, !info.curve.isEmpty {
                    miniAltitudeSparkline(curve: info.curve, width: colW.spark / 2 - 1, height: 28)
                    miniAzimuthArrows(target: target, width: colW.spark / 2 - 1, height: 28)
                } else {
                    Color.clear.frame(width: colW.spark, height: 28)
                }
            }
            .frame(width: colW.spark, height: 28)

            Spacer()

            // Magnitude
            Text(target.magnitudeV != nil ? String(format: "%.1f", target.magnitudeV!) : "—")
                .font(.system(size: fs * fontScale, design: .monospaced))
                .foregroundColor(target.magnitudeV != nil ? AppColors.fg(nightMode) : AppColors.fgVeryDim(nightMode))
                .lineLimit(1).fixedSize()
                .frame(width: colW.mag, alignment: .trailing)

            // Size (compact single-line)
            Text(target.angularSizeMajor != nil ? formatSizeCompact(target.angularSizeMajor!, target.angularSizeMinor) : "—")
                .font(.system(size: (fs - 1) * fontScale, design: .monospaced))
                .foregroundColor(AppColors.fgDim(nightMode))
                .lineLimit(1)
                .frame(width: colW.size, alignment: .trailing)

            // Max altitude tonight
            let maxAlt = visInfo?.maxAltitude ?? -99
            Text(maxAlt > 0 ? "\(Int(maxAlt))°" : "—")
                .font(.system(size: fs * fontScale, weight: .medium, design: .monospaced))
                .lineLimit(1).fixedSize()
                .foregroundColor(maxAlt >= 30 ? AppColors.green(nightMode) :
                                maxAlt >= 15 ? AppColors.orange(nightMode) :
                                AppColors.fgVeryDim(nightMode))
                .frame(width: colW.alt, alignment: .trailing)
                .help(maxAlt > 0 ? "Max altitude tonight: \(Int(maxAlt))° — \(maxAlt >= 30 ? "good" : maxAlt >= 15 ? "low" : "very low")" : "Below horizon tonight")

            // Moon distance
            Text(moonDist != nil ? "☽\(Int(moonDist!))°" : "—")
                .font(.system(size: (fs - 2) * fontScale, design: .monospaced))
                .lineLimit(1).fixedSize()
                .foregroundColor(moonDist != nil && moonDist! < 30 ? .red.opacity(0.7) :
                                 moonDist != nil && moonDist! < 60 ? AppColors.orange(nightMode) :
                                 AppColors.fgVeryDim(nightMode))
                .frame(width: colW.moon, alignment: .trailing)
            .help(moonDist != nil ? "Moon: \(Int(moonDist!))° away (\(Int(viewModel.moonIllumination * 100))% illuminated)\(moonDist! < 30 ? " — too close!" : moonDist! < 60 ? " — moderate" : " — safe")" : "Moon distance unknown")

            // Integration hours (only if has history)
            if let hist = history {
                Text(String(format: "%.0fh", hist.totalHours))
                    .font(.system(size: (fs - 1) * fontScale, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(AppColors.accent(nightMode).opacity(0.2))
                    .cornerRadius(4)
                    .foregroundColor(AppColors.accent(nightMode))
                    .frame(width: colW.hours, alignment: .trailing)
            } else {
                Color.clear.frame(width: colW.hours)
            }

            // Filter gap — ONLY for previously imaged targets
            if hasHistory, let _ = target.primaryFilter,
               viewModel.filterGapAnalysis(target: target)?.hasGap == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.orange(nightMode))
                    .frame(width: colW.gap)
            } else {
                Color.clear.frame(width: colW.gap)
            }

            // Recommended filter set pill (single line, abbreviated)
            if let primary = target.primaryFilter {
                Text(primary.set)
                    .font(.system(size: (fs - 2) * fontScale, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(filterSetColor(primary.set, nightMode: nightMode).opacity(0.2))
                    .foregroundColor(filterSetColor(primary.set, nightMode: nightMode))
                    .cornerRadius(3)
                    .frame(width: colW.filter, alignment: .center)
            } else {
                Color.clear.frame(width: colW.filter)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Right Pane (Detail)

    private var rightPane: some View {
        Group {
            if let target = viewModel.selectedTarget {
                ScrollView {
                    TargetDetailView(target: target, viewModel: viewModel, nightMode: nightMode)
                        .padding(16)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "telescope")
                        .font(.system(size: 48))
                        .foregroundColor(AppColors.fgVeryDim(nightMode))
                    Text("Select a target")
                        .font(.system(size: 14 * fontScale))
                        .foregroundColor(AppColors.fgDim(nightMode))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppColors.bgControl(nightMode))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func typeIcon(_ type: String) -> some View {
        let (icon, color) = typeIconInfo(type)
        Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundColor(nightMode ? .red.opacity(0.8) : color)
    }

    /// Mini altitude sparkline for list rows — shows rise/transit/set at a glance
    private func miniAltitudeSparkline(curve: [AltAzCalculator.VisibilityPoint], width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            guard curve.count > 1 else { return }
            let maxAlt = 90.0
            let step = size.width / CGFloat(curve.count - 1)

            // Draw the altitude curve as a filled path
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, point) in curve.enumerated() {
                let x = CGFloat(i) * step
                let y = size.height - (max(0, point.altitude) / maxAlt * Double(size.height))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()

            let fillColor = nightMode ? Color.red.opacity(0.35) : Color.accentColor.opacity(0.25)
            context.fill(path, with: .color(fillColor))

            // Stroke the curve line on top
            var linePath = Path()
            for (i, point) in curve.enumerated() {
                let x = CGFloat(i) * step
                let y = size.height - (max(0, point.altitude) / maxAlt * Double(size.height))
                if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
                else { linePath.addLine(to: CGPoint(x: x, y: y)) }
            }
            let lineColor = nightMode ? Color.red.opacity(0.7) : Color.accentColor.opacity(0.6)
            context.stroke(linePath, with: .color(lineColor), lineWidth: 1.2)

            // 25° dashed line (lower threshold)
            let y25 = size.height - (25.0 / maxAlt * Double(size.height))
            var dash25 = Path()
            dash25.move(to: CGPoint(x: 0, y: y25))
            dash25.addLine(to: CGPoint(x: size.width, y: y25))
            context.stroke(dash25, with: .color(.orange.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

            // 30° dashed line (good imaging threshold)
            let y30 = size.height - (30.0 / maxAlt * Double(size.height))
            var dash30 = Path()
            dash30.move(to: CGPoint(x: 0, y: y30))
            dash30.addLine(to: CGPoint(x: size.width, y: y30))
            context.stroke(dash30, with: .color(.green.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
        }
        .frame(width: width, height: height)
        .cornerRadius(3)
        .help("Altitude tonight — green dashed = 30° (good), orange dashed = 25° (minimum)")
    }

    /// Mini azimuth direction arrows — shows compass direction during the night
    private func miniAzimuthArrows(target: TargetCatalogService.CatalogTarget, width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            guard let loc = viewModel.observerLocation else { return }
            guard let visInfo = viewModel.tonightVisibility[target.canonicalName] else { return }
            let points = visInfo.curve
            guard points.count > 2 else { return }

            let step = size.width / CGFloat(points.count - 1)
            let arrowSpacing = max(3, Int(points.count) / 8)  // ~8 arrows across

            for (i, point) in points.enumerated() {
                guard i % arrowSpacing == arrowSpacing / 2, point.altitude > 0 else { continue }
                // Compute azimuth for this time
                let altAz = AltAzCalculator.compute(ra: target.raJ2000, dec: target.decJ2000,
                                                     latitude: loc.lat, longitude: loc.lon,
                                                     utcDate: point.time)
                let az = altAz.azimuth
                let x = CGFloat(i) * step
                let cy = size.height / 2
                let arrowLen: CGFloat = 5

                // Arrow direction: 0°=N=up, 90°=E=right, 180°=S=down, 270°=W=left
                let rad = az * .pi / 180
                let dx = sin(rad) * Double(arrowLen)
                let dy = -cos(rad) * Double(arrowLen)  // negative because Y grows downward

                var arrowPath = Path()
                arrowPath.move(to: CGPoint(x: x - CGFloat(dx), y: cy - CGFloat(dy)))
                arrowPath.addLine(to: CGPoint(x: x + CGFloat(dx), y: cy + CGFloat(dy)))

                let arrowColor = nightMode ? Color.red.opacity(0.5) : Color.blue.opacity(0.5)
                context.stroke(arrowPath, with: .color(arrowColor), lineWidth: 1.5)

                // Arrowhead
                let headLen: CGFloat = 3
                let headAngle = atan2(CGFloat(dy), CGFloat(dx))
                let tip = CGPoint(x: x + CGFloat(dx), y: cy + CGFloat(dy))
                var head = Path()
                head.move(to: tip)
                head.addLine(to: CGPoint(
                    x: tip.x - headLen * cos(headAngle - .pi / 4),
                    y: tip.y - headLen * sin(headAngle - .pi / 4)
                ))
                head.move(to: tip)
                head.addLine(to: CGPoint(
                    x: tip.x - headLen * cos(headAngle + .pi / 4),
                    y: tip.y - headLen * sin(headAngle + .pi / 4)
                ))
                context.stroke(head, with: .color(arrowColor), lineWidth: 1)
            }

            // Cardinal labels
            let labelFont = Font.system(size: 6).monospaced()
            context.draw(Text("N").font(labelFont).foregroundColor(.gray.opacity(0.4)),
                         at: CGPoint(x: size.width - 4, y: 3))
        }
        .frame(width: width, height: height)
        .cornerRadius(3)
        .help("Azimuth direction during the night (↑N ↓S →E ←W)")
    }
}

// MARK: - Detail View

struct TargetDetailView: View {
    let target: TargetCatalogService.CatalogTarget
    @ObservedObject var viewModel: TargetDatabaseViewModel
    let nightMode: Bool
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
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
                    Text("FOV with \(setup.description)")
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

// MARK: - Formatting Helpers

private func formatRA(_ degrees: Double) -> String {
    let totalHours = degrees / 15.0
    let h = Int(totalHours)
    let mFrac = (totalHours - Double(h)) * 60.0
    let m = Int(mFrac)
    let s = (mFrac - Double(m)) * 60.0
    return String(format: "%02dh %02dm %04.1fs", h, m, s)
}

private func formatDec(_ degrees: Double) -> String {
    let sign = degrees >= 0 ? "+" : "-"
    let abs = Swift.abs(degrees)
    let d = Int(abs)
    let mFrac = (abs - Double(d)) * 60.0
    let m = Int(mFrac)
    let s = (mFrac - Double(m)) * 60.0
    return String(format: "%@%02d° %02d' %04.1f\"", sign, d, m, s)
}

/// Compact single-line size format for list rows (no line breaks)
private func formatSizeCompact(_ major: Double, _ minor: Double?) -> String {
    if let minor {
        if major >= 60 {
            return String(format: "%.0f°×%.0f°", major / 60, minor / 60)
        }
        return String(format: "%.0f'×%.0f'", major, minor)
    }
    if major >= 60 { return String(format: "%.0f°", major / 60) }
    return String(format: "%.0f'", major)
}

private func formatSize(_ major: Double, _ minor: Double?) -> String {
    if let minor {
        if major >= 60 {
            return String(format: "%.1f° x %.1f°", major / 60, minor / 60)
        }
        return String(format: "%.1f' x %.1f'", major, minor)
    }
    return String(format: "%.1f'", major)
}

private func formatArcmin(_ value: Double) -> String {
    if value >= 60 {
        return String(format: "%.1f°", value / 60)
    }
    return String(format: "%.1f'", value)
}

private func typeDisplayName(_ type: String) -> String {
    type.replacingOccurrences(of: "_", with: " ").capitalized
}

private func typeIconInfo(_ type: String) -> (icon: String, color: Color) {
    switch type {
    case "galaxy", "galaxy_group":       return ("hurricane", .blue)
    case "emission_nebula", "hii_region": return ("cloud.fill", .teal)
    case "reflection_nebula":            return ("cloud", .cyan)
    case "planetary_nebula":             return ("circle.dashed", .mint)
    case "dark_nebula":                  return ("cloud.fog.fill", .gray)
    case "supernova_remnant":            return ("sparkles", .orange)
    case "open_cluster":                 return ("star.leadinghalf.filled", .yellow)
    case "globular_cluster":             return ("circle.grid.cross.fill", .orange)
    case "ifn":                          return ("waveform.path", .purple)
    case "star_forming_region":          return ("flame.fill", .red)
    case "quasar":                       return ("bolt.fill", .indigo)
    case "wolf_rayet_nebula":            return ("wind", .pink)
    case "double_star":                  return ("star.fill", .yellow)
    case "variable_star":                return ("star.circle.fill", .yellow)
    default:                             return ("questionmark.circle", .gray)
    }
}

private func filterColor(_ filter: String, nightMode: Bool) -> Color {
    if nightMode { return .red.opacity(0.8) }
    switch filter.lowercased() {
    case "l":     return .gray
    case "r":     return .red
    case "g":     return .green
    case "b":     return .blue
    case "ha":    return Color(red: 0.9, green: 0.4, blue: 0.1)
    case "oiii":  return .teal
    case "sii":   return Color(red: 0.8, green: 0.7, blue: 0.1)
    case "hbeta": return .cyan
    case "nii":   return .pink
    default:      return .gray
    }
}

private func difficultyColor(_ diff: String) -> Color {
    switch diff {
    case "beginner":      return .green
    case "intermediate":  return .blue
    case "advanced":      return .orange
    case "expert":        return .red
    default:              return .gray
    }
}

private func weightColor(_ value: Double) -> Color {
    if value < 0.8 { return .blue }
    if value <= 1.2 { return .green }
    if value <= 1.5 { return .orange }
    return .red
}

private func filterSetColor(_ set: String, nightMode: Bool) -> Color {
    if nightMode { return .red.opacity(0.8) }
    switch set.uppercased() {
    case "SHO":     return .orange
    case "HOO":     return .teal
    case "LRGB":    return .blue
    case "HARGB", "HALRGB": return .purple
    case "RGB":     return .green
    case "L":       return .gray
    default:        return .secondary
    }
}

private func gapLevelColor(_ level: GapLevel) -> Color {
    switch level {
    case .good:    return .green
    case .partial: return .yellow
    case .gap:     return .red.opacity(0.7)
    }
}

// MARK: - DSS Thumbnail Cache + View

/// Disk-cached DSS thumbnail loader. Downloads once, caches forever to
/// ~/Library/Caches/AstroBlinkV2/dss_thumbnails/. Memory cache via NSCache.
@MainActor
private final class DSSImageCache: ObservableObject {
    static let shared = DSSImageCache()

    private let memCache = NSCache<NSURL, NSImage>()
    private let cacheDir: URL
    private var inFlight: Set<URL> = []

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("AstroBlinkV2/dss_thumbnails")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memCache.countLimit = 600
    }

    func image(for url: URL) -> NSImage? {
        // Check memory
        if let img = memCache.object(forKey: url as NSURL) { return img }
        // Check disk
        let diskPath = diskFile(for: url)
        if FileManager.default.fileExists(atPath: diskPath.path),
           let img = NSImage(contentsOf: diskPath) {
            memCache.setObject(img, forKey: url as NSURL)
            return img
        }
        return nil
    }

    func fetch(_ url: URL) {
        guard !inFlight.contains(url), image(for: url) == nil else { return }
        inFlight.insert(url)
        Task.detached(priority: .utility) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let img = NSImage(data: data) else { return }
                let diskPath = await self.diskFile(for: url)
                try? data.write(to: diskPath, options: .atomic)
                await MainActor.run {
                    self.memCache.setObject(img, forKey: url as NSURL)
                    self.inFlight.remove(url)
                    self.objectWillChange.send()
                }
            } catch {
                await MainActor.run { self.inFlight.remove(url) }
            }
        }
    }

    private func diskFile(for url: URL) -> URL {
        // Use RA/Dec from the URL as unique filename (extracted from query params)
        // URL format: ...&r=60.217&d=36.617&...
        let s = url.absoluteString
        let name = s.components(separatedBy: "&")
            .filter { $0.hasPrefix("r=") || $0.hasPrefix("d=") || $0.hasPrefix("h=") }
            .joined(separator: "_")
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "m")
            .replacingOccurrences(of: ".", with: "p")
        return cacheDir.appendingPathComponent("dss_\(name).gif")
    }
}

/// Cached DSS thumbnail view. Uses DSSImageCache for disk + memory caching.
struct DSSThumbnailView: View {
    let url: URL?
    let size: CGFloat
    @ObservedObject private var cache = DSSImageCache.shared

    var body: some View {
        if let url {
            if let nsImage = cache.image(for: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .cornerRadius(size > 60 ? 8 : 4)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: size, height: size)
                    .cornerRadius(size > 60 ? 8 : 4)
                    .onAppear { cache.fetch(url) }
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: size * 0.4))
                .foregroundColor(.gray.opacity(0.3))
                .frame(width: size, height: size)
        }
    }
}

// Convenience for use in both TargetDatabaseContentView and TargetDetailView
@ViewBuilder
private func dssThumbnail(url: URL?, size: CGFloat) -> some View {
    DSSThumbnailView(url: url, size: size)
}

/// DSS thumbnail that enlarges on hover — 120px normal, 300px on hover
struct ZoomableDSSThumbnail: View {
    let url: URL?
    @State private var isHovered = false

    var body: some View {
        DSSThumbnailView(url: url, size: isHovered ? 300 : 120)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .zIndex(isHovered ? 10 : 0)
    }
}

// Benchmark Leaderboard — floating window with tabs for stacking and session load benchmarks.
// Users must share their own benchmark before seeing the leaderboard.
// Stacking ranked by t/frame, session load ranked by MB/s throughput.

import SwiftUI

// MARK: - Window Controller

class BenchmarkLeaderboardWindowController {
    static let shared = BenchmarkLeaderboardWindowController()
    private var window: NSWindow?

    func show(service: BenchmarkService, myMachineHash: String, engine: String) {
        // Reuse or create window
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let view = BenchmarkLeaderboardView(
            service: service,
            myMachineHash: myMachineHash,
            engine: engine
        )

        let hostingView = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Benchmark Leaderboard"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 780, height: 420)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Tab Selection

enum LeaderboardTab: String, CaseIterable {
    case stacking = "Stacking"
    case sessionLoad = "Session Load"
}

// MARK: - Column layout constants

// Stacking tab column widths — all right-aligned except Chip (left) and # (center)
private enum SC {
    static let rank: CGFloat = 32
    static let tPerFrame: CGFloat = 68
    static let totalTime: CGFloat = 68
    static let frames: CGFloat = 52
    static let mp: CGFloat = 46
    static let msPerMP: CGFloat = 66
    static let gap: CGFloat = 10
    static let chip: CGFloat = 130
    static let cores: CGFloat = 46
    static let ram: CGFloat = 44
    static let version: CGFloat = 44
    static let date: CGFloat = 90
    static let pad: CGFloat = 6   // padding between each column
}

// Session load tab column widths
private enum SL {
    static let rank: CGFloat = 32
    static let throughput: CGFloat = 58
    static let totalTime: CGFloat = 60
    static let scan: CGFloat = 52
    static let firstImg: CGFloat = 56
    static let headers: CGFloat = 58
    static let cache: CGFloat = 54
    static let files: CGFloat = 44
    static let size: CGFloat = 50
    static let source: CGFloat = 44
    static let gap: CGFloat = 10
    static let chip: CGFloat = 110
    static let ram: CGFloat = 40
    static let date: CGFloat = 90
    static let pad: CGFloat = 5
}

// Shared font sizes
private let headerFont: Font = .system(size: 11, weight: .semibold, design: .monospaced)
private let cellFont: Font = .system(size: 11, design: .monospaced)
private let cellFontBold: Font = .system(size: 11, weight: .medium, design: .monospaced)
private let dateFont: Font = .system(size: 10, design: .monospaced)

// MARK: - Main Leaderboard View

struct BenchmarkLeaderboardView: View {
    @ObservedObject var service: BenchmarkService
    let myMachineHash: String
    let engine: String

    @State private var selectedTab: LeaderboardTab = .stacking

    var body: some View {
        VStack(spacing: 0) {
            // Header with tab picker
            HStack {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.yellow)
                Text("Community Benchmarks")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))

                Spacer()

                Picker("", selection: $selectedTab) {
                    ForEach(LeaderboardTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if service.isFetching {
                Spacer()
                ProgressView("Loading leaderboard...")
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
            } else if let error = service.errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                switch selectedTab {
                case .stacking:
                    stackingTab
                case .sessionLoad:
                    sessionLoadTab
                }
            }

            // Footer
            Divider()
            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("Anonymous — only hardware specs and timing are shared")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: copyToClipboard) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("Copy")
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .padding(.trailing, 8)
                let count = selectedTab == .stacking ? service.leaderboard.count : service.sessionLeaderboard.count
                Text("\(count) entries")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear {
            Task { try? await service.fetchSessionLeaderboard(sourceType: nil) }
        }
    }

    // MARK: - Copy to clipboard (tab-separated for spreadsheet paste)

    private func copyToClipboard() {
        var text = ""
        if selectedTab == .stacking {
            text = "# t/frame Time Frames MP ms/MP/f Chip Cores RAM Ver Date\n"
            for (i, entry) in service.sortedLeaderboard.enumerated() {
                let chip = entry.chip_name.replacingOccurrences(of: "Apple ", with: "")
                text += "\(i+1)\t\(String(format: "%.2fs", entry.timePerFrame))\t\(entry.formattedTime)\t\(entry.file_count)\t\(String(format: "%.1f", entry.image_megapixels))\t\(String(format: "%.0f", entry.msPerMPPerFrame))\t\(chip)\t\(entry.cpu_cores)\t\(entry.ram_gb)G\t\(entry.app_version)\t\(entry.formattedDateTime)\n"
            }
        } else {
            text = "# MB/s Total Scan 1stImg Headers Cache Files Size Source Chip RAM Date\n"
            for (i, entry) in service.sortedSessionLeaderboard.enumerated() {
                let chip = entry.chip_name.replacingOccurrences(of: "Apple ", with: "")
                let src = entry.source_type == "local" ? "SSD" : entry.source_type == "network" ? "Net" : "?"
                text += "\(i+1)\t\(String(format: "%.0f", entry.throughputMBs))\t\(entry.formattedTotalTime)\t\(formatMs(entry.scan_ms))\t\(formatMs(entry.first_image_ms))\t\(formatMs(entry.header_ms))\t\(formatMs(entry.caching_ms))\t\(entry.file_count)\t\(entry.formattedSize)\t\(src)\t\(chip)\t\(entry.ram_gb)G\t\(entry.formattedDateTime)\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Stacking Tab

    @ViewBuilder
    private var stackingTab: some View {
        if service.leaderboard.isEmpty {
            Spacer()
            Text("No stacking benchmarks yet — run a Quick Stack and Share & Compare!")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
        } else {
            // Column headers
            HStack(spacing: SC.pad) {
                Text("#")
                    .frame(width: SC.rank, alignment: .center)
                stackHeader(.timePerFrame, width: SC.tPerFrame)
                stackHeader(.totalTime, width: SC.totalTime)
                stackHeader(.frames, width: SC.frames)
                stackHeader(.megapixels, width: SC.mp)
                stackHeader(.msPerMP, width: SC.msPerMP)
                Spacer().frame(width: SC.gap)
                stackHeader(.chip, width: SC.chip)
                stackHeader(.cores, width: SC.cores)
                stackHeader(.ram, width: SC.ram)
                stackHeader(.version, width: SC.version)
                stackHeader(.date, width: SC.date)
                Spacer()
            }
            .font(headerFont)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(service.sortedLeaderboard.enumerated()), id: \.element.id) { index, entry in
                        stackingRow(rank: index + 1, entry: entry, isMe: entry.machine_hash == myMachineHash)
                    }
                }
            }
        }
    }

    private func stackHeader(_ col: BenchmarkSortColumn, width: CGFloat) -> some View {
        Button(action: { service.toggleSort(col) }) {
            HStack(spacing: 2) {
                Text(col.rawValue)
                if service.sortColumn == col {
                    Image(systemName: service.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .foregroundColor(service.sortColumn == col ? .accentColor : .secondary)
    }

    private func stackingRow(rank: Int, entry: BenchmarkEntry, isMe: Bool) -> some View {
        HStack(spacing: SC.pad) {
            rankBadge(rank)
                .frame(width: SC.rank, alignment: .center)
                .font(.system(size: 12, weight: rank <= 3 ? .bold : .regular, design: .monospaced))

            Text(String(format: "%.2fs", entry.timePerFrame))
                .frame(width: SC.tPerFrame, alignment: .trailing)
                .font(cellFontBold)
                .foregroundColor(isMe ? .blue : .primary)
            Text(entry.formattedTime)
                .frame(width: SC.totalTime, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)
            Text("\(entry.file_count)")
                .frame(width: SC.frames, alignment: .trailing)
                .font(cellFont)
            Text(String(format: "%.1f", entry.image_megapixels))
                .frame(width: SC.mp, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)
            Text(String(format: "%.0f", entry.msPerMPPerFrame))
                .frame(width: SC.msPerMP, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Spacer().frame(width: SC.gap)

            Text(entry.chip_name.replacingOccurrences(of: "Apple ", with: ""))
                .frame(width: SC.chip, alignment: .leading)
                .font(cellFont)
                .lineLimit(1)
            Text("\(entry.cpu_cores)")
                .frame(width: SC.cores, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)
            Text("\(entry.ram_gb)G")
                .frame(width: SC.ram, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)
            Text(entry.app_version)
                .frame(width: SC.version, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)
            Text(entry.formattedDateTime)
                .frame(width: SC.date, alignment: .trailing)
                .font(dateFont)
                .foregroundColor(.secondary)

            Spacer()
            youBadge(isMe)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(rowBackground(rank: rank, isMe: isMe))
    }

    // MARK: - Session Load Tab

    @ViewBuilder
    private var sessionLoadTab: some View {
        if service.sessionLeaderboard.isEmpty {
            Spacer()
            Text("No session load benchmarks yet — open a folder and Share & Compare from Benchmark Stats!")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        } else {
            // Column headers
            HStack(spacing: SL.pad) {
                Text("#")
                    .frame(width: SL.rank, alignment: .center)
                sessionHeader(.throughput, width: SL.throughput)
                sessionHeader(.totalTime, width: SL.totalTime)
                sessionHeader(.scanTime, width: SL.scan)
                sessionHeader(.firstImage, width: SL.firstImg)
                sessionHeader(.headerTime, width: SL.headers)
                sessionHeader(.cacheTime, width: SL.cache)
                sessionHeader(.files, width: SL.files)
                sessionHeader(.size, width: SL.size)
                sessionHeader(.source, width: SL.source)
                Spacer().frame(width: SL.gap)
                sessionHeader(.chip, width: SL.chip)
                sessionHeader(.ram, width: SL.ram)
                sessionHeader(.date, width: SL.date)
                Spacer()
            }
            .font(headerFont)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(service.sortedSessionLeaderboard.enumerated()), id: \.element.id) { index, entry in
                        sessionRow(rank: index + 1, entry: entry, isMe: entry.machine_hash == myMachineHash)
                    }
                }
            }
        }
    }

    private func sessionHeader(_ col: SessionSortColumn, width: CGFloat) -> some View {
        Button(action: { service.toggleSessionSort(col) }) {
            HStack(spacing: 2) {
                Text(col.rawValue)
                if service.sessionSortColumn == col {
                    Image(systemName: service.sessionSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .foregroundColor(service.sessionSortColumn == col ? .accentColor : .secondary)
    }

    private func sessionRow(rank: Int, entry: SessionBenchmarkEntry, isMe: Bool) -> some View {
        HStack(spacing: SL.pad) {
            rankBadge(rank)
                .frame(width: SL.rank, alignment: .center)
                .font(.system(size: 12, weight: rank <= 3 ? .bold : .regular, design: .monospaced))

            Text(String(format: "%.0f", entry.throughputMBs))
                .frame(width: SL.throughput, alignment: .trailing)
                .font(cellFontBold)
                .foregroundColor(isMe ? .blue : .primary)

            Text(entry.formattedTotalTime)
                .frame(width: SL.totalTime, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Text(formatMs(entry.scan_ms))
                .frame(width: SL.scan, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Text(formatMs(entry.first_image_ms))
                .frame(width: SL.firstImg, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Text(formatMs(entry.header_ms))
                .frame(width: SL.headers, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Text(formatMs(entry.caching_ms))
                .frame(width: SL.cache, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Text("\(entry.file_count)")
                .frame(width: SL.files, alignment: .trailing)
                .font(cellFont)

            Text(entry.formattedSize)
                .frame(width: SL.size, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Text(entry.source_type == "local" ? "SSD" : entry.source_type == "network" ? "Net" : "?")
                .frame(width: SL.source, alignment: .trailing)
                .font(cellFontBold)
                .foregroundColor(entry.source_type == "local" ? .green : (entry.source_type == "network" ? .orange : .secondary))

            Spacer().frame(width: SL.gap)

            Text(entry.chip_name.replacingOccurrences(of: "Apple ", with: ""))
                .frame(width: SL.chip, alignment: .leading)
                .font(cellFont)
                .lineLimit(1)

            Text("\(entry.ram_gb)G")
                .frame(width: SL.ram, alignment: .trailing)
                .font(cellFont)
                .foregroundColor(.secondary)

            Text(entry.formattedDateTime)
                .frame(width: SL.date, alignment: .trailing)
                .font(dateFont)
                .foregroundColor(.secondary)

            Spacer()
            youBadge(isMe)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(rowBackground(rank: rank, isMe: isMe))
    }

    // MARK: - Shared helpers

    private func formatMs(_ ms: Int) -> String {
        let s = Double(ms) / 1000.0
        if s < 60 { return String(format: "%.1fs", s) }
        let min = Int(s) / 60
        let sec = s - Double(min * 60)
        return String(format: "%dm%.0fs", min, sec)
    }

    @ViewBuilder
    private func rankBadge(_ rank: Int) -> some View {
        if rank == 1 {
            Text("1").foregroundColor(.yellow)
        } else if rank == 2 {
            Text("2").foregroundColor(Color(white: 0.75))
        } else if rank == 3 {
            Text("3").foregroundColor(.orange)
        } else {
            Text("\(rank)").foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func youBadge(_ isMe: Bool) -> some View {
        if isMe {
            Text("YOU")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.blue))
        }
    }

    private func rowBackground(rank: Int, isMe: Bool) -> some View {
        Group {
            if isMe {
                Color.blue.opacity(0.08)
            } else if rank % 2 == 0 {
                Color.clear
            } else {
                Color(NSColor.controlBackgroundColor).opacity(0.3)
            }
        }
    }
}

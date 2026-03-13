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
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Benchmark Leaderboard"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 700, height: 400)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Tab Selection

enum LeaderboardTab: String, CaseIterable {
    case stacking = "Stacking"
    case sessionLoad = "Session Load"
}

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
            // Fetch session leaderboard on first appear
            Task { try? await service.fetchSessionLeaderboard(sourceType: nil) }
        }
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
            HStack(spacing: 0) {
                Text("#").frame(width: 30, alignment: .center)
                stackHeader(.timePerFrame, width: 65)
                stackHeader(.totalTime, width: 65)
                stackHeader(.frames, width: 50)
                stackHeader(.megapixels, width: 40)
                stackHeader(.msPerMP, width: 62)
                Spacer().frame(width: 8)
                stackHeader(.chip, width: 120)
                stackHeader(.cores, width: 42)
                stackHeader(.ram, width: 40)
                stackHeader(.version, width: 42)
                stackHeader(.date, width: 85)
                Spacer()
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

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
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .frame(width: width, alignment: col == .chip ? .leading : .trailing)
        }
        .buttonStyle(.plain)
        .foregroundColor(service.sortColumn == col ? .accentColor : .secondary)
    }

    private func stackingRow(rank: Int, entry: BenchmarkEntry, isMe: Bool) -> some View {
        HStack(spacing: 0) {
            rankBadge(rank)
                .frame(width: 30, alignment: .center)
                .font(.system(size: 11, weight: rank <= 3 ? .bold : .regular, design: .monospaced))

            Text(String(format: "%.2fs", entry.timePerFrame))
                .frame(width: 65, alignment: .trailing)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(isMe ? .blue : .primary)
            Text(entry.formattedTime)
                .frame(width: 65, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text("\(entry.file_count)")
                .frame(width: 50, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
            Text(String(format: "%.1f", entry.image_megapixels))
                .frame(width: 40, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text(String(format: "%.0f", entry.msPerMPPerFrame))
                .frame(width: 62, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer().frame(width: 8)

            Text(entry.chip_name.replacingOccurrences(of: "Apple ", with: ""))
                .frame(width: 120, alignment: .leading)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
            Text("\(entry.cpu_cores)")
                .frame(width: 42, alignment: .center)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text("\(entry.ram_gb)G")
                .frame(width: 40, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text(entry.app_version)
                .frame(width: 42, alignment: .center)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text(entry.formattedDateTime)
                .frame(width: 85, alignment: .center)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer()
            youBadge(isMe)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
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
            HStack(spacing: 0) {
                Text("#").frame(width: 30, alignment: .center)
                sessionHeader(.throughput, width: 55)
                sessionHeader(.totalTime, width: 58)
                sessionHeader(.scanTime, width: 48)
                sessionHeader(.firstImage, width: 52)
                sessionHeader(.headerTime, width: 55)
                sessionHeader(.cacheTime, width: 50)
                sessionHeader(.files, width: 40)
                sessionHeader(.size, width: 45)
                sessionHeader(.source, width: 48)
                Spacer().frame(width: 6)
                sessionHeader(.chip, width: 100)
                sessionHeader(.ram, width: 36)
                sessionHeader(.date, width: 85)
                Spacer()
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

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
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .frame(width: width, alignment: col == .chip || col == .source ? .leading : .trailing)
        }
        .buttonStyle(.plain)
        .foregroundColor(service.sessionSortColumn == col ? .accentColor : .secondary)
    }

    private func sessionRow(rank: Int, entry: SessionBenchmarkEntry, isMe: Bool) -> some View {
        HStack(spacing: 0) {
            rankBadge(rank)
                .frame(width: 30, alignment: .center)
                .font(.system(size: 11, weight: rank <= 3 ? .bold : .regular, design: .monospaced))

            Text(String(format: "%.0f", entry.throughputMBs))
                .frame(width: 55, alignment: .trailing)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(isMe ? .blue : .primary)

            Text(entry.formattedTotalTime)
                .frame(width: 58, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text(formatMs(entry.scan_ms))
                .frame(width: 48, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text(formatMs(entry.first_image_ms))
                .frame(width: 52, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text(formatMs(entry.header_ms))
                .frame(width: 55, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text(formatMs(entry.caching_ms))
                .frame(width: 50, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text("\(entry.file_count)")
                .frame(width: 40, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))

            Text(entry.formattedSize)
                .frame(width: 45, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text(entry.source_type == "local" ? "SSD" : entry.source_type == "network" ? "Net" : "?")
                .frame(width: 48, alignment: .leading)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(entry.source_type == "local" ? .green : (entry.source_type == "network" ? .orange : .secondary))

            Spacer().frame(width: 6)

            Text(entry.chip_name.replacingOccurrences(of: "Apple ", with: ""))
                .frame(width: 100, alignment: .leading)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)

            Text("\(entry.ram_gb)G")
                .frame(width: 36, alignment: .trailing)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Text(entry.formattedDateTime)
                .frame(width: 85, alignment: .center)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer()
            youBadge(isMe)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
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

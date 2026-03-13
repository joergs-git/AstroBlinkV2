// v3.3.0 — Benchmark Stats window with horizontal bar chart
import SwiftUI

// Window controller for the benchmark stats floating window
class BenchmarkStatsWindowController: NSWindowController {
    static let shared = BenchmarkStatsWindowController()

    private var statsRef: BenchmarkStats?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Benchmark Stats"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 340)
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // Show the window with current benchmark data
    func show(stats: BenchmarkStats, sessionRootURL: URL? = nil) {
        statsRef = stats
        let hostingView = NSHostingView(rootView: BenchmarkStatsContentView(stats: stats, sessionRootURL: sessionRootURL))
        window?.contentView = hostingView
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// SwiftUI content for the benchmark stats window
struct BenchmarkStatsContentView: View {
    @ObservedObject var stats: BenchmarkStats
    let sessionRootURL: URL?
    @State private var memorySnapshot: BenchmarkStats.MemorySnapshot?
    @StateObject private var benchmarkService = BenchmarkService()

    // Bar chart data derived from stats
    private var barItems: [(label: String, duration: Double, color: Color)] {
        var items: [(String, Double, Color)] = []

        if let d = stats.fileLoadingDuration {
            items.append(("File Scanning", d, .blue))
        }
        if let d = stats.firstImageDuration {
            items.append(("First Image", d, .green))
        }
        if let d = stats.headerEnrichDuration {
            items.append(("Header Reading", d, .orange))
        }
        if let d = stats.cachingDuration {
            items.append(("Pre-Caching (STF)", d, .purple))
        }
        if let d = stats.quickStackDuration {
            let frames = stats.quickStackFrameCount
            items.append(("Quick Stack (\(frames)f)", d, .cyan))
        }
        if let d = stats.totalSessionDuration {
            items.append(("Total Ready", d, .red))
        }

        return items
    }

    // Maximum duration for scaling the bars
    private var maxDuration: Double {
        barItems.map(\.duration).max() ?? 1.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Session Load Benchmark")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if stats.fileCount > 0 {
                    Text("\(stats.formattedTotalSize) from \(stats.fileCount) files")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            if stats.sessionStartTime == nil {
                // No data yet
                VStack(spacing: 8) {
                    Spacer()
                    Text("No benchmark data yet")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text("Open a folder to start measuring performance.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Bar chart
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(barItems.enumerated()), id: \.offset) { _, item in
                        barRow(label: item.label, duration: item.duration, color: item.color)
                    }
                }

                // Status indicator
                if !stats.isComplete && stats.sessionStartTime != nil {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                        Text("Session loading in progress...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Memory section
                memorySection
            }

            // Share & Compare button — uploads benchmarks and opens leaderboard
            if stats.totalSessionDuration != nil || stats.quickStackDuration != nil {
                Divider()

                HStack {
                    Spacer()

                    Button(action: { shareBenchmarks() }) {
                        HStack(spacing: 4) {
                            Image(systemName: benchmarkService.isUploading ? "arrow.triangle.2.circlepath" : "trophy")
                                .font(.system(size: 12))
                            Text("Share & Compare")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.regular)
                    .disabled(benchmarkService.isUploading || !BenchmarkConfig.isConfigured)
                    .help("Share your benchmarks and see the community leaderboard")

                    Spacer()
                }
            }

            Spacer(minLength: 4)
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 320)
        .onAppear {
            memorySnapshot = stats.captureMemorySnapshot()
        }
        // Refresh memory snapshot periodically while visible
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            memorySnapshot = stats.captureMemorySnapshot()
        }
    }

    // Upload all available benchmarks and open the leaderboard
    private func shareBenchmarks() {
        let sourceType = MachineInfo.sourceType(for: sessionRootURL)
        var engine = "lightspeed"

        Task {
            // Upload stacking benchmark if available
            if let stackDuration = stats.quickStackDuration {
                engine = stats.quickStackEngine
                let stackEntry = BenchmarkService.buildEntry(
                    engine: engine,
                    stackTimeMs: Int(stackDuration * 1000),
                    fileCount: stats.quickStackFrameCount,
                    imageWidth: stats.quickStackImageWidth,
                    imageHeight: stats.quickStackImageHeight
                )
                await benchmarkService.shareAndCompare(entry: stackEntry)
            }

            // Upload session load benchmark if available
            if let totalDuration = stats.totalSessionDuration {
                let sessionEntry = BenchmarkService.buildSessionEntry(
                    fileCount: stats.fileCount,
                    totalSizeBytes: stats.totalFileSizeBytes,
                    sourceType: sourceType,
                    scanMs: Int((stats.fileLoadingDuration ?? 0) * 1000),
                    firstImageMs: Int((stats.firstImageDuration ?? 0) * 1000),
                    headerMs: Int((stats.headerEnrichDuration ?? 0) * 1000),
                    cachingMs: Int((stats.cachingDuration ?? 0) * 1000),
                    totalReadyMs: Int(totalDuration * 1000)
                )
                await benchmarkService.shareSessionBenchmark(entry: sessionEntry)
            }

            // Open leaderboard
            BenchmarkLeaderboardWindowController.shared.show(
                service: benchmarkService,
                myMachineHash: MachineInfo.machineHash,
                engine: engine
            )
        }
    }

    // Single bar row: label on left, colored bar proportional to duration, value on right
    private func barRow(label: String, duration: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 110, alignment: .leading)

                GeometryReader { geo in
                    let barWidth = maxDuration > 0
                        ? max(4, geo.size.width * CGFloat(duration / maxDuration))
                        : 4

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.8))
                        .frame(width: barWidth, height: 18)
                }
                .frame(height: 18)

                Text(BenchmarkStats.formatDuration(duration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    // Memory usage display
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory")
                .font(.system(size: 13, weight: .semibold))

            if let mem = memorySnapshot {
                HStack(spacing: 20) {
                    memoryItem(
                        label: "App RAM",
                        value: mem.appResidentMB >= 1024
                            ? String(format: "%.1f GB", mem.appResidentMB / 1024)
                            : String(format: "%.0f MB", mem.appResidentMB)
                    )

                    memoryItem(
                        label: "System Total",
                        value: String(format: "%.0f GB", mem.systemTotalGB)
                    )

                    memoryItem(
                        label: "Swap",
                        value: mem.swapUsedMB < 1
                            ? "None"
                            : mem.swapUsedMB >= 1024
                                ? String(format: "%.1f GB", mem.swapUsedMB / 1024)
                                : String(format: "%.0f MB", mem.swapUsedMB)
                    )
                }

                // Visual memory bar showing app usage relative to system total
                let usageFraction = mem.appResidentMB / (mem.systemTotalGB * 1024)
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 10)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(usageFraction > 0.7 ? Color.red.opacity(0.7) : Color.accentColor.opacity(0.6))
                                .frame(width: max(4, geo.size.width * CGFloat(usageFraction)), height: 10)
                        }
                    }
                    .frame(height: 10)

                    Text(String(format: "%.1f%% of system RAM", usageFraction * 100))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Measuring...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func memoryItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }
}

// Benchmark sharing service — anonymous upload + leaderboard fetch via Supabase REST API.
// Machine identity is a SHA256 hash of the hardware UUID (consistent, anonymous, not reversible).
// Two benchmark types: stacking performance and session load performance.

import Foundation
import CryptoKit
import Metal
import IOKit

// MARK: - Configuration

// Supabase project config — anon key allows insert + select only (RLS enforced)
enum BenchmarkConfig {
    static let supabaseURL = "https://bpngramreznwvtssrcbe.supabase.co"
    static let supabaseAnonKey = "sb_publishable_NROHg8DwJvvdfdyr7JIcog_nILiDe9U"
    static var isConfigured: Bool {
        !supabaseURL.contains("YOUR_PROJECT") && !supabaseAnonKey.contains("YOUR_ANON_KEY")
    }
}

// MARK: - Stacking Benchmark Model

struct BenchmarkEntry: Codable, Identifiable {
    var id: String?
    let machine_hash: String
    let machine_model: String
    let chip_name: String
    let cpu_cores: Int
    let ram_gb: Int
    let app_version: String
    let file_count: Int
    let stack_engine: String        // "lightspeed" or "normal"
    let stack_time_ms: Int
    let image_megapixels: Double
    let created_at: String?

    // Computed: seconds per frame — the universal ranking metric
    var timePerFrame: Double {
        guard file_count > 0 else { return 0 }
        return Double(stack_time_ms) / Double(file_count) / 1000.0
    }

    // Computed: ms per megapixel per frame — normalized for image size
    var msPerMPPerFrame: Double {
        guard file_count > 0, image_megapixels > 0 else { return 0 }
        return Double(stack_time_ms) / Double(file_count) / image_megapixels
    }

    var formattedTime: String {
        let seconds = Double(stack_time_ms) / 1000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let min = Int(seconds) / 60
            let sec = seconds - Double(min * 60)
            return String(format: "%dm %04.1fs", min, sec)
        }
    }

    var formattedDateTime: String {
        Self.formatISO(created_at)
    }

    // Shared ISO 8601 date+time formatter: "03-13 14:32"
    static func formatISO(_ ts: String?) -> String {
        guard let ts = ts, ts.count >= 16 else { return "—" }
        let dateStr = String(ts.prefix(16))
        let parts = dateStr.split(separator: "T")
        guard parts.count == 2 else { return String(ts.prefix(10)) }
        return "\(parts[0].dropFirst(5)) \(parts[1])"
    }
}

// MARK: - Session Load Benchmark Model

struct SessionBenchmarkEntry: Codable, Identifiable {
    var id: String?
    let machine_hash: String
    let machine_model: String
    let chip_name: String
    let cpu_cores: Int
    let ram_gb: Int
    let app_version: String
    let file_count: Int
    let total_size_bytes: Int64
    let source_type: String         // "local", "network", "unknown"
    let scan_ms: Int
    let first_image_ms: Int
    let header_ms: Int
    let caching_ms: Int
    let total_ready_ms: Int
    let created_at: String?

    // Throughput: MB/s for total session load
    var throughputMBs: Double {
        guard total_ready_ms > 0 else { return 0 }
        let mb = Double(total_size_bytes) / (1024.0 * 1024.0)
        return mb / (Double(total_ready_ms) / 1000.0)
    }

    // Files per second
    var filesPerSecond: Double {
        guard total_ready_ms > 0 else { return 0 }
        return Double(file_count) / (Double(total_ready_ms) / 1000.0)
    }

    var formattedTotalTime: String {
        let seconds = Double(total_ready_ms) / 1000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let min = Int(seconds) / 60
            let sec = seconds - Double(min * 60)
            return String(format: "%dm %04.1fs", min, sec)
        }
    }

    var formattedSize: String {
        let gb = Double(total_size_bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 { return String(format: "%.1fG", gb) }
        let mb = Double(total_size_bytes) / (1024.0 * 1024.0)
        return String(format: "%.0fM", mb)
    }

    var formattedDateTime: String {
        BenchmarkEntry.formatISO(created_at)
    }
}

// MARK: - Machine Info

enum MachineInfo {

    /// SHA256 hash of hardware UUID — anonymous but consistent per machine
    static var machineHash: String {
        guard let uuid = hardwareUUID() else { return "unknown" }
        let hash = SHA256.hash(data: Data(uuid.utf8))
        return hash.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static var machineModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    static var chipName: String {
        MTLCreateSystemDefaultDevice()?.name ?? "Unknown"
    }

    static var cpuCores: Int {
        ProcessInfo.processInfo.processorCount
    }

    static var ramGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Detect if a path is on a local disk or network volume
    static func sourceType(for url: URL?) -> String {
        guard let url = url else { return "unknown" }
        do {
            let values = try url.resourceValues(forKeys: [.volumeIsLocalKey])
            if let isLocal = values.volumeIsLocal {
                return isLocal ? "local" : "network"
            }
        } catch {}
        return "unknown"
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuidRef = IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        return uuidRef
    }
}

// MARK: - Sort Columns

enum BenchmarkSortColumn: String, CaseIterable {
    case timePerFrame = "t/frame"
    case totalTime = "Time"
    case frames = "Frames"
    case megapixels = "MP"
    case msPerMP = "ms/MP/f"
    case chip = "Chip"
    case cores = "Cores"
    case ram = "RAM"
    case version = "Ver"
    case date = "Date"
}

enum SessionSortColumn: String, CaseIterable {
    case throughput = "MB/s"
    case totalTime = "Total"
    case scanTime = "Scan"
    case firstImage = "1st Img"
    case headerTime = "Headers"
    case cacheTime = "Cache"
    case files = "Files"
    case size = "Size"
    case source = "Source"
    case chip = "Chip"
    case cores = "Cores"
    case ram = "RAM"
    case date = "Date"
}

// MARK: - Benchmark Service

@MainActor
class BenchmarkService: ObservableObject {
    // Stacking leaderboard
    @Published var leaderboard: [BenchmarkEntry] = []
    // Session load leaderboard
    @Published var sessionLeaderboard: [SessionBenchmarkEntry] = []

    @Published var isUploading = false
    @Published var isFetching = false
    @Published var errorMessage: String?
    @Published var uploadedSuccessfully = false

    // Stacking sort state
    @Published var sortColumn: BenchmarkSortColumn = .timePerFrame
    @Published var sortAscending: Bool = true

    // Session sort state
    @Published var sessionSortColumn: SessionSortColumn = .throughput
    @Published var sessionSortAscending: Bool = false  // highest throughput first

    // MARK: - Stacking sorted

    var sortedLeaderboard: [BenchmarkEntry] {
        leaderboard.sorted { a, b in
            let cmp: Int
            switch sortColumn {
            case .timePerFrame: cmp = cmpD(a.timePerFrame, b.timePerFrame)
            case .totalTime:    cmp = cmpI(a.stack_time_ms, b.stack_time_ms)
            case .frames:       cmp = cmpI(a.file_count, b.file_count)
            case .megapixels:   cmp = cmpD(a.image_megapixels, b.image_megapixels)
            case .msPerMP:      cmp = cmpD(a.msPerMPPerFrame, b.msPerMPPerFrame)
            case .chip:         cmp = cmpS(a.chip_name, b.chip_name)
            case .cores:        cmp = cmpI(a.cpu_cores, b.cpu_cores)
            case .ram:          cmp = cmpI(a.ram_gb, b.ram_gb)
            case .version:      cmp = cmpS(a.app_version, b.app_version)
            case .date:         cmp = cmpS(a.created_at ?? "", b.created_at ?? "")
            }
            if cmp == 0 { return cmpD(a.timePerFrame, b.timePerFrame) < 0 }
            return sortAscending ? (cmp < 0) : (cmp > 0)
        }
    }

    // MARK: - Session sorted

    var sortedSessionLeaderboard: [SessionBenchmarkEntry] {
        sessionLeaderboard.sorted { a, b in
            let cmp: Int
            switch sessionSortColumn {
            case .throughput:  cmp = cmpD(a.throughputMBs, b.throughputMBs)
            case .totalTime:   cmp = cmpI(a.total_ready_ms, b.total_ready_ms)
            case .scanTime:    cmp = cmpI(a.scan_ms, b.scan_ms)
            case .firstImage:  cmp = cmpI(a.first_image_ms, b.first_image_ms)
            case .headerTime:  cmp = cmpI(a.header_ms, b.header_ms)
            case .cacheTime:   cmp = cmpI(a.caching_ms, b.caching_ms)
            case .files:       cmp = cmpI(a.file_count, b.file_count)
            case .size:        cmp = cmpI(Int(a.total_size_bytes), Int(b.total_size_bytes))
            case .source:      cmp = cmpS(a.source_type, b.source_type)
            case .chip:        cmp = cmpS(a.chip_name, b.chip_name)
            case .cores:       cmp = cmpI(a.cpu_cores, b.cpu_cores)
            case .ram:         cmp = cmpI(a.ram_gb, b.ram_gb)
            case .date:        cmp = cmpS(a.created_at ?? "", b.created_at ?? "")
            }
            if cmp == 0 { return cmpD(a.throughputMBs, b.throughputMBs) > 0 }
            return sessionSortAscending ? (cmp < 0) : (cmp > 0)
        }
    }

    // MARK: - Sort helpers

    private func cmpD(_ a: Double, _ b: Double) -> Int { a < b ? -1 : (a > b ? 1 : 0) }
    private func cmpI(_ a: Int, _ b: Int) -> Int { a < b ? -1 : (a > b ? 1 : 0) }
    private func cmpS(_ a: String, _ b: String) -> Int { a < b ? -1 : (a > b ? 1 : 0) }

    func toggleSort(_ column: BenchmarkSortColumn) {
        if sortColumn == column { sortAscending.toggle() }
        else { sortColumn = column; sortAscending = true }
    }

    func toggleSessionSort(_ column: SessionSortColumn) {
        if sessionSortColumn == column { sessionSortAscending.toggle() }
        else {
            sessionSortColumn = column
            // Default descending for throughput/files/size, ascending for times
            sessionSortAscending = [.totalTime, .scanTime, .firstImage, .headerTime, .cacheTime, .date].contains(column)
        }
    }

    // MARK: - Stacking upload + fetch

    func shareAndCompare(entry: BenchmarkEntry) async {
        guard BenchmarkConfig.isConfigured else {
            errorMessage = "Benchmark sharing not configured"; return
        }
        isUploading = true; errorMessage = nil
        do {
            let isDuplicate = try await checkDuplicate(table: "benchmarks", filters: [
                "machine_hash": entry.machine_hash,
                "stack_engine": entry.stack_engine,
                "file_count": "\(entry.file_count)",
                "stack_time_ms": "\(entry.stack_time_ms)"
            ])
            if !isDuplicate {
                try await upload(table: "benchmarks", entry: entry)
            }
            uploadedSuccessfully = true; isUploading = false
            try await fetchLeaderboard(engine: entry.stack_engine)
        } catch {
            errorMessage = error.localizedDescription; isUploading = false
        }
    }

    func fetchLeaderboard(engine: String) async throws {
        isFetching = true; defer { isFetching = false }
        let urlString = "\(BenchmarkConfig.supabaseURL)/rest/v1/benchmarks" +
            "?select=*&stack_engine=eq.\(engine)&limit=200"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BenchmarkError.fetchFailed
        }
        let entries = try JSONDecoder().decode([BenchmarkEntry].self, from: data)
        leaderboard = entries.sorted { $0.timePerFrame < $1.timePerFrame }
    }

    // MARK: - Session upload + fetch

    func shareSessionBenchmark(entry: SessionBenchmarkEntry) async {
        guard BenchmarkConfig.isConfigured else {
            errorMessage = "Benchmark sharing not configured"; return
        }
        isUploading = true; errorMessage = nil
        do {
            let isDuplicate = try await checkDuplicate(table: "session_benchmarks", filters: [
                "machine_hash": entry.machine_hash,
                "file_count": "\(entry.file_count)",
                "total_ready_ms": "\(entry.total_ready_ms)"
            ])
            if !isDuplicate {
                try await upload(table: "session_benchmarks", entry: entry)
            }
            uploadedSuccessfully = true; isUploading = false
            try await fetchSessionLeaderboard(sourceType: nil)
        } catch {
            errorMessage = error.localizedDescription; isUploading = false
        }
    }

    func fetchSessionLeaderboard(sourceType: String?) async throws {
        isFetching = true; defer { isFetching = false }
        var urlString = "\(BenchmarkConfig.supabaseURL)/rest/v1/session_benchmarks?select=*&limit=200"
        if let src = sourceType {
            urlString += "&source_type=eq.\(src)"
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BenchmarkError.fetchFailed
        }
        let entries = try JSONDecoder().decode([SessionBenchmarkEntry].self, from: data)
        sessionLeaderboard = entries.sorted { $0.throughputMBs > $1.throughputMBs }
    }

    // MARK: - Generic helpers

    private func checkDuplicate(table: String, filters: [String: String]) async throws -> Bool {
        var urlString = "\(BenchmarkConfig.supabaseURL)/rest/v1/\(table)?select=id&limit=1"
        for (key, value) in filters {
            urlString += "&\(key)=eq.\(value)"
        }
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
        let results = try JSONDecoder().decode([[String: String]].self, from: data)
        return !results.isEmpty
    }

    private func upload<T: Encodable>(table: String, entry: T) async throws {
        guard let url = URL(string: "\(BenchmarkConfig.supabaseURL)/rest/v1/\(table)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(entry)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BenchmarkError.uploadFailed
        }
    }

    // MARK: - Entry builders

    static func buildEntry(
        engine: String, stackTimeMs: Int, fileCount: Int,
        imageWidth: Int, imageHeight: Int
    ) -> BenchmarkEntry {
        let megapixels = Double(imageWidth * imageHeight) / 1_000_000.0
        return BenchmarkEntry(
            id: nil, machine_hash: MachineInfo.machineHash,
            machine_model: MachineInfo.machineModel, chip_name: MachineInfo.chipName,
            cpu_cores: MachineInfo.cpuCores, ram_gb: MachineInfo.ramGB,
            app_version: MachineInfo.appVersion, file_count: fileCount,
            stack_engine: engine, stack_time_ms: stackTimeMs,
            image_megapixels: megapixels, created_at: nil
        )
    }

    static func buildSessionEntry(
        fileCount: Int, totalSizeBytes: Int64, sourceType: String,
        scanMs: Int, firstImageMs: Int, headerMs: Int,
        cachingMs: Int, totalReadyMs: Int
    ) -> SessionBenchmarkEntry {
        SessionBenchmarkEntry(
            id: nil, machine_hash: MachineInfo.machineHash,
            machine_model: MachineInfo.machineModel, chip_name: MachineInfo.chipName,
            cpu_cores: MachineInfo.cpuCores, ram_gb: MachineInfo.ramGB,
            app_version: MachineInfo.appVersion, file_count: fileCount,
            total_size_bytes: totalSizeBytes, source_type: sourceType,
            scan_ms: scanMs, first_image_ms: firstImageMs,
            header_ms: headerMs, caching_ms: cachingMs,
            total_ready_ms: totalReadyMs, created_at: nil
        )
    }

    enum BenchmarkError: LocalizedError {
        case uploadFailed, fetchFailed
        var errorDescription: String? {
            switch self {
            case .uploadFailed: return "Failed to upload benchmark"
            case .fetchFailed: return "Failed to fetch leaderboard"
            }
        }
    }
}

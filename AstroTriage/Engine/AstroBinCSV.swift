// v6.13.0
import Foundation

/// AstroBin acquisition CSV (6.13.0) — the text block AstroBin's "Import from CSV" accepts
/// for deep-sky acquisitions (https://welcome.astrobin.com/importing-acquisitions-from-csv).
///
/// Rules taken from that page: the first line is a header line, no spaces around commas,
/// only `number` and `duration` are mandatory, `filter` is the NUMERIC ID of the filter in
/// AstroBin's equipment database (the number in the filter page's URL), invalid or empty
/// values are ignored. One line = one night x filter x sub length (x binning x gain).
///
/// GUI-free and pure, so it is covered by Tests/AstroBinCSVTests.swift.
enum AstroBinCSV {

    /// One acquisition line: the light frames of one object, night, filter and sub length.
    struct Group: Equatable {
        let object: String          // target as shown in the Session Overview ("unknown" when empty)
        let date: String            // observing night, YYYY-MM-DD ("" when no date is known)
        let filter: String          // filter name as in the file ("" when none)
        let duration: Double        // seconds per sub
        let binning: Int?           // 1…4
        let gain: Int?
        let number: Int             // sub count
        let sensorCooling: Int?     // mean sensor temperature, whole °C
        let bortle: Int?            // 1…9
        let meanFwhm: Double?       // arcseconds — only from MEASURED star sizes with a known plate scale
        let temperature: Double?    // mean ambient temperature, °C
    }

    /// Group the LIGHT frames (frames without a frame type count as lights) into acquisition lines.
    static func groups(from images: [ImageEntry]) -> [Group] {
        struct Key: Hashable {
            let object: String, date: String, filter: String
            let duration: Double
            let binning: Int?, gain: Int?
        }
        struct Sums {
            var number = 0
            var cooling: [Double] = [], bortle: [Double] = [], fwhm: [Double] = [], ambient: [Double] = []
        }
        var buckets: [Key: Sums] = [:]

        for entry in images {
            if let type = entry.frameType, !type.isEmpty, type.uppercased() != "LIGHT" { continue }
            // Keyed at the precision the CSV prints (4 decimals): 299.99999 s and 300 s are one line.
            guard let raw = entry.exposure else { continue }
            let duration = (raw * 10_000).rounded() / 10_000
            guard duration > 0 else { continue }
            let key = Key(object: displayName(entry.target),
                          date: String((entry.observingNight ?? "").prefix(10)),
                          filter: (entry.filter ?? "").trimmingCharacters(in: .whitespaces),
                          duration: duration,
                          binning: binningFactor(entry.binning),
                          gain: entry.gain)
            var sums = buckets[key] ?? Sums()
            sums.number += 1
            if let v = entry.sensorTemp { sums.cooling.append(v) }
            if let v = entry.bortleClass { sums.bortle.append(v) }
            if let v = entry.ambientTemp { sums.ambient.append(v) }
            if let px = entry.computedFWHM, px > 0, let scale = entry.arcsecPerPixel { sums.fwhm.append(px * scale) }
            buckets[key] = sums
        }

        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return buckets.map { key, sums in
            Group(object: key.object, date: key.date, filter: key.filter, duration: key.duration,
                  binning: key.binning, gain: key.gain, number: sums.number,
                  sensorCooling: mean(sums.cooling).map { Int($0.rounded()) }.flatMap { (-274...100).contains($0) ? $0 : nil },
                  bortle: mean(sums.bortle).map { min(9, max(1, Int($0.rounded()))) },
                  meanFwhm: mean(sums.fwhm),
                  temperature: mean(sums.ambient).flatMap { (-88.0...58.0).contains($0) ? $0 : nil })
        }
        .sorted { a, b in
            if a.object != b.object { return a.object < b.object }
            if a.date != b.date { return a.date < b.date }
            let fa = FrameHistoryModel.filterSortOrder(a.filter), fb = FrameHistoryModel.filterSortOrder(b.filter)
            if fa != fb { return fa < fb }
            if a.filter != b.filter { return a.filter < b.filter }
            return a.duration < b.duration
        }
    }

    /// The CSV text for one object (`nil` = every object). `filterIDs` maps `filterKey(name)`
    /// to the AstroBin filter ID; a filter without an ID leaves its `filter` cell empty.
    /// Optional columns appear only when at least one line has a value for them.
    static func csv(groups: [Group], object: String?, filterIDs: [String: String]) -> String {
        let lines = groups.filter { object == nil || $0.object == object }
        guard !lines.isEmpty else { return "" }

        typealias Column = (name: String, value: (Group) -> String)
        var columns: [Column] = [
            ("date", { $0.date }),
            ("filter", { filterIDs[filterKey($0.filter)].flatMap { validFilterID($0) } ?? "" }),
            ("number", { String($0.number) }),
            ("duration", { decimal($0.duration, places: 4) }),
        ]
        let optional: [Column] = [
            ("binning", { $0.binning.map(String.init) ?? "" }),
            ("gain", { $0.gain.map(String.init) ?? "" }),
            ("sensorCooling", { $0.sensorCooling.map(String.init) ?? "" }),
            ("bortle", { $0.bortle.map(String.init) ?? "" }),
            ("meanFwhm", { $0.meanFwhm.map { decimal($0, places: 2) } ?? "" }),
            ("temperature", { $0.temperature.map { decimal($0, places: 2) } ?? "" }),
        ]
        columns += optional.filter { column in lines.contains { !column.value($0).isEmpty } }

        let header = columns.map(\.name).joined(separator: ",")
        let body = lines.map { line in columns.map { $0.value(line) }.joined(separator: ",") }
        return ([header] + body).joined(separator: "\n")
    }

    /// Distinct filter names of one object's lines, in line order ("" = no filter, left out).
    static func filterNames(in groups: [Group], object: String?) -> [String] {
        var seen = Set<String>(), names: [String] = []
        for group in groups where (object == nil || group.object == object) && !group.filter.isEmpty {
            if seen.insert(filterKey(group.filter)).inserted { names.append(group.filter) }
        }
        return names
    }

    /// Lookup key of a filter name in the ID table: case- and whitespace-insensitive.
    static func filterKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// An AstroBin filter ID is a positive whole number; anything else is not written.
    static func validFilterID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let n = Int(trimmed), n > 0 else { return nil }
        return String(n)
    }

    // MARK: - Filter ID table (per user, kept across sessions)

    private static let filterIDsKey = "astrobinFilterIDs"

    static func loadFilterIDs() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: filterIDsKey) as? [String: String] ?? [:]
    }

    static func saveFilterIDs(_ ids: [String: String]) {
        UserDefaults.standard.set(ids.filter { validFilterID($0.value) != nil }, forKey: filterIDsKey)
    }

    // MARK: - Helpers

    /// Same naming as the Session Overview: an empty target is "unknown".
    static func displayName(_ target: String?) -> String {
        let name = (target ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "unknown" : name
    }

    /// "2x2" → 2; only the values AstroBin accepts (1…4).
    static func binningFactor(_ binning: String?) -> Int? {
        guard let first = binning?.lowercased().split(separator: "x").first,
              let n = Int(first.trimmingCharacters(in: .whitespaces)), (1...4).contains(n) else { return nil }
        return n
    }

    /// Fixed-point with at most `places` decimals, trailing zeros removed, "." as separator.
    static func decimal(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

// AIsaac — Persistent user equipment profile
// Learns from FITS/XISF headers across sessions. Stored locally as JSON.
// Enables "what should I shoot tonight?" even without a session loaded.
import Foundation

struct AIsaacUserProfile: Codable {

    // Known equipment setups (deduplicated by telescope+camera)
    var equipmentSetups: [EquipmentSetup] = []

    // Known imaging locations (deduplicated by rounded lat/lon)
    var locations: [ImagingLocation] = []

    // Previously imaged objects with dates
    var imagedObjects: [ImagedObject] = []

    // Known filter sets (all filters the user has ever used)
    var knownFilters: Set<String> = []

    // Preferred language (learned from user choice, e.g. "de", "en", "nl")
    var preferredLanguage: String?

    // Last updated timestamp
    var lastUpdated: Date = Date()

    struct EquipmentSetup: Codable, Hashable {
        let telescope: String
        let camera: String
        let focalLength: Double?
        let pixelSize: Double?
        var lastUsed: Date

        // Computed FOV description
        var description: String {
            var parts = [telescope, camera]
            if let fl = focalLength { parts.append("\(Int(fl))mm") }
            return parts.joined(separator: " + ")
        }
    }

    struct ImagingLocation: Codable, Hashable {
        let latitude: Double   // rounded to 0.1 degree for privacy
        let longitude: Double  // rounded to 0.1 degree for privacy
        var lastUsed: Date

        // Rough location description for Claude (Claude can infer country/Bortle)
        var description: String {
            return String(format: "%.1fN, %.1fE", latitude, longitude)
        }
    }

    struct ImagedObject: Codable, Hashable {
        let name: String
        var filters: Set<String>
        var sessionDates: [String]  // YYYY-MM-DD
        var totalFrames: Int
        var lastImaged: Date
        // Planning-relevant data (learned from quality scoring)
        var perFilterFrames: [String: Int]?         // e.g. {"Ha": 40, "OIII": 20, "L": 60}
        var perFilterIntegrationMin: [String: Int]? // total integration per filter in minutes
        var avgQualityScore: Double?                // average combined z-score (higher = better data)
        var needsMoreData: Bool?                    // true if quality is borderline or filters unbalanced
        var userNote: String?                       // user can add notes like "needs more SII"
    }

    // MARK: - Learning

    // Update profile from a loaded session's images
    mutating func learnFrom(images: [ImageEntry]) {
        guard !images.isEmpty else { return }
        lastUpdated = Date()

        // Learn equipment
        let telescope = images.first(where: { $0.telescope != nil })?.telescope
        let camera = images.first(where: { $0.camera != nil })?.camera
        let focalLength = images.first(where: { $0.focalLength != nil })?.focalLength
        let pixelSize = images.first(where: { $0.pixelSizeMicrons != nil })?.pixelSizeMicrons

        if let telescope = telescope, let camera = camera {
            let setup = EquipmentSetup(
                telescope: telescope, camera: camera,
                focalLength: focalLength, pixelSize: pixelSize,
                lastUsed: Date()
            )
            // Update existing or add new
            if let idx = equipmentSetups.firstIndex(where: {
                $0.telescope == telescope && $0.camera == camera
            }) {
                equipmentSetups[idx] = setup
            } else {
                equipmentSetups.append(setup)
            }
        }

        // Learn location (round for privacy)
        if let lat = images.first(where: { $0.siteLatitude != nil })?.siteLatitude,
           let lon = images.first(where: { $0.siteLongitude != nil })?.siteLongitude {
            let roundedLat = (lat * 10).rounded() / 10
            let roundedLon = (lon * 10).rounded() / 10
            let loc = ImagingLocation(latitude: roundedLat, longitude: roundedLon, lastUsed: Date())

            let rLat = roundedLat
            let rLon = roundedLon
            let matchIdx = locations.firstIndex { existing in
                Swift.abs(existing.latitude - rLat) < 0.2 && Swift.abs(existing.longitude - rLon) < 0.2
            }
            if let idx = matchIdx {
                locations[idx] = loc
            } else {
                locations.append(loc)
            }
        }

        // Learn filters
        let sessionFilters = Set(images.compactMap { $0.filter }.filter { !$0.isEmpty })
        knownFilters.formUnion(sessionFilters)

        // Learn objects
        let sessionDate = images.first(where: { $0.date != nil })?.date ?? "unknown"
        let targets = Set(images.compactMap { $0.target }.filter { !$0.isEmpty })
        for target in targets {
            let targetImages = images.filter { $0.target == target }
            let targetFilters = Set(targetImages.compactMap { $0.filter }.filter { !$0.isEmpty })

            // Per-filter frame counts and integration time
            var perFilterFrames: [String: Int] = [:]
            var perFilterIntegration: [String: Int] = [:]
            for img in targetImages {
                let f = img.filter ?? "unknown"
                perFilterFrames[f, default: 0] += 1
                if let exp = img.exposure {
                    perFilterIntegration[f, default: 0] += Int(exp / 60.0)
                }
            }

            // Average quality score
            let zScores = targetImages.compactMap { $0.qualityBreakdown?.combinedZScore }
            let avgZ = zScores.isEmpty ? nil : zScores.reduce(0, +) / Double(zScores.count)

            // Detect if more data is needed (many borderline/trash or unbalanced filters)
            let trashCount = targetImages.filter { $0.qualityTier == .trash }.count
            let borderlineCount = targetImages.filter { $0.qualityTier == .borderline }.count
            let needsMore = Double(trashCount + borderlineCount) / Double(max(1, targetImages.count)) > 0.3

            if let idx = imagedObjects.firstIndex(where: { $0.name == target }) {
                imagedObjects[idx].totalFrames += targetImages.count
                imagedObjects[idx].lastImaged = Date()
                if !imagedObjects[idx].sessionDates.contains(sessionDate) {
                    imagedObjects[idx].sessionDates.append(sessionDate)
                }
                imagedObjects[idx].filters.formUnion(targetFilters)
                imagedObjects[idx].perFilterFrames = perFilterFrames
                imagedObjects[idx].perFilterIntegrationMin = perFilterIntegration
                imagedObjects[idx].avgQualityScore = avgZ
                imagedObjects[idx].needsMoreData = needsMore
            } else {
                imagedObjects.append(ImagedObject(
                    name: target, filters: targetFilters,
                    sessionDates: [sessionDate],
                    totalFrames: targetImages.count,
                    lastImaged: Date(),
                    perFilterFrames: perFilterFrames,
                    perFilterIntegrationMin: perFilterIntegration,
                    avgQualityScore: avgZ,
                    needsMoreData: needsMore
                ))
            }
        }
    }

    // MARK: - Context for AIsaac

    // Build a text summary for the system prompt
    func contextSummary() -> String? {
        guard !equipmentSetups.isEmpty || !imagedObjects.isEmpty else { return nil }

        var lines: [String] = ["USER EQUIPMENT PROFILE (learned from previous sessions):"]

        if let lang = preferredLanguage {
            lines.append("- Preferred language: \(lang) — ALWAYS respond in this language unless the user writes in a different one.")
        }

        if !equipmentSetups.isEmpty {
            lines.append("Equipment setups:")
            for setup in equipmentSetups.sorted(by: { $0.lastUsed > $1.lastUsed }) {
                var desc = "  - \(setup.description)"
                if let px = setup.pixelSize, let fl = setup.focalLength, fl > 0 {
                    let arcsec = 206.265 * px / fl
                    desc += " (\(String(format: "%.2f", arcsec))\"/px)"
                }
                lines.append(desc)
            }
        }

        if !locations.isEmpty {
            lines.append("Imaging locations:")
            for loc in locations.sorted(by: { $0.lastUsed > $1.lastUsed }) {
                lines.append("  - \(loc.description)")
            }
        }

        if !knownFilters.isEmpty {
            lines.append("Available filters: \(knownFilters.sorted().joined(separator: ", "))")
        }

        if !imagedObjects.isEmpty {
            let recent = imagedObjects.sorted(by: { $0.lastImaged > $1.lastImaged }).prefix(15)
            lines.append("Previously imaged objects (most recent first):")
            lines.append("  (Note: frame counts are approximate — do NOT cite exact numbers to the user)")
            for obj in recent {
                let dateStr = obj.sessionDates.last ?? "?"
                let filterList = obj.filters.sorted().joined(separator: ", ")
                var desc = "  - \(obj.name): filters used: \(filterList) (last session: \(dateStr))"
                if obj.needsMoreData == true {
                    desc += " — quality was mixed, could benefit from more data"
                }
                if let note = obj.userNote {
                    desc += " [user note: \(note)]"
                }
                lines.append(desc)
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence (iCloud Drive with local fallback)

    private static let fileName = "aisaac_profile.json"

    // iCloud Drive URL (nil if iCloud unavailable)
    private static var iCloudURL: URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.joergsflow.AstroBlinkV2") else {
            return nil
        }
        let dir = container.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    // Local fallback URL
    private static var localURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AstroBlinkV2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> AIsaacUserProfile {
        // Try iCloud first, then local
        let urls = [iCloudURL, localURL].compactMap { $0 }
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let profile = try? JSONDecoder().decode(AIsaacUserProfile.self, from: data) {
                return profile
            }
        }
        return AIsaacUserProfile()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        // Save to both iCloud and local (local is instant backup)
        try? data.write(to: Self.localURL, options: .atomic)
        if let icloudURL = Self.iCloudURL {
            try? data.write(to: icloudURL, options: .atomic)
        }
    }

    /// Delete both the local and iCloud copy of the profile JSON.
    /// In-memory profiles held by AIsaacContextBuilder etc. are NOT cleared by this —
    /// the next AIsaacUserProfile.load() call will return a fresh blank profile.
    static func delete() {
        let fm = FileManager.default
        try? fm.removeItem(at: localURL)
        if let icloud = iCloudURL {
            try? fm.removeItem(at: icloud)
        }
    }

    /// Write a pretty-printed copy of the profile to the given URL (typically
    /// a user-chosen location via NSSavePanel). Throws on encoding/write failure.
    func exportTo(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

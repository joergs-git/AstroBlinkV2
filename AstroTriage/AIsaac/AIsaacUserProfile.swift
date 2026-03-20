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

            if let idx = imagedObjects.firstIndex(where: { $0.name == target }) {
                imagedObjects[idx].totalFrames += targetImages.count
                imagedObjects[idx].lastImaged = Date()
                if !imagedObjects[idx].sessionDates.contains(sessionDate) {
                    imagedObjects[idx].sessionDates.append(sessionDate)
                }
                imagedObjects[idx].filters.formUnion(targetFilters)
            } else {
                imagedObjects.append(ImagedObject(
                    name: target, filters: targetFilters,
                    sessionDates: [sessionDate],
                    totalFrames: targetImages.count,
                    lastImaged: Date()
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
            for obj in recent {
                let dateStr = obj.sessionDates.last ?? "?"
                lines.append("  - \(obj.name): \(obj.totalFrames) frames in \(obj.filters.sorted().joined(separator: ",")) (last: \(dateStr))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AstroBlinkV2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aisaac_profile.json")
    }

    static func load() -> AIsaacUserProfile {
        guard let data = try? Data(contentsOf: fileURL),
              let profile = try? JSONDecoder().decode(AIsaacUserProfile.self, from: data) else {
            return AIsaacUserProfile()
        }
        return profile
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

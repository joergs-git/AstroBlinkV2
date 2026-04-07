// Deep-sky target database with astronomical properties for target-aware quality scoring,
// filter recommendations, FOV fill ratio computation, and imaging planner features.
// Data sourced from SIMBAD, NGC/IC catalogs, and established astrophotography references.
//
// v5.14.0 — Initial target database with ~500 objects

import Foundation

// MARK: - Target Type Classification

/// Classification of deep-sky objects by their physical nature.
/// Determines scoring weight modifiers (FWHM, stars, noise, trailing importance).
enum TargetType: String, Codable, CaseIterable {
    case galaxy              // Spiral, barred, irregular, elliptical galaxies
    case galaxyGroup         // Interacting pairs, triplets, galaxy clusters
    case emissionNebula      // HII regions, star-forming regions with emission lines
    case reflectionNebula    // Dust clouds illuminated by nearby stars
    case planetaryNebula     // Shells ejected by dying stars (OIII dominant)
    case darkNebula          // Absorption nebulae (Barnard, LDN)
    case supernovaRemnant    // Expanding shells from stellar explosions
    case openCluster         // Young star groups (Pleiades, Double Cluster)
    case globularCluster     // Dense ancient star clusters (M13, M92)
    case ifn                 // Integrated flux nebulae (extremely faint galactic cirrus)
    case starFormingRegion   // Mixed emission + reflection + dark (Rho Oph, Cepheus)
    case quasar              // Active galactic nuclei (3C 273)
    case wolfRayetNebula     // Shells around WR stars (NGC 6888, Thor's Helmet)
    case hiiRegion           // Synonym for large emission nebula complexes

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .galaxy: return "Galaxy"
        case .galaxyGroup: return "Galaxy Group"
        case .emissionNebula: return "Emission Nebula"
        case .reflectionNebula: return "Reflection Nebula"
        case .planetaryNebula: return "Planetary Nebula"
        case .darkNebula: return "Dark Nebula"
        case .supernovaRemnant: return "Supernova Remnant"
        case .openCluster: return "Open Cluster"
        case .globularCluster: return "Globular Cluster"
        case .ifn: return "Integrated Flux Nebula"
        case .starFormingRegion: return "Star-Forming Region"
        case .quasar: return "Quasar"
        case .wolfRayetNebula: return "Wolf-Rayet Nebula"
        case .hiiRegion: return "HII Region"
        }
    }

    // MARK: - Scoring Weight Modifiers

    /// FWHM weight modifier. Higher = more penalty for poor seeing.
    /// Galaxies need resolution; IFN doesn't care.
    var fwhmWeightModifier: Double {
        switch self {
        case .galaxy, .galaxyGroup: return 1.4
        case .globularCluster: return 1.3
        case .planetaryNebula: return 1.3
        case .openCluster: return 1.2
        case .reflectionNebula: return 0.9
        case .darkNebula: return 0.8
        case .emissionNebula, .hiiRegion: return 0.7
        case .supernovaRemnant, .wolfRayetNebula: return 0.8
        case .starFormingRegion: return 0.8
        case .ifn: return 0.4
        case .quasar: return 1.0
        }
    }

    /// Star count / PSF flux weight modifier. Lower for crowded or star-poor targets.
    var starWeightModifier: Double {
        switch self {
        case .galaxy: return 0.8
        case .galaxyGroup: return 0.8
        case .globularCluster: return 0.2   // Star count meaningless (saturated)
        case .openCluster: return 0.3        // Too many stars, crowding issues
        case .emissionNebula, .hiiRegion: return 0.6
        case .planetaryNebula: return 0.7
        case .reflectionNebula: return 0.8
        case .darkNebula: return 0.8
        case .supernovaRemnant, .wolfRayetNebula: return 0.6
        case .starFormingRegion: return 0.6
        case .ifn: return 0.5
        case .quasar: return 1.0
        }
    }

    /// Noise / SNR weight modifier. Higher = more penalty for noisy frames.
    /// IFN and faint targets need every photon.
    var noiseWeightModifier: Double {
        switch self {
        case .ifn: return 2.0
        case .emissionNebula, .hiiRegion: return 1.4
        case .supernovaRemnant, .wolfRayetNebula: return 1.3
        case .darkNebula: return 1.3
        case .reflectionNebula: return 1.2
        case .starFormingRegion: return 1.2
        case .planetaryNebula: return 1.0
        case .galaxyGroup: return 1.0
        case .galaxy: return 0.8
        case .openCluster: return 0.8
        case .globularCluster: return 0.8
        case .quasar: return 1.0
        }
    }

    /// Trailing weight modifier. Higher = more penalty for elongated stars.
    /// Galaxies show trailing clearly; diffuse targets hide it.
    var trailingWeightModifier: Double {
        switch self {
        case .galaxy: return 1.2
        case .galaxyGroup: return 1.1
        case .planetaryNebula: return 1.1
        case .globularCluster: return 1.0
        case .openCluster: return 1.0
        case .reflectionNebula: return 0.8
        case .darkNebula: return 0.7
        case .emissionNebula, .hiiRegion: return 0.6
        case .supernovaRemnant, .wolfRayetNebula: return 0.7
        case .starFormingRegion: return 0.7
        case .ifn: return 0.3
        case .quasar: return 1.0
        }
    }
}

// MARK: - Filter Recommendations

/// Recommended filter approach for a target.
enum FilterSet: Codable, Equatable {
    /// Narrowband SHO (Hubble palette). Ratios are relative integration weights.
    case sho(ha: Int, oiii: Int, sii: Int)
    /// Narrowband bicolor Ha + OIII.
    case hoo(ha: Int, oiii: Int)
    /// Broadband LRGB.
    case lrgb(l: Int, r: Int, g: Int, b: Int)
    /// Broadband LRGB with Ha supplement for spiral arms / HII regions.
    case haLrgb(ha: Int, l: Int, r: Int, g: Int, b: Int)
    /// Broadband RGB only (star clusters).
    case rgb(r: Int, g: Int, b: Int)
    /// Luminance-only (extremely faint targets like IFN).
    case luminanceOnly
    /// Narrowband not useful (e.g., reflection nebulae, star clusters).
    case narrowbandNotUseful

    /// Short description for display
    var displayName: String {
        switch self {
        case .sho: return "SHO"
        case .hoo: return "HOO"
        case .lrgb: return "LRGB"
        case .haLrgb: return "HaLRGB"
        case .rgb: return "RGB"
        case .luminanceOnly: return "L only"
        case .narrowbandNotUseful: return "NB not useful"
        }
    }

    /// Ratio string for display (e.g., "Ha:6 OIII:4 SII:2")
    var ratioDescription: String {
        switch self {
        case .sho(let ha, let oiii, let sii): return "Ha:\(ha) OIII:\(oiii) SII:\(sii)"
        case .hoo(let ha, let oiii): return "Ha:\(ha) OIII:\(oiii)"
        case .lrgb(let l, let r, let g, let b): return "L:\(l) R:\(r) G:\(g) B:\(b)"
        case .haLrgb(let ha, let l, let r, let g, let b): return "Ha:\(ha) L:\(l) R:\(r) G:\(g) B:\(b)"
        case .rgb(let r, let g, let b): return "R:\(r) G:\(g) B:\(b)"
        case .luminanceOnly: return "L: maximum"
        case .narrowbandNotUseful: return "—"
        }
    }
}

/// Filter recommendation for a specific target, with primary and optional secondary approach.
struct FilterRecommendation: Codable, Equatable {
    let primary: FilterSet
    let secondary: FilterSet?
    let notes: String?

    init(_ primary: FilterSet, secondary: FilterSet? = nil, notes: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.notes = notes
    }
}

// MARK: - Deep-Sky Target Record

/// A single deep-sky object with all astronomical and imaging properties.
struct DeepSkyTarget: Codable, Equatable {
    let canonicalName: String           // Matches TargetCatalog.canonicalName() output
    let commonName: String?             // Popular name (e.g., "Andromeda Galaxy")
    let type: TargetType
    let raJ2000: Double                 // Right ascension in degrees [0, 360)
    let decJ2000: Double                // Declination in degrees [-90, +90]
    let angularSizeMajor: Double        // Major axis in arcminutes
    let angularSizeMinor: Double        // Minor axis in arcminutes
    let magnitudeV: Double?             // Visual magnitude (nil if unavailable)
    let surfaceBrightness: Double?      // mag/arcsec² (nil if unavailable)
    let constellation: String           // IAU abbreviation (e.g., "And", "Ori")
    let filters: FilterRecommendation
    let aliases: [String]               // Alternative catalog IDs

    /// Angular size diagonal in arcminutes
    var angularSizeDiagonal: Double {
        sqrt(angularSizeMajor * angularSizeMajor + angularSizeMinor * angularSizeMinor)
    }

    /// Compute FOV fill ratio for a given imaging setup
    /// - Parameters:
    ///   - focalLength: Telescope focal length in mm
    ///   - pixelSizeMicrons: Pixel size in microns
    ///   - sensorWidth: Sensor width in pixels
    ///   - sensorHeight: Sensor height in pixels
    /// - Returns: Fill ratio (0 = tiny target, 1+ = fills/exceeds FOV)
    func fovFillRatio(focalLength: Double, pixelSizeMicrons: Double,
                      sensorWidth: Int, sensorHeight: Int) -> Double {
        guard focalLength > 0, pixelSizeMicrons > 0 else { return 0 }
        let sensorDiagMM = sqrt(
            pow(Double(sensorWidth) * pixelSizeMicrons / 1000.0, 2) +
            pow(Double(sensorHeight) * pixelSizeMicrons / 1000.0, 2)
        )
        let fovDiagArcmin = (sensorDiagMM / focalLength) * (180.0 / .pi) * 60.0
        guard fovDiagArcmin > 0 else { return 0 }
        return angularSizeDiagonal / fovDiagArcmin
    }
}

// MARK: - Database Lookup

enum DeepSkyTargetDatabase {

    /// Look up a target by its canonical name (as output by TargetCatalog.canonicalName()).
    static func lookup(_ canonicalName: String) -> DeepSkyTarget? {
        let upper = canonicalName.uppercased()
        return targetIndex[upper]
    }

    /// Determine target type for an ImageEntry via its target name.
    /// Falls back to nil for unknown targets.
    static func targetType(for targetName: String?) -> TargetType? {
        guard let name = targetName, !name.isEmpty else { return nil }
        let canonical = TargetCatalog.canonicalName(name)
        return lookup(canonical)?.type
    }

    /// All targets in the database.
    static var allTargets: [DeepSkyTarget] { targets }

    /// Search targets by type.
    static func targets(ofType type: TargetType) -> [DeepSkyTarget] {
        targets.filter { $0.type == type }
    }

    /// Search targets visible from a given declination range.
    static func targets(minDec: Double, maxDec: Double) -> [DeepSkyTarget] {
        targets.filter { $0.decJ2000 >= minDec && $0.decJ2000 <= maxDec }
    }

    /// Search targets by constellation.
    static func targets(in constellation: String) -> [DeepSkyTarget] {
        let abbr = constellation.uppercased().prefix(3)
        return targets.filter { $0.constellation.uppercased().hasPrefix(abbr) }
    }

    // MARK: - Scoring Weight Modifiers

    /// Get FOV-fill-ratio-based weight modulation for a target + setup combination.
    /// Returns (fwhmMod, noiseMod) — multiply on top of target-type modifiers.
    /// Small target in large FOV → boost FWHM. Target fills FOV → boost noise.
    static func fovWeightModulation(fillRatio: Double) -> (fwhmMod: Double, noiseMod: Double) {
        if fillRatio < 0.15 {
            // Small target in large FOV — resolution matters more
            return (fwhmMod: 1.2, noiseMod: 1.0)
        } else if fillRatio > 0.50 {
            // Target fills frame — noise/SNR matters more
            return (fwhmMod: 0.9, noiseMod: 1.2)
        } else {
            // Balanced — no modification
            return (fwhmMod: 1.0, noiseMod: 1.0)
        }
    }

    // MARK: - Private Index

    /// Pre-built index for O(1) lookup by canonical name
    private static let targetIndex: [String: DeepSkyTarget] = {
        var dict: [String: DeepSkyTarget] = [:]
        dict.reserveCapacity(targets.count * 2)
        for target in targets {
            dict[target.canonicalName.uppercased()] = target
            for alias in target.aliases {
                dict[alias.uppercased()] = target
            }
        }
        return dict
    }()

    // MARK: - Convenience initializer

    private static func t(
        _ name: String, _ common: String?, _ type: TargetType,
        ra: Double, dec: Double, major: Double, minor: Double,
        mag: Double? = nil, sb: Double? = nil, con: String,
        filters: FilterRecommendation, aliases: [String] = []
    ) -> DeepSkyTarget {
        DeepSkyTarget(
            canonicalName: name, commonName: common, type: type,
            raJ2000: ra, decJ2000: dec,
            angularSizeMajor: major, angularSizeMinor: minor,
            magnitudeV: mag, surfaceBrightness: sb, constellation: con,
            filters: filters, aliases: aliases
        )
    }

    // MARK: - Filter recommendation shorthands

    private static let shoDefault = FilterRecommendation(.sho(ha: 6, oiii: 4, sii: 2))
    private static let hooDefault = FilterRecommendation(.hoo(ha: 3, oiii: 2))
    private static let lrgbDefault = FilterRecommendation(.lrgb(l: 6, r: 2, g: 2, b: 2))
    private static let rgbDefault = FilterRecommendation(.rgb(r: 3, g: 3, b: 3))
    private static let haLrgbDefault = FilterRecommendation(.haLrgb(ha: 3, l: 6, r: 2, g: 2, b: 2))
    private static let lOnlyDefault = FilterRecommendation(.luminanceOnly)
    private static let nbNotUseful = FilterRecommendation(.lrgb(l: 4, r: 3, g: 3, b: 3),
        notes: "Narrowband not useful — reflection/continuum target")

    // Specific filter combos used by multiple targets
    private static let hooPN = FilterRecommendation(.hoo(ha: 2, oiii: 3),
        notes: "OIII dominant — planetary nebula ionization")
    private static let shoSNR = FilterRecommendation(.sho(ha: 4, oiii: 3, sii: 5),
        notes: "SII often dominant in shock fronts")
    private static let galaxyHa = FilterRecommendation(.haLrgb(ha: 3, l: 6, r: 2, g: 2, b: 2),
        notes: "Ha supplement for HII regions in spiral arms")

    // =========================================================================
    // MARK: - TARGET DATA
    // =========================================================================
    //
    // RA is in degrees [0, 360). Dec is in degrees [-90, +90].
    // Angular sizes in arcminutes.
    // Organized by catalog for maintainability.
    //
    // RA conversion: hours*15 + min*0.25 + sec*0.00417
    // Dec conversion: deg + min/60 + sec/3600 (with sign)
    // =========================================================================

    static let targets: [DeepSkyTarget] = messierTargets + ngcTargets + icTargets
        + sharplessTargets + abellTargets + barnardTargets + otherTargets

    // MARK: - Messier Catalog (M1–M110)

    static let messierTargets: [DeepSkyTarget] = [
        // M1 — Crab Nebula (supernova remnant)
        t("M1", "Crab Nebula", .supernovaRemnant,
          ra: 83.633, dec: 22.014, major: 6.0, minor: 4.0,
          mag: 8.4, sb: 12.0, con: "Tau",
          filters: shoSNR, aliases: ["NGC1952", "SH2-244"]),

        // M2 — Globular cluster
        t("M2", nil, .globularCluster,
          ra: 323.363, dec: -0.823, major: 16.0, minor: 16.0,
          mag: 6.5, con: "Aqr", filters: lrgbDefault, aliases: ["NGC7089"]),

        // M3 — Globular cluster
        t("M3", nil, .globularCluster,
          ra: 205.548, dec: 28.377, major: 18.0, minor: 18.0,
          mag: 6.2, con: "CVn", filters: lrgbDefault, aliases: ["NGC5272"]),

        // M4 — Globular cluster
        t("M4", nil, .globularCluster,
          ra: 245.897, dec: -26.526, major: 36.0, minor: 36.0,
          mag: 5.6, con: "Sco", filters: lrgbDefault, aliases: ["NGC6121"]),

        // M5 — Globular cluster
        t("M5", nil, .globularCluster,
          ra: 229.638, dec: 2.081, major: 23.0, minor: 23.0,
          mag: 5.6, con: "Ser", filters: lrgbDefault, aliases: ["NGC5904"]),

        // M6 — Butterfly Cluster (open cluster)
        t("M6", "Butterfly Cluster", .openCluster,
          ra: 265.083, dec: -32.217, major: 25.0, minor: 25.0,
          mag: 4.2, con: "Sco", filters: rgbDefault, aliases: ["NGC6405"]),

        // M7 — Ptolemy Cluster (open cluster)
        t("M7", "Ptolemy Cluster", .openCluster,
          ra: 268.458, dec: -34.793, major: 80.0, minor: 80.0,
          mag: 3.3, con: "Sco", filters: rgbDefault, aliases: ["NGC6475"]),

        // M8 — Lagoon Nebula
        t("M8", "Lagoon Nebula", .emissionNebula,
          ra: 270.917, dec: -24.383, major: 90.0, minor: 40.0,
          mag: 6.0, sb: 13.0, con: "Sgr",
          filters: shoDefault, aliases: ["NGC6523", "SH2-25"]),

        // M9 — Globular cluster
        t("M9", nil, .globularCluster,
          ra: 259.800, dec: -18.516, major: 12.0, minor: 12.0,
          mag: 7.7, con: "Oph", filters: lrgbDefault, aliases: ["NGC6333"]),

        // M10 — Globular cluster
        t("M10", nil, .globularCluster,
          ra: 254.288, dec: -4.100, major: 20.0, minor: 20.0,
          mag: 6.6, con: "Oph", filters: lrgbDefault, aliases: ["NGC6254"]),

        // M11 — Wild Duck Cluster
        t("M11", "Wild Duck Cluster", .openCluster,
          ra: 282.767, dec: -6.267, major: 14.0, minor: 14.0,
          mag: 5.8, con: "Sct", filters: rgbDefault, aliases: ["NGC6705"]),

        // M12 — Globular cluster
        t("M12", nil, .globularCluster,
          ra: 251.809, dec: -1.949, major: 16.0, minor: 16.0,
          mag: 6.7, con: "Oph", filters: lrgbDefault, aliases: ["NGC6218"]),

        // M13 — Hercules Cluster
        t("M13", "Hercules Cluster", .globularCluster,
          ra: 250.422, dec: 36.461, major: 20.0, minor: 20.0,
          mag: 5.8, con: "Her", filters: lrgbDefault, aliases: ["NGC6205"]),

        // M14 — Globular cluster
        t("M14", nil, .globularCluster,
          ra: 264.400, dec: -3.246, major: 11.0, minor: 11.0,
          mag: 7.6, con: "Oph", filters: lrgbDefault, aliases: ["NGC6402"]),

        // M15 — Globular cluster
        t("M15", nil, .globularCluster,
          ra: 322.493, dec: 12.167, major: 18.0, minor: 18.0,
          mag: 6.2, con: "Peg", filters: lrgbDefault, aliases: ["NGC7078"]),

        // M16 — Eagle Nebula (Pillars of Creation)
        t("M16", "Eagle Nebula", .emissionNebula,
          ra: 274.700, dec: -13.807, major: 35.0, minor: 28.0,
          mag: 6.0, sb: 13.0, con: "Ser",
          filters: shoDefault, aliases: ["NGC6611", "SH2-49", "IC4703"]),

        // M17 — Omega/Swan Nebula
        t("M17", "Omega Nebula", .emissionNebula,
          ra: 275.196, dec: -16.172, major: 46.0, minor: 37.0,
          mag: 6.0, sb: 12.0, con: "Sgr",
          filters: shoDefault, aliases: ["NGC6618", "SH2-45", "Swan Nebula"]),

        // M18 — Open cluster
        t("M18", nil, .openCluster,
          ra: 275.233, dec: -17.133, major: 9.0, minor: 9.0,
          mag: 7.5, con: "Sgr", filters: rgbDefault, aliases: ["NGC6613"]),

        // M19 — Globular cluster
        t("M19", nil, .globularCluster,
          ra: 255.657, dec: -26.268, major: 17.0, minor: 17.0,
          mag: 6.8, con: "Oph", filters: lrgbDefault, aliases: ["NGC6273"]),

        // M20 — Trifid Nebula
        t("M20", "Trifid Nebula", .emissionNebula,
          ra: 270.600, dec: -23.033, major: 28.0, minor: 28.0,
          mag: 6.3, sb: 13.5, con: "Sgr",
          filters: FilterRecommendation(.sho(ha: 6, oiii: 4, sii: 2),
              secondary: .lrgb(l: 4, r: 3, g: 3, b: 3),
              notes: "Emission + reflection components — NB for emission, LRGB for blue reflection"),
          aliases: ["NGC6514", "SH2-30"]),

        // M22 — Globular cluster
        t("M22", nil, .globularCluster,
          ra: 279.100, dec: -23.905, major: 32.0, minor: 32.0,
          mag: 5.1, con: "Sgr", filters: lrgbDefault, aliases: ["NGC6656"]),

        // M27 — Dumbbell Nebula
        t("M27", "Dumbbell Nebula", .planetaryNebula,
          ra: 299.902, dec: 22.721, major: 8.0, minor: 5.7,
          mag: 7.5, sb: 12.0, con: "Vul",
          filters: hooPN, aliases: ["NGC6853"]),

        // M31 — Andromeda Galaxy
        t("M31", "Andromeda Galaxy", .galaxy,
          ra: 10.685, dec: 41.269, major: 190.0, minor: 60.0,
          mag: 3.4, sb: 13.5, con: "And",
          filters: galaxyHa, aliases: ["NGC224"]),

        // M32 — Satellite of M31
        t("M32", nil, .galaxy,
          ra: 10.674, dec: 40.866, major: 8.7, minor: 6.5,
          mag: 8.1, sb: 12.5, con: "And", filters: lrgbDefault, aliases: ["NGC221"]),

        // M33 — Triangulum Galaxy
        t("M33", "Triangulum Galaxy", .galaxy,
          ra: 23.462, dec: 30.660, major: 73.0, minor: 45.0,
          mag: 5.7, sb: 14.2, con: "Tri",
          filters: galaxyHa, aliases: ["NGC598"]),

        // M34 — Open cluster
        t("M34", nil, .openCluster,
          ra: 40.512, dec: 42.763, major: 35.0, minor: 35.0,
          mag: 5.2, con: "Per", filters: rgbDefault, aliases: ["NGC1039"]),

        // M35 — Open cluster
        t("M35", nil, .openCluster,
          ra: 92.283, dec: 24.333, major: 28.0, minor: 28.0,
          mag: 5.1, con: "Gem", filters: rgbDefault, aliases: ["NGC2168"]),

        // M36 — Open cluster
        t("M36", nil, .openCluster,
          ra: 84.083, dec: 34.133, major: 12.0, minor: 12.0,
          mag: 6.0, con: "Aur", filters: rgbDefault, aliases: ["NGC1960"]),

        // M37 — Open cluster
        t("M37", nil, .openCluster,
          ra: 88.075, dec: 32.550, major: 24.0, minor: 24.0,
          mag: 5.6, con: "Aur", filters: rgbDefault, aliases: ["NGC2099"]),

        // M38 — Open cluster
        t("M38", nil, .openCluster,
          ra: 82.167, dec: 35.833, major: 21.0, minor: 21.0,
          mag: 6.4, con: "Aur", filters: rgbDefault, aliases: ["NGC1912"]),

        // M42 — Orion Nebula
        t("M42", "Orion Nebula", .emissionNebula,
          ra: 83.822, dec: -5.391, major: 85.0, minor: 60.0,
          mag: 4.0, sb: 13.0, con: "Ori",
          filters: FilterRecommendation(.sho(ha: 4, oiii: 4, sii: 2),
              secondary: .rgb(r: 2, g: 2, b: 2),
              notes: "Very bright — short subs work; RGB for star colors"),
          aliases: ["NGC1976", "SH2-281"]),

        // M43 — De Mairan's Nebula (part of M42 complex)
        t("M43", "De Mairan's Nebula", .emissionNebula,
          ra: 83.883, dec: -5.267, major: 20.0, minor: 15.0,
          mag: 9.0, con: "Ori", filters: shoDefault, aliases: ["NGC1982"]),

        // M44 — Beehive Cluster
        t("M44", "Beehive Cluster", .openCluster,
          ra: 130.025, dec: 19.667, major: 95.0, minor: 95.0,
          mag: 3.1, con: "Cnc", filters: rgbDefault, aliases: ["NGC2632"]),

        // M45 — Pleiades
        t("M45", "Pleiades", .openCluster,
          ra: 56.750, dec: 24.117, major: 110.0, minor: 110.0,
          mag: 1.6, con: "Tau",
          filters: nbNotUseful),

        // M46 — Open cluster
        t("M46", nil, .openCluster,
          ra: 115.442, dec: -14.817, major: 27.0, minor: 27.0,
          mag: 6.1, con: "Pup", filters: rgbDefault, aliases: ["NGC2437"]),

        // M47 — Open cluster
        t("M47", nil, .openCluster,
          ra: 114.150, dec: -14.500, major: 30.0, minor: 30.0,
          mag: 4.4, con: "Pup", filters: rgbDefault, aliases: ["NGC2422"]),

        // M48 — Open cluster
        t("M48", nil, .openCluster,
          ra: 123.433, dec: -5.800, major: 54.0, minor: 54.0,
          mag: 5.8, con: "Hya", filters: rgbDefault, aliases: ["NGC2548"]),

        // M49 — Elliptical galaxy
        t("M49", nil, .galaxy,
          ra: 187.445, dec: 8.000, major: 10.0, minor: 8.3,
          mag: 8.4, con: "Vir", filters: lrgbDefault, aliases: ["NGC4472"]),

        // M50 — Open cluster
        t("M50", nil, .openCluster,
          ra: 105.675, dec: -8.367, major: 16.0, minor: 16.0,
          mag: 5.9, con: "Mon", filters: rgbDefault, aliases: ["NGC2323"]),

        // M51 — Whirlpool Galaxy
        t("M51", "Whirlpool Galaxy", .galaxyGroup,
          ra: 202.470, dec: 47.195, major: 11.2, minor: 6.9,
          mag: 8.4, sb: 12.9, con: "CVn",
          filters: galaxyHa, aliases: ["NGC5194", "NGC5195"]),

        // M52 — Open cluster
        t("M52", nil, .openCluster,
          ra: 351.200, dec: 61.583, major: 13.0, minor: 13.0,
          mag: 6.9, con: "Cas", filters: rgbDefault, aliases: ["NGC7654"]),

        // M53 — Globular cluster
        t("M53", nil, .globularCluster,
          ra: 198.230, dec: 18.169, major: 14.0, minor: 14.0,
          mag: 7.6, con: "Com", filters: lrgbDefault, aliases: ["NGC5024"]),

        // M54 — Globular cluster
        t("M54", nil, .globularCluster,
          ra: 283.764, dec: -30.478, major: 12.0, minor: 12.0,
          mag: 7.6, con: "Sgr", filters: lrgbDefault, aliases: ["NGC6715"]),

        // M55 — Globular cluster
        t("M55", nil, .globularCluster,
          ra: 294.999, dec: -30.965, major: 19.0, minor: 19.0,
          mag: 6.3, con: "Sgr", filters: lrgbDefault, aliases: ["NGC6809"]),

        // M56 — Globular cluster
        t("M56", nil, .globularCluster,
          ra: 289.147, dec: 30.184, major: 9.0, minor: 9.0,
          mag: 8.3, con: "Lyr", filters: lrgbDefault, aliases: ["NGC6779"]),

        // M57 — Ring Nebula
        t("M57", "Ring Nebula", .planetaryNebula,
          ra: 283.396, dec: 33.029, major: 1.4, minor: 1.0,
          mag: 8.8, sb: 9.0, con: "Lyr",
          filters: hooPN, aliases: ["NGC6720"]),

        // M58 — Barred spiral galaxy
        t("M58", nil, .galaxy,
          ra: 189.997, dec: 11.818, major: 5.5, minor: 4.5,
          mag: 9.7, con: "Vir", filters: lrgbDefault, aliases: ["NGC4579"]),

        // M59 — Elliptical galaxy
        t("M59", nil, .galaxy,
          ra: 190.509, dec: 11.647, major: 5.4, minor: 3.7,
          mag: 9.6, con: "Vir", filters: lrgbDefault, aliases: ["NGC4621"]),

        // M60 — Elliptical galaxy
        t("M60", nil, .galaxy,
          ra: 190.917, dec: 11.553, major: 7.6, minor: 6.2,
          mag: 8.8, con: "Vir", filters: lrgbDefault, aliases: ["NGC4649"]),

        // M61 — Spiral galaxy
        t("M61", nil, .galaxy,
          ra: 185.479, dec: 4.474, major: 6.5, minor: 5.8,
          mag: 9.7, con: "Vir", filters: galaxyHa, aliases: ["NGC4303"]),

        // M62 — Globular cluster
        t("M62", nil, .globularCluster,
          ra: 255.303, dec: -30.113, major: 15.0, minor: 15.0,
          mag: 6.5, con: "Oph", filters: lrgbDefault, aliases: ["NGC6266"]),

        // M63 — Sunflower Galaxy
        t("M63", "Sunflower Galaxy", .galaxy,
          ra: 198.955, dec: 42.029, major: 12.6, minor: 7.2,
          mag: 8.6, con: "CVn", filters: lrgbDefault, aliases: ["NGC5055"]),

        // M64 — Black Eye Galaxy
        t("M64", "Black Eye Galaxy", .galaxy,
          ra: 194.182, dec: 21.683, major: 10.0, minor: 5.4,
          mag: 8.5, con: "Com", filters: lrgbDefault, aliases: ["NGC4826"]),

        // M65 — Leo Triplet member
        t("M65", nil, .galaxy,
          ra: 169.733, dec: 13.092, major: 10.0, minor: 3.3,
          mag: 9.3, con: "Leo", filters: lrgbDefault, aliases: ["NGC3623"]),

        // M66 — Leo Triplet member
        t("M66", nil, .galaxy,
          ra: 170.063, dec: 12.991, major: 9.1, minor: 4.2,
          mag: 8.9, con: "Leo", filters: lrgbDefault, aliases: ["NGC3627"]),

        // M67 — Open cluster
        t("M67", nil, .openCluster,
          ra: 132.825, dec: 11.817, major: 30.0, minor: 30.0,
          mag: 6.9, con: "Cnc", filters: rgbDefault, aliases: ["NGC2682"]),

        // M68 — Globular cluster
        t("M68", nil, .globularCluster,
          ra: 189.867, dec: -26.744, major: 11.0, minor: 11.0,
          mag: 7.8, con: "Hya", filters: lrgbDefault, aliases: ["NGC4590"]),

        // M69 — Globular cluster
        t("M69", nil, .globularCluster,
          ra: 277.846, dec: -32.348, major: 9.8, minor: 9.8,
          mag: 7.6, con: "Sgr", filters: lrgbDefault, aliases: ["NGC6637"]),

        // M70 — Globular cluster
        t("M70", nil, .globularCluster,
          ra: 280.803, dec: -32.292, major: 8.0, minor: 8.0,
          mag: 7.9, con: "Sgr", filters: lrgbDefault, aliases: ["NGC6681"]),

        // M71 — Globular cluster
        t("M71", nil, .globularCluster,
          ra: 298.444, dec: 18.779, major: 7.2, minor: 7.2,
          mag: 8.2, con: "Sge", filters: lrgbDefault, aliases: ["NGC6838"]),

        // M72 — Globular cluster
        t("M72", nil, .globularCluster,
          ra: 313.365, dec: -12.537, major: 6.6, minor: 6.6,
          mag: 9.3, con: "Aqr", filters: lrgbDefault, aliases: ["NGC6981"]),

        // M74 — Phantom Galaxy
        t("M74", "Phantom Galaxy", .galaxy,
          ra: 24.174, dec: 15.784, major: 10.5, minor: 9.5,
          mag: 9.4, sb: 14.2, con: "Psc", filters: galaxyHa, aliases: ["NGC628"]),

        // M75 — Globular cluster
        t("M75", nil, .globularCluster,
          ra: 301.520, dec: -21.921, major: 6.8, minor: 6.8,
          mag: 8.5, con: "Sgr", filters: lrgbDefault, aliases: ["NGC6864"]),

        // M76 — Little Dumbbell Nebula
        t("M76", "Little Dumbbell Nebula", .planetaryNebula,
          ra: 25.583, dec: 51.575, major: 2.7, minor: 1.8,
          mag: 10.1, con: "Per", filters: hooPN, aliases: ["NGC650", "NGC651"]),

        // M77 — Cetus A (Seyfert galaxy)
        t("M77", "Cetus A", .galaxy,
          ra: 40.670, dec: -0.014, major: 7.1, minor: 6.0,
          mag: 8.9, con: "Cet", filters: lrgbDefault, aliases: ["NGC1068"]),

        // M78 — Reflection nebula
        t("M78", nil, .reflectionNebula,
          ra: 86.650, dec: 0.050, major: 8.0, minor: 6.0,
          mag: 8.3, con: "Ori", filters: nbNotUseful, aliases: ["NGC2068"]),

        // M79 — Globular cluster
        t("M79", nil, .globularCluster,
          ra: 81.046, dec: -24.524, major: 9.6, minor: 9.6,
          mag: 7.7, con: "Lep", filters: lrgbDefault, aliases: ["NGC1904"]),

        // M80 — Globular cluster
        t("M80", nil, .globularCluster,
          ra: 244.260, dec: -22.975, major: 10.0, minor: 10.0,
          mag: 7.3, con: "Sco", filters: lrgbDefault, aliases: ["NGC6093"]),

        // M81 — Bode's Galaxy
        t("M81", "Bode's Galaxy", .galaxy,
          ra: 148.888, dec: 69.065, major: 26.9, minor: 14.1,
          mag: 6.9, sb: 13.2, con: "UMa",
          filters: galaxyHa, aliases: ["NGC3031"]),

        // M82 — Cigar Galaxy
        t("M82", "Cigar Galaxy", .galaxy,
          ra: 148.968, dec: 69.680, major: 11.2, minor: 4.3,
          mag: 8.4, sb: 12.5, con: "UMa",
          filters: galaxyHa, aliases: ["NGC3034"]),

        // M83 — Southern Pinwheel
        t("M83", "Southern Pinwheel", .galaxy,
          ra: 204.254, dec: -29.866, major: 12.9, minor: 11.5,
          mag: 7.6, con: "Hya", filters: galaxyHa, aliases: ["NGC5236"]),

        // M84 — Lenticular galaxy (Virgo)
        t("M84", nil, .galaxy,
          ra: 186.265, dec: 12.887, major: 6.5, minor: 5.6,
          mag: 9.1, con: "Vir", filters: lrgbDefault, aliases: ["NGC4374"]),

        // M85 — Lenticular galaxy
        t("M85", nil, .galaxy,
          ra: 186.350, dec: 18.191, major: 7.1, minor: 5.5,
          mag: 9.1, con: "Com", filters: lrgbDefault, aliases: ["NGC4382"]),

        // M86 — Elliptical galaxy (Virgo)
        t("M86", nil, .galaxy,
          ra: 186.549, dec: 12.946, major: 9.8, minor: 7.4,
          mag: 8.9, con: "Vir", filters: lrgbDefault, aliases: ["NGC4406"]),

        // M87 — Virgo A (giant elliptical, jet)
        t("M87", "Virgo A", .galaxy,
          ra: 187.706, dec: 12.391, major: 8.3, minor: 6.6,
          mag: 8.6, con: "Vir", filters: lrgbDefault, aliases: ["NGC4486"]),

        // M88 — Spiral galaxy
        t("M88", nil, .galaxy,
          ra: 187.997, dec: 14.420, major: 6.9, minor: 3.7,
          mag: 9.6, con: "Com", filters: lrgbDefault, aliases: ["NGC4501"]),

        // M89 — Elliptical galaxy
        t("M89", nil, .galaxy,
          ra: 188.916, dec: 12.556, major: 5.1, minor: 4.7,
          mag: 9.8, con: "Vir", filters: lrgbDefault, aliases: ["NGC4552"]),

        // M90 — Spiral galaxy
        t("M90", nil, .galaxy,
          ra: 189.209, dec: 13.163, major: 9.5, minor: 4.4,
          mag: 9.5, con: "Vir", filters: lrgbDefault, aliases: ["NGC4569"]),

        // M91 — Barred spiral
        t("M91", nil, .galaxy,
          ra: 188.863, dec: 14.497, major: 5.4, minor: 4.3,
          mag: 10.2, con: "Com", filters: lrgbDefault, aliases: ["NGC4548"]),

        // M92 — Globular cluster
        t("M92", nil, .globularCluster,
          ra: 259.281, dec: 43.136, major: 14.0, minor: 14.0,
          mag: 6.4, con: "Her", filters: lrgbDefault, aliases: ["NGC6341"]),

        // M93 — Open cluster
        t("M93", nil, .openCluster,
          ra: 116.158, dec: -23.883, major: 22.0, minor: 22.0,
          mag: 6.2, con: "Pup", filters: rgbDefault, aliases: ["NGC2447"]),

        // M94 — Cat's Eye Galaxy
        t("M94", "Cat's Eye Galaxy", .galaxy,
          ra: 192.721, dec: 41.120, major: 11.2, minor: 9.1,
          mag: 8.2, con: "CVn", filters: lrgbDefault, aliases: ["NGC4736"]),

        // M95 — Barred spiral
        t("M95", nil, .galaxy,
          ra: 160.990, dec: 11.704, major: 7.4, minor: 5.0,
          mag: 9.7, con: "Leo", filters: lrgbDefault, aliases: ["NGC3351"]),

        // M96 — Spiral galaxy
        t("M96", nil, .galaxy,
          ra: 161.693, dec: 11.820, major: 7.6, minor: 5.2,
          mag: 9.2, con: "Leo", filters: lrgbDefault, aliases: ["NGC3368"]),

        // M97 — Owl Nebula
        t("M97", "Owl Nebula", .planetaryNebula,
          ra: 168.699, dec: 55.019, major: 3.4, minor: 3.3,
          mag: 9.9, con: "UMa", filters: hooPN, aliases: ["NGC3587"]),

        // M98 — Spiral galaxy
        t("M98", nil, .galaxy,
          ra: 183.451, dec: 14.900, major: 9.8, minor: 2.8,
          mag: 10.1, con: "Com", filters: lrgbDefault, aliases: ["NGC4192"]),

        // M99 — Coma Pinwheel
        t("M99", "Coma Pinwheel", .galaxy,
          ra: 184.707, dec: 14.417, major: 5.4, minor: 4.7,
          mag: 9.9, con: "Com", filters: galaxyHa, aliases: ["NGC4254"]),

        // M100 — Mirror Galaxy
        t("M100", nil, .galaxy,
          ra: 185.729, dec: 15.822, major: 7.4, minor: 6.3,
          mag: 9.3, con: "Com", filters: galaxyHa, aliases: ["NGC4321"]),

        // M101 — Pinwheel Galaxy
        t("M101", "Pinwheel Galaxy", .galaxy,
          ra: 210.803, dec: 54.349, major: 28.8, minor: 26.9,
          mag: 7.9, sb: 14.8, con: "UMa",
          filters: galaxyHa, aliases: ["NGC5457"]),

        // M102 — Spindle Galaxy
        t("M102", "Spindle Galaxy", .galaxy,
          ra: 226.623, dec: 55.764, major: 6.5, minor: 3.1,
          mag: 9.9, con: "Dra", filters: lrgbDefault, aliases: ["NGC5866"]),

        // M103 — Open cluster
        t("M103", nil, .openCluster,
          ra: 23.417, dec: 60.700, major: 6.0, minor: 6.0,
          mag: 7.4, con: "Cas", filters: rgbDefault, aliases: ["NGC581"]),

        // M104 — Sombrero Galaxy
        t("M104", "Sombrero Galaxy", .galaxy,
          ra: 190.000, dec: -11.623, major: 8.7, minor: 3.5,
          mag: 8.0, sb: 11.5, con: "Vir",
          filters: lrgbDefault, aliases: ["NGC4594"]),

        // M105 — Elliptical galaxy
        t("M105", nil, .galaxy,
          ra: 161.957, dec: 12.582, major: 5.4, minor: 4.8,
          mag: 9.3, con: "Leo", filters: lrgbDefault, aliases: ["NGC3379"]),

        // M106 — Spiral galaxy (Seyfert)
        t("M106", nil, .galaxy,
          ra: 184.740, dec: 47.304, major: 18.6, minor: 7.2,
          mag: 8.4, con: "CVn", filters: galaxyHa, aliases: ["NGC4258"]),

        // M107 — Globular cluster
        t("M107", nil, .globularCluster,
          ra: 248.133, dec: -13.053, major: 13.0, minor: 13.0,
          mag: 7.9, con: "Oph", filters: lrgbDefault, aliases: ["NGC6171"]),

        // M108 — Surfboard Galaxy
        t("M108", "Surfboard Galaxy", .galaxy,
          ra: 167.879, dec: 55.674, major: 8.7, minor: 2.2,
          mag: 10.0, con: "UMa", filters: lrgbDefault, aliases: ["NGC3556"]),

        // M109 — Barred spiral
        t("M109", nil, .galaxy,
          ra: 179.400, dec: 53.375, major: 7.6, minor: 4.9,
          mag: 9.8, con: "UMa", filters: lrgbDefault, aliases: ["NGC3992"]),

        // M110 — Satellite of M31
        t("M110", nil, .galaxy,
          ra: 10.092, dec: 41.685, major: 21.9, minor: 11.0,
          mag: 8.5, con: "And", filters: lrgbDefault, aliases: ["NGC205"]),

        // Messier objects we skipped (M21, M23-M26, M28-M30, M39-M41, M73)
        // M21 — Open cluster
        t("M21", nil, .openCluster,
          ra: 270.967, dec: -22.500, major: 13.0, minor: 13.0,
          mag: 5.9, con: "Sgr", filters: rgbDefault, aliases: ["NGC6531"]),

        // M23 — Open cluster
        t("M23", nil, .openCluster,
          ra: 269.267, dec: -19.017, major: 27.0, minor: 27.0,
          mag: 5.5, con: "Sgr", filters: rgbDefault, aliases: ["NGC6494"]),

        // M24 — Sagittarius Star Cloud
        t("M24", "Sagittarius Star Cloud", .openCluster,
          ra: 274.700, dec: -18.517, major: 90.0, minor: 90.0,
          mag: 4.6, con: "Sgr", filters: rgbDefault, aliases: ["IC4715"]),

        // M25 — Open cluster
        t("M25", nil, .openCluster,
          ra: 277.875, dec: -19.117, major: 32.0, minor: 32.0,
          mag: 4.6, con: "Sgr", filters: rgbDefault, aliases: ["IC4725"]),

        // M26 — Open cluster
        t("M26", nil, .openCluster,
          ra: 281.312, dec: -9.383, major: 15.0, minor: 15.0,
          mag: 8.0, con: "Sct", filters: rgbDefault, aliases: ["NGC6694"]),

        // M28 — Globular cluster
        t("M28", nil, .globularCluster,
          ra: 276.137, dec: -24.870, major: 11.2, minor: 11.2,
          mag: 6.8, con: "Sgr", filters: lrgbDefault, aliases: ["NGC6626"]),

        // M29 — Open cluster
        t("M29", nil, .openCluster,
          ra: 305.983, dec: 38.517, major: 7.0, minor: 7.0,
          mag: 6.6, con: "Cyg", filters: rgbDefault, aliases: ["NGC6913"]),

        // M30 — Globular cluster
        t("M30", nil, .globularCluster,
          ra: 325.092, dec: -23.180, major: 12.0, minor: 12.0,
          mag: 7.2, con: "Cap", filters: lrgbDefault, aliases: ["NGC7099"]),

        // M39 — Open cluster
        t("M39", nil, .openCluster,
          ra: 322.317, dec: 48.433, major: 32.0, minor: 32.0,
          mag: 4.6, con: "Cyg", filters: rgbDefault, aliases: ["NGC7092"]),

        // M40 — Double star (not a deep-sky object, included for completeness)
        t("M40", "Winnecke 4", .openCluster,
          ra: 185.575, dec: 58.083, major: 0.8, minor: 0.8,
          mag: 8.4, con: "UMa", filters: rgbDefault),

        // M41 — Open cluster
        t("M41", nil, .openCluster,
          ra: 101.504, dec: -20.733, major: 38.0, minor: 38.0,
          mag: 4.5, con: "CMa", filters: rgbDefault, aliases: ["NGC2287"]),

        // M48 already listed above

        // M73 — Asterism (4 stars)
        t("M73", nil, .openCluster,
          ra: 314.750, dec: -12.633, major: 2.8, minor: 2.8,
          mag: 9.0, con: "Aqr", filters: rgbDefault, aliases: ["NGC6994"]),
    ]

    // MARK: - Popular NGC Targets

    static let ngcTargets: [DeepSkyTarget] = [
        // NGC 253 — Sculptor Galaxy
        t("NGC253", "Sculptor Galaxy", .galaxy,
          ra: 11.888, dec: -25.288, major: 27.5, minor: 6.8,
          mag: 7.1, sb: 13.2, con: "Scl", filters: lrgbDefault,
          aliases: ["Caldwell 65", "Silver Dollar Galaxy"]),

        // NGC 281 — Pacman Nebula
        t("NGC281", "Pacman Nebula", .emissionNebula,
          ra: 13.167, dec: 56.633, major: 35.0, minor: 30.0,
          mag: 7.4, sb: 13.0, con: "Cas", filters: shoDefault,
          aliases: ["SH2-184", "IC11"]),

        // NGC 457 — Owl Cluster / ET Cluster
        t("NGC457", "Owl Cluster", .openCluster,
          ra: 19.883, dec: 58.283, major: 13.0, minor: 13.0,
          mag: 6.4, con: "Cas", filters: rgbDefault),

        // NGC 869 + NGC 884 — Double Cluster
        t("NGC869", "Double Cluster (h Per)", .openCluster,
          ra: 34.775, dec: 57.133, major: 30.0, minor: 30.0,
          mag: 4.3, con: "Per", filters: rgbDefault, aliases: ["NGC884"]),

        // NGC 891 — Edge-on galaxy
        t("NGC891", "Silver Sliver Galaxy", .galaxy,
          ra: 35.639, dec: 42.349, major: 13.5, minor: 2.5,
          mag: 9.9, sb: 13.6, con: "And", filters: lrgbDefault,
          aliases: ["Caldwell 23"]),

        // NGC 1333 — Reflection nebula / star forming
        t("NGC1333", nil, .starFormingRegion,
          ra: 52.300, dec: 31.317, major: 6.0, minor: 3.0,
          mag: 5.6, con: "Per",
          filters: FilterRecommendation(.lrgb(l: 6, r: 3, g: 3, b: 3),
              secondary: .sho(ha: 4, oiii: 2, sii: 2),
              notes: "Mixed reflection + Herbig-Haro emission")),

        // NGC 1499 — California Nebula
        t("NGC1499", "California Nebula", .emissionNebula,
          ra: 60.217, dec: 36.617, major: 145.0, minor: 40.0,
          mag: 6.0, sb: 14.0, con: "Per",
          filters: FilterRecommendation(.hoo(ha: 5, oiii: 2),
              notes: "Very large — wide field needed; Ha dominant")),

        // NGC 1977 — Running Man Nebula
        t("NGC1977", "Running Man Nebula", .reflectionNebula,
          ra: 83.850, dec: -4.833, major: 20.0, minor: 10.0,
          mag: 7.0, con: "Ori",
          filters: FilterRecommendation(.lrgb(l: 4, r: 3, g: 3, b: 3),
              secondary: .sho(ha: 3, oiii: 3, sii: 1),
              notes: "Reflection + emission components")),

        // NGC 2024 — Flame Nebula
        t("NGC2024", "Flame Nebula", .emissionNebula,
          ra: 85.417, dec: -1.850, major: 30.0, minor: 30.0,
          mag: 7.2, con: "Ori", filters: shoDefault),

        // NGC 2174 — Monkey Head Nebula
        t("NGC2174", "Monkey Head Nebula", .emissionNebula,
          ra: 92.050, dec: 20.500, major: 40.0, minor: 30.0,
          con: "Ori", filters: shoDefault),

        // NGC 2237 — Rosette Nebula
        t("NGC2237", "Rosette Nebula", .emissionNebula,
          ra: 97.967, dec: 5.033, major: 80.0, minor: 60.0,
          mag: 9.0, sb: 14.0, con: "Mon",
          filters: shoDefault, aliases: ["NGC2238", "NGC2239", "NGC2246", "NGC2244", "Caldwell 49", "SH2-275"]),

        // NGC 2264 — Cone Nebula / Christmas Tree
        t("NGC2264", "Cone Nebula", .emissionNebula,
          ra: 100.242, dec: 9.883, major: 20.0, minor: 10.0,
          mag: 3.9, con: "Mon", filters: shoDefault,
          aliases: ["Christmas Tree Cluster", "SH2-273"]),

        // NGC 2359 — Thor's Helmet
        t("NGC2359", "Thor's Helmet", .wolfRayetNebula,
          ra: 109.275, dec: -13.217, major: 10.0, minor: 5.0,
          mag: 11.5, con: "CMa",
          filters: FilterRecommendation(.sho(ha: 5, oiii: 5, sii: 3),
              notes: "OIII-rich Wolf-Rayet bubble + SII shock fronts")),

        // NGC 2392 — Eskimo/Clown Face Nebula
        t("NGC2392", "Eskimo Nebula", .planetaryNebula,
          ra: 112.292, dec: 20.912, major: 0.7, minor: 0.7,
          mag: 9.2, con: "Gem", filters: hooPN),

        // NGC 2403 — Spiral galaxy
        t("NGC2403", nil, .galaxy,
          ra: 114.214, dec: 65.602, major: 21.9, minor: 12.3,
          mag: 8.5, con: "Cam", filters: galaxyHa),

        // NGC 2841 — Flocculent spiral
        t("NGC2841", nil, .galaxy,
          ra: 140.511, dec: 50.977, major: 8.1, minor: 3.5,
          mag: 9.2, con: "UMa", filters: lrgbDefault),

        // NGC 2903 — Barred spiral
        t("NGC2903", nil, .galaxy,
          ra: 143.042, dec: 21.501, major: 12.6, minor: 6.0,
          mag: 8.9, con: "Leo", filters: galaxyHa),

        // NGC 3184 — Spiral galaxy
        t("NGC3184", nil, .galaxy,
          ra: 154.570, dec: 41.424, major: 7.4, minor: 6.9,
          mag: 9.8, sb: 14.4, con: "UMa", filters: galaxyHa),

        // NGC 3190 — Hickson 44 member
        t("NGC3190", nil, .galaxyGroup,
          ra: 154.524, dec: 21.832, major: 4.4, minor: 1.5,
          mag: 11.1, con: "Leo", filters: lrgbDefault),

        // NGC 3628 — Hamburger Galaxy (Leo Triplet)
        t("NGC3628", "Hamburger Galaxy", .galaxy,
          ra: 170.071, dec: 13.589, major: 14.8, minor: 3.0,
          mag: 9.5, sb: 13.5, con: "Leo", filters: lrgbDefault),

        // NGC 4244 — Silver Needle Galaxy
        t("NGC4244", "Silver Needle Galaxy", .galaxy,
          ra: 184.374, dec: 37.807, major: 16.6, minor: 1.9,
          mag: 10.4, con: "CVn", filters: lrgbDefault),

        // NGC 4361 — Planetary nebula
        t("NGC4361", nil, .planetaryNebula,
          ra: 186.127, dec: -18.786, major: 1.3, minor: 1.3,
          mag: 10.9, con: "Crv", filters: hooPN),

        // NGC 4565 — Needle Galaxy
        t("NGC4565", "Needle Galaxy", .galaxy,
          ra: 189.087, dec: 25.988, major: 15.8, minor: 1.9,
          mag: 9.6, sb: 13.2, con: "Com", filters: lrgbDefault),

        // NGC 4631 — Whale Galaxy
        t("NGC4631", "Whale Galaxy", .galaxy,
          ra: 190.533, dec: 32.541, major: 15.5, minor: 2.7,
          mag: 9.2, con: "CVn", filters: galaxyHa),

        // NGC 4656 — Hockey Stick Galaxy
        t("NGC4656", "Hockey Stick Galaxy", .galaxy,
          ra: 190.990, dec: 32.170, major: 15.1, minor: 2.4,
          mag: 10.5, con: "CVn", filters: lrgbDefault),

        // NGC 5128 — Centaurus A
        t("NGC5128", "Centaurus A", .galaxy,
          ra: 201.365, dec: -43.019, major: 25.7, minor: 20.0,
          mag: 6.8, con: "Cen", filters: lrgbDefault),

        // NGC 5907 — Splinter Galaxy
        t("NGC5907", "Splinter Galaxy", .galaxy,
          ra: 228.974, dec: 56.329, major: 12.6, minor: 1.4,
          mag: 10.3, con: "Dra", filters: lrgbDefault),

        // NGC 6188 — Fighting Dragons of Ara
        t("NGC6188", "Fighting Dragons", .emissionNebula,
          ra: 250.117, dec: -48.767, major: 20.0, minor: 12.0,
          con: "Ara", filters: shoDefault),

        // NGC 6334 — Cat's Paw Nebula
        t("NGC6334", "Cat's Paw Nebula", .emissionNebula,
          ra: 260.150, dec: -35.950, major: 40.0, minor: 25.0,
          con: "Sco", filters: shoDefault),

        // NGC 6357 — Lobster Nebula
        t("NGC6357", "Lobster Nebula", .emissionNebula,
          ra: 261.375, dec: -34.350, major: 50.0, minor: 40.0,
          con: "Sco", filters: shoDefault),

        // NGC 6543 — Cat's Eye Nebula
        t("NGC6543", "Cat's Eye Nebula", .planetaryNebula,
          ra: 269.639, dec: 66.633, major: 0.4, minor: 0.3,
          mag: 8.1, con: "Dra", filters: hooPN),

        // NGC 6559 — Near Lagoon Nebula
        t("NGC6559", nil, .emissionNebula,
          ra: 271.400, dec: -24.100, major: 8.0, minor: 5.0,
          con: "Sgr", filters: shoDefault),

        // NGC 6726/6727/6729 — Corona Australis complex
        t("NGC6726", "Corona Australis Nebula", .reflectionNebula,
          ra: 286.133, dec: -36.900, major: 9.0, minor: 7.0,
          con: "CrA", filters: nbNotUseful, aliases: ["NGC6727", "NGC6729"]),

        // NGC 6781 — Planetary nebula
        t("NGC6781", nil, .planetaryNebula,
          ra: 289.617, dec: 6.542, major: 1.8, minor: 1.8,
          mag: 11.4, con: "Aql", filters: hooPN),

        // NGC 6820/6823 — Emission nebula + open cluster
        t("NGC6820", nil, .emissionNebula,
          ra: 295.783, dec: 23.100, major: 40.0, minor: 30.0,
          con: "Vul",
          filters: shoDefault, aliases: ["NGC6823"]),

        // NGC 6826 — Blinking Planetary
        t("NGC6826", "Blinking Planetary", .planetaryNebula,
          ra: 296.200, dec: 50.525, major: 0.4, minor: 0.4,
          mag: 8.8, con: "Cyg", filters: hooPN),

        // NGC 6888 — Crescent Nebula
        t("NGC6888", "Crescent Nebula", .wolfRayetNebula,
          ra: 303.058, dec: 38.350, major: 18.0, minor: 12.0,
          mag: 7.4, con: "Cyg",
          filters: FilterRecommendation(.sho(ha: 5, oiii: 5, sii: 2),
              notes: "OIII-rich Wolf-Rayet bubble"),
          aliases: ["Caldwell 27", "SH2-105"]),

        // NGC 6914 — Reflection nebula in Cygnus
        t("NGC6914", nil, .reflectionNebula,
          ra: 305.417, dec: 42.483, major: 5.0, minor: 3.0,
          con: "Cyg", filters: nbNotUseful),

        // NGC 6934 — Globular cluster
        t("NGC6934", nil, .globularCluster,
          ra: 308.548, dec: 7.404, major: 7.1, minor: 7.1,
          mag: 8.8, con: "Del", filters: lrgbDefault),

        // NGC 6946 — Fireworks Galaxy
        t("NGC6946", "Fireworks Galaxy", .galaxy,
          ra: 308.718, dec: 60.154, major: 11.5, minor: 9.8,
          mag: 8.8, con: "Cep", filters: galaxyHa),

        // NGC 6960 — Western Veil / Witch's Broom
        t("NGC6960", "Western Veil Nebula", .supernovaRemnant,
          ra: 312.167, dec: 30.717, major: 70.0, minor: 6.0,
          mag: 7.0, con: "Cyg",
          filters: FilterRecommendation(.sho(ha: 4, oiii: 6, sii: 2),
              notes: "OIII dominant in Veil — use more OIII than typical SNR"),
          aliases: ["NGC6992", "NGC6995", "NGC6979", "Caldwell 33", "Caldwell 34", "Witch's Broom"]),

        // NGC 7000 — North America Nebula
        // IC5070 (Pelican) is a sub-target — has own entry + parentTargetMap
        t("NGC7000", "North America Nebula", .emissionNebula,
          ra: 314.667, dec: 44.333, major: 120.0, minor: 100.0,
          mag: 4.0, sb: 15.0, con: "Cyg",
          filters: shoDefault, aliases: ["Caldwell 20", "SH2-117"]),

        // NGC 7023 — Iris Nebula
        t("NGC7023", "Iris Nebula", .reflectionNebula,
          ra: 315.392, dec: 68.167, major: 18.0, minor: 18.0,
          mag: 7.4, con: "Cep",
          filters: FilterRecommendation(.lrgb(l: 6, r: 3, g: 3, b: 4),
              notes: "Blue reflection — extra B channel; NB mostly not useful"),
          aliases: ["Caldwell 4"]),

        // NGC 7129 — Reflection/emission nebula
        t("NGC7129", nil, .starFormingRegion,
          ra: 325.700, dec: 66.117, major: 8.0, minor: 7.0,
          con: "Cep",
          filters: FilterRecommendation(.lrgb(l: 5, r: 3, g: 3, b: 3),
              secondary: .hoo(ha: 2, oiii: 1)),
          aliases: ["Caldwell 8"]),

        // NGC 7293 — Helix Nebula
        t("NGC7293", "Helix Nebula", .planetaryNebula,
          ra: 337.411, dec: -20.837, major: 25.0, minor: 22.0,
          mag: 7.3, sb: 13.5, con: "Aqr",
          filters: FilterRecommendation(.hoo(ha: 3, oiii: 4),
              notes: "Large PN — OIII dominant, needs wide field"),
          aliases: ["Caldwell 63"]),

        // NGC 7331 — Spiral galaxy
        t("NGC7331", nil, .galaxy,
          ra: 339.267, dec: 34.416, major: 10.5, minor: 3.7,
          mag: 9.5, sb: 13.5, con: "Peg", filters: lrgbDefault,
          aliases: ["Caldwell 30"]),

        // NGC 7380 — Wizard Nebula
        t("NGC7380", "Wizard Nebula", .emissionNebula,
          ra: 341.800, dec: 58.133, major: 25.0, minor: 25.0,
          mag: 7.2, con: "Cep", filters: shoDefault,
          aliases: ["SH2-142"]),

        // NGC 7479 — Barred spiral
        t("NGC7479", nil, .galaxy,
          ra: 346.236, dec: 12.323, major: 4.1, minor: 3.1,
          mag: 10.9, con: "Peg", filters: lrgbDefault,
          aliases: ["Caldwell 44"]),

        // NGC 7635 — Bubble Nebula
        t("NGC7635", "Bubble Nebula", .emissionNebula,
          ra: 350.200, dec: 61.200, major: 15.0, minor: 8.0,
          mag: 7.0, con: "Cas",
          filters: FilterRecommendation(.sho(ha: 5, oiii: 4, sii: 3),
              notes: "SII shows shock structure around the bubble"),
          aliases: ["Caldwell 11", "SH2-162"]),

        // NGC 7662 — Blue Snowball Nebula
        t("NGC7662", "Blue Snowball", .planetaryNebula,
          ra: 351.958, dec: 42.533, major: 0.5, minor: 0.5,
          mag: 8.3, con: "And", filters: hooPN,
          aliases: ["Caldwell 22"]),

        // NGC 7789 — Caroline's Rose
        t("NGC7789", "Caroline's Rose", .openCluster,
          ra: 359.333, dec: 56.717, major: 16.0, minor: 16.0,
          mag: 6.7, con: "Cas", filters: rgbDefault,
          aliases: ["Caldwell 56"]),

        // NGC 7814 — Little Sombrero
        t("NGC7814", "Little Sombrero", .galaxy,
          ra: 0.812, dec: 16.146, major: 6.3, minor: 2.6,
          mag: 10.6, con: "Peg", filters: lrgbDefault,
          aliases: ["Caldwell 43"]),
    ]

    // MARK: - IC Catalog Targets

    static let icTargets: [DeepSkyTarget] = [
        // IC 342 — Hidden Galaxy
        t("IC342", "Hidden Galaxy", .galaxy,
          ra: 56.702, dec: 68.096, major: 21.4, minor: 20.9,
          mag: 9.1, sb: 14.5, con: "Cam", filters: galaxyHa,
          aliases: ["Caldwell 5"]),

        // IC 405 — Flaming Star Nebula
        t("IC405", "Flaming Star Nebula", .emissionNebula,
          ra: 79.042, dec: 34.267, major: 30.0, minor: 20.0,
          con: "Aur",
          filters: FilterRecommendation(.sho(ha: 5, oiii: 3, sii: 2),
              secondary: .lrgb(l: 4, r: 3, g: 3, b: 3),
              notes: "Mixed emission + reflection — NB for gas, LRGB for dust")),

        // IC 410 — Tadpoles Nebula
        t("IC410", "Tadpoles Nebula", .emissionNebula,
          ra: 79.917, dec: 33.350, major: 40.0, minor: 30.0,
          con: "Aur", filters: shoDefault),

        // IC 434 — Horsehead Nebula (dark against emission)
        // IC434 = emission nebula ridge; B33 = dark horsehead silhouette on it. Merged as one target.
        t("IC434", "Horsehead Nebula", .emissionNebula,
          ra: 85.250, dec: -2.450, major: 60.0, minor: 10.0,
          con: "Ori",
          filters: FilterRecommendation(.sho(ha: 6, oiii: 2, sii: 2),
              secondary: .lrgb(l: 6, r: 2, g: 2, b: 2),
              notes: "Ha dominant — horsehead is dark silhouette against IC434 emission"),
          aliases: ["B33", "Barnard 33"]),

        // IC 443 — Jellyfish Nebula
        t("IC443", "Jellyfish Nebula", .supernovaRemnant,
          ra: 94.250, dec: 22.567, major: 50.0, minor: 40.0,
          con: "Gem", filters: shoSNR,
          aliases: ["SH2-248"]),

        // IC 1275 — Near M8
        t("IC1275", nil, .emissionNebula,
          ra: 271.650, dec: -23.967, major: 8.0, minor: 5.0,
          con: "Sgr", filters: shoDefault),

        // IC 1318 — Butterfly/Sadr Nebula
        t("IC1318", "Sadr Region", .emissionNebula,
          ra: 305.450, dec: 40.250, major: 120.0, minor: 60.0,
          con: "Cyg", filters: shoDefault,
          aliases: ["Butterfly Nebula", "Gamma Cygni Nebula"]),

        // IC 1396 — Elephant's Trunk Nebula
        t("IC1396", "Elephant's Trunk Nebula", .emissionNebula,
          ra: 323.583, dec: 57.500, major: 170.0, minor: 140.0,
          sb: 15.0, con: "Cep",
          filters: shoDefault, aliases: ["IC1396A"]),

        // IC 1613 — Irregular galaxy (Local Group)
        t("IC1613", nil, .galaxy,
          ra: 16.200, dec: 2.133, major: 16.0, minor: 14.5,
          mag: 9.2, con: "Cet", filters: lrgbDefault,
          aliases: ["Caldwell 51"]),

        // IC 1795 — Fish Head / Northern Bear
        t("IC1795", "Fish Head Nebula", .emissionNebula,
          ra: 38.200, dec: 62.000, major: 20.0, minor: 12.0,
          con: "Cas", filters: shoDefault),

        // IC 1805 — Heart Nebula
        // IC1795 (Fish Head) is a sub-target, not alias — has own entry + parentTargetMap
        t("IC1805", "Heart Nebula", .emissionNebula,
          ra: 38.175, dec: 61.467, major: 60.0, minor: 60.0,
          mag: 6.5, sb: 14.0, con: "Cas",
          filters: shoDefault),

        // IC 1848 — Soul Nebula
        t("IC1848", "Soul Nebula", .emissionNebula,
          ra: 44.100, dec: 60.433, major: 60.0, minor: 30.0,
          con: "Cas", filters: shoDefault,
          aliases: ["SH2-199", "Westerhout 5", "W5"]),

        // IC 2118 — Witch Head Nebula
        t("IC2118", "Witch Head Nebula", .reflectionNebula,
          ra: 79.083, dec: -7.217, major: 180.0, minor: 60.0,
          con: "Eri",
          filters: FilterRecommendation(.lrgb(l: 6, r: 2, g: 2, b: 4),
              notes: "Blue reflection — extra B channel")),

        // IC 2177 — Seagull Nebula
        t("IC2177", "Seagull Nebula", .emissionNebula,
          ra: 105.750, dec: -10.417, major: 120.0, minor: 40.0,
          con: "Mon", filters: shoDefault),

        // IC 2574 — Coddington's Nebula (galaxy)
        t("IC2574", "Coddington's Nebula", .galaxy,
          ra: 157.088, dec: 68.412, major: 13.2, minor: 5.4,
          mag: 10.8, con: "UMa", filters: lrgbDefault),

        // IC 4592 — Blue Horsehead Nebula
        t("IC4592", "Blue Horsehead", .reflectionNebula,
          ra: 242.667, dec: -19.533, major: 60.0, minor: 15.0,
          con: "Sco", filters: nbNotUseful),

        // IC 4628 — Prawn Nebula
        t("IC4628", "Prawn Nebula", .emissionNebula,
          ra: 253.050, dec: -40.367, major: 60.0, minor: 20.0,
          con: "Sco", filters: shoDefault),

        // IC 4756 — Open cluster
        t("IC4756", nil, .openCluster,
          ra: 279.667, dec: 5.433, major: 52.0, minor: 52.0,
          mag: 4.6, con: "Ser", filters: rgbDefault),

        // IC 5067/5070 — Pelican Nebula (part of NGC 7000 complex)
        t("IC5067", "Pelican Nebula", .emissionNebula,
          ra: 313.333, dec: 44.350, major: 60.0, minor: 50.0,
          con: "Cyg", filters: shoDefault, aliases: ["IC5070"]),

        // IC 5146 — Cocoon Nebula
        t("IC5146", "Cocoon Nebula", .emissionNebula,
          ra: 325.483, dec: 47.267, major: 12.0, minor: 12.0,
          mag: 7.2, con: "Cyg",
          filters: FilterRecommendation(.sho(ha: 5, oiii: 3, sii: 2),
              secondary: .lrgb(l: 4, r: 3, g: 3, b: 3),
              notes: "Emission core + surrounding dark nebula"),
          aliases: ["Caldwell 19", "SH2-125"]),
    ]

    // MARK: - Sharpless HII Regions

    static let sharplessTargets: [DeepSkyTarget] = [
        // SH2-101 — Tulip Nebula
        t("SH2-101", "Tulip Nebula", .emissionNebula,
          ra: 299.900, dec: 35.283, major: 16.0, minor: 9.0,
          con: "Cyg", filters: shoDefault),

        // SH2-106 — Hourglass Nebula
        t("SH2-106", nil, .emissionNebula,
          ra: 306.183, dec: 37.383, major: 3.0, minor: 1.5,
          con: "Cyg", filters: shoDefault),

        // SH2-112 — Emission nebula near Deneb
        t("SH2-112", nil, .emissionNebula,
          ra: 313.517, dec: 45.433, major: 15.0, minor: 12.0,
          con: "Cyg", filters: shoDefault),

        // SH2-115 — Emission nebula
        t("SH2-115", nil, .emissionNebula,
          ra: 316.700, dec: 48.167, major: 30.0, minor: 20.0,
          con: "Cyg", filters: shoDefault),

        // SH2-119 — Emission nebula
        t("SH2-119", nil, .emissionNebula,
          ra: 319.650, dec: 43.833, major: 15.0, minor: 12.0,
          con: "Cyg", filters: shoDefault),

        // SH2-129 — Flying Bat Nebula
        t("SH2-129", "Flying Bat Nebula", .emissionNebula,
          ra: 325.833, dec: 60.000, major: 120.0, minor: 80.0,
          con: "Cep",
          filters: FilterRecommendation(.sho(ha: 6, oiii: 6, sii: 2),
              notes: "Contains OU4 (Giant Squid) — needs OIII")),

        // SH2-132 — Lion Nebula
        t("SH2-132", "Lion Nebula", .emissionNebula,
          ra: 333.000, dec: 56.167, major: 30.0, minor: 15.0,
          con: "Cep", filters: shoDefault),

        // SH2-155 — Cave Nebula
        t("SH2-155", "Cave Nebula", .emissionNebula,
          ra: 342.967, dec: 62.600, major: 50.0, minor: 30.0,
          con: "Cep", filters: shoDefault,
          aliases: ["Caldwell 9"]),

        // SH2-157 — Lobster Claw Nebula
        t("SH2-157", "Lobster Claw Nebula", .emissionNebula,
          ra: 345.233, dec: 58.383, major: 30.0, minor: 25.0,
          con: "Cas", filters: shoDefault),

        // SH2-171 — Part of IC 1805 complex
        t("SH2-171", nil, .emissionNebula,
          ra: 0.750, dec: 67.017, major: 20.0, minor: 15.0,
          con: "Cep", filters: shoDefault),

        // SH2-188 — Dolphin Head Nebula
        t("SH2-188", "Dolphin Head Nebula", .planetaryNebula,
          ra: 16.300, dec: 58.367, major: 9.0, minor: 4.0,
          con: "Cas", filters: hooPN),

        // SH2-240 — Simeis 147 / Spaghetti Nebula
        t("SH2-240", "Spaghetti Nebula", .supernovaRemnant,
          ra: 84.000, dec: 28.000, major: 180.0, minor: 180.0,
          con: "Tau",
          filters: FilterRecommendation(.hoo(ha: 6, oiii: 4),
              notes: "Extremely faint — long integration needed; also known as Simeis 147"),
          aliases: ["Simeis 147", "Sim 147"]),

        // SH2-261 — Lower's Nebula
        t("SH2-261", "Lower's Nebula", .emissionNebula,
          ra: 92.700, dec: 17.133, major: 30.0, minor: 25.0,
          con: "Ori", filters: shoDefault),

        // SH2-275 — Rosette Nebula (alternate catalog)
        // Already listed as NGC 2237

        // SH2-308 — Dolphin Nebula
        t("SH2-308", "Dolphin Nebula", .wolfRayetNebula,
          ra: 103.050, dec: -26.350, major: 40.0, minor: 35.0,
          con: "CMa",
          filters: FilterRecommendation(.hoo(ha: 2, oiii: 5),
              notes: "OIII dominant — Wolf-Rayet bubble")),
    ]

    // MARK: - Abell Planetary Nebulae & Galaxy Clusters

    static let abellTargets: [DeepSkyTarget] = [
        // Abell 12 — Hidden planetary near Mu Ori
        t("ABELL12", nil, .planetaryNebula,
          ra: 89.633, dec: 9.617, major: 0.6, minor: 0.6,
          mag: 13.9, con: "Ori", filters: hooPN),

        // Abell 21 — Medusa Nebula
        t("ABELL21", "Medusa Nebula", .planetaryNebula,
          ra: 110.833, dec: 13.250, major: 10.0, minor: 8.0,
          mag: 10.0, con: "Gem", filters: hooPN,
          aliases: ["SH2-274"]),

        // Abell 31 — Large planetary nebula
        t("ABELL31", nil, .planetaryNebula,
          ra: 127.550, dec: 8.883, major: 17.0, minor: 16.0,
          mag: 12.2, con: "Cnc",
          filters: FilterRecommendation(.hoo(ha: 2, oiii: 5),
              notes: "Very faint — extreme OIII dominance")),

        // Abell 33 — Diamond Ring Nebula
        t("ABELL33", "Diamond Ring Nebula", .planetaryNebula,
          ra: 145.487, dec: -2.809, major: 4.5, minor: 4.5,
          mag: 12.7, con: "Hya", filters: hooPN),

        // Abell 39 — Spherical planetary nebula
        t("ABELL39", nil, .planetaryNebula,
          ra: 244.587, dec: 27.900, major: 2.8, minor: 2.8,
          mag: 13.7, con: "Her", filters: hooPN),

        // Abell 426 — Perseus Galaxy Cluster
        t("ABELL426", "Perseus Cluster", .galaxyGroup,
          ra: 49.950, dec: 41.517, major: 120.0, minor: 120.0,
          con: "Per", filters: lrgbDefault),

        // Abell 1656 — Coma Galaxy Cluster
        t("ABELL1656", "Coma Cluster", .galaxyGroup,
          ra: 194.900, dec: 27.950, major: 240.0, minor: 240.0,
          con: "Com", filters: lrgbDefault),

        // Abell 2151 — Hercules Galaxy Cluster
        t("ABELL2151", "Hercules Cluster (galaxies)", .galaxyGroup,
          ra: 241.300, dec: 17.717, major: 30.0, minor: 30.0,
          con: "Her", filters: lrgbDefault),
    ]

    // MARK: - Barnard Dark Nebulae

    static let barnardTargets: [DeepSkyTarget] = [
        // B33 — Horsehead (see IC 434 for emission background)
        // B33 merged into IC434 entry above (same object — horsehead + emission ridge)

        // B72 — Snake Nebula
        t("B72", "Snake Nebula", .darkNebula,
          ra: 260.450, dec: -23.617, major: 30.0, minor: 3.0,
          con: "Oph", filters: lrgbDefault),

        // B86 — Inkspot Nebula
        t("B86", "Inkspot Nebula", .darkNebula,
          ra: 273.467, dec: -27.900, major: 5.0, minor: 3.0,
          con: "Sgr", filters: lrgbDefault),

        // B142/B143 — Barnard's E
        t("B142", "Barnard's E", .darkNebula,
          ra: 294.817, dec: 1.617, major: 40.0, minor: 30.0,
          con: "Aql", filters: lrgbDefault, aliases: ["B143"]),

        // B150 — Seahorse Nebula
        t("B150", "Seahorse Nebula", .darkNebula,
          ra: 310.333, dec: 35.833, major: 50.0, minor: 10.0,
          con: "Cep", filters: lrgbDefault),

        // LDN 1251 — Dark nebula in Cepheus
        t("LDN1251", nil, .darkNebula,
          ra: 339.333, dec: 75.200, major: 20.0, minor: 10.0,
          con: "Cep", filters: lrgbDefault),

        // LDN 1470 — Dark nebula
        t("LDN1470", nil, .darkNebula,
          ra: 60.000, dec: 32.500, major: 15.0, minor: 8.0,
          con: "Per", filters: lrgbDefault),

        // LDN 1622 — Boogeyman Nebula
        t("LDN1622", "Boogeyman Nebula", .darkNebula,
          ra: 86.950, dec: 1.850, major: 30.0, minor: 10.0,
          con: "Ori",
          filters: FilterRecommendation(.lrgb(l: 6, r: 2, g: 2, b: 2),
              secondary: .hoo(ha: 2, oiii: 1),
              notes: "Ha faintly illuminates surrounding gas")),
    ]

    // MARK: - Other Notable Targets

    static let otherTargets: [DeepSkyTarget] = [
        // vdB 1 — Reflection nebula
        t("VDB1", nil, .reflectionNebula,
          ra: 0.367, dec: 58.617, major: 6.0, minor: 6.0,
          con: "Cas", filters: nbNotUseful),

        // vdB 14 — Reflection nebula
        t("VDB14", nil, .reflectionNebula,
          ra: 47.017, dec: 53.900, major: 4.0, minor: 3.0,
          con: "Cam", filters: nbNotUseful),

        // vdB 142 — Elephant's Trunk (reflection component)
        t("VDB142", "Elephant's Trunk", .reflectionNebula,
          ra: 323.733, dec: 57.500, major: 10.0, minor: 5.0,
          con: "Cep",
          filters: FilterRecommendation(.sho(ha: 5, oiii: 3, sii: 2),
              secondary: .lrgb(l: 4, r: 3, g: 3, b: 3),
              notes: "Dark globule rim — Ha + LRGB for dust structure")),

        // Cederblad 214 — Emission nebula in Cepheus
        // NGC7822 — emission nebula complex; CED214 is its brightest sub-region
        t("NGC7822", nil, .emissionNebula,
          ra: 345.083, dec: 67.867, major: 40.0, minor: 30.0,
          con: "Cep", filters: shoDefault,
          aliases: ["CED214", "Cederblad 214"]),

        // OU4 — Giant Squid Nebula (inside SH2-129)
        t("OU4", "Giant Squid Nebula", .planetaryNebula,
          ra: 326.000, dec: 59.867, major: 60.0, minor: 10.0,
          con: "Cep",
          filters: FilterRecommendation(.hoo(ha: 2, oiii: 8),
              notes: "EXTREMELY faint — OIII only; 50+ hours needed")),

        // Rho Ophiuchi Cloud Complex
        t("RHOOPH", "Rho Ophiuchi", .starFormingRegion,
          ra: 246.833, dec: -23.450, major: 270.0, minor: 180.0,
          con: "Oph",
          filters: FilterRecommendation(.lrgb(l: 4, r: 3, g: 3, b: 3),
              secondary: .sho(ha: 3, oiii: 2, sii: 2),
              notes: "Mixed emission + reflection + dark — LRGB for color, NB for gas")),

        // Cygnus Wall (part of NGC 7000)
        t("CYGNUSWALL", "Cygnus Wall", .emissionNebula,
          ra: 314.500, dec: 43.833, major: 60.0, minor: 20.0,
          con: "Cyg", filters: shoDefault),

        // Stephan's Quintet
        t("STEPHANSQUINTET", "Stephan's Quintet", .galaxyGroup,
          ra: 339.017, dec: 33.967, major: 4.0, minor: 3.0,
          mag: 13.6, con: "Peg",
          filters: lrgbDefault, aliases: ["NGC7317", "NGC7318", "NGC7319", "NGC7320"]),

        // Leo Triplet (M65 + M66 + NGC 3628)
        // Members (M65, M66, NGC3628) have standalone entries — linked via parentTargetMap
        t("LEOTRIPLET", "Leo Triplet", .galaxyGroup,
          ra: 169.900, dec: 13.100, major: 30.0, minor: 15.0,
          con: "Leo", filters: lrgbDefault),

        // Markarian's Chain (Virgo Cluster)
        t("MARKARIANSCHAIN", "Markarian's Chain", .galaxyGroup,
          ra: 186.600, dec: 12.700, major: 90.0, minor: 15.0,
          con: "Vir", filters: lrgbDefault),

        // Antennae Galaxies
        t("NGC4038", "Antennae Galaxies", .galaxyGroup,
          ra: 180.471, dec: -18.867, major: 5.2, minor: 3.1,
          mag: 10.3, con: "Crv",
          filters: lrgbDefault, aliases: ["NGC4039"]),

        // Caldwell 49 — Rosette Nebula (duplicate reference via Caldwell)
        // Already listed as NGC 2237

        // IFN targets (no catalog — named by discoverers)
        t("MWC1", "Mandel-Wilson Catalog 1", .ifn,
          ra: 200.000, dec: 53.000, major: 120.0, minor: 60.0,
          con: "UMa",
          filters: lOnlyDefault),

        // Simeis 147 — already listed as SH2-240

        // CTB 1 — Supernova remnant in Cassiopeia
        t("CTB1", nil, .supernovaRemnant,
          ra: 0.050, dec: 62.467, major: 34.0, minor: 34.0,
          con: "Cas",
          filters: FilterRecommendation(.hoo(ha: 4, oiii: 5),
              notes: "Extremely faint SNR — OIII + Ha")),

        // Jones-Emberson 1 — Headphone Nebula
        t("JONESEMBERSON1", "Headphone Nebula", .planetaryNebula,
          ra: 114.250, dec: 47.700, major: 6.0, minor: 5.5,
          mag: 15.0, con: "Lyn",
          filters: FilterRecommendation(.hoo(ha: 2, oiii: 5),
              notes: "Extremely faint — OIII dominant")),

        // WR 134 Ring — Wolf-Rayet nebula
        t("WR134", nil, .wolfRayetNebula,
          ra: 303.167, dec: 36.333, major: 15.0, minor: 12.0,
          con: "Cyg",
          filters: FilterRecommendation(.sho(ha: 4, oiii: 5, sii: 2),
              notes: "Near Crescent Nebula — OIII-rich shell")),

        // Sh2-86 / NGC 6820 complex — already listed

        // HCG 92 — Stephan's Quintet (alternate designation)
        // Already listed as STEPHANSQUINTET

        // Abell 85 — Peculiar planetary nebula
        t("ABELL85", nil, .planetaryNebula,
          ra: 285.317, dec: -4.667, major: 2.0, minor: 2.0,
          mag: 15.0, con: "Aql",
          filters: FilterRecommendation(.hoo(ha: 2, oiii: 5),
              notes: "Very faint — OIII dominant")),

        // NGC 6992 — Eastern Veil (already captured via NGC 6960 aliases)

        // Pickering's Triangle — part of Veil complex
        t("PICKERINGSTRIANGLE", "Pickering's Triangle", .supernovaRemnant,
          ra: 313.000, dec: 32.000, major: 45.0, minor: 10.0,
          con: "Cyg",
          filters: FilterRecommendation(.sho(ha: 4, oiii: 6, sii: 2),
              notes: "OIII dominant — part of Veil Nebula complex")),
    ]
}

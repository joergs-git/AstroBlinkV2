// Target name normalization and clustering for consistent cross-session comparison.
// Handles common naming variations: "NGC 7000" = "NGC7000", "M 42" = "M42",
// "Orion Nebula" = "M42", "Elephant's Trunk Nebula" = "IC1396A", etc.

import Foundation

enum TargetCatalog {

    // MARK: - Name Normalization

    /// Normalize a target name to a canonical form for grouping.
    /// Handles catalog prefix spacing, common aliases, and suffixes.
    ///
    /// Examples:
    ///   "NGC 7000" → "NGC7000"
    ///   "M 42" → "M42"
    ///   "Orion Nebula" → "M42"
    ///   "IC 63 Ghost" → "IC63"
    ///   "Elephant's Trunk Nebula" → "IC1396A"
    ///   "NGC 281W" → "NGC281"
    ///   "FlatWizard" → "FLATWIZARD" (non-astro, kept as-is)
    static func canonicalName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Step 1: Check common name alias table first (case-insensitive)
        let lowered = trimmed.lowercased()
        if let alias = commonNameAliases[lowered] {
            return alias
        }
        // Check with stripped special chars too
        let strippedLower = lowered.replacingOccurrences(of: "'", with: "")
                                   .replacingOccurrences(of: "'", with: "")
                                   .replacingOccurrences(of: "-", with: " ")
        if let alias = commonNameAliases[strippedLower] {
            return alias
        }

        // Step 2: Normalize catalog prefixes — remove spaces between prefix and number
        // M 42 → M42, NGC 7000 → NGC7000, IC 1396 → IC1396, SH2-275 → SH2-275
        var normalized = trimmed

        // Match catalog patterns: "NGC 1234", "IC 1234", "M 42", "SH2-123", "PK 164+31.1"
        let catalogPattern = try? NSRegularExpression(
            pattern: #"^(NGC|IC|M|SH2|PGC|UGC|Abell|Arp|LDN|LBN|VdB|PK|Barnard|Ced|CED|Sh2|RCW|GUM|HH|Cr|Mel|Tr|Stock|vdB)\s+(\d+.*)"#,
            options: [.caseInsensitive]
        )
        if let match = catalogPattern?.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let prefixRange = Range(match.range(at: 1), in: normalized),
           let numRange = Range(match.range(at: 2), in: normalized) {
            let prefix = String(normalized[prefixRange]).uppercased()
            let number = String(normalized[numRange])
            // Strip common suffixes: "Ghost", "bubble", "butterfly", "Wide", "Core", "W"
            let cleanNum = stripSuffix(number)
            normalized = prefix + cleanNum
        } else {
            // Not a catalog entry — uppercase for consistency
            normalized = trimmed.uppercased()
        }

        // Step 3: Check aliases again after normalization
        if let alias = catalogAliases[normalized.uppercased()] {
            return alias
        }

        return normalized
    }

    /// Strip common user-added suffixes from target names.
    /// "NGC 281W" → "281", "IC 63 Ghost" → "63", "NGC 7635 bubble" → "7635"
    private static func stripSuffix(_ number: String) -> String {
        let suffixes = ["ghost", "bubble", "butterfly", "wide", "core", "narrow",
                        "center", "mosaic", "panel", "east", "west", "north", "south",
                        "w", "e", "n", "s"]
        var clean = number.trimmingCharacters(in: .whitespaces)
        for suffix in suffixes {
            // Only strip if suffix is after a space or if it's a single letter at the end
            if clean.lowercased().hasSuffix(" \(suffix)") {
                clean = String(clean.dropLast(suffix.count + 1))
            } else if suffix.count == 1 && clean.count > 1 {
                // Single letter suffix right after number: "281W" → "281"
                let lastChar = String(clean.last!).lowercased()
                if lastChar == suffix && clean.dropLast().last?.isNumber == true {
                    clean = String(clean.dropLast())
                }
            }
        }
        return clean.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Display Name (catalog → "M42 (Orion Nebula)")

    /// Returns a display name enriched with the common name if known.
    /// "M42" → "M42 (Orion Nebula)", "NGC7000" → "NGC7000 (North America)"
    static func displayName(_ canonical: String) -> String {
        if let common = catalogToCommonName[canonical.uppercased()] {
            return "\(canonical) (\(common))"
        }
        return canonical
    }

    /// Reverse lookup: catalog ID → common name
    private static let catalogToCommonName: [String: String] = [
        "M1": "Crab Nebula", "M8": "Lagoon Nebula", "M11": "Wild Duck",
        "M13": "Hercules Cluster", "M16": "Eagle Nebula", "M17": "Omega Nebula",
        "M20": "Trifid Nebula", "M27": "Dumbbell Nebula", "M31": "Andromeda",
        "M33": "Triangulum", "M42": "Orion Nebula", "M45": "Pleiades",
        "M51": "Whirlpool", "M57": "Ring Nebula", "M63": "Sunflower",
        "M64": "Black Eye", "M76": "Little Dumbbell", "M81": "Bode's Galaxy",
        "M82": "Cigar Galaxy", "M97": "Owl Nebula", "M99": "Starfish",
        "M101": "Pinwheel", "M104": "Sombrero",
        "NGC281": "Pacman Nebula", "NGC1499": "California Nebula",
        "NGC2024": "Flame Nebula", "NGC2174": "Monkey Head",
        "NGC2237": "Rosette Nebula", "NGC2244": "Rosette",
        "NGC2264": "Cone Nebula", "NGC2359": "Thor's Helmet",
        "NGC2392": "Eskimo Nebula", "NGC4565": "Needle Galaxy",
        "NGC6543": "Cat's Eye", "NGC6826": "Blinking Nebula",
        "NGC6888": "Crescent Nebula", "NGC6946": "Fireworks Galaxy",
        "NGC6960": "Veil Nebula", "NGC7000": "North America",
        "NGC7023": "Iris Nebula", "NGC7293": "Helix Nebula",
        "NGC7380": "Wizard Nebula", "NGC7635": "Bubble Nebula",
        "NGC7662": "Blue Snowball",
        "IC434": "Horsehead", "IC443": "Jellyfish",
        "IC405": "Flaming Star", "IC410": "Tadpole",
        "IC417": "Spider Nebula", "IC1396": "Elephant's Trunk",
        "IC1805": "Heart Nebula", "IC1848": "Soul Nebula",
        "IC5070": "Pelican Nebula", "IC5146": "Cocoon Nebula",
        "IC1318": "Butterfly Nebula",
        "SH2-101": "Tulip Nebula", "SH2-132": "Lion Nebula",
        "SH2-155": "Cave Nebula", "SH2-274": "Medusa Nebula",
        "SH2-275": "Rosette Region",
        "NGC3628": "Leo Triplet",
    ]

    // MARK: - Common Name Aliases

    /// Maps common/popular names to their catalog designations.
    /// Keys are lowercased for case-insensitive lookup.
    private static let commonNameAliases: [String: String] = [
        // Messier objects by popular name
        "orion nebula": "M42",
        "great orion nebula": "M42",
        "crab nebula": "M1",
        "ring nebula": "M57",
        "dumbbell nebula": "M27",
        "whirlpool galaxy": "M51",
        "pinwheel galaxy": "M101",
        "andromeda galaxy": "M31",
        "andromeda": "M31",
        "triangulum galaxy": "M33",
        "sombrero galaxy": "M104",
        "bodes galaxy": "M81",
        "cigar galaxy": "M82",
        "owl nebula": "M97",
        "eagle nebula": "M16",
        "pillars of creation": "M16",
        "omega nebula": "M17",
        "swan nebula": "M17",
        "lagoon nebula": "M8",
        "trifid nebula": "M20",
        "pleiades": "M45",
        "seven sisters": "M45",
        "hercules cluster": "M13",
        "wild duck cluster": "M11",
        "sunflower galaxy": "M63",
        "black eye galaxy": "M64",
        "starfish galaxy": "M99",

        // NGC objects by popular name
        "north america nebula": "NGC7000",
        "california nebula": "NGC1499",
        "horsehead nebula": "IC434",
        "horsehead": "IC434",
        "flame nebula": "NGC2024",
        "rosette nebula": "NGC2244",
        "rosette": "NGC2244",
        "heart nebula": "IC1805",
        "soul nebula": "IC1848",
        "pacman nebula": "NGC281",
        "bubble nebula": "NGC7635",
        "cocoon nebula": "IC5146",
        "jellyfish nebula": "IC443",
        "elephants trunk nebula": "IC1396A",
        "elephant trunk nebula": "IC1396A",
        "elephanttrunk nebula": "IC1396A",
        "elephanttrunknebula": "IC1396A",
        "pelican nebula": "IC5070",
        "crescent nebula": "NGC6888",
        "tulip nebula": "SH2-101",
        "veil nebula": "NGC6960",
        "western veil": "NGC6960",
        "eastern veil": "NGC6992",
        "witchs broom": "NGC6960",
        "witchs broom nebula": "NGC6960",
        "cone nebula": "NGC2264",
        "christmas tree cluster": "NGC2264",
        "monkey head nebula": "NGC2174",
        "iris nebula": "NGC7023",
        "cave nebula": "SH2-155",
        "lions nebula": "SH2-132",
        "wizard nebula": "NGC7380",
        "flaming star nebula": "IC405",
        "tadpole nebula": "IC410",
        "spider nebula": "IC417",
        "medusa nebula": "SH2-274",
        "cats eye nebula": "NGC6543",
        "helix nebula": "NGC7293",
        "blue snowball nebula": "NGC7662",
        "eskimo nebula": "NGC2392",
        "little dumbbell": "M76",
        "blinking nebula": "NGC6826",
        "thor's helmet": "NGC2359",
        "thors helmet": "NGC2359",
        "ngc7000": "NGC7000",
        "ngc 7000": "NGC7000",
        "ic63 ghost": "IC63",
        "ic 63 ghost": "IC63",
        "ic1318 butterfly": "IC1318",
        "ic 1318 butterfly": "IC1318",
        "ngc 7635 bubble": "NGC7635",
        "ngc7635 bubble": "NGC7635",
        "sh2 275": "SH2-275",

        // Galaxies
        "needle galaxy": "NGC4565",
        "fireworks galaxy": "NGC6946",
        "leo triplet": "NGC3628",
        "markarians chain": "NGC4477",
        "antennae galaxies": "NGC4038",

        // Misc
        "flatwizard": "FLATWIZARD",
        "flat wizard": "FLATWIZARD",
        "12p": "12P",
    ]

    /// Maps normalized catalog IDs to their primary designation (deduplication).
    private static let catalogAliases: [String: String] = [
        "NGC2244": "NGC2237",   // Rosette: cluster vs nebula — unify to nebula
        "NGC6992": "NGC6960",   // Eastern/Western Veil — unify
        "NGC6995": "NGC6960",   // Pickering's Triangle — part of Veil
        "IC1396A": "IC1396",    // Elephant's Trunk is part of IC1396
        "NGC1976": "M42",       // NGC alias for M42
        "NGC5194": "M51",       // NGC alias for M51
        "NGC5457": "M101",      // NGC alias for M101
        "NGC3031": "M81",       // NGC alias for M81
        "NGC3034": "M82",       // NGC alias for M82
        "NGC224":  "M31",       // NGC alias for M31
        "NGC598":  "M33",       // NGC alias for M33
        "NGC1952": "M1",        // NGC alias for M1
        "NGC6720": "M57",       // NGC alias for Ring Nebula
        "NGC6853": "M27",       // NGC alias for Dumbbell
        "NGC6611": "M16",       // NGC alias for Eagle
    ]
}

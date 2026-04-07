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
    static func canonicalName(_ raw: String, isRecursive: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Step 1: Check common name alias table first (case-insensitive)
        let lowered = trimmed.lowercased()
        if let alias = commonNameAliases[lowered] {
            return alias
        }
        // Check with stripped special chars too
        let strippedLower = lowered.replacingOccurrences(of: "'", with: "")
                                   .replacingOccurrences(of: "\u{2019}", with: "")
                                   .replacingOccurrences(of: "-", with: " ")
        if let alias = commonNameAliases[strippedLower] {
            return alias
        }

        // Step 1.3: Suffix normalization for typos — "Bode Galaxcie" → "bode" → try "bode galaxy"
        // Strip misspelled object-type suffixes and try canonical variants against alias table
        let typeSuffixes = ["nebula", "nebulae", "neubla", "nebual",
                            "galaxy", "galaxie", "galaxcy", "galaxcie",
                            "cluster", "cluser", "clutser"]
        let canonicalTypes = ["nebula", "galaxy", "cluster"]
        for suffix in typeSuffixes {
            if strippedLower.hasSuffix(suffix) || strippedLower.hasSuffix(suffix + "s") {
                let root = strippedLower
                    .replacingOccurrences(of: suffix + "s", with: "")
                    .replacingOccurrences(of: suffix, with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !root.isEmpty else { continue }
                // Try root + each canonical suffix
                for canonical in canonicalTypes {
                    if let alias = commonNameAliases[root + " " + canonical] {
                        return alias
                    }
                }
                // Try root alone (e.g., "bode" → not in aliases, but covers some)
                if let alias = commonNameAliases[root] {
                    return alias
                }
            }
        }

        // Step 1.5: Compound name splitting — "M81-Bode", "M81 Bode Galaxy"
        // Split on delimiters, try each part. First catalog ID match wins.
        if !isRecursive {
            let delimiters = CharacterSet(charactersIn: "- _")
            let parts = trimmed.components(separatedBy: delimiters)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                for part in parts {
                    let candidate = canonicalName(part, isRecursive: true)
                    // If it resolved to something different than just uppercased input,
                    // it matched a known catalog entry or alias
                    if candidate != part.uppercased() {
                        return candidate
                    }
                }
            }
        }

        // Step 2: Normalize catalog prefixes — handles ALL separator variants:
        // "IC 1848", "IC-1848", "IC1848", "iC18 48", "ic 18-48" → "IC1848"
        // "NGC 7000", "ngc7000", "NGC-7000", "N G C 7000" → "NGC7000"
        // "M 42", "M42", "m-42", "M 4 2" → "M42"
        // "SH2-275", "sh2 275", "Sh2275" → "SH2-275" (SH2 keeps dash)
        var normalized = trimmed

        // Known catalog prefixes (order matters — longer first to avoid partial matches)
        let prefixes = ["BARNARD", "ABELL", "STOCK", "SH2", "NGC", "PGC", "UGC", "LDN",
                        "LBN", "VDB", "RCW", "GUM", "CED", "MEL", "IC", "PK", "CR",
                        "HH", "TR", "OU", "M", "B"]

        let upper = normalized.uppercased()
        // Strip all spaces/dashes/underscores from the input to find prefix match
        let compacted = upper.replacingOccurrences(of: " ", with: "")
                             .replacingOccurrences(of: "-", with: "")
                             .replacingOccurrences(of: "_", with: "")

        var matched = false
        for prefix in prefixes {
            if compacted.hasPrefix(prefix) {
                let rest = String(compacted.dropFirst(prefix.count))
                // Rest must start with a digit to be a catalog number
                guard let firstChar = rest.first, firstChar.isNumber else { continue }
                // Strip spaces from number part (handles "18 48" → "1848")
                let cleanNum = stripSuffix(rest)
                // SH2 uses dash convention: "SH2-275"
                if prefix == "SH2" {
                    normalized = "SH2-\(cleanNum)"
                } else {
                    normalized = prefix + cleanNum
                }
                matched = true
                break
            }
        }

        if !matched {
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

    // MARK: - Major/Minor Target (sub-target → parent association)

    /// Returns the parent (major) target for a sub-target, or nil if canonical IS the major target.
    /// Unlike catalogAliases (which overwrites canonical), this preserves the sub-target identity.
    /// "MEL15" → "IC1805" (Melotte 15 is inside Heart Nebula)
    /// Normalizes input through canonicalName() so "IC 1805", "Heart Nebula", etc. all work.
    static func majorTarget(_ raw: String) -> String? {
        let normalized = canonicalName(raw)
        return parentTargetMap[normalized.uppercased()]
    }

    /// Returns all known sub-targets for a given parent target.
    /// "IC1805", "IC 1805", "Heart Nebula" → [("MEL15", "MEL15 (Melotte 15)"), ...]
    /// Normalizes input through canonicalName() for flexible matching.
    static func subTargets(of raw: String) -> [(canonical: String, display: String)] {
        let normalized = canonicalName(raw).uppercased()
        return parentTargetMap
            .filter { $0.value.uppercased() == normalized }
            .map { (canonical: $0.key, display: displayName($0.key)) }
            .sorted { $0.canonical < $1.canonical }
    }

    /// Returns a display name with major > minor formatting when applicable.
    /// "MEL15" with major IC1805 → "Heart Nebula > Melotte 15"
    static func displayNameWithParent(_ canonical: String, majorTarget: String?) -> String {
        if let major = majorTarget {
            let majorDisplay = displayName(major)
            let minorDisplay = displayName(canonical)
            return "\(majorDisplay) > \(minorDisplay)"
        }
        return displayName(canonical)
    }

    /// Maps sub-targets to their parent (major) target.
    /// These are distinct from catalogAliases: the sub-target keeps its own canonical name,
    /// but is associated with the parent for grouping/statistics purposes.
    /// Comprehensive list for amateur astrophotography — helps beginners understand
    /// that the specific object they aimed at is part of a larger well-known complex.
    private static let parentTargetMap: [String: String] = [

        // ═══════════════════════════════════════════════════════════
        // ORION MOLECULAR CLOUD COMPLEX (parent: M42)
        // ═══════════════════════════════════════════════════════════
        "M43": "M42",               // De Mairan's Nebula — attached to Great Orion Nebula
        "NGC1977": "M42",           // Running Man Nebula — reflection nebula north of M42
        "NGC1980": "M42",           // Iota Orionis association — below M42
        "NGC1981": "M42",           // Open cluster above Running Man
        "NGC1999": "M42",           // Reflection nebula south of M42 (T Tauri region)
        "NGC2024": "M42",           // Flame Nebula — near Alnitak, Orion belt region
        "IC434": "M42",             // Horsehead Nebula — near Alnitak, Orion belt region
        "M78": "M42",              // Reflection nebula — north of Orion belt
        "NGC2071": "M42",           // Reflection nebula near M78
        "SH2-276": "M42",           // Barnard's Loop — giant arc around entire Orion complex

        // ═══════════════════════════════════════════════════════════
        // HEART & SOUL NEBULAE (parent: IC1805)
        // ═══════════════════════════════════════════════════════════
        "MEL15": "IC1805",          // Melotte 15 — central star cluster of Heart Nebula
        "NGC1027": "IC1805",        // Open cluster in Heart region
        "NGC896": "IC1805",         // Bright extension of Heart Nebula (sometimes shot separately)
        "IC1795": "IC1805",         // Fish Head Nebula — NW extension of Heart
        "IC1848": "IC1805",         // Soul Nebula — paired with Heart (Heart & Soul complex)

        // ═══════════════════════════════════════════════════════════
        // NORTH AMERICA / PELICAN COMPLEX (parent: NGC7000)
        // ═══════════════════════════════════════════════════════════
        "IC5070": "NGC7000",        // Pelican Nebula — separated from NA by dark lane
        // IC5067 omitted — catalogAlias redirects IC5067→IC5070, then IC5070→NGC7000 via this map
        "CYGNUSWALL": "NGC7000",    // Cygnus Wall — sub-region of North America Nebula
        // "Cygnus Wall" is a sub-region of NGC7000 itself (no separate catalog entry)

        // ═══════════════════════════════════════════════════════════
        // VEIL NEBULA / CYGNUS LOOP (parent: NGC6960)
        // ═══════════════════════════════════════════════════════════
        "NGC6992": "NGC6960",       // Eastern Veil (Network Nebula)
        "NGC6995": "NGC6960",       // Eastern Veil extension
        "NGC6979": "NGC6960",       // Pickering's Triangle — faint filament
        "IC1340": "NGC6960",        // Southern extension of Eastern Veil
        "PICKERINGSTRIANGLE": "NGC6960", // Pickering's Triangle — faint filament in Veil complex

        // ═══════════════════════════════════════════════════════════
        // ROSETTE NEBULA (parent: NGC2237)
        // ═══════════════════════════════════════════════════════════
        "NGC2244": "NGC2237",       // Rosette Cluster — central open cluster
        "NGC2246": "NGC2237",       // Part of Rosette Nebula

        // ═══════════════════════════════════════════════════════════
        // CARINA NEBULA COMPLEX (parent: NGC3372)
        // ═══════════════════════════════════════════════════════════
        "NGC3324": "NGC3372",       // Gabriela Mistral Nebula — NW of Carina
        "NGC3293": "NGC3372",       // Open cluster in Carina region
        "IC2599": "NGC3372",        // Nebulosity around Carina
        "NGC3532": "NGC3372",       // Wishing Well Cluster — near Carina
        "TR14": "NGC3372",          // Trumpler 14 — young cluster in Carina
        "TR16": "NGC3372",          // Trumpler 16 — contains Eta Carinae star

        // ═══════════════════════════════════════════════════════════
        // LAGOON / TRIFID REGION (parent: M8)
        // ═══════════════════════════════════════════════════════════
        "NGC6530": "M8",            // Open cluster embedded in Lagoon Nebula
        "M20": "M8",               // Trifid Nebula — nearby, often imaged together
        // NGC6514 omitted — catalogAlias redirects NGC6514→M20, then M20→M8 via parentTargetMap
        "M21": "M8",               // Open cluster near Trifid, same FOV

        // ═══════════════════════════════════════════════════════════
        // EAGLE NEBULA (parent: M16)
        // ═══════════════════════════════════════════════════════════
        "NGC6611": "M16",           // Open cluster in Eagle Nebula
        "IC4703": "M16",            // Nebulosity of Eagle (Pillars of Creation region)

        // ═══════════════════════════════════════════════════════════
        // CYGNUS / SADR REGION (parent: IC1318)
        // ═══════════════════════════════════════════════════════════
        "NGC6888": "IC1318",        // Crescent Nebula — embedded in Sadr/Butterfly region
        "NGC6914": "IC1318",        // Reflection nebula in Cygnus, near Sadr
        // Note: IC1318 (Butterfly/Sadr) is the parent complex here

        // ═══════════════════════════════════════════════════════════
        // IC1396 COMPLEX — Elephant's Trunk (parent: IC1396)
        // ═══════════════════════════════════════════════════════════
        "IC1396A": "IC1396",        // Elephant's Trunk — dark globule, popular long-FL target
        "TR37": "IC1396",           // Trumpler 37 — central cluster of IC1396

        // ═══════════════════════════════════════════════════════════
        // RHO OPHIUCHI CLOUD COMPLEX (parent: RHOOPH — DB uses this canonical ID)
        // ═══════════════════════════════════════════════════════════
        "IC4603": "RHOOPH",         // Blue reflection nebula near Rho Oph
        "IC4604": "RHOOPH",         // Primary reflection nebula (IC4604 = Rho Oph in some catalogs)
        "IC4605": "RHOOPH",         // Reflection nebula near Rho Oph
        "IC4606": "RHOOPH",         // Nebulosity near Antares
        "SH2-9": "RHOOPH",          // Antares nebula — part of Rho Oph complex

        // ═══════════════════════════════════════════════════════════
        // ANDROMEDA GROUP (parent: M31)
        // ═══════════════════════════════════════════════════════════
        "M32": "M31",              // Compact elliptical satellite of Andromeda
        "M110": "M31",             // Dwarf elliptical satellite of Andromeda
        "NGC206": "M31",            // Giant star cloud in M31's spiral arm (long-FL target)

        // ═══════════════════════════════════════════════════════════
        // M81 / M82 GROUP (parent: M81)
        // ═══════════════════════════════════════════════════════════
        "M82": "M81",              // Cigar Galaxy — interacting pair with Bode's
        "NGC3077": "M81",           // Irregular galaxy in M81 group (IFN region)

        // ═══════════════════════════════════════════════════════════
        // LEO TRIPLET (parent: LEOTRIPLET — group entry in DeepSkyTargetDatabase)
        // ═══════════════════════════════════════════════════════════
        "M65": "LEOTRIPLET",       // Leo Triplet — spiral galaxy
        "M66": "LEOTRIPLET",       // Leo Triplet — spiral galaxy
        "NGC3628": "LEOTRIPLET",   // Hamburger Galaxy — Leo Triplet member

        // ═══════════════════════════════════════════════════════════
        // DEER LICK GROUP (parent: NGC7331)
        // ═══════════════════════════════════════════════════════════
        "NGC7335": "NGC7331",       // Deer Lick Group member
        "NGC7336": "NGC7331",       // Deer Lick Group member
        "NGC7337": "NGC7331",       // Deer Lick Group member
        "NGC7340": "NGC7331",       // Deer Lick Group member

        // ═══════════════════════════════════════════════════════════
        // STEPHAN'S QUINTET (parent: STEPHANSQUINTET — group entry)
        // ═══════════════════════════════════════════════════════════
        "NGC7317": "STEPHANSQUINTET", // Stephan's Quintet member
        "NGC7318": "STEPHANSQUINTET", // Stephan's Quintet (A+B pair)
        "NGC7319": "STEPHANSQUINTET", // Stephan's Quintet member
        "NGC7320": "STEPHANSQUINTET", // Stephan's Quintet foreground galaxy

        // ═══════════════════════════════════════════════════════════
        // MARKARIAN'S CHAIN / VIRGO CLUSTER (parent: MARKARIANSCHAIN — group entry)
        // ═══════════════════════════════════════════════════════════
        "M84": "MARKARIANSCHAIN",   // Markarian's Chain — lenticular galaxy
        "M86": "MARKARIANSCHAIN",   // Markarian's Chain — elliptical galaxy
        "NGC4435": "MARKARIANSCHAIN", // The Eyes (pair with NGC4438)
        "NGC4438": "MARKARIANSCHAIN", // The Eyes — interacting pair
        "NGC4461": "MARKARIANSCHAIN", // Part of the chain
        "NGC4473": "MARKARIANSCHAIN", // Chain member
        "NGC4477": "MARKARIANSCHAIN", // Chain member
        // Siamese Twins (nearby in Virgo Cluster)
        "NGC4567": "MARKARIANSCHAIN", // Siamese Twins — butterfly galaxies
        "NGC4568": "MARKARIANSCHAIN", // Siamese Twins — butterfly galaxies

        // ═══════════════════════════════════════════════════════════
        // MONOCEROS / CONE REGION (parent: NGC2264)
        // ═══════════════════════════════════════════════════════════
        // NGC2264 includes: Cone Nebula, Christmas Tree Cluster, Fox Fur Nebula
        // All are part of the same HII region, different sub-regions
        "NGC2261": "NGC2264",       // Hubble's Variable Nebula — nearby in Monoceros

        // ═══════════════════════════════════════════════════════════
        // AURIGA STAR-FORMING REGION (parent: IC405)
        // ═══════════════════════════════════════════════════════════
        "IC410": "IC405",           // Tadpole Nebula — near Flaming Star in Auriga
        "IC417": "IC405",           // Spider Nebula — Auriga cluster region
        "NGC1931": "IC405",         // Small emission nebula near IC405

        // ═══════════════════════════════════════════════════════════
        // SCORPIUS / CAT'S PAW REGION (parent: NGC6334)
        // ═══════════════════════════════════════════════════════════
        "NGC6357": "NGC6334",       // Lobster / War & Peace Nebula — adjacent to Cat's Paw

        // ═══════════════════════════════════════════════════════════
        // LARGE MAGELLANIC CLOUD (parent: LMC — use NGC2070 as parent)
        // ═══════════════════════════════════════════════════════════
        "NGC2014": "NGC2070",       // Emission nebula in LMC near Tarantula
        "NGC2074": "NGC2070",       // Seahorse Nebula — near Tarantula
        "NGC1850": "NGC2070",       // Double cluster in LMC
        "NGC1818": "NGC2070",       // Young cluster in LMC

        // ═══════════════════════════════════════════════════════════
        // PERSEUS MOLECULAR CLOUD (parent: NGC1333)
        // ═══════════════════════════════════════════════════════════
        "IC348": "NGC1333",         // Young cluster in Perseus cloud

        // ═══════════════════════════════════════════════════════════
        // CEPHEUS FLARE / REGION (parent: SH2-155)
        // ═══════════════════════════════════════════════════════════
        "NGC7129": "SH2-155",       // Reflection nebula in Cepheus (near Cave Nebula)
        "NGC7142": "SH2-155",       // Open cluster near Cave Nebula
        "VDB152": "SH2-155",        // Wolf's Cave — dark/reflection nebula in Cepheus

        // ═══════════════════════════════════════════════════════════
        // CASSIOPEIA REGION (parent: NGC869 — Double Cluster)
        // ═══════════════════════════════════════════════════════════
        "NGC884": "NGC869",         // Double Cluster — h Persei paired with Chi Persei

        // ═══════════════════════════════════════════════════════════
        // WHALE / HOCKEY STICK GALAXY PAIR (parent: NGC4631)
        // ═══════════════════════════════════════════════════════════
        "NGC4627": "NGC4631",       // Small companion above Whale Galaxy
        "NGC4656": "NGC4631",       // Hockey Stick Galaxy — interacting neighbor
        "NGC4657": "NGC4631",       // Extension of Hockey Stick

        // ═══════════════════════════════════════════════════════════
        // ANTENNAE GALAXIES (parent: NGC4038)
        // ═══════════════════════════════════════════════════════════
        "NGC4039": "NGC4038",       // Antennae pair — merging galaxies

        // ═══════════════════════════════════════════════════════════
        // FLYING BAT / SQUID (parent: SH2-129)
        // ═══════════════════════════════════════════════════════════
        "OU4": "SH2-129",           // Giant Squid Nebula — inside Flying Bat Nebula

        // ═══════════════════════════════════════════════════════════
        // SPAGHETTI NEBULA (parent: SH2-240)
        // ═══════════════════════════════════════════════════════════
        "SIMEIS147": "SH2-240",     // Simeis 147 = SH2-240 (same object, different catalogs)

        // ═══════════════════════════════════════════════════════════
        // WESTERN GRAZING GALAXIES / NGC891 AREA
        // ═══════════════════════════════════════════════════════════
        "ABELL347": "NGC891",       // Galaxy cluster near Silver Sliver (same FOV wide-field)

        // ═══════════════════════════════════════════════════════════
        // FLAMING STAR / IC405 AREA — ADDITIONAL
        // ═══════════════════════════════════════════════════════════
        "NGC1893": "IC405",         // Open cluster near Spider/Tadpole region

        // ═══════════════════════════════════════════════════════════
        // MISCELLANEOUS PAIRS & GROUPS
        // ═══════════════════════════════════════════════════════════
        // M51 + companion
        "NGC5195": "M51",           // Companion galaxy to Whirlpool

        // NGC253 Sculptor group
        "NGC247": "NGC253",         // Sculptor group member (same wide-field)

        // M87 / Virgo A jet
        "NGC4486": "M87",          // NGC designation for M87 (same object alias coverage)

        // Pleiades sub-nebulae
        "IC349": "M45",             // Barnard's Merope Nebula — reflection in Pleiades
        "VDB23": "M45",             // Merope reflection nebula in Pleiades

        // ═══════════════════════════════════════════════════════════
        // ADDITIONAL COMPLEXES (from comprehensive research)
        // ═══════════════════════════════════════════════════════════

        // Seagull Nebula Complex (parent: IC2177)
        "NGC2327": "IC2177",        // Head of the Seagull
        "NGC2335": "IC2177",        // Open cluster in Seagull
        "SH2-292": "IC2177",        // Sharpless component of Seagull

        // NGC7822 / CED214 merged — CED214 is alias on NGC7822 DB entry

        // NGC6820 / NGC6823 (cluster powers the nebula)
        "NGC6823": "NGC6820",       // Open cluster powering NGC6820 nebulosity

        // Monkey Head region
        "NGC2175": "NGC2174",       // Cluster in Monkey Head Nebula

        // Boogeyman / Orion outskirts
        "LDN1622": "M42",           // Boogeyman Nebula — Orion complex outskirts
        "B33": "IC434",             // Horsehead dark silhouette — on IC434 emission

        // Crescent region
        "WR134": "NGC6888",         // WR 134 Ring Nebula — near Crescent

        // (NGC884, NGC4627, NGC4657 already in main sections above)
    ]

    // MARK: - Display Name (catalog → "M42 (Orion Nebula)")

    /// Returns a display name enriched with the common name if known.
    /// "M42" → "M42 (Orion Nebula)", "NGC7000" → "NGC7000 (North America)"
    static func displayName(_ canonical: String) -> String {
        if let common = catalogToCommonName[canonical.uppercased()] {
            return "\(canonical) (\(common))"
        }
        return canonical
    }

    /// Reverse lookup: catalog ID → common name.
    /// Comprehensive coverage of all popular astrophotography targets.
    private static let catalogToCommonName: [String: String] = [
        // --- Messier objects (all 110) with well-known names ---
        "M1": "Crab Nebula", "M2": "Aquarius Globular", "M3": "Canes Venatici Globular",
        "M4": "Cat's Paw Cluster", "M5": "Serpens Globular", "M6": "Butterfly Cluster",
        "M7": "Ptolemy's Cluster", "M8": "Lagoon Nebula", "M9": "Ophiuchus Globular",
        "M10": "Ophiuchus Globular II", "M11": "Wild Duck Cluster", "M12": "Gumball Globular",
        "M13": "Hercules Cluster", "M14": "Ophiuchus Globular III", "M15": "Pegasus Globular",
        "M16": "Eagle Nebula", "M17": "Omega Nebula", "M18": "Black Swan Cluster",
        "M19": "Ophiuchus Globular IV", "M20": "Trifid Nebula", "M21": "Webb's Cross Cluster",
        "M22": "Sagittarius Cluster", "M23": "Sagittarius Star Cloud Cluster",
        "M24": "Sagittarius Star Cloud", "M25": "IC4725 Cluster",
        "M27": "Dumbbell Nebula", "M28": "Sagittarius Globular",
        "M29": "Cooling Tower Cluster", "M30": "Jellyfish Cluster",
        "M31": "Andromeda Galaxy", "M32": "Andromeda Satellite", "M33": "Triangulum Galaxy",
        "M34": "Perseus Cluster", "M35": "Gemini Cluster",
        "M36": "Pinwheel Cluster", "M37": "January Salt-and-Pepper",
        "M38": "Starfish Cluster", "M39": "Cygnus Cluster",
        "M41": "Little Beehive", "M42": "Orion Nebula", "M43": "De Mairan's Nebula",
        "M44": "Beehive Cluster", "M45": "Pleiades",
        "M46": "Puppis Cluster", "M47": "Puppis Cluster II", "M48": "Hydra Cluster",
        "M49": "Virgo Elliptical", "M50": "Heart-Shaped Cluster",
        "M51": "Whirlpool Galaxy", "M52": "Cassiopeia Salt-and-Pepper",
        "M53": "Coma Berenices Globular", "M54": "Sagittarius Dwarf Globular",
        "M55": "Summer Rose Star", "M56": "Lyra Globular",
        "M57": "Ring Nebula", "M58": "Virgo Spiral",
        "M59": "Virgo Elliptical II", "M60": "Virgo Elliptical III",
        "M61": "Swelling Spiral", "M62": "Flickering Globular",
        "M63": "Sunflower Galaxy", "M64": "Black Eye Galaxy",
        "M65": "Leo Triplet A", "M66": "Leo Triplet B",
        "M67": "King Cobra Cluster", "M68": "Hydra Globular",
        "M69": "Sagittarius Globular II", "M70": "Sagittarius Globular III",
        "M71": "Sagitta Globular", "M72": "Aquarius Globular II",
        "M74": "Phantom Galaxy", "M75": "Sagittarius Globular IV",
        "M76": "Little Dumbbell", "M77": "Cetus A / Squid Galaxy",
        "M78": "Casper the Ghost Nebula", "M79": "Lepus Globular",
        "M80": "Scorpius Globular", "M81": "Bode's Galaxy",
        "M82": "Cigar Galaxy", "M83": "Southern Pinwheel",
        "M84": "Virgo Lenticular", "M85": "Coma Lenticular",
        "M86": "Virgo Elliptical IV", "M87": "Virgo A",
        "M88": "Coma Spiral", "M89": "Virgo Elliptical V",
        "M90": "Virgo Spiral II", "M91": "Barred Spiral",
        "M92": "Hercules Globular II", "M93": "Puppis Open Cluster",
        "M94": "Cat's Eye Galaxy", "M95": "Leo Barred Spiral",
        "M96": "Leo Spiral", "M97": "Owl Nebula",
        "M98": "Coma Spiral II", "M99": "Coma Pinwheel",
        "M100": "Mirror Galaxy", "M101": "Pinwheel Galaxy",
        "M102": "Spindle Galaxy", "M103": "Cassiopeia Cluster",
        "M104": "Sombrero Galaxy", "M105": "Leo Elliptical",
        "M106": "Canes Venatici Spiral", "M107": "Ophiuchus Globular V",
        "M108": "Surfboard Galaxy", "M109": "Vacuum Cleaner Galaxy",
        "M110": "Andromeda Satellite II",

        // --- NGC nebulae (popular astrophotography targets) ---
        "NGC40": "Bow-Tie Nebula", "NGC246": "Skull Nebula",
        "NGC253": "Sculptor Galaxy", "NGC281": "Pacman Nebula",
        "NGC457": "Owl Cluster", "NGC663": "Cassiopeia Cluster",
        "NGC869": "Double Cluster h", "NGC884": "Double Cluster chi",
        "NGC891": "Silver Sliver Galaxy", "NGC896": "Heart Nebula Extension",
        "NGC1333": "Perseus Reflection", "NGC1491": "Fossil Footprint Nebula",
        "NGC1499": "California Nebula", "NGC1502": "Kemble's Cascade Cluster",
        "NGC1514": "Crystal Ball Nebula", "NGC1528": "Perseus Cluster",
        "NGC1535": "Cleopatra's Eye",
        "NGC1788": "Fox Face Nebula", "NGC1893": "Flaming Star Cluster",
        "NGC1931": "Fly Nebula", "NGC1977": "Running Man Nebula",
        "NGC1999": "Keyhole Nebula Orion", "NGC2023": "Horsehead Reflection",
        "NGC2024": "Flame Nebula", "NGC2070": "Tarantula Nebula",
        "NGC2146": "Dusty Hand Galaxy", "NGC2174": "Monkey Head Nebula",
        "NGC2237": "Rosette Nebula", "NGC2244": "Rosette Cluster",
        "NGC2261": "Hubble's Variable Nebula", "NGC2264": "Cone Nebula",
        "NGC2359": "Thor's Helmet", "NGC2392": "Eskimo Nebula",
        "NGC2403": "Camelopardalis Spiral", "NGC2438": "Puppis PN",
        "NGC2440": "Papillon Nebula", "NGC2467": "Skull and Crossbones",
        "NGC2683": "UFO Galaxy", "NGC2736": "Pencil Nebula",
        "NGC2770": "Supernova Factory", "NGC2841": "Tiger's Eye Galaxy",
        "NGC2903": "Barred Spiral Leo", "NGC2976": "M81 Group Dwarf",
        "NGC3079": "Ursa Major Edge-On", "NGC3115": "Spindle Galaxy",
        "NGC3132": "Eight-Burst Nebula", "NGC3184": "Little Pinwheel",
        "NGC3190": "Leo Group", "NGC3242": "Ghost of Jupiter",
        "NGC3293": "Gem Cluster", "NGC3324": "Gabriela Mistral Nebula",
        "NGC3372": "Carina Nebula", "NGC3521": "Bubble Galaxy",
        "NGC3576": "Statue of Liberty Nebula", "NGC3603": "Starburst Cluster",
        "NGC3628": "Hamburger Galaxy", "NGC3718": "Warped Spiral",
        "NGC3953": "Ursa Major Spiral", "NGC4038": "Antennae Galaxies",
        "NGC4039": "Antennae Galaxies B", "NGC4236": "Draco Barred Spiral",
        "NGC4244": "Silver Needle Galaxy", "NGC4258": "M106",
        "NGC4274": "Coma Berenices Spiral", "NGC4388": "Virgo Edge-On",
        "NGC4449": "Box Galaxy", "NGC4490": "Cocoon Galaxy",
        "NGC4565": "Needle Galaxy", "NGC4631": "Whale Galaxy",
        "NGC4656": "Hockey Stick Galaxy", "NGC4725": "One-Armed Spiral",
        "NGC4755": "Jewel Box Cluster", "NGC5005": "Canes Venatici Spiral",
        "NGC5033": "Needle's Eye Galaxy", "NGC5128": "Centaurus A",
        "NGC5139": "Omega Centauri", "NGC5189": "Spiral Planetary",
        "NGC5248": "Boötes Spiral", "NGC5364": "Virgo Grand Spiral",
        "NGC5367": "Reflection Nebula",
        "NGC5426": "Interacting Pair", "NGC5427": "Interacting Pair B",
        "NGC5529": "Edge-On Spiral", "NGC5566": "Virgo Group",
        "NGC5746": "Virgo Edge-On II", "NGC5866": "Spindle Galaxy",
        "NGC5907": "Splinter Galaxy", "NGC6188": "Fighting Dragons",
        "NGC6210": "Turtle Nebula", "NGC6302": "Bug Nebula",
        "NGC6334": "Cat's Paw Nebula", "NGC6357": "Lobster Nebula",
        "NGC6369": "Little Ghost Nebula", "NGC6397": "Ara Globular",
        "NGC6441": "Scorpius Globular", "NGC6514": "Trifid Nebula",
        "NGC6523": "Lagoon Nebula", "NGC6543": "Cat's Eye Nebula",
        "NGC6559": "Lagoon Region", "NGC6572": "Emerald Eye Nebula",
        "NGC6611": "Eagle Nebula Cluster", "NGC6618": "Omega Nebula",
        "NGC6633": "Tweedledee Cluster", "NGC6720": "Ring Nebula",
        "NGC6741": "Phantom Streak Nebula", "NGC6751": "Glowing Eye Nebula",
        "NGC6781": "Snowglobe Nebula", "NGC6804": "Little Ring",
        "NGC6818": "Little Gem Nebula", "NGC6819": "Foxhead Cluster",
        "NGC6820": "Fox Fur Nebula Region",
        "NGC6826": "Blinking Planetary", "NGC6853": "Dumbbell Nebula",
        "NGC6888": "Crescent Nebula", "NGC6914": "Reflection in Cygnus",
        "NGC6934": "Delphinus Globular", "NGC6939": "Cepheus Cluster",
        "NGC6940": "Vulpecula Cluster", "NGC6946": "Fireworks Galaxy",
        "NGC6960": "Western Veil", "NGC6979": "Pickering's Triangle",
        "NGC6992": "Eastern Veil", "NGC6995": "Network Nebula",
        "NGC7000": "North America Nebula", "NGC7009": "Saturn Nebula",
        "NGC7023": "Iris Nebula", "NGC7027": "Jewel Bug Nebula",
        "NGC7048": "Cygnus Planetary", "NGC7129": "Rosebud Nebula",
        "NGC7139": "Cepheus Planetary",
        "NGC7160": "Cepheus Cluster", "NGC7209": "Lacerta Cluster",
        "NGC7235": "Cepheus Cluster II", "NGC7243": "Lacerta Cluster II",
        "NGC7293": "Helix Nebula", "NGC7331": "Deer Lick Galaxy",
        "NGC7332": "Pegasus Lenticular", "NGC7380": "Wizard Nebula",
        "NGC7479": "Superman Galaxy", "NGC7510": "Cepheus Open Cluster",
        "NGC7538": "Northern Lagoon", "NGC7635": "Bubble Nebula",
        "NGC7662": "Blue Snowball", "NGC7741": "Pegasus Barred Spiral",
        "NGC7789": "Caroline's Rose", "NGC7822": "Cepheus Star Forming",

        // --- IC objects ---
        "IC59": "Gamma Cas Nebula A", "IC63": "Ghost of Cassiopeia",
        "IC342": "Hidden Galaxy", "IC405": "Flaming Star Nebula",
        "IC410": "Tadpole Nebula", "IC417": "Spider Nebula",
        "IC418": "Spirograph Nebula", "IC434": "Horsehead Nebula",
        "IC443": "Jellyfish Nebula", "IC1275": "Lagoon Dark Nebula",
        "IC1283": "Lagoon Nebula Region",
        "IC1284": "Sagittarius Reflection", "IC1295": "Cygnus Planetary",
        "IC1318": "Butterfly Nebula (Sadr)", "IC1340": "Bat Nebula",
        "IC1396": "Elephant's Trunk Nebula", "IC1470": "Cepheus Nebula",
        "IC1613": "Cetus Dwarf", "IC1795": "Fish Head Nebula",
        "IC1805": "Heart Nebula", "IC1848": "Soul Nebula",
        "IC2118": "Witch Head Nebula", "IC2177": "Seagull Nebula",
        "IC2574": "Coddington's Nebula",
        "IC4592": "Blue Horsehead Nebula", "IC4603": "Rho Oph Reflection",
        "IC4604": "Rho Ophiuchi", "IC4628": "Prawn Nebula",
        "IC4665": "Summer Beehive", "IC4703": "Eagle Nebula",
        "IC4756": "Graff's Cluster",
        "IC5067": "Pelican Nebula Spine", "IC5070": "Pelican Nebula",
        "IC5146": "Cocoon Nebula",

        // --- Sharpless HII regions ---
        "SH2-9": "Antares Nebula", "SH2-27": "Zeta Oph Nebula",
        "SH2-46": "Westerhout 40", "SH2-54": "Serpens Nebula",
        "SH2-71": "Aquila Planetary", "SH2-86": "Vulpecula Nebula",
        "SH2-101": "Tulip Nebula", "SH2-106": "Cygnus Bipolar",
        "SH2-112": "Cygnus HII", "SH2-119": "Clamshell Nebula",
        "SH2-129": "Flying Bat Nebula", "SH2-131": "Cepheus Nebula",
        "SH2-132": "Lion Nebula", "SH2-140": "Cepheus Bubble",
        "SH2-155": "Cave Nebula", "SH2-157": "Lobster Claw Nebula",
        "SH2-162": "Bubble Nebula Region", "SH2-170": "Little Rosette",
        "SH2-171": "Cassiopeia Nebula", "SH2-174": "Valentine Nebula",
        "SH2-188": "Dolphin Head Nebula", "SH2-199": "Soul Nebula Region",
        "SH2-223": "Supernova Remnant",
        "SH2-224": "Supernova Remnant II",
        "SH2-232": "Auriga Nebula", "SH2-235": "Auriga Star Forming",
        "SH2-236": "IC410 Region", "SH2-240": "Simeis 147",
        "SH2-245": "Spaghetti Nebula",
        "SH2-261": "Lowers Nebula", "SH2-264": "Lambda Orionis Ring",
        "SH2-274": "Medusa Nebula", "SH2-275": "Rosette Nebula Region",
        "SH2-276": "Barnard's Loop",
        "SH2-278": "Gem Nebula", "SH2-308": "Dolphin Nebula",
        "SH2-311": "Puppis Nebula",

        // --- Barnard dark nebulae ---
        "B33": "Horsehead Dark Nebula", "B68": "Dark Molecular Cloud",
        "B72": "Snake Nebula", "B86": "Ink Spot Nebula",
        "B92": "Small Sagittarius Star Cloud Dark", "B142": "Barnard's E",
        "B143": "Barnard's E Extension", "B150": "Seahorse Nebula",
        "B168": "Cygnus Dark Nebula", "B352": "Ophiuchus Dark Cloud",

        // --- LDN dark nebulae ---
        "LDN673": "Dark Nebula in Aquila", "LDN1235": "Dark Shark Nebula",
        "LDN1251": "Cepheus Dark Cloud", "LDN1470": "Perseus Dark Nebula",
        "LDN1495": "Taurus Dark Cloud", "LDN1622": "Boogeyman Nebula",
        "LDN1641": "Orion Dark Cloud", "LDN1780": "Lupus Dark Cloud",

        // --- vdB reflection nebulae ---
        "VDB1": "Cassiopeia Reflection", "VDB13": "Iris Nebula Extension",
        "VDB14": "Camelopardalis Reflection", "VDB15": "Camelopardalis Reflection II",
        "VDB31": "Auriga Reflection", "VDB38": "IC405 Reflection",
        "VDB93": "Gem OB1 Reflection", "VDB105": "Monoceros Reflection",
        "VDB126": "Vulpecula Reflection", "VDB141": "Ghost Nebula",
        "VDB142": "Cepheus Reflection", "VDB152": "Wolf's Cave",

        // --- Abell planetary nebulae ---
        "ABELL6": "Perseus Planetary", "ABELL12": "Hidden Planetary",
        "ABELL21": "Medusa Nebula", "ABELL31": "Headphone Nebula",
        "ABELL33": "Diamond Ring Nebula", "ABELL39": "Hercules Planetary",
        "ABELL61": "Cygnus Planetary", "ABELL71": "Cygnus Shell",
        "ABELL72": "Delphinus Planetary", "ABELL85": "Cassiopeia Planetary",

        // --- Abell galaxy clusters ---
        "ABELL426": "Perseus Galaxy Cluster", "ABELL1656": "Coma Cluster",
        "ABELL2065": "Corona Borealis Cluster", "ABELL2151": "Hercules Galaxy Cluster",
        "ABELL2199": "Ophiuchus Galaxy Cluster",

        // --- Named regions / asterisms ---
        "CED214": "Cepheus Nebula Region",
        "SIMEIS147": "Spaghetti Nebula", "CTB1": "Abell 85",
        "WR134": "Wolf-Rayet Ring", "WR136": "Crescent Nebula WR",
        "G65.3+5.7": "Cygnus Supernova Remnant",
        "OUPERC": "Squid Nebula", "OU4": "Giant Squid Nebula",
    ]

    // MARK: - Common Name Aliases

    /// Maps common/popular names to their catalog designations.
    /// Keys are lowercased for case-insensitive lookup.
    private static let commonNameAliases: [String: String] = [
        // --- Messier objects by popular name ---
        "orion nebula": "M42", "great orion nebula": "M42", "m42 nebula": "M42",
        "de mairans nebula": "M43",
        "crab nebula": "M1", "crab": "M1",
        "ring nebula": "M57",
        "dumbbell nebula": "M27", "dumbbell": "M27",
        "whirlpool galaxy": "M51", "whirlpool": "M51",
        "pinwheel galaxy": "M101", "pinwheel": "M101",
        "andromeda galaxy": "M31", "andromeda": "M31",
        "triangulum galaxy": "M33", "triangulum": "M33",
        "sombrero galaxy": "M104", "sombrero": "M104",
        "bodes galaxy": "M81", "bode galaxy": "M81",
        "cigar galaxy": "M82",
        "owl nebula": "M97",
        "eagle nebula": "M16", "pillars of creation": "M16",
        "omega nebula": "M17", "swan nebula": "M17", "horseshoe nebula": "M17",
        "lagoon nebula": "M8", "lagoon": "M8",
        "trifid nebula": "M20", "trifid": "M20",
        "pleiades": "M45", "seven sisters": "M45", "subaru": "M45",
        "hercules cluster": "M13", "great hercules cluster": "M13",
        "wild duck cluster": "M11", "wild duck": "M11",
        "sunflower galaxy": "M63", "sunflower": "M63",
        "black eye galaxy": "M64", "evil eye galaxy": "M64",
        "coma pinwheel": "M99",
        "phantom galaxy": "M74",
        "little dumbbell": "M76", "little dumbbell nebula": "M76",
        "casper nebula": "M78", "casper the ghost nebula": "M78",
        "southern pinwheel": "M83",
        "virgo a": "M87",
        "cats eye galaxy": "M94",
        "surfboard galaxy": "M108",
        "vacuum cleaner galaxy": "M109",
        "beehive cluster": "M44", "praesepe": "M44",
        "butterfly cluster": "M6",
        "ptolemys cluster": "M7",
        "double cluster": "NGC869",

        // --- NGC nebulae by popular name ---
        "north america nebula": "NGC7000", "north america": "NGC7000",
        "california nebula": "NGC1499", "california": "NGC1499",
        "flame nebula": "NGC2024", "flame": "NGC2024",
        "rosette nebula": "NGC2237", "rosette": "NGC2237",
        "cone nebula": "NGC2264", "christmas tree cluster": "NGC2264", "fox fur nebula": "NGC2264",
        "monkey head nebula": "NGC2174", "monkey head": "NGC2174",
        "thors helmet": "NGC2359", "thor's helmet": "NGC2359",
        "eskimo nebula": "NGC2392", "clown face nebula": "NGC2392",
        "cats eye nebula": "NGC6543", "cats eye": "NGC6543",
        "blinking nebula": "NGC6826", "blinking planetary": "NGC6826",
        "crescent nebula": "NGC6888", "crescent": "NGC6888",
        "veil nebula": "NGC6960", "western veil": "NGC6960",
        "eastern veil": "NGC6992", "network nebula": "NGC6995",
        "witchs broom": "NGC6960", "witchs broom nebula": "NGC6960",
        "pickerings triangle": "NGC6979",
        "cygnus loop": "NGC6960",
        "iris nebula": "NGC7023", "iris": "NGC7023",
        "helix nebula": "NGC7293", "helix": "NGC7293", "eye of god": "NGC7293",
        "wizard nebula": "NGC7380", "wizard": "NGC7380",
        "bubble nebula": "NGC7635", "bubble": "NGC7635",
        "blue snowball nebula": "NGC7662", "blue snowball": "NGC7662",
        "pacman nebula": "NGC281", "pacman": "NGC281", "pac-man nebula": "NGC281",
        "skull nebula": "NGC246",
        "running man nebula": "NGC1977", "running man": "NGC1977",
        "hubbles variable nebula": "NGC2261",
        "carolines rose": "NGC7789",
        "deer lick galaxy": "NGC7331", "deer lick group": "NGC7331",
        "saturn nebula": "NGC7009",
        "rosebud nebula": "NGC7129",
        "ghost of jupiter": "NGC3242",
        "pencil nebula": "NGC2736",
        "bow tie nebula": "NGC40", "bow-tie nebula": "NGC40",
        "little gem nebula": "NGC6818",
        "fox fur nebula region": "NGC6820",

        // --- NGC galaxies by popular name ---
        "needle galaxy": "NGC4565",
        "fireworks galaxy": "NGC6946",
        "leo triplet": "NGC3628", "hamburger galaxy": "NGC3628",
        "whale galaxy": "NGC4631",
        "hockey stick galaxy": "NGC4656",
        "silver sliver galaxy": "NGC891",
        "sculptor galaxy": "NGC253", "silver dollar galaxy": "NGC253",
        "antennae galaxies": "NGC4038", "antennae": "NGC4038",
        "centaurus a": "NGC5128",
        "splinter galaxy": "NGC5907",
        "superman galaxy": "NGC7479",
        "hidden galaxy": "IC342",
        "ufo galaxy": "NGC2683",
        "box galaxy": "NGC4449",
        "cocoon galaxy": "NGC4490",
        "one armed spiral": "NGC4725",
        "markarians chain": "NGC4477", "markarian chain": "NGC4477",

        // --- IC objects by popular name ---
        "horsehead nebula": "IC434", "horsehead": "IC434",
        "heart nebula": "IC1805", "heart": "IC1805",
        "soul nebula": "IC1848", "soul": "IC1848", "embryo nebula": "IC1848",
        "jellyfish nebula": "IC443", "jellyfish": "IC443",
        "flaming star nebula": "IC405", "flaming star": "IC405",
        "tadpole nebula": "IC410", "tadpoles": "IC410",
        "spider nebula": "IC417", "spider": "IC417",
        "elephants trunk nebula": "IC1396", "elephant trunk nebula": "IC1396",
        "elephanttrunk nebula": "IC1396", "elephanttrunknebula": "IC1396",
        "elephants trunk": "IC1396", "elephant trunk": "IC1396",
        "pelican nebula": "IC5070", "pelican": "IC5070",
        "cocoon nebula": "IC5146", "cocoon": "IC5146",
        "butterfly nebula": "IC1318", "sadr region": "IC1318",
        "ghost of cassiopeia": "IC63", "gamma cas nebula": "IC63",
        "seagull nebula": "IC2177", "seagull": "IC2177",
        "witch head nebula": "IC2118", "witch head": "IC2118",
        "fish head nebula": "IC1795", "fishhead nebula": "IC1795",
        "spirograph nebula": "IC418",
        "prawn nebula": "IC4628",
        "blue horsehead nebula": "IC4592", "blue horsehead": "IC4592",
        "rho ophiuchi": "IC4604", "rho oph": "IC4604", "rho oph cloud": "IC4604",

        // --- Sharpless HII regions by popular name ---
        "tulip nebula": "SH2-101", "tulip": "SH2-101",
        "lion nebula": "SH2-132", "lions nebula": "SH2-132",
        "cave nebula": "SH2-155", "cave": "SH2-155",
        "medusa nebula": "SH2-274", "medusa": "SH2-274",
        "flying bat nebula": "SH2-129", "flying bat": "SH2-129", "bat nebula": "SH2-129",
        "lobster claw nebula": "SH2-157", "lobster claw": "SH2-157",
        "dolphin head nebula": "SH2-188", "dolphin head": "SH2-188",
        "valentine nebula": "SH2-174",
        "clamshell nebula": "SH2-119",
        "little rosette": "SH2-170",
        "dolphin nebula": "SH2-308",
        "spaghetti nebula": "SH2-240", "simeis 147": "SH2-240",

        // --- Barnard dark nebulae ---
        "barnards loop": "SH2-276",
        "snake nebula": "B72",
        "ink spot nebula": "B86",
        "barnards e": "B142",
        "seahorse nebula": "B150",
        "dark shark nebula": "LDN1235", "dark shark": "LDN1235",
        "boogeyman nebula": "LDN1622", "boogeyman": "LDN1622",

        // --- Other named objects ---
        "ghost nebula": "VDB141",
        "wolfs cave": "VDB152",
        "squid nebula": "OU4", "giant squid nebula": "OU4", "giant squid": "OU4",
        "tarantula nebula": "NGC2070", "tarantula": "NGC2070",
        "carina nebula": "NGC3372", "eta carinae": "NGC3372", "eta carina nebula": "NGC3372",
        "omega centauri": "NGC5139",
        "jewel box cluster": "NGC4755", "jewel box": "NGC4755",
        "cats paw nebula": "NGC6334", "cats paw": "NGC6334",
        "lobster nebula": "NGC6357",
        "bug nebula": "NGC6302", "butterfly planetary": "NGC6302",
        "statue of liberty nebula": "NGC3576",
        "gabriela mistral nebula": "NGC3324",
        "eight burst nebula": "NGC3132", "southern ring nebula": "NGC3132",

        // --- Catalog prefix-less entries ---
        "ngc7000": "NGC7000", "ngc 7000": "NGC7000",
        "ic63 ghost": "IC63", "ic 63 ghost": "IC63",
        "ic1318 butterfly": "IC1318", "ic 1318 butterfly": "IC1318",
        "ngc 7635 bubble": "NGC7635", "ngc7635 bubble": "NGC7635",
        "sh2 275": "SH2-275",

        // --- Non-astro / special ---
        "flatwizard": "FLATWIZARD", "flat wizard": "FLATWIZARD",
        "12p": "12P",
    ]

    /// Maps normalized catalog IDs to their primary designation (deduplication).
    /// NGC → Messier when both exist; sub-regions → parent object.
    private static let catalogAliases: [String: String] = [
        // Rosette complex — unify to nebula
        "NGC2244": "NGC2237", "NGC2246": "NGC2237", "SH2-275": "NGC2237",
        // Veil Nebula complex — unify to Western Veil
        "NGC6992": "NGC6960", "NGC6995": "NGC6960", "NGC6979": "NGC6960",
        "IC1340": "NGC6960",
        // Sub-regions → parent
        "IC1396A": "IC1396",    // Elephant's Trunk → IC1396
        "IC5067": "IC5070",     // Pelican Nebula spine → Pelican
        "NGC896": "IC1805",     // Heart extension → Heart
        // IC1795 (Fish Head) kept as standalone — linked via parentTargetMap, not alias
        // NGC → Messier cross-references
        "NGC1952": "M1",   "NGC1976": "M42",  "NGC1982": "M43",
        "NGC224":  "M31",  "NGC221":  "M32",  "NGC598":  "M33",
        "NGC1039": "M34",  "NGC2168": "M35",  "NGC1960": "M36",
        "NGC2099": "M37",  "NGC1912": "M38",  "NGC7092": "M39",
        "NGC2287": "M41",  "NGC2632": "M44",
        "NGC1904": "M79",  "NGC2323": "M50",
        "NGC5194": "M51",  "NGC7654": "M52",
        "NGC5024": "M53",  "NGC6715": "M54",  "NGC6809": "M55",
        "NGC6779": "M56",  "NGC6720": "M57",
        "NGC4579": "M58",  "NGC4621": "M59",  "NGC4649": "M60",
        "NGC4303": "M61",  "NGC6266": "M62",
        "NGC5055": "M63",  "NGC4826": "M64",
        "NGC3623": "M65",  "NGC3627": "M66",
        "NGC2682": "M67",  "NGC4590": "M68",
        "NGC6637": "M69",  "NGC6681": "M70",  "NGC6838": "M71",
        "NGC6981": "M72",  "NGC628":  "M74",  "NGC6864": "M75",
        "NGC650":  "M76",  "NGC1068": "M77",  "NGC2068": "M78",
        "NGC6093": "M80",
        "NGC3031": "M81",  "NGC3034": "M82",  "NGC5236": "M83",
        "NGC4374": "M84",  "NGC4382": "M85",  "NGC4406": "M86",
        "NGC4486": "M87",  "NGC4501": "M88",  "NGC4552": "M89",
        "NGC4569": "M90",  "NGC4548": "M91",  "NGC6341": "M92",
        "NGC2447": "M93",  "NGC4736": "M94",  "NGC3351": "M95",
        "NGC3368": "M96",  "NGC3587": "M97",
        "NGC4192": "M98",  "NGC4254": "M99",  "NGC4321": "M100",
        "NGC5457": "M101", "NGC5866": "M102", "NGC581":  "M103",
        "NGC4594": "M104", "NGC3379": "M105", "NGC4258": "M106",
        "NGC6171": "M107", "NGC3556": "M108", "NGC3992": "M109",
        "NGC205":  "M110",
        // Eagle Nebula
        "NGC6611": "M16",  "IC4703": "M16",
        // Omega / Swan Nebula
        "NGC6618": "M17",
        // Lagoon Nebula
        "NGC6523": "M8",   "NGC6530": "M8",
        // Trifid Nebula
        "NGC6514": "M20",
        // Dumbbell Nebula
        "NGC6853": "M27",
        // Spaghetti Nebula
        "SIMEIS147": "SH2-240", "SH2-245": "SH2-240",
        // Medusa: ABELL21 is the canonical entry (SH2-274 added as alias on DB entry)
    ]
}

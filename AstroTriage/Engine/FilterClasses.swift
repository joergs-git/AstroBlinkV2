// FilterClasses.swift
// ONE home for "what kind of filter is this name". Used by the scoring engine (trailing
// multiplier), by the session overview and the Frame History charts (display classes), by
// Color Combine (channel aliases) and by the navigation fallback (same filter class).
//
// It lives in the AstroScoreCLI source closure so the headless rig classifies exactly like the
// app: until 6.11.1 the CLI stub of ColorCombineEngine mapped names to THEMSELVES, so the rig
// scored an "H" frame as an unknown filter (trailing × 0.7) while the app scored it as Ha
// (× 0.3) — the third rig/app parity bug. GUI-free on purpose; keep it that way.

import Foundation

enum FilterClasses {

    // MARK: - Canonical channel names

    /// Common filter-name variants → canonical channel (Ha, OIII, SII, Hbeta, NII, L, R, G, B).
    /// NINA, SGP, Voyager and ASIAIR all spell them differently.
    private static let aliases: [String: String] = [
        // Ha (hydrogen-alpha)
        "h": "Ha", "ha": "Ha", "h-alpha": "Ha", "halpha": "Ha", "hα": "Ha", "h_alpha": "Ha",
        "ha_7nm": "Ha", "ha_3nm": "Ha", "ha_12nm": "Ha",
        "hii": "Ha", "h2": "Ha",
        // OIII (oxygen-III)
        "o": "OIII", "o3": "OIII", "oiii": "OIII",
        "oiii_7nm": "OIII", "oiii_3nm": "OIII", "oiii_12nm": "OIII",
        "o_iii": "OIII", "o-iii": "OIII",
        // SII (sulfur-II)
        "s": "SII", "s2": "SII", "sii": "SII",
        "sii_7nm": "SII", "sii_3nm": "SII", "sii_12nm": "SII",
        "s_ii": "SII", "s-ii": "SII",
        // Hbeta
        "hbeta": "Hbeta", "hb": "Hbeta", "h-beta": "Hbeta",
        // NII
        "nii": "NII", "n2": "NII", "n_ii": "NII",
        // Broadband
        "l": "L", "lum": "L", "luminance": "L", "clear": "L", "lumi": "L",
        "r": "R", "red": "R",
        "g": "G", "green": "G",
        "b": "B", "blue": "B",
    ]

    /// Canonical channel name for `raw`. A trailing bandwidth ("OIII 7nm", "Ha_3nm") is stripped
    /// before the lookup; unknown names pass through trimmed (an L-eXtreme stays "Extr").
    static func canonicalName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let key = trimmed.lowercased()

        // Direct match
        if let canonical = aliases[key] { return canonical }

        // Try stripping trailing bandwidth (e.g., "OIII 7nm" → "oiii", "Ha_3nm" → "ha")
        let stripped = key
            .replacingOccurrences(of: #"\s*\d+\s*nm$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"_\d+nm$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let canonical = aliases[stripped] { return canonical }

        // Fallback: return original trimmed name
        return trimmed
    }

    // MARK: - Band classes

    /// The classic single-line narrowband channels.
    static let narrowbandCanonical: Set<String> = ["Ha", "OIII", "SII", "Hbeta", "NII"]

    /// Dual- and multi-band display class for a raw or canonical name, nil for anything else:
    /// "Lextr" (Optolong L-eXtreme, 7 nm Ha + OIII), "Lenh" (L-eNhance, 10/24 nm), "Lult"
    /// (L-Ultimate, 3 nm), "Duo" (other Ha + OIII combinations: Antlia ALP-T, IDAS NBZ, …),
    /// "Quad" (L-Quad and other four-line filters). The brand families stay distinct because
    /// their bandwidths differ by 3× — they are not interchangeable in a quality comparison.
    static func dualBandClass(_ name: String) -> String? {
        let key = compact(name)
        if ["LEXTR", "LEXT", "LEXTREME", "EXTR", "EXTREME"].contains(key) { return "Lextr" }
        if ["LENH", "LENHANCE", "LE", "ENH", "ENHANCE"].contains(key) { return "Lenh" }
        if ["LULT", "LULTIMATE", "ULTIMATE"].contains(key) { return "Lult" }
        if ["DUO", "DUOBAND", "DUALBAND", "DUAL", "DUONB", "ALPT", "NBZ", "NBZII"].contains(key) { return "Duo" }
        if key.contains("QUAD") || key == "LQUA" { return "Quad" }
        return nil
    }

    /// True for every filter that passes only emission lines: the classic narrowband channels
    /// and the dual-/multi-band filters that combine two or four of them. Scoring treats them
    /// alike since algorithm v42 — an L-eXtreme frame is a nebula frame with Ha + OIII stars,
    /// not an "unknown" filter.
    static func isNarrowbandLike(_ name: String) -> Bool {
        narrowbandCanonical.contains(canonicalName(name)) || dualBandClass(name) != nil
    }

    /// Uppercased with separators removed: "L-eXtreme" → "LEXTREME", "l_ext" → "LEXT".
    static func compact(_ name: String) -> String {
        name.uppercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

// FieldGrouping.swift
// Groups frames by the patch of sky they point at, from plate-solve / header coordinates and the
// field of view. Feeds the LightspeedStacker gate ("can these frames be aligned?") and the "Field"
// column in the file list. GUI-free and pure — no view model, no file access — so it is
// unit-testable with hand-built ImageEntry values. Introduced in 6.10.0.
//
// Why the field of view and not a fixed angle: the old gate allowed 1° regardless of optics.
// That is 35% of an 85 mm / APS-C field (2.88° wide — two pointings 1.2° apart still overlap by
// 60% and stack fine, yet were refused) and MORE than the whole field of an RC12 (0.85° wide —
// two frames 0.9° apart share nothing, yet passed). The physical question is "do the frames
// overlap enough for the star matcher", and that scales with the field.

import Foundation

/// One group of frames pointing at (roughly) the same patch of sky. Index 1 is the field with
/// the most frames; the others follow by frame count.
struct FieldSummary: Equatable {
    let index: Int
    let frameCount: Int
    let centerRA: Double            // degrees
    let centerDec: Double           // degrees
    let separationFromFirst: Double // degrees from field 1's center (0 for field 1)
    let targetNames: [String]       // distinct OBJECT names in this field, sorted

    /// "23h16m +60°04'" — compact sexagesimal center for tooltips and alerts.
    var centerText: String { FieldGrouping.formatCenter(ra: centerRA, dec: centerDec) }
}

/// What the stacking gate found out about a selection.
struct StackFieldCheck {
    let fields: [FieldSummary]
    /// Field index per checked entry (nil = the entry has no coordinates).
    let assignments: [Int?]
    let toleranceDegrees: Double
    let fieldSize: (width: Double, height: Double)?
    /// Distinct object names when NO entry carries coordinates — the name-only fallback.
    let namesWithoutCoordinates: [String]
    /// Index (into the checked entries) of the frame nearest field 1's center: the best
    /// reference when the user stacks a mixed selection anyway.
    let leadingEntryIndex: Int?

    /// True when nothing speaks against stacking the whole selection as one field.
    var isSingleField: Bool { fields.count <= 1 && namesWithoutCoordinates.count <= 1 }

    var uncheckedCount: Int { assignments.filter { $0 == nil }.count }

    var alertTitle: String {
        fields.count > 1 ? "Frames Point to Different Sky Fields" : "Mixed Object Names"
    }

    /// The text of the "Stack Anyway" alert. Says WHICH fields, how far apart, and what the
    /// tolerance was — the pre-6.10.0 message blamed the object names for a coordinate mismatch.
    var alertMessage: String {
        if fields.count > 1 {
            var lines = ["The selected frames point to \(fields.count) different sky fields:", ""]
            for field in fields {
                var line = "Field \(field.index): \(field.frameCount) frame\(field.frameCount == 1 ? "" : "s")"
                if !field.targetNames.isEmpty {
                    line += " · " + field.targetNames.joined(separator: ", ")
                }
                line += " · " + field.centerText
                if field.index > 1 {
                    line += String(format: " · %.1f° from field 1", field.separationFromFirst)
                }
                lines.append(line)
            }
            if uncheckedCount > 0 && uncheckedCount < assignments.count {
                lines.append("\(uncheckedCount) frame\(uncheckedCount == 1 ? "" : "s") without coordinates not checked")
            }
            lines.append("")
            if let size = fieldSize {
                lines.append(String(format: "Field of view %.2f° × %.2f°: frames up to %.2f° apart still overlap enough to align.",
                                    size.width, size.height, toleranceDegrees))
            } else {
                lines.append(String(format: "Field of view unknown (no focal length / pixel size in the headers): frames up to %.1f° apart count as one field.",
                                    toleranceDegrees))
            }
            lines.append("“Stack Anyway” aligns whatever overlaps field 1 and skips the rest.")
            return lines.joined(separator: "\n")
        }
        let names = namesWithoutCoordinates.joined(separator: ", ")
        return "The selected frames carry \(namesWithoutCoordinates.count) different object names (\(names)) "
            + "and no coordinates to check whether the fields overlap.\n\n"
            + "“Stack Anyway” aligns whatever overlaps the first frame and skips the rest."
    }
}

enum FieldGrouping {
    /// Two frames may be offset by this fraction of the larger field edge and still count as the
    /// same field: 0.6 leaves at least 40% overlap along that axis for the star matcher.
    static let overlapOffsetFraction = 0.6
    /// Used when the field of view is unknown (no FOCALLEN / XPIXSZ): the pre-6.10.0 fixed limit.
    static let fallbackToleranceDegrees = 1.0

    // MARK: - Coordinates

    /// "HH MM SS.ss", "HH:MM:SS" or decimal degrees → degrees.
    static func parseRA(_ ra: String) -> Double? {
        let parts = sexagesimalParts(ra)
        if parts.count >= 3 {
            // HH MM SS → degrees (15° per hour)
            return (parts[0] + parts[1] / 60.0 + parts[2] / 3600.0) * 15.0
        }
        if parts.count == 1 { return parts[0] }
        return nil
    }

    /// "+DD MM SS.ss", "-DD:MM:SS" or decimal degrees → degrees.
    static func parseDec(_ dec: String) -> Double? {
        let trimmed = dec.trimmingCharacters(in: .whitespaces)
        let isNegative = trimmed.hasPrefix("-")
        let cleaned = trimmed.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
        let parts = sexagesimalParts(cleaned)
        if parts.count >= 3 {
            let deg = parts[0] + parts[1] / 60.0 + parts[2] / 3600.0
            return isNegative ? -deg : deg
        }
        if parts.count == 1 {
            return isNegative ? -parts[0] : parts[0]
        }
        return nil
    }

    private static func sexagesimalParts(_ text: String) -> [Double] {
        text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == ":" })
            .compactMap { Double($0) }
    }

    /// Great-circle separation in degrees. Haversine: stable for tiny angles, correct across the
    /// 0h/24h RA wrap and near the poles — a plain |ΔRA| read 359° for a field straddling 0h.
    static func angularSeparation(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let toRad = Double.pi / 180
        let dLat = (dec2 - dec1) * toRad
        let dLon = (ra2 - ra1) * toRad
        let a = sin(dLat / 2) * sin(dLat / 2)
              + cos(dec1 * toRad) * cos(dec2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * atan2(sqrt(a), sqrt(max(0, 1 - a))) / toRad
    }

    /// The frame's sky center: the plate solve first (CRVAL1/2 — or, on load, NINA's RA/DEC
    /// mount position), the OBJCTRA/OBJCTDEC catalog position of the named object as fallback.
    static func skyCenter(of entry: ImageEntry) -> (ra: Double, dec: Double)? {
        if let ra = entry.solvedRA, let dec = entry.solvedDec { return (ra, dec) }
        guard let raText = entry.objctRA, let decText = entry.objctDec,
              let ra = parseRA(raText), let dec = parseDec(decText) else { return nil }
        return (ra, dec)
    }

    /// Field of view in degrees (width × height) from focal length, pixel size, binning and the
    /// frame dimensions. Height comes from the shared ASTAP helper; width follows the aspect.
    static func fieldSize(of entry: ImageEntry) -> (width: Double, height: Double)? {
        guard let width = entry.width, let height = entry.height, width > 0, height > 0,
              let heightDegrees = ASTAPSolver.fieldOfViewDegrees(heightPixels: height,
                                                                 arcsecPerPixel: entry.arcsecPerPixel,
                                                                 binning: entry.binning)
        else { return nil }
        return (heightDegrees * Double(width) / Double(height), heightDegrees)
    }

    /// Same-field tolerance for a set of frames: 60% of the larger edge of the typical field
    /// (median over the frames whose field is known), or the fixed fallback when none is.
    static func tolerance(for entries: [ImageEntry]) -> (degrees: Double, fieldSize: (width: Double, height: Double)?) {
        let sizes = entries.compactMap(fieldSize(of:))
        guard !sizes.isEmpty else { return (fallbackToleranceDegrees, nil) }
        let widths = sizes.map(\.width).sorted()
        let heights = sizes.map(\.height).sorted()
        let size = (width: widths[widths.count / 2], height: heights[heights.count / 2])
        return (overlapOffsetFraction * max(size.width, size.height), size)
    }

    // MARK: - Clustering

    private struct Cluster {
        var vectorSum: SIMD3<Double>
        var members: [Int]
        var center: (ra: Double, dec: Double) { FieldGrouping.direction(of: vectorSum) }
    }

    /// Groups entries into sky fields. Returns one field index per entry (nil when the entry has
    /// no coordinates) and the summaries, largest field first.
    ///
    /// Greedy single pass (join the nearest existing field whose center is within tolerance, else
    /// open a new one) followed by one re-assignment pass against the final centers, so a field's
    /// seed being an off-center dither does not split it. Hundreds of frames, a handful of
    /// fields — O(n·k) is instant.
    static func group(_ entries: [ImageEntry], tolerance: Double) -> (assignments: [Int?], fields: [FieldSummary]) {
        var positions: [(index: Int, ra: Double, dec: Double, vector: SIMD3<Double>)] = []
        for (index, entry) in entries.enumerated() {
            guard let center = skyCenter(of: entry) else { continue }
            positions.append((index, center.ra, center.dec, unitVector(ra: center.ra, dec: center.dec)))
        }
        var assignments = [Int?](repeating: nil, count: entries.count)
        guard !positions.isEmpty else { return (assignments, []) }

        var clusters: [Cluster] = []
        var clusterOf = [Int](repeating: 0, count: positions.count)
        for (p, position) in positions.enumerated() {
            var best: (cluster: Int, distance: Double)? = nil
            for (c, cluster) in clusters.enumerated() {
                let center = cluster.center
                let d = angularSeparation(ra1: position.ra, dec1: position.dec, ra2: center.ra, dec2: center.dec)
                if d <= tolerance && (best == nil || d < best!.distance) { best = (c, d) }
            }
            if let best {
                clusters[best.cluster].vectorSum += position.vector
                clusters[best.cluster].members.append(p)
                clusterOf[p] = best.cluster
            } else {
                clusters.append(Cluster(vectorSum: position.vector, members: [p]))
                clusterOf[p] = clusters.count - 1
            }
        }

        // Refinement pass against the settled centers.
        if clusters.count > 1 {
            let centers = clusters.map(\.center)
            var moved = false
            for (p, position) in positions.enumerated() {
                var nearest = clusterOf[p]
                var nearestDistance = angularSeparation(ra1: position.ra, dec1: position.dec,
                                                        ra2: centers[nearest].ra, dec2: centers[nearest].dec)
                for (c, center) in centers.enumerated() where c != nearest {
                    let d = angularSeparation(ra1: position.ra, dec1: position.dec, ra2: center.ra, dec2: center.dec)
                    if d < nearestDistance && d <= tolerance { nearest = c; nearestDistance = d }
                }
                if nearest != clusterOf[p] { clusterOf[p] = nearest; moved = true }
            }
            if moved {
                for c in clusters.indices { clusters[c].vectorSum = .zero; clusters[c].members = [] }
                for (p, position) in positions.enumerated() {
                    clusters[clusterOf[p]].vectorSum += position.vector
                    clusters[clusterOf[p]].members.append(p)
                }
                clusters.removeAll { $0.members.isEmpty }
            }
        }

        // Largest field first; ties keep the order of first appearance.
        let ordered = clusters.enumerated().sorted {
            $0.element.members.count != $1.element.members.count
                ? $0.element.members.count > $1.element.members.count
                : $0.offset < $1.offset
        }.map(\.element)

        var fields: [FieldSummary] = []
        let firstCenter = ordered[0].center
        for (rank, cluster) in ordered.enumerated() {
            let index = rank + 1
            var names = Set<String>()
            for p in cluster.members {
                let entryIndex = positions[p].index
                assignments[entryIndex] = index
                if let name = targetName(of: entries[entryIndex]) { names.insert(name) }
            }
            let center = cluster.center
            fields.append(FieldSummary(
                index: index,
                frameCount: cluster.members.count,
                centerRA: center.ra,
                centerDec: center.dec,
                separationFromFirst: rank == 0 ? 0
                    : angularSeparation(ra1: center.ra, dec1: center.dec, ra2: firstCenter.ra, dec2: firstCenter.dec),
                targetNames: names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            ))
        }
        return (assignments, fields)
    }

    /// Convenience: tolerance derived from the entries themselves.
    static func group(_ entries: [ImageEntry]) -> (assignments: [Int?], fields: [FieldSummary]) {
        group(entries, tolerance: tolerance(for: entries).degrees)
    }

    // MARK: - Stacking gate

    /// Everything `startQuickStackV2` needs to decide, and to explain, whether a selection is one
    /// field. Coordinates decide when any frame has them; object names only when none does.
    static func checkStackability(_ entries: [ImageEntry]) -> StackFieldCheck {
        let tolerance = tolerance(for: entries)
        let grouped = group(entries, tolerance: tolerance.degrees)
        let hasCoordinates = grouped.assignments.contains { $0 != nil }

        var names: [String] = []
        if !hasCoordinates {
            var seen = Set<String>()
            for entry in entries {
                if let name = targetName(of: entry), seen.insert(name.lowercased()).inserted { names.append(name) }
            }
            names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        var leading: Int? = nil
        if let first = grouped.fields.first {
            var nearest = Double.infinity
            for (index, assignment) in grouped.assignments.enumerated() where assignment == first.index {
                guard let center = skyCenter(of: entries[index]) else { continue }
                let d = angularSeparation(ra1: center.ra, dec1: center.dec, ra2: first.centerRA, dec2: first.centerDec)
                if d < nearest { nearest = d; leading = index }
            }
        }

        return StackFieldCheck(fields: grouped.fields,
                               assignments: grouped.assignments,
                               toleranceDegrees: tolerance.degrees,
                               fieldSize: tolerance.fieldSize,
                               namesWithoutCoordinates: names,
                               leadingEntryIndex: leading)
    }

    // MARK: - Helpers

    /// OBJECT name as the gate and the summaries show it; nil for empty / "unknown".
    static func targetName(of entry: ImageEntry) -> String? {
        guard let raw = entry.target else { return nil }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.lowercased() != "unknown" else { return nil }
        return name
    }

    /// "23h16m +60°04'"
    static func formatCenter(ra: Double, dec: Double) -> String {
        var hours = (ra / 15.0).truncatingRemainder(dividingBy: 24)
        if hours < 0 { hours += 24 }
        let h = Int(hours)
        let m = Int(((hours - Double(h)) * 60).rounded())
        let (hh, mm) = m == 60 ? ((h + 1) % 24, 0) : (h, m)
        let sign = dec < 0 ? "-" : "+"
        let absDec = abs(dec)
        let d = Int(absDec)
        var arcmin = Int(((absDec - Double(d)) * 60).rounded())
        var dd = d
        if arcmin == 60 { arcmin = 0; dd += 1 }
        return String(format: "%02dh%02dm %@%02d°%02d'", hh, mm, sign, dd, arcmin)
    }

    private static func unitVector(ra: Double, dec: Double) -> SIMD3<Double> {
        let toRad = Double.pi / 180
        let cosDec = cos(dec * toRad)
        return SIMD3(cosDec * cos(ra * toRad), cosDec * sin(ra * toRad), sin(dec * toRad))
    }

    private static func direction(of vector: SIMD3<Double>) -> (ra: Double, dec: Double) {
        let length = (vector * vector).sum().squareRoot()
        guard length > 0 else { return (0, 0) }
        let toDeg = 180 / Double.pi
        var ra = atan2(vector.y, vector.x) * toDeg
        if ra < 0 { ra += 360 }
        let dec = asin(max(-1, min(1, vector.z / length))) * toDeg
        return (ra, dec)
    }
}

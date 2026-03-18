// v4.4.0 — Color Combine Engine
// Orchestrates per-filter stacking via QuickStackEngineV2, then maps
// mono filter stacks to RGB channels with per-channel weight control.
// Supports presets: LRGB, HOO, SHO, HSO, HaRGB, Custom.

import Foundation
import Metal
import Accelerate
import Combine

@MainActor
class ColorCombineEngine: ObservableObject {

    // MARK: - Types

    enum Phase: String {
        case idle = ""
        case setup = "Setting up..."
        case stacking = "Stacking..."
        case combining = "Combining channels..."
        case done = "Done"
        case failed = "Failed"
    }

    enum ChannelPreset: String, CaseIterable, Identifiable {
        case sho = "SHO"
        case hoo = "HOO"
        case hso = "HSO"
        case lrgb = "LRGB"
        case hargb = "HaRGB"
        case custom = "Custom"

        var id: String { rawValue }
    }

    struct ChannelSource: Equatable {
        var filterName: String  // canonical filter name, or "" for none
        var weight: Float

        static let none = ChannelSource(filterName: "", weight: 1.0)
    }

    struct ChannelMapping: Equatable {
        var red: [ChannelSource]
        var green: [ChannelSource]
        var blue: [ChannelSource]
        var luminanceFilter: String  // "" = no luminance blending
        var luminanceBlend: Float    // 0.0–1.0

        static let empty = ChannelMapping(
            red: [.none], green: [.none], blue: [.none],
            luminanceFilter: "", luminanceBlend: 0.5
        )
    }

    struct FilterStack {
        let filterName: String        // canonical name
        let displayName: String       // original filter name from header
        let entries: [ImageEntry]
        var floatData: [Float]?       // mono planar float after stacking (uint16 range)
        var width: Int = 0
        var height: Int = 0
    }

    // MARK: - Published State

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var currentFilter: String = ""
    @Published var filtersDone: Int = 0
    @Published var filtersTotal: Int = 0
    @Published var availableFilters: [FilterInfo] = []
    @Published var selectedPreset: ChannelPreset = .sho
    @Published var channelMapping: ChannelMapping = .empty
    @Published var errorMessage: String?
    @Published var resultTexture: MTLTexture?

    var resultFloatData: [Float]?
    var resultWidth: Int = 0
    var resultHeight: Int = 0
    let resultChannelCount = 3

    // Per-filter stacked results (kept in memory for live recombine)
    var filterStacks: [String: FilterStack] = [:]

    struct FilterInfo: Identifiable {
        let canonical: String
        let display: String
        let count: Int
        var id: String { canonical }
    }

    let device: MTLDevice
    private var combineTask: Task<Void, Never>?

    // MARK: - Filter Alias Mapping

    // Maps common filter name variants to canonical names.
    // NINA, SGP, Voyager, ASIAIR all use different naming conventions.
    private static let filterAliases: [String: String] = [
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

    static func canonicalFilterName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let key = trimmed.lowercased()

        // Direct match
        if let canonical = filterAliases[key] { return canonical }

        // Try stripping trailing bandwidth (e.g., "OIII 7nm" → "oiii", "Ha_3nm" → "ha")
        let stripped = key
            .replacingOccurrences(of: #"\s*\d+\s*nm$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"_\d+nm$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let canonical = filterAliases[stripped] { return canonical }

        // Fallback: return original trimmed name
        return trimmed
    }

    // MARK: - Preset Definitions

    static func mapping(for preset: ChannelPreset) -> ChannelMapping {
        switch preset {
        case .sho:
            return ChannelMapping(
                red: [ChannelSource(filterName: "SII", weight: 1.0)],
                green: [ChannelSource(filterName: "Ha", weight: 1.0)],
                blue: [ChannelSource(filterName: "OIII", weight: 1.0)],
                luminanceFilter: "", luminanceBlend: 0.5
            )
        case .hoo:
            return ChannelMapping(
                red: [ChannelSource(filterName: "Ha", weight: 1.0)],
                green: [ChannelSource(filterName: "OIII", weight: 1.0)],
                blue: [ChannelSource(filterName: "OIII", weight: 1.0)],
                luminanceFilter: "", luminanceBlend: 0.5
            )
        case .hso:
            return ChannelMapping(
                red: [ChannelSource(filterName: "Ha", weight: 1.0)],
                green: [ChannelSource(filterName: "SII", weight: 1.0)],
                blue: [ChannelSource(filterName: "OIII", weight: 1.0)],
                luminanceFilter: "", luminanceBlend: 0.5
            )
        case .lrgb:
            return ChannelMapping(
                red: [ChannelSource(filterName: "R", weight: 1.0)],
                green: [ChannelSource(filterName: "G", weight: 1.0)],
                blue: [ChannelSource(filterName: "B", weight: 1.0)],
                luminanceFilter: "L", luminanceBlend: 0.5
            )
        case .hargb:
            return ChannelMapping(
                red: [ChannelSource(filterName: "R", weight: 0.5), ChannelSource(filterName: "Ha", weight: 0.5)],
                green: [ChannelSource(filterName: "G", weight: 1.0)],
                blue: [ChannelSource(filterName: "B", weight: 1.0)],
                luminanceFilter: "", luminanceBlend: 0.5
            )
        case .custom:
            return .empty
        }
    }

    // MARK: - Init

    init?(device: MTLDevice) {
        self.device = device
    }

    func cancel() {
        combineTask?.cancel()
        combineTask = nil
        phase = .idle
    }

    // MARK: - Scan Filters

    func scanFilters(entries: [ImageEntry]) {
        // Group entries by canonical filter name
        var groups: [String: (display: String, entries: [ImageEntry])] = [:]

        for entry in entries {
            let raw = entry.filter ?? ""
            guard !raw.isEmpty else { continue }
            let canonical = Self.canonicalFilterName(raw)
            if groups[canonical] == nil {
                groups[canonical] = (display: raw, entries: [])
            }
            groups[canonical]!.entries.append(entry)
        }

        // Only include filters with >= 3 frames (minimum for stacking)
        availableFilters = groups
            .filter { $0.value.entries.count >= 3 }
            .map { FilterInfo(canonical: $0.key, display: $0.value.display, count: $0.value.entries.count) }
            .sorted { $0.count > $1.count }

        // Store filter stacks for later
        for (canonical, group) in groups where group.entries.count >= 3 {
            filterStacks[canonical] = FilterStack(
                filterName: canonical, displayName: group.display,
                entries: group.entries
            )
        }

        // Auto-detect best preset
        let available = Set(availableFilters.map { $0.canonical })
        selectedPreset = autoDetectPreset(available: available)
        channelMapping = Self.mapping(for: selectedPreset)
    }

    private func autoDetectPreset(available: Set<String>) -> ChannelPreset {
        let hasHa = available.contains("Ha")
        let hasOIII = available.contains("OIII")
        let hasSII = available.contains("SII")
        let hasR = available.contains("R")
        let hasG = available.contains("G")
        let hasB = available.contains("B")

        if hasHa && hasOIII && hasSII { return .sho }
        if hasHa && hasOIII { return .hoo }
        if hasR && hasG && hasB && hasHa { return .hargb }
        if hasR && hasG && hasB { return .lrgb }
        return .custom
    }

    // MARK: - Start Combine

    func startCombine(debayerEnabled: Bool) {
        combineTask?.cancel()
        combineTask = nil

        errorMessage = nil
        phase = .stacking
        progress = 0

        // Determine which filters need stacking (only those assigned to a channel)
        let neededFilters = collectNeededFilters()
        guard !neededFilters.isEmpty else {
            errorMessage = "No filters assigned to channels"
            phase = .failed
            return
        }

        filtersTotal = neededFilters.count
        filtersDone = 0

        combineTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runCombine(neededFilters: neededFilters, debayerEnabled: debayerEnabled)
        }
    }

    private func collectNeededFilters() -> Set<String> {
        var needed: Set<String> = []
        for source in channelMapping.red where !source.filterName.isEmpty {
            needed.insert(source.filterName)
        }
        for source in channelMapping.green where !source.filterName.isEmpty {
            needed.insert(source.filterName)
        }
        for source in channelMapping.blue where !source.filterName.isEmpty {
            needed.insert(source.filterName)
        }
        if !channelMapping.luminanceFilter.isEmpty {
            needed.insert(channelMapping.luminanceFilter)
        }
        return needed
    }

    private func runCombine(neededFilters: Set<String>, debayerEnabled: Bool) async {
        // Stack each filter group sequentially
        for filterName in neededFilters.sorted() {
            guard !Task.isCancelled else { phase = .idle; return }
            guard var stack = filterStacks[filterName] else {
                errorMessage = "Filter '\(filterName)' has no frames"
                phase = .failed
                return
            }

            currentFilter = filterName
            phase = .stacking

            // Create a fresh stacking engine for this filter group
            guard let stackEngine = QuickStackEngineV2(device: device) else {
                errorMessage = "Failed to create stacking engine"
                phase = .failed
                return
            }

            // Start stacking (mono, no debayer for mono filters)
            stackEngine.startStack(entries: stack.entries, debayerEnabled: false)

            // Wait for completion by observing phase changes
            for await stackPhase in stackEngine.$phase.values {
                if stackPhase == .done { break }
                if stackPhase == .failed {
                    errorMessage = stackEngine.errorMessage ?? "Stacking failed for \(filterName)"
                    phase = .failed
                    return
                }
                // Update progress: per-filter progress weighted by filter count
                let filterProgress = stackEngine.progress
                progress = (Double(filtersDone) + filterProgress) / Double(filtersTotal)
            }

            guard let floatData = stackEngine.resultFloatData else {
                errorMessage = "No result data for \(filterName)"
                phase = .failed
                return
            }

            stack.floatData = floatData
            stack.width = stackEngine.resultWidth
            stack.height = stackEngine.resultHeight
            filterStacks[filterName] = stack

            filtersDone += 1
            progress = Double(filtersDone) / Double(filtersTotal)
        }

        guard !Task.isCancelled else { phase = .idle; return }

        // Combine channels
        phase = .combining
        combineChannels()

        if resultFloatData != nil {
            // Create display texture
            resultTexture = createDisplayTexture()
            phase = .done
            progress = 1.0
        }
    }

    // MARK: - Channel Combination (vDSP)

    func combineChannels() {
        // Find common dimensions (smallest across all stacked filters)
        var commonW = Int.max
        var commonH = Int.max
        for (_, stack) in filterStacks where stack.floatData != nil {
            commonW = min(commonW, stack.width)
            commonH = min(commonH, stack.height)
        }
        guard commonW < Int.max, commonH < Int.max, commonW > 0, commonH > 0 else {
            errorMessage = "No stacked filter data available"
            phase = .failed
            return
        }

        let planeSize = commonW * commonH
        var combined = [Float](repeating: 0, count: planeSize * 3) // R, G, B planes

        // Helper: add weighted filter data to an output channel plane
        func addWeighted(sources: [ChannelSource], channelOffset: Int) {
            var totalWeight: Float = 0
            for source in sources where !source.filterName.isEmpty {
                guard let stack = filterStacks[source.filterName],
                      let data = stack.floatData else { continue }
                totalWeight += source.weight

                // If dimensions match, use vDSP directly; otherwise crop to common size
                if stack.width == commonW && stack.height == commonH {
                    combined.withUnsafeMutableBufferPointer { outBuf in
                        data.withUnsafeBufferPointer { srcBuf in
                            vDSP_vsma(
                                srcBuf.baseAddress!, 1,
                                [source.weight],
                                outBuf.baseAddress! + channelOffset, 1,
                                outBuf.baseAddress! + channelOffset, 1,
                                vDSP_Length(planeSize)
                            )
                        }
                    }
                } else {
                    // Center-crop source to common dimensions
                    let offsetX = (stack.width - commonW) / 2
                    let offsetY = (stack.height - commonH) / 2
                    for y in 0..<commonH {
                        let srcRow = (y + offsetY) * stack.width + offsetX
                        let dstRow = channelOffset + y * commonW
                        for x in 0..<commonW {
                            combined[dstRow + x] += data[srcRow + x] * source.weight
                        }
                    }
                }
            }

            // Normalize by total weight
            if totalWeight > 0 && totalWeight != 1.0 {
                combined.withUnsafeMutableBufferPointer { buf in
                    vDSP_vsdiv(
                        buf.baseAddress! + channelOffset, 1,
                        [totalWeight],
                        buf.baseAddress! + channelOffset, 1,
                        vDSP_Length(planeSize)
                    )
                }
            }
        }

        addWeighted(sources: channelMapping.red, channelOffset: 0)
        addWeighted(sources: channelMapping.green, channelOffset: planeSize)
        addWeighted(sources: channelMapping.blue, channelOffset: 2 * planeSize)

        // Apply luminance blending if configured
        if !channelMapping.luminanceFilter.isEmpty, channelMapping.luminanceBlend > 0,
           let lumStack = filterStacks[channelMapping.luminanceFilter],
           let lumData = lumStack.floatData {
            applyLuminanceBlend(
                rgb: &combined, lumData: lumData,
                lumWidth: lumStack.width, lumHeight: lumStack.height,
                commonW: commonW, commonH: commonH, planeSize: planeSize,
                blend: channelMapping.luminanceBlend
            )
        }

        resultFloatData = combined
        resultWidth = commonW
        resultHeight = commonH
    }

    // MARK: - Luminance Blending
    // Preserves RGB color ratios while injecting L-channel detail.
    // Method: scale RGB by (L / Y) where Y is the luminance derived from RGB.

    private func applyLuminanceBlend(
        rgb: inout [Float], lumData: [Float],
        lumWidth: Int, lumHeight: Int,
        commonW: Int, commonH: Int, planeSize: Int,
        blend: Float
    ) {
        let rOff = 0, gOff = planeSize, bOff = 2 * planeSize

        for y in 0..<commonH {
            for x in 0..<commonW {
                let idx = y * commonW + x

                // Current RGB luminance (Rec.709)
                let yVal = 0.2126 * rgb[rOff + idx] + 0.7152 * rgb[gOff + idx] + 0.0722 * rgb[bOff + idx]
                guard yVal > 1.0 else { continue } // skip very dark pixels (avoid div by ~0)

                // Get L value (center-crop if needed)
                let lumX = x + (lumWidth - commonW) / 2
                let lumY = y + (lumHeight - commonH) / 2
                let lumIdx = lumY * lumWidth + lumX
                guard lumIdx >= 0 && lumIdx < lumData.count else { continue }
                let lVal = lumData[lumIdx]

                // Blended ratio: interpolate between 1.0 (no change) and L/Y (full luminance)
                let ratio = 1.0 + blend * (lVal / yVal - 1.0)
                let clampedRatio = min(max(ratio, 0.1), 10.0) // safety clamp

                rgb[rOff + idx] *= clampedRatio
                rgb[gOff + idx] *= clampedRatio
                rgb[bOff + idx] *= clampedRatio
            }
        }
    }

    // MARK: - Recombine (live weight adjustment, no re-stacking)

    func recombineWithWeights() {
        combineChannels()
        resultTexture = createDisplayTexture()
    }

    // MARK: - Display Texture

    private func createDisplayTexture() -> MTLTexture? {
        guard let data = resultFloatData else { return nil }
        return renderFloatToTexture(
            data: data, width: resultWidth, height: resultHeight,
            channelCount: 3, targetBackground: 0.25,
            device: device
        )
    }
}

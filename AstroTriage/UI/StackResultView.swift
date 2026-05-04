// Quick Stack V2 result window — final stacked image with stretch/contrast/
// saturation/sharpening/dark controls and save-to-file.
import SwiftUI
import AppKit
import Metal
import MetalKit
import Accelerate

struct StackResultViewV2: View {
    let engine: QuickStackEngineV2
    let nightMode: Bool
    let stackTimeMs: Int
    @Environment(\.fontScale) private var fontScale
    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }
    // Gradient removal state
    @State private var removeGradient: Bool = false
    @State private var structureAmount: Double = 0.0
    @State private var showOriginal: Bool = false
    @State private var originalTexture: MTLTexture?
    // Preprocessed data cache: gradient + wiener + structure applied to raw floats.
    // Only recomputed when these specific controls change — NOT on stretch/dark/sharp etc.
    @State private var preprocessedData: [Float]?
    @State private var preprocessNeedsUpdate: Bool = true
    @State private var stretchValue: Double = 0.25
    @State private var sharpening: Double = 0.0
    @State private var contrast: Double = 0.0
    @State private var darkLevel: Double = 0.0
    @State private var saturation: Double = 1.0
    @State private var linkedStretch: Bool = false
    @State private var denoise: Double = 0.0
    @State private var deconvolve: Double = 0.0
    @State private var useRL: Bool = false
    @State private var deconvMode: DeconvMode = .rl
    @State private var displayTexture: MTLTexture?
    @State private var savedMessage: String?
    @State private var isRendering: Bool = false
    @State private var renderTask: Task<Void, Never>?
    @StateObject private var benchmarkService = BenchmarkService()
    // Freeze-stamp: stack of frozen base textures for sequential processing
    @State private var frozenStack: [(texture: MTLTexture, floatData: [Float])] = []

    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }

    // Compute best frame metrics summary from stacked entries
    private var bestFrameMetrics: String? {
        let entries = engine.stackedEntries
        guard entries.count >= 2 else { return nil }
        // Find the best entry by quality z-score
        guard let best = entries.max(by: { ($0.qualityZScore ?? -100) < ($1.qualityZScore ?? -100) }) else { return nil }
        var parts: [String] = ["Best frame vs \(entries.count) stacked:"]
        if let stars = best.displayStarCount { parts.append("Stars \(stars)") }
        if let fwhm = best.displayFWHM { parts.append("FWHM \(String(format: "%.1f", fwhm))") }
        if let hfr = best.displayHFR { parts.append("HFR \(String(format: "%.1f", hfr))") }
        if let ecc = best.computedEccentricity { parts.append("Ecc \(String(format: "%.2f", ecc))") }
        if let med = best.noiseMedian, let mad = best.noiseMAD, mad > 0 {
            let snr = med / mad
            // Theoretical SNR improvement from stacking N frames
            let stackSNR = snr * Float(entries.count).squareRoot()
            parts.append("SNR \(String(format: "%.0f", snr))\u{2192}\(String(format: "%.0f", stackSNR)) (est.)")
        }
        return parts.count > 1 ? parts.joined(separator: "  \u{2502}  ") : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Single view instance — swap texture to preserve zoom state
                if let tex = (showOriginal ? originalTexture : displayTexture) ?? engine.resultTexture {
                    ZoomableMetalTextureView(texture: tex)
                }
                if showOriginal {
                    VStack {
                        HStack {
                            Text("ORIGINAL")
                                .font(.system(size: fs(14), weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.7)))
                            Spacer()
                        }
                        .padding(12)
                        Spacer()
                    }
                }
                if isRendering {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(1.2)
                                .tint(nightMode ? .red : .blue)
                                .padding(12)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(10)
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }

            HStack(spacing: 10) {
                Button(action: resetSliders) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: fs(12), weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(nightMode ? .red : .primary)
                .help("Reset all sliders")

                // Freeze: bake current adjustments into a new base layer
                Button(action: freezeCurrentState) {
                    HStack(spacing: 2) {
                        Image(systemName: "snowflake")
                            .font(.system(size: fs(10)))
                        Text("Freeze")
                            .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered).controlSize(.mini)
                .tint(.cyan)
                .help("Bake current adjustments into base. Then apply further adjustments on top.")

                // Unfreeze: revert to previous frozen state
                if !frozenStack.isEmpty {
                    Button(action: unfreezeLastState) {
                        HStack(spacing: 2) {
                            Image(systemName: "flame")
                                .font(.system(size: fs(10)))
                            Text("Unfreeze (\(frozenStack.count))")
                                .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .tint(.orange)
                    .help("Undo last freeze — go back one step")
                }

                // Row 1: Basic processing
                resultSlider("Stretch", value: $stretchValue, range: 0.0...1.0, step: 0.01,
                             display: "\(Int(stretchValue * 100))%")
                    .help("STF auto-stretch target background level.\n0% = linear (no stretch), 25% = default, higher = brighter.")
                resultSlider("Dark", value: $darkLevel, range: 0.0...1.0, step: 0.01,
                             display: String(format: "%.2f", darkLevel))
                    .help("Dark level / shadows clip.\nRaises the black point to clip faint background.")
                resultSlider("Sharp", value: $sharpening, range: -4.0...4.0, step: 0.1,
                             display: String(format: "%+.1f", sharpening))
                    .help("Unsharp mask sharpening.\nNegative = blur, 0 = off, positive = sharpen.")
                resultSlider("Contrast", value: $contrast, range: -2.0...2.0, step: 0.05,
                             display: String(format: "%+.1f", contrast))
                    .help("Contrast adjustment around midpoint.\nNegative = flatten, 0 = off, positive = increase.")
                if engine.resultChannelCount > 1 {
                    resultSlider("Color", value: $saturation, range: 0.0...3.0, step: 0.05,
                                 display: String(format: "%.1f", saturation))
                        .help("Color saturation.\n0 = monochrome, 1.0 = natural, >1 = boosted.")
                    Toggle("Linked", isOn: $linkedStretch)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(nightMode ? .red.opacity(0.7) : .secondary)
                        .help("OFF = Balanced: per-channel background clip + shared midtone (best white balance).\nON = Linked: identical stretch for all channels (raw color ratios).")
                        .onChange(of: linkedStretch) { scheduleRender() }
                }
                resultSlider("Denoise", value: $denoise, range: 0.0...2.0, step: 0.02,
                             display: denoise < 0.01 ? "Off" : String(format: "%.0f%%", denoise * 100))
                    .help("Two-pass GPU denoise: bilateral (pixel noise) + chrominance (color patches).\n0 = off, 100%+ = aggressive.")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            // Row 2: Advanced — deconvolution, structure, gradient
            HStack(spacing: 4) {
                resultSlider("Deconv", value: $deconvolve, range: 0.0...2.0, step: 0.02,
                             display: deconvolve < 0.01 ? "Off" : String(format: "%.1f", deconvolve))
                    .help("Star deconvolution — recovers detail lost to atmospheric seeing.\nRL = Richardson-Lucy (GPU, fast, default).\nUSM = Unsharp Mask (GPU, fastest).\nWiener = noise-aware (GPU, experimental).")
                    .onChange(of: deconvolve) { if deconvMode == .wiener { invalidatePreprocess() } }
                Picker("", selection: $deconvMode) {
                    ForEach(DeconvMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .font(.system(size: fs(9)))
                .help("RL = Richardson-Lucy iterative (GPU, recommended).\nUSM = multi-scale unsharp mask (GPU, fastest).\nWiener = noise-regularized sharpening using measured FWHM (GPU, experimental).")
                .onChange(of: deconvMode) { _, newMode in
                    useRL = (newMode == .rl)
                    invalidatePreprocess()
                }
                resultSlider("Structure", value: $structureAmount, range: 0.0...2.0, step: 0.02,
                             display: structureAmount < 0.01 ? "Off" : String(format: "%.0f%%", structureAmount * 100))
                    .help("Enhance nebula/cloud detail without sharpening stars.\nLarge-radius local contrast boost for extended structures.")
                    .onChange(of: structureAmount) { invalidatePreprocess() }
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                Toggle("Gradient", isOn: $removeGradient)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                    .foregroundColor(removeGradient ? .cyan : .secondary)
                    .help("Remove background gradient (light pollution, vignetting).\nUses median grid + bicubic interpolation.")
                    .onChange(of: removeGradient) {
                        invalidatePreprocess()
                    }
                    .frame(width: 82)
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 16)
                Toggle("A/B", isOn: $showOriginal)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                    .foregroundColor(showOriginal ? .orange : .secondary)
                    .help("Toggle original vs processed view. Preserves zoom. No recalculation.")
                    .frame(width: 60)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            // Best frame comparison — shows what the best single frame had vs the stack
            if let bestMetrics = bestFrameMetrics {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: fs(10)))
                        .foregroundColor(.cyan.opacity(0.8))
                    Text(bestMetrics)
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(fgDim)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(nightMode ? Color(red: 0.04, green: 0, blue: 0) : Color(NSColor.controlBackgroundColor).opacity(0.5))
            }

            HStack(spacing: 12) {
                Text("\(engine.resultWidth)x\(engine.resultHeight) — LightspeedStacker")
                    .font(.system(size: fs(11), design: .monospaced))
                    .foregroundColor(fgDim)

                if !engine.alignmentInfo.isEmpty {
                    Text(engine.alignmentInfo)
                        .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                        .foregroundColor(engine.alignmentInfo.contains("skipped") ? .orange : .green)
                }

                Spacer()

                // Share & Compare benchmark button — centered and prominent
                Button(action: { shareLightspeedBenchmark() }) {
                    HStack(spacing: 4) {
                        Image(systemName: benchmarkService.isUploading ? "arrow.triangle.2.circlepath" : "trophy")
                            .font(.system(size: fs(12)))
                        Text("Share & Compare")
                            .font(.system(size: fs(11), weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(benchmarkService.isUploading || !BenchmarkConfig.isConfigured)
                .help(BenchmarkConfig.isConfigured
                      ? "Share your benchmark and see how you rank"
                      : "Benchmark sharing not configured — see CLAUDE.md")

                Spacer()

                Button(action: saveAsPNG) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: fs(12)))
                        Text("Save PNG")
                            .font(.system(size: fs(11), weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export current view as PNG file")
                if let msg = savedMessage {
                    Text(msg)
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(nightMode ? Color.black : Color(NSColor.windowBackgroundColor))
        }
        .background(Color.black)
        .onAppear { scheduleRender() }
    }

    private func resultSlider(_ label: String, value: Binding<Double>,
                               range: ClosedRange<Double>, step: Double,
                               display: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: fs(10), design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 48, alignment: .trailing)
            Slider(value: value, in: range, step: step)
                .frame(minWidth: 60, maxWidth: 100)
                .onChange(of: value.wrappedValue) { scheduleRender() }
            Text(display)
                .font(.system(size: fs(10), design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 32, alignment: .leading)
        }
    }

    private func resetSliders() {
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0; saturation = 1.0; linkedStretch = false; denoise = 0.0; deconvolve = 0.0; useRL = false
        removeGradient = false; structureAmount = 0.0
        preprocessedData = nil; preprocessNeedsUpdate = true
        scheduleRender()
    }

    // Freeze: render current adjustments into a new base float array, reset sliders
    private func freezeCurrentState() {
        guard let currentTex = displayTexture ?? engine.resultTexture else { return }
        guard let currentFloat = engine.resultFloatData else { return }

        frozenStack.append((texture: currentTex, floatData: currentFloat))

        let w = engine.resultWidth
        let h = engine.resultHeight
        let ch = engine.resultChannelCount

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        currentTex.getBytes(&pixels, bytesPerRow: w * 4,
                     from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1)),
                     mipmapLevel: 0)

        let isRGBA = currentTex.pixelFormat != .bgra8Unorm
        var newFloatData = [Float](repeating: 0, count: w * h * ch)
        let planeSize = w * h
        for y in 0..<h {
            for x in 0..<w {
                let pi = (y * w + x) * 4
                let r = Float(pixels[pi + (isRGBA ? 0 : 2)]) / 255.0 * 65535.0
                let g = Float(pixels[pi + 1]) / 255.0 * 65535.0
                let b = Float(pixels[pi + (isRGBA ? 2 : 0)]) / 255.0 * 65535.0
                newFloatData[y * w + x] = r
                if ch >= 3 {
                    newFloatData[planeSize + y * w + x] = g
                    newFloatData[2 * planeSize + y * w + x] = b
                }
            }
        }

        engine.resultFloatData = newFloatData
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0
        saturation = 1.0; linkedStretch = false; denoise = 0.0; deconvolve = 0.0; useRL = false
        scheduleRender()
    }

    private func unfreezeLastState() {
        guard let prev = frozenStack.popLast() else { return }
        engine.resultFloatData = prev.floatData
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0
        saturation = 1.0; linkedStretch = false; denoise = 0.0; deconvolve = 0.0; useRL = false
        scheduleRender()
    }

    private func scheduleRender() {
        renderTask?.cancel()
        isRendering = true
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await restretch()
        }
    }

    // Invalidate preprocessed cache — call when gradient/wiener/structure change
    // Uses longer debounce since preprocessing is CPU-heavy
    private func invalidatePreprocess() {
        preprocessedData = nil
        preprocessNeedsUpdate = true
        renderTask?.cancel()
        isRendering = true
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce for heavy ops
            guard !Task.isCancelled else { return }
            await restretch()
        }
    }

    @MainActor
    private func restretch() async {
        guard let floatData = engine.resultFloatData else { isRendering = false; return }
        let w = engine.resultWidth, h = engine.resultHeight, ch = engine.resultChannelCount
        let target = Float(stretchValue), sharp = Float(sharpening)
        let cont = Float(contrast), dark = Float(darkLevel), sat = Float(saturation)
        let linked = linkedStretch
        let dn = Float(denoise)
        let dc = Float(deconvolve)
        let rl = useRL
        let dev = engine.device

        // Preprocess: gradient + wiener + structure (CACHED — only recomputed when needed)
        if preprocessNeedsUpdate || preprocessedData == nil {
            let doGradient = removeGradient
            let doWiener = deconvMode == .wiener && dc > 0.01
            let wienerStrength = dc
            let wienerFwhm = Float(engine.averageFWHM ?? 3.0)
            let structAmt = Float(structureAmount)

            let gpuDevice = dev
            let result = await Task.detached(priority: .userInitiated) { () -> [Float] in
                var data = floatData

                // Gradient removal (GPU)
                if doGradient {
                    data = GradientRemoval.removeGradient(data: data, width: w, height: h, channelCount: ch, device: gpuDevice)
                }

                // Wiener deconvolution (GPU)
                if doWiener {
                    data = WienerDeconvolution.deconvolve(data: data, width: w, height: h,
                                                          channelCount: ch, fwhm: wienerFwhm, strength: wienerStrength, device: gpuDevice)
                }

                // Structure enhancement (GPU)
                if structAmt > 0.01 {
                    data = StructureEnhancement.enhance(data: data, width: w, height: h,
                                                        channelCount: ch, amount: structAmt, device: gpuDevice)
                }

                return data
            }.value

            preprocessedData = result
            preprocessNeedsUpdate = false
        }

        let dataToRender = preprocessedData ?? floatData

        // GPU render: STF + sharp + contrast + dark + denoise + GPU deconv (FAST — <16ms)
        let gpuDeconv: Float = deconvMode == .wiener ? 0 : dc

        let tex = await Task.detached(priority: .userInitiated) {
            renderFloatToTexture(data: dataToRender, width: w, height: h,
                                channelCount: ch, targetBackground: target,
                                sharpening: sharp, contrast: cont, darkLevel: dark,
                                saturation: sat, linkedStretch: linked, denoise: dn, deconvolve: gpuDeconv, useRL: rl, device: dev)
        }.value

        displayTexture = tex
        // Cache original on first render for A/B toggle
        if originalTexture == nil {
            originalTexture = await Task.detached(priority: .utility) {
                renderFloatToTexture(data: floatData, width: w, height: h,
                                    channelCount: ch, targetBackground: 0.25, device: dev)
            }.value
        }
        isRendering = false
    }

    private func defaultFilename() -> String {
        let entries = engine.stackedEntries
        guard !entries.isEmpty else { return "quickstack_v2_result.png" }
        var parts: [String] = []
        if let obj = entries.compactMap({ $0.target }).first, !obj.isEmpty, obj.lowercased() != "unknown" {
            parts.append(obj.replacingOccurrences(of: " ", with: "_"))
        }
        if let date = entries.compactMap({ $0.date }).sorted().first { parts.append(date) }
        let filters = Set(entries.compactMap { $0.filter?.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "none" })
        if !filters.isEmpty { parts.append(filters.sorted().joined(separator: "+")) }
        if let cam = entries.compactMap({ $0.camera }).first, !cam.isEmpty {
            parts.append(cam.replacingOccurrences(of: " ", with: "_"))
        }
        parts.append("stacked-\(entries.count)")
        if parts.isEmpty { return "quickstack_v2_result.png" }
        let name = parts.joined(separator: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-")).inverted).joined()
        return "\(name).png"
    }

    private func saveAsPNG() {
        guard let tex = displayTexture ?? engine.resultTexture else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFilename()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let w = tex.width, h = tex.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&pixels, bytesPerRow: w * 4,
                     from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1)),
                     mipmapLevel: 0)
        if tex.pixelFormat == .bgra8Unorm {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let b = pixels[i]; pixels[i] = pixels[i + 2]; pixels[i + 2] = b
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try pngData.write(to: url)
            savedMessage = "Saved!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedMessage = nil }
        } catch {
            savedMessage = "Error: \(error.localizedDescription)"
        }
    }

    // Upload benchmark and open leaderboard
    private func shareLightspeedBenchmark() {
        let entry = BenchmarkService.buildEntry(
            engine: "lightspeed",
            stackTimeMs: stackTimeMs,
            fileCount: engine.totalLayers,
            imageWidth: engine.resultWidth,
            imageHeight: engine.resultHeight
        )
        Task {
            await benchmarkService.shareAndCompare(entry: entry)
            BenchmarkLeaderboardWindowController.shared.show(
                service: benchmarkService,
                myMachineHash: MachineInfo.machineHash,
                engine: "lightspeed"
            )
        }
    }
}


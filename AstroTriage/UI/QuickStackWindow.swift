// v3.2.0
import SwiftUI
import MetalKit
import Accelerate
import UniformTypeIdentifiers

// Quick Stack progress panel: shows live 200x200 mini preview during stacking,
// then opens the full result in a floating window when complete.

struct QuickStackProgressView: View {
    @ObservedObject var engine: QuickStackEngine
    let nightMode: Bool
    var onDismiss: () -> Void

    // Track stack start time to compute duration for benchmark
    @State private var stackStartDate = Date()

    private var fg: Color { nightMode ? .red : .primary }
    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }
    private var bg: Color { nightMode ? .black : Color(NSColor.windowBackgroundColor) }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "square.3.layers.3d.down.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(fg)
                Text("Quick Stack")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(fg)
                Spacer()

                if engine.phase != .done && engine.phase != .failed && engine.phase != .idle {
                    Button(action: {
                        engine.cancel()
                        onDismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(fgDim)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel stacking")
                }
            }

            // Mini preview (200x200)
            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 200, height: 200)

                if let texture = engine.miniPreviewTexture {
                    MetalTextureView(texture: texture)
                        .frame(width: 200, height: 200)
                } else {
                    // Placeholder before first preview appears
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(nightMode ? .red : nil)
                        Text("Preparing...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }

                // Blue crosses showing detected star positions during star detection phase
                if engine.phase == .detecting && !engine.detectedStarPositions.isEmpty {
                    ForEach(0..<engine.detectedStarPositions.count, id: \.self) { i in
                        let pos = engine.detectedStarPositions[i]
                        StarCrossShape()
                            .stroke(Color(red: 0.3, green: 0.6, blue: 1.0), lineWidth: 1.5)
                            .frame(width: 10, height: 10)
                            .position(x: pos.x, y: pos.y)
                    }
                }
            }
            .frame(width: 200, height: 200)
            .clipped()
            .cornerRadius(4)

            // Phase + progress
            Text(engine.phase.rawValue)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(fg)

            if engine.phase == .aligning || engine.phase == .stacking {
                Text("Layer \(engine.currentLayer) / \(engine.totalLayers)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(fgDim)
            }

            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .tint(nightMode ? .red : .accentColor)

            // Error message
            if let error = engine.errorMessage {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }

            // Done: open result button
            if engine.phase == .done {
                Button(action: { openResultWindow() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                        Text("Open Result (\(engine.resultWidth)x\(engine.resultHeight))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Dismiss button for done/failed states
            if engine.phase == .done || engine.phase == .failed {
                Button("Close") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(fg)
            }
        }
        .padding(16)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bg.opacity(0.95))
                .shadow(radius: 8)
        )
        // Auto-open result window when stacking completes
        .onChange(of: engine.phase) { newPhase in
            if newPhase == .done {
                openResultWindow()
            }
        }
    }

    // Open the stacked result in a new floating NSWindow
    private func openResultWindow() {
        guard engine.resultTexture != nil else { return }

        let stackMs = Int(Date().timeIntervalSince(stackStartDate) * 1000)
        let resultView = StackResultView(
            engine: engine,
            nightMode: nightMode,
            stackTimeMs: stackMs
        )

        let hostingView = NSHostingView(rootView: resultView)

        // Size the window to fit the image at a reasonable scale
        let maxDim: CGFloat = 1200
        let scale = min(maxDim / CGFloat(engine.resultWidth), maxDim / CGFloat(engine.resultHeight), 1.0)
        let winW = CGFloat(engine.resultWidth) * scale + 40
        let winH = CGFloat(engine.resultHeight) * scale + 80

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Stack Result — \(engine.resultWidth)x\(engine.resultHeight)"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }
}

// Displays the stacked result with all adjustment sliders (stretch, sharpening, contrast, dark)
// and Save as PNG. All adjustments are applied to the raw float data for maximum quality.
struct StackResultView: View {
    let engine: QuickStackEngine
    let nightMode: Bool
    let stackTimeMs: Int
    @State private var stretchValue: Double = 0.25
    @State private var sharpening: Double = 0.0
    @State private var contrast: Double = 0.0
    @State private var darkLevel: Double = 0.0
    @State private var saturation: Double = 1.0
    @State private var linkedStretch: Bool = false
    @State private var denoise: Double = 0.0
    @State private var deconvolve: Double = 0.0
    @State private var useRL: Bool = false
    @State private var displayTexture: MTLTexture?
    @State private var savedMessage: String?
    @State private var isRendering: Bool = false
    @StateObject private var benchmarkService = BenchmarkService()
    // Debounce timer to avoid re-rendering on every slider tick
    @State private var renderTask: Task<Void, Never>?

    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let tex = displayTexture ?? engine.resultTexture {
                    ZoomableMetalTextureView(texture: tex)
                }

                // Subtle loading spinner while re-rendering after slider change
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

            // Row 1: Sliders
            HStack(spacing: 10) {
                // Reset button
                Button(action: resetSliders) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(nightMode ? .red : .primary)
                .help("Reset all sliders")

                resultSlider("Stretch", value: $stretchValue, range: 0.0...1.0, step: 0.01,
                             display: "\(Int(stretchValue / 1.0 * 100))%")
                    .help("STF auto-stretch target background level.\n0% = linear (no stretch), 25% = default, higher = brighter.")
                resultSlider("Sharp", value: $sharpening, range: -4.0...4.0, step: 0.1,
                             display: String(format: "%+.1f", sharpening))
                    .help("Unsharp mask sharpening.\nNegative = blur, 0 = off, positive = sharpen.")
                resultSlider("Contrast", value: $contrast, range: -2.0...2.0, step: 0.05,
                             display: String(format: "%+.1f", contrast))
                    .help("Contrast adjustment around midpoint.\nNegative = flatten, 0 = off, positive = increase.")
                resultSlider("Dark", value: $darkLevel, range: 0.0...1.0, step: 0.01,
                             display: String(format: "%.2f", darkLevel))
                    .help("Dark level / shadows clip.\nRaises the black point to clip faint background.")
                if engine.resultChannelCount > 1 {
                    resultSlider("Color", value: $saturation, range: 0.0...3.0, step: 0.05,
                                 display: String(format: "%.1f", saturation))
                        .help("Color saturation.\n0 = monochrome, 1.0 = natural, >1 = boosted.")
                    Toggle("Linked", isOn: $linkedStretch)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(nightMode ? .red.opacity(0.7) : .secondary)
                        .help("OFF = Balanced: per-channel background clip + shared midtone (best white balance).\nON = Linked: identical stretch for all channels (raw color ratios).")
                        .onChange(of: linkedStretch) { _ in scheduleRender() }
                }
                resultSlider("Denoise", value: $denoise, range: 0.0...2.0, step: 0.02,
                             display: denoise < 0.01 ? "Off" : String(format: "%.0f%%", denoise * 100))
                    .help("Two-pass GPU denoise: bilateral (pixel noise) + chrominance (color patches).\n0 = off, 100%+ = aggressive.")
                resultSlider("Deconv", value: $deconvolve, range: 0.0...2.0, step: 0.02,
                             display: deconvolve < 0.01 ? "Off" : String(format: "%.1f", deconvolve))
                    .help("Deconvolution sharpening to recover detail.\nUSM = multi-scale unsharp mask, RL = Richardson-Lucy iterative.")
                Toggle(useRL ? "RL" : "USM", isOn: $useRL)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(useRL ? .orange : .secondary)
                    .help("USM = Multi-scale Unsharp Mask (fast).\nRL = Richardson-Lucy deconvolution (better quality, slower).")
                    .onChange(of: useRL) { _ in scheduleRender() }
                    .frame(width: 52)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            // Row 2: Share centered, info + save on sides
            HStack(spacing: 12) {
                Text("\(engine.resultWidth)x\(engine.resultHeight) — Quick Stack")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(fgDim)

                Spacer()

                // Share & Compare benchmark button — centered and prominent
                Button(action: { shareNormalBenchmark() }) {
                    HStack(spacing: 4) {
                        Image(systemName: benchmarkService.isUploading ? "arrow.triangle.2.circlepath" : "trophy")
                            .font(.system(size: 12))
                        Text("Share & Compare")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                            .font(.system(size: 12))
                        Text("Save PNG")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export current view as PNG file")

                if let msg = savedMessage {
                    Text(msg)
                        .font(.system(size: 10, design: .monospaced))
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

    // Compact slider matching the main app's style
    private func resultSlider(_ label: String, value: Binding<Double>,
                               range: ClosedRange<Double>, step: Double,
                               display: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 48, alignment: .trailing)
            Slider(value: value, in: range, step: step)
                .frame(minWidth: 60, maxWidth: 100)
                .onChange(of: value.wrappedValue) { _ in scheduleRender() }
            Text(display)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 32, alignment: .leading)
        }
    }

    private func resetSliders() {
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0; saturation = 1.0; linkedStretch = false; denoise = 0.0; deconvolve = 0.0; useRL = false
        scheduleRender()
    }

    // Debounced render: cancels previous task so rapid slider changes don't pile up
    private func scheduleRender() {
        renderTask?.cancel()
        isRendering = true
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms debounce
            guard !Task.isCancelled else { return }
            await restretch()
        }
    }

    // Re-render with current stretch + post-processing settings
    @MainActor
    private func restretch() async {
        guard let floatData = engine.resultFloatData else {
            isRendering = false
            return
        }
        let w = engine.resultWidth
        let h = engine.resultHeight
        let ch = engine.resultChannelCount
        let target = Float(stretchValue)
        let sharp = Float(sharpening)
        let cont = Float(contrast)
        let dark = Float(darkLevel)
        let sat = Float(saturation)
        let linked = linkedStretch
        let dn = Float(denoise)
        let dc = Float(deconvolve)
        let rl = useRL
        let dev = engine.device

        let tex = await Task.detached(priority: .userInitiated) {
            renderFloatToTexture(
                data: floatData, width: w, height: h,
                channelCount: ch, targetBackground: target,
                sharpening: sharp, contrast: cont, darkLevel: dark,
                saturation: sat, linkedStretch: linked, denoise: dn, deconvolve: dc, useRL: rl, device: dev
            )
        }.value

        displayTexture = tex
        isRendering = false
    }

    // Build a descriptive default filename from session metadata:
    // objectname_datetime_filters_camera.png
    private func defaultFilename() -> String {
        let entries = engine.stackedEntries
        guard !entries.isEmpty else { return "quickstack_result.png" }

        var parts: [String] = []

        // Object name
        if let obj = entries.compactMap({ $0.target }).first, !obj.isEmpty, obj.lowercased() != "unknown" {
            parts.append(obj.replacingOccurrences(of: " ", with: "_"))
        }

        // Acquisition date from first image
        if let date = entries.compactMap({ $0.date }).sorted().first {
            parts.append(date)
        }

        // Unique filters sorted alphabetically
        let filters = Set(entries.compactMap { $0.filter?
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "none" })
        if !filters.isEmpty {
            parts.append(filters.sorted().joined(separator: "+"))
        }

        // Camera/instrument
        if let cam = entries.compactMap({ $0.camera }).first, !cam.isEmpty {
            parts.append(cam.replacingOccurrences(of: " ", with: "_"))
        }

        if parts.isEmpty { return "quickstack_result.png" }
        // Sanitize: remove characters that are problematic in filenames
        let name = parts.joined(separator: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-")).inverted)
            .joined()
        return "\(name).png"
    }

    // Save the current display texture as PNG (includes all adjustments)
    private func saveAsPNG() {
        guard let tex = displayTexture ?? engine.resultTexture else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFilename()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let w = tex.width
        let h = tex.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&pixels, bytesPerRow: w * 4,
                     from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1)),
                     mipmapLevel: 0)

        // Swap B↔R only for BGRA textures (engine.resultTexture).
        // renderFloatToTexture output is RGBA — no swap needed.
        if tex.pixelFormat == .bgra8Unorm {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let b = pixels[i]; pixels[i] = pixels[i + 2]; pixels[i + 2] = b
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return }

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
    private func shareNormalBenchmark() {
        let entry = BenchmarkService.buildEntry(
            engine: "normal",
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
                engine: "normal"
            )
        }
    }
}

// Render float data to a BGRA8 texture with STF stretch + post-processing.
// Uses Metal GPU compute for instant results (<16ms on any Apple Silicon).
// CPU fallback only if Metal pipeline setup fails.
// Post-process pipeline: stretch → dark level → contrast → sharpening (matches main app)
func renderFloatToTexture(
    data: [Float], width: Int, height: Int,
    channelCount: Int, targetBackground: Float,
    sharpening: Float = 0, contrast: Float = 0, darkLevel: Float = 0,
    saturation: Float = 1.0, linkedStretch: Bool = false,
    denoise: Float = 0, deconvolve: Float = 0, useRL: Bool = false,
    precomputedSTF: [STFParams]? = nil,
    device: MTLDevice
) -> MTLTexture? {
    let planeSize = width * height

    // Compute STF params per channel (matches STFCalculator: 5% subsample)
    func computeSTF(channelOffset: Int) -> (c0: Float, mb: Float) {
        let sampleCount = max(1000, Int(Float(planeSize) * 0.05))
        let sampleStride = max(1, planeSize / sampleCount)
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        for i in stride(from: 0, to: planeSize, by: sampleStride) {
            samples.append(data[channelOffset + i] / 65535.0)
        }
        vDSP_vsort(&samples, vDSP_Length(samples.count), 1)
        let median = samples[samples.count / 2]
        var devs = samples
        let negMed = -median
        vDSP_vsadd(devs, 1, [negMed], &devs, 1, vDSP_Length(devs.count))
        vDSP_vabs(devs, 1, &devs, 1, vDSP_Length(devs.count))
        vDSP_vsort(&devs, vDSP_Length(devs.count), 1)
        let mad = 1.4826 * devs[devs.count / 2]
        let c0 = max(Float(0.0), min(Float(1.0), median + (-1.25) * mad))
        let mb: Float
        if targetBackground <= 0.001 {
            mb = 0.5
        } else {
            let mNorm = max(Float(0.001), min(Float(0.999), (median - c0) / max(1.0 - c0, 0.001)))
            mb = mNorm * (1 - targetBackground) / (mNorm * (1 - 2 * targetBackground) + targetBackground)
        }
        return (c0, mb)
    }

    // Use precomputed STF params (from full-res data) only when stretch slider
    // is at default (0.25). When user adjusts stretch, recompute with new target.
    let usePrecomputed = precomputedSTF != nil && abs(targetBackground - 0.25) < 0.01

    let stfR: (c0: Float, mb: Float)
    if usePrecomputed, let pre = precomputedSTF, !pre.isEmpty {
        stfR = (pre[0].c0, pre[0].mb)
    } else {
        stfR = computeSTF(channelOffset: 0)
    }

    let c0: Float
    let mb: Float
    let stfG: (c0: Float, mb: Float)
    let stfB: (c0: Float, mb: Float)

    if linkedStretch || channelCount < 3 {
        c0 = stfR.c0
        mb = stfR.mb
        stfG = stfR
        stfB = stfR
    } else {
        c0 = stfR.c0
        mb = stfR.mb
        if usePrecomputed, let pre = precomputedSTF, pre.count >= 3 {
            stfG = (pre[1].c0, pre[1].mb)
            stfB = (pre[2].c0, pre[2].mb)
        } else {
            stfG = computeSTF(channelOffset: planeSize)
            stfB = computeSTF(channelOffset: 2 * planeSize)
        }
    }

    // GPU path: upload float data to MTLBuffer, run restretch_float kernel
    let dataByteCount = data.count * MemoryLayout<Float>.size
    guard let inputBuffer = data.withUnsafeBufferPointer({ ptr in
        device.makeBuffer(bytes: ptr.baseAddress!, length: dataByteCount, options: .storageModeShared)
    }) else { return nil }

    // Output texture
    let texDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
    )
    texDesc.usage = [.shaderRead, .shaderWrite]
    guard let outputTex = device.makeTexture(descriptor: texDesc) else { return nil }

    // Pack params struct (must match RestretchParams in Metal shader)
    struct RestretchParams {
        var c0: Float
        var mb: Float
        var darkLevel: Float
        var contrast: Float
        var sharpening: Float
        var width: Int32
        var height: Int32
        var channelCount: Int32
        var saturation: Float
        var c0_g: Float
        var mb_g: Float
        var c0_b: Float
        var mb_b: Float
    }

    var params = RestretchParams(
        c0: c0, mb: mb,
        darkLevel: darkLevel, contrast: contrast, sharpening: sharpening,
        width: Int32(width), height: Int32(height), channelCount: Int32(channelCount),
        saturation: saturation,
        c0_g: stfG.c0, mb_g: stfG.mb,
        c0_b: stfB.c0, mb_b: stfB.mb
    )

    guard let library = device.makeDefaultLibrary(),
          let function = library.makeFunction(name: "restretch_float"),
          let pipeline = try? device.makeComputePipelineState(function: function),
          let queue = device.makeCommandQueue(),
          let cmdBuf = queue.makeCommandBuffer(),
          let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(inputBuffer, offset: 0, index: 0)
    encoder.setTexture(outputTex, index: 0)
    encoder.setBytes(&params, length: MemoryLayout<RestretchParams>.size, index: 1)

    let tg = MTLSize(width: 32, height: 32, depth: 1)
    let grid = MTLSize(width: (width + 31) / 32, height: (height + 31) / 32, depth: 1)
    encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    encoder.endEncoding()
    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()

    // Helper: create a scratch texture matching output dimensions
    func makeScratchTex() -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: td)
    }

    var currentResult: MTLTexture = outputTex

    // ── Pass A: Two-pass denoise (bilateral + chrominance) ──
    if denoise > 0.01 {
        let effectiveStrength = min(denoise, 1.0)

        struct DenoiseParams {
            var strength: Float; var width: Int32; var height: Int32; var radius: Int32
        }

        if let denoiseFunc = library.makeFunction(name: "bilateral_denoise"),
           let denoisePipe = try? device.makeComputePipelineState(function: denoiseFunc),
           let chromaFunc = library.makeFunction(name: "chroma_denoise"),
           let chromaPipe = try? device.makeComputePipelineState(function: chromaFunc),
           let texA = makeScratchTex(), let texB = makeScratchTex() {

            // Bilateral (pixel noise)
            let lumRadius: Int32 = denoise > 1.0 ? 7 : (denoise > 0.5 ? 5 : 3)
            var p1 = DenoiseParams(strength: effectiveStrength,
                                   width: Int32(width), height: Int32(height), radius: lumRadius)
            if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                e.setComputePipelineState(denoisePipe)
                e.setTexture(currentResult, index: 0); e.setTexture(texA, index: 1)
                e.setBytes(&p1, length: MemoryLayout<DenoiseParams>.size, index: 0)
                e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
            }

            // Chrominance (color patches)
            let chromaRadius: Int32 = denoise > 1.0 ? 7 : 5
            var p2 = DenoiseParams(strength: min(denoise * 1.5, 1.0),
                                   width: Int32(width), height: Int32(height), radius: chromaRadius)
            if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                e.setComputePipelineState(chromaPipe)
                e.setTexture(texA, index: 0); e.setTexture(texB, index: 1)
                e.setBytes(&p2, length: MemoryLayout<DenoiseParams>.size, index: 0)
                e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
            }
            currentResult = texB
        }
    }

    // ── Pass B: Deconvolution (USM or Richardson-Lucy) ──
    if deconvolve > 0.01 {
        if useRL {
            // Richardson-Lucy iterative deconvolution
            // PSF sigma scales with slider: 0.8–2.0 pixels (typical seeing blur)
            // Iterations scale: 5–20 based on strength
            struct RLParams {
                var psfSigma: Float; var psfRadius: Int32; var width: Int32; var height: Int32
            }

            let psfSigma: Float = 0.8 + deconvolve * 0.6  // 0.8–2.0
            let psfRadius = Int32(ceil(3.0 * psfSigma))
            let iterations = min(20, max(5, Int(deconvolve * 10)))

            if let ratioFunc = library.makeFunction(name: "rl_compute_ratio"),
               let ratioPipe = try? device.makeComputePipelineState(function: ratioFunc),
               let updateFunc = library.makeFunction(name: "rl_update_estimate"),
               let updatePipe = try? device.makeComputePipelineState(function: updateFunc),
               let ratioTex = makeScratchTex(),
               let estA = makeScratchTex(), let estB = makeScratchTex() {

                var rlp = RLParams(psfSigma: psfSigma, psfRadius: psfRadius,
                                   width: Int32(width), height: Int32(height))

                // Copy current result to initial estimate
                if let cb = queue.makeCommandBuffer(), let enc = cb.makeBlitCommandEncoder() {
                    enc.copy(from: currentResult, to: estA)
                    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                }

                let observed = currentResult
                var curEst = estA
                var newEst = estB

                for _ in 0..<iterations {
                    // Step 1: ratio = observed / convolve(estimate, PSF)
                    if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                        e.setComputePipelineState(ratioPipe)
                        e.setTexture(observed, index: 0)
                        e.setTexture(curEst, index: 1)
                        e.setTexture(ratioTex, index: 2)
                        e.setBytes(&rlp, length: MemoryLayout<RLParams>.size, index: 0)
                        e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                        cb.commit(); cb.waitUntilCompleted()
                    }
                    // Step 2: estimate *= convolve(ratio, PSF)
                    if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                        e.setComputePipelineState(updatePipe)
                        e.setTexture(curEst, index: 0)
                        e.setTexture(ratioTex, index: 1)
                        e.setTexture(newEst, index: 2)
                        e.setBytes(&rlp, length: MemoryLayout<RLParams>.size, index: 0)
                        e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                        cb.commit(); cb.waitUntilCompleted()
                    }
                    swap(&curEst, &newEst)
                }
                currentResult = curEst
            }
        } else {
            // Multi-scale unsharp mask (fast approximation)
            struct SharpenParams {
                var amount: Float; var radius: Float; var width: Int32; var height: Int32
            }

            if let sharpFunc = library.makeFunction(name: "unsharp_mask_lum"),
               let sharpPipe = try? device.makeComputePipelineState(function: sharpFunc),
               let pingTex = makeScratchTex(), let pongTex = makeScratchTex() {

                let scales: [(radius: Float, factor: Float)] = [
                    (1.5, 1.0), (3.0, 0.6), (5.0, 0.3)
                ]
                var src = currentResult
                var dst = pingTex

                for (i, scale) in scales.enumerated() {
                    var sp = SharpenParams(amount: deconvolve * scale.factor, radius: scale.radius,
                                           width: Int32(width), height: Int32(height))
                    if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                        e.setComputePipelineState(sharpPipe)
                        e.setTexture(src, index: 0); e.setTexture(dst, index: 1)
                        e.setBytes(&sp, length: MemoryLayout<SharpenParams>.size, index: 0)
                        e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                        cb.commit(); cb.waitUntilCompleted()
                    }
                    if i < scales.count - 1 {
                        src = dst; dst = (src === pingTex) ? pongTex : pingTex
                    }
                }
                currentResult = dst
            }
        }
    }

    return currentResult
}

// Small cross shape for marking detected stars in the mini preview
struct StarCrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX, cy = rect.midY
        let half = min(rect.width, rect.height) / 2
        path.move(to: CGPoint(x: cx - half, y: cy))
        path.addLine(to: CGPoint(x: cx + half, y: cy))
        path.move(to: CGPoint(x: cx, y: cy - half))
        path.addLine(to: CGPoint(x: cx, y: cy + half))
        return path
    }
}

// Zoomable MTKView for Quick Stack result: Photoshop-style click-drag zoom,
// scroll-wheel pan, trackpad pinch, double-click reset to fit.
class ZoomableTextureMTKView: MTKView {
    var textureCoordinator: ZoomableMetalTextureView.Coordinator?

    // Zoom state (self-contained, no dependency on MetalRenderer)
    var zoomScale: CGFloat = 1.0
    var panOffset: CGPoint = .zero
    var imageWidth: Int = 0
    var imageHeight: Int = 0

    private var isZoomDragging = false
    private var zoomAnchorView: NSPoint = .zero
    private var zoomStartScale: CGFloat = 1.0
    private var zoomStartPan: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    // Fit scale: how much to scale image to fit the view
    func fitScale() -> CGFloat {
        guard imageWidth > 0, imageHeight > 0 else { return 1.0 }
        let vw = bounds.width
        let vh = bounds.height
        guard vw > 0, vh > 0 else { return 1.0 }
        return min(vw / CGFloat(imageWidth), vh / CGFloat(imageHeight))
    }

    func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
    }

    // MARK: - Photoshop-style click-drag zoom

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetZoom()
            needsDisplay = true
            return
        }
        isZoomDragging = true
        zoomAnchorView = convert(event.locationInWindow, from: nil)
        zoomStartScale = zoomScale
        zoomStartPan = panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard isZoomDragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - zoomAnchorView.x

        // Horizontal drag: right = zoom in, left = zoom out (~200px = 2x)
        let zoomFactor = pow(2.0, dx / 200.0)
        let newScale = max(0.1, min(50.0, zoomStartScale * zoomFactor))

        let viewBounds = bounds.size
        let baseFit = fitScale()
        guard baseFit > 0 else { return }

        let oldEffective = baseFit * zoomStartScale
        let newEffective = baseFit * newScale

        let relX = zoomAnchorView.x - viewBounds.width / 2.0
        let relY = zoomAnchorView.y - viewBounds.height / 2.0

        let imgX = (relX - zoomStartPan.x) / oldEffective
        let imgY = (relY + zoomStartPan.y) / oldEffective

        panOffset.x = relX - imgX * newEffective
        panOffset.y = -(relY - imgY * newEffective)
        zoomScale = newScale

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isZoomDragging = false
    }

    // Scroll wheel: pan when zoomed in
    override func scrollWheel(with event: NSEvent) {
        guard zoomScale > 1.01 else {
            super.scrollWheel(with: event)
            return
        }
        panOffset.x += event.scrollingDeltaX
        panOffset.y += event.scrollingDeltaY
        needsDisplay = true
    }

    // Trackpad pinch-to-zoom
    override func magnify(with event: NSEvent) {
        let mouseInView = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + event.magnification
        let oldScale = zoomScale
        let newScale = max(0.1, min(50.0, oldScale * factor))

        let viewBounds = bounds.size
        let baseFit = fitScale()
        guard baseFit > 0 else { return }

        let oldEffective = baseFit * oldScale
        let newEffective = baseFit * newScale

        let relX = mouseInView.x - viewBounds.width / 2.0
        let relY = mouseInView.y - viewBounds.height / 2.0

        let imgX = (relX - panOffset.x) / oldEffective
        let imgY = (relY + panOffset.y) / oldEffective

        panOffset.x = relX - imgX * newEffective
        panOffset.y = -(relY - imgY * newEffective)
        zoomScale = newScale

        needsDisplay = true
    }
}

// SwiftUI wrapper for the zoomable texture view (used in Quick Stack result window)
struct ZoomableMetalTextureView: NSViewRepresentable {
    let texture: MTLTexture

    func makeNSView(context: Context) -> ZoomableTextureMTKView {
        let view = ZoomableTextureMTKView()
        view.device = texture.device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.textureCoordinator = context.coordinator
        view.imageWidth = texture.width
        view.imageHeight = texture.height
        return view
    }

    func updateNSView(_ mtkView: ZoomableTextureMTKView, context: Context) {
        context.coordinator.texture = texture
        mtkView.imageWidth = texture.width
        mtkView.imageHeight = texture.height
        mtkView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture
        private var renderPipeline: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        private var commandQueue: MTLCommandQueue?

        init(texture: MTLTexture) {
            self.texture = texture
            super.init()

            let device = texture.device
            commandQueue = device.makeCommandQueue()

            if let library = device.makeDefaultLibrary(),
               let vertexFunc = library.makeFunction(name: "quad_vertex"),
               let fragmentFunc = library.makeFunction(name: "quad_fragment") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFunc
                desc.fragmentFunction = fragmentFunc
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
            }

            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: samplerDesc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let zoomView = view as? ZoomableTextureMTKView,
                  let drawable = view.currentDrawable,
                  let pipeline = renderPipeline,
                  let queue = commandQueue,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let samp = sampler else { return }

            let renderPassDesc = MTLRenderPassDescriptor()
            renderPassDesc.colorAttachments[0].texture = drawable.texture
            renderPassDesc.colorAttachments[0].loadAction = .clear
            renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            renderPassDesc.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
            encoder.setRenderPipelineState(pipeline)

            let dw = Float(drawable.texture.width)
            let dh = Float(drawable.texture.height)
            let tw = Float(texture.width)
            let th = Float(texture.height)

            // Fit-to-view base scale, then apply zoom + pan
            let baseFit = Float(zoomView.fitScale())
            let scale = baseFit * Float(zoomView.zoomScale)

            let ndcHW = (tw * scale) / dw
            let ndcHH = (th * scale) / dh

            // Pan offset in NDC (convert from points to drawable pixels for Retina)
            let backingScale = Float(view.window?.backingScaleFactor ?? 2.0)
            let panX = Float(zoomView.panOffset.x) * backingScale / dw * 2.0
            let panY = Float(zoomView.panOffset.y) * backingScale / dh * 2.0

            var vertices: [Float] = [
                -ndcHW + panX, -ndcHH - panY, 0.0, 1.0,
                 ndcHW + panX, -ndcHH - panY, 1.0, 1.0,
                -ndcHW + panX,  ndcHH - panY, 0.0, 0.0,
                 ndcHW + panX,  ndcHH - panY, 1.0, 0.0,
            ]

            encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samp, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// NSViewRepresentable wrapper to display a MTLTexture in SwiftUI using MTKView
struct MetalTextureView: NSViewRepresentable {
    let texture: MTLTexture

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = texture.device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.texture = texture
        mtkView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture
        private var renderPipeline: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        private var commandQueue: MTLCommandQueue?

        init(texture: MTLTexture) {
            self.texture = texture
            super.init()

            let device = texture.device
            commandQueue = device.makeCommandQueue()

            if let library = device.makeDefaultLibrary(),
               let vertexFunc = library.makeFunction(name: "quad_vertex"),
               let fragmentFunc = library.makeFunction(name: "quad_fragment") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFunc
                desc.fragmentFunction = fragmentFunc
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
            }

            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: samplerDesc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pipeline = renderPipeline,
                  let queue = commandQueue,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let samp = sampler else { return }

            let renderPassDesc = MTLRenderPassDescriptor()
            renderPassDesc.colorAttachments[0].texture = drawable.texture
            renderPassDesc.colorAttachments[0].loadAction = .clear
            renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            renderPassDesc.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
            encoder.setRenderPipelineState(pipeline)

            let dw = Float(drawable.texture.width)
            let dh = Float(drawable.texture.height)
            let tw = Float(texture.width)
            let th = Float(texture.height)

            // Fit-to-view scaling
            let scale = min(dw / tw, dh / th)
            let ndcHW = (tw * scale) / dw
            let ndcHH = (th * scale) / dh

            var vertices: [Float] = [
                -ndcHW, -ndcHH, 0.0, 1.0,
                 ndcHW, -ndcHH, 1.0, 1.0,
                -ndcHW,  ndcHH, 0.0, 0.0,
                 ndcHW,  ndcHH, 1.0, 0.0,
            ]

            encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samp, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - Quick Stack V2 Views
// These mirror QuickStackProgressView and StackResultView but use QuickStackEngineV2

struct QuickStackV2ProgressView: View {
    @ObservedObject var engine: QuickStackEngineV2
    let nightMode: Bool
    var onDismiss: () -> Void

    // Track stack start time to compute duration for benchmark
    @State private var stackStartDate = Date()

    private var fg: Color { nightMode ? .red : .primary }
    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }
    private var bg: Color { nightMode ? .black : Color(NSColor.windowBackgroundColor) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "square.3.layers.3d.down.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(fg)
                Text("LightspeedStacker")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(fg)
                Spacer()

                if engine.phase != .done && engine.phase != .failed && engine.phase != .idle {
                    Button(action: {
                        engine.cancel()
                        onDismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(fgDim)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel stacking")
                }
            }

            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 200, height: 200)

                if let texture = engine.miniPreviewTexture {
                    MetalTextureView(texture: texture)
                        .frame(width: 200, height: 200)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(nightMode ? .red : nil)
                        Text("Preparing...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }

                if engine.phase == .detecting && !engine.detectedStarPositions.isEmpty {
                    ForEach(0..<engine.detectedStarPositions.count, id: \.self) { i in
                        let pos = engine.detectedStarPositions[i]
                        StarCrossShape()
                            .stroke(Color(red: 0.3, green: 0.6, blue: 1.0), lineWidth: 1.5)
                            .frame(width: 10, height: 10)
                            .position(x: pos.x, y: pos.y)
                    }
                }
            }
            .frame(width: 200, height: 200)
            .clipped()
            .cornerRadius(4)

            Text(engine.phase.rawValue)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(fg)

            if engine.phase == .aligning || engine.phase == .stacking {
                Text("Layer \(engine.currentLayer) / \(engine.totalLayers)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(fgDim)
            }

            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .tint(nightMode ? .red : .accentColor)

            if let error = engine.errorMessage {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }

            if engine.phase == .done {
                Button(action: { openResultWindow() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                        Text("Open Result (\(engine.resultWidth)x\(engine.resultHeight))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if engine.phase == .done || engine.phase == .failed {
                Button("Close") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(fg)
            }
        }
        .padding(16)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bg.opacity(0.95))
                .shadow(radius: 8)
        )
        .onChange(of: engine.phase) { newPhase in
            if newPhase == .done {
                openResultWindow()
            }
        }
    }

    private func openResultWindow() {
        guard engine.resultTexture != nil else { return }

        let stackMs = Int(Date().timeIntervalSince(stackStartDate) * 1000)
        let resultView = StackResultViewV2(engine: engine, nightMode: nightMode, stackTimeMs: stackMs)
        let hostingView = NSHostingView(rootView: resultView)
        let maxDim: CGFloat = 1200
        let scale = min(maxDim / CGFloat(engine.resultWidth), maxDim / CGFloat(engine.resultHeight), 1.0)
        let winW = CGFloat(engine.resultWidth) * scale + 40
        let winH = CGFloat(engine.resultHeight) * scale + 80

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LightspeedStacker Result — \(engine.resultWidth)x\(engine.resultHeight)"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }
}

struct StackResultViewV2: View {
    let engine: QuickStackEngineV2
    let nightMode: Bool
    let stackTimeMs: Int
    @State private var stretchValue: Double = 0.25
    @State private var sharpening: Double = 0.0
    @State private var contrast: Double = 0.0
    @State private var darkLevel: Double = 0.0
    @State private var saturation: Double = 1.0
    @State private var linkedStretch: Bool = false
    @State private var denoise: Double = 0.0
    @State private var deconvolve: Double = 0.0
    @State private var useRL: Bool = false
    @State private var displayTexture: MTLTexture?
    @State private var savedMessage: String?
    @State private var isRendering: Bool = false
    @State private var renderTask: Task<Void, Never>?
    @StateObject private var benchmarkService = BenchmarkService()

    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let tex = displayTexture ?? engine.resultTexture {
                    ZoomableMetalTextureView(texture: tex)
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
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(nightMode ? .red : .primary)
                .help("Reset all sliders")

                resultSlider("Stretch", value: $stretchValue, range: 0.0...1.0, step: 0.01,
                             display: "\(Int(stretchValue * 100))%")
                    .help("STF auto-stretch target background level.\n0% = linear (no stretch), 25% = default, higher = brighter.")
                resultSlider("Sharp", value: $sharpening, range: -4.0...4.0, step: 0.1,
                             display: String(format: "%+.1f", sharpening))
                    .help("Unsharp mask sharpening.\nNegative = blur, 0 = off, positive = sharpen.")
                resultSlider("Contrast", value: $contrast, range: -2.0...2.0, step: 0.05,
                             display: String(format: "%+.1f", contrast))
                    .help("Contrast adjustment around midpoint.\nNegative = flatten, 0 = off, positive = increase.")
                resultSlider("Dark", value: $darkLevel, range: 0.0...1.0, step: 0.01,
                             display: String(format: "%.2f", darkLevel))
                    .help("Dark level / shadows clip.\nRaises the black point to clip faint background.")
                if engine.resultChannelCount > 1 {
                    resultSlider("Color", value: $saturation, range: 0.0...3.0, step: 0.05,
                                 display: String(format: "%.1f", saturation))
                        .help("Color saturation.\n0 = monochrome, 1.0 = natural, >1 = boosted.")
                    Toggle("Linked", isOn: $linkedStretch)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(nightMode ? .red.opacity(0.7) : .secondary)
                        .help("OFF = Balanced: per-channel background clip + shared midtone (best white balance).\nON = Linked: identical stretch for all channels (raw color ratios).")
                        .onChange(of: linkedStretch) { _ in scheduleRender() }
                }
                resultSlider("Denoise", value: $denoise, range: 0.0...2.0, step: 0.02,
                             display: denoise < 0.01 ? "Off" : String(format: "%.0f%%", denoise * 100))
                    .help("Two-pass GPU denoise: bilateral (pixel noise) + chrominance (color patches).\n0 = off, 100%+ = aggressive.")
                resultSlider("Deconv", value: $deconvolve, range: 0.0...2.0, step: 0.02,
                             display: deconvolve < 0.01 ? "Off" : String(format: "%.1f", deconvolve))
                    .help("Deconvolution sharpening to recover detail.\nUSM = multi-scale unsharp mask, RL = Richardson-Lucy iterative.")
                Toggle(useRL ? "RL" : "USM", isOn: $useRL)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(useRL ? .orange : .secondary)
                    .help("USM = Multi-scale Unsharp Mask (fast).\nRL = Richardson-Lucy deconvolution (better quality, slower).")
                    .onChange(of: useRL) { _ in scheduleRender() }
                    .frame(width: 52)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            HStack(spacing: 12) {
                Text("\(engine.resultWidth)x\(engine.resultHeight) — LightspeedStacker")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(fgDim)

                Spacer()

                // Share & Compare benchmark button — centered and prominent
                Button(action: { shareLightspeedBenchmark() }) {
                    HStack(spacing: 4) {
                        Image(systemName: benchmarkService.isUploading ? "arrow.triangle.2.circlepath" : "trophy")
                            .font(.system(size: 12))
                        Text("Share & Compare")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                            .font(.system(size: 12))
                        Text("Save PNG")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export current view as PNG file")
                if let msg = savedMessage {
                    Text(msg)
                        .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 48, alignment: .trailing)
            Slider(value: value, in: range, step: step)
                .frame(minWidth: 60, maxWidth: 100)
                .onChange(of: value.wrappedValue) { _ in scheduleRender() }
            Text(display)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 32, alignment: .leading)
        }
    }

    private func resetSliders() {
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0; saturation = 1.0; linkedStretch = false; denoise = 0.0; deconvolve = 0.0; useRL = false
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

        let tex = await Task.detached(priority: .userInitiated) {
            renderFloatToTexture(data: floatData, width: w, height: h,
                                channelCount: ch, targetBackground: target,
                                sharpening: sharp, contrast: cont, darkLevel: dark,
                                saturation: sat, linkedStretch: linked, denoise: dn, deconvolve: dc, useRL: rl, device: dev)
        }.value

        displayTexture = tex
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
        if parts.isEmpty { return "quickstack_v2_result.png" }
        let name = parts.joined(separator: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-")).inverted).joined()
        return "\(name)_v2.png"
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

// MARK: - Image Preview Window (double-click from file list)

/// Opens a single image in a floating window with stretch/contrast/saturation controls.
/// Reuses the same rendering pipeline as the stacking result window.
enum ImagePreviewWindowController {

    // Cached GPU resources for debayer (avoid recreating pipeline every time)
    private static var cachedDebayerPipeline: MTLComputePipelineState?
    private static var cachedQueue: MTLCommandQueue?
    private static let bayerMap: [String: Int] = ["RGGB": 0, "GRBG": 1, "GBRG": 2, "BGGR": 3]

    static func open(entry: ImageEntry, device: MTLDevice, nightMode: Bool, debayerEnabled: Bool) {
        let url = entry.decodingURL
        let bayerPattern = debayerEnabled ? entry.bayerPattern : nil

        // Ensure GPU resources are cached
        if cachedDebayerPipeline == nil {
            if let library = device.makeDefaultLibrary(),
               let function = library.makeFunction(name: "debayer_bilinear"),
               let pipeline = try? device.makeComputePipelineState(function: function) {
                cachedDebayerPipeline = pipeline
            }
        }
        if cachedQueue == nil { cachedQueue = device.makeCommandQueue() }

        Task.detached(priority: .userInitiated) {
            let decodeResult = ImageDecoder.decode(url: url, device: device)
            guard case .success(let decoded) = decodeResult else { return }

            // Debayer OSC if needed (uses cached pipeline — fast)
            var image = decoded
            if let pattern = bayerPattern, decoded.channelCount == 1 {
                if let debayered = debayerOnGPU(image: decoded, pattern: pattern, device: device) {
                    image = debayered
                }
            }

            // Compute STF from full-res data (matches main window exactly)
            let stfParams = STFCalculator.calculate(from: image)

            // Bin 2x + convert to float for display
            let result = binAndConvert(image: image)

            await MainActor.run {
                showWindow(floatData: result.data, width: result.width, height: result.height,
                          channelCount: result.channelCount, stfParams: stfParams,
                          filename: entry.filename, nightMode: nightMode, device: device)
            }
        }
    }

    /// Bin 2x and convert uint16 → Float in one pass. Uses vDSP where possible.
    private static func binAndConvert(image: DecodedImage) -> (data: [Float], width: Int, height: Int, channelCount: Int) {
        let w = image.width, h = image.height, ch = image.channelCount
        let ptr = image.buffer.contents().bindMemory(to: UInt16.self, capacity: w * h * ch)
        let bw = w / 2, bh = h / 2
        guard bw > 0, bh > 0 else {
            let total = w * h * ch
            var floatData = [Float](repeating: 0, count: total)
            vDSP_vfltu16(ptr, 1, &floatData, 1, vDSP_Length(total))
            return (floatData, w, h, ch)
        }

        let binnedPlane = bw * bh
        var floatData = [Float](repeating: 0, count: binnedPlane * ch)

        // Parallel bin per channel for speed
        DispatchQueue.concurrentPerform(iterations: ch) { c in
            let srcOff = c * w * h
            let dstOff = c * binnedPlane
            for by in 0..<bh {
                let sy = by * 2
                let srcRow0 = srcOff + sy * w
                let srcRow1 = srcOff + (sy + 1) * w
                for bx in 0..<bw {
                    let sx = bx * 2
                    let v = Float(ptr[srcRow0 + sx]) + Float(ptr[srcRow0 + sx + 1]) +
                            Float(ptr[srcRow1 + sx]) + Float(ptr[srcRow1 + sx + 1])
                    floatData[dstOff + by * bw + bx] = v * 0.25
                }
            }
        }
        return (floatData, bw, bh, ch)
    }

    @MainActor
    private static func showWindow(floatData: [Float], width: Int, height: Int, channelCount: Int,
                                    stfParams: [STFParams]? = nil,
                                    filename: String, nightMode: Bool, device: MTLDevice) {
        let view = ImagePreviewView(
            floatData: floatData,
            width: width, height: height, channelCount: channelCount,
            stfParams: stfParams,
            filename: filename, nightMode: nightMode, device: device
        )
        let hostingView = NSHostingView(rootView: view)

        // Fixed window size matching typical stacking result window
        let winW: CGFloat = 900
        let winH: CGFloat = 700

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = filename
        window.contentView = hostingView
        window.minSize = NSSize(width: 500, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
    }

    private static func debayerOnGPU(image: DecodedImage, pattern: String, device: MTLDevice) -> DecodedImage? {
        guard let pipeline = cachedDebayerPipeline,
              let queue = cachedQueue,
              let patternIndex = bayerMap[pattern.uppercased()] else { return nil }

        let outputSize = image.width * image.height * 3 * MemoryLayout<UInt16>.size
        guard let outputBuffer = device.makeBuffer(length: outputSize, options: .storageModeShared),
              let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        var w = Int32(image.width), h = Int32(image.height), pat = Int32(patternIndex)
        encoder.setBytes(&w, length: 4, index: 2)
        encoder.setBytes(&h, length: 4, index: 3)
        encoder.setBytes(&pat, length: 4, index: 4)
        let tg = MTLSize(width: 32, height: 32, depth: 1)
        let grid = MTLSize(width: (image.width + 31) / 32, height: (image.height + 31) / 32, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return DecodedImage(buffer: outputBuffer, width: image.width, height: image.height, channelCount: 3)
    }
}

struct ImagePreviewView: View {
    let floatData: [Float]
    let width: Int
    let height: Int
    let channelCount: Int
    let stfParams: [STFParams]?  // Pre-computed from full-res data (matches main window)
    let filename: String
    let nightMode: Bool
    let device: MTLDevice

    @State private var stretchValue: Double = 0.25
    @State private var sharpening: Double = 0.0
    @State private var contrast: Double = 0.0
    @State private var darkLevel: Double = 0.0
    @State private var saturation: Double = 1.0
    @State private var linkedStretch: Bool = false
    @State private var denoise: Double = 0.0
    @State private var deconvolve: Double = 0.0
    @State private var useRL: Bool = false
    @State private var displayTexture: MTLTexture?
    @State private var savedMessage: String?
    @State private var isRendering: Bool = false
    @State private var renderTask: Task<Void, Never>?

    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black // Ensures the image area always takes space
                if let tex = displayTexture {
                    ZoomableMetalTextureView(texture: tex)
                }
                if isRendering {
                    VStack { Spacer(); HStack { Spacer()
                        ProgressView().progressViewStyle(.circular).scaleEffect(1.2)
                            .tint(nightMode ? .red : .blue).padding(12)
                            .background(Color.black.opacity(0.6)).cornerRadius(10)
                        Spacer() }; Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            HStack(spacing: 10) {
                Button(action: resetSliders) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundColor(nightMode ? .red : .primary).help("Reset all sliders")

                resultSlider("Stretch", value: $stretchValue, range: 0.0...1.0, step: 0.01,
                             display: "\(Int(stretchValue * 100))%")
                    .help("STF auto-stretch target background level.\n0% = linear (no stretch), 25% = default, higher = brighter.")
                resultSlider("Sharp", value: $sharpening, range: -4.0...4.0, step: 0.1,
                             display: String(format: "%+.1f", sharpening))
                    .help("Unsharp mask sharpening.\nNegative = blur, 0 = off, positive = sharpen.")
                resultSlider("Contrast", value: $contrast, range: -2.0...2.0, step: 0.05,
                             display: String(format: "%+.1f", contrast))
                    .help("Contrast adjustment around midpoint.\nNegative = flatten, 0 = off, positive = increase.")
                resultSlider("Dark", value: $darkLevel, range: 0.0...1.0, step: 0.01,
                             display: String(format: "%.2f", darkLevel))
                    .help("Dark level / shadows clip.\nRaises the black point to clip faint background.")
                if channelCount > 1 {
                    resultSlider("Color", value: $saturation, range: 0.0...3.0, step: 0.05,
                                 display: String(format: "%.1f", saturation))
                        .help("Color saturation.\n0 = monochrome, 1.0 = natural, >1 = boosted.")
                    Toggle("Linked", isOn: $linkedStretch)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(fgDim)
                        .help("OFF = Balanced: per-channel background clip + shared midtone (best white balance).\nON = Linked: identical stretch for all channels (raw color ratios).")
                        .onChange(of: linkedStretch) { _ in scheduleRender() }
                }
                resultSlider("Denoise", value: $denoise, range: 0.0...2.0, step: 0.02,
                             display: denoise < 0.01 ? "Off" : String(format: "%.0f%%", denoise * 100))
                    .help("Two-pass GPU denoise: bilateral (pixel noise) + chrominance (color patches).\n0 = off, 100%+ = aggressive.")
                resultSlider("Deconv", value: $deconvolve, range: 0.0...2.0, step: 0.02,
                             display: deconvolve < 0.01 ? "Off" : String(format: "%.1f", deconvolve))
                    .help("Deconvolution sharpening to recover detail.\nUSM = multi-scale unsharp mask, RL = Richardson-Lucy iterative.")
                Toggle(useRL ? "RL" : "USM", isOn: $useRL)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(useRL ? .orange : .secondary)
                    .help("USM = Multi-scale Unsharp Mask (fast).\nRL = Richardson-Lucy deconvolution (better quality, slower).")
                    .onChange(of: useRL) { _ in scheduleRender() }
                    .frame(width: 52)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            HStack(spacing: 12) {
                Text("\(width)x\(height) — \(filename)")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(fgDim)
                Spacer()
                Button(action: saveAsPNG) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 12))
                        Text("Save PNG").font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Export current view as PNG file")
                if let msg = savedMessage {
                    Text(msg).font(.system(size: 10, design: .monospaced)).foregroundColor(.green)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(nightMode ? Color.black : Color(NSColor.windowBackgroundColor))
        }
        .background(Color.black)
        .onAppear { scheduleRender() }
    }

    private func resultSlider(_ label: String, value: Binding<Double>,
                               range: ClosedRange<Double>, step: Double, display: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(fgDim)
                .frame(width: 48, alignment: .trailing)
            Slider(value: value, in: range, step: step)
                .frame(minWidth: 60, maxWidth: 100)
                .onChange(of: value.wrappedValue) { _ in scheduleRender() }
            Text(display).font(.system(size: 10, design: .monospaced)).foregroundColor(fgDim)
                .frame(width: 32, alignment: .leading)
        }
    }

    private func resetSliders() {
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0; saturation = 1.0; linkedStretch = false; denoise = 0.0; deconvolve = 0.0; useRL = false
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

    @MainActor
    private func restretch() async {
        let w = width, h = height, ch = channelCount
        let target = Float(stretchValue), sharp = Float(sharpening)
        let cont = Float(contrast), dark = Float(darkLevel), sat = Float(saturation)
        let linked = linkedStretch
        let dn = Float(denoise)
        let dc = Float(deconvolve)
        let rl = useRL
        let dev = device, data = floatData
        let preSTF = stfParams

        let tex = await Task.detached(priority: .userInitiated) {
            renderFloatToTexture(data: data, width: w, height: h,
                                channelCount: ch, targetBackground: target,
                                sharpening: sharp, contrast: cont, darkLevel: dark,
                                saturation: sat, linkedStretch: linked, denoise: dn, deconvolve: dc, useRL: rl,
                                precomputedSTF: preSTF, device: dev)
        }.value

        displayTexture = tex
        isRendering = false
    }

    private func saveAsPNG() {
        guard let tex = displayTexture else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let baseName = (filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName)_preview.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let w = tex.width, h = tex.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&pixels, bytesPerRow: w * 4,
                     from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1)),
                     mipmapLevel: 0)
        // displayTexture is always RGBA (from renderFloatToTexture) — no swap needed
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
}

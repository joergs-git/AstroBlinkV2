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

        let resultView = StackResultView(
            engine: engine,
            nightMode: nightMode
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
    @State private var stretchValue: Double = 0.25
    @State private var sharpening: Double = 0.0
    @State private var contrast: Double = 0.0
    @State private var darkLevel: Double = 0.0
    @State private var displayTexture: MTLTexture?
    @State private var savedMessage: String?
    @State private var isRendering: Bool = false
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
                resultSlider("Sharp", value: $sharpening, range: -4.0...4.0, step: 0.1,
                             display: String(format: "%+.1f", sharpening))
                resultSlider("Contrast", value: $contrast, range: -2.0...2.0, step: 0.05,
                             display: String(format: "%+.1f", contrast))
                resultSlider("Dark", value: $darkLevel, range: 0.0...1.0, step: 0.01,
                             display: String(format: "%.2f", darkLevel))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            // Row 2: Info + save
            HStack(spacing: 12) {
                Text("\(engine.resultWidth)x\(engine.resultHeight) — Quick Stack")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(fgDim)

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
        stretchValue = 0.25
        sharpening = 0.0
        contrast = 0.0
        darkLevel = 0.0
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
        let dev = engine.device

        let tex = await Task.detached(priority: .userInitiated) {
            renderFloatToTexture(
                data: floatData, width: w, height: h,
                channelCount: ch, targetBackground: target,
                sharpening: sharp, contrast: cont, darkLevel: dark,
                device: dev
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

        // Convert BGRA to RGBA for CGImage
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = pixels[i]
            pixels[i] = pixels[i + 2]
            pixels[i + 2] = b
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
}

// Render float data to a BGRA8 texture with STF stretch + post-processing.
// Uses vDSP vectorized math for ~5-10x speedup over scalar loops.
// Post-process pipeline: stretch → dark level → contrast → sharpening (matches main app)
private func renderFloatToTexture(
    data: [Float], width: Int, height: Int,
    channelCount: Int, targetBackground: Float,
    sharpening: Float = 0, contrast: Float = 0, darkLevel: Float = 0,
    device: MTLDevice
) -> MTLTexture? {
    let planeSize = width * height
    let n = vDSP_Length(planeSize)

    // STF stats from subsampled data
    let sampleCount = min(50000, planeSize)
    let sampleStride = max(1, planeSize / sampleCount)
    var samples = [Float]()
    samples.reserveCapacity(sampleCount)
    for i in stride(from: 0, to: planeSize, by: sampleStride) {
        samples.append(data[i] / 65535.0)
    }
    vDSP_vsort(&samples, vDSP_Length(samples.count), 1)
    let median = samples[samples.count / 2]
    var devs = samples
    var negMed = -median
    vDSP_vsadd(devs, 1, &negMed, &devs, 1, vDSP_Length(devs.count))
    vDSP_vabs(devs, 1, &devs, 1, vDSP_Length(devs.count))
    vDSP_vsort(&devs, vDSP_Length(devs.count), 1)
    let mad = 1.4826 * devs[devs.count / 2]
    let c0 = max(0.0, min(1.0, median + (-1.25) * mad))

    let mb: Float
    if targetBackground <= 0.001 {
        mb = 0.5
    } else {
        let mNorm = max(0.001, min(0.999, (median - c0) / max(1.0 - c0, 0.001)))
        mb = mNorm * (1 - targetBackground) / (mNorm * (1 - 2 * targetBackground) + targetBackground)
    }

    // Vectorized MTF: (m-1)*x / ((2m-1)*x - m) with bounds at 0 and 1
    func mtfVector(_ plane: inout [Float]) {
        let mMinus1 = mb - 1.0
        let twoMMinus1 = 2.0 * mb - 1.0
        var negM = -mb

        // Numerator: (m-1) * x
        var numerator = [Float](repeating: 0, count: plane.count)
        var mm1 = mMinus1
        vDSP_vsmul(plane, 1, &mm1, &numerator, 1, vDSP_Length(plane.count))

        // Denominator: (2m-1)*x - m
        var denominator = [Float](repeating: 0, count: plane.count)
        var tmm1 = twoMMinus1
        vDSP_vsmul(plane, 1, &tmm1, &denominator, 1, vDSP_Length(plane.count))
        vDSP_vsadd(denominator, 1, &negM, &denominator, 1, vDSP_Length(plane.count))

        // Avoid division by zero: replace tiny denominators
        for i in 0..<plane.count {
            if abs(denominator[i]) < 1e-10 { denominator[i] = 1e-10 }
        }

        // result = numerator / denominator
        vDSP_vdiv(denominator, 1, numerator, 1, &plane, 1, vDSP_Length(plane.count))

        // Clamp to [0, 1]
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(plane, 1, &lo, &hi, &plane, 1, vDSP_Length(plane.count))
    }

    // Step 1: STF stretch using vDSP vectorized ops
    // Normalize: x = raw / 65535, then x = clamp((x - c0) / (1 - c0), 0, 1), then MTF
    let invScale: Float = 1.0 / 65535.0
    let rangeInv: Float = 1.0 / max(1.0 - c0, 0.001)
    let numChannels = min(channelCount, 3)

    // Allocate 3 planes (mono gets replicated)
    var planes = [[Float]](repeating: [Float](repeating: 0, count: planeSize), count: 3)

    for ch in 0..<numChannels {
        let srcOff = ch * planeSize
        // Scale to [0,1]
        var scaled = invScale
        vDSP_vsmul(Array(data[srcOff..<(srcOff + planeSize)]), 1, &scaled, &planes[ch], 1, n)
        // Subtract c0
        var negC0 = -c0
        vDSP_vsadd(planes[ch], 1, &negC0, &planes[ch], 1, n)
        // Multiply by 1/(1-c0)
        var rInv = rangeInv
        vDSP_vsmul(planes[ch], 1, &rInv, &planes[ch], 1, n)
        // Clamp [0,1]
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(planes[ch], 1, &lo, &hi, &planes[ch], 1, n)
        // Apply MTF
        mtfVector(&planes[ch])
    }

    // Mono: replicate to all 3 channels
    if channelCount == 1 {
        planes[1] = planes[0]
        planes[2] = planes[0]
    }

    // Step 2: Post-processing with vDSP (dark → contrast → sharpen)
    if darkLevel > 0.001 {
        var negDark = -darkLevel
        var inv = 1.0 / max(1.0 - darkLevel, 0.001)
        var lo: Float = 0, hi: Float = 1
        for ch in 0..<3 {
            vDSP_vsadd(planes[ch], 1, &negDark, &planes[ch], 1, n)
            vDSP_vsmul(planes[ch], 1, &inv, &planes[ch], 1, n)
            vDSP_vclip(planes[ch], 1, &lo, &hi, &planes[ch], 1, n)
        }
    }

    if abs(contrast) > 0.001 {
        let c = 1.0 + contrast
        var negHalf: Float = -0.5
        var half: Float = 0.5
        var cMul = c
        var lo: Float = 0, hi: Float = 1
        for ch in 0..<3 {
            vDSP_vsadd(planes[ch], 1, &negHalf, &planes[ch], 1, n)
            vDSP_vsmul(planes[ch], 1, &cMul, &planes[ch], 1, n)
            vDSP_vsadd(planes[ch], 1, &half, &planes[ch], 1, n)
            vDSP_vclip(planes[ch], 1, &lo, &hi, &planes[ch], 1, n)
        }
    }

    if abs(sharpening) > 0.001 {
        // 3x3 unsharp mask using pointer-offset vDSP for vectorized speed
        let innerStart = width        // skip first row
        let innerCount = vDSP_Length(planeSize - 2 * width)

        for ch in 0..<3 {
            let original = planes[ch]
            var blur = [Float](repeating: 0, count: planeSize)
            var detail = [Float](repeating: 0, count: planeSize)

            original.withUnsafeBufferPointer { origBuf in
                let origPtr = origBuf.baseAddress!
                blur.withUnsafeMutableBufferPointer { blurBuf in
                    let blurPtr = blurBuf.baseAddress!
                    // blur = top + bottom neighbors
                    vDSP_vadd(origPtr, 1,
                              origPtr + 2 * width, 1,
                              blurPtr + innerStart, 1, innerCount)
                    // + left neighbor
                    var temp = [Float](repeating: 0, count: planeSize)
                    temp.withUnsafeMutableBufferPointer { tmpBuf in
                        vDSP_vadd(blurPtr + innerStart, 1,
                                  origPtr + innerStart - 1, 1,
                                  tmpBuf.baseAddress! + innerStart, 1, innerCount)
                        // + right neighbor
                        vDSP_vadd(tmpBuf.baseAddress! + innerStart, 1,
                                  origPtr + innerStart + 1, 1,
                                  blurPtr + innerStart, 1, innerCount)
                    }
                    // * 0.25 to get average
                    var quarter: Float = 0.25
                    vDSP_vsmul(blurPtr + innerStart, 1, &quarter,
                               blurPtr + innerStart, 1, innerCount)

                    // detail = original - blur
                    detail.withUnsafeMutableBufferPointer { detBuf in
                        vDSP_vsub(blurPtr + innerStart, 1,
                                  origPtr + innerStart, 1,
                                  detBuf.baseAddress! + innerStart, 1, innerCount)
                        // result = original + sharpening * detail
                        var sharpAmt = sharpening
                        planes[ch].withUnsafeMutableBufferPointer { planeBuf in
                            vDSP_vsma(detBuf.baseAddress! + innerStart, 1, &sharpAmt,
                                      origPtr + innerStart, 1,
                                      planeBuf.baseAddress! + innerStart, 1, innerCount)
                        }
                    }
                }
            }

            // Preserve edge pixels (first/last row, first/last column)
            for i in 0..<width { planes[ch][i] = original[i] }
            for i in (planeSize - width)..<planeSize { planes[ch][i] = original[i] }
            for y in 1..<(height - 1) {
                planes[ch][y * width] = original[y * width]
                planes[ch][y * width + width - 1] = original[y * width + width - 1]
            }

            var lo: Float = 0, hi: Float = 1
            vDSP_vclip(planes[ch], 1, &lo, &hi, &planes[ch], 1, n)
        }
    }

    // Step 3: Convert 3 float planes to interleaved BGRA8 using vDSP
    var pixels = [UInt8](repeating: 255, count: planeSize * 4) // alpha = 255
    var scaleTo255: Float = 255.0
    var rScaled = [Float](repeating: 0, count: planeSize)
    var gScaled = [Float](repeating: 0, count: planeSize)
    var bScaled = [Float](repeating: 0, count: planeSize)
    vDSP_vsmul(planes[0], 1, &scaleTo255, &rScaled, 1, n)
    vDSP_vsmul(planes[1], 1, &scaleTo255, &gScaled, 1, n)
    vDSP_vsmul(planes[2], 1, &scaleTo255, &bScaled, 1, n)

    // Interleave to BGRA (still needs per-pixel write due to interleaving)
    for idx in 0..<planeSize {
        let outIdx = idx * 4
        pixels[outIdx]     = UInt8(bScaled[idx])  // B
        pixels[outIdx + 1] = UInt8(gScaled[idx])  // G
        pixels[outIdx + 2] = UInt8(rScaled[idx])  // R
        // alpha already 255
    }

    let texDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    texDesc.usage = [.shaderRead]
    guard let tex = device.makeTexture(descriptor: texDesc) else { return nil }
    tex.replace(
        region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
        mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4
    )
    return tex
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

        let resultView = StackResultViewV2(engine: engine, nightMode: nightMode)
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
    @State private var stretchValue: Double = 0.25
    @State private var sharpening: Double = 0.0
    @State private var contrast: Double = 0.0
    @State private var darkLevel: Double = 0.0
    @State private var displayTexture: MTLTexture?
    @State private var savedMessage: String?
    @State private var isRendering: Bool = false
    @State private var renderTask: Task<Void, Never>?

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
                resultSlider("Sharp", value: $sharpening, range: -4.0...4.0, step: 0.1,
                             display: String(format: "%+.1f", sharpening))
                resultSlider("Contrast", value: $contrast, range: -2.0...2.0, step: 0.05,
                             display: String(format: "%+.1f", contrast))
                resultSlider("Dark", value: $darkLevel, range: 0.0...1.0, step: 0.01,
                             display: String(format: "%.2f", darkLevel))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            HStack(spacing: 12) {
                Text("\(engine.resultWidth)x\(engine.resultHeight) — LightspeedStacker")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(fgDim)
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
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0
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
        let cont = Float(contrast), dark = Float(darkLevel)
        let dev = engine.device

        let tex = await Task.detached(priority: .userInitiated) {
            renderFloatToTexture(data: floatData, width: w, height: h,
                                channelCount: ch, targetBackground: target,
                                sharpening: sharp, contrast: cont, darkLevel: dark,
                                device: dev)
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
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = pixels[i]; pixels[i] = pixels[i + 2]; pixels[i + 2] = b
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
}

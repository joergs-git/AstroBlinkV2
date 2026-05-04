// Image Preview Window — opens a single frame in a floating window with
// stretch/contrast/saturation controls. Triggered by double-click in the
// main file list. Reuses the same Metal rendering pipeline as stacking results.
import SwiftUI
import AppKit
import Metal
import MetalKit
import Accelerate

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
    static func binAndConvert(image: DecodedImage) -> (data: [Float], width: Int, height: Int, channelCount: Int) {
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
        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let view = ImagePreviewView(
            floatData: floatData,
            width: width, height: height, channelCount: channelCount,
            stfParams: stfParams,
            filename: filename, nightMode: nightMode, device: device
        )
        let hostingView = NSHostingView(rootView: view.environment(\.fontScale, savedScale))

        // Fixed window size matching typical stacking result window
        let winW: CGFloat = 1100
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

    static func debayerOnGPU(image: DecodedImage, pattern: String, device: MTLDevice) -> DecodedImage? {
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

    @Environment(\.fontScale) private var fontScale
    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

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
                    Image(systemName: "arrow.counterclockwise").font(.system(size: fs(12), weight: .medium))
                }
                .buttonStyle(.plain).foregroundColor(nightMode ? .red : .primary).help("Reset all sliders")

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
                if channelCount > 1 {
                    resultSlider("Color", value: $saturation, range: 0.0...3.0, step: 0.05,
                                 display: String(format: "%.1f", saturation))
                        .help("Color saturation.\n0 = monochrome, 1.0 = natural, >1 = boosted.")
                    Toggle("Linked", isOn: $linkedStretch)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(fgDim)
                        .help("OFF = Balanced: per-channel background clip + shared midtone (best white balance).\nON = Linked: identical stretch for all channels (raw color ratios).")
                        .onChange(of: linkedStretch) { scheduleRender() }
                }
                resultSlider("Denoise", value: $denoise, range: 0.0...2.0, step: 0.02,
                             display: denoise < 0.01 ? "Off" : String(format: "%.0f%%", denoise * 100))
                    .help("Two-pass GPU denoise: bilateral (pixel noise) + chrominance (color patches).\n0 = off, 100%+ = aggressive.")
                resultSlider("Deconv", value: $deconvolve, range: 0.0...2.0, step: 0.02,
                             display: deconvolve < 0.01 ? "Off" : String(format: "%.1f", deconvolve))
                    .help("Deconvolution sharpening to recover detail.\nUSM = multi-scale unsharp mask, RL = Richardson-Lucy iterative.")
                Toggle(useRL ? "RL" : "USM", isOn: $useRL)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                    .foregroundColor(useRL ? .orange : .secondary)
                    .help("USM = Multi-scale Unsharp Mask (fast).\nRL = Richardson-Lucy deconvolution (better quality, slower).")
                    .onChange(of: useRL) { scheduleRender() }
                    .frame(width: 52)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            HStack(spacing: 12) {
                Text("\(width)x\(height) — \(filename)")
                    .font(.system(size: fs(11), design: .monospaced)).foregroundColor(fgDim)
                Spacer()
                Button(action: saveAsPNG) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: fs(12)))
                        Text("Save PNG").font(.system(size: fs(11), weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Export current view as PNG file")
                if let msg = savedMessage {
                    Text(msg).font(.system(size: fs(10), design: .monospaced)).foregroundColor(.green)
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
            Text(label).font(.system(size: fs(10), design: .monospaced)).foregroundColor(fgDim)
                .frame(width: 55, alignment: .trailing)
            Slider(value: value, in: range, step: step)
                .frame(minWidth: 80, maxWidth: .infinity)
                .onChange(of: value.wrappedValue) { scheduleRender() }
            Text(display).font(.system(size: fs(10), design: .monospaced)).foregroundColor(fgDim)
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

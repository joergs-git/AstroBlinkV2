// v4.4.0 — Color Combine UI
// Setup panel (inline overlay) + result window for mono filter → RGB color combine.
// Reuses renderFloatToTexture and ZoomableMetalTextureView from QuickStackWindow.

import SwiftUI
import MetalKit
import Accelerate
import UniformTypeIdentifiers

// MARK: - Setup Panel (inline overlay, like QuickStack progress)

struct ColorCombineSetupView: View {
    @ObservedObject var engine: ColorCombineEngine
    let nightMode: Bool
    var onDismiss: () -> Void
    var debayerEnabled: Bool

    @Environment(\.fontScale) private var fontScale
    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

    private var fg: Color { nightMode ? .red : .primary }
    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }
    private var bg: Color { nightMode ? .black : Color(NSColor.windowBackgroundColor) }

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: fs(16), weight: .semibold))
                    .foregroundColor(fg)
                Text("Color Combine")
                    .font(.system(size: fs(14), weight: .semibold, design: .monospaced))
                    .foregroundColor(fg)
                Spacer()
                Button(action: {
                    engine.cancel()
                    onDismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: fs(14)))
                        .foregroundColor(fgDim)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            // Detected filters
            if !engine.availableFilters.isEmpty {
                HStack(spacing: 6) {
                    Text("Filters:")
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(fgDim)
                    ForEach(engine.availableFilters) { info in
                        Text("\(info.display)(\(info.count))")
                            .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                            .foregroundColor(fg)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2)))
                    }
                    Spacer()
                }
            }

            // Preset picker
            if engine.phase == .idle || engine.phase == .setup {
                HStack(spacing: 6) {
                    Text("Preset:")
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(fgDim)
                    Picker("", selection: $engine.selectedPreset) {
                        ForEach(ColorCombineEngine.ChannelPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .controlSize(.small)
                    .onChange(of: engine.selectedPreset) { _, newPreset in
                        engine.channelMapping = ColorCombineEngine.mapping(for: newPreset)
                    }
                    Spacer()
                }

                // Channel assignments
                let filterNames = [""] + engine.availableFilters.map { $0.canonical }
                channelRow("R", color: .red, sources: $engine.channelMapping.red, filters: filterNames)
                channelRow("G", color: .green, sources: $engine.channelMapping.green, filters: filterNames)
                channelRow("B", color: .blue, sources: $engine.channelMapping.blue, filters: filterNames)

                // Luminance
                HStack(spacing: 4) {
                    Toggle("L:", isOn: Binding(
                        get: { !engine.channelMapping.luminanceFilter.isEmpty },
                        set: { enabled in
                            engine.channelMapping.luminanceFilter = enabled
                                ? (engine.availableFilters.first(where: { $0.canonical == "L" })?.canonical ?? "")
                                : ""
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: fs(10), weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                    if !engine.channelMapping.luminanceFilter.isEmpty {
                        Picker("", selection: $engine.channelMapping.luminanceFilter) {
                            ForEach(filterNames, id: \.self) { name in
                                Text(name.isEmpty ? "None" : name).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 70)
                        .controlSize(.mini)

                        Text("Blend:")
                            .font(.system(size: fs(9), design: .monospaced))
                            .foregroundColor(fgDim)
                        Slider(value: $engine.channelMapping.luminanceBlend, in: 0...1, step: 0.05)
                            .frame(width: 60)
                        Text(String(format: "%.0f%%", engine.channelMapping.luminanceBlend * 100))
                            .font(.system(size: fs(9), design: .monospaced))
                            .foregroundColor(fgDim)
                            .frame(width: 28)
                    }
                    Spacer()
                }

                // Start button
                Button(action: { engine.startCombine(debayerEnabled: debayerEnabled) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: fs(10)))
                        Text("Start Combine")
                            .font(.system(size: fs(12), weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(engine.availableFilters.count < 2)
            }

            // Progress during stacking
            if engine.phase == .stacking || engine.phase == .combining {
                VStack(spacing: 6) {
                    Text(engine.phase == .stacking
                         ? "Stacking \(engine.currentFilter)... (\(engine.filtersDone + 1)/\(engine.filtersTotal))"
                         : engine.phase.rawValue)
                        .font(.system(size: fs(11), weight: .medium, design: .monospaced))
                        .foregroundColor(fg)

                    ProgressView(value: engine.progress)
                        .progressViewStyle(.linear)
                        .tint(nightMode ? .red : .accentColor)
                }
            }

            // Error
            if let error = engine.errorMessage {
                Text(error)
                    .font(.system(size: fs(11), design: .monospaced))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            // Done: open result
            if engine.phase == .done {
                Button(action: { openResultWindow() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: fs(12)))
                        Text("Open Color Result (\(engine.resultWidth)x\(engine.resultHeight))")
                            .font(.system(size: fs(12), weight: .medium, design: .monospaced))
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
        .padding(12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(bg.opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 8)
        )
        .onChange(of: engine.phase) { _, newPhase in
            if newPhase == .done {
                openResultWindow()
            }
        }
    }

    // MARK: - Channel Row Helper

    private func channelRow(_ label: String, color: Color, sources: Binding<[ColorCombineEngine.ChannelSource]>, filters: [String]) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: fs(11), weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 14, alignment: .trailing)

            // Primary source picker
            Picker("", selection: Binding(
                get: { sources.wrappedValue.first?.filterName ?? "" },
                set: { newFilter in
                    if sources.wrappedValue.isEmpty {
                        sources.wrappedValue = [ColorCombineEngine.ChannelSource(filterName: newFilter, weight: 1.0)]
                    } else {
                        sources.wrappedValue[0].filterName = newFilter
                    }
                    engine.selectedPreset = .custom
                }
            )) {
                ForEach(filters, id: \.self) { name in
                    Text(name.isEmpty ? "None" : name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 70)
            .controlSize(.mini)

            // Weight slider
            let weightBinding = Binding<Float>(
                get: { sources.wrappedValue.first?.weight ?? 1.0 },
                set: { newWeight in
                    if !sources.wrappedValue.isEmpty {
                        sources.wrappedValue[0].weight = newWeight
                    }
                }
            )
            Slider(value: weightBinding, in: 0...3.0, step: 0.05)
                .frame(width: 80)
            Text(String(format: "%.2f", weightBinding.wrappedValue))
                .font(.system(size: fs(9), design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 28, alignment: .leading)

            Spacer()
        }
    }

    // MARK: - Result Window

    private func openResultWindow() {
        guard engine.resultFloatData != nil else { return }

        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let resultView = ColorCombineResultView(
            engine: engine,
            nightMode: nightMode
        )

        let hostingView = NSHostingView(rootView: resultView.environment(\.fontScale, savedScale))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 900, height: 400)
        window.contentView = hostingView
        window.title = "Color Combine — \(engine.selectedPreset.rawValue) (\(engine.resultWidth)x\(engine.resultHeight))"
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Result View (floating window with weight + post-processing sliders)

struct ColorCombineResultView: View {
    let engine: ColorCombineEngine
    let nightMode: Bool

    @Environment(\.fontScale) private var fontScale
    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

    // Per-channel weights (live recombine)
    @State private var redWeight: Float = 1.0
    @State private var greenWeight: Float = 1.0
    @State private var blueWeight: Float = 1.0
    @State private var lumBlend: Float = 0.5

    // Post-processing sliders (same as StackResultViewV2)
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
            // Main image display
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

            // Channel weight sliders (trigger recombine)
            HStack(spacing: 8) {
                Text("Weights:")
                    .font(.system(size: fs(10), weight: .bold, design: .monospaced))
                    .foregroundColor(fgDim)
                channelWeightSlider("R", color: .red, value: $redWeight)
                channelWeightSlider("G", color: .green, value: $greenWeight)
                channelWeightSlider("B", color: .blue, value: $blueWeight)

                if !engine.channelMapping.luminanceFilter.isEmpty {
                    Divider().frame(height: 12)
                    HStack(spacing: 2) {
                        Text("L:")
                            .font(.system(size: fs(10), weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Slider(value: $lumBlend, in: Float(0)...Float(1), step: Float(0.05),
                               onEditingChanged: { editing in
                            if !editing { scheduleRecombine() }
                        })
                            .frame(width: 60)
                        Text(String(format: "%.0f%%", lumBlend * 100))
                            .font(.system(size: fs(9), design: .monospaced))
                            .foregroundColor(fgDim)
                            .frame(width: 28)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.08, green: 0, blue: 0) : Color(NSColor.controlBackgroundColor).opacity(0.5))

            // Post-processing sliders
            HStack(spacing: 10) {
                Button(action: resetSliders) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: fs(12), weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(nightMode ? .red : .primary)
                .help("Reset all sliders")

                resultSlider("Stretch", value: $stretchValue, range: 0.0...1.0, step: 0.01,
                             display: "\(Int(stretchValue * 100))%")
                resultSlider("Dark", value: $darkLevel, range: 0.0...1.0, step: 0.01,
                             display: String(format: "%.2f", darkLevel))
                resultSlider("Sharp", value: $sharpening, range: -4.0...4.0, step: 0.1,
                             display: String(format: "%+.1f", sharpening))
                resultSlider("Contrast", value: $contrast, range: -2.0...2.0, step: 0.05,
                             display: String(format: "%+.1f", contrast))
                resultSlider("Color", value: $saturation, range: 0.0...3.0, step: 0.05,
                             display: String(format: "%.1f", saturation))
                Toggle("Linked", isOn: $linkedStretch)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: fs(10), design: .monospaced))
                    .foregroundColor(fgDim)
                    .onChange(of: linkedStretch) { scheduleRender() }
                resultSlider("Denoise", value: $denoise, range: 0.0...2.0, step: 0.02,
                             display: denoise < 0.01 ? "Off" : String(format: "%.0f%%", denoise * 100))
                resultSlider("Deconv", value: $deconvolve, range: 0.0...2.0, step: 0.02,
                             display: deconvolve < 0.01 ? "Off" : String(format: "%.1f", deconvolve))
                Toggle(useRL ? "RL" : "USM", isOn: $useRL)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                    .foregroundColor(useRL ? .orange : .secondary)
                    .onChange(of: useRL) { scheduleRender() }
                    .frame(width: 52)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(nightMode ? Color(red: 0.06, green: 0, blue: 0) : Color(NSColor.underPageBackgroundColor))

            // Bottom bar
            HStack(spacing: 12) {
                Text("\(engine.resultWidth)x\(engine.resultHeight) — Color Combine (\(engine.selectedPreset.rawValue))")
                    .font(.system(size: fs(11), design: .monospaced))
                    .foregroundColor(fgDim)

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
        .onAppear {
            // Initialize weights from engine mapping
            redWeight = engine.channelMapping.red.first?.weight ?? 1.0
            greenWeight = engine.channelMapping.green.first?.weight ?? 1.0
            blueWeight = engine.channelMapping.blue.first?.weight ?? 1.0
            lumBlend = engine.channelMapping.luminanceBlend
            scheduleRender()
        }
    }

    // MARK: - Channel Weight Slider

    private func channelWeightSlider(_ label: String, color: Color, value: Binding<Float>) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: fs(10), weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Slider(value: value, in: Float(0)...Float(3.0), step: Float(0.05),
                   onEditingChanged: { editing in
                if !editing { scheduleRecombine() }
            })
                .frame(width: 60)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: fs(9), design: .monospaced))
                .foregroundColor(fgDim)
                .frame(width: 28)
        }
    }

    // MARK: - Slider Helper

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

    // MARK: - Rendering

    private func scheduleRecombine() {
        // Update engine mapping with current weights and recombine
        if !engine.channelMapping.red.isEmpty {
            engine.channelMapping.red[0].weight = redWeight
        }
        if !engine.channelMapping.green.isEmpty {
            engine.channelMapping.green[0].weight = greenWeight
        }
        if !engine.channelMapping.blue.isEmpty {
            engine.channelMapping.blue[0].weight = blueWeight
        }
        engine.channelMapping.luminanceBlend = lumBlend

        // Recombine channels (fast CPU pass, <100ms)
        engine.recombineWithWeights()

        // Then render with current post-processing settings
        scheduleRender()
    }

    private func scheduleRender() {
        renderTask?.cancel()
        isRendering = true

        let dev = engine.device
        let target = Float(stretchValue)
        let sharp = Float(sharpening)
        let cont = Float(contrast)
        let dark = Float(darkLevel)
        let sat = Float(saturation)
        let linked = linkedStretch
        let dn = Float(denoise)
        let dc = Float(deconvolve)
        let rl = useRL
        let w = engine.resultWidth
        let h = engine.resultHeight

        renderTask = Task {
            guard let floatData = engine.resultFloatData else { isRendering = false; return }

            let tex = await Task.detached(priority: .userInitiated) {
                renderFloatToTexture(
                    data: floatData, width: w, height: h,
                    channelCount: 3, targetBackground: target,
                    sharpening: sharp, contrast: cont, darkLevel: dark,
                    saturation: sat, linkedStretch: linked,
                    denoise: dn, deconvolve: dc, useRL: rl,
                    device: dev
                )
            }.value

            if !Task.isCancelled {
                displayTexture = tex
                isRendering = false
            }
        }
    }

    private func resetSliders() {
        stretchValue = 0.25; sharpening = 0.0; contrast = 0.0; darkLevel = 0.0
        saturation = 1.0; linkedStretch = false; denoise = 0.0; deconvolve = 0.0; useRL = false
        scheduleRender()
    }

    // MARK: - Save PNG

    private func saveAsPNG() {
        guard let tex = displayTexture ?? engine.resultTexture else { return }
        let w = tex.width, h = tex.height

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ColorCombine_\(engine.selectedPreset.rawValue)_\(w)x\(h).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1))
        tex.getBytes(&pixels, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // Swap R/B if BGRA texture
        if tex.pixelFormat == .bgra8Unorm {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels.swapAt(i, i + 2)
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else { return }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }

        do {
            try pngData.write(to: url)
            savedMessage = "Saved!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { savedMessage = nil }
        } catch {
            savedMessage = "Error: \(error.localizedDescription)"
        }
    }
}

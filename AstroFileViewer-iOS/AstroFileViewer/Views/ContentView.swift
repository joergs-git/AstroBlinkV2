// v1.4.0
import SwiftUI
import MetalKit
import StoreKit

struct ContentView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @State private var showHeaders = false
    @State private var showHelp = false
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let texture = viewModel.displayTexture {
                    ZStack {
                        ZoomableImageContainer(
                            texture: texture,
                            autoRotate: viewModel.autoRotate && viewModel.isLandscapeImage,
                            onSwipeLeft: { viewModel.navigateForward() },
                            onSwipeRight: { viewModel.navigateBack() }
                        )

                        // Navigation arrows
                        HStack {
                            if viewModel.canGoBack {
                                Image(systemName: "chevron.left")
                                    .font(.title2.bold())
                                    .foregroundColor(.white.opacity(0.4))
                                    .padding(.leading, 4)
                            }
                            Spacer()
                            if viewModel.canGoForward {
                                Image(systemName: "chevron.right")
                                    .font(.title2.bold())
                                    .foregroundColor(.white.opacity(0.4))
                                    .padding(.trailing, 4)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .ignoresSafeArea()
                } else if viewModel.isLoading {
                    ProgressView("Processing...")
                        .foregroundColor(.white)
                        .tint(.white)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "star.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)

                        Text("AstroFileViewer")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text("Open a FITS or XISF file")
                            .font(.subheadline)
                            .foregroundColor(.gray)

                        Button(action: { viewModel.showFilePicker = true }) {
                            Label("Open File", systemImage: "folder")
                                .font(.headline)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }

                        // Recent files thumbnail grid
                        if !viewModel.fileHistory.isEmpty {
                            VStack(spacing: 8) {
                                Text("Recent")
                                    .font(.caption.bold())
                                    .foregroundColor(.gray)

                                LazyVGrid(columns: [
                                    GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)
                                ], spacing: 8) {
                                    ForEach(Array(viewModel.fileHistory.prefix(6).enumerated()), id: \.offset) { index, entry in
                                        Button(action: {
                                            viewModel.currentHistoryIndex = index
                                            viewModel.openFromHistoryPublic(at: index)
                                        }) {
                                            VStack(spacing: 4) {
                                                RecentThumbnail(entry: entry)
                                                    .frame(height: 70)
                                                    .cornerRadius(6)

                                                Text(entry.shortLabel)
                                                    .font(.caption2)
                                                    .foregroundColor(.gray)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            .padding(.top, 16)
                        }

                        Spacer().frame(height: 20)

                        Button(action: { showHelp = true }) {
                            Text("Help & About")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle(viewModel.filename.isEmpty ? "AstroFileViewer" : viewModel.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 12) {
                        Button(action: { viewModel.showFilePicker = true }) {
                            Image(systemName: "folder")
                        }
                        Button(action: { showHelp = true }) {
                            Image(systemName: "questionmark.circle")
                        }
                    }
                }

                if viewModel.displayTexture != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 12) {
                            // Image adjustments toggle with gradient indicator
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.showAdjustments.toggle()
                                }
                            }) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "slider.horizontal.3")
                                        .foregroundColor(viewModel.showAdjustments ? .yellow : .white)
                                    if viewModel.gradientStrength > 0 {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                            .offset(x: 6, y: -6)
                                    }
                                }
                            }

                            // Save to Photos
                            Button(action: { viewModel.saveToPhotos() }) {
                                if viewModel.isSaving {
                                    ProgressView()
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                }
                            }
                            .disabled(viewModel.isSaving)
                        }
                    }
                }

                if !viewModel.headers.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showHeaders = true }) {
                            Image(systemName: "info.circle")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Adjustments panel
                    if viewModel.showAdjustments && viewModel.displayTexture != nil {
                        AdjustmentsPanel(viewModel: viewModel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Status messages
                    VStack(spacing: 4) {
                        if !viewModel.saveMessage.isEmpty {
                            Text(viewModel.saveMessage)
                                .font(.caption.monospaced())
                                .foregroundColor(viewModel.saveMessage.starts(with: "Saved") ? .green : .orange)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.7))
                                .cornerRadius(8)
                        }
                        if viewModel.displayTexture != nil && !viewModel.showAdjustments {
                            Text(viewModel.currentImageInfo)
                                .font(.caption.monospaced())
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.6))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .sheet(isPresented: $showHeaders) {
                HeaderListView(headers: viewModel.headers, filename: viewModel.filename)
            }
            .sheet(isPresented: $showHelp) {
                HelpAboutView()
            }
            .fileImporter(
                isPresented: $viewModel.showFilePicker,
                allowedContentTypes: ViewerViewModel.supportedTypes,
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.openFile(url: url)
                }
            }
            .onAppear {
                checkForReviewPrompt()
            }
        }
    }

    private func checkForReviewPrompt() {
        let key = "launchCount"
        let count = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(count, forKey: key)
        if count == 10 || (count > 10 && count % 50 == 0) {
            requestReview()
        }
    }
}

// MARK: - Image Adjustments Panel

struct AdjustmentsPanel: View {
    @ObservedObject var viewModel: ViewerViewModel
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            // Drag handle
            Capsule()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 36, height: 4)
                .padding(.top, 2)

            // Stretch strength slider
            SliderRow(icon: "sun.min", label: "Stretch", value: $viewModel.stretchStrength,
                      range: 0.0...0.50, step: 0.01, tint: .yellow,
                      display: String(format: "%.0f%%", viewModel.stretchStrength * 200))

            // Dark level slider
            SliderRow(icon: "circle.bottomhalf.filled", label: "Dark", value: $viewModel.darkLevel,
                      range: 0.0...0.5, step: 0.01, tint: .purple,
                      display: String(format: "%.0f%%", viewModel.darkLevel * 200))

            // Contrast slider
            SliderRow(icon: "circle.lefthalf.filled", label: "Contrast", value: $viewModel.contrastAmount,
                      range: -2.0...2.0, step: 0.1, tint: .white,
                      display: viewModel.contrastAmount == 0 ? "0" :
                        String(format: "%+.0f%%", viewModel.contrastAmount * 50))

            // Saturation slider
            SliderRow(icon: "paintpalette", label: "Color", value: $viewModel.saturationAmount,
                      range: 0.0...3.0, step: 0.1, tint: .pink,
                      display: String(format: "%.0f%%", viewModel.saturationAmount * 100))

            // Denoise slider (0-300% for stronger effect on mobile)
            SliderRow(icon: "aqi.medium", label: "Denoise", value: $viewModel.denoiseAmount,
                      range: 0.0...3.0, step: 0.1, tint: .mint,
                      display: String(format: "%.0f%%", viewModel.denoiseAmount * 100))

            // Gradient correction slider (0-300% for aggressive LP removal)
            SliderRow(icon: "circle.grid.cross", label: "Gradient", value: $viewModel.gradientStrength,
                      range: 0.0...3.0, step: 0.1, tint: .orange,
                      display: viewModel.gradientStrength > 0
                        ? String(format: "%.0f%%", viewModel.gradientStrength * 100) : "Off")

            // Auto-rotate toggle + Debayer toggle
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "rotate.left")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 16)
                    Text("Auto-Rotate")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                    Toggle("", isOn: $viewModel.autoRotate)
                        .labelsHidden()
                        .tint(.indigo)
                }

                if viewModel.bayerPatternDetected != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.3x3")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .frame(width: 16)
                        Text("Debayer")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Toggle("", isOn: $viewModel.debayerEnabled)
                            .labelsHidden()
                            .tint(.green)
                    }
                }

                Spacer()
            }

            // Reset button
            if viewModel.hasNonDefaultSettings {
                Button(action: {
                    viewModel.stretchStrength = 0.25
                    viewModel.darkLevel = 0
                    viewModel.contrastAmount = 0
                    viewModel.saturationAmount = 1.0
                    viewModel.denoiseAmount = 0
                    viewModel.gradientStrength = 0
                }) {
                    Text("Reset to Default")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Image info
            Text(viewModel.currentImageInfo)
                .font(.caption2.monospaced())
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow downward drag
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 60 {
                        // Swipe down past threshold — dismiss panel
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.showAdjustments = false
                        }
                    }
                    withAnimation(.easeOut(duration: 0.15)) {
                        dragOffset = 0
                    }
                }
        )
    }
}

// MARK: - Reusable Slider Row

struct SliderRow: View {
    let icon: String
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let tint: Color
    let display: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.gray)
                .frame(width: 18)

            Text(label)
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 58, alignment: .leading)

            Slider(value: $value, in: range, step: step)
                .tint(tint)

            Text(display)
                .font(.caption.monospaced())
                .foregroundColor(.gray)
                .frame(width: 36)
        }
    }
}

// MARK: - Help & About View

struct HelpAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Support link at the top
                Section {
                    Link(destination: URL(string: "https://buymeacoffee.com/joergsflow")!) {
                        HStack {
                            Image(systemName: "cup.and.saucer.fill")
                                .foregroundColor(.orange)
                            Text("Like it? Buy me a coffee!")
                                .font(.subheadline.bold())
                        }
                    }
                }

                // Getting Started
                Section("Getting Started") {
                    HelpRow(icon: "sparkles", color: .yellow,
                            title: "Play Around!",
                            text: "The best way to learn is to experiment. Open a file and drag the sliders — everything updates in real-time on the GPU. Try cranking denoise to 200%, then adding some sharpen. Push gradient to 300% and watch light pollution vanish. There's no wrong setting — you can always hit Reset. Have fun!")

                    HelpRow(icon: "folder", color: .blue,
                            title: "Open Files",
                            text: "Tap the folder icon to open FITS (.fits, .fit, .fts) or XISF (.xisf) files from the Files app, iCloud Drive, or any document provider.")

                    HelpRow(icon: "sun.min", color: .yellow,
                            title: "Auto Stretch",
                            text: "Images are automatically stretched using a PixInsight-compatible STF algorithm. The stretch makes faint nebulae and galaxies visible while preserving star shapes.")
                }

                // Image Controls
                Section("Image Controls") {
                    HelpRow(icon: "sun.min", color: .yellow,
                            title: "Stretch (0-100%)",
                            text: "Controls the target background level. Higher values reveal fainter detail but may blow out bright areas. Default: 50%.")

                    HelpRow(icon: "circle.bottomhalf.filled", color: .purple,
                            title: "Dark (0-100%)",
                            text: "Raises the black point to clip faint noise in the background. Useful for cleaning up light-polluted subs. Similar to the Shadows slider in photo editors.")

                    HelpRow(icon: "circle.lefthalf.filled", color: .white,
                            title: "Contrast (-100% to +100%)",
                            text: "S-curve contrast adjustment. Positive values deepen shadows and brighten highlights — great for making nebulae pop. Negative values flatten the image for a softer look. Centered at 0 (neutral).")

                    HelpRow(icon: "paintpalette", color: .pink,
                            title: "Color / Saturation (0-300%)",
                            text: "Controls color intensity. 100% is neutral (no change). Below 100% desaturates toward grayscale. Above 100% boosts colors — useful for bringing out faint Ha reds or OIII blues in OSC data. Goes up to 300% for dramatic effect.")

                    HelpRow(icon: "aqi.medium", color: .mint,
                            title: "Denoise (0-300%)",
                            text: "GPU bilateral noise reduction that preserves edges. Smooths background noise while keeping stars sharp. Goes up to 300% for aggressive smoothing on mobile screens.")

                    HelpRow(icon: "circle.grid.cross", color: .orange,
                            title: "Gradient (0-300%)",
                            text: "Removes linear light pollution gradients across the frame. At 0% the correction is off. Start around 100% and increase until the background looks even — go up to 300% for stubborn gradients. Uses an 8x8 grid of background samples to detect and subtract the tilt.")

                    HelpRow(icon: "square.grid.3x3", color: .green,
                            title: "Debayer",
                            text: "Converts raw Bayer CFA data to color. Auto-enabled when a Bayer pattern (RGGB, GRBG, etc.) is detected in the file header. Only available for mono CFA images.")
                }

                // Tips
                Section("Tips") {
                    HelpRow(icon: "rotate.left", color: .indigo,
                            title: "Auto-Rotate",
                            text: "Landscape images are automatically rotated to fill the screen in portrait mode. No need to turn your phone! Toggle off in adjustments if you prefer the original orientation.")

                    HelpRow(icon: "hand.pinch", color: .white,
                            title: "Zoom & Pan",
                            text: "Pinch to zoom (up to 10x), drag to pan. Works naturally even on rotated images.")

                    HelpRow(icon: "square.and.arrow.down", color: .white,
                            title: "Save to Photos",
                            text: "Saves the current view as a bin2 JPEG to your photo library. All active adjustments are baked in — stretch, dark, denoise, sharpen, and gradient correction.")

                    HelpRow(icon: "info.circle", color: .white,
                            title: "Header Inspector",
                            text: "View all FITS/XISF header keywords. Important keywords (OBJECT, FILTER, EXPTIME, GAIN, etc.) are highlighted at the top.")

                    HelpRow(icon: "gearshape", color: .white,
                            title: "Persistent Settings",
                            text: "All slider positions and toggles are saved automatically and restored on next launch. Use 'Reset to Default' to clear all settings.")
                }

                // About
                Section("About") {
                    VStack(alignment: .center, spacing: 12) {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "star.circle")
                                    .font(.system(size: 40))
                                    .foregroundColor(.blue)
                                Text("AstroFileViewer")
                                    .font(.headline)
                                Text("v1.4.0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("by joergsflow")
                                    .font(.subheadline)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.clear)

                    Link(destination: URL(string: "https://app.astrobin.com/u/joergsflow#gallery")!) {
                        Label("Astrobin Gallery", systemImage: "photo.on.rectangle")
                    }

                    Link(destination: URL(string: "https://www.instagram.com/joergsflow/")!) {
                        Label("Instagram @joergsflow", systemImage: "camera")
                    }

                    Link(destination: URL(string: "https://github.com/joergs-git/AstroBlinkV2")!) {
                        Label("GitHub — Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Link(destination: URL(string: "https://buymeacoffee.com/joergsflow")!) {
                        Label("Buy Me a Coffee", systemImage: "cup.and.saucer")
                    }

                    VStack(alignment: .center, spacing: 4) {
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Text("Open Source — GPLv3 License")
                                    .font(.caption2)
                                Text("Uses libxisf (GPLv3) and cfitsio (NASA Open Source)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Help & About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Recent File Thumbnail

struct RecentThumbnail: View {
    let entry: FileHistoryEntry
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "star.circle")
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
        }
        .onAppear {
            image = ViewerViewModel.loadThumbnail(for: entry)
        }
    }
}

// MARK: - Help Row Component

struct HelpRow: View {
    let icon: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(color)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Header List Sheet

struct HeaderListView: View {
    let headers: [(key: String, value: String)]
    let filename: String
    @Environment(\.dismiss) private var dismiss

    private let highlighted: Set<String> = [
        "OBJECT", "FILTER", "EXPTIME", "EXPOSURE",
        "CCD-TEMP", "GAIN", "OFFSET",
        "INSTRUME", "TELESCOP", "BAYERPAT"
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(headers, id: \.key) { header in
                    HStack(alignment: .top, spacing: 10) {
                        Text(header.key)
                            .font(.body.monospaced().bold())
                            .foregroundColor(highlighted.contains(header.key.uppercased()) ? .red : .accentColor)
                            .frame(width: 120, alignment: .trailing)

                        Text(header.value)
                            .font(.body.monospaced())
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
            .listStyle(.plain)
            .navigationTitle("\(filename) — \(headers.count) keywords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Zoomable Image (proper pinch-to-zoom + pan)

struct ZoomableImageContainer: UIViewRepresentable {
    let texture: MTLTexture
    var autoRotate: Bool = false
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    func makeUIView(context: Context) -> ZoomableImageView {
        let view = ZoomableImageView(texture: texture, autoRotate: autoRotate)
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        return view
    }

    func updateUIView(_ uiView: ZoomableImageView, context: Context) {
        uiView.onSwipeLeft = onSwipeLeft
        uiView.onSwipeRight = onSwipeRight
        uiView.updateTexture(texture, autoRotate: autoRotate)
    }
}

// UIScrollView-based pinch-to-zoom with proper content size management
class ZoomableImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var imageSize: CGSize = .zero
    private var currentAutoRotate: Bool = false
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    init(texture: MTLTexture, autoRotate: Bool) {
        super.init(frame: .zero)

        delegate = self
        minimumZoomScale = 1.0
        maximumZoomScale = 10.0
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        backgroundColor = .black

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)

        // Swipe gestures for history navigation (only fire at zoom 1.0)
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft))
        swipeLeft.direction = .left
        addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        swipeRight.direction = .right
        addGestureRecognizer(swipeRight)

        updateTexture(texture, autoRotate: autoRotate)
    }

    @objc private func handleSwipeLeft() {
        guard zoomScale <= 1.01 else { return }
        onSwipeLeft?()
    }

    @objc private func handleSwipeRight() {
        guard zoomScale <= 1.01 else { return }
        onSwipeRight?()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1.0 {
            imageView.frame = bounds
        }
        centerImageView()
    }

    func updateTexture(_ texture: MTLTexture, autoRotate: Bool) {
        let width = texture.width
        let height = texture.height
        let newSize = CGSize(width: width, height: height)
        let rotateChanged = autoRotate != currentAutoRotate
        let isNewImage = newSize != imageSize || rotateChanged
        imageSize = newSize
        currentAutoRotate = autoRotate
        let bytesPerRow = width * 4

        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: .init(), size: .init(width: width, height: height, depth: 1)),
                         mipmapLevel: 0)

        // BGRA -> RGBA
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = pixels[i]
            pixels[i] = pixels[i + 2]
            pixels[i + 2] = b
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return }

        // Auto-rotate: use UIImage orientation metadata (zero-cost, no pixel copy)
        let uiImage: UIImage
        if autoRotate && width > height {
            uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .left)
        } else {
            uiImage = UIImage(cgImage: cgImage)
        }
        imageView.image = uiImage

        if isNewImage {
            zoomScale = 1.0
            imageView.frame = bounds
        }
    }

    private func centerImageView() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame

        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
        } else {
            frameToCenter.origin.x = 0
        }

        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
        } else {
            frameToCenter.origin.y = 0
        }

        imageView.frame = frameToCenter
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }
}

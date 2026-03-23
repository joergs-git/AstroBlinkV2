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
                    ZoomableImageContainer(texture: texture)
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

                        Spacer().frame(height: 40)

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
                                    if viewModel.gradientEnabled {
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
                        if !viewModel.statusMessage.isEmpty && viewModel.displayTexture != nil && !viewModel.showAdjustments {
                            Text(viewModel.statusMessage)
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
        // Trigger on 10th launch and every 50th after that (Apple rate-limits to 3x/year anyway)
        if count == 10 || (count > 10 && count % 50 == 0) {
            requestReview()
        }
    }
}

// MARK: - Image Adjustments Panel

struct AdjustmentsPanel: View {
    @ObservedObject var viewModel: ViewerViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Stretch strength slider
            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 20)

                Text("Stretch")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 60, alignment: .leading)

                Slider(value: $viewModel.stretchStrength, in: 0.0...0.50, step: 0.01)
                    .tint(.yellow)

                Text(String(format: "%.0f%%", viewModel.stretchStrength * 200))
                    .font(.caption.monospaced())
                    .foregroundColor(.gray)
                    .frame(width: 40)
            }

            // Dark level slider
            HStack(spacing: 8) {
                Image(systemName: "circle.bottomhalf.filled")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 20)

                Text("Dark")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 60, alignment: .leading)

                Slider(value: $viewModel.darkLevel, in: 0.0...0.5, step: 0.01)
                    .tint(.purple)

                Text(String(format: "%.0f%%", viewModel.darkLevel * 200))
                    .font(.caption.monospaced())
                    .foregroundColor(.gray)
                    .frame(width: 40)
            }

            // Sharpening slider
            HStack(spacing: 8) {
                Image(systemName: "diamond")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 20)

                Text("Sharpen")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 60, alignment: .leading)

                Slider(value: $viewModel.sharpenAmount, in: 0...2.0, step: 0.05)
                    .tint(.cyan)

                Text(String(format: "%.0f%%", viewModel.sharpenAmount * 50))
                    .font(.caption.monospaced())
                    .foregroundColor(.gray)
                    .frame(width: 40)
            }

            // Gradient correction toggle
            HStack(spacing: 8) {
                Image(systemName: "circle.grid.cross")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 20)

                Text("Gradient")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 60, alignment: .leading)

                Toggle("", isOn: $viewModel.gradientEnabled)
                    .labelsHidden()
                    .tint(.orange)

                Text("Auto LP removal")
                    .font(.caption2)
                    .foregroundColor(.gray)

                Spacer()
            }

            // Debayer toggle (only when Bayer pattern detected)
            if viewModel.bayerPatternDetected != nil {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 20)

                    Text("Debayer")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .frame(width: 60, alignment: .leading)

                    Toggle("", isOn: $viewModel.debayerEnabled)
                        .labelsHidden()
                        .tint(.green)

                    Text(viewModel.bayerPatternDetected ?? "")
                        .font(.caption.monospaced())
                        .foregroundColor(.gray)

                    Spacer()
                }
            }

            // Reset button
            if viewModel.hasNonDefaultSettings {
                Button(action: {
                    viewModel.stretchStrength = 0.25
                    viewModel.darkLevel = 0
                    viewModel.sharpenAmount = 0
                    viewModel.gradientEnabled = false
                }) {
                    Text("Reset to Default")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Image info
            Text(viewModel.statusMessage)
                .font(.caption2.monospaced())
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - Help & About View

struct HelpAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Getting Started
                Section("Getting Started") {
                    HelpRow(icon: "folder", color: .blue,
                            title: "Open Files",
                            text: "Tap the folder icon to open FITS (.fits, .fit, .fts) or XISF (.xisf) files from the Files app, iCloud Drive, or any document provider.")

                    HelpRow(icon: "sparkles", color: .yellow,
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

                    HelpRow(icon: "diamond", color: .cyan,
                            title: "Sharpen (0-100%)",
                            text: "Applies an unsharp mask to enhance fine detail. Use sparingly — over-sharpening amplifies noise.")

                    HelpRow(icon: "circle.grid.cross", color: .orange,
                            title: "Gradient Correction",
                            text: "Automatically detects and removes linear light pollution gradients across the frame. Uses an 8x8 grid of background samples to fit and subtract the gradient tilt. When active, an indicator icon appears on the adjustments button.")

                    HelpRow(icon: "square.grid.3x3", color: .green,
                            title: "Debayer",
                            text: "Converts raw Bayer CFA data to color. Auto-enabled when a Bayer pattern (RGGB, GRBG, etc.) is detected in the file header. Only available for mono CFA images.")
                }

                // Tips
                Section("Tips") {
                    HelpRow(icon: "hand.pinch", color: .white,
                            title: "Zoom & Pan",
                            text: "Pinch to zoom (up to 10x), drag to pan. Double-tap not needed — just pinch anywhere on the image.")

                    HelpRow(icon: "square.and.arrow.down", color: .white,
                            title: "Save to Photos",
                            text: "Saves the current view as a bin2 JPEG to your photo library. The image includes all active adjustments (stretch, dark, sharpen, gradient correction).")

                    HelpRow(icon: "info.circle", color: .white,
                            title: "Header Inspector",
                            text: "View all FITS/XISF header keywords. Important keywords (OBJECT, FILTER, EXPTIME, GAIN, etc.) are highlighted at the top.")

                    HelpRow(icon: "gearshape", color: .white,
                            title: "Persistent Settings",
                            text: "Your slider positions and gradient toggle are saved automatically and restored on next launch. Use 'Reset to Default' to clear all settings.")
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
                    HStack(alignment: .top) {
                        Text(header.key)
                            .font(.caption.monospaced().bold())
                            .foregroundColor(highlighted.contains(header.key.uppercased()) ? .red : .accentColor)
                            .frame(width: 100, alignment: .trailing)

                        Text(header.value)
                            .font(.caption.monospaced())
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
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

    func makeUIView(context: Context) -> ZoomableImageView {
        ZoomableImageView(texture: texture)
    }

    func updateUIView(_ uiView: ZoomableImageView, context: Context) {
        uiView.updateTexture(texture)
    }
}

// UIScrollView-based pinch-to-zoom with proper content size management
class ZoomableImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var imageSize: CGSize = .zero

    init(texture: MTLTexture) {
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
        // Trilinear filtering reduces Moire artifacts when image is zoomed out
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)

        updateTexture(texture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only reset frame when not zoomed
        if zoomScale == 1.0 {
            imageView.frame = bounds
        }
        centerImageView()
    }

    func updateTexture(_ texture: MTLTexture) {
        let width = texture.width
        let height = texture.height
        let newSize = CGSize(width: width, height: height)
        let isNewImage = newSize != imageSize
        imageSize = newSize
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

        imageView.image = UIImage(cgImage: cgImage)

        // Only reset zoom when a different image is opened (dimensions changed),
        // not when stretch/sharpen sliders change the same image
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

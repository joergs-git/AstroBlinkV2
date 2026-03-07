// v1.2.0
import SwiftUI
import MetalKit
import StoreKit

struct ContentView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @State private var showHeaders = false
    @State private var showAbout = false
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let texture = viewModel.displayTexture {
                    ZoomableImageContainer(texture: texture)
                        .ignoresSafeArea()
                } else if viewModel.isLoading {
                    ProgressView("Decoding...")
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

                        // About link on landing screen
                        Button(action: { showAbout = true }) {
                            Text("About AstroFileViewer")
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
                        Button(action: { showAbout = true }) {
                            Image(systemName: "person.circle")
                        }
                    }
                }

                if viewModel.displayTexture != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
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

                if !viewModel.headers.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showHeaders = true }) {
                            Image(systemName: "info.circle")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
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
                    if !viewModel.statusMessage.isEmpty && viewModel.displayTexture != nil {
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
            .sheet(isPresented: $showHeaders) {
                HeaderListView(headers: viewModel.headers, filename: viewModel.filename)
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
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

    // Ask for App Store rating after 10 launches
    private func checkForReviewPrompt() {
        let key = "launchCount"
        let count = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(count, forKey: key)
        if count == 10 {
            requestReview()
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: "star.circle")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)

                    Text("AstroFileViewer")
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    Text("v1.0.0")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Text("FITS & XISF viewer for astrophotography.\nPixInsight-compatible STF auto-stretch.")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    Divider().background(Color.gray.opacity(0.3)).padding(.horizontal, 40)

                    Text("by joergsflow")
                        .font(.headline)
                        .foregroundColor(.white)

                    VStack(spacing: 10) {
                        Link(destination: URL(string: "https://app.astrobin.com/u/joergsflow#gallery")!) {
                            Label("Astrobin Gallery", systemImage: "photo.on.rectangle")
                                .font(.subheadline)
                        }

                        Link(destination: URL(string: "https://www.instagram.com/joergsflow/")!) {
                            Label("Instagram @joergsflow", systemImage: "camera")
                                .font(.subheadline)
                        }

                        Link(destination: URL(string: "https://github.com/joergs-git/AstroBlinkV2")!) {
                            Label("GitHub – Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.subheadline)
                        }
                    }
                    .padding(.top, 8)

                    Divider().background(Color.gray.opacity(0.3)).padding(.horizontal, 40)

                    Text("Open Source — GPLv3 License")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    Text("Uses libxisf (GPLv3) and cfitsio (NASA Open Source)")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    Spacer()
                }
                .padding(.top, 20)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
        "INSTRUME", "TELESCOP"
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
        addSubview(imageView)

        updateTexture(texture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only reset frame when not zoomed (zoom scale == 1)
        if zoomScale == 1.0 {
            imageView.frame = bounds
        }
        centerImageView()
    }

    func updateTexture(_ texture: MTLTexture) {
        let width = texture.width
        let height = texture.height
        imageSize = CGSize(width: width, height: height)
        let bytesPerRow = width * 4

        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: .init(), size: .init(width: width, height: height, depth: 1)),
                         mipmapLevel: 0)

        // BGRA → RGBA
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

        // Reset zoom when new image loads
        zoomScale = 1.0
        imageView.frame = bounds
    }

    // Center the image when zoomed out or smaller than scroll view
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

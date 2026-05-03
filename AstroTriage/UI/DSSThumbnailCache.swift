// Disk-cached DSS thumbnail loader plus the SwiftUI views that consume it.
// Used by Target Catalog browser to show NASA DSS preview images for each
// deep-sky target. Disk cache lives at ~/Library/Caches/AstroBlinkV2/dss_thumbnails/
// and is intentionally preserved across launches by SessionCache.cleanupAllCaches().
import SwiftUI
import AppKit

/// Disk-cached DSS thumbnail loader. Downloads once, caches forever to
/// ~/Library/Caches/AstroBlinkV2/dss_thumbnails/. Memory cache via NSCache.
@MainActor
final class DSSImageCache: ObservableObject {
    static let shared = DSSImageCache()

    private let memCache = NSCache<NSURL, NSImage>()
    private let cacheDir: URL
    private var inFlight: Set<URL> = []

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = caches.appendingPathComponent("AstroBlinkV2/dss_thumbnails")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memCache.countLimit = 600
    }

    func image(for url: URL) -> NSImage? {
        // Check memory
        if let img = memCache.object(forKey: url as NSURL) { return img }
        // Check disk
        let diskPath = diskFile(for: url)
        if FileManager.default.fileExists(atPath: diskPath.path),
           let img = NSImage(contentsOf: diskPath) {
            memCache.setObject(img, forKey: url as NSURL)
            return img
        }
        return nil
    }

    func fetch(_ url: URL) {
        guard !inFlight.contains(url), image(for: url) == nil else { return }
        inFlight.insert(url)
        Task.detached(priority: .utility) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let img = NSImage(data: data) else { return }
                let diskPath = await self.diskFile(for: url)
                try? data.write(to: diskPath, options: .atomic)
                await MainActor.run {
                    self.memCache.setObject(img, forKey: url as NSURL)
                    self.inFlight.remove(url)
                    self.objectWillChange.send()
                }
            } catch {
                await MainActor.run { self.inFlight.remove(url) }
            }
        }
    }

    private func diskFile(for url: URL) -> URL {
        // Use RA/Dec from the URL as unique filename (extracted from query params)
        // URL format: ...&r=60.217&d=36.617&...
        let s = url.absoluteString
        let name = s.components(separatedBy: "&")
            .filter { $0.hasPrefix("r=") || $0.hasPrefix("d=") || $0.hasPrefix("h=") }
            .joined(separator: "_")
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "m")
            .replacingOccurrences(of: ".", with: "p")
        return cacheDir.appendingPathComponent("dss_\(name).gif")
    }
}

/// Cached DSS thumbnail view. Uses DSSImageCache for disk + memory caching.
struct DSSThumbnailView: View {
    let url: URL?
    let size: CGFloat
    @ObservedObject private var cache = DSSImageCache.shared

    var body: some View {
        if let url {
            if let nsImage = cache.image(for: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .cornerRadius(size > 60 ? 8 : 4)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: size, height: size)
                    .cornerRadius(size > 60 ? 8 : 4)
                    .onAppear { cache.fetch(url) }
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: size * 0.4))
                .foregroundColor(.gray.opacity(0.3))
                .frame(width: size, height: size)
        }
    }
}

/// DSS thumbnail that enlarges on hover — 120px normal, 300px on hover.
struct ZoomableDSSThumbnail: View {
    let url: URL?
    @State private var isHovered = false

    var body: some View {
        DSSThumbnailView(url: url, size: isHovered ? 300 : 120)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .zIndex(isHovered ? 10 : 0)
    }
}

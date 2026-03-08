// v2.0.1
import QuickLookThumbnailing
import CoreGraphics
import ImageDecoderBridge

// QuickLook thumbnail provider for FITS and XISF astrophotography files.
// Decodes the image, applies STF auto-stretch, and renders a thumbnail.
// Embedded in AstroBlinkV2 — users get Finder previews automatically.
class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        let maxSize = request.maximumSize
        let scale = request.scale

        // Decode the image file via C bridge
        guard let imageData = QuickLookDecoder.decode(url: fileURL) else {
            handler(nil, QuickLookError.decodeFailed)
            return
        }
        defer { imageData.free() }

        // Calculate STF parameters for auto-stretch
        let stfParams = QuickLookSTF.calculate(
            pixels: imageData.pixels,
            width: imageData.width,
            height: imageData.height,
            channelCount: imageData.channelCount
        )

        // Determine thumbnail dimensions (fit within maxSize, preserve aspect ratio)
        let aspectRatio = CGFloat(imageData.width) / CGFloat(imageData.height)
        let thumbWidth: CGFloat
        let thumbHeight: CGFloat
        if aspectRatio > maxSize.width / maxSize.height {
            thumbWidth = maxSize.width
            thumbHeight = maxSize.width / aspectRatio
        } else {
            thumbHeight = maxSize.height
            thumbWidth = maxSize.height * aspectRatio
        }
        let contextSize = CGSize(width: thumbWidth, height: thumbHeight)
        let renderWidth = max(1, Int(thumbWidth * scale))
        let renderHeight = max(1, Int(thumbHeight * scale))

        // Render to CGImage
        guard let cgImage = QuickLookRenderer.renderToImage(
            imageData: imageData,
            stfParams: stfParams,
            targetWidth: renderWidth,
            targetHeight: renderHeight
        ) else {
            handler(nil, QuickLookError.renderFailed)
            return
        }

        // Use drawing-based reply — the closure receives a CGContext
        let reply = QLThumbnailReply(contextSize: contextSize, drawing: { context -> Bool in
            context.draw(cgImage, in: CGRect(origin: .zero, size: contextSize))
            return true
        })

        handler(reply, nil)
    }
}

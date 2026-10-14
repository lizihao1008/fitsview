import CoreGraphics
import QuickLookThumbnailing

struct NothingToDraw: Error {}

/// Finder icon / gallery thumbnail: the image (zscale), a spectrum plot, or binned events.
/// Files with only headers or plain tables fall back to the regular document icon.
@objc(FITSThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let fits = try FITSFile(url: request.fileURL)
            let pixels = Int(max(request.maximumSize.width, request.maximumSize.height) * request.scale)
            guard let visual = fits.heroVisual(maxSize: max(64, pixels)) else { throw NothingToDraw() }
            let size = thumbnailSize(for: visual, maxSize: request.maximumSize)
            let reply = QLThumbnailReply(contextSize: size) { ctx in
                // On Retina the bitmap is contextSize × scale pixels but its CTM is not
                // pre-scaled, so measure the drawable area instead of assuming points.
                var area = size
                if ctx.width > 0 && ctx.height > 0 {
                    let u = ctx.convertToUserSpace(CGSize(width: ctx.width, height: ctx.height))
                    area = CGSize(width: abs(u.width), height: abs(u.height))
                }
                return drawThumbnail(visual, in: ctx, size: area)
            }
            reply.extensionBadge = "FITS"
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}

import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Space-bar preview: an HTML page with the image/spectrum, HDU list, tables and headers.
@objc(FITSPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 980, height: 820)) { reply in
            let fits = try FITSFile(url: url)
            let doc = PreviewBuilder.build(fits, fileName: url.lastPathComponent)
            reply.stringEncoding = .utf8
            reply.attachments = doc.attachments.mapValues { QLPreviewReplyAttachment(data: $0, contentType: .png) }
            return Data(doc.html.utf8)
        }
        handler(reply, nil)
    }
}

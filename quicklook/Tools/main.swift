// qlrender OUTDIR FILE... — runs the Quick Look rendering code outside Quick Look:
// writes OUTDIR/<file>/index.html (+ PNG attachments) and thumb.png for each file.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: qlrender OUTDIR FILE..."); exit(2) }
let outRoot = URL(fileURLWithPath: args[1])
var failures = 0
for path in args.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let dir = outRoot.appendingPathComponent(url.lastPathComponent)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t0 = Date()
        let fits = try FITSFile(url: url)
        let doc = PreviewBuilder.build(fits, fileName: url.lastPathComponent)
        for (name, data) in doc.attachments { try data.write(to: dir.appendingPathComponent(name)) }
        try doc.html.replacingOccurrences(of: "cid:", with: "").write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let t1 = Date()
        var thumb = "none"
        if let v = fits.heroVisual(maxSize: 512) {
            let size = thumbnailSize(for: v, maxSize: CGSize(width: 512, height: 512))
            let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if drawThumbnail(v, in: ctx, size: size), let img = ctx.makeImage(), let png = pngData(img) {
                try png.write(to: dir.appendingPathComponent("thumb.png"))
                thumb = "\(Int(size.width))×\(Int(size.height))"
            }
        }
        print(String(format: "%-28@ preview %4.0f ms  thumb %4.0f ms  %@  attachments=%d", url.lastPathComponent as NSString,
                     t1.timeIntervalSince(t0) * 1000, Date().timeIntervalSince(t1) * 1000, thumb as NSString, doc.attachments.count))
    } catch {
        failures += 1
        print("\(url.lastPathComponent): ERROR \(error)")
    }
}
exit(failures == 0 ? 0 : 1)

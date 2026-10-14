// Image stretch, colour mapping, PNG encoding, and spectrum drawing (SVG + CoreGraphics).

import CoreGraphics
import Foundation
import ImageIO

// MARK: - zscale (port of astropy.visualization.ZScaleInterval)

func zscale(_ px: [Float], samples: Int = 10_000, contrast: Double = 0.25) -> (Float, Float) {
    let step = max(1, px.count / samples)
    var s = [Float]()
    s.reserveCapacity(samples + 1)
    var i = 0
    while i < px.count { if px[i].isFinite { s.append(px[i]) }; i += step }
    guard s.count > 1 else { let v = s.first ?? 0; return (v, v + 1) }
    s.sort()
    let n = s.count
    var vmin = s[0], vmax = s[n - 1]
    let minpix = max(5, Int(Double(n) * 0.5))
    let ngrow = max(1, Int(Double(n) * 0.01))
    var bad = [Bool](repeating: false, count: n)
    var ngood = n, lastGood = n + 1
    var slope = 0.0
    for _ in 0..<5 {
        if ngood >= lastGood || ngood < minpix { break }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, cnt = 0.0
        for k in 0..<n where !bad[k] {
            let x = Double(k), y = Double(s[k])
            sx += x; sy += y; sxx += x * x; sxy += x * y; cnt += 1
        }
        let den = cnt * sxx - sx * sx
        guard den != 0 else { break }
        let b = (cnt * sxy - sx * sy) / den, a = (sy - b * sx) / cnt
        slope = b
        var mean = 0.0, sq = 0.0
        for k in 0..<n where !bad[k] { let r = Double(s[k]) - (a + b * Double(k)); mean += r; sq += r * r }
        mean /= cnt
        let threshold = 2.5 * (sq / cnt - mean * mean).squareRoot()
        var marked = bad
        for k in 0..<n where abs(Double(s[k]) - (a + b * Double(k))) > threshold { marked[k] = true }
        // grow rejected regions (np.convolve(badpix, ones(ngrow), 'same'))
        bad = marked
        if ngrow > 1 {
            let lo = (ngrow - 1) / 2, hi = ngrow - 1 - lo
            for k in 0..<n where marked[k] { for j in max(0, k - hi)...min(n - 1, k + lo) { bad[j] = true } }
        }
        lastGood = ngood
        ngood = bad.lazy.filter { !$0 }.count
    }
    if ngood >= minpix {
        let sl = Float(slope / contrast)
        let center = (n - 1) / 2
        let median = n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
        vmin = max(vmin, median - Float(center - 1) * sl)
        vmax = min(vmax, median + Float(n - center) * sl)
    }
    return vmin < vmax ? (vmin, vmax) : (s[0], max(s[n - 1], s[0] + 1))
}

// MARK: - colour

enum Colormap {
    case gray, heat

    var lut: [(UInt8, UInt8, UInt8)] {
        let anchors: [(Double, Double, Double)]
        switch self {
        case .gray: anchors = [(0, 0, 0), (255, 255, 255)]
        case .heat: anchors = [(0, 0, 0), (140, 20, 0), (230, 110, 0), (255, 220, 80), (255, 255, 255)]
        }
        return (0..<256).map { i in
            let t = Double(i) / 255 * Double(anchors.count - 1)
            let k = min(Int(t), anchors.count - 2), f = t - Double(k)
            let a = anchors[k], b = anchors[k + 1]
            return (UInt8(a.0 + (b.0 - a.0) * f), UInt8(a.1 + (b.1 - a.1) * f), UInt8(a.2 + (b.2 - a.2) * f))
        }
    }
}

func makeCGImage(_ p: ImagePlane, z1: Float, z2: Float, colormap: Colormap = .gray) -> CGImage? {
    let lut = colormap.lut
    let span = z2 > z1 ? z2 - z1 : 1
    var buf = [UInt8](repeating: 255, count: p.width * p.height * 4)
    for y in 0..<p.height {
        let src = (p.height - 1 - y) * p.width   // FITS origin is bottom-left
        let dst = y * p.width * 4
        for x in 0..<p.width {
            let v = p.pixels[src + x]
            let c: (UInt8, UInt8, UInt8)
            if v.isFinite {
                c = lut[Int(min(max((v - z1) / span, 0), 1) * 255)]
            } else {
                c = (52, 40, 64)   // NaN: muted purple-grey
            }
            buf[dst + 4 * x] = c.0; buf[dst + 4 * x + 1] = c.1; buf[dst + 4 * x + 2] = c.2
        }
    }
    guard let provider = CGDataProvider(data: Data(buf) as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.width * 4,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func pngData(_ image: CGImage) -> Data? {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

// MARK: - spectrum helpers

/// Keep the min and max of each bucket so narrow emission/absorption lines survive.
func decimate(_ x: [Double], _ y: [Double], buckets: Int) -> [(Double, Double)] {
    let pts = zip(x, y).filter { $0.0.isFinite && $0.1.isFinite }
    guard pts.count > 2 * buckets else { return pts }
    let size = Double(pts.count) / Double(buckets)
    var out = [(Double, Double)]()
    out.reserveCapacity(2 * buckets)
    for b in 0..<buckets {
        let lo = Int(Double(b) * size), hi = min(pts.count, Int(Double(b + 1) * size))
        guard lo < hi else { continue }
        var iMin = lo, iMax = lo
        for i in lo..<hi {
            if pts[i].1 < pts[iMin].1 { iMin = i }
            if pts[i].1 > pts[iMax].1 { iMax = i }
        }
        out.append(pts[min(iMin, iMax)])
        if iMin != iMax { out.append(pts[max(iMin, iMax)]) }
    }
    return out
}

func finiteRange(_ v: [Double]) -> (Double, Double)? {
    var lo = Double.infinity, hi = -Double.infinity
    for x in v where x.isFinite { lo = min(lo, x); hi = max(hi, x) }
    guard lo <= hi else { return nil }
    return lo == hi ? (lo - 1, hi + 1) : (lo, hi)
}

func niceTicks(_ lo: Double, _ hi: Double, target: Int = 6) -> (ticks: [Double], step: Double) {
    let raw = (hi - lo) / Double(target)
    guard raw > 0, raw.isFinite else { return ([lo], 1) }
    let mag = pow(10, floor(log10(raw)))
    let norm = raw / mag
    let step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag
    var ticks = [Double]()
    var t = (lo / step).rounded(.up) * step
    while t <= hi + step * 1e-9 { ticks.append(t); t += step }
    return (ticks, step)
}

func tickLabel(_ v: Double, step: Double) -> String {
    let a = max(abs(v), step)
    if a >= 1e6 || a < 1e-3 { return String(format: "%.2g", v) }
    let decimals = max(0, Int(-floor(log10(step))))
    return String(format: "%.\(decimals)f", abs(v) < step / 2 ? 0 : v)
}

private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// Inline SVG line plot; colours come from the page CSS (.ax, .grid, .line, .band).
func spectrumSVG(_ s: Spectrum, width: Double = 920, height: Double = 340) -> String {
    guard let (x0, x1) = finiteRange(s.x), let (ya, yb) = finiteRange(s.y) else { return "" }
    let pad = (yb - ya) * 0.05
    let y0 = ya - pad, y1 = yb + pad
    let l = 74.0, r = 16.0, t = 12.0, b = 46.0
    let pw = width - l - r, ph = height - t - b
    func px(_ x: Double) -> Double { l + (x - x0) / (x1 - x0) * pw }
    func py(_ y: Double) -> Double { t + (1 - (y - y0) / (y1 - y0)) * ph }
    func f(_ v: Double) -> String { String(format: "%.1f", v) }

    var svg = "<svg viewBox=\"0 0 \(Int(width)) \(Int(height))\" xmlns=\"http://www.w3.org/2000/svg\" class=\"plot\">"
    let (xt, xs) = niceTicks(x0, x1), (yt, ys) = niceTicks(y0, y1, target: 5)
    for v in xt {
        svg += "<line class=\"grid\" x1=\"\(f(px(v)))\" x2=\"\(f(px(v)))\" y1=\"\(f(t))\" y2=\"\(f(t + ph))\"/>"
        svg += "<text class=\"tick\" x=\"\(f(px(v)))\" y=\"\(f(t + ph + 16))\" text-anchor=\"middle\">\(tickLabel(v, step: xs))</text>"
    }
    for v in yt {
        svg += "<line class=\"grid\" x1=\"\(f(l))\" x2=\"\(f(l + pw))\" y1=\"\(f(py(v)))\" y2=\"\(f(py(v)))\"/>"
        svg += "<text class=\"tick\" x=\"\(f(l - 6))\" y=\"\(f(py(v) + 4))\" text-anchor=\"end\">\(tickLabel(v, step: ys))</text>"
    }
    let buckets = Int(pw)
    if let e = s.err {
        let k = max(1, s.y.count / buckets)
        var upper = [(Double, Double)](), lower = [(Double, Double)]()
        for i in stride(from: 0, to: s.y.count, by: k) where s.x[i].isFinite && s.y[i].isFinite && e[i].isFinite {
            upper.append((s.x[i], min(y1, s.y[i] + e[i]))); lower.append((s.x[i], max(y0, s.y[i] - e[i])))
        }
        if !upper.isEmpty {
            let pts = upper + lower.reversed()
            svg += "<path class=\"band\" d=\"M" + pts.map { "\(f(px($0.0))),\(f(py($0.1)))" }.joined(separator: "L") + "Z\"/>"
        }
    }
    let pts = decimate(s.x, s.y, buckets: buckets)
    svg += "<path class=\"line\" d=\"M" + pts.map { "\(f(px($0.0))),\(f(py($0.1)))" }.joined(separator: "L") + "\"/>"
    svg += "<rect class=\"ax\" x=\"\(f(l))\" y=\"\(f(t))\" width=\"\(f(pw))\" height=\"\(f(ph))\"/>"
    svg += "<text class=\"label\" x=\"\(f(l + pw / 2))\" y=\"\(f(height - 8))\" text-anchor=\"middle\">\(xmlEscape(s.xlabel))</text>"
    svg += "<text class=\"label\" transform=\"translate(16 \(f(t + ph / 2))) rotate(-90)\" text-anchor=\"middle\">\(xmlEscape(s.ylabel))</text>"
    return svg + "</svg>"
}

// MARK: - thumbnails (CoreGraphics, origin bottom-left)

func thumbnailSize(for v: Visual, maxSize: CGSize) -> CGSize {
    switch v.content {
    case .image(let p, _, _, _):
        let k = min(maxSize.width / CGFloat(p.width), maxSize.height / CGFloat(p.height))
        return CGSize(width: max(1, (CGFloat(p.width) * k).rounded()), height: max(1, (CGFloat(p.height) * k).rounded()))
    case .spectrum:
        let w = min(maxSize.width, maxSize.height * 4 / 3)
        return CGSize(width: w, height: (w * 3 / 4).rounded())
    }
}

func drawThumbnail(_ v: Visual, in ctx: CGContext, size: CGSize) -> Bool {
    let rect = CGRect(origin: .zero, size: size)
    switch v.content {
    case .image(let p, let z1, let z2, let cmap):
        guard let img = makeCGImage(p, z1: z1, z2: z2, colormap: cmap) else { return false }
        ctx.interpolationQuality = CGFloat(p.width) < size.width ? .none : .medium
        ctx.draw(img, in: rect)
        return true
    case .spectrum(let s):
        guard let (x0, x1) = finiteRange(s.x), let (ya, yb) = finiteRange(s.y) else { return false }
        let u = size.width / 100
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        let plot = rect.insetBy(dx: 6 * u, dy: 8 * u)
        let pad = (yb - ya) * 0.06
        let y0 = ya - pad, y1 = yb + pad
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((x - x0) / (x1 - x0)) * plot.width,
                    y: plot.minY + CGFloat((y - y0) / (y1 - y0)) * plot.height)
        }
        ctx.setStrokeColor(CGColor(gray: 0.86, alpha: 1))
        ctx.setLineWidth(max(0.5, 0.4 * u))
        for k in 0...3 {
            let y = plot.minY + plot.height * CGFloat(k) / 3
            ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.strokePath()
        let pts = decimate(s.x, s.y, buckets: max(50, Int(plot.width)))
        guard let first = pts.first, let last = pts.last else { return false }
        // soft fill under the curve, then the line itself
        ctx.beginPath()
        ctx.move(to: CGPoint(x: pt(first.0, first.1).x, y: plot.minY))
        for p in pts { ctx.addLine(to: pt(p.0, p.1)) }
        ctx.addLine(to: CGPoint(x: pt(last.0, last.1).x, y: plot.minY))
        ctx.closePath()
        ctx.setFillColor(CGColor(red: 0.18, green: 0.44, blue: 0.87, alpha: 0.12))
        ctx.fillPath()
        ctx.beginPath()
        ctx.move(to: pt(first.0, first.1))
        for p in pts.dropFirst() { ctx.addLine(to: pt(p.0, p.1)) }
        ctx.setStrokeColor(CGColor(red: 0.18, green: 0.44, blue: 0.87, alpha: 1))
        ctx.setLineWidth(max(1, 0.55 * u))
        ctx.setLineJoin(.round)
        ctx.strokePath()
        return true
    }
}

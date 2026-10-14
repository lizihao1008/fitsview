// Picks the most representative thing to show for a FITS file:
// an image (or cube plane), a spectrum, or a binned event list.

import Foundation

struct Spectrum {
    var x: [Double]
    var y: [Double]
    var err: [Double]?
    var xlabel: String
    var ylabel: String
}

enum VisualContent {
    case image(ImagePlane, z1: Float, z2: Float, colormap: Colormap)
    case spectrum(Spectrum)
}

struct Visual {
    let hdu: Int
    let caption: String
    let content: VisualContent
}

extension FITSFile {
    /// Most informative visual in the file: a science image/cube, else event list, else spectrum.
    func heroVisual(maxSize: Int) -> Visual? {
        let kinds = hdus.map { ($0, kind($0)) }
        // Science-looking images first; weights, masks, covariance etc. last
        // (e.g. grizli *.full.fits starts with a mostly-zero COVAR matrix before DSCI).
        let images = kinds.filter { $0.1 == .image || $0.1 == .cube }.map(\.0)
            .sorted { (Self.imageRank($0), $0.index) < (Self.imageRank($1), $1.index) }
        var fallback: Visual?
        for h in images.prefix(8) {
            guard let v = imageVisual(h, maxSize: maxSize) else { continue }
            if Self.isInformative(v) { return v }
            fallback = fallback ?? v
        }
        // an event list says more than the PHA spectrum that often rides along with it
        if let (h, _) = kinds.first(where: { $0.1 == .events }), let v = eventsVisual(h, bins: min(512, maxSize)) {
            return v
        }
        for (h, k) in kinds where [.spectrum, .spectra, .spectrumTable].contains(k) {
            if let v = spectrumVisual(h) { return v }
        }
        return fallback
    }

    private static let scienceNames: Set<String> = ["SCI", "DSCI", "IMAGE", "IMG", "DATA", "FLUX", "PRIMARY", "INTENSITY"]
    private static let auxiliaryTokens = ["COV", "WHT", "WEIGHT", "IVAR", "VAR", "ERR", "UNC", "DQ", "MASK", "FLAG",
                                          "SEG", "PSF", "CONTAM", "EXP", "CTX", "BKG", "SKY", "NOISE", "RMS", "MODEL"]

    /// 0 = science extension name, 1 = unknown, 2 = auxiliary (weights, masks, errors, ...)
    static func imageRank(_ h: HDU) -> Int {
        let name = h.name.uppercased()
        if scienceNames.contains(name) { return 0 }
        return auxiliaryTokens.contains { name.contains($0) } ? 2 : 1
    }

    /// False for planes that are (almost) all one value or all NaN: masks, empty
    /// continuum models, sparse matrices — they render as a flat square.
    static func isInformative(_ v: Visual) -> Bool {
        guard case .image(let p, _, _, _) = v.content else { return true }
        let finite = p.pixels.filter(\.isFinite)
        guard finite.count >= max(4, p.pixels.count / 100) else { return false }
        let median = finite.sorted()[finite.count / 2]
        let differing = finite.lazy.filter { $0 != median }.count
        return Double(differing) > 0.2 * Double(finite.count)
    }

    func label(_ h: HDU) -> String {
        "HDU \(h.index)" + (h.name.isEmpty ? "" : " · \(h.name)")
    }

    func imageVisual(_ h: HDU, maxSize: Int) -> Visual? {
        let ax = h.naxes
        // cubes: show the middle plane of the 3rd axis (usually the spectral/time axis)
        let planes = ax.count >= 3 ? ax[2] : 1
        let plane = planes / 2
        guard let p = imagePlane(h, plane: plane, maxSize: maxSize) else { return nil }
        let (z1, z2) = zscale(p.pixels)
        var caption = "\(label(h)) · \(ax.map(String.init).joined(separator: " × "))"
        if planes > 1 { caption += " · plane \(plane + 1) of \(planes)" }
        return Visual(hdu: h.index, caption: caption + " · zscale", content: .image(p, z1: z1, z2: z2, colormap: .gray))
    }

    func spectrumVisual(_ h: HDU) -> Visual? {
        guard let s = spectrum(h), s.y.contains(where: \.isFinite) else { return nil }
        return Visual(hdu: h.index, caption: "\(label(h)) · \(kind(h).rawValue)", content: .spectrum(s))
    }

    func spectrum(_ h: HDU) -> Spectrum? {
        switch kind(h) {
        case .spectrum, .spectra:
            let y = imageRow(h)
            guard !y.isEmpty else { return nil }
            let hd = h.header
            var x = (0..<y.count).map(Double.init)
            var xlabel = "pixel"
            if let crval = hd.double("CRVAL1"), let cdelt = hd.double("CDELT1") ?? hd.double("CD1_1") {
                let crpix = hd.double("CRPIX1") ?? 1
                x = x.map { crval + ($0 + 1 - crpix) * cdelt }
                if hd.int("DC-FLAG") == 1 { x = x.map { pow(10, $0) } }
                let ctype = hd.string("CTYPE1") ?? "", cunit = hd.string("CUNIT1") ?? ""
                xlabel = (ctype.isEmpty ? "axis 1" : ctype) + (cunit.isEmpty ? "" : " [\(cunit)]")
            }
            return Spectrum(x: x, y: y, err: nil, xlabel: xlabel, ylabel: hd.string("BUNIT") ?? "value")
        case .spectrumTable:
            guard let t = table(h) else { return nil }
            let g = t.spectrumGuess()
            guard let yc = g.y else { return nil }
            let row: Int? = yc.isVector ? 0 : nil
            let y = values(t, yc, row: row)
            var x: [Double]
            var xlabel = row == nil ? "row" : "element"
            if let xc = g.x, xc.isVector == yc.isVector {
                x = values(t, xc, row: row)
                xlabel = xc.name + (xc.unit.isEmpty ? "" : " [\(xc.unit)]")
                if xc.name.lowercased() == "loglam" {
                    x = x.map { pow(10, $0) }
                    xlabel = "wavelength (10^loglam)"
                }
            } else {
                x = (0..<y.count).map(Double.init)
            }
            guard x.count == y.count else { return nil }
            var err: [Double]?
            if let ec = g.err, ec.isVector == yc.isVector {
                var e = values(t, ec, row: row)
                if ec.name.lowercased() == "ivar" { e = e.map { $0 > 0 ? 1 / $0.squareRoot() : .nan } }
                if e.count == y.count { err = e }
            }
            var ylabel = yc.name + (yc.unit.isEmpty ? "" : " [\(yc.unit)]")
            if row != nil && t.nrows > 1 { ylabel += " (row 0 of \(t.nrows))" }
            return Spectrum(x: x, y: y, err: err, xlabel: xlabel, ylabel: ylabel)
        default:
            return nil
        }
    }

    /// Bin X/Y event positions into a square image (log counts), like DS9 does.
    func eventsVisual(_ h: HDU, bins: Int) -> Visual? {
        guard let t = table(h), let xc = t.column(named: "X"), let yc = t.column(named: "Y") else { return nil }
        let xs = values(t, xc, limit: 2_000_000), ys = values(t, yc, limit: 2_000_000)
        func bounds(_ v: [Double]) -> (Double, Double)? {
            let step = max(1, v.count / 100_000)
            let s = stride(from: 0, to: v.count, by: step).map { v[$0] }.filter(\.isFinite).sorted()
            guard s.count > 1 else { return nil }
            return (s[Int(Double(s.count - 1) * 0.001)], s[Int(Double(s.count - 1) * 0.999)])
        }
        guard let (x0, x1) = bounds(xs), let (y0, y1) = bounds(ys) else { return nil }
        let half = max(x1 - x0, y1 - y0, 1) / 2 * 1.05
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let scale = Double(bins) / (2 * half)
        var counts = [Float](repeating: 0, count: bins * bins)
        for i in 0..<min(xs.count, ys.count) {
            let bx = Int(((xs[i] - cx + half) * scale).rounded(.down))
            let by = Int(((ys[i] - cy + half) * scale).rounded(.down))
            if bx >= 0 && bx < bins && by >= 0 && by < bins { counts[by * bins + bx] += 1 }
        }
        let logc = counts.map { log10(1 + $0) }
        let top = logc.max() ?? 1
        let plane = ImagePlane(width: bins, height: bins, pixels: logc)
        let caption = "\(label(h)) · \(t.nrows) events binned on X/Y · log scale"
        return Visual(hdu: h.index, caption: caption, content: .image(plane, z1: 0, z2: max(top, 1e-3), colormap: .heat))
    }
}

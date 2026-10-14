// Builds the Quick Look (space-bar) preview: a static HTML page (Quick Look runs
// no JavaScript) with PNG attachments referenced as cid:<name>.

import Foundation

struct PreviewDocument {
    var html: String
    var attachments: [String: Data]   // name -> PNG bytes
}

enum PreviewBuilder {
    static let maxHDUSections = 60
    static let maxExtraImages = 8
    static let maxCards = 2000
    static let previewRows = 25
    static let previewCols = 40

    static func build(_ f: FITSFile, fileName: String) -> PreviewDocument {
        var attachments = [String: Data]()
        var body = ""
        let kinds = f.hdus.map { f.kind($0) }

        body += "<header><h1>\(esc(fileName))</h1><div class=\"meta\">\(f.hdus.count) HDU\(f.hdus.count == 1 ? "" : "s") · \(byteSize(f.fileSize))</div></header>"

        // hero visual
        let hero = f.heroVisual(maxSize: 1400)
        if let v = hero {
            body += "<section class=\"hero\">" + visualHTML(v, name: "hero.png", attachments: &attachments, cls: "hero-img")
            body += "<div class=\"caption\">\(esc(v.caption))</div></section>"
        }

        // HDU overview, like the fv main window
        body += "<table class=\"hdus\"><thead><tr><th>#</th><th>Extension</th><th>Type</th><th>Content</th><th>Dimensions</th><th>BITPIX</th><th>Cards</th></tr></thead><tbody>"
        for (h, k) in zip(f.hdus, kinds) {
            let obj = h.header.string("OBJECT").map { "<div class=\"sub\">\(esc($0))</div>" } ?? ""
            body += "<tr><td class=\"mono\">\(h.index)</td><td><b>\(esc(h.name.isEmpty ? "—" : h.name))</b>\(obj)</td>"
            body += "<td class=\"mono\">\(h.typeName)</td><td>\(badge(k))</td><td class=\"mono\">\(esc(h.dimsText))</td>"
            body += "<td class=\"mono muted\">\(h.isTable ? "" : String(h.bitpix))</td><td class=\"mono muted\">\(h.header.cards.count)</td></tr>"
        }
        body += "</tbody></table>"

        // per-HDU sections
        var extraImages = 0
        for (h, k) in zip(f.hdus, kinds).prefix(maxHDUSections) {
            body += "<section class=\"hdu\"><h2>HDU \(h.index) · \(esc(h.name.isEmpty ? "—" : h.name)) \(badge(k)) <span class=\"dims\">\(esc(h.typeName)) · \(esc(h.dimsText))</span></h2>"
            if hero?.hdu != h.index {
                if (k == .image || k == .cube) && extraImages < maxExtraImages, let v = f.imageVisual(h, maxSize: 480) {
                    extraImages += 1
                    body += "<figure class=\"small\">" + visualHTML(v, name: "hdu\(h.index).png", attachments: &attachments, cls: "small-img")
                    body += "<figcaption>\(esc(v.caption))</figcaption></figure>"
                } else if [.spectrum, .spectra, .spectrumTable].contains(k), let v = f.spectrumVisual(h) {
                    body += "<figure>" + visualHTML(v, name: "", attachments: &attachments, cls: "") + "</figure>"
                }
            }
            if case .image(let p, let z1, let z2, _)? = (hero?.hdu == h.index ? hero?.content : nil), k == .image || k == .cube {
                body += statsHTML(p, z1: z1, z2: z2, bunit: h.header.string("BUNIT"))
            }
            if k == .compressed {
                body += "<p class=\"note\">Tile-compressed image — open it in FITSView or DS9 to see the pixels.</p>"
            }
            if h.isTable && !h.isCompressedImage, let t = f.table(h) {
                body += tableHTML(f, t)
            }
            body += headerHTML(h, open: f.hdus.count == 1 && k == .empty)
            body += "</section>"
        }
        if f.hdus.count > maxHDUSections {
            body += "<p class=\"note\">… \(f.hdus.count - maxHDUSections) more HDUs not shown.</p>"
        }
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><style>\(css)</style></head><body>\(body)</body></html>"
        return PreviewDocument(html: html, attachments: attachments)
    }

    // MARK: pieces

    private static func visualHTML(_ v: Visual, name: String, attachments: inout [String: Data], cls: String) -> String {
        switch v.content {
        case .image(let p, let z1, let z2, let cmap):
            guard let img = makeCGImage(p, z1: z1, z2: z2, colormap: cmap), let png = pngData(img) else { return "" }
            attachments[name] = png
            return "<img class=\"\(cls)\" src=\"cid:\(name)\" width=\"\(p.width)\" height=\"\(p.height)\" alt=\"\">"
        case .spectrum(let s):
            return "<div class=\"svgwrap\">" + spectrumSVG(s) + "</div>"
        }
    }

    private static func statsHTML(_ p: ImagePlane, z1: Float, z2: Float, bunit: String?) -> String {
        let vals = p.pixels.filter(\.isFinite).sorted()
        guard !vals.isEmpty else { return "<p class=\"note\">All pixels are NaN.</p>" }
        let mean = vals.reduce(0, +) / Float(vals.count)
        let nanFrac = 1 - Double(vals.count) / Double(p.pixels.count)
        let items: [(String, String)] = [
            ("min", formatNumber(Double(vals.first!))), ("max", formatNumber(Double(vals.last!))),
            ("median", formatNumber(Double(vals[vals.count / 2]))), ("mean", formatNumber(Double(mean))),
            ("zscale", "\(formatNumber(Double(z1))) … \(formatNumber(Double(z2)))"),
            ("NaN", String(format: "%.1f%%", nanFrac * 100)), ("BUNIT", bunit ?? "—"),
        ]
        return "<dl class=\"stats\">" + items.map { "<div><dt>\($0.0)</dt><dd>\(esc($0.1))</dd></div>" }.joined() + "</dl>"
    }

    private static func tableHTML(_ f: FITSFile, _ t: FITSTable) -> String {
        let cols = Array(t.columns.prefix(previewCols))
        var s = "<details class=\"cols\"><summary>Columns (\(t.columns.count))</summary><table class=\"colinfo\"><tr><th>#</th><th>Name</th><th>Format</th><th>Unit</th><th>Shape</th></tr>"
        for (i, c) in t.columns.enumerated() {
            s += "<tr><td>\(i + 1)</td><td>\(esc(c.name))</td><td>\(esc(c.format))</td><td>\(esc(c.unit))</td><td>\(esc(c.shapeText))</td></tr>"
        }
        s += "</table></details>"
        let n = min(t.nrows, previewRows)
        guard n > 0 else { return s + "<p class=\"note\">Table has no rows.</p>" }
        s += "<div class=\"gridwrap\"><table class=\"grid\"><thead><tr><th>row</th>"
        for c in cols { s += "<th>\(esc(c.name))<span>\(esc(c.unit.isEmpty ? " " : c.unit))</span></th>" }
        s += "</tr></thead><tbody>"
        for r in 0..<n {
            s += "<tr><td class=\"rn\">\(r)</td>"
            for c in cols {
                let text = f.cellText(t, row: r, column: c)
                s += "<td\(c.isNumeric && !c.isVector ? "" : " class=\"str\"")>\(esc(text))</td>"
            }
            s += "</tr>"
        }
        s += "</tbody></table></div>"
        var notes = [String]()
        if t.nrows > n { notes.append("first \(n) of \(t.nrows) rows") }
        if t.columns.count > cols.count { notes.append("first \(cols.count) of \(t.columns.count) columns") }
        if !notes.isEmpty { s += "<p class=\"note\">Showing \(notes.joined(separator: ", ")).</p>" }
        return s
    }

    private static func headerHTML(_ h: HDU, open: Bool) -> String {
        let cards = h.header.cards
        var s = "<details class=\"header\"\(open ? " open" : "")><summary>Header (\(cards.count) cards)</summary><table class=\"cards\">"
        for c in cards.prefix(maxCards) {
            let commentary = c.value == nil
            var value = c.value ?? ""
            if c.isString { value = "'\(value)'" }
            s += "<tr\(commentary ? " class=\"hist\"" : "")><td class=\"key\">\(esc(c.key))</td>"
            s += commentary ? "<td class=\"val\" colspan=\"2\">\(esc(c.comment))</td>" : "<td class=\"val\">\(esc(value))</td><td class=\"com\">\(esc(c.comment))</td>"
            s += "</tr>"
        }
        if cards.count > maxCards { s += "<tr><td></td><td colspan=\"2\" class=\"com\">… \(cards.count - maxCards) more cards</td></tr>" }
        return s + "</table></details>"
    }

    private static func badge(_ k: HDUKind) -> String {
        let cls: String
        switch k {
        case .image, .spectra, .compressed: cls = "k-image"
        case .cube: cls = "k-cube"
        case .spectrum, .spectrumTable: cls = "k-spec"
        case .table, .groups: cls = "k-table"
        case .events: cls = "k-events"
        case .empty: cls = "k-empty"
        }
        return "<span class=\"badge \(cls)\">\(k.rawValue)</span>"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func byteSize(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }

    static let css = """
    :root{--bg:#fff;--panel:#f5f6f8;--border:#e1e4ea;--text:#1c2330;--muted:#6b7585;--accent:#2f6fde;--band:rgba(47,111,222,.16);
    --k-image:#2f6fde;--k-cube:#7b4fd6;--k-spec:#1b9a6c;--k-table:#b9720f;--k-events:#c4467a;--k-empty:#8a93a3;--img:#101318}
    @media (prefers-color-scheme:dark){:root{--bg:#1b1e25;--panel:#23272f;--border:#323845;--text:#e3e7ee;--muted:#8f99aa;--accent:#6b9cff;
    --band:rgba(107,156,255,.2);--k-image:#6b9cff;--k-cube:#a888f0;--k-spec:#48c595;--k-table:#e0a24a;--k-events:#e9799f;--k-empty:#7d8698}}
    *{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--text)}
    body{font:13px/1.45 -apple-system,system-ui,sans-serif;padding:18px 22px 30px}
    .mono,.cards,.grid,.colinfo td,.stats dd{font-family:ui-monospace,Menlo,monospace}
    .muted,.sub,.dims,.note,.caption,figcaption{color:var(--muted)}
    header{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap;margin-bottom:12px}
    h1{font-size:18px;margin:0;font-weight:650}h2{font-size:14px;margin:0 0 10px;font-weight:600}
    .hero{margin:0 0 18px}.hero-img,.small-img{display:block;max-width:100%;height:auto;image-rendering:pixelated;background:var(--img);border-radius:6px}
    .hero-img{width:auto;max-height:58vh;min-height:160px;margin:0 auto}
    .caption{text-align:center;margin-top:6px;font-size:12px}
    .svgwrap{background:var(--panel);border:1px solid var(--border);border-radius:8px;padding:6px}
    svg.plot{width:100%;height:auto;display:block}
    .plot .grid{stroke:var(--border);stroke-width:1}.plot .ax{fill:none;stroke:var(--muted);stroke-width:1}
    .plot .line{fill:none;stroke:var(--accent);stroke-width:1.3;stroke-linejoin:round}.plot .band{fill:var(--band);stroke:none}
    .plot .tick{fill:var(--muted);font-size:11px}.plot .label{fill:var(--text);font-size:12px}
    table{border-collapse:collapse}
    .hdus{width:100%;background:var(--panel);border-radius:8px;overflow:hidden;margin-bottom:8px}
    .hdus th{font-size:11px;font-weight:600;color:var(--muted);text-align:left;padding:6px 10px;border-bottom:1px solid var(--border)}
    .hdus td{padding:6px 10px;border-top:1px solid var(--border);white-space:nowrap}.sub{font-size:11px}
    .badge{display:inline-block;font-size:11px;font-weight:600;padding:1px 8px;border-radius:999px;color:var(--k);
    background:color-mix(in srgb,var(--k) 14%,transparent);vertical-align:1px}
    .k-image{--k:var(--k-image)}.k-cube{--k:var(--k-cube)}.k-spec{--k:var(--k-spec)}.k-table{--k:var(--k-table)}.k-events{--k:var(--k-events)}.k-empty{--k:var(--k-empty)}
    .hdu{border-top:1px solid var(--border);padding-top:14px;margin-top:16px}.dims{font-weight:400;font-size:12px;margin-left:6px}
    figure{margin:0 0 10px}figure.small{max-width:340px}figcaption{font-size:12px;margin-top:4px}
    .stats{display:flex;flex-wrap:wrap;gap:6px 18px;margin:0 0 10px}.stats div{display:flex;gap:6px}
    .stats dt{color:var(--muted)}.stats dd{margin:0}
    details{margin:6px 0}summary{cursor:pointer;color:var(--accent);font-weight:500;padding:2px 0}
    .cards{font-size:12px;width:100%}.cards td{padding:1px 10px 1px 0;vertical-align:top;border-bottom:1px solid var(--panel)}
    .cards .key{color:var(--accent);white-space:nowrap}.cards .val{white-space:pre-wrap;word-break:break-word}
    .cards .com,.cards .hist .val{color:var(--muted)}
    .colinfo{font-size:12px}.colinfo th,.colinfo td{text-align:left;padding:3px 14px 3px 0;border-bottom:1px solid var(--panel)}
    .gridwrap{overflow:auto;max-height:420px;border:1px solid var(--border);border-radius:6px;margin-top:6px}
    .grid{font-size:12px}.grid th,.grid td{padding:3px 10px;white-space:nowrap;text-align:right;border-right:1px solid var(--panel)}
    .grid th{position:sticky;top:0;background:var(--panel);font-family:-apple-system,system-ui,sans-serif;text-align:center}
    .grid th span{display:block;font-weight:400;font-size:10.5px;color:var(--muted)}
    .grid td.str{text-align:left}.grid td.rn{color:var(--muted);background:var(--panel)}
    .note{font-size:12px;margin:6px 0}
    """
}

// Minimal, dependency-free FITS reader used by the Quick Look extensions.
// Covers headers, uncompressed images (all BITPIX), binary and ASCII tables.

import Foundation

enum FITSError: Error, CustomStringConvertible {
    case notFITS

    var description: String { "not a FITS file" }
}

// MARK: - Header

struct FITSCard {
    let key: String
    let value: String?   // strings already unquoted
    let isString: Bool
    let comment: String
}

struct FITSHeader {
    let cards: [FITSCard]
    private let lookup: [String: FITSCard]

    init(_ cards: [FITSCard]) {
        self.cards = cards
        var d = [String: FITSCard]()
        for c in cards where c.value != nil && d[c.key] == nil { d[c.key] = c }
        lookup = d
    }

    func string(_ key: String) -> String? { lookup[key]?.value }

    func double(_ key: String) -> Double? {
        guard let v = lookup[key], !v.isString, let s = v.value else { return nil }
        return Double(s.replacingOccurrences(of: "D", with: "E").replacingOccurrences(of: "d", with: "e"))
    }

    func int(_ key: String) -> Int? {
        guard let v = lookup[key], !v.isString, let s = v.value else { return nil }
        if let i = Int(s) { return i }
        if let d = double(key), d.isFinite, d.rounded() == d, abs(d) < 9e18 { return Int(d) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        switch lookup[key]?.value { case "T": return true; case "F": return false; default: return nil }
    }

    static func parseCard(_ a: [UInt8]) -> FITSCard {
        func text(_ r: Range<Int>) -> String { String(decoding: a[r], as: UTF8.self) }
        func rtrim(_ s: String) -> String {
            var s = s
            while let last = s.last, last == " " || last == "\0" { s.removeLast() }
            return s
        }
        let quote = UInt8(ascii: "'"), slash = UInt8(ascii: "/"), space = UInt8(ascii: " ")
        var key = text(0..<8).trimmingCharacters(in: .whitespaces)
        var valueStart: Int?
        if key == "HIERARCH", let eq = a.firstIndex(of: UInt8(ascii: "=")) {
            key = text(8..<eq).trimmingCharacters(in: .whitespaces)
            valueStart = eq + 1
        } else if a[8] == UInt8(ascii: "="), a[9] == space, !["COMMENT", "HISTORY", ""].contains(key) {
            valueStart = 10
        }
        guard var i = valueStart else {
            return FITSCard(key: key, value: nil, isString: false, comment: rtrim(text(8..<80)))
        }
        while i < 80 && a[i] == space { i += 1 }
        if i < 80 && a[i] == quote {
            var s = [UInt8]()
            var j = i + 1
            while j < 80 {
                if a[j] == quote {
                    if j + 1 < 80 && a[j + 1] == quote { s.append(quote); j += 2; continue }
                    break
                }
                s.append(a[j]); j += 1
            }
            var comment = ""
            if j < 80, let sl = a[(j + 1)...].firstIndex(of: slash) {
                comment = text((sl + 1)..<80).trimmingCharacters(in: .whitespaces)
            }
            return FITSCard(key: key, value: rtrim(String(decoding: s, as: UTF8.self)), isString: true, comment: comment)
        }
        let sl = a[i...].firstIndex(of: slash) ?? 80
        let value = text(i..<sl).trimmingCharacters(in: .whitespaces)
        let comment = sl < 80 ? text((sl + 1)..<80).trimmingCharacters(in: .whitespaces) : ""
        return FITSCard(key: key, value: value.isEmpty ? nil : value, isString: false, comment: comment)
    }
}

// MARK: - HDU

enum HDUKind: String {
    case empty = "header only"
    case image
    case cube
    case spectrum = "1-D spectrum"
    case spectra = "spectra (rows)"
    case table
    case spectrumTable = "spectrum table"
    case events = "event list"
    case compressed = "compressed image"
    case groups = "random groups"
}

struct HDU {
    let index: Int
    let header: FITSHeader
    let dataOffset: Int
    let dataSize: Int

    var xtension: String {
        header.string("XTENSION")?.trimmingCharacters(in: .whitespaces).uppercased() ?? (index == 0 ? "PRIMARY" : "")
    }
    var name: String {
        if let n = header.string("EXTNAME"), !n.isEmpty { return n }
        return index == 0 ? "PRIMARY" : ""
    }
    var bitpix: Int { header.int("BITPIX") ?? 8 }
    var naxes: [Int] { (0..<max(0, header.int("NAXIS") ?? 0)).map { header.int("NAXIS\($0 + 1)") ?? 0 } }
    var isTable: Bool { xtension == "BINTABLE" || xtension == "TABLE" }
    var isCompressedImage: Bool { xtension == "BINTABLE" && header.bool("ZIMAGE") == true }
    var isGroups: Bool { header.bool("GROUPS") == true && naxes.first == 0 }
    var hasImageData: Bool { !isTable && !isGroups && !naxes.isEmpty && !naxes.contains(0) && dataSize > 0 }

    var typeName: String {
        if index == 0 { return isGroups ? "GroupsHDU" : "PrimaryHDU" }
        if isCompressedImage { return "CompImageHDU" }
        switch xtension {
        case "BINTABLE": return "BinTableHDU"
        case "TABLE": return "TableHDU"
        case "IMAGE": return "ImageHDU"
        default: return xtension.isEmpty ? "HDU" : xtension
        }
    }

    /// e.g. "512 × 512" or "6 cols × 80 rows"
    var dimsText: String {
        if isTable {
            if isCompressedImage {
                let z = (0..<(header.int("ZNAXIS") ?? 0)).map { String(header.int("ZNAXIS\($0 + 1)") ?? 0) }
                return z.joined(separator: " × ")
            }
            return "\(header.int("TFIELDS") ?? 0) cols × \(naxes.count > 1 ? naxes[1] : 0) rows"
        }
        return naxes.isEmpty ? "—" : naxes.map(String.init).joined(separator: " × ")
    }
}

// MARK: - File

final class FITSFile {
    let data: Data
    let hdus: [HDU]
    let fileSize: Int

    init(url: URL, maxHDUs: Int = 1000) throws {
        data = try Data(contentsOf: url, options: [.alwaysMapped])
        fileSize = data.count
        guard data.count >= 2880, data.prefix(9) == Data("SIMPLE  =".utf8) else { throw FITSError.notFITS }
        var list = [HDU]()
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset + 2880 <= raw.count && list.count < maxHDUs {
                guard let (header, length) = FITSFile.parseHeader(raw, at: offset, primary: offset == 0) else { break }
                let start = offset + length
                let size = FITSFile.dataSize(header)
                list.append(HDU(index: list.count, header: header, dataOffset: start, dataSize: size))
                offset = start + (size + 2879) / 2880 * 2880
            }
        }
        guard !list.isEmpty else { throw FITSError.notFITS }
        hdus = list
    }

    private static func parseHeader(_ raw: UnsafeRawBufferPointer, at start: Int, primary: Bool) -> (FITSHeader, Int)? {
        var cards = [FITSCard]()
        var pos = start
        while pos + 2880 <= raw.count && pos - start < 2880 * 10_000 {
            for c in 0..<36 {
                let off = pos + c * 80
                let card = FITSHeader.parseCard([UInt8](raw[off..<(off + 80)]))
                if cards.isEmpty && card.key != (primary ? "SIMPLE" : "XTENSION") { return nil }
                if card.key == "END" && card.value == nil { return (FITSHeader(cards), pos + 2880 - start) }
                cards.append(card)
            }
            pos += 2880
        }
        return nil
    }

    private static func dataSize(_ h: FITSHeader) -> Int {
        let naxis = h.int("NAXIS") ?? 0
        guard naxis > 0 else { return 0 }
        var dims = (1...naxis).map { max(0, h.int("NAXIS\($0)") ?? 0) }
        if dims[0] == 0 && h.bool("GROUPS") == true { dims.removeFirst() }
        let count = dims.reduce(1, *)
        let size = abs(h.int("BITPIX") ?? 8) / 8 * max(1, h.int("GCOUNT") ?? 1) * (max(0, h.int("PCOUNT") ?? 0) + count)
        return max(0, size)
    }

    // MARK: classification

    func kind(_ hdu: HDU) -> HDUKind {
        if hdu.isGroups { return .groups }
        if hdu.isCompressedImage { return .compressed }
        if hdu.isTable {
            guard let t = table(hdu) else { return .table }
            let names = Set(t.columns.map { $0.name.uppercased() })
            if names.contains("X") && names.contains("Y") && !names.isDisjoint(with: ["TIME", "PI", "PHA"]) { return .events }
            return t.spectrumGuess().y != nil ? .spectrumTable : .table
        }
        guard hdu.hasImageData else { return .empty }
        let dims = hdu.naxes
        let real = dims.filter { $0 > 1 }
        if real.count == 1 { return .spectrum }
        if dims.count == 2 && dims[1] <= 20 && dims[0] >= 10 * dims[1] { return .spectra }
        return real.count >= 3 ? .cube : .image
    }
}

// MARK: - Images

struct ImagePlane {
    let width: Int
    let height: Int
    var pixels: [Float]   // row 0 is the bottom row (FITS order)
}

extension FITSFile {
    /// One 2-D plane, block-averaged (or sub-sampled for huge images) so that
    /// the longest side is <= maxSize.
    func imagePlane(_ hdu: HDU, plane: Int = 0, maxSize: Int) -> ImagePlane? {
        let ax = hdu.naxes
        guard hdu.hasImageData, let w = ax.first else { return nil }
        let h = ax.count > 1 ? ax[1] : 1
        let bytes = abs(hdu.bitpix) / 8
        let planePixels = w * h
        let nplanes = ax.dropFirst(2).reduce(1, *)
        let p = min(max(plane, 0), max(nplanes - 1, 0))
        let base = hdu.dataOffset + p * planePixels * bytes
        guard bytes > 0, base + planePixels * bytes <= data.count else { return nil }

        let decoder = RowDecoder(hdu)
        let f = max(1, Int((Double(max(w, h)) / Double(max(maxSize, 1))).rounded(.up)))
        let ow = max(1, w / f), oh = max(1, h / f)
        let average = planePixels <= 16_000_000   // otherwise sub-sample: much less I/O
        var out = [Float](repeating: .nan, count: ow * oh)
        var row = [Float](repeating: 0, count: w)
        var sums = [Float](repeating: 0, count: ow)
        var counts = [Int32](repeating: 0, count: ow)

        data.withUnsafeBytes { raw in
            for oy in 0..<oh {
                for i in 0..<ow { sums[i] = 0; counts[i] = 0 }
                let ys = average ? Array((oy * f)..<min(h, oy * f + f)) : [min(h - 1, oy * f + f / 2)]
                for y in ys {
                    decoder.decode(raw, offset: base + y * w * bytes, count: w, into: &row)
                    for ox in 0..<ow {
                        if average {
                            for x in (ox * f)..<min(w, ox * f + f) where row[x].isFinite {
                                sums[ox] += row[x]; counts[ox] += 1
                            }
                        } else {
                            let v = row[min(w - 1, ox * f + f / 2)]
                            if v.isFinite { sums[ox] = v; counts[ox] = 1 }
                        }
                    }
                }
                for ox in 0..<ow where counts[ox] > 0 { out[oy * ow + ox] = sums[ox] / Float(counts[ox]) }
            }
        }
        return ImagePlane(width: ow, height: oh, pixels: out)
    }

    /// First row of an image HDU at full resolution (1-D spectra, multispec rows).
    func imageRow(_ hdu: HDU, row: Int = 0, limit: Int = 4_000_000) -> [Double] {
        let ax = hdu.naxes
        guard hdu.hasImageData else { return [] }
        let real = ax.filter { $0 > 1 }
        let n = real.count == 1 ? real[0] : ax[0]
        let bytes = abs(hdu.bitpix) / 8
        let count = min(n, limit)
        let start = hdu.dataOffset + (real.count == 1 ? 0 : row * ax[0] * bytes)
        guard start + count * bytes <= data.count else { return [] }
        var buf = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { RowDecoder(hdu).decode($0, offset: start, count: count, into: &buf) }
        return buf.map(Double.init)
    }
}

/// Decodes big-endian image pixels (any BITPIX) with BSCALE/BZERO/BLANK applied.
struct RowDecoder {
    let bitpix: Int
    let scale: Double
    let zero: Double
    let blank: Int64?

    init(_ hdu: HDU) {
        bitpix = hdu.bitpix
        scale = hdu.header.double("BSCALE") ?? 1
        zero = hdu.header.double("BZERO") ?? 0
        blank = hdu.bitpix > 0 ? hdu.header.int("BLANK").map(Int64.init) : nil
    }

    func decode(_ raw: UnsafeRawBufferPointer, offset off: Int, count n: Int, into out: inout [Float]) {
        let s = scale, z = zero
        @inline(__always) func integer(_ v: Int64) -> Float {
            if let b = blank, v == b { return .nan }
            return Float(Double(v) * s + z)
        }
        switch bitpix {
        case 8:
            for i in 0..<n { out[i] = integer(Int64(raw[off + i])) }
        case 16:
            for i in 0..<n { out[i] = integer(Int64(Int16(bigEndian: raw.loadUnaligned(fromByteOffset: off + 2 * i, as: Int16.self)))) }
        case 32:
            for i in 0..<n { out[i] = integer(Int64(Int32(bigEndian: raw.loadUnaligned(fromByteOffset: off + 4 * i, as: Int32.self)))) }
        case 64:
            for i in 0..<n { out[i] = integer(Int64(bigEndian: raw.loadUnaligned(fromByteOffset: off + 8 * i, as: Int64.self))) }
        case -32:
            let fs = Float(s), fz = Float(z), plain = s == 1 && z == 0
            for i in 0..<n {
                let v = Float(bitPattern: UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off + 4 * i, as: UInt32.self)))
                out[i] = plain ? v : v * fs + fz
            }
        case -64:
            for i in 0..<n {
                let v = Double(bitPattern: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: off + 8 * i, as: UInt64.self)))
                out[i] = Float(v * s + z)
            }
        default:
            for i in 0..<n { out[i] = .nan }
        }
    }
}

// MARK: - Tables

struct FITSColumn {
    let name: String
    let unit: String
    let format: String
    let code: Character      // TFORM type letter (bintable) or A/I/F/E/D (ascii)
    let repeatCount: Int
    let vlaCode: Character?  // element type of P/Q descriptors
    let offset: Int          // byte offset within the row
    let width: Int           // bytes in the row
    let scale: Double
    let zero: Double
    let null: Int64?
    let dim: String

    var isNumeric: Bool { "BIJKED".contains(code) || (vlaCode.map { "BIJKED".contains($0) } ?? false) }
    var isVector: Bool { (repeatCount > 1 && code != "A") || vlaCode != nil }
    var shapeText: String {
        if vlaCode != nil { return "var" }
        if !dim.isEmpty { return dim.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).replacingOccurrences(of: ",", with: "×") }
        return repeatCount > 1 && code != "A" ? "\(repeatCount)" : ""
    }
}

struct FITSTable {
    let hdu: HDU
    let ascii: Bool
    let columns: [FITSColumn]
    let rowWidth: Int
    let nrows: Int

    func column(named n: String) -> FITSColumn? { columns.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }

    private static let waveNames: Set<String> = ["wave", "wavelength", "lambda", "wl", "wav", "loglam", "lam", "freq",
                                                 "frequency", "energy", "e_mid", "channel", "vel", "velocity"]
    private static let fluxNames: Set<String> = ["flux", "f_lambda", "flam", "fnu", "f_nu", "flux_density", "counts",
                                                 "rate", "intensity", "spec", "spectrum", "sci"]
    private static let errNames: Set<String> = ["err", "error", "flux_err", "fluxerr", "flux_error", "sigma", "stat_err",
                                                "e_flux", "ivar", "uncertainty", "noise"]

    /// Same heuristics as the Python viewer (fitsinfo.guess_spectrum_columns).
    func spectrumGuess() -> (x: FITSColumn?, y: FITSColumn?, err: FITSColumn?) {
        let num = columns.filter(\.isNumeric)
        let x = num.first { Self.waveNames.contains($0.name.lowercased()) }
        let y = num.first { Self.fluxNames.contains($0.name.lowercased()) && $0.name != x?.name }
        let e = num.first { Self.errNames.contains($0.name.lowercased()) && $0.name != x?.name && $0.name != y?.name }
        return (x, y, e)
    }
}

extension FITSFile {
    func table(_ hdu: HDU) -> FITSTable? {
        guard hdu.isTable, hdu.naxes.count == 2 else { return nil }
        let h = hdu.header
        let ascii = hdu.xtension == "TABLE"
        var cols = [FITSColumn]()
        var offset = 0
        for i in 1...max(1, h.int("TFIELDS") ?? 0) where (h.int("TFIELDS") ?? 0) > 0 {
            let tform = (h.string("TFORM\(i)") ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            var rest = Substring(tform)
            let digits = rest.prefix { $0.isNumber }
            rest = rest.dropFirst(digits.count)
            guard let code = rest.first else { return nil }
            var repeatCount = Int(digits) ?? 1
            var vla: Character?
            var width: Int
            var colOffset = offset
            if ascii {
                repeatCount = 1
                width = Int(rest.dropFirst().prefix { $0.isNumber }) ?? 0
                colOffset = (h.int("TBCOL\(i)") ?? 1) - 1
            } else {
                switch code {
                case "L", "B", "A": width = repeatCount
                case "X": width = (repeatCount + 7) / 8
                case "I": width = 2 * repeatCount
                case "J", "E": width = 4 * repeatCount
                case "K", "D", "C": width = 8 * repeatCount
                case "M": width = 16 * repeatCount
                case "P": width = 8 * repeatCount; vla = rest.dropFirst().first
                case "Q": width = 16 * repeatCount; vla = rest.dropFirst().first
                default: return nil
                }
                offset += width
            }
            cols.append(FITSColumn(
                name: h.string("TTYPE\(i)") ?? "col\(i)", unit: h.string("TUNIT\(i)") ?? "", format: tform,
                code: code, repeatCount: repeatCount, vlaCode: vla, offset: colOffset, width: width,
                scale: h.double("TSCAL\(i)") ?? 1, zero: h.double("TZERO\(i)") ?? 0,
                null: h.int("TNULL\(i)").map(Int64.init), dim: h.string("TDIM\(i)") ?? ""))
        }
        let rowWidth = hdu.naxes[0], nrows = hdu.naxes[1]
        guard ascii || offset <= rowWidth, hdu.dataOffset + rowWidth * nrows <= data.count else { return nil }
        return FITSTable(hdu: hdu, ascii: ascii, columns: cols, rowWidth: rowWidth, nrows: nrows)
    }

    /// Element `element` of a numeric cell, scaled; NaN for TNULL / unparsable.
    private func number(_ raw: UnsafeRawBufferPointer, _ t: FITSTable, _ c: FITSColumn, row: Int, element: Int) -> Double {
        let base = t.hdu.dataOffset + row * t.rowWidth + c.offset
        if t.ascii {
            let s = String(decoding: raw[base..<(base + c.width)], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "D", with: "E")
            return (Double(s) ?? .nan) * c.scale + c.zero
        }
        func scaled(_ v: Int64) -> Double { (c.null != nil && v == c.null!) ? .nan : Double(v) * c.scale + c.zero }
        switch c.code {
        case "B": return scaled(Int64(raw[base + element]))
        case "I": return scaled(Int64(Int16(bigEndian: raw.loadUnaligned(fromByteOffset: base + 2 * element, as: Int16.self))))
        case "J": return scaled(Int64(Int32(bigEndian: raw.loadUnaligned(fromByteOffset: base + 4 * element, as: Int32.self))))
        case "K": return scaled(Int64(bigEndian: raw.loadUnaligned(fromByteOffset: base + 8 * element, as: Int64.self)))
        case "E":
            let v = Float(bitPattern: UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: base + 4 * element, as: UInt32.self)))
            return Double(v) * c.scale + c.zero
        case "D":
            let v = Double(bitPattern: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: base + 8 * element, as: UInt64.self)))
            return v * c.scale + c.zero
        case "L": return raw[base + element] == UInt8(ascii: "T") ? 1 : 0
        default: return .nan
        }
    }

    /// Whole scalar column (sub-sampled to <= limit rows), or one vector cell when `row` is given.
    func values(_ t: FITSTable, _ c: FITSColumn, row: Int? = nil, limit: Int = 400_000) -> [Double] {
        data.withUnsafeBytes { raw in
            if let r = row {
                guard r < t.nrows, c.vlaCode == nil else { return [] }
                return (0..<min(c.repeatCount, limit)).map { number(raw, t, c, row: r, element: $0) }
            }
            let step = max(1, (t.nrows + limit - 1) / limit)
            return stride(from: 0, to: t.nrows, by: step).map { number(raw, t, c, row: $0, element: 0) }
        }
    }

    func cellText(_ t: FITSTable, row: Int, column c: FITSColumn) -> String {
        data.withUnsafeBytes { raw in
            let base = t.hdu.dataOffset + row * t.rowWidth + c.offset
            guard base + c.width <= raw.count else { return "" }
            if t.ascii || c.code == "A" {
                return String(decoding: raw[base..<(base + c.width)].prefix { $0 != 0 }, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
            }
            switch c.code {
            case "L":
                return (0..<c.repeatCount).map { i -> String in
                    switch raw[base + i] { case UInt8(ascii: "T"): return "T"; case UInt8(ascii: "F"): return "F"; default: return "—" }
                }.joined(separator: " ")
            case "X":
                return "0x" + raw[base..<(base + c.width)].map { String(format: "%02X", $0) }.joined()
            case "P", "Q":
                let n = c.code == "P"
                    ? Int(Int32(bigEndian: raw.loadUnaligned(fromByteOffset: base, as: Int32.self)))
                    : Int(Int64(bigEndian: raw.loadUnaligned(fromByteOffset: base, as: Int64.self)))
                return "var[\(n)]"
            case "C", "M":
                let d = c.code == "M"
                func part(_ k: Int) -> Double {
                    d ? Double(bitPattern: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: base + 8 * k, as: UInt64.self)))
                      : Double(Float(bitPattern: UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: base + 4 * k, as: UInt32.self))))
                }
                return "(\(formatNumber(part(0))), \(formatNumber(part(1))))" + (c.repeatCount > 1 ? " …" : "")
            default:
                let integer = "BIJK".contains(c.code) && c.scale == 1 && c.zero.rounded() == c.zero
                func fmt(_ k: Int) -> String {
                    let v = number(raw, t, c, row: row, element: k)
                    if v.isNaN { return "—" }
                    return integer ? String(Int64(v)) : formatNumber(v)
                }
                if c.repeatCount == 1 { return fmt(0) }
                if c.repeatCount <= 6 { return "[" + (0..<c.repeatCount).map(fmt).joined(separator: ", ") + "]" }
                return "[\(c.repeatCount)] " + (0..<3).map(fmt).joined(separator: ", ") + ", …"
            }
        }
    }
}

func formatNumber(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v > 0 ? "inf" : "-inf" }
    if v.rounded() == v && abs(v) < 1e15 { return String(Int64(v)) }
    let a = abs(v)
    if a < 1e-3 || a >= 1e7 { return String(format: "%.5e", v) }
    var s = String(format: "%.7g", v)
    if s.contains(".") && !s.contains("e") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s
}

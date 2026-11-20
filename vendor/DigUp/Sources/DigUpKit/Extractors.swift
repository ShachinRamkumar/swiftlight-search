import Foundation

enum ExtractError: Error, CustomStringConvertible {
    case unreadable(String)
    case tooSmall(Int, Int)
    case locked
    case empty(String)
    /// Not for the index after all, once read (code that a program made, or that holds a private key).
    case leftOut(String)

    var description: String {
        switch self {
        case .unreadable(let why): "unreadable: \(why)"
        case .tooSmall(let width, let height): "small image \(width)×\(height)"
        case .locked: "password-protected"
        case .empty(let why): why
        case .leftOut(let why): why
        }
    }
}

/// Pictures for the model: a downscaled copy of each image (`prepare`) and the camera's date. ImageIO on macOS (HEIC,
/// RAW, WebP and friends); stb_image elsewhere (Platform/).
enum ImageExtractor {
    struct Prepared: Sendable {
        let path: String
        let width: Int
        let height: Int
        let taken: String?   // EXIF DateTimeOriginal, as written by the camera
    }
}

/// Text recognition in screenshots, for keyword search only: Apple Vision on macOS, nothing elsewhere yet.
enum OCR {}

/// Plain words for what a picture shows: the colours covering much of it, and on macOS what Apple Vision sees in it
/// ("dog", "chart", "beach"). Not searched by themselves: the launcher shows a picture that only half stands out by
/// meaning when these words agree with the query ("red and blue screenshot": the model ranked the right one 2nd of
/// 4.7k pictures, but 3.3 deviations out, under the gate that keeps noise away, 2026-10-13).
enum ImageTags {
    /// Colours of at least this share of the picture's pixels.
    static let colourShare = 0.12

    /// A pixel's colour name: neutral below a fifth of saturation, else by hue.
    static func colour(red r: Double, green g: Double, blue b: Double) -> String {
        let high = max(r, g, b), low = min(r, g, b), spread = high - low
        if high < 0.2 { return "black" }
        if spread / high < 0.2 { return high > 0.85 ? "white" : "gray" }
        var hue: Double
        if high == r { hue = 60 * ((g - b) / spread).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = 60 * ((b - r) / spread + 2) }
        else { hue = 60 * ((r - g) / spread + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15, 345...: return "red"
        case ..<40: return high < 0.6 ? "brown" : "orange"
        case ..<65: return "yellow"
        case ..<165: return "green"
        case ..<195: return "teal"
        case ..<255: return "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }

    /// The colours of packed RGBA or RGB pixels (`stride` bytes each), most covered first.
    static func colours(_ pixels: [UInt8], stride: Int) -> [String] {
        var counts: [String: Int] = [:]
        var total = 0
        for i in Swift.stride(from: 0, to: pixels.count - stride + 1, by: stride) {
            counts[colour(red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255,
                          blue: Double(pixels[i + 2]) / 255), default: 0] += 1
            total += 1
        }
        guard total > 0 else { return [] }
        return counts.filter { Double($0.value) >= colourShare * Double(total) }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)
    }
}

/// PDF pages as text, or as pictures when they have little text (scans, slides): PDFKit on macOS, PDFium elsewhere.
enum PDFExtractor {
    struct Page: Sendable {
        let number: Int        // 1-based
        let text: String       // may be empty for scans
        let imagePath: String? // set when the page had too little text and was rendered for the vision encoder
        var ocr = false        // the text came from OCR: the text layer was garbled (`PageTextProblem.lostLetters`)
        /// Text read in glyph order (`PageTextProblem.glyphOrder`): too garbled to show or match words against, but
        /// enough of its words survive for a meaning vector beside the page's picture.
        var garbled: String?
    }
}

enum DocExtractor {
    /// Plain text from txt/md directly, HTML by stripping tags, and rtf/docx/doc/odt through `richText` (the Cocoa
    /// text system on macOS, the files' own XML elsewhere).
    static func text(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx", "doc", "odt", "rtf": return try richText(of: url, type: ext)
        case "html", "htm": return plainText(fromHTML: try readText(url))
        default: return try readText(url)
        }
    }

    static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    /// Good enough for search: drops scripts, styles and comments, turns block ends into line breaks, strips the
    /// remaining tags, and decodes common entities.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b.*?</script\s*>"#, #"(?is)<style\b.*?</style\s*>"#, #"(?s)<!--.*?-->"#,
                        #"(?is)<head\b.*?</head\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"#,
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        text = decodeNumericEntities(text)
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let codeRange = Range(match.range(at: 1), in: text)
            else { continue }
            let code = text[codeRange]
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            result += text[last..<range.lowerBound]
            result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? " "
            last = range.upperBound
        }
        return result + text[last...]
    }

    /// Splits text into ~`size`-character pieces (~450 tokens) that overlap a little, breaking at whitespace.
    static func chunks(_ text: String, size: Int = 1800, overlap: Int = 200, limit: Int) -> [String] {
        let clean = text
            // A plain string, so Swift puts the real tab and no-break space in the class: ICU doesn't read \u{…}, and
            // an invalid pattern leaves the text as it is on macOS but empties it on Linux (found by the port).
            .replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [String] = []
        var start = clean.startIndex
        while start < clean.endIndex, chunks.count < limit {
            var end = clean.index(start, offsetBy: size, limitedBy: clean.endIndex) ?? clean.endIndex
            if end < clean.endIndex, let space = clean[start..<end].lastIndex(where: \.isWhitespace),
               clean.distance(from: start, to: space) > size / 2 {
                end = space
            }
            let chunk = clean[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            guard end < clean.endIndex else { break }
            var next = clean.index(end, offsetBy: -overlap, limitedBy: start) ?? end
            if next <= start { next = end }
            // Start the next chunk on a word boundary.
            while next < end, !clean[next].isWhitespace { next = clean.index(after: next) }
            start = next < end ? next : end
        }
        return chunks
    }
}

/// One line, at most `limit` characters: for result lists.
func excerpt(_ text: String, limit: Int = 240) -> String {
    // Only the start is shown, so only the start is cleaned up (a page or a chunk can be thousands of characters).
    let start = text.prefix(limit * 8)
    let line = String(start).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return line.count > limit || start.endIndex < text.endIndex ? String(line.prefix(limit)) + "…" : line
}

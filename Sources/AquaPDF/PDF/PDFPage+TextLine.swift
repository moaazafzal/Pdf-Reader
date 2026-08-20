import AppKit
import PDFKit

/// Caches per-page glyph rectangles. `characterBounds(at:)` is slow enough that scanning a
/// text-heavy page on every mouse-moved event is visibly laggy without this.
private final class GlyphBoundsCache {
    static let shared = GlyphBoundsCache()
    private let table = NSMapTable<PDFPage, NSArray>.weakToStrongObjects()
    private let lock = NSLock()

    func bounds(for page: PDFPage, count: Int) -> [CGRect] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = table.object(forKey: page) as? [CGRect], cached.count == count {
            return cached
        }
        let rects = (0..<count).map { page.characterBounds(at: $0) }
        table.setObject(rects as NSArray, forKey: page)
        return rects
    }
}

extension PDFPage {
    struct TextLine {
        let rect: CGRect
        let text: String
    }

    /// Finds the line of page text under `point`.
    ///
    /// PDFKit's `selectionForLine(at:)` ignores the point on many documents (it returns the
    /// same line wherever you click), so the line is reconstructed from character bounds.
    func textLine(at point: CGPoint) -> TextLine? {
        guard let full = string as NSString? else { return nil }
        let count = min(numberOfCharacters, full.length)
        guard count > 0 else { return nil }

        let glyphs = GlyphBoundsCache.shared.bounds(for: self, count: count)

        var hitIndex = -1
        for i in 0..<count where glyphs[i].insetBy(dx: -1, dy: -2).contains(point) {
            hitIndex = i
            break
        }
        guard hitIndex >= 0 else { return nil }
        let hitBounds = glyphs[hitIndex]

        func onSameLine(_ i: Int) -> Bool {
            let b = glyphs[i]
            guard b.height > 0, b.width > 0 else { return false }
            return abs(b.midY - hitBounds.midY) < max(hitBounds.height, b.height) * 0.6
        }

        // Walk outward, tolerating a few glyphless characters (spaces and the line breaks
        // PDFKit inserts mid-line) before deciding the line has ended.
        let maxSkip = 4
        var start = hitIndex, skips = 0, i = hitIndex - 1
        while i >= 0 {
            if onSameLine(i) { start = i; skips = 0 }
            else if skips < maxSkip { skips += 1 }
            else { break }
            i -= 1
        }
        var end = hitIndex
        skips = 0
        i = hitIndex + 1
        while i < count {
            if onSameLine(i) { end = i; skips = 0 }
            else if skips < maxSkip { skips += 1 }
            else { break }
            i += 1
        }

        var rect = CGRect.null
        for i in start...end where onSameLine(i) { rect = rect.union(glyphs[i]) }
        guard !rect.isNull, rect.height > 1 else { return nil }

        let raw = full.substring(with: NSRange(location: start, length: end - start + 1))
        let text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return TextLine(rect: rect, text: text)
    }
}

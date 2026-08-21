import AppKit
import PDFKit

enum PDFOperations {

    // MARK: - Image burn-in (signatures, image stamps)

    /// Draws `image` into the actual page content (vector page preserved underneath),
    /// so the result survives in every PDF reader. Existing annotations are re-attached.
    static func burnImage(_ image: NSImage, centeredAt point: CGPoint, pageIndex: Int, in document: PDFDocument) {
        let maxWidth: CGFloat = 180
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        burnImage(image, in: target, pageIndex: pageIndex, in: document)
    }

    static func burnImage(_ image: NSImage, in rect: CGRect, pageIndex: Int, in document: PDFDocument) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        rebuildPage(at: pageIndex, in: document) { ctx in
            ctx.draw(cgImage, in: rect)
        }
    }

    /// Replaces `pageIndex` with a rebuilt page: original vector content + custom overlay drawing.
    /// Existing annotations are moved onto the rebuilt page.
    static func rebuildPage(at pageIndex: Int, in document: PDFDocument, overlay: (CGContext) -> Void) {
        guard let page = document.page(at: pageIndex), let cgPage = page.pageRef else { return }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return }
        var box = page.bounds(for: .mediaBox)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }

        ctx.beginPDFPage(nil)
        ctx.drawPDFPage(cgPage)
        overlay(ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        guard let newDoc = PDFDocument(data: data as Data), let newPage = newDoc.page(at: 0) else { return }

        // Move existing annotations onto the rebuilt page.
        let annotations = page.annotations
        for a in annotations { page.removeAnnotation(a) }
        newPage.rotation = page.rotation
        document.removePage(at: pageIndex)
        document.insert(newPage, at: pageIndex)
        for a in annotations { newPage.addAnnotation(a) }
    }

    /// Flattens all interactive `ImageStampAnnotation`s (signatures, placed images)
    /// into real page content. Called before every save.
    static func burnImageStamps(in document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let stamps = page.annotations.compactMap { $0 as? ImageStampAnnotation }
            for stamp in stamps {
                page.removeAnnotation(stamp)
                burnImage(stamp.image, in: stamp.bounds, pageIndex: i, in: document)
            }
        }
    }

    // MARK: - Redaction (true, destructive)

    /// Applies all redaction marks: affected pages are re-rendered to 300 dpi images with
    /// black boxes, so the text and graphics underneath are REMOVED, not just covered.
    /// Returns the number of pages redacted.
    static func applyRedactions(in document: PDFDocument) -> Int {
        var redactedPages = 0
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let cgPage = page.pageRef else { continue }
            let marks = page.annotations.filter { $0.isRedactionMark }
            guard !marks.isEmpty else { continue }
            let others = page.annotations.filter { !$0.isRedactionMark }

            let mediaBox = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let dims = rotated
                ? CGSize(width: mediaBox.height, height: mediaBox.width)
                : mediaBox.size
            let scale: CGFloat = 300 / 72

            guard let bitmap = CGContext(
                data: nil,
                width: max(1, Int(dims.width * scale)),
                height: max(1, Int(dims.height * scale)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(origin: .zero, size: CGSize(width: dims.width * scale, height: dims.height * scale)))
            bitmap.scaleBy(x: scale, y: scale)
            let transform = cgPage.getDrawingTransform(
                .mediaBox,
                rect: CGRect(origin: .zero, size: dims),
                rotate: 0,
                preserveAspectRatio: true
            )
            bitmap.concatenate(transform)
            bitmap.drawPDFPage(cgPage)

            // Rotated pages: annotation coordinates would not survive the rebuild — flatten them too.
            if page.rotation != 0 {
                for a in others { a.draw(with: .mediaBox, in: bitmap) }
            }

            bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
            for mark in marks { bitmap.fill(mark.bounds) }

            guard let cgImage = bitmap.makeImage() else { continue }
            let image = NSImage(cgImage: cgImage, size: dims)
            guard let newPage = PDFPage(image: image) else { continue }

            for a in page.annotations { page.removeAnnotation(a) }
            document.removePage(at: i)
            document.insert(newPage, at: i)
            if page.rotation == 0 {
                for a in others { newPage.addAnnotation(a) }
            }
            redactedPages += 1
        }
        return redactedPages
    }

    // MARK: - Edit text (beta)

    /// Replaces one text line: paints the original line over with the page background color
    /// and burns the replacement text into page content.
    static func replaceTextLine(
        in document: PDFDocument,
        pageIndex: Int,
        lineRect: CGRect,
        newText: String,
        font textFont: NSFont? = nil,
        textColor: NSColor = .black,
        backgroundColor: NSColor = .white
    ) {
        rebuildPage(at: pageIndex, in: document) { ctx in
            ctx.setFillColor(backgroundColor.cgColor)
            ctx.fill(lineRect.insetBy(dx: -1, dy: -1))

            guard !newText.isEmpty else { return }
            let font = textFont ?? NSFont(name: "Helvetica", size: lineRect.height * 0.72)
                ?? .systemFont(ofSize: lineRect.height * 0.72)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: textColor.cgColor,
            ]
            guard let attrString = CFAttributedStringCreate(nil, newText as CFString, attributes as CFDictionary)
            else { return }
            let line = CTLineCreateWithAttributedString(attrString)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

            ctx.saveGState()
            ctx.setTextDrawingMode(.fill)
            // Shrink horizontally if the new text is wider than the original line box.
            let fit = width > lineRect.width ? lineRect.width / width : 1
            ctx.textMatrix = CGAffineTransform(scaleX: fit, y: 1)
            ctx.textPosition = CGPoint(x: lineRect.origin.x, y: lineRect.origin.y + lineRect.height * 0.22)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    /// Renders a page-space rectangle to an image (SnapShot, loupe, magnifier).
    static func renderRegion(_ rect: CGRect, of page: PDFPage, scale: CGFloat = 2) -> NSImage? {
        guard rect.width > 0, rect.height > 0, let cgPage = page.pageRef else { return nil }
        let pixelSize = CGSize(width: max(rect.width * scale, 1), height: max(rect.height * scale, 1))

        // Draw only the requested region. Rendering the whole page and cropping made
        // the loupe and SnapShot far more expensive than they needed to be.
        guard let ctx = CGContext(
            data: nil,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: pixelSize))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.drawPDFPage(cgPage)
        for annotation in page.annotations where annotation.shouldDisplay {
            annotation.draw(with: .mediaBox, in: ctx)
        }
        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: rect.size)
    }


    // MARK: - Page numbering

    /// Where a page number is stamped on the page.
    enum NumberPosition: String, CaseIterable, Identifiable {
        case topLeft = "Top Left"
        case topCenter = "Top Center"
        case topRight = "Top Right"
        case bottomLeft = "Bottom Left"
        case bottomCenter = "Bottom Center"
        case bottomRight = "Bottom Right"
        var id: String { rawValue }
        var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }
    }

    /// How the number is rendered.
    enum NumberFormat: String, CaseIterable, Identifiable {
        case plain = "1"
        case pageN = "Page 1"
        case ofTotal = "1 of N"
        case pageOfTotal = "Page 1 of N"
        case roman = "i, ii, iii"
        case letters = "A, B, C"
        var id: String { rawValue }
    }

    struct PageNumberOptions {
        var position: NumberPosition = .bottomCenter
        var format: NumberFormat = .plain
        var startNumber = 1
        /// Zero-based page range that receives numbers.
        var range: ClosedRange<Int>?
        var fontSize: CGFloat = 11
        var margin: CGFloat = 28
        var color: NSColor = .black
        var prefix = ""
    }

    static func romanNumeral(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remaining = value, out = ""
        for (number, symbol) in table {
            while remaining >= number { out += symbol; remaining -= number }
        }
        return out
    }

    /// Spreadsheet-style letters: A, B, ... Z, AA, AB, …
    static func letterLabel(_ value: Int) -> String {
        guard value > 0 else { return "" }
        var remaining = value, out = ""
        while remaining > 0 {
            let index = (remaining - 1) % 26
            out = String(UnicodeScalar(65 + index)!) + out
            remaining = (remaining - 1) / 26
        }
        return out
    }

    static func pageNumberText(number: Int, total: Int, options: PageNumberOptions) -> String {
        let body: String
        switch options.format {
        case .plain: body = "\(number)"
        case .pageN: body = "Page \(number)"
        case .ofTotal: body = "\(number) of \(total)"
        case .pageOfTotal: body = "Page \(number) of \(total)"
        case .roman: body = romanNumeral(number)
        case .letters: body = letterLabel(number)
        }
        return options.prefix.isEmpty ? body : options.prefix + " " + body
    }

    /// Stamps page numbers into real page content, so they print and appear in every reader.
    /// The whole document is rebuilt in a single pass and annotations are carried over.
    @discardableResult
    static func insertPageNumbers(in document: PDFDocument, options: PageNumberOptions) -> Int {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return 0 }
        let range = options.range ?? 0...(pageCount - 1)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return 0 }
        var firstBox = document.page(at: 0)?.bounds(for: .mediaBox)
            ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return 0 }

        let numbered = range.count
        var stamped = 0

        for i in 0..<pageCount {
            guard let page = document.page(at: i), let cgPage = page.pageRef else { continue }
            var box = page.bounds(for: .mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox: NSData(
                bytes: &box, length: MemoryLayout<CGRect>.size
            )] as CFDictionary)
            ctx.drawPDFPage(cgPage)

            if range.contains(i) {
                let number = options.startNumber + (i - range.lowerBound)
                let text = pageNumberText(number: number, total: numbered, options: options)
                draw(pageNumber: text, in: box, options: options, context: ctx)
                stamped += 1
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard let rebuilt = PDFDocument(data: data as Data), rebuilt.pageCount == pageCount else { return 0 }

        // Move annotations and rotation onto the rebuilt pages, then swap the pages in.
        for i in 0..<pageCount {
            guard let old = document.page(at: i), let new = rebuilt.page(at: i) else { continue }
            new.rotation = old.rotation
            let annotations = old.annotations
            for a in annotations { old.removeAnnotation(a) }
            for a in annotations { new.addAnnotation(a) }
        }
        for i in stride(from: pageCount - 1, through: 0, by: -1) {
            document.removePage(at: i)
        }
        for i in 0..<pageCount {
            guard let new = rebuilt.page(at: i) else { continue }
            document.insert(new, at: i)
        }
        return stamped
    }

    private static func draw(
        pageNumber text: String,
        in box: CGRect,
        options: PageNumberOptions,
        context ctx: CGContext
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, options.fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: options.color.cgColor,
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        let x: CGFloat
        switch options.position {
        case .topLeft, .bottomLeft:
            x = box.minX + options.margin
        case .topCenter, .bottomCenter:
            x = box.midX - width / 2
        case .topRight, .bottomRight:
            x = box.maxX - options.margin - width
        }
        let y = options.position.isTop
            ? box.maxY - options.margin - options.fontSize
            : box.minY + options.margin

        ctx.saveGState()
        ctx.setTextDrawingMode(.fill)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Merge / split / extract

    static func merge(urls: [URL], into document: PDFDocument) {
        for url in urls {
            guard let other = PDFDocument(url: url) else { continue }
            for i in 0..<other.pageCount {
                guard let page = other.page(at: i)?.copy() as? PDFPage else { continue }
                document.insert(page, at: document.pageCount)
            }
        }
    }

    static func splitIntoSinglePages(_ document: PDFDocument, baseName: String, directory: URL) throws -> Int {
        var written = 0
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let url = directory.appendingPathComponent("\(baseName)-page-\(i + 1).pdf")
            guard single.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
            written += 1
        }
        return written
    }

    static func extract(pageIndexes: [Int], from document: PDFDocument, to url: URL) throws {
        let out = PDFDocument()
        for (n, i) in pageIndexes.sorted().enumerated() {
            guard let page = document.page(at: i)?.copy() as? PDFPage else { continue }
            out.insert(page, at: n)
        }
        guard out.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Compress / protect

    static func writeCompressed(_ document: PDFDocument, to url: URL) throws {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        guard document.write(to: url, withOptions: options) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func writeProtected(_ document: PDFDocument, to url: URL, password: String) throws {
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ]
        guard document.write(to: url, withOptions: options) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Burns all annotations into page content (rasterizes their appearance, keeps page vectors).
    static func writeFlattened(_ document: PDFDocument, to url: URL) throws {
        if #available(macOS 13, *) {
            let options: [PDFDocumentWriteOption: Any] = [.burnInAnnotationsOption: true]
            guard document.write(to: url, withOptions: options) else { throw CocoaError(.fileWriteUnknown) }
            return
        }
        // Big Sur / Monterey: draw each page plus its annotation appearances into a new PDF.
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw CocoaError(.fileWriteUnknown) }
        var box = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let cgPage = page.pageRef else { continue }
            var pageBox = page.bounds(for: .mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox: NSData(
                bytes: &pageBox, length: MemoryLayout<CGRect>.size
            )] as CFDictionary)
            ctx.drawPDFPage(cgPage)
            for annotation in page.annotations { annotation.draw(with: .mediaBox, in: ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: url)
    }

    // MARK: - Export

    static func exportPagesAsImages(_ document: PDFDocument, to directory: URL, baseName: String, dpi: CGFloat = 144) throws -> Int {
        var written = 0
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = dpi / 72
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { continue }
            let url = directory.appendingPathComponent("\(baseName)-page-\(i + 1).png")
            try png.write(to: url)
            written += 1
        }
        return written
    }

    static func exportText(_ document: PDFDocument, to url: URL) throws {
        let text = document.string ?? ""
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

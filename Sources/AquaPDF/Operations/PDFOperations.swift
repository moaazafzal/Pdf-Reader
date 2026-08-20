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
        guard rect.width > 0, rect.height > 0 else { return nil }
        let pageBounds = page.bounds(for: .mediaBox)
        let fullSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        let full = page.thumbnail(of: fullSize, for: .mediaBox)

        let pixelSize = CGSize(width: rect.width * scale, height: rect.height * scale)
        let crop = NSImage(size: pixelSize)
        crop.lockFocus()
        // Page space and NSImage space are both bottom-left origin.
        let source = NSRect(
            x: (rect.minX - pageBounds.minX) * scale,
            y: (rect.minY - pageBounds.minY) * scale,
            width: pixelSize.width,
            height: pixelSize.height
        )
        full.draw(in: NSRect(origin: .zero, size: pixelSize), from: source, operation: .copy, fraction: 1)
        crop.unlockFocus()
        return crop
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
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]
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
        let options: [PDFDocumentWriteOption: Any] = [.burnInAnnotationsOption: true]
        guard document.write(to: url, withOptions: options) else { throw CocoaError(.fileWriteUnknown) }
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

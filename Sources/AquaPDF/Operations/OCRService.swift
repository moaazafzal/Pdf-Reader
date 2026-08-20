import AppKit
import PDFKit
import Vision

enum OCRService {

    struct RecognizedLine {
        let text: String
        /// Normalized (0–1) bounding box, origin bottom-left (Vision convention).
        let box: CGRect
    }

    /// OCR every page and return a new PDF with an invisible, selectable/searchable
    /// text layer drawn over the original (vector-preserved) page content.
    static func makeSearchablePDF(from document: PDFDocument) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw CocoaError(.fileWriteUnknown) }

        var firstBox = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let cgPage = page.pageRef else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let lines = try recognizeLines(on: page)

            var boxDict: [CFString: Any] = [:]
            var boxValue = mediaBox
            boxDict[kCGPDFContextMediaBox] = NSData(bytes: &boxValue, length: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage(boxDict as CFDictionary)
            ctx.drawPDFPage(cgPage)
            drawInvisibleText(lines, in: mediaBox, context: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard let out = PDFDocument(data: data as Data) else { throw CocoaError(.fileReadCorruptFile) }
        return out
    }

    /// Plain-text OCR of the whole document (for image-only PDFs where `document.string` is empty).
    static func recognizeText(in document: PDFDocument) throws -> String {
        var parts: [String] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let lines = try recognizeLines(on: page)
            parts.append(lines.map(\.text).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func recognizeLines(on page: PDFPage) throws -> [RecognizedLine] {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 300 / 72
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, box: obs.boundingBox)
        }
    }

    private static func drawInvisibleText(_ lines: [RecognizedLine], in mediaBox: CGRect, context ctx: CGContext) {
        for line in lines {
            let rect = CGRect(
                x: mediaBox.origin.x + line.box.origin.x * mediaBox.width,
                y: mediaBox.origin.y + line.box.origin.y * mediaBox.height,
                width: line.box.width * mediaBox.width,
                height: line.box.height * mediaBox.height
            )
            guard rect.height > 1, !line.text.isEmpty else { continue }

            let fontSize = rect.height
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
            ]
            let attrString = CFAttributedStringCreate(nil, line.text as CFString, attributes as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attrString)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard lineWidth > 0 else { continue }

            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            // Scale horizontally so the invisible text spans the recognized box.
            ctx.textMatrix = CGAffineTransform(scaleX: rect.width / lineWidth, y: 1)
            ctx.textPosition = CGPoint(x: rect.origin.x, y: rect.origin.y + fontSize * 0.2)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }
}

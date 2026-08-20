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
        guard let page = document.page(at: pageIndex),
              let cgPage = page.pageRef,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return }
        var box = page.bounds(for: .mediaBox)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }

        ctx.beginPDFPage(nil)
        ctx.drawPDFPage(cgPage)
        ctx.draw(cgImage, in: rect)
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

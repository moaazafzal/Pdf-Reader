import AppKit
import PDFKit

/// Interactive image/signature placement. Lives as an annotation (movable, resizable)
/// until save, when `PDFFileDocument` burns it into real page content.
final class ImageStampAnnotation: PDFAnnotation {
    let image: NSImage

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        shouldPrint = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}

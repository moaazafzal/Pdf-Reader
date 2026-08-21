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
        image = coder.decodeObject(forKey: "image") as? NSImage ?? NSImage(size: .zero)
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}

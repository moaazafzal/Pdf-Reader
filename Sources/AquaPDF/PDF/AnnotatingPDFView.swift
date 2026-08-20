import AppKit
import PDFKit

/// PDFView subclass that turns mouse drags into annotations depending on the active tool.
@MainActor
final class AnnotatingPDFView: PDFView {
    weak var viewModel: DocViewModel?

    /// Image placed by the signature / image-stamp tools (burned into page content on click).
    var pendingStampImage: NSImage?

    // In-progress drag state
    private var dragStartPagePoint: CGPoint = .zero
    private var dragPage: PDFPage?
    private var inkPoints: [CGPoint] = []
    private var previewAnnotation: PDFAnnotation?

    private var tool: Tool { viewModel?.tool ?? .select }
    private var style: AnnotationStyle { viewModel?.style ?? AnnotationStyle() }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)

        switch tool {
        case .select:
            if let hit = page.annotation(at: pagePoint), !(hit.isLink || hit.isWidget) {
                viewModel?.selectedAnnotation = hit
            } else {
                viewModel?.selectedAnnotation = nil
            }
            super.mouseDown(with: event)

        case .highlight, .underline, .strikeout:
            // Let PDFView run its normal text-selection drag; markup applied on mouseUp.
            super.mouseDown(with: event)

        case .ink:
            dragPage = page
            inkPoints = [pagePoint]

        case .rectangle, .ellipse, .line, .arrow:
            dragPage = page
            dragStartPagePoint = pagePoint

        case .textBox:
            viewModel?.pendingTextRequest = .init(page: page, point: pagePoint, kind: .textBox)

        case .note:
            viewModel?.pendingTextRequest = .init(page: page, point: pagePoint, kind: .note)

        case .signature, .imageStamp:
            if let image = pendingStampImage, let document = document {
                let pageIndex = document.index(for: page)
                PDFOperations.burnImage(image, centeredAt: pagePoint, pageIndex: pageIndex, in: document)
                viewModel?.annotationsVersion += 1
                setNeedsDisplay(bounds)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        switch tool {
        case .ink:
            guard let page = dragPage else { return }
            inkPoints.append(convert(viewPoint, to: page))
            updateInkPreview(on: page)

        case .rectangle, .ellipse, .line, .arrow:
            guard let page = dragPage else { return }
            updateShapePreview(to: convert(viewPoint, to: page), on: page)

        default:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .highlight, .underline, .strikeout:
            super.mouseUp(with: event)
            applyMarkup()

        case .ink:
            finishInk()

        case .rectangle, .ellipse, .line, .arrow:
            finishShape(with: event)

        default:
            super.mouseUp(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Delete / backspace removes the selected annotation.
        if event.keyCode == 51 || event.keyCode == 117, viewModel?.selectedAnnotation != nil {
            viewModel?.deleteSelectedAnnotation()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Text markup (highlight / underline / strikeout)

    private func applyMarkup() {
        guard let selection = currentSelection, let string = selection.string, !string.isEmpty else { return }
        let subtype: PDFAnnotationSubtype
        switch tool {
        case .highlight: subtype = .highlight
        case .underline: subtype = .underline
        default: subtype = .strikeOut
        }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = style.color.withAlphaComponent(tool == .highlight ? 0.5 : 1)
                page.addAnnotation(annotation)
            }
        }
        setCurrentSelection(nil, animate: false)
        viewModel?.annotationsVersion += 1
    }

    // MARK: - Ink

    private func updateInkPreview(on page: PDFPage) {
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        guard inkPoints.count > 1 else { return }
        let annotation = makeInkAnnotation(points: inkPoints)
        page.addAnnotation(annotation)
        previewAnnotation = annotation
    }

    private func finishInk() {
        defer {
            previewAnnotation = nil
            inkPoints = []
            dragPage = nil
        }
        guard let page = dragPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        guard inkPoints.count > 1 else { return }
        page.addAnnotation(makeInkAnnotation(points: inkPoints))
        viewModel?.annotationsVersion += 1
    }

    private func makeInkAnnotation(points: [CGPoint]) -> PDFAnnotation {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let pad = style.lineWidth + 2
        let bounds = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = style.color
        let border = PDFBorder()
        border.lineWidth = style.lineWidth
        annotation.border = border

        let path = NSBezierPath()
        let rel = points.map { CGPoint(x: $0.x - bounds.origin.x, y: $0.y - bounds.origin.y) }
        path.move(to: rel[0])
        for p in rel.dropFirst() { path.line(to: p) }
        annotation.add(path)
        return annotation
    }

    // MARK: - Shapes

    private func updateShapePreview(to current: CGPoint, on page: PDFPage) {
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let annotation = makeShapeAnnotation(from: dragStartPagePoint, to: current)
        page.addAnnotation(annotation)
        previewAnnotation = annotation
    }

    private func finishShape(with event: NSEvent) {
        defer {
            previewAnnotation = nil
            dragPage = nil
        }
        guard let page = dragPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let end = convert(viewPoint, to: page)
        let dx = abs(end.x - dragStartPagePoint.x), dy = abs(end.y - dragStartPagePoint.y)
        guard dx > 3 || dy > 3 else { return }
        page.addAnnotation(makeShapeAnnotation(from: dragStartPagePoint, to: end))
        viewModel?.annotationsVersion += 1
    }

    private func makeShapeAnnotation(from start: CGPoint, to end: CGPoint) -> PDFAnnotation {
        let pad = style.lineWidth + 2
        let rect = CGRect(
            x: min(start.x, end.x) - pad,
            y: min(start.y, end.y) - pad,
            width: abs(end.x - start.x) + pad * 2,
            height: abs(end.y - start.y) + pad * 2
        )
        let border = PDFBorder()
        border.lineWidth = style.lineWidth

        switch tool {
        case .rectangle:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = style.color
            a.border = border
            return a
        case .ellipse:
            let a = PDFAnnotation(bounds: rect, forType: .circle, withProperties: nil)
            a.color = style.color
            a.border = border
            return a
        default:
            let a = PDFAnnotation(bounds: rect, forType: .line, withProperties: nil)
            a.color = style.color
            a.border = border
            a.startPoint = CGPoint(x: start.x - rect.origin.x, y: start.y - rect.origin.y)
            a.endPoint = CGPoint(x: end.x - rect.origin.x, y: end.y - rect.origin.y)
            if tool == .arrow {
                a.endLineStyle = .closedArrow
                a.interiorColor = style.color
            }
            return a
        }
    }
}

extension PDFAnnotation {
    var isLink: Bool { type == PDFAnnotationSubtype.link.rawValue.trimmingSlash }
    var isWidget: Bool { type == PDFAnnotationSubtype.widget.rawValue.trimmingSlash }
}

private extension String {
    /// PDFAnnotation.type omits the leading "/" of PDFAnnotationSubtype raw values.
    var trimmingSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }
}

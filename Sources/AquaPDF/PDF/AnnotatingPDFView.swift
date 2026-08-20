import AppKit
import PDFKit

/// PDFView subclass that turns mouse drags into annotations depending on the active tool.
/// All mutations register with the window's undo manager (which also marks the SwiftUI
/// document dirty so autosave works).
@MainActor
final class AnnotatingPDFView: PDFView {
    weak var viewModel: DocViewModel?

    /// Image placed by the signature / image-stamp tools.
    var pendingStampImage: NSImage?

    // In-progress drag state
    private var dragStartPagePoint: CGPoint = .zero
    private var dragPage: PDFPage?
    private var inkPoints: [CGPoint] = []
    private var previewAnnotation: PDFAnnotation?

    private enum SelectDrag {
        case none
        case moving(PDFAnnotation, grabOffset: CGPoint, originalBounds: CGRect)
        case resizing(PDFAnnotation, anchor: CGPoint, originalBounds: CGRect)
    }
    private var selectDrag: SelectDrag = .none

    private var tool: Tool { viewModel?.tool ?? .select }
    private var style: AnnotationStyle { viewModel?.style ?? AnnotationStyle() }

    nonisolated static let redactionUserName = "AquaPDF.Redact"

    // MARK: - Undoable mutations

    func insert(_ annotation: PDFAnnotation, on page: PDFPage) {
        page.addAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { target in
            target.remove(annotation)
        }
        undoManager?.setActionName("Add Annotation")
        viewModel?.annotationsVersion += 1
        setNeedsDisplay(bounds)
    }

    func remove(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { target in
            target.insert(annotation, on: page)
        }
        undoManager?.setActionName("Remove Annotation")
        if viewModel?.selectedAnnotation === annotation {
            viewModel?.selectedAnnotation = nil
        }
        viewModel?.annotationsVersion += 1
        setNeedsDisplay(bounds)
    }

    private func setBounds(_ newBounds: CGRect, for annotation: PDFAnnotation) {
        let old = annotation.bounds
        annotation.bounds = newBounds
        undoManager?.registerUndo(withTarget: self) { target in
            target.setBounds(old, for: annotation)
        }
        undoManager?.setActionName("Move Annotation")
        setNeedsDisplay(bounds)
    }

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
            beginSelectDrag(at: pagePoint, on: page, event: event)

        case .highlight, .underline, .strikeout:
            // Let PDFView run its normal text-selection drag; markup applied on mouseUp.
            super.mouseDown(with: event)

        case .ink:
            dragPage = page
            inkPoints = [pagePoint]

        case .rectangle, .ellipse, .line, .arrow, .redact:
            dragPage = page
            dragStartPagePoint = pagePoint

        case .textBox:
            viewModel?.pendingTextRequest = .init(page: page, point: pagePoint, kind: .textBox)

        case .note:
            viewModel?.pendingTextRequest = .init(page: page, point: pagePoint, kind: .note)

        case .signature, .imageStamp:
            placeStamp(at: pagePoint, on: page)

        case .editText:
            requestTextEdit(at: pagePoint, on: page)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        switch tool {
        case .select:
            if case .none = selectDrag {
                super.mouseDragged(with: event)
            } else if let page = dragPage {
                continueSelectDrag(to: convert(viewPoint, to: page))
            }

        case .ink:
            guard let page = dragPage else { return }
            inkPoints.append(convert(viewPoint, to: page))
            updateInkPreview(on: page)

        case .rectangle, .ellipse, .line, .arrow, .redact:
            guard let page = dragPage else { return }
            updateShapePreview(to: convert(viewPoint, to: page), on: page)

        default:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .select:
            finishSelectDrag()
            if case .none = selectDrag { super.mouseUp(with: event) }
            selectDrag = .none
            dragPage = nil

        case .highlight, .underline, .strikeout:
            super.mouseUp(with: event)
            applyMarkup()

        case .ink:
            finishInk()

        case .rectangle, .ellipse, .line, .arrow, .redact:
            finishShape(with: event)

        default:
            super.mouseUp(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Delete / backspace removes the selected annotation.
        if event.keyCode == 51 || event.keyCode == 117, let selected = viewModel?.selectedAnnotation {
            remove(selected)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Selection handles

    /// Handle size in page space (constant on screen).
    private var handleSize: CGFloat { 9 / max(scaleFactor, 0.1) }

    private func annotationIsResizable(_ annotation: PDFAnnotation) -> Bool {
        if annotation is ImageStampAnnotation { return true }
        let type = annotation.type ?? ""
        return ["Square", "Circle", "FreeText"].contains(type)
    }

    private func handleRects(for annotation: PDFAnnotation) -> [CGRect] {
        let b = annotation.bounds
        let s = handleSize
        return [
            CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
            CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY),
        ].map { CGRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        guard let selected = viewModel?.selectedAnnotation, selected.page === page else { return }

        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / max(scaleFactor, 0.1))
        context.setLineDash(phase: 0, lengths: [4 / max(scaleFactor, 0.1)])
        context.stroke(selected.bounds.insetBy(dx: -2, dy: -2))

        if annotationIsResizable(selected) {
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(NSColor.white.cgColor)
            for rect in handleRects(for: selected) {
                context.fill(rect)
                context.stroke(rect)
            }
        }
        context.restoreGState()
    }

    // MARK: - Select-mode drag (move / resize)

    private func beginSelectDrag(at pagePoint: CGPoint, on page: PDFPage, event: NSEvent) {
        selectDrag = .none

        // Resize handle on the current selection?
        if let selected = viewModel?.selectedAnnotation,
           selected.page === page,
           annotationIsResizable(selected)
        {
            let handles = handleRects(for: selected)
            for (i, rect) in handles.enumerated() where rect.insetBy(dx: -3, dy: -3).contains(pagePoint) {
                // Anchor is the opposite corner (handles order: BL, BR, TL, TR).
                let b = selected.bounds
                let anchors = [
                    CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY),
                    CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.minY),
                ]
                selectDrag = .resizing(selected, anchor: anchors[i], originalBounds: b)
                dragPage = page
                return
            }
        }

        if let hit = page.annotation(at: pagePoint), !(hit.isLink || hit.isWidget) {
            viewModel?.selectedAnnotation = hit
            selectDrag = .moving(
                hit,
                grabOffset: CGPoint(x: pagePoint.x - hit.bounds.origin.x, y: pagePoint.y - hit.bounds.origin.y),
                originalBounds: hit.bounds
            )
            dragPage = page
            setNeedsDisplay(bounds)
        } else {
            viewModel?.selectedAnnotation = nil
            setNeedsDisplay(bounds)
            super.mouseDown(with: event)
        }
    }

    private func continueSelectDrag(to pagePoint: CGPoint) {
        switch selectDrag {
        case .moving(let annotation, let grabOffset, _):
            annotation.bounds.origin = CGPoint(x: pagePoint.x - grabOffset.x, y: pagePoint.y - grabOffset.y)
            setNeedsDisplay(bounds)
        case .resizing(let annotation, let anchor, _):
            let minSize: CGFloat = 8
            let rect = CGRect(
                x: min(anchor.x, pagePoint.x),
                y: min(anchor.y, pagePoint.y),
                width: max(minSize, abs(pagePoint.x - anchor.x)),
                height: max(minSize, abs(pagePoint.y - anchor.y))
            )
            annotation.bounds = rect
            setNeedsDisplay(bounds)
        case .none:
            break
        }
    }

    private func finishSelectDrag() {
        switch selectDrag {
        case .moving(let annotation, _, let original), .resizing(let annotation, _, let original):
            guard annotation.bounds != original else { break }
            // Re-apply through the undoable setter: restore, then set, so undo returns to `original`.
            let final = annotation.bounds
            annotation.bounds = original
            setBounds(final, for: annotation)
        case .none:
            break
        }
    }

    // MARK: - Stamp placement (signature / image)

    private func placeStamp(at pagePoint: CGPoint, on page: PDFPage) {
        guard let image = pendingStampImage else { return }
        let maxWidth: CGFloat = 180
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(
            x: pagePoint.x - size.width / 2,
            y: pagePoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        let annotation = ImageStampAnnotation(image: image, bounds: rect)
        insert(annotation, on: page)
        viewModel?.selectedAnnotation = annotation
        viewModel?.tool = .select  // switch to select so it can be moved/resized immediately
    }

    // MARK: - Edit text (beta)

    private func requestTextEdit(at pagePoint: CGPoint, on page: PDFPage) {
        guard let selection = page.selectionForLine(at: pagePoint),
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let lineBounds = selection.bounds(for: page)
        guard !lineBounds.isEmpty else { return }
        viewModel?.pendingEditTextRequest = .init(page: page, lineBounds: lineBounds, originalText: text)
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
                let lineBounds = line.bounds(for: page)
                guard !lineBounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: lineBounds, forType: subtype, withProperties: nil)
                annotation.color = style.color.withAlphaComponent(tool == .highlight ? 0.5 : 1)
                insert(annotation, on: page)
            }
        }
        setCurrentSelection(nil, animate: false)
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
        insert(makeInkAnnotation(points: inkPoints), on: page)
    }

    private func makeInkAnnotation(points: [CGPoint]) -> PDFAnnotation {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let pad = style.lineWidth + 2
        let inkBounds = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        let annotation = PDFAnnotation(bounds: inkBounds, forType: .ink, withProperties: nil)
        annotation.color = style.color
        let border = PDFBorder()
        border.lineWidth = style.lineWidth
        annotation.border = border

        let path = NSBezierPath()
        let rel = points.map { CGPoint(x: $0.x - inkBounds.origin.x, y: $0.y - inkBounds.origin.y) }
        path.move(to: rel[0])
        for p in rel.dropFirst() { path.line(to: p) }
        annotation.add(path)
        return annotation
    }

    // MARK: - Shapes & redaction marks

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
        insert(makeShapeAnnotation(from: dragStartPagePoint, to: end), on: page)
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
        case .redact:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = .black
            a.interiorColor = NSColor.black.withAlphaComponent(0.85)
            a.border = border
            a.userName = Self.redactionUserName
            a.contents = "Redaction mark — apply via Tools ▸ Apply Redactions"
            return a
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
    var isRedactionMark: Bool { userName == AnnotatingPDFView.redactionUserName }
}

private extension String {
    /// PDFAnnotation.type omits the leading "/" of PDFAnnotationSubtype raw values.
    var trimmingSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }
}

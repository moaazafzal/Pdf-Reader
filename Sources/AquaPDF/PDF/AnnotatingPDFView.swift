import AppKit
import PDFKit

/// Borderless text view used for in-place text editing on the page (Foxit-style).
final class InlineTextEditor: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// true: Enter commits (single-line edit). false: Enter inserts newline; ⌘Enter commits.
    var commitsOnEnter = false

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func insertNewline(_ sender: Any?) {
        if commitsOnEnter { onCommit?() } else { super.insertNewline(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {  // ⌘Enter
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// PDFView subclass that turns mouse drags into annotations depending on the active tool.
/// All mutations register with the window's undo manager (which also marks the SwiftUI
/// document dirty so autosave works).
@MainActor
final class AnnotatingPDFView: PDFView {
    weak var viewModel: DocViewModel?

    /// Image placed by the signature / image-stamp tools.
    var pendingStampImage: NSImage?

    // In-place text editing session
    private struct TextSession {
        enum Kind {
            case add
            case editLine(original: String)
        }
        let kind: Kind
        let page: PDFPage
        var pageRect: CGRect
        let pageFontSize: CGFloat
    }
    private var textSession: TextSession?
    private var inlineEditor: InlineTextEditor?
    private var scrollObserver: NSObjectProtocol?

    // Hover highlight for the Edit Text tool
    private var hoverPage: PDFPage?
    private var hoverRect: CGRect = .null
    private var hoverTrackingArea: NSTrackingArea?

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
        // Click outside an active in-place editor commits it (Foxit behavior).
        if inlineEditor != nil {
            commitInlineEditor()
            return
        }

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
            beginAddText(at: pagePoint, on: page)

        case .note:
            viewModel?.pendingTextRequest = .init(page: page, point: pagePoint, kind: .note)

        case .signature, .imageStamp:
            placeStamp(at: pagePoint, on: page)

        case .editText:
            beginEditLine(at: pagePoint, on: page)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        switch tool {
        case .editText:
            NSCursor.iBeam.set()
            let viewPoint = convert(event.locationInWindow, from: nil)
            guard let page = page(for: viewPoint, nearest: true) else { return }
            let pagePoint = convert(viewPoint, to: page)
            var newRect = CGRect.null
            if let selection = page.selectionForLine(at: pagePoint),
               let text = selection.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let rect = selection.bounds(for: page)
                if rect.insetBy(dx: -4, dy: -4).contains(pagePoint) { newRect = rect }
            }
            if newRect != hoverRect || page !== hoverPage {
                hoverPage = newRect.isNull ? nil : page
                hoverRect = newRect
                setNeedsDisplay(bounds)
            }
        case .textBox:
            NSCursor.iBeam.set()
            clearHover()
        default:
            clearHover()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    private func clearHover() {
        guard hoverPage != nil || !hoverRect.isNull else { return }
        hoverPage = nil
        hoverRect = .null
        setNeedsDisplay(bounds)
    }

    /// Called when the active tool changes (from PDFKitView.updateNSView).
    func toolDidChange() {
        if inlineEditor != nil { commitInlineEditor() }
        clearHover()
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

        // Edit Text hover: outline the line under the cursor so the editable area is visible.
        if hoverPage === page, !hoverRect.isNull {
            context.saveGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5 / max(scaleFactor, 0.1))
            context.setLineDash(phase: 0, lengths: [3 / max(scaleFactor, 0.1)])
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
            let box = hoverRect.insetBy(dx: -3, dy: -3)
            context.fill(box)
            context.stroke(box)
            context.restoreGState()
        }

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

    // MARK: - In-place text editing (Add Text / Edit Text)

    private func beginAddText(at pagePoint: CGPoint, on page: PDFPage) {
        let fontSize = style.fontSize
        let height = fontSize * 1.7
        let pageBounds = page.bounds(for: .mediaBox)
        let width = min(240, pageBounds.maxX - pagePoint.x - 4)
        guard width > 30 else { return }
        let rect = CGRect(x: pagePoint.x, y: pagePoint.y - height, width: width, height: height)
        startSession(TextSession(kind: .add, page: page, pageRect: rect, pageFontSize: fontSize), text: "")
    }

    private func beginEditLine(at pagePoint: CGPoint, on page: PDFPage) {
        guard let selection = page.selectionForLine(at: pagePoint),
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        let lineBounds = selection.bounds(for: page)
        guard !lineBounds.isEmpty else { return }
        clearHover()
        let session = TextSession(
            kind: .editLine(original: text),
            page: page,
            pageRect: lineBounds,
            pageFontSize: lineBounds.height * 0.72
        )
        startSession(session, text: text)
    }

    private func startSession(_ session: TextSession, text: String) {
        commitInlineEditor()
        textSession = session

        let editor = InlineTextEditor(frame: convert(session.pageRect, from: session.page))
        editor.string = text
        editor.isRichText = false
        editor.drawsBackground = true
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 2, height: 2)
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 1.5
        editor.layer?.cornerRadius = 2

        switch session.kind {
        case .add:
            editor.backgroundColor = NSColor.white.withAlphaComponent(0.65)
            editor.textColor = style.color
            editor.commitsOnEnter = false
        case .editLine:
            editor.backgroundColor = .white
            editor.textColor = .black
            editor.commitsOnEnter = true
        }

        editor.onCommit = { [weak self] in self?.commitInlineEditor() }
        editor.onCancel = { [weak self] in self?.cancelInlineEditor() }

        addSubview(editor)
        inlineEditor = editor
        layoutInlineEditor()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: text.count, length: 0))

        // Track scroll/zoom so the editor stays glued to the page rect.
        if let clipView = documentView?.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.layoutInlineEditor() }
            }
        }
    }

    private func layoutInlineEditor() {
        guard let editor = inlineEditor, let session = textSession else { return }
        editor.frame = convert(session.pageRect, from: session.page).insetBy(dx: -2, dy: -2)
        editor.font = .systemFont(ofSize: session.pageFontSize * scaleFactor)
    }

    private func teardownInlineEditor() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        inlineEditor?.removeFromSuperview()
        inlineEditor = nil
        textSession = nil
        window?.makeFirstResponder(self)
    }

    func commitInlineEditor() {
        guard let editor = inlineEditor, let session = textSession else { return }
        let text = editor.string
        teardownInlineEditor()

        switch session.kind {
        case .add:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: session.pageFontSize)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: 520, height: 2000),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font]
            )
            let rect = CGRect(
                x: session.pageRect.minX,
                y: session.pageRect.maxY - measured.height - 8,
                width: max(measured.width + 14, 36),
                height: measured.height + 8
            )
            let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = font
            annotation.fontColor = style.color
            annotation.color = .clear
            insert(annotation, on: session.page)

        case .editLine(let original):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != original else { return }
            viewModel?.editTextHandler?(session.page, session.pageRect, trimmed)
        }
    }

    private func cancelInlineEditor() {
        teardownInlineEditor()
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

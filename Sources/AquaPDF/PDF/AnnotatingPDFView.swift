import AppKit
import Combine
import PDFKit
import SwiftUI

/// PDFView subclass that turns mouse input into annotations depending on the active tool.
/// All mutations register with the window's undo manager (which also marks the SwiftUI
/// document dirty so autosave works).
@MainActor
final class AnnotatingPDFView: PDFView {
    weak var viewModel: DocViewModel?

    /// Image placed by the signature / image-stamp tools.
    var pendingStampImage: NSImage?
    /// Text placed by the stamp palette.
    var pendingStampText: String?

    nonisolated static let redactionUserName = "AquaPDF.Redact"

    // MARK: - Drag state

    private var dragStartPagePoint: CGPoint = .zero
    private var dragPage: PDFPage?
    private var inkPoints: [CGPoint] = []
    private var previewAnnotation: PDFAnnotation?

    /// Points collected by multi-point tools (polygon, polyline, cloud, perimeter, area).
    private var multiPoints: [CGPoint] = []
    private var multiPage: PDFPage?

    private enum SelectDrag {
        case none
        case moving(PDFAnnotation, grabOffset: CGPoint, originalBounds: CGRect)
        case resizing(PDFAnnotation, anchor: CGPoint, originalBounds: CGRect)
    }
    private var selectDrag: SelectDrag = .none

    private var tool: Tool { viewModel?.tool ?? .select }
    private var style: AnnotationStyle { viewModel?.style ?? AnnotationStyle() }
    private var measureScale: MeasureScale { viewModel?.measureScale ?? MeasureScale() }

    // MARK: - In-place text editing

    private struct TextSession {
        enum Kind {
            case add
            case callout(target: CGPoint)
            case editLine(original: String)
            case editAnnotation(PDFAnnotation)
            var isEdit: Bool {
                switch self {
                case .add, .callout: return false
                default: return true
                }
            }
        }
        let kind: Kind
        let page: PDFPage
        var pageRect: CGRect
        var pageFontSize: CGFloat
    }
    private var textSession: TextSession?
    private var inlineBox: InlineTextBox?
    private var formatBarHost: NSHostingView<TextFormatBar>?
    private var formatState: TextFormatState?
    private var formatCancellable: AnyCancellable?
    private var scrollObserver: NSObjectProtocol?
    private var inlineEditor: InlineTextEditor? { inlineBox?.editor }

    // Hover highlight for the Edit Text tool
    private var hoverPage: PDFPage?
    private var hoverRect: CGRect = .null
    private var hoverTrackingArea: NSTrackingArea?

    // MARK: - Visual mode

    enum VisualMode: String, CaseIterable, Identifiable {
        case standard = "Default"
        case night = "Night"
        case sepia = "Sepia"
        case eyeComfort = "Eye Comfort"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .standard: return "sun.max"
            case .night: return "moon"
            case .sepia: return "book.closed"
            case .eyeComfort: return "eye"
            }
        }
    }

    var visualMode: VisualMode = .standard {
        didSet { applyVisualMode() }
    }

    private func applyVisualMode() {
        guard let documentView else { return }
        documentView.wantsLayer = true
        switch visualMode {
        case .standard:
            documentView.layer?.filters = nil
            backgroundColor = .underPageBackgroundColor
        case .night:
            let invert = CIFilter(name: "CIColorInvert")!
            let hue = CIFilter(name: "CIHueAdjust")!
            hue.setValue(Float.pi, forKey: kCIInputAngleKey)
            documentView.layer?.filters = [invert, hue]
            backgroundColor = .black
        case .sepia:
            let sepia = CIFilter(name: "CISepiaTone")!
            sepia.setValue(0.75, forKey: kCIInputIntensityKey)
            documentView.layer?.filters = [sepia]
            backgroundColor = NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.22, alpha: 1)
        case .eyeComfort:
            let warm = CIFilter(name: "CISepiaTone")!
            warm.setValue(0.28, forKey: kCIInputIntensityKey)
            documentView.layer?.filters = [warm]
            backgroundColor = NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.26, alpha: 1)
        }
        setNeedsDisplay(bounds)
    }

    // MARK: - AutoScroll

    private var autoScrollTimer: Timer?
    private(set) var isAutoScrolling = false
    var autoScrollSpeed: CGFloat = 1.4

    func toggleAutoScroll() {
        isAutoScrolling ? stopAutoScroll() : startAutoScroll()
    }

    func startAutoScroll() {
        stopAutoScroll()
        isAutoScrolling = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoScrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        isAutoScrolling = false
        viewModel?.isAutoScrolling = false
    }

    private func autoScrollTick() {
        guard let clipView = documentView?.enclosingScrollView?.contentView,
              let docHeight = documentView?.frame.height
        else { return stopAutoScroll() }
        var origin = clipView.bounds.origin
        origin.y += autoScrollSpeed
        let maxY = docHeight - clipView.bounds.height
        guard maxY > 0 else { return stopAutoScroll() }
        if origin.y >= maxY { origin.y = maxY }
        clipView.scroll(to: origin)
        documentView?.enclosingScrollView?.reflectScrolledClipView(clipView)
        if origin.y >= maxY { stopAutoScroll() }
    }

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

        // Multi-point tools collect clicks; a double-click finishes the shape.
        if tool.isMultiPoint {
            if event.clickCount >= 2 {
                finishMultiPoint()
            } else {
                if multiPage !== page { multiPoints = []; multiPage = page }
                multiPoints.append(pagePoint)
                updateMultiPointPreview(cursor: pagePoint)
            }
            return
        }

        switch tool {
        case .hand:
            super.mouseDown(with: event)

        case .select, .selectAnnotation:
            if event.clickCount >= 2, let existing = editableTextAnnotation(at: pagePoint, on: page) {
                beginEditAnnotation(existing, on: page)
                return
            }
            beginSelectDrag(at: pagePoint, on: page, event: event)

        case .highlight, .underline, .squiggly, .strikeout, .replaceText, .insertText:
            // Let PDFView run its normal text-selection drag; markup applied on mouseUp.
            super.mouseDown(with: event)

        case .ink:
            dragPage = page
            inkPoints = [pagePoint]

        case .eraser:
            dragPage = page
            eraseInk(at: pagePoint, on: page)

        case .note:
            viewModel?.pendingTextRequest = .init(page: page, point: pagePoint, kind: .note)

        case .fileAttachment:
            attachFile(at: pagePoint, on: page)

        case .textBox:
            beginAddText(at: pagePoint, on: page)

        case .editText:
            beginEditLine(at: pagePoint, on: page)

        case .stamp, .signature, .imageStamp:
            placeStamp(at: pagePoint, on: page)

        default:
            if tool.isDragShape {
                dragPage = page
                dragStartPagePoint = pagePoint
            } else {
                super.mouseDown(with: event)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        switch tool {
        case .select, .selectAnnotation:
            if case .none = selectDrag {
                super.mouseDragged(with: event)
            } else if let page = dragPage {
                continueSelectDrag(to: convert(viewPoint, to: page))
            }

        case .ink:
            guard let page = dragPage else { return }
            inkPoints.append(convert(viewPoint, to: page))
            updateInkPreview(on: page)

        case .eraser:
            guard let page = dragPage else { return }
            eraseInk(at: convert(viewPoint, to: page), on: page)

        default:
            if tool.isDragShape, let page = dragPage {
                updateShapePreview(to: convert(viewPoint, to: page), on: page)
            } else {
                super.mouseDragged(with: event)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if tool.isMultiPoint { return }

        switch tool {
        case .select, .selectAnnotation:
            finishSelectDrag()
            if case .none = selectDrag { super.mouseUp(with: event) }
            selectDrag = .none
            dragPage = nil

        case .highlight, .underline, .squiggly, .strikeout, .replaceText, .insertText:
            super.mouseUp(with: event)
            applyMarkup()

        case .ink:
            finishInk()

        case .eraser:
            dragPage = nil

        case .snapshot:
            finishSnapshot(with: event)

        case .marqueeZoom:
            finishMarqueeZoom(with: event)

        case .callout:
            finishCallout(with: event)

        default:
            if tool.isDragShape {
                finishShape(with: event)
            } else {
                super.mouseUp(with: event)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        if tool.isMultiPoint, !multiPoints.isEmpty, let page = multiPage {
            let pagePoint = convert(convert(event.locationInWindow, from: nil), to: page)
            updateMultiPointPreview(cursor: pagePoint)
            return
        }

        switch tool {
        case .editText:
            NSCursor.iBeam.set()
            let viewPoint = convert(event.locationInWindow, from: nil)
            guard let page = page(for: viewPoint, nearest: true) else { return }
            let pagePoint = convert(viewPoint, to: page)
            var newRect = CGRect.null
            if let existing = editableTextAnnotation(at: pagePoint, on: page) {
                newRect = existing.bounds
            } else if let line = page.textLine(at: pagePoint) {
                newRect = line.rect
            }
            if newRect != hoverRect || page !== hoverPage {
                // Repaint only the old and new highlight rects, not the whole view.
                let oldRect = hoverRect, oldPage = hoverPage
                hoverPage = newRect.isNull ? nil : page
                hoverRect = newRect
                invalidate(pageRect: oldRect, on: oldPage)
                invalidate(pageRect: newRect, on: page)
            }
        case .textBox, .callout:
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
        let oldRect = hoverRect, oldPage = hoverPage
        hoverPage = nil
        hoverRect = .null
        invalidate(pageRect: oldRect, on: oldPage)
    }

    /// Marks just the view region covering a page-space rect as needing redraw.
    private func invalidate(pageRect: CGRect, on page: PDFPage?) {
        guard let page, !pageRect.isNull, !pageRect.isEmpty else { return }
        let viewRect = convert(pageRect.insetBy(dx: -8, dy: -8), from: page)
        guard !viewRect.isNull, !viewRect.isEmpty else { return }
        setNeedsDisplay(viewRect.intersection(bounds))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:  // delete / forward delete
            if let selected = viewModel?.selectedAnnotation {
                remove(selected)
                return
            }
        case 36:  // return
            if tool.isMultiPoint, multiPoints.count >= 2 {
                finishMultiPoint()
                return
            }
        case 53:  // escape
            if tool.isMultiPoint, !multiPoints.isEmpty {
                cancelMultiPoint()
                return
            }
            if isAutoScrolling {
                stopAutoScroll()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Called when the active tool changes (from PDFKitView.updateNSView).
    func toolDidChange() {
        if inlineEditor != nil { commitInlineEditor() }
        if !multiPoints.isEmpty { cancelMultiPoint() }
        clearHover()
    }

    // MARK: - Selection handles

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

        // Fast path: nothing of ours to draw on this page. This runs for every rendered
        // tile, so it must stay cheap.
        let hasHover = hoverPage === page && !hoverRect.isNull
        let selected = viewModel?.selectedAnnotation
        let hasSelection = selected != nil && selected?.page === page
        guard hasHover || hasSelection else { return }

        // Edit Text hover: outline the line under the cursor so the editable area is visible.
        if hasHover {
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

        guard hasSelection, let selected else { return }

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
            if tool == .select { super.mouseDown(with: event) }
        }
    }

    private func continueSelectDrag(to pagePoint: CGPoint) {
        switch selectDrag {
        case .moving(let annotation, let grabOffset, _):
            annotation.bounds.origin = CGPoint(x: pagePoint.x - grabOffset.x, y: pagePoint.y - grabOffset.y)
            setNeedsDisplay(bounds)
        case .resizing(let annotation, let anchor, _):
            let minSize: CGFloat = 8
            annotation.bounds = CGRect(
                x: min(anchor.x, pagePoint.x),
                y: min(anchor.y, pagePoint.y),
                width: max(minSize, abs(pagePoint.x - anchor.x)),
                height: max(minSize, abs(pagePoint.y - anchor.y))
            )
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

    // MARK: - Stamps, attachments

    private func placeStamp(at pagePoint: CGPoint, on page: PDFPage) {
        if let text = pendingStampText {
            let annotation = StampTextAnnotation(
                text: text,
                bounds: CGRect(x: pagePoint.x - 70, y: pagePoint.y - 16, width: 140, height: 32),
                color: style.color
            )
            insert(annotation, on: page)
            viewModel?.selectedAnnotation = annotation
            viewModel?.tool = .select
            return
        }
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
        viewModel?.tool = .select
    }

    private func attachFile(at pagePoint: CGPoint, on page: PDFPage) {
        let panel = NSOpenPanel()
        panel.message = "Choose a file to attach as a comment"
        guard panel.runModal() == .OK, let url = panel.url else {
            viewModel?.tool = .select
            return
        }
        let rect = CGRect(x: pagePoint.x - 10, y: pagePoint.y - 10, width: 20, height: 20)
        let annotation = PDFAnnotation(bounds: rect, forType: .text, withProperties: nil)
        annotation.iconType = .newParagraph
        annotation.color = style.color
        annotation.contents = "Attached file: \(url.lastPathComponent)\n\(url.path)"
        annotation.userName = "AquaPDF.attachment"
        insert(annotation, on: page)
        viewModel?.flashHandler?("Attached \(url.lastPathComponent) as a comment")
        viewModel?.tool = .select
    }

    // MARK: - Multi-point shapes

    private func updateMultiPointPreview(cursor: CGPoint) {
        guard let page = multiPage, !multiPoints.isEmpty else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let points = multiPoints + [cursor]
        guard points.count >= 2 else { return }
        let annotation = makeMultiPointAnnotation(points: points, preview: true)
        page.addAnnotation(annotation)
        previewAnnotation = annotation
        setNeedsDisplay(bounds)
    }

    private func finishMultiPoint() {
        defer {
            multiPoints = []
            multiPage = nil
            previewAnnotation = nil
        }
        guard let page = multiPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        guard multiPoints.count >= 2 else { return }
        insert(makeMultiPointAnnotation(points: multiPoints, preview: false), on: page)
    }

    private func cancelMultiPoint() {
        if let page = multiPage, let preview = previewAnnotation { page.removeAnnotation(preview) }
        multiPoints = []
        multiPage = nil
        previewAnnotation = nil
        setNeedsDisplay(bounds)
    }

    private func makeMultiPointAnnotation(points: [CGPoint], preview: Bool) -> PDFAnnotation {
        let color = preview ? style.color.withAlphaComponent(0.6) : style.color
        switch tool {
        case .polygon:
            return PathAnnotation(kind: .polygon, points: points, color: color,
                                  lineWidth: style.lineWidth, dashed: style.dashed)
        case .polyline:
            return PathAnnotation(kind: .polyline, points: points, color: color,
                                  lineWidth: style.lineWidth, dashed: style.dashed)
        case .cloud:
            return PathAnnotation(kind: .cloud, points: points, color: color,
                                  lineWidth: style.lineWidth, dashed: style.dashed)
        case .measurePerimeter:
            return MeasureAnnotation(kind: .perimeter, points: points, scale: measureScale, color: color)
        default:
            return MeasureAnnotation(kind: .areaPolygon, points: points, scale: measureScale, color: color)
        }
    }

    // MARK: - Text markup

    private func applyMarkup() {
        guard let selection = currentSelection, let string = selection.string, !string.isEmpty else { return }

        // Replace Text / Insert Text are proofreading marks that also carry a note.
        if tool == .replaceText || tool == .insertText {
            applyProofingMark(selection: selection, original: string)
            return
        }

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
                // PDFKit has no Squiggly subtype — draw a wavy ink line under the text instead.
                let annotation = tool == .squiggly
                    ? makeSquigglyAnnotation(under: lineBounds)
                    : PDFAnnotation(bounds: lineBounds, forType: subtype, withProperties: nil)
                if tool != .squiggly {
                    annotation.color = style.color.withAlphaComponent(tool == .highlight ? 0.5 : 1)
                }
                if viewModel?.copyMarkedTextIntoNote == true {
                    annotation.contents = line.string
                }
                insert(annotation, on: page)
            }
        }
        setCurrentSelection(nil, animate: false)
    }

    private func applyProofingMark(selection: PDFSelection, original: String) {
        guard let page = selection.pages.first else { return }
        let selectionBounds = selection.bounds(for: page)
        guard !selectionBounds.isEmpty else { return }
        setCurrentSelection(nil, animate: false)

        let isReplace = tool == .replaceText
        let prompt = isReplace ? "Replacement text for \"\(original)\"" : "Text to insert here"
        guard let replacement = InputPrompt.run(
            title: isReplace ? "Replace Text" : "Insert Text",
            message: prompt,
            defaultValue: ""
        ) else { return }

        undoManager?.beginUndoGrouping()
        if isReplace {
            let strike = PDFAnnotation(bounds: selectionBounds, forType: .strikeOut, withProperties: nil)
            strike.color = style.color
            strike.contents = "Replace with: \(replacement)"
            insert(strike, on: page)
        } else {
            // Caret marker at the start of the selection.
            let caret = CGRect(x: selectionBounds.minX - 4, y: selectionBounds.minY, width: 9, height: selectionBounds.height)
            let mark = PathAnnotation(
                kind: .polyline,
                points: [
                    CGPoint(x: caret.minX, y: caret.minY),
                    CGPoint(x: caret.midX, y: caret.maxY),
                    CGPoint(x: caret.maxX, y: caret.minY),
                ],
                color: style.color,
                lineWidth: 1.5
            )
            mark.contents = "Insert: \(replacement)"
            insert(mark, on: page)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(isReplace ? "Replace Text" : "Insert Text")
    }

    private func makeSquigglyAnnotation(under lineBounds: CGRect) -> PDFAnnotation {
        let amplitude: CGFloat = 1.6
        let wavelength: CGFloat = 5
        let baseline = lineBounds.minY + 1
        let rect = CGRect(
            x: lineBounds.minX,
            y: baseline - amplitude - 2,
            width: lineBounds.width,
            height: amplitude * 2 + 4
        )
        let annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
        annotation.color = style.color
        let border = PDFBorder()
        border.lineWidth = 1.2
        annotation.border = border

        let path = NSBezierPath()
        let midY = rect.height / 2
        path.move(to: CGPoint(x: 0, y: midY))
        var x: CGFloat = 0
        var up = true
        while x < rect.width {
            let next = min(x + wavelength / 2, rect.width)
            path.line(to: CGPoint(x: next, y: midY + (up ? amplitude : -amplitude)))
            up.toggle()
            x = next
        }
        annotation.add(path)
        return annotation
    }

    /// Search & Highlight: highlights every match of `text`.
    @discardableResult
    func highlightAllMatches(of text: String) -> Int {
        guard let document, !text.isEmpty else { return 0 }
        let matches = document.findString(text, withOptions: .caseInsensitive)
        guard !matches.isEmpty else { return 0 }
        undoManager?.beginUndoGrouping()
        var count = 0
        for match in matches {
            for line in match.selectionsByLine() {
                for page in line.pages {
                    let rect = line.bounds(for: page)
                    guard !rect.isEmpty else { continue }
                    let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    annotation.color = style.color.withAlphaComponent(0.5)
                    insert(annotation, on: page)
                    count += 1
                }
            }
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Search & Highlight")
        return count
    }

    // MARK: - Ink & eraser

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
        let inkBounds = PathAnnotation.bounds(of: points, padding: style.lineWidth + 2)
        let annotation = PDFAnnotation(bounds: inkBounds, forType: .ink, withProperties: nil)
        annotation.color = style.color
        annotation.border = style.border

        let path = NSBezierPath()
        let rel = points.map { CGPoint(x: $0.x - inkBounds.origin.x, y: $0.y - inkBounds.origin.y) }
        path.move(to: rel[0])
        for p in rel.dropFirst() { path.line(to: p) }
        annotation.add(path)
        return annotation
    }

    /// Eraser removes pencil strokes under the cursor.
    private func eraseInk(at pagePoint: CGPoint, on page: PDFPage) {
        let victims = page.annotations.filter { annotation in
            guard annotation.type == "Ink" else { return false }
            return annotation.bounds.insetBy(dx: -2, dy: -2).contains(pagePoint)
        }
        for victim in victims { remove(victim) }
    }

    // MARK: - Drag shapes

    private func updateShapePreview(to current: CGPoint, on page: PDFPage) {
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let annotation = makeShapeAnnotation(from: dragStartPagePoint, to: current)
        page.addAnnotation(annotation)
        previewAnnotation = annotation
        setNeedsDisplay(bounds)
    }

    private func finishShape(with event: NSEvent) {
        defer {
            previewAnnotation = nil
            dragPage = nil
        }
        guard let page = dragPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
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

        switch tool {
        case .snapshot, .marqueeZoom:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = .controlAccentColor
            a.border = style.border
            return a
        case .callout:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = .controlAccentColor
            a.border = style.border
            return a
        case .measureDistance:
            return MeasureAnnotation(kind: .distance, points: [start, end], scale: measureScale, color: style.color)
        case .measureAreaCircle:
            return MeasureAnnotation(kind: .areaCircle, points: [start, end], scale: measureScale, color: style.color)
        case .arc:
            return PathAnnotation(kind: .arc, points: [start, end], color: style.color,
                                  lineWidth: style.lineWidth, dashed: style.dashed)
        case .areaHighlight:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = .clear
            a.interiorColor = style.color.withAlphaComponent(0.4)
            return a
        case .redact:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = .black
            a.interiorColor = NSColor.black.withAlphaComponent(0.85)
            a.border = style.border
            a.userName = Self.redactionUserName
            a.contents = "Redaction mark — apply via Protect ▸ Apply Redactions"
            return a
        case .rectangle:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = style.color
            a.border = style.border
            return a
        case .ellipse:
            let a = PDFAnnotation(bounds: rect, forType: .circle, withProperties: nil)
            a.color = style.color
            a.border = style.border
            return a
        default:
            let a = PDFAnnotation(bounds: rect, forType: .line, withProperties: nil)
            a.color = style.color
            a.border = style.border
            a.startPoint = CGPoint(x: start.x - rect.origin.x, y: start.y - rect.origin.y)
            a.endPoint = CGPoint(x: end.x - rect.origin.x, y: end.y - rect.origin.y)
            if tool == .arrow {
                a.endLineStyle = .closedArrow
                a.interiorColor = style.color
            }
            return a
        }
    }

    // MARK: - SnapShot / marquee zoom / callout

    private func draggedPageRect(with event: NSEvent, on page: PDFPage) -> CGRect {
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
        return CGRect(
            x: min(dragStartPagePoint.x, end.x),
            y: min(dragStartPagePoint.y, end.y),
            width: abs(end.x - dragStartPagePoint.x),
            height: abs(end.y - dragStartPagePoint.y)
        )
    }

    private func finishSnapshot(with event: NSEvent) {
        defer {
            previewAnnotation = nil
            dragPage = nil
        }
        guard let page = dragPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let rect = draggedPageRect(with: event, on: page)
        guard rect.width > 4, rect.height > 4 else { return }
        guard let image = PDFOperations.renderRegion(rect, of: page, scale: 2) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        viewModel?.flashHandler?("Snapshot copied to clipboard")
    }

    private func finishMarqueeZoom(with event: NSEvent) {
        defer {
            previewAnnotation = nil
            dragPage = nil
        }
        guard let page = dragPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let rect = draggedPageRect(with: event, on: page)
        guard rect.width > 6, rect.height > 6 else { return }
        autoScales = false
        let visible = convert(bounds, to: page)
        scaleFactor = min(visible.width / rect.width, visible.height / rect.height) * scaleFactor
        go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY)))
        viewModel?.tool = .hand
    }

    private func finishCallout(with event: NSEvent) {
        defer {
            previewAnnotation = nil
            dragPage = nil
        }
        guard let page = dragPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
        // Drag runs from the pointed-at target to where the text box goes.
        let target = dragStartPagePoint
        let boxWidth: CGFloat = max(120, abs(end.x - target.x))
        let boxRect = CGRect(x: end.x, y: end.y - 34, width: boxWidth, height: 34)
        let session = TextSession(
            kind: .callout(target: target),
            page: page,
            pageRect: boxRect,
            pageFontSize: style.fontSize
        )
        startSession(session, text: "")
    }

    // MARK: - In-place text editing

    private func beginAddText(at pagePoint: CGPoint, on page: PDFPage) {
        let fontSize = style.fontSize
        let height = fontSize * 1.7
        let pageBounds = page.bounds(for: .mediaBox)
        let width = min(240, pageBounds.maxX - pagePoint.x - 4)
        guard width > 30 else { return }
        let rect = CGRect(x: pagePoint.x, y: pagePoint.y - height, width: width, height: height)
        startSession(TextSession(kind: .add, page: page, pageRect: rect, pageFontSize: fontSize), text: "")
    }

    /// A previously added text annotation that can be reopened for editing.
    func editableTextAnnotation(at pagePoint: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first {
            $0.type == "FreeText" && $0.bounds.insetBy(dx: -2, dy: -2).contains(pagePoint)
        }
    }

    private func beginEditLine(at pagePoint: CGPoint, on page: PDFPage) {
        // Text this app added stays editable forever — reopen it instead of burning over it.
        if let existing = editableTextAnnotation(at: pagePoint, on: page) {
            beginEditAnnotation(existing, on: page)
            return
        }
        guard let line = page.textLine(at: pagePoint) else { return }
        clearHover()
        let session = TextSession(
            kind: .editLine(original: line.text),
            page: page,
            pageRect: line.rect,
            pageFontSize: line.rect.height * 0.82
        )
        startSession(session, text: line.text)
    }

    /// Reopens an existing freeText annotation in the in-place editor.
    func beginEditAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) {
        clearHover()
        let font = annotation.font ?? .systemFont(ofSize: 14)
        let session = TextSession(
            kind: .editAnnotation(annotation),
            page: page,
            pageRect: annotation.bounds,
            pageFontSize: font.pointSize
        )
        // Hide the original while editing so text is not drawn twice.
        annotation.shouldDisplay = false
        setNeedsDisplay(bounds)
        startSession(session, text: annotation.contents ?? "", font: font, color: annotation.fontColor ?? .black)
    }

    private func startSession(
        _ session: TextSession,
        text: String,
        font: NSFont? = nil,
        color: NSColor? = nil
    ) {
        commitInlineEditor()
        textSession = session

        // Format state seeded from the session (Edit Text matches the text it replaces).
        let state = TextFormatState()
        state.fontSize = session.pageFontSize
        if let font {
            state.fontName = font.familyName ?? font.fontName
            let traits = NSFontManager.shared.traits(of: font)
            state.bold = traits.contains(.boldFontMask)
            state.italic = traits.contains(.italicFontMask)
        } else if !session.kind.isEdit {
            state.fontName = style.fontName
            state.bold = style.bold
            state.italic = style.italic
        }
        state.color = color ?? (session.kind.isEdit ? .black : style.textColor)
        formatState = state

        let box = InlineTextBox(frame: .zero)
        box.editor.string = text
        box.editor.commitsOnEnter = false  // Enter adds a line; ⌘Enter or click-away commits
        box.editor.backgroundColor = session.kind.isEdit ? .white : NSColor.white.withAlphaComponent(0.7)
        box.editor.onCommit = { [weak self] in self?.commitInlineEditor() }
        box.editor.onCancel = { [weak self] in self?.cancelInlineEditor() }
        box.onMove = { [weak self] delta in self?.moveSession(by: delta) }
        box.onResize = { [weak self] delta in self?.resizeSession(by: delta) }

        addSubview(box)
        inlineBox = box

        let host = NSHostingView(rootView: TextFormatBar(state: state))
        addSubview(host)
        formatBarHost = host

        applyFormatting()
        formatCancellable = state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.applyFormatting() }
        }

        layoutInlineEditor()
        window?.makeFirstResponder(box.editor)
        box.editor.setSelectedRange(NSRange(location: text.count, length: 0))

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

    /// Pushes the format bar's font/size/color into the live editor.
    private func applyFormatting() {
        guard let state = formatState, let editor = inlineEditor else { return }
        textSession?.pageFontSize = state.fontSize
        editor.font = state.font(at: state.fontSize * scaleFactor)
        editor.textColor = state.color
        // Remember the choices as the defaults for the next text box.
        if let session = textSession, !session.kind.isEdit {
            viewModel?.style.fontName = state.fontName
            viewModel?.style.fontSize = state.fontSize
            viewModel?.style.bold = state.bold
            viewModel?.style.italic = state.italic
            viewModel?.style.textColor = state.color
        }
        layoutInlineEditor()
    }

    private func moveSession(by delta: CGSize) {
        guard var session = textSession else { return }
        let pageDelta = CGSize(width: delta.width / scaleFactor, height: delta.height / scaleFactor)
        var rect = session.pageRect
        rect.origin.x += pageDelta.width
        rect.origin.y += pageDelta.height
        let limits = session.page.bounds(for: .mediaBox)
        rect.origin.x = min(max(limits.minX - rect.width / 2, rect.origin.x), limits.maxX - rect.width / 2)
        rect.origin.y = min(max(limits.minY - rect.height / 2, rect.origin.y), limits.maxY - rect.height / 2)
        session.pageRect = rect
        textSession = session
        layoutInlineEditor()
    }

    private func resizeSession(by delta: CGSize) {
        guard var session = textSession else { return }
        let pageDelta = CGSize(width: delta.width / scaleFactor, height: delta.height / scaleFactor)
        var rect = session.pageRect
        let newWidth = max(40, rect.width + pageDelta.width)
        // Dragging the bottom-right grip grows downward: the top edge stays put.
        let newHeight = max(session.pageFontSize * 1.4, rect.height - pageDelta.height)
        rect = CGRect(x: rect.minX, y: rect.maxY - newHeight, width: newWidth, height: newHeight)
        session.pageRect = rect
        textSession = session
        layoutInlineEditor()
    }

    private func layoutInlineEditor() {
        guard let box = inlineBox, let session = textSession else { return }
        let margin = InlineTextBox.margin
        box.frame = convert(session.pageRect, from: session.page).insetBy(dx: -margin, dy: -margin)
        box.needsLayout = true
        box.window?.invalidateCursorRects(for: box)

        if let host = formatBarHost {
            let size = host.fittingSize
            var origin = NSPoint(x: box.frame.minX, y: box.frame.maxY + 6)
            if origin.y + size.height > bounds.maxY { origin.y = box.frame.minY - size.height - 6 }
            origin.x = min(max(4, origin.x), max(4, bounds.maxX - size.width - 4))
            host.frame = NSRect(origin: origin, size: size)
        }
    }

    private func teardownInlineEditor() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        formatCancellable = nil
        formatState = nil
        formatBarHost?.removeFromSuperview()
        formatBarHost = nil
        inlineBox?.removeFromSuperview()
        inlineBox = nil
        textSession = nil
        window?.makeFirstResponder(self)
    }

    func commitInlineEditor() {
        guard let editor = inlineEditor, let session = textSession else { return }
        let text = editor.string
        let state = formatState ?? TextFormatState()
        let font = state.font(at: state.fontSize)
        let color = state.color
        teardownInlineEditor()

        switch session.kind {
        case .add:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            insert(makeTextAnnotation(text: text, session: session, font: font, color: color), on: session.page)

        case .callout(let target):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let annotation = CalloutAnnotation(
                text: text,
                boxRect: session.pageRect,
                target: target,
                font: font,
                textColor: color,
                strokeColor: style.color
            )
            insert(annotation, on: session.page)

        case .editAnnotation(let original):
            original.shouldDisplay = true
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                remove(original)
                return
            }
            let replacement = makeTextAnnotation(text: text, session: session, font: font, color: color)
            replacement.contents = text
            undoManager?.beginUndoGrouping()
            remove(original)
            insert(replacement, on: session.page)
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Edit Text")
            viewModel?.selectedAnnotation = replacement

        case .editLine(let original):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != original else { return }
            viewModel?.editTextHandler?(session.page, session.pageRect, trimmed, font, color)
        }
    }

    private func makeTextAnnotation(
        text: String,
        session: TextSession,
        font: NSFont,
        color: NSColor
    ) -> PDFAnnotation {
        // Grow the box downward if the typed text needs more room than it was given.
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: session.pageRect.width, height: 4000),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        )
        let height = max(session.pageRect.height, measured.height + 6)
        let rect = CGRect(
            x: session.pageRect.minX,
            y: session.pageRect.maxY - height,
            width: session.pageRect.width,
            height: height
        )
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = color
        annotation.color = .clear
        return annotation
    }

    private func cancelInlineEditor() {
        if case .editAnnotation(let original)? = textSession?.kind {
            original.shouldDisplay = true
        }
        teardownInlineEditor()
        setNeedsDisplay(bounds)
    }
}

// MARK: - Stamp text annotation

/// Classic review stamp ("APPROVED", "DRAFT", …) drawn as outlined text.
final class StampTextAnnotation: PDFAnnotation {
    let text: String
    let stampColor: NSColor

    init(text: String, bounds: CGRect, color: NSColor) {
        self.text = text
        self.stampColor = color
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        contents = text
        userName = "AquaPDF.stamp"
    }

    required init?(coder: NSCoder) {
        // PDFKit can archive/unarchive annotations while copying pages or writing a
        // document; trapping here would crash the app, so decode into a plain stamp.
        text = coder.decodeObject(forKey: "text") as? String ?? ""
        stampColor = coder.decodeObject(forKey: "stampColor") as? NSColor ?? .systemRed
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        let rect = bounds.insetBy(dx: 2, dy: 2)
        context.setStrokeColor(stampColor.cgColor)
        context.setLineWidth(2.5)
        let rounded = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(rounded)
        context.strokePath()

        let size = min(rect.height * 0.55, rect.width / max(CGFloat(text.count) * 0.62, 1))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: stampColor.cgColor,
        ]
        if let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY - size * 0.35)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

// MARK: - Small modal text prompt

enum InputPrompt {
    /// Runs a modal single-field prompt. Returns nil when cancelled.
    @MainActor
    static func run(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Modal password prompt. Returns nil when cancelled or left empty.
    @MainActor
    static func runSecure(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
    }

    /// Modal confirmation for a destructive action.
    @MainActor
    static func confirmDestructive(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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

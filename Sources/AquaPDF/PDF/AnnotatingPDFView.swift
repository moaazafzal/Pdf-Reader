import AppKit
import Combine
import PDFKit
import SwiftUI

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
            var isEdit: Bool { if case .editLine = self { return true }; return false }
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

    // MARK: - Visual mode (Default / Night / Sepia / Eye Comfort)

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
    /// Points per tick; negative scrolls backwards.
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
    }

    private func autoScrollTick() {
        guard let clipView = documentView?.enclosingScrollView?.contentView,
              let docHeight = documentView?.frame.height
        else { return stopAutoScroll() }
        var origin = clipView.bounds.origin
        origin.y += autoScrollSpeed
        let maxY = docHeight - clipView.bounds.height
        guard maxY > 0 else { return stopAutoScroll() }
        if origin.y >= maxY {
            origin.y = maxY
            clipView.scroll(to: origin)
            documentView?.enclosingScrollView?.reflectScrolledClipView(clipView)
            stopAutoScroll()
            return
        }
        clipView.scroll(to: origin)
        documentView?.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

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

        case .highlight, .underline, .squiggly, .strikeout:
            // Let PDFView run its normal text-selection drag; markup applied on mouseUp.
            super.mouseDown(with: event)

        case .ink:
            dragPage = page
            inkPoints = [pagePoint]

        case .rectangle, .ellipse, .line, .arrow, .redact, .areaHighlight, .snapshot:
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

        case .rectangle, .ellipse, .line, .arrow, .redact, .areaHighlight, .snapshot:
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

        case .highlight, .underline, .squiggly, .strikeout:
            super.mouseUp(with: event)
            applyMarkup()

        case .ink:
            finishInk()

        case .snapshot:
            finishSnapshot(with: event)

        case .rectangle, .ellipse, .line, .arrow, .redact, .areaHighlight:
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

        // Format state seeded from the session (Edit Text matches the line it replaces).
        let state = TextFormatState()
        state.fontSize = session.pageFontSize
        switch session.kind {
        case .add:
            state.fontName = style.fontName
            state.color = style.color
        case .editLine:
            state.color = .black
        }
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

        // Floating format bar above the box.
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
            viewModel?.style.color = state.color
        }
        layoutInlineEditor()
    }

    private func moveSession(by delta: CGSize) {
        guard var session = textSession else { return }
        let pageDelta = CGSize(width: delta.width / scaleFactor, height: delta.height / scaleFactor)
        var rect = session.pageRect
        rect.origin.x += pageDelta.width
        rect.origin.y += pageDelta.height
        // Keep the box on the page.
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
            // Flip below the box if there is no room above.
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
            insert(annotation, on: session.page)

        case .editLine(let original):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != original else { return }
            viewModel?.editTextHandler?(session.page, session.pageRect, trimmed, font, color)
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
                // PDFKit has no Squiggly subtype — draw a wavy ink line under the text instead.
                let annotation = tool == .squiggly
                    ? makeSquigglyAnnotation(under: lineBounds)
                    : PDFAnnotation(bounds: lineBounds, forType: subtype, withProperties: nil)
                if tool != .squiggly {
                    annotation.color = style.color.withAlphaComponent(tool == .highlight ? 0.5 : 1)
                }
                insert(annotation, on: page)
            }
        }
        setCurrentSelection(nil, animate: false)
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

    /// SnapShot: copies the dragged page region to the clipboard as an image.
    private func finishSnapshot(with event: NSEvent) {
        defer {
            previewAnnotation = nil
            dragPage = nil
        }
        guard let page = dragPage else { return }
        if let preview = previewAnnotation { page.removeAnnotation(preview) }
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
        let rect = CGRect(
            x: min(dragStartPagePoint.x, end.x),
            y: min(dragStartPagePoint.y, end.y),
            width: abs(end.x - dragStartPagePoint.x),
            height: abs(end.y - dragStartPagePoint.y)
        )
        guard rect.width > 4, rect.height > 4 else { return }

        let scale: CGFloat = 2  // 144 dpi
        let pixelSize = CGSize(width: rect.width * scale, height: rect.height * scale)
        let full = page.thumbnail(of: CGSize(width: page.bounds(for: .mediaBox).width * scale,
                                             height: page.bounds(for: .mediaBox).height * scale),
                                  for: .mediaBox)
        let crop = NSImage(size: pixelSize)
        crop.lockFocus()
        let pageBounds = page.bounds(for: .mediaBox)
        // Page space is bottom-left origin, same as NSImage — offset by the crop rect.
        let source = NSRect(
            x: (rect.minX - pageBounds.minX) * scale,
            y: (rect.minY - pageBounds.minY) * scale,
            width: pixelSize.width,
            height: pixelSize.height
        )
        full.draw(in: NSRect(origin: .zero, size: pixelSize), from: source, operation: .copy, fraction: 1)
        crop.unlockFocus()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([crop])
        viewModel?.flashHandler?("Snapshot copied to clipboard")
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
        case .snapshot:
            // Marquee preview only — never committed as an annotation.
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = .controlAccentColor
            a.border = border
            return a
        case .areaHighlight:
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = .clear
            a.interiorColor = style.color.withAlphaComponent(0.4)
            return a
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

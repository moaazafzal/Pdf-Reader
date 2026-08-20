import AppKit
import SwiftUI

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

/// Draggable, resizable frame around an in-place text editor.
/// The border margin is the drag handle; the bottom-right corner resizes.
final class InlineTextBox: NSView {
    static let margin: CGFloat = 9
    private static let cornerSize: CGFloat = 12

    let editor = InlineTextEditor()

    /// Called with the frame delta (in view coordinates) while dragging or resizing.
    var onMove: ((CGSize) -> Void)?
    var onResize: ((CGSize) -> Void)?

    private enum Mode { case none, moving, resizing }
    private var mode: Mode = .none
    private var lastPoint: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 3
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor

        editor.isRichText = false
        editor.drawsBackground = true
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 2, height: 2)
        addSubview(editor)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        editor.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
    }

    // MARK: - Cursors

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(resizeCornerRect, cursor: .crosshair)
        addCursorRect(bounds.insetBy(dx: Self.margin, dy: Self.margin), cursor: .iBeam)
    }

    private var resizeCornerRect: NSRect {
        NSRect(x: bounds.maxX - Self.cornerSize, y: bounds.minY, width: Self.cornerSize, height: Self.cornerSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Resize grip in the bottom-right corner.
        NSColor.controlAccentColor.setFill()
        let grip = NSBezierPath()
        let r = resizeCornerRect.insetBy(dx: 3, dy: 3)
        grip.move(to: NSPoint(x: r.maxX, y: r.minY))
        grip.line(to: NSPoint(x: r.maxX, y: r.maxY))
        grip.line(to: NSPoint(x: r.minX, y: r.minY))
        grip.close()
        grip.fill()
    }

    // MARK: - Drag / resize

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Border margin and resize corner belong to this view; the interior goes to the editor.
        if resizeCornerRect.contains(local) { return self }
        if bounds.insetBy(dx: Self.margin, dy: Self.margin).contains(local) { return editor }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        lastPoint = convert(event.locationInWindow, from: nil)
        mode = resizeCornerRect.contains(lastPoint) ? .resizing : .moving
        if mode == .moving { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode != .none else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y)
        switch mode {
        case .moving:
            onMove?(delta)
        case .resizing:
            onResize?(delta)
            lastPoint = point
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        mode = .none
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }
}

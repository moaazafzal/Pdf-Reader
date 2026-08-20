import AppKit
import PDFKit

/// Multi-segment shapes (polygon, polyline, cloud, arc) and measurements.
/// PDFKit has no Polygon/PolyLine subtypes, so these draw themselves as ink paths
/// that other readers still render correctly.
final class PathAnnotation: PDFAnnotation {
    enum Kind: String {
        case polygon, polyline, cloud, arc
    }

    let kind: Kind
    /// Points in page space.
    private(set) var points: [CGPoint]
    var strokeColor: NSColor
    var fillColor: NSColor?
    var strokeWidth: CGFloat
    var dashed: Bool

    init(
        kind: Kind,
        points: [CGPoint],
        color: NSColor,
        fill: NSColor? = nil,
        lineWidth: CGFloat = 2,
        dashed: Bool = false
    ) {
        self.kind = kind
        self.points = points
        self.strokeColor = color
        self.fillColor = fill
        self.strokeWidth = lineWidth
        self.dashed = dashed
        let bounds = PathAnnotation.bounds(of: points, padding: lineWidth + 12)
        super.init(bounds: bounds, forType: .ink, withProperties: nil)
        self.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        self.border = border
        userName = "AquaPDF.\(kind.rawValue)"
        rebuildInkPath()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func bounds(of points: [CGPoint], padding: CGFloat) -> CGRect {
        guard !points.isEmpty else { return .zero }
        var rect = CGRect(origin: points[0], size: .zero)
        for p in points.dropFirst() {
            rect = rect.union(CGRect(origin: p, size: .zero))
        }
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    /// Path in annotation-local coordinates.
    func localPath() -> NSBezierPath {
        let origin = bounds.origin
        let local = points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        switch kind {
        case .polygon:
            let path = NSBezierPath()
            guard local.count > 1 else { return path }
            path.move(to: local[0])
            for p in local.dropFirst() { path.line(to: p) }
            path.close()
            return path
        case .polyline:
            let path = NSBezierPath()
            guard local.count > 1 else { return path }
            path.move(to: local[0])
            for p in local.dropFirst() { path.line(to: p) }
            return path
        case .cloud:
            return PathAnnotation.cloudPath(through: local, closed: true)
        case .arc:
            let path = NSBezierPath()
            guard local.count >= 2 else { return path }
            let start = local[0], end = local[local.count - 1]
            // Bow the curve perpendicular to the chord.
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let dx = end.x - start.x, dy = end.y - start.y
            let control = CGPoint(x: mid.x - dy * 0.4, y: mid.y + dx * 0.4)
            path.move(to: start)
            path.curve(to: end, controlPoint1: control, controlPoint2: control)
            return path
        }
    }

    /// Cloud outline: scalloped arcs along each segment.
    static func cloudPath(through points: [CGPoint], closed: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count >= 2 else { return path }
        let list = closed ? points + [points[0]] : points
        let radius: CGFloat = 9

        path.move(to: list[0])
        for i in 0..<(list.count - 1) {
            let a = list[i], b = list[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(sqrt(dx * dx + dy * dy), 0.01)
            let bumps = max(Int(length / (radius * 1.6)), 1)
            let stepX = dx / CGFloat(bumps), stepY = dy / CGFloat(bumps)
            // Perpendicular direction, used to bow each scallop outward.
            let nx = -dy / length, ny = dx / length
            for b in 0..<bumps {
                let from = CGPoint(x: a.x + stepX * CGFloat(b), y: a.y + stepY * CGFloat(b))
                let to = CGPoint(x: a.x + stepX * CGFloat(b + 1), y: a.y + stepY * CGFloat(b + 1))
                let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                let bulge = CGPoint(x: mid.x + nx * radius, y: mid.y + ny * radius)
                path.curve(to: to, controlPoint1: bulge, controlPoint2: bulge)
            }
        }
        if closed { path.close() }
        return path
    }

    /// Keeps an ink path attached so the annotation still renders in other PDF readers.
    private func rebuildInkPath() {
        for path in paths ?? [] { remove(path) }
        add(localPath())
    }

    func setPoints(_ newPoints: [CGPoint]) {
        points = newPoints
        bounds = PathAnnotation.bounds(of: newPoints, padding: strokeWidth + 12)
        rebuildInkPath()
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: bounds.origin.x, y: bounds.origin.y)
        let path = localPath().cgPath
        if let fillColor {
            context.setFillColor(fillColor.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        if dashed { context.setLineDash(phase: 0, lengths: [5, 4]) }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

/// Distance / perimeter / area measurement with an on-page label.
final class MeasureAnnotation: PDFAnnotation {
    enum Kind { case distance, perimeter, areaPolygon, areaCircle }

    let kind: Kind
    private(set) var points: [CGPoint]
    let scale: MeasureScale
    var strokeColor: NSColor

    init(kind: Kind, points: [CGPoint], scale: MeasureScale, color: NSColor) {
        self.kind = kind
        self.points = points
        self.scale = scale
        self.strokeColor = color
        let bounds = PathAnnotation.bounds(of: points, padding: 26)
        super.init(bounds: bounds, forType: .ink, withProperties: nil)
        self.color = color
        userName = "AquaPDF.measure"
        contents = MeasureAnnotation.measurementText(kind: kind, points: points, scale: scale)
        rebuildPath()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func measurementText(kind: Kind, points: [CGPoint], scale: MeasureScale) -> String {
        switch kind {
        case .distance:
            guard points.count >= 2 else { return "" }
            return scale.format(length: hypot(points[1].x - points[0].x, points[1].y - points[0].y))
        case .perimeter:
            var total: CGFloat = 0
            for i in 0..<max(points.count - 1, 0) {
                total += hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y)
            }
            return scale.format(length: total)
        case .areaPolygon:
            return scale.format(area: MeasureAnnotation.shoelaceArea(points))
        case .areaCircle:
            guard points.count >= 2 else { return "" }
            let rx = abs(points[1].x - points[0].x) / 2
            let ry = abs(points[1].y - points[0].y) / 2
            return scale.format(area: .pi * rx * ry)
        }
    }

    /// Polygon area by the shoelace formula.
    static func shoelaceArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    func setPoints(_ newPoints: [CGPoint]) {
        points = newPoints
        bounds = PathAnnotation.bounds(of: newPoints, padding: 26)
        contents = MeasureAnnotation.measurementText(kind: kind, points: newPoints, scale: scale)
        rebuildPath()
    }

    private func localPath() -> NSBezierPath {
        let origin = bounds.origin
        let local = points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        let path = NSBezierPath()
        switch kind {
        case .distance, .perimeter:
            guard local.count >= 2 else { return path }
            path.move(to: local[0])
            for p in local.dropFirst() { path.line(to: p) }
        case .areaPolygon:
            guard local.count >= 2 else { return path }
            path.move(to: local[0])
            for p in local.dropFirst() { path.line(to: p) }
            path.close()
        case .areaCircle:
            guard local.count >= 2 else { return path }
            path.appendOval(in: CGRect(
                x: min(local[0].x, local[1].x),
                y: min(local[0].y, local[1].y),
                width: abs(local[1].x - local[0].x),
                height: abs(local[1].y - local[0].y)
            ))
        }
        return path
    }

    private func rebuildPath() {
        for path in paths ?? [] { remove(path) }
        add(localPath())
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: bounds.origin.x, y: bounds.origin.y)
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.addPath(localPath().cgPath)
        context.strokePath()

        // End caps for distance measurements.
        if kind == .distance, points.count >= 2 {
            let origin = bounds.origin
            for p in [points[0], points[1]] {
                let local = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
                context.fillEllipse(in: CGRect(x: local.x - 2.5, y: local.y - 2.5, width: 5, height: 5))
            }
            context.setFillColor(strokeColor.cgColor)
            context.fillPath()
        }
        context.restoreGState()

        drawLabel(in: context)
    }

    private func drawLabel(in context: CGContext) {
        guard let text = contents, !text.isEmpty else { return }
        let anchor: CGPoint
        switch kind {
        case .distance where points.count >= 2:
            anchor = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        default:
            anchor = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: NSColor.white.cgColor,
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let box = CGRect(x: anchor.x - width / 2 - 4, y: anchor.y - 7, width: width + 8, height: 14)

        context.saveGState()
        context.setFillColor(strokeColor.withAlphaComponent(0.9).cgColor)
        context.fill(box)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: box.minX + 4, y: box.minY + 4)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Text box with a leader line pointing at a target (Foxit "Callout").
final class CalloutAnnotation: PDFAnnotation {
    var text: String
    var target: CGPoint
    var textFont: NSFont
    var textColor: NSColor
    var strokeColor: NSColor

    init(text: String, boxRect: CGRect, target: CGPoint, font: NSFont, textColor: NSColor, strokeColor: NSColor) {
        self.text = text
        self.target = target
        self.textFont = font
        self.textColor = textColor
        self.strokeColor = strokeColor
        let bounds = boxRect.union(CGRect(origin: target, size: .zero)).insetBy(dx: -8, dy: -8)
        super.init(bounds: bounds, forType: .freeText, withProperties: nil)
        contents = text
        color = .clear
        userName = "AquaPDF.callout"
        self.boxRect = boxRect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Text box in page space (the leader line runs from here to `target`).
    var boxRect: CGRect = .zero

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()

        // Leader line from the nearest box edge to the target point.
        let from = CGPoint(
            x: min(max(target.x, boxRect.minX), boxRect.maxX),
            y: target.y > boxRect.maxY ? boxRect.maxY : (target.y < boxRect.minY ? boxRect.minY : boxRect.midY)
        )
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(1.4)
        context.move(to: from)
        context.addLine(to: target)
        context.strokePath()
        context.fillEllipse(in: CGRect(x: target.x - 2.5, y: target.y - 2.5, width: 5, height: 5))
        context.setFillColor(strokeColor.cgColor)
        context.fillEllipse(in: CGRect(x: target.x - 2.5, y: target.y - 2.5, width: 5, height: 5))

        // Box
        context.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.fill(boxRect)
        context.stroke(boxRect)

        // Text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: textFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])
        let framePath = CGPath(rect: boxRect.insetBy(dx: 4, dy: 3), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), framePath, nil)
        CTFrameDraw(frame, context)

        context.restoreGState()
    }
}

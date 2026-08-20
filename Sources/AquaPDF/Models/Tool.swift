import AppKit
import PDFKit

enum Tool: String, CaseIterable, Identifiable {
    // Navigation / selection
    case hand
    case select
    case selectAnnotation
    case snapshot
    case marqueeZoom

    // Text markup
    case highlight
    case underline
    case squiggly
    case strikeout
    case replaceText
    case insertText
    case areaHighlight

    // Notes & text
    case note
    case fileAttachment
    case textBox
    case callout
    case editText

    // Drawing
    case ink
    case eraser
    case rectangle
    case ellipse
    case line
    case arrow
    case polygon
    case polyline
    case cloud
    case arc

    // Stamps & signing
    case stamp
    case signature
    case imageStamp

    // Measure
    case measureDistance
    case measurePerimeter
    case measureAreaPolygon
    case measureAreaCircle

    // Security
    case redact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hand: return "Hand"
        case .select: return "Select"
        case .selectAnnotation: return "Select Annotation"
        case .snapshot: return "SnapShot"
        case .marqueeZoom: return "Marquee"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .squiggly: return "Squiggly"
        case .strikeout: return "Strikeout"
        case .replaceText: return "Replace Text"
        case .insertText: return "Insert Text"
        case .areaHighlight: return "Area Highlight"
        case .note: return "Note"
        case .fileAttachment: return "File"
        case .textBox: return "Text Box"
        case .callout: return "Callout"
        case .editText: return "Edit Text"
        case .ink: return "Pencil"
        case .eraser: return "Eraser"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Oval"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .polygon: return "Polygon"
        case .polyline: return "Polyline"
        case .cloud: return "Cloud"
        case .arc: return "Arc"
        case .stamp: return "Stamp"
        case .signature: return "Signature"
        case .imageStamp: return "Image"
        case .measureDistance: return "Distance"
        case .measurePerimeter: return "Perimeter"
        case .measureAreaPolygon: return "Area"
        case .measureAreaCircle: return "Circle Area"
        case .redact: return "Redact"
        }
    }

    var systemImage: String {
        switch self {
        case .hand: return "hand.raised"
        case .select: return "cursorarrow"
        case .selectAnnotation: return "cursorarrow.rays"
        case .snapshot: return "camera.viewfinder"
        case .marqueeZoom: return "viewfinder.rectangular"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .squiggly: return "underline"
        case .strikeout: return "strikethrough"
        case .replaceText: return "arrow.left.arrow.right"
        case .insertText: return "text.insert"
        case .areaHighlight: return "rectangle.inset.filled"
        case .note: return "note.text"
        case .fileAttachment: return "paperclip"
        case .textBox: return "textbox"
        case .callout: return "bubble.left.and.text.bubble.right"
        case .editText: return "character.cursor.ibeam"
        case .ink: return "pencil.and.scribble"
        case .eraser: return "eraser"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .polygon: return "pentagon"
        case .polyline: return "scribble.variable"
        case .cloud: return "cloud"
        case .arc: return "arrow.up.forward"
        case .stamp: return "seal"
        case .signature: return "signature"
        case .imageStamp: return "photo"
        case .measureDistance: return "ruler"
        case .measurePerimeter: return "ruler.fill"
        case .measureAreaPolygon: return "skew"
        case .measureAreaCircle: return "circle.dashed"
        case .redact: return "eye.slash"
        }
    }

    /// Markup tools operate on a text selection made by dragging.
    var isTextMarkup: Bool {
        switch self {
        case .highlight, .underline, .squiggly, .strikeout, .replaceText, .insertText: return true
        default: return false
        }
    }

    /// Tools built by clicking a series of points, finished with double-click or Enter.
    var isMultiPoint: Bool {
        switch self {
        case .polygon, .polyline, .cloud, .measurePerimeter, .measureAreaPolygon: return true
        default: return false
        }
    }

    /// Tools built by a single press-drag-release.
    var isDragShape: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .arc, .redact, .areaHighlight,
             .snapshot, .marqueeZoom, .measureDistance, .measureAreaCircle, .callout:
            return true
        default: return false
        }
    }

    var isMeasure: Bool {
        switch self {
        case .measureDistance, .measurePerimeter, .measureAreaPolygon, .measureAreaCircle: return true
        default: return false
        }
    }
}

struct AnnotationStyle {
    var color: NSColor = .systemYellow
    /// Text tools default to black; markup keeps its own highlight color.
    var textColor: NSColor = .black
    var lineWidth: CGFloat = 2
    var opacity: CGFloat = 1
    var fontName: String = "Helvetica"
    var fontSize: CGFloat = 14
    var bold = false
    var italic = false
    var dashed = false

    /// Text font with the current family, size and traits.
    var font: NSFont {
        var font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let manager = NSFontManager.shared
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    var border: PDFBorder {
        let border = PDFBorder()
        border.lineWidth = lineWidth
        if dashed {
            border.style = .dashed
            border.dashPattern = [4, 3]
        }
        return border
    }
}

/// Measurement scale: how many page points equal one real-world unit.
struct MeasureScale {
    var unit: String = "in"
    /// Real-world units per PDF point.
    var unitsPerPoint: Double = 1.0 / 72.0

    static let presets: [(name: String, unit: String, unitsPerPoint: Double)] = [
        ("Inches", "in", 1.0 / 72.0),
        ("Centimeters", "cm", 2.54 / 72.0),
        ("Millimeters", "mm", 25.4 / 72.0),
        ("Points", "pt", 1.0),
    ]

    func format(length: CGFloat) -> String {
        String(format: "%.2f %@", Double(length) * unitsPerPoint, unit)
    }

    func format(area: CGFloat) -> String {
        String(format: "%.2f %@²", Double(area) * unitsPerPoint * unitsPerPoint, unit)
    }
}

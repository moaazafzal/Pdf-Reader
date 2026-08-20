import AppKit
import PDFKit

enum Tool: String, CaseIterable, Identifiable {
    case select
    case highlight
    case underline
    case squiggly
    case strikeout
    case areaHighlight
    case snapshot
    case ink
    case rectangle
    case ellipse
    case line
    case arrow
    case textBox
    case note
    case signature
    case imageStamp
    case redact
    case editText

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .squiggly: return "Squiggly"
        case .strikeout: return "Strikeout"
        case .areaHighlight: return "Area Highlight"
        case .snapshot: return "SnapShot"
        case .ink: return "Draw"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .textBox: return "Text Box"
        case .note: return "Note"
        case .signature: return "Signature"
        case .imageStamp: return "Image"
        case .redact: return "Redact"
        case .editText: return "Edit Text (beta)"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .squiggly: return "underline"
        case .strikeout: return "strikethrough"
        case .areaHighlight: return "rectangle.inset.filled"
        case .snapshot: return "camera.viewfinder"
        case .ink: return "pencil.and.scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .textBox: return "textbox"
        case .note: return "note.text"
        case .signature: return "signature"
        case .imageStamp: return "photo"
        case .redact: return "eye.slash"
        case .editText: return "character.cursor.ibeam"
        }
    }

    /// Markup tools operate on a text selection made by dragging.
    var isTextMarkup: Bool {
        self == .highlight || self == .underline || self == .squiggly || self == .strikeout
    }

    var isShape: Bool {
        self == .rectangle || self == .ellipse || self == .line || self == .arrow
    }
}

struct AnnotationStyle {
    var color: NSColor = .systemYellow
    var lineWidth: CGFloat = 2
    var opacity: CGFloat = 1
    var fontName: String = "Helvetica"
    var fontSize: CGFloat = 14
    var bold = false
    var italic = false

    /// Text font with the current family, size and traits.
    var font: NSFont {
        var font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let manager = NSFontManager.shared
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
}

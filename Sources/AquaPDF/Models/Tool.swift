import AppKit
import PDFKit

enum Tool: String, CaseIterable, Identifiable {
    case select
    case highlight
    case underline
    case strikeout
    case ink
    case rectangle
    case ellipse
    case line
    case arrow
    case textBox
    case note
    case signature
    case imageStamp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strikeout"
        case .ink: return "Draw"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .textBox: return "Text Box"
        case .note: return "Note"
        case .signature: return "Signature"
        case .imageStamp: return "Image"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
        case .ink: return "pencil.and.scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .textBox: return "textbox"
        case .note: return "note.text"
        case .signature: return "signature"
        case .imageStamp: return "photo"
        }
    }

    /// Markup tools operate on a text selection made by dragging.
    var isTextMarkup: Bool {
        self == .highlight || self == .underline || self == .strikeout
    }

    var isShape: Bool {
        self == .rectangle || self == .ellipse || self == .line || self == .arrow
    }
}

struct AnnotationStyle {
    var color: NSColor = .systemYellow
    var lineWidth: CGFloat = 2
    var opacity: CGFloat = 1
    var fontSize: CGFloat = 14
}

import Foundation
import PDFKit

/// Review metadata (replies, status, checkmark) stored on the annotation itself.
/// Custom annotation keys survive a PDFKit write/read round trip, so this persists in the file.
struct CommentMeta: Codable {
    enum Status: String, Codable, CaseIterable, Identifiable {
        case none = "None"
        case accepted = "Accepted"
        case rejected = "Rejected"
        case cancelled = "Cancelled"
        case completed = "Completed"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .none: return "circle"
            case .accepted: return "checkmark.circle"
            case .rejected: return "xmark.circle"
            case .cancelled: return "slash.circle"
            case .completed: return "flag.checkered"
            }
        }
    }

    struct Reply: Codable, Identifiable {
        var id = UUID()
        var author: String
        var text: String
        var date: Date
    }

    var status: Status = .none
    var checked = false
    var replies: [Reply] = []

    static let annotationKey = PDFAnnotationKey(rawValue: "AquaPDFReview")

    static func read(from annotation: PDFAnnotation) -> CommentMeta {
        guard let raw = annotation.value(forAnnotationKey: annotationKey) as? String,
              let data = raw.data(using: .utf8),
              let meta = try? JSONDecoder().decode(CommentMeta.self, from: data)
        else { return CommentMeta() }
        return meta
    }

    func write(to annotation: PDFAnnotation) {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return }
        annotation.setValue(string, forAnnotationKey: CommentMeta.annotationKey)
    }
}

extension PDFAnnotation {
    var reviewMeta: CommentMeta {
        get { CommentMeta.read(from: self) }
        set { newValue.write(to: self) }
    }

    /// Human-readable annotation kind, matching the names used in the ribbon.
    var displayKind: String {
        if userName?.hasPrefix("AquaPDF.") == true {
            let suffix = String(userName!.dropFirst("AquaPDF.".count))
            switch suffix {
            case "Redact": return "Redaction"
            case "measure": return "Measurement"
            case "callout": return "Callout"
            case "stamp": return "Stamp"
            case "attachment": return "File Attachment"
            default: return suffix.capitalized
            }
        }
        switch type ?? "" {
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strikeout"
        case "Ink": return "Pencil"
        case "Square": return "Rectangle"
        case "Circle": return "Oval"
        case "Line": return "Line"
        case "FreeText": return "Text"
        case "Text": return "Note"
        case "Stamp": return "Stamp"
        default: return type ?? "Annotation"
        }
    }
}

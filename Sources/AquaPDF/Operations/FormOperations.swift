import AppKit
import PDFKit

/// Interactive form (AcroForm) support: reset, highlight, import/export field data.
enum FormOperations {

    static func fields(in document: PDFDocument) -> [PDFAnnotation] {
        (0..<document.pageCount).flatMap { i -> [PDFAnnotation] in
            document.page(at: i)?.annotations.filter { $0.isWidget } ?? []
        }
    }

    static func resetForm(in document: PDFDocument) -> Int {
        let all = fields(in: document)
        for field in all {
            switch field.widgetControlType {
            case .radioButtonControl, .checkBoxControl:
                field.buttonWidgetState = .offState
            default:
                field.widgetStringValue = ""
            }
        }
        return all.count
    }

    static func setHighlight(_ on: Bool, in document: PDFDocument) {
        for field in fields(in: document) {
            field.backgroundColor = on
                ? NSColor.systemBlue.withAlphaComponent(0.18)
                : .clear
        }
    }

    /// Field name → value for every named field with a value.
    static func values(in document: PDFDocument) -> [(name: String, value: String)] {
        fields(in: document).compactMap { field -> (name: String, value: String)? in
            guard let name = field.fieldName, !name.isEmpty else { return nil }
            let value: String
            switch field.widgetControlType {
            case .radioButtonControl, .checkBoxControl:
                value = field.buttonWidgetState == .onState ? "On" : "Off"
            default:
                value = field.widgetStringValue ?? ""
            }
            return (name: name, value: value)
        }
    }

    static func exportFDF(_ document: PDFDocument, to url: URL) throws {
        let entries = values(in: document)
        let body = entries.map { entry in
            "<< /T (\(escape(entry.name))) /V (\(escape(entry.value))) >>"
        }.joined(separator: "\n")
        let fdf = """
        %FDF-1.2
        1 0 obj
        << /FDF << /Fields [
        \(body)
        ] /F (\(escape(document.documentURL?.lastPathComponent ?? ""))) >> >>
        endobj
        trailer
        << /Root 1 0 R >>
        %%EOF
        """
        try fdf.write(to: url, atomically: true, encoding: .isoLatin1)
    }

    static func exportCSV(_ document: PDFDocument, to url: URL, appending: Bool) throws {
        let entries = values(in: document)
        let header = entries.map { csvEscape($0.name) }.joined(separator: ",")
        let row = entries.map { csvEscape($0.value) }.joined(separator: ",")

        if appending, let existing = try? String(contentsOf: url, encoding: .utf8), !existing.isEmpty {
            let updated = existing.hasSuffix("\n") ? existing + row + "\n" : existing + "\n" + row + "\n"
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try (header + "\n" + row + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Imports values from an FDF file written by this app or another reader.
    @discardableResult
    static func importFDF(from url: URL, into document: PDFDocument) throws -> Int {
        let text = try String(contentsOf: url, encoding: .isoLatin1)
        var imported: [String: String] = [:]

        // Entries look like: << /T (name) /V (value) >>
        let pattern = #"/T\s*\(((?:\\.|[^\\()])*)\)\s*/V\s*\(((?:\\.|[^\\()])*)\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text)
            else { continue }
            imported[unescape(String(text[nameRange]))] = unescape(String(text[valueRange]))
        }

        var applied = 0
        for field in fields(in: document) {
            guard let name = field.fieldName, let value = imported[name] else { continue }
            switch field.widgetControlType {
            case .radioButtonControl, .checkBoxControl:
                field.buttonWidgetState = value == "On" ? .onState : .offState
            default:
                field.widgetStringValue = value
            }
            applied += 1
        }
        return applied
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func csvEscape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Scans a PDF for JavaScript actions (Foxit 2026.1 "Action Inspector").
enum ActionInspector {
    struct Finding {
        let where_: String
        let detail: String
    }

    static func scan(_ document: PDFDocument) -> [Finding] {
        var findings: [Finding] = []

        // Document-level JavaScript lives in the raw file; a substring scan is enough to warn.
        if let data = document.dataRepresentation(),
           let text = String(data: data, encoding: .isoLatin1)
        {
            for marker in ["/JavaScript", "/JS", "/OpenAction", "/AA", "/Launch", "/SubmitForm", "/EmbeddedFile"] {
                let count = text.components(separatedBy: marker).count - 1
                if count > 0 {
                    findings.append(Finding(
                        where_: "Document",
                        detail: "\(count) occurrence\(count == 1 ? "" : "s") of \(marker)"
                    ))
                }
            }
        }

        // Link annotations whose action is not a simple destination.
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for annotation in page.annotations where annotation.isLink {
                if let action = annotation.action, !(action is PDFActionGoTo) {
                    findings.append(Finding(
                        where_: "Page \(i + 1)",
                        detail: "Link runs \(String(describing: type(of: action)))"
                    ))
                }
            }
        }
        return findings
    }
}

import AppKit
import PDFKit

/// Comment import/export: XFDF and FDF interchange, highlighted-text extraction,
/// and a printable comment summary.
enum CommentExchange {

    struct Entry {
        let annotation: PDFAnnotation
        let pageIndex: Int
    }

    static func allComments(in document: PDFDocument) -> [Entry] {
        (0..<document.pageCount).flatMap { i -> [Entry] in
            guard let page = document.page(at: i) else { return [] }
            return page.annotations
                .filter { !$0.isLink && !$0.isWidget }
                .map { Entry(annotation: $0, pageIndex: i) }
        }
    }

    // MARK: - XFDF

    static func exportXFDF(_ entries: [Entry], documentURL: URL?, to url: URL) throws {
        var body = ""
        for entry in entries {
            let a = entry.annotation
            let meta = a.reviewMeta
            let rect = a.bounds
            let attributes = [
                "page=\"\(entry.pageIndex)\"",
                "rect=\"\(rect.minX),\(rect.minY),\(rect.maxX),\(rect.maxY)\"",
                "title=\"\(escape(a.userName ?? ""))\"",
                "subject=\"\(escape(a.displayKind))\"",
                "date=\"\(iso(a.modificationDate ?? Date()))\"",
                "color=\"\(hex(a.color))\"",
                "state=\"\(meta.status.rawValue)\"",
            ].joined(separator: " ")
            let subtype = (a.type ?? "text").lowercased()
            body += "  <\(subtype) \(attributes)>\n"
            body += "    <contents>\(escape(a.contents ?? ""))</contents>\n"
            for reply in meta.replies {
                body += "    <reply title=\"\(escape(reply.author))\" date=\"\(iso(reply.date))\">\(escape(reply.text))</reply>\n"
            }
            body += "  </\(subtype)>\n"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
        <annots>
        \(body)</annots>
        <f href="\(escape(documentURL?.lastPathComponent ?? ""))"/>
        </xfdf>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Imports annotations from an XFDF file produced by this app or another PDF reader.
    @discardableResult
    static func importXFDF(from url: URL, into document: PDFDocument) throws -> Int {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let delegate = XFDFParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else { throw CocoaError(.fileReadCorruptFile) }

        var added = 0
        for item in delegate.items {
            guard item.pageIndex >= 0, item.pageIndex < document.pageCount,
                  let page = document.page(at: item.pageIndex)
            else { continue }
            let subtype: PDFAnnotationSubtype
            switch item.subtype {
            case "highlight": subtype = .highlight
            case "underline": subtype = .underline
            case "strikeout": subtype = .strikeOut
            case "square": subtype = .square
            case "circle": subtype = .circle
            case "freetext": subtype = .freeText
            case "ink": subtype = .ink
            default: subtype = .text
            }
            let annotation = PDFAnnotation(bounds: item.rect, forType: subtype, withProperties: nil)
            annotation.contents = item.contents
            annotation.userName = item.title
            if let color = item.color { annotation.color = color }
            var meta = CommentMeta()
            meta.status = CommentMeta.Status(rawValue: item.state) ?? .none
            meta.replies = item.replies.map {
                CommentMeta.Reply(author: $0.author, text: $0.text, date: Date())
            }
            annotation.reviewMeta = meta
            page.addAnnotation(annotation)
            added += 1
        }
        return added
    }

    // MARK: - FDF

    /// Minimal FDF wrapper. FDF is a PDF-syntax container; readers use it to carry annotations.
    static func exportFDF(_ entries: [Entry], documentURL: URL?, to url: URL) throws {
        var annots = ""
        for entry in entries {
            let a = entry.annotation
            let r = a.bounds
            annots += "<< /Type /Annot /Subtype /\(a.type ?? "Text") /Page \(entry.pageIndex) "
            annots += "/Rect [\(fmt(r.minX)) \(fmt(r.minY)) \(fmt(r.maxX)) \(fmt(r.maxY))] "
            annots += "/Contents (\(pdfString(a.contents ?? ""))) "
            annots += "/T (\(pdfString(a.userName ?? ""))) "
            annots += "/Subj (\(pdfString(a.displayKind))) >>\n"
        }
        let fdf = """
        %FDF-1.2
        1 0 obj
        << /FDF << /Annots [
        \(annots)] /F (\(pdfString(documentURL?.lastPathComponent ?? ""))) >> >>
        endobj
        trailer
        << /Root 1 0 R >>
        %%EOF
        """
        try fdf.write(to: url, atomically: true, encoding: .isoLatin1)
    }

    // MARK: - Highlighted text

    static func highlightedText(in document: PDFDocument) -> [(page: Int, text: String)] {
        var results: [(Int, String)] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for annotation in page.annotations where annotation.type == "Highlight" {
                let selection = page.selection(for: annotation.bounds)
                let text = (selection?.string ?? annotation.contents ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { results.append((i + 1, text)) }
            }
        }
        return results
    }

    static func exportHighlightedText(_ document: PDFDocument, to url: URL, asCSV: Bool) throws {
        let rows = highlightedText(in: document)
        let content: String
        if asCSV {
            let body = rows.map { "\($0.page),\"\($0.text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            content = (["Page,Highlighted Text"] + body).joined(separator: "\n")
        } else {
            content = rows.map { "p.\($0.page): \($0.text)" }.joined(separator: "\n")
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Summary

    enum SummarySort: String, CaseIterable, Identifiable {
        case page = "Page", type = "Type", author = "Author", date = "Date"
        var id: String { rawValue }
    }

    /// Builds a standalone PDF listing every comment.
    static func summaryPDF(
        for document: PDFDocument,
        sortedBy sort: SummarySort,
        fontSize: CGFloat = 11,
        title: String
    ) -> PDFDocument? {
        var entries = allComments(in: document)
        switch sort {
        case .page: entries.sort { $0.pageIndex < $1.pageIndex }
        case .type: entries.sort { $0.annotation.displayKind < $1.annotation.displayKind }
        case .author: entries.sort { ($0.annotation.userName ?? "") < ($1.annotation.userName ?? "") }
        case .date:
            entries.sort {
                ($0.annotation.modificationDate ?? .distantPast) < ($1.annotation.modificationDate ?? .distantPast)
            }
        }

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "\(title)\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: fontSize + 7),
        ]))
        text.append(NSAttributedString(string: "\(entries.count) comments · sorted by \(sort.rawValue)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        for entry in entries {
            let a = entry.annotation
            let meta = a.reviewMeta
            var header = "Page \(entry.pageIndex + 1) · \(a.displayKind)"
            if let author = a.userName, !author.isEmpty { header += " · \(author)" }
            if let date = a.modificationDate { header += " · \(formatter.string(from: date))" }
            if meta.status != .none { header += " · [\(meta.status.rawValue)]" }
            text.append(NSAttributedString(string: header + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: fontSize),
            ]))
            let body = (a.contents?.isEmpty == false ? a.contents! : "(no note)")
            text.append(NSAttributedString(string: body + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
            ]))
            for reply in meta.replies {
                text.append(NSAttributedString(string: "    ↳ \(reply.author): \(reply.text)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize - 1),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            text.append(NSAttributedString(string: "\n"))
        }

        return renderPDF(from: text)
    }

    /// Lays out attributed text across US-Letter pages and returns it as a PDF.
    static func renderPDF(from text: NSAttributedString, pageSize: CGSize = CGSize(width: 612, height: 792)) -> PDFDocument? {
        let margin: CGFloat = 54
        let textRect = CGRect(
            x: margin, y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var start = 0
        let total = text.length
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length <= 0 { break }
            start += visible.length
        } while start < total
        ctx.closePDF()

        return PDFDocument(data: data as Data)
    }

    // MARK: - Helpers

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    private static func pdfString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

/// Parses the subset of XFDF this app writes (and what common readers emit).
private final class XFDFParserDelegate: NSObject, XMLParserDelegate {
    struct Reply { let author: String; let text: String }
    struct Item {
        var subtype = ""
        var pageIndex = -1
        var rect: CGRect = .zero
        var contents = ""
        var title = ""
        var state = "None"
        var color: NSColor?
        var replies: [Reply] = []
    }

    private(set) var items: [Item] = []
    private var current: Item?
    private var buffer = ""
    private var replyAuthor: String?

    private static let known: Set<String> = [
        "highlight", "underline", "strikeout", "squiggly", "square", "circle",
        "line", "polygon", "polyline", "freetext", "ink", "text", "stamp", "caret",
    ]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        let name = elementName.lowercased()
        if Self.known.contains(name) {
            var item = Item()
            item.subtype = name
            item.pageIndex = Int(attributes["page"] ?? "") ?? -1
            if let rect = attributes["rect"] {
                let parts = rect.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 4 {
                    item.rect = CGRect(x: parts[0], y: parts[1], width: parts[2] - parts[0], height: parts[3] - parts[1])
                }
            }
            item.title = attributes["title"] ?? ""
            item.state = attributes["state"] ?? "None"
            if let hex = attributes["color"] { item.color = NSColor(hex: hex) }
            current = item
        } else if name == "reply" {
            replyAuthor = attributes["title"] ?? ""
            buffer = ""
        } else if name == "contents" {
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "contents" {
            current?.contents = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
        } else if name == "reply" {
            current?.replies.append(Reply(
                author: replyAuthor ?? "",
                text: buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            buffer = ""
            replyAuthor = nil
        } else if Self.known.contains(name), let item = current {
            items.append(item)
            current = nil
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

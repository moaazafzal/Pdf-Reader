import Foundation
import PDFKit

/// Exports PDF text to a Word .docx file (text-level conversion: paragraphs per line,
/// page breaks preserved; layout/images are not converted).
enum DocxExporter {

    static func export(_ document: PDFDocument, to url: URL) throws {
        var pages: [String] = []
        for i in 0..<document.pageCount {
            pages.append(document.page(at: i)?.string ?? "")
        }
        let docXML = documentXML(pages: pages)

        var zip = ZipWriter()
        zip.addFile(path: "[Content_Types].xml", text: contentTypesXML)
        zip.addFile(path: "_rels/.rels", text: relsXML)
        zip.addFile(path: "word/document.xml", text: docXML)
        try zip.data().write(to: url)
    }

    // MARK: - OOXML parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static func documentXML(pages: [String]) -> String {
        var body = ""
        for (i, pageText) in pages.enumerated() {
            let lines = pageText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    body += "<w:p/>"
                } else {
                    body += "<w:p><w:r><w:t xml:space=\"preserve\">\(escapeXML(trimmed))</w:t></w:r></w:p>"
                }
            }
            if i < pages.count - 1 {
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>\(body)<w:sectPr/></w:body>
        </w:document>
        """
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Minimal ZIP archive writer (stored entries, no compression).
struct ZipWriter {
    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var out = Data()
    private var entries: [Entry] = []

    mutating func addFile(path: String, text: String) {
        addFile(path: path, data: Data(text.utf8))
    }

    mutating func addFile(path: String, data: Data) {
        let crc = ZipWriter.crc32(data)
        let offset = UInt32(out.count)
        let nameBytes = Data(path.utf8)

        // Local file header
        out.append(le32(0x0403_4B50))
        out.append(le16(20))          // version needed
        out.append(le16(0))           // flags
        out.append(le16(0))           // method: stored
        out.append(le16(0))           // mod time
        out.append(le16(0x21))        // mod date (valid dummy: 1980-01-01)
        out.append(le32(crc))
        out.append(le32(UInt32(data.count)))  // compressed size
        out.append(le32(UInt32(data.count)))  // uncompressed size
        out.append(le16(UInt16(nameBytes.count)))
        out.append(le16(0))           // extra length
        out.append(nameBytes)
        out.append(data)

        entries.append(Entry(path: path, data: data, crc: crc, offset: offset))
    }

    func data() -> Data {
        var result = out
        let centralStart = UInt32(result.count)

        for entry in entries {
            let nameBytes = Data(entry.path.utf8)
            result.append(le32(0x0201_4B50))
            result.append(le16(20))   // version made by
            result.append(le16(20))   // version needed
            result.append(le16(0))    // flags
            result.append(le16(0))    // method
            result.append(le16(0))    // mod time
            result.append(le16(0x21)) // mod date
            result.append(le32(entry.crc))
            result.append(le32(UInt32(entry.data.count)))
            result.append(le32(UInt32(entry.data.count)))
            result.append(le16(UInt16(nameBytes.count)))
            result.append(le16(0))    // extra
            result.append(le16(0))    // comment
            result.append(le16(0))    // disk number
            result.append(le16(0))    // internal attrs
            result.append(le32(0))    // external attrs
            result.append(le32(entry.offset))
            result.append(nameBytes)
        }

        let centralSize = UInt32(result.count) - centralStart
        result.append(le32(0x0605_4B50))
        result.append(le16(0))        // disk
        result.append(le16(0))        // central dir disk
        result.append(le16(UInt16(entries.count)))
        result.append(le16(UInt16(entries.count)))
        result.append(le32(centralSize))
        result.append(le32(centralStart))
        result.append(le16(0))        // comment length
        return result
    }

    // MARK: - Helpers

    private func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }

    private func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

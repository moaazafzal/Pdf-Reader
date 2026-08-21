import PDFKit
import SwiftUI
import UniformTypeIdentifiers

final class PDFFileDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    @Published var pdf: PDFDocument

    init() {
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        pdf = doc
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let doc = PDFDocument(data: data)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pdf = doc
    }

    func snapshot(contentType: UTType) throws -> Data {
        // Placed signatures/images live as interactive annotations until save,
        // when they become real page content (so they survive in every reader).
        PDFOperations.burnImageStamps(in: pdf)
        guard let data = pdf.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    /// Undo support for whole-document operations (merge, page organize, redact, edit text):
    /// call with the PDF's data captured BEFORE the operation. Undo restores that data,
    /// redo restores the post-operation state. Also marks the document dirty for autosave.
    func registerContentUndo(_ undoManager: UndoManager?, actionName: String, previousData: Data?) {
        guard let previousData else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            let currentData = target.pdf.dataRepresentation()
            guard let restored = PDFDocument(data: previousData) else { return }
            target.objectWillChange.send()
            target.pdf = restored
            ThumbnailCache.shared.invalidate()
            target.registerContentUndo(undoManager, actionName: actionName, previousData: currentData)
        }
        undoManager?.setActionName(actionName)
    }
}

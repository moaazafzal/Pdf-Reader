import AppKit
import Combine
import PDFKit
import SwiftUI

@MainActor
final class DocViewModel: ObservableObject {
    @Published var tool: Tool = .select
    @Published var style = AnnotationStyle()
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var searchText: String = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var currentPageIndex: Int = 0
    @Published var pageCount: Int = 0
    @Published var scaleFactor: CGFloat = 1
    @Published var sidebarTab: SidebarTab = .pages
    @Published var showOrganizer = false
    @Published var showSignatureManager = false
    @Published var annotationsVersion: Int = 0  // bump to refresh annotation list
    @Published var isAutoScrolling = false
    @Published var visualMode: AnnotatingPDFView.VisualMode = .standard {
        didSet { (pdfView as? AnnotatingPDFView)?.visualMode = visualMode }
    }
    let speech = ReadOutLoud()

    /// Text prompt state for text-box / note tools.
    @Published var pendingTextRequest: PendingTextRequest?

    /// Applies an in-place Edit Text commit: (page, line bounds, new text, font, color).
    /// Set by ContentView so the burn-in gets document-level undo registration.
    var editTextHandler: ((PDFPage, CGRect, String, NSFont, NSColor) -> Void)?

    /// Shows a transient status message (set by ContentView).
    var flashHandler: ((String) -> Void)?

    weak var pdfView: PDFView?

    enum SidebarTab: String, CaseIterable, Identifiable {
        case pages = "Pages"
        case outline = "Outline"
        case annotations = "Annotations"
        case search = "Search"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .pages: return "square.grid.2x2"
            case .outline: return "list.bullet.indent"
            case .annotations: return "text.bubble"
            case .search: return "magnifyingglass"
            }
        }
    }

    struct PendingTextRequest: Identifiable {
        let id = UUID()
        let page: PDFPage
        let point: CGPoint
        let kind: Kind
        enum Kind { case textBox, note }
        /// Existing annotation being edited (nil when creating).
        var existing: PDFAnnotation?
    }


    func runSearch(in document: PDFDocument?) {
        guard let document, !searchText.isEmpty else {
            searchResults = []
            return
        }
        searchResults = document.findString(searchText, withOptions: .caseInsensitive)
    }

    func goTo(selection: PDFSelection) {
        guard let pdfView else { return }
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation else { return }
        if let view = pdfView as? AnnotatingPDFView {
            view.remove(annotation)  // undoable
        } else if let page = annotation.page {
            page.removeAnnotation(annotation)
            selectedAnnotation = nil
            annotationsVersion += 1
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        }
    }
}

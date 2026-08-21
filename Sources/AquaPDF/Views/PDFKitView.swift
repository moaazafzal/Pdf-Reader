import PDFKit
import SwiftUI

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    func makeNSView(context: Context) -> AnnotatingPDFView {
        let view = AnnotatingPDFView()
        view.viewModel = viewModel
        if viewModel.pageCount != document.pageCount {
            DispatchQueue.main.async { viewModel.pageCount = document.pageCount }
        }
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        viewModel.pdfView = view
        viewModel.pageCount = document.pageCount

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ view: AnnotatingPDFView, context: Context) {
        if view.document !== document {
            view.document = document
            // Document swapped (e.g. undo of a whole-document operation) — old selection is stale.
            DispatchQueue.main.async {
                viewModel.selectedAnnotation = nil
                viewModel.pageCount = document.pageCount
            }
        }
        view.viewModel = viewModel
        if context.coordinator.lastTool != viewModel.tool {
            context.coordinator.lastTool = viewModel.tool
            view.toolDidChange()  // commits any in-place text editor
            view.needsDisplay = true
        }
        // Only repaint when the selection actually changed. Redrawing on every
        // SwiftUI update forced a full PDFKit tile re-render and pegged the CPU.
        let selection = viewModel.selectedAnnotation
        if context.coordinator.lastSelection !== selection {
            context.coordinator.lastSelection = selection
            view.needsDisplay = true
        }

        // Markup and drawing tools need our drag handling; select mode keeps native text selection.
        switch viewModel.tool {
        case .signature, .imageStamp:
            break  // pendingStampImage set by ContentView
        default:
            view.pendingStampImage = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    @MainActor
    final class Coordinator: NSObject {
        let viewModel: DocViewModel
        var lastTool: Tool = .select
        weak var lastSelection: PDFAnnotation?
        init(viewModel: DocViewModel) { self.viewModel = viewModel }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView,
                  let page = view.currentPage,
                  let doc = view.document
            else { return }
            let index = doc.index(for: page)
            if viewModel.currentPageIndex != index { viewModel.currentPageIndex = index }
        }

        @objc func scaleChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            // Coalesce tiny changes: scrolling emits a stream of scale notifications.
            if abs(viewModel.scaleFactor - view.scaleFactor) > 0.001 {
                viewModel.scaleFactor = view.scaleFactor
            }
        }
    }
}

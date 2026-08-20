import PDFKit
import SwiftUI

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    func makeNSView(context: Context) -> AnnotatingPDFView {
        let view = AnnotatingPDFView()
        view.viewModel = viewModel
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
        }
        view.setNeedsDisplay(view.bounds)  // keep selection handles in sync

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
        init(viewModel: DocViewModel) { self.viewModel = viewModel }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView,
                  let page = view.currentPage,
                  let doc = view.document
            else { return }
            viewModel.currentPageIndex = doc.index(for: page)
        }

        @objc func scaleChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            viewModel.scaleFactor = view.scaleFactor
        }
    }
}

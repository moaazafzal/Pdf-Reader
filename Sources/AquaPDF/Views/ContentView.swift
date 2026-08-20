import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var document: PDFFileDocument
    @StateObject private var viewModel = DocViewModel()
    @State private var showInspector = true
    @State private var passwordPrompt = false
    @State private var passwordDraft = ""
    @State private var confirmRedactions = false
    @State private var busyMessage: String?
    @State private var statusMessage: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            RibbonView(viewModel: viewModel, actions: ribbonActions)
            mainSplit
            statusBar
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(viewModel: viewModel)
                .inspectorColumnWidth(min: 220, ideal: 250, max: 320)
        }
        .sheet(item: $viewModel.pendingTextRequest) { request in
            TextPromptSheet(request: request, viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingEditTextRequest) { request in
            EditTextSheet(request: request, viewModel: viewModel, document: document)
        }
        .sheet(isPresented: $viewModel.showSignatureManager) {
            SignatureManagerView { image in
                (viewModel.pdfView as? AnnotatingPDFView)?.pendingStampImage = image
                viewModel.tool = .signature
            }
        }
        .sheet(isPresented: $viewModel.showOrganizer) {
            PageOrganizerView(document: document.pdf, viewModel: viewModel) { before in
                document.registerContentUndo(undoManager, actionName: "Organize Pages", previousData: before)
                document.objectWillChange.send()
                viewModel.pageCount = document.pdf.pageCount
            }
        }
        .alert("Set Password", isPresented: $passwordPrompt) {
            SecureField("Password", text: $passwordDraft)
            Button("Save Protected Copy…") { saveProtectedCopy() }
            Button("Cancel", role: .cancel) { passwordDraft = "" }
        } message: {
            Text("Saves an encrypted copy of this PDF. The original file is not changed.")
        }
        .alert("Apply Redactions?", isPresented: $confirmRedactions) {
            Button("Apply", role: .destructive) { applyRedactions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pages with redaction marks are converted to 300 dpi images with the marked areas removed. Text and graphics under the marks are permanently destroyed and the pages lose selectable text (run OCR afterwards if needed). This cannot be undone.")
        }
        .onChange(of: viewModel.tool) { _, newTool in
            if newTool == .imageStamp {
                pickStampImage()
            } else if newTool == .signature,
                      (viewModel.pdfView as? AnnotatingPDFView)?.pendingStampImage == nil {
                viewModel.showSignatureManager = true
            }
        }
    }

    private var mainSplit: some View {
        NavigationSplitView {
            SidebarView(document: document.pdf, viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            PDFKitView(document: document.pdf, viewModel: viewModel)
                .overlay(alignment: .bottom) {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if let busyMessage {
                        ZStack {
                            Color.black.opacity(0.25)
                            VStack(spacing: 10) {
                                ProgressView()
                                Text(busyMessage)
                            }
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text("Page \(viewModel.currentPageIndex + 1) of \(viewModel.pageCount)")
            Spacer()
            Text("\(Int(viewModel.scaleFactor * 100))%")
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Ribbon wiring

    private var ribbonActions: RibbonActions {
        RibbonActions(
            zoomIn: { viewModel.pdfView?.zoomIn(nil) },
            zoomOut: { viewModel.pdfView?.zoomOut(nil) },
            fitWidth: { viewModel.pdfView?.autoScales = true },
            actualSize: { viewModel.pdfView?.scaleFactor = 1 },
            previousPage: { viewModel.pdfView?.goToPreviousPage(nil) },
            nextPage: { viewModel.pdfView?.goToNextPage(nil) },
            addImage: { viewModel.tool = .imageStamp },
            organizer: { viewModel.showOrganizer = true },
            signatureManager: { viewModel.showSignatureManager = true },
            merge: { mergePDFs() },
            split: { splitPDF() },
            compress: { saveCompressedCopy() },
            protect: { passwordPrompt = true },
            flatten: { saveFlattenedCopy() },
            applyRedactions: { confirmRedactions = true },
            ocrSearchable: { runOCRSearchable() },
            ocrText: { runOCRText() },
            exportDocx: { exportDocx() },
            exportImages: { exportImages() },
            exportText: { exportText() },
            toggleInspector: { showInspector.toggle() },
            displayMode: { viewModel.pdfView?.displayMode ?? .singlePageContinuous },
            setDisplayMode: { mode in
                viewModel.pdfView?.displayMode = mode
                viewModel.objectWillChange.send()  // refresh ribbon active state
            }
        )
    }

    // MARK: - Actions

    private func flash(_ message: String) {
        withAnimation { statusMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { statusMessage = nil }
        }
    }

    private func mergePDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let before = document.pdf.dataRepresentation()
        PDFOperations.merge(urls: panel.urls, into: document.pdf)
        document.registerContentUndo(undoManager, actionName: "Merge PDFs", previousData: before)
        document.objectWillChange.send()
        viewModel.pageCount = document.pdf.pageCount
        flash("Merged \(panel.urls.count) file(s) — \(document.pdf.pageCount) pages total")
    }

    private func splitPDF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder for the single-page PDFs"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let n = try PDFOperations.splitIntoSinglePages(document.pdf, baseName: baseName(), directory: dir)
            flash("Wrote \(n) single-page PDFs")
        } catch {
            flash("Split failed: \(error.localizedDescription)")
        }
    }

    private func saveCompressedCopy() {
        guard let url = savePanel(suggested: baseName() + "-compressed.pdf") else { return }
        do {
            try PDFOperations.writeCompressed(document.pdf, to: url)
            flash("Compressed copy saved")
        } catch {
            flash("Compression failed: \(error.localizedDescription)")
        }
    }

    private func saveProtectedCopy() {
        defer { passwordDraft = "" }
        let password = passwordDraft
        guard !password.isEmpty,
              let url = savePanel(suggested: baseName() + "-protected.pdf") else { return }
        do {
            try PDFOperations.writeProtected(document.pdf, to: url, password: password)
            flash("Encrypted copy saved")
        } catch {
            flash("Encryption failed: \(error.localizedDescription)")
        }
    }

    private func saveFlattenedCopy() {
        guard let url = savePanel(suggested: baseName() + "-flattened.pdf") else { return }
        do {
            try PDFOperations.writeFlattened(document.pdf, to: url)
            flash("Flattened copy saved")
        } catch {
            flash("Flatten failed: \(error.localizedDescription)")
        }
    }

    private func runOCRSearchable() {
        guard let url = savePanel(suggested: baseName() + "-searchable.pdf") else { return }
        busyMessage = "Running OCR…"
        let pdf = document.pdf
        Task.detached(priority: .userInitiated) {
            do {
                let out = try OCRService.makeSearchablePDF(from: pdf)
                let ok = out.write(to: url)
                await MainActor.run {
                    busyMessage = nil
                    flash(ok ? "Searchable PDF saved" : "OCR write failed")
                }
            } catch {
                await MainActor.run {
                    busyMessage = nil
                    flash("OCR failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runOCRText() {
        guard let url = savePanel(suggested: baseName() + "-ocr.txt", types: [.plainText]) else { return }
        busyMessage = "Running OCR…"
        let pdf = document.pdf
        Task.detached(priority: .userInitiated) {
            do {
                let text = try OCRService.recognizeText(in: pdf)
                try text.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    busyMessage = nil
                    flash("Recognized text saved")
                }
            } catch {
                await MainActor.run {
                    busyMessage = nil
                    flash("OCR failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func exportImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder for the PNG files"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let n = try PDFOperations.exportPagesAsImages(document.pdf, to: dir, baseName: baseName())
            flash("Exported \(n) PNG file(s)")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    private func exportText() {
        guard let url = savePanel(suggested: baseName() + ".txt", types: [.plainText]) else { return }
        do {
            try PDFOperations.exportText(document.pdf, to: url)
            flash("Text exported")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    private func exportDocx() {
        let docxType = UTType(filenameExtension: "docx") ?? .data
        guard let url = savePanel(suggested: baseName() + ".docx", types: [docxType]) else { return }
        do {
            try DocxExporter.export(document.pdf, to: url)
            flash("Word document exported (text-level conversion)")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    private func applyRedactions() {
        let before = document.pdf.dataRepresentation()
        let n = PDFOperations.applyRedactions(in: document.pdf)
        if n == 0 {
            flash("No redaction marks found — use the Redact tool to mark areas first")
            return
        }
        document.registerContentUndo(undoManager, actionName: "Apply Redactions", previousData: before)
        document.objectWillChange.send()
        viewModel.selectedAnnotation = nil
        viewModel.annotationsVersion += 1
        viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
        flash("Redacted \(n) page(s) — content under marks destroyed")
    }

    private func pickStampImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else {
            viewModel.tool = .select
            return
        }
        (viewModel.pdfView as? AnnotatingPDFView)?.pendingStampImage = image
        flash("Click the page to place the image")
    }

    private func savePanel(suggested: String, types: [UTType] = [.pdf]) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = suggested
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func baseName() -> String {
        document.pdf.documentURL?.deletingPathExtension().lastPathComponent ?? "document"
    }
}

// MARK: - Text prompt sheet (text box / note tools)

struct TextPromptSheet: View {
    let request: DocViewModel.PendingTextRequest
    @ObservedObject var viewModel: DocViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.kind == .textBox ? "Add Text" : "Add Note")
                .font(.headline)
            TextField("Text", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    addAnnotation()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
            }
        }
        .padding(20)
    }

    private func addAnnotation() {
        let style = viewModel.style
        switch request.kind {
        case .textBox:
            let width: CGFloat = max(120, CGFloat(text.count) * style.fontSize * 0.55)
            let bounds = CGRect(x: request.point.x, y: request.point.y - 20, width: min(width, 420), height: 40)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.systemFont(ofSize: style.fontSize)
            annotation.fontColor = style.color
            annotation.color = .clear
            add(annotation)
        case .note:
            let bounds = CGRect(x: request.point.x - 10, y: request.point.y - 10, width: 20, height: 20)
            let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.contents = text
            annotation.color = style.color
            annotation.iconType = .comment
            add(annotation)
        }
    }

    private func add(_ annotation: PDFAnnotation) {
        if let view = viewModel.pdfView as? AnnotatingPDFView {
            view.insert(annotation, on: request.page)  // undoable
        } else {
            request.page.addAnnotation(annotation)
            viewModel.annotationsVersion += 1
            viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
        }
    }
}

// MARK: - Edit text sheet (Edit Text beta tool)

struct EditTextSheet: View {
    let request: DocViewModel.EditTextRequest
    @ObservedObject var viewModel: DocViewModel
    @ObservedObject var document: PDFFileDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Text (beta)")
                .font(.headline)
            Text("Replaces this line by painting over it and writing new text into the page. Works best on plain, light backgrounds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 360, alignment: .leading)
            TextField("Text", text: $text)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = request.originalText.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func apply() {
        let pageIndex = document.pdf.index(for: request.page)
        guard pageIndex >= 0 else { return }
        let before = document.pdf.dataRepresentation()
        PDFOperations.replaceTextLine(
            in: document.pdf,
            pageIndex: pageIndex,
            lineRect: request.lineBounds,
            newText: text
        )
        document.registerContentUndo(undoManager, actionName: "Edit Text", previousData: before)
        document.objectWillChange.send()
        viewModel.selectedAnnotation = nil
        viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
    }
}

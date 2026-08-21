import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var document: PDFFileDocument
    @StateObject private var viewModel = DocViewModel()
    @State private var showInspector = false
    @State private var busyMessage: String?
    @State private var statusMessage: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.readingMode != .read {
                RibbonView(viewModel: viewModel, actions: ribbonActions)
            }

            switch viewModel.readingMode {
            case .reflow:
                ReflowView(document: document.pdf, viewModel: viewModel)
            case .textViewer:
                TextViewerView(document: document.pdf, viewModel: viewModel)
            case .normal, .read:
                mainArea
            }

            statusBar
        }
        .sheet(item: $viewModel.pendingTextRequest) { request in
            TextPromptSheet(request: request, viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showSignatureManager) {
            SignatureManagerView { image in
                if let view = viewModel.pdfView as? AnnotatingPDFView {
                    view.pendingStampText = nil
                    view.pendingStampImage = image
                }
                viewModel.tool = .signature
            }
        }
        .sheet(isPresented: $viewModel.showStamps) {
            StampPaletteView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showPreferences) {
            PreferencesView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showProperties) {
            DocumentPropertiesView(document: document.pdf)
        }
        .sheet(isPresented: $viewModel.showOrganizer) {
            PageOrganizerView(document: document.pdf, viewModel: viewModel) { before in
                document.registerContentUndo(undoManager, actionName: "Organize Pages", previousData: before)
                document.objectWillChange.send()
                viewModel.pageCount = document.pdf.pageCount
            }
        }
        .onChange(of: viewModel.tool) { newTool in
            if newTool == .imageStamp {
                pickStampImage()
            } else if newTool == .signature,
                      (viewModel.pdfView as? AnnotatingPDFView)?.pendingStampImage == nil {
                viewModel.showSignatureManager = true
            }
        }
        .onAppear { installHandlers() }
    }

    // MARK: - Main area

    private var mainArea: some View {
        HStack(spacing: 0) {
            if viewModel.showSidebar, viewModel.readingMode == .normal {
                SidebarView(document: document.pdf, viewModel: viewModel)
                    .frame(width: 215)
                Divider()
            }
            pdfArea
            if showInspector {
                Divider()
                InspectorView(viewModel: viewModel)
                    .frame(width: 250)
            }
        }
    }

    @ViewBuilder
    private var pdfArea: some View {
        let primary = PDFKitView(document: document.pdf, viewModel: viewModel)
            .overlay(
                Group {
                    if viewModel.showLoupe {
                        LoupeView(viewModel: viewModel)
                            .padding(12)
                    }
                },
                alignment: .topTrailing
            )
            .overlay(
                Group {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .capsuleBackground()
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                },
                alignment: .bottom
            )
            .overlay(
                Group {
                    if let busyMessage {
                        ZStack {
                            Color.black.opacity(0.25)
                            VStack(spacing: 10) {
                                ProgressView()
                                Text(busyMessage)
                            }
                            .padding(24)
                            .panelBackground(cornerRadius: 12)
                        }
                    }
                }
            )

        switch viewModel.splitMode {
        case .none:
            primary
        case .vertical:
            HSplitView {
                primary
                SecondaryPDFView(document: document.pdf)
            }
        case .horizontal:
            VSplitView {
                primary
                SecondaryPDFView(document: document.pdf)
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button { viewModel.pdfView?.goToFirstPage(nil) } label: { Image(systemName: "chevron.up.2") }
                .help("First page")
            Button { viewModel.pdfView?.goToPreviousPage(nil) } label: { Image(systemName: "chevron.up") }
                .help("Previous page")
            Text("\(viewModel.currentPageIndex + 1) / \(viewModel.pageCount)")
                .font(.system(size: 11).monospacedDigit())
            Button { viewModel.pdfView?.goToNextPage(nil) } label: { Image(systemName: "chevron.down") }
                .help("Next page")
            Button { viewModel.pdfView?.goToLastPage(nil) } label: { Image(systemName: "chevron.down.2") }
                .help("Last page")

            Divider().frame(height: 12)

            Button { viewModel.pdfView?.goBack(nil) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help("Previous view")
            Button { viewModel.pdfView?.goForward(nil) } label: { Image(systemName: "arrowshape.turn.up.right") }
                .help("Next view")

            Spacer()

            if viewModel.readingMode == .read {
                Button("Exit Read Mode") { viewModel.readingMode = .normal }
                    .controlSize(.small)
            }

            Button { viewModel.pdfView?.zoomOut(nil) } label: { Image(systemName: "minus") }
            Slider(
                value: Binding(
                    get: { min(max(Double(viewModel.scaleFactor), 0.25), 5) },
                    set: { newValue in
                        viewModel.pdfView?.autoScales = false
                        viewModel.pdfView?.scaleFactor = CGFloat(newValue)
                        viewModel.scaleFactor = CGFloat(newValue)
                    }
                ),
                in: 0.25...5
            )
            .frame(width: 110)
            Button { viewModel.pdfView?.zoomIn(nil) } label: { Image(systemName: "plus") }
            Text("\(Int(viewModel.scaleFactor * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.from(.windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Handlers

    private func installHandlers() {
        viewModel.flashHandler = { flash($0) }
        viewModel.editTextHandler = { page, lineRect, newText, font, color in
            let pageIndex = document.pdf.index(for: page)
            guard pageIndex >= 0 else { return }
            let before = document.pdf.dataRepresentation()
            PDFOperations.replaceTextLine(
                in: document.pdf,
                pageIndex: pageIndex,
                lineRect: lineRect,
                newText: newText,
                font: font,
                textColor: color
            )
            document.registerContentUndo(undoManager, actionName: "Edit Text", previousData: before)
            document.objectWillChange.send()
            viewModel.selectedAnnotation = nil
            viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
            flash("Text replaced — ⌘Z to undo")
        }
    }

    // MARK: - Ribbon wiring

    private var ribbonActions: RibbonActions {
        RibbonActions(
            open: { NSDocumentController.shared.openDocument(nil) },
            save: { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) },
            saveAs: { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) },
            print: { printDocument() },
            batchPrint: { batchPrint() },
            email: { emailDocument() },
            zoomIn: { viewModel.pdfView?.zoomIn(nil) },
            zoomOut: { viewModel.pdfView?.zoomOut(nil) },
            fitWidth: {
                viewModel.pdfView?.autoScales = true
                viewModel.pdfView?.displayMode = .singlePageContinuous
            },
            fitPage: { fitPage() },
            actualSize: {
                viewModel.pdfView?.autoScales = false
                viewModel.pdfView?.scaleFactor = 1
            },
            previousPage: { viewModel.pdfView?.goToPreviousPage(nil) },
            nextPage: { viewModel.pdfView?.goToNextPage(nil) },
            rotateView: { degrees in rotateView(degrees) },
            addImage: { viewModel.tool = .imageStamp },
            organizer: { viewModel.showOrganizer = true },
            signatureManager: { viewModel.showSignatureManager = true },
            merge: { mergePDFs() },
            split: { splitPDF() },
            compress: { saveCompressedCopy() },
            protect: { saveProtectedCopy() },
            flatten: { saveFlattenedCopy() },
            applyRedactions: { applyRedactions() },
            inspectActions: { inspectActions() },
            ocrSearchable: { runOCRSearchable() },
            ocrText: { runOCRText() },
            exportDocx: { exportDocx() },
            exportImages: { exportImages() },
            exportText: { exportText() },
            toggleInspector: { showInspector.toggle() },
            displayMode: { viewModel.pdfView?.displayMode ?? .singlePageContinuous },
            setDisplayMode: { mode in
                viewModel.pdfView?.displayMode = mode
                viewModel.objectWillChange.send()
            },
            toggleAutoScroll: {
                guard let view = viewModel.pdfView as? AnnotatingPDFView else { return }
                view.toggleAutoScroll()
                viewModel.isAutoScrolling = view.isAutoScrolling
            },
            toggleFullScreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
            toggleReflow: { viewModel.readingMode = viewModel.readingMode == .reflow ? .normal : .reflow },
            toggleTextViewer: { viewModel.readingMode = viewModel.readingMode == .textViewer ? .normal : .textViewer },
            toggleReadMode: { viewModel.readingMode = viewModel.readingMode == .read ? .normal : .read },
            toggleReverseView: { toggleReverseView() },
            readPage: { viewModel.speech.readPage(viewModel.pdfView?.currentPage) },
            readFrom: { viewModel.speech.readFrom(page: viewModel.currentPageIndex, in: document.pdf) },
            readPause: { viewModel.speech.togglePause() },
            readStop: { viewModel.speech.stop() },
            wordCount: { showWordCount() },
            searchAndHighlight: { searchAndHighlight() },
            summarizeComments: { summarizeComments() },
            exportComments: { asFDF in exportComments(asFDF: asFDF) },
            importComments: { importComments() },
            exportHighlights: { asCSV in exportHighlights(asCSV: asCSV) },
            resetForm: { resetForm() },
            importFormData: { importFormData() },
            exportFormData: { exportFormData() },
            exportFormCSV: { exportFormCSV() },
            toggleFieldHighlight: { toggleFieldHighlight() },
            showShortcuts: { showShortcuts() },
            showAbout: { showAbout() },
            makeDefaultReader: { makeDefaultReader() }
        )
    }

    // MARK: - View actions

    private func fitPage() {
        guard let view = viewModel.pdfView, let page = view.currentPage else { return }
        view.autoScales = false
        let pageSize = page.bounds(for: .mediaBox).size
        let available = view.bounds.size
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        view.scaleFactor = min(available.width / pageSize.width, available.height / pageSize.height) * 0.97
    }

    private func rotateView(_ degrees: Int) {
        guard let page = viewModel.pdfView?.currentPage else { return }
        // View-only rotation: applied to the displayed page, not saved unless the user saves.
        page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        viewModel.pdfView?.layoutDocumentView()
        flash("Rotated view \(degrees > 0 ? "right" : "left")")
    }

    private func toggleReverseView() {
        let before = document.pdf.dataRepresentation()
        let count = document.pdf.pageCount
        guard count > 1 else { return }
        // Reverse by repeatedly moving the last page to the front.
        for i in 0..<count {
            guard let page = document.pdf.page(at: count - 1) else { continue }
            document.pdf.removePage(at: count - 1)
            document.pdf.insert(page, at: i)
        }
        document.registerContentUndo(undoManager, actionName: "Reverse View", previousData: before)
        document.objectWillChange.send()
        viewModel.reverseView.toggle()
        flash(viewModel.reverseView ? "Page order reversed" : "Page order restored")
    }

    private func showWordCount() {
        let text = document.pdf.string ?? ""
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        flash("\(words) words · \(text.count) characters · \(document.pdf.pageCount) pages")
    }

    // MARK: - Comment actions

    private func searchAndHighlight() {
        guard let needle = InputPrompt.run(
            title: "Search & Highlight",
            message: "Highlight every occurrence of:",
            defaultValue: viewModel.searchText
        ) else { return }
        guard let view = viewModel.pdfView as? AnnotatingPDFView else { return }
        let count = view.highlightAllMatches(of: needle)
        flash(count == 0 ? "No matches for \"\(needle)\"" : "Highlighted \(count) match(es)")
    }

    private func summarizeComments() {
        guard let summary = CommentExchange.summaryPDF(
            for: document.pdf,
            sortedBy: .page,
            title: "Comment Summary — \(baseName())"
        ) else {
            flash("Could not build the summary")
            return
        }
        guard let url = savePanel(suggested: baseName() + "-comments.pdf") else { return }
        flash(summary.write(to: url) ? "Comment summary saved" : "Could not write the summary")
    }

    private func exportComments(asFDF: Bool) {
        let type = UTType(filenameExtension: asFDF ? "fdf" : "xfdf") ?? .data
        guard let url = savePanel(suggested: baseName() + (asFDF ? ".fdf" : ".xfdf"), types: [type]) else { return }
        let entries = CommentExchange.allComments(in: document.pdf)
        do {
            if asFDF {
                try CommentExchange.exportFDF(entries, documentURL: document.pdf.documentURL, to: url)
            } else {
                try CommentExchange.exportXFDF(entries, documentURL: document.pdf.documentURL, to: url)
            }
            flash("Exported \(entries.count) comment(s)")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    private func importComments() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xfdf") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let before = document.pdf.dataRepresentation()
            let count = try CommentExchange.importXFDF(from: url, into: document.pdf)
            document.registerContentUndo(undoManager, actionName: "Import Comments", previousData: before)
            document.objectWillChange.send()
            viewModel.annotationsVersion += 1
            flash("Imported \(count) comment(s)")
        } catch {
            flash("Import failed: \(error.localizedDescription)")
        }
    }

    private func exportHighlights(asCSV: Bool) {
        let type: UTType = asCSV ? (UTType(filenameExtension: "csv") ?? .commaSeparatedText) : .plainText
        guard let url = savePanel(suggested: baseName() + (asCSV ? "-highlights.csv" : "-highlights.txt"), types: [type])
        else { return }
        do {
            try CommentExchange.exportHighlightedText(document.pdf, to: url, asCSV: asCSV)
            flash("Highlighted text exported")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Form actions

    private func resetForm() {
        let before = document.pdf.dataRepresentation()
        let count = FormOperations.resetForm(in: document.pdf)
        guard count > 0 else { return flash("This document has no form fields") }
        document.registerContentUndo(undoManager, actionName: "Reset Form", previousData: before)
        viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
        flash("Reset \(count) field(s)")
    }

    private func toggleFieldHighlight() {
        viewModel.highlightFormFields.toggle()
        FormOperations.setHighlight(viewModel.highlightFormFields, in: document.pdf)
        viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
    }

    private func exportFormData() {
        guard let url = savePanel(suggested: baseName() + ".fdf", types: [UTType(filenameExtension: "fdf") ?? .data])
        else { return }
        do {
            try FormOperations.exportFDF(document.pdf, to: url)
            flash("Form data exported")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    private func exportFormCSV() {
        guard let url = savePanel(
            suggested: baseName() + "-form.csv",
            types: [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        ) else { return }
        do {
            let exists = FileManager.default.fileExists(atPath: url.path)
            try FormOperations.exportCSV(document.pdf, to: url, appending: exists)
            flash(exists ? "Appended form data to the sheet" : "Form data written to the sheet")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    private func importFormData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fdf") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let before = document.pdf.dataRepresentation()
            let count = try FormOperations.importFDF(from: url, into: document.pdf)
            document.registerContentUndo(undoManager, actionName: "Import Form Data", previousData: before)
            viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
            flash("Filled \(count) field(s)")
        } catch {
            flash("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Protect / help

    private func inspectActions() {
        let findings = ActionInspector.scan(document.pdf)
        let alert = NSAlert()
        alert.messageText = findings.isEmpty ? "No Active Content Found" : "Active Content Found"
        alert.informativeText = findings.isEmpty
            ? "This PDF contains no JavaScript, launch, submit or embedded-file actions."
            : findings.map { "• \($0.where_): \($0.detail)" }.joined(separator: "\n")
        alert.alertStyle = findings.isEmpty ? .informational : .warning
        alert.runModal()
    }

    private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        ⌘O Open      ⌘S Save      ⌘P Print      ⌘D Properties      ⌘, Preferences
        ⌘Z Undo      ⇧⌘Z Redo     ⌘F Find      ⌥Q Command search
        ⌘+ / ⌘− Zoom      ⌘1 Actual size      F11 Full screen
        Delete  Remove the selected annotation
        Return  Finish a polygon / polyline / cloud / measurement
        Esc     Cancel the current shape, editor or AutoScroll
        Double-click text you added  Edit it again
        """
        alert.runModal()
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AquaPDF"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        alert.informativeText = """
        Version \(version)
        A free, native macOS PDF reader and editor built on SwiftUI and Apple PDFKit.
        No subscriptions, no accounts, no paid SDKs.
        """
        alert.runModal()
    }

    private func makeDefaultReader() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        // LSSetDefaultRoleHandlerForContentType works back to macOS 10.10;
        // NSWorkspace.setDefaultApplication is macOS 12+.
        let status = LSSetDefaultRoleHandlerForContentType("com.adobe.pdf" as CFString, .all, bundleID as CFString)
        flash(status == noErr ? "AquaPDF is now the default PDF app" : "Could not change the default app")
    }

    // MARK: - Printing

    private func printDocument() {
        viewModel.pdfView?.print(with: NSPrintInfo.shared, autoRotate: true, pageScaling: .pageScaleDownToFit)
    }

    private func batchPrint() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to print"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var printed = 0
        for url in panel.urls {
            guard let doc = PDFDocument(url: url),
                  let operation = doc.printOperation(
                      for: NSPrintInfo.shared,
                      scalingMode: .pageScaleDownToFit,
                      autoRotate: true
                  )
            else { continue }
            operation.showsPrintPanel = false
            operation.showsProgressPanel = true
            if operation.run() { printed += 1 }
        }
        flash("Printed \(printed) of \(panel.urls.count) document(s)")
    }

    private func emailDocument() {
        guard let url = document.pdf.documentURL else {
            flash("Save the document first, then email it")
            return
        }
        let service = NSSharingService(named: .composeEmail)
        service?.perform(withItems: [url])
    }

    // MARK: - Document actions

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
        ThumbnailCache.shared.invalidate()
        document.registerContentUndo(undoManager, actionName: "Merge PDFs", previousData: before)
        document.objectWillChange.send()
        viewModel.pageCount = document.pdf.pageCount
        flash("Merged \(panel.urls.count) file(s) — \(document.pdf.pageCount) pages total")
    }

    private func splitPDF() {
        guard let dir = chooseFolder(message: "Choose a folder for the single-page PDFs") else { return }
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
        guard let password = InputPrompt.runSecure(
            title: "Protect With Password",
            message: "Saves an encrypted copy of this PDF. The original file is not changed."
        ) else { return }
        guard let url = savePanel(suggested: baseName() + "-protected.pdf") else { return }
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

    private func applyRedactions() {
        guard InputPrompt.confirmDestructive(
            title: "Apply Redactions?",
            message: "Pages with redaction marks are converted to 300 dpi images with the marked areas removed. Text and graphics under the marks are permanently destroyed and the pages lose selectable text (run OCR afterwards if needed).",
            confirmTitle: "Apply"
        ) else { return }
        let before = document.pdf.dataRepresentation()
        let n = PDFOperations.applyRedactions(in: document.pdf)
        ThumbnailCache.shared.invalidate()
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
        guard let dir = chooseFolder(message: "Choose a folder for the PNG files") else { return }
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

    private func pickStampImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else {
            viewModel.tool = .select
            return
        }
        if let view = viewModel.pdfView as? AnnotatingPDFView {
            view.pendingStampText = nil
            view.pendingStampImage = image
        }
        flash("Click the page to place the image")
    }

    // MARK: - Panels

    private func savePanel(suggested: String, types: [UTType] = [.pdf]) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = suggested
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func baseName() -> String {
        document.pdf.documentURL?.deletingPathExtension().lastPathComponent ?? "document"
    }
}

/// Read-only second pane used by the Split view modes.
struct SecondaryPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

// MARK: - Note prompt sheet

struct TextPromptSheet: View {
    let request: DocViewModel.PendingTextRequest
    @ObservedObject var viewModel: DocViewModel
    @Environment(\.presentationMode) private var presentation
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Note")
                .font(.headline)
            TextField("Note", text: $text)
                .lineLimit(8)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    addAnnotation()
                    presentation.wrappedValue.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
            }
        }
        .padding(20)
    }

    private func addAnnotation() {
        let bounds = CGRect(x: request.point.x - 10, y: request.point.y - 10, width: 20, height: 20)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = viewModel.style.color
        annotation.iconType = .comment
        annotation.userName = viewModel.authorName
        if let view = viewModel.pdfView as? AnnotatingPDFView {
            view.insert(annotation, on: request.page)
        } else {
            request.page.addAnnotation(annotation)
            viewModel.annotationsVersion += 1
        }
    }
}

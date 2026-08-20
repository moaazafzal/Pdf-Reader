import AppKit
import PDFKit
import SwiftUI

/// Foxit-style ribbon: tab strip on top, grouped tool buttons below.
struct RibbonView: View {
    @ObservedObject var viewModel: DocViewModel
    let actions: RibbonActions

    @State private var tab: RibbonTab = .home
    @State private var commandQuery = ""
    @State private var showCommandSearch = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            toolStrip
                .frame(height: 78)
            Divider()
        }
        .background(Color.from(.windowBackgroundColor))
        .sheet(isPresented: $showCommandSearch) {
            CommandSearchView(query: $commandQuery, viewModel: viewModel, actions: actions) { newTab in
                tab = newTab
            }
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(RibbonTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.title)
                        .font(.system(size: 12.5, weight: tab == t ? .semibold : .regular))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(tab == t ? Color.accentColor.opacity(0.15) : .clear)
                        )
                        .overlay(
                            Rectangle()
                                .fill(tab == t ? Color.accentColor : .clear)
                                .frame(height: 2)
                            , alignment: .bottom)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                showCommandSearch = true
            } label: {
                Label("Search commands", systemImage: "magnifyingglass")
                    .font(.system(size: 11))
                    
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .keyboardShortcut("q", modifiers: [.option])
            .help("Find a command (⌥Q)")
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Tool strip

    @ViewBuilder
    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                switch tab {
                case .file: fileTab
                case .home: homeTab
                case .comment: commentTab
                case .edit: editTab
                case .organize: organizeTab
                case .convert: convertTab
                case .form: formTab
                case .protect: protectTab
                case .view: viewTab
                case .help: helpTab
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var fileTab: some View {
        RibbonGroup("File") {
            RibbonButton(icon: "folder", title: "Open") { actions.open() }
            RibbonButton(icon: "square.and.arrow.down", title: "Save") { actions.save() }
            RibbonButton(icon: "square.and.arrow.down.on.square", title: "Save As") { actions.saveAs() }
        }
        RibbonGroup("Print") {
            RibbonButton(icon: "printer", title: "Print") { actions.print() }
            RibbonButton(icon: "printer.filled.and.paper", title: "Batch Print") { actions.batchPrint() }
        }
        RibbonGroup("Document") {
            RibbonButton(icon: "info.circle", title: "Properties") { viewModel.showProperties = true }
            RibbonButton(icon: "envelope", title: "Email") { actions.email() }
        }
        RibbonGroup("Settings") {
            RibbonButton(icon: "gearshape", title: "Preferences") { viewModel.showPreferences = true }
        }
    }

    @ViewBuilder private var homeTab: some View {
        RibbonGroup("Tools") {
            toolButton(.hand)
            toolButton(.select)
            toolButton(.snapshot)
        }
        RibbonGroup("Zoom") {
            RibbonButton(icon: "minus.magnifyingglass", title: "Out") { actions.zoomOut() }
            VStack(spacing: 3) {
                Text("\(Int(viewModel.scaleFactor * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                RibbonSmallButton(title: "Fit Width") { actions.fitWidth() }
                RibbonSmallButton(title: "Fit Page") { actions.fitPage() }
            }
            .frame(width: 66)
            RibbonButton(icon: "plus.magnifyingglass", title: "In") { actions.zoomIn() }
            RibbonButton(icon: "1.magnifyingglass", title: "Actual") { actions.actualSize() }
            toolButton(.marqueeZoom, title: "Marquee")
        }
        RibbonGroup("Navigate") {
            RibbonButton(icon: "chevron.up", title: "Previous") { actions.previousPage() }
            VStack(spacing: 2) {
                Text("\(viewModel.currentPageIndex + 1)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text("of \(viewModel.pageCount)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(width: 46)
            RibbonButton(icon: "chevron.down", title: "Next") { actions.nextPage() }
        }
        RibbonGroup("View") {
            RibbonButton(icon: "doc.text.magnifyingglass", title: "Reflow",
                         active: viewModel.readingMode == .reflow) { actions.toggleReflow() }
            RibbonButton(icon: "rotate.left", title: "Rotate L") { actions.rotateView(-90) }
            RibbonButton(icon: "rotate.right", title: "Rotate R") { actions.rotateView(90) }
        }
        RibbonGroup("Text") {
            toolButton(.textBox, title: "Typewriter")
            toolButton(.editText, title: "Edit Text")
            toolButton(.highlight)
        }
        RibbonGroup("Sign") {
            toolButton(.signature, title: "Fill & Sign")
        }
    }

    @ViewBuilder private var commentTab: some View {
        RibbonGroup("Text Markup") {
            toolButton(.highlight)
            toolButton(.underline)
            toolButton(.squiggly)
            toolButton(.strikeout)
            toolButton(.replaceText, title: "Replace")
            toolButton(.insertText, title: "Insert")
        }
        RibbonGroup("Notes") {
            toolButton(.note)
            toolButton(.fileAttachment, title: "File")
            toolButton(.textBox)
            toolButton(.callout)
        }
        RibbonGroup("Drawing") {
            toolButton(.ink, title: "Pencil")
            toolButton(.eraser)
            toolButton(.rectangle)
            toolButton(.ellipse)
            toolButton(.line)
            toolButton(.arrow)
            toolButton(.polygon)
            toolButton(.polyline)
            toolButton(.cloud)
            toolButton(.arc)
            toolButton(.areaHighlight, title: "Area")
        }
        RibbonGroup("Stamp") {
            RibbonButton(icon: "seal", title: "Stamps") { viewModel.showStamps = true }
        }
        RibbonGroup("Measure") {
            toolButton(.measureDistance)
            toolButton(.measurePerimeter)
            toolButton(.measureAreaPolygon, title: "Area")
            toolButton(.measureAreaCircle, title: "Circle")
        }
        RibbonGroup("Manage") {
            RibbonButton(icon: "text.magnifyingglass", title: "Find & Mark") { actions.searchAndHighlight() }
            RibbonButton(icon: "list.bullet.rectangle", title: "Comments") {
                viewModel.sidebarTab = .annotations
                viewModel.showSidebar = true
            }
            RibbonButton(icon: "doc.text", title: "Summarize") { actions.summarizeComments() }
        }
        RibbonGroup("Exchange") {
            Menu {
                Button("Export All Comments (XFDF)…") { actions.exportComments(false) }
                Button("Export All Comments (FDF)…") { actions.exportComments(true) }
                Button("Import Comments…") { actions.importComments() }
                Divider()
                Button("Export Highlighted Text (CSV)…") { actions.exportHighlights(true) }
                Button("Export Highlighted Text (TXT)…") { actions.exportHighlights(false) }
            } label: {
                Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
            }
            .frame(width: 120)
        }
        RibbonGroup("Style") {
            VStack(spacing: 4) {
                ColorPicker("", selection: Binding(
                    get: { Color.from(viewModel.style.color) },
                    set: { viewModel.style.color = NSColor.from($0) }
                ))
                .labelsHidden()
                Text("Color")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            .frame(width: 46)
        }
    }

    @ViewBuilder private var editTab: some View {
        RibbonGroup("Text") {
            toolButton(.editText, title: "Edit Text")
            toolButton(.textBox, title: "Add Text")
        }
        RibbonGroup("Objects") {
            RibbonButton(icon: "photo.badge.plus", title: "Add Image") { actions.addImage() }
            toolButton(.select)
        }
        RibbonGroup("Signature") {
            toolButton(.signature, title: "Place")
            RibbonButton(icon: "signature", title: "Manage") { actions.signatureManager() }
        }
        RibbonGroup("Pages") {
            RibbonButton(icon: "square.grid.3x3", title: "Organize") { actions.organizer() }
        }
    }

    @ViewBuilder private var organizeTab: some View {
        RibbonGroup("Pages") {
            RibbonButton(icon: "square.grid.3x3", title: "Organize") { actions.organizer() }
            RibbonButton(icon: "rotate.right", title: "Rotate") { actions.organizer() }
        }
        RibbonGroup("Combine") {
            RibbonButton(icon: "doc.on.doc", title: "Merge…") { actions.merge() }
            RibbonButton(icon: "square.split.2x1", title: "Split…") { actions.split() }
        }
    }

    @ViewBuilder private var convertTab: some View {
        RibbonGroup("To Office") {
            RibbonButton(icon: "doc.richtext", title: "To Word") { actions.exportDocx() }
        }
        RibbonGroup("To Image / Text") {
            RibbonButton(icon: "photo.on.rectangle", title: "To PNG") { actions.exportImages() }
            RibbonButton(icon: "doc.plaintext", title: "To Text") { actions.exportText() }
        }
        RibbonGroup("OCR") {
            RibbonButton(icon: "text.viewfinder", title: "Searchable") { actions.ocrSearchable() }
            RibbonButton(icon: "text.magnifyingglass", title: "OCR Text") { actions.ocrText() }
        }
        RibbonGroup("Optimize") {
            RibbonButton(icon: "arrow.down.circle", title: "Compress") { actions.compress() }
        }
    }

    @ViewBuilder private var formTab: some View {
        RibbonGroup("Form Data") {
            RibbonButton(icon: "arrow.counterclockwise", title: "Reset") { actions.resetForm() }
            RibbonButton(icon: "square.and.arrow.down", title: "Import") { actions.importFormData() }
            RibbonButton(icon: "square.and.arrow.up", title: "Export") { actions.exportFormData() }
            RibbonButton(icon: "tablecells", title: "To Sheet") { actions.exportFormCSV() }
        }
        RibbonGroup("Fields") {
            RibbonButton(icon: "highlighter", title: "Highlight",
                         active: viewModel.highlightFormFields) { actions.toggleFieldHighlight() }
        }
        RibbonGroup("Fill & Sign") {
            toolButton(.textBox, title: "Add Text")
            toolButton(.signature, title: "Sign")
        }
    }

    @ViewBuilder private var protectTab: some View {
        RibbonGroup("Encrypt") {
            RibbonButton(icon: "lock", title: "Password") { actions.protect() }
        }
        RibbonGroup("Redaction") {
            toolButton(.redact, title: "Mark")
            RibbonButton(icon: "eye.slash.fill", title: "Apply") { actions.applyRedactions() }
        }
        RibbonGroup("Flatten") {
            RibbonButton(icon: "square.2.layers.3d.bottom.filled", title: "Flatten") { actions.flatten() }
        }
        RibbonGroup("Sign") {
            toolButton(.signature, title: "Place")
            RibbonButton(icon: "signature", title: "Manage") { actions.signatureManager() }
            RibbonButton(icon: "checkmark.seal", title: "Signatures") {
                viewModel.sidebarTab = .signatures
                viewModel.showSidebar = true
            }
        }
        RibbonGroup("Inspect") {
            RibbonButton(icon: "exclamationmark.shield", title: "Actions") { actions.inspectActions() }
        }
    }

    @ViewBuilder private var viewTab: some View {
        RibbonGroup("Panels") {
            RibbonButton(icon: "sidebar.left", title: "Navigation",
                         active: viewModel.showSidebar) { viewModel.showSidebar.toggle() }
            ForEach(DocViewModel.SidebarTab.allCases) { t in
                RibbonButton(icon: t.systemImage, title: t.rawValue,
                             active: viewModel.showSidebar && viewModel.sidebarTab == t) {
                    viewModel.sidebarTab = t
                    viewModel.showSidebar = true
                }
            }
        }
        RibbonGroup("Page Display") {
            RibbonButton(icon: "doc", title: "Single", active: actions.displayMode() == .singlePage) {
                actions.setDisplayMode(.singlePage)
            }
            RibbonButton(icon: "doc.text", title: "Continuous", active: actions.displayMode() == .singlePageContinuous) {
                actions.setDisplayMode(.singlePageContinuous)
            }
            RibbonButton(icon: "book.closed", title: "Facing", active: actions.displayMode() == .twoUp) {
                actions.setDisplayMode(.twoUp)
            }
            RibbonButton(icon: "book", title: "Cont. Facing", active: actions.displayMode() == .twoUpContinuous) {
                actions.setDisplayMode(.twoUpContinuous)
            }
            RibbonButton(icon: "arrow.up.arrow.down", title: "Reverse",
                         active: viewModel.reverseView) { actions.toggleReverseView() }
        }
        RibbonGroup("Reading") {
            RibbonButton(icon: "doc.text.magnifyingglass", title: "Reflow",
                         active: viewModel.readingMode == .reflow) { actions.toggleReflow() }
            RibbonButton(icon: "text.alignleft", title: "Text Viewer",
                         active: viewModel.readingMode == .textViewer) { actions.toggleTextViewer() }
            RibbonButton(icon: "book.pages", title: "Read Mode",
                         active: viewModel.readingMode == .read) { actions.toggleReadMode() }
            RibbonButton(icon: "rectangle.inset.filled", title: "Full Screen") { actions.toggleFullScreen() }
        }
        RibbonGroup("Visual Mode") {
            ForEach(AnnotatingPDFView.VisualMode.allCases) { mode in
                RibbonButton(icon: mode.systemImage, title: mode.rawValue, active: viewModel.visualMode == mode) {
                    viewModel.visualMode = mode
                }
            }
        }
        RibbonGroup("Split") {
            ForEach(DocViewModel.SplitMode.allCases) { mode in
                RibbonButton(icon: mode.systemImage, title: mode.rawValue, active: viewModel.splitMode == mode) {
                    viewModel.splitMode = mode
                }
            }
        }
        RibbonGroup("Assist") {
            RibbonButton(icon: "arrow.down.doc", title: "AutoScroll", active: viewModel.isAutoScrolling) {
                actions.toggleAutoScroll()
            }
            RibbonButton(icon: "plus.magnifyingglass", title: "Loupe", active: viewModel.showLoupe) {
                viewModel.showLoupe.toggle()
            }
            toolButton(.marqueeZoom, title: "Marquee")
        }
        RibbonGroup("Read Out Loud") {
            RibbonButton(icon: "speaker.wave.2", title: "This Page") { actions.readPage() }
            RibbonButton(icon: "text.line.first.and.arrowtriangle.forward", title: "From Here") { actions.readFrom() }
            RibbonButton(icon: "playpause", title: "Pause") { actions.readPause() }
            RibbonButton(icon: "stop.fill", title: "Stop") { actions.readStop() }
        }
        RibbonGroup("Analyze") {
            RibbonButton(icon: "textformat.123", title: "Word Count") { actions.wordCount() }
            RibbonButton(icon: "sidebar.right", title: "Properties") { actions.toggleInspector() }
        }
    }

    @ViewBuilder private var helpTab: some View {
        RibbonGroup("Help") {
            RibbonButton(icon: "keyboard", title: "Shortcuts") { actions.showShortcuts() }
            RibbonButton(icon: "info.circle", title: "About") { actions.showAbout() }
        }
        RibbonGroup("Defaults") {
            RibbonButton(icon: "doc.badge.gearshape", title: "Default App") { actions.makeDefaultReader() }
        }
    }

    private func toolButton(_ tool: Tool, title: String? = nil) -> some View {
        RibbonButton(
            icon: tool.systemImage,
            title: title ?? tool.label,
            active: viewModel.tool == tool
        ) {
            viewModel.tool = tool
        }
    }
}

// MARK: - Ribbon primitives

enum RibbonTab: String, CaseIterable, Identifiable {
    case file, home, comment, edit, organize, convert, form, protect, view, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .file: return "File"
        case .home: return "Home"
        case .comment: return "Comment"
        case .edit: return "Edit"
        case .organize: return "Organize"
        case .convert: return "Convert"
        case .form: return "Form"
        case .protect: return "Protect"
        case .view: return "View"
        case .help: return "Help"
        }
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 2) {
                HStack(alignment: .top, spacing: 2) { content }
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
            .padding(.horizontal, 6)
            Divider()
                .frame(height: 60)
                .padding(.horizontal, 2)
        }
    }
}

struct RibbonButton: View {
    let icon: String
    let title: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(height: 21)
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .frame(minWidth: 46)
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.18) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct RibbonSmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}

// MARK: - Command search (⌥Q)

struct CommandSearchView: View {
    @Binding var query: String
    @ObservedObject var viewModel: DocViewModel
    let actions: RibbonActions
    let selectTab: (RibbonTab) -> Void
    @Environment(\.presentationMode) private var presentation

    private struct Command: Identifiable {
        let id = UUID()
        let name: String
        let tab: RibbonTab
        let run: () -> Void
    }

    private var commands: [Command] {
        var list: [Command] = Tool.allCases.map { tool in
            Command(name: tool.label, tab: tool.isTextMarkup || tool.isMeasure ? .comment : .home) {
                viewModel.tool = tool
            }
        }
        list += [
            Command(name: "Open", tab: .file, run: actions.open),
            Command(name: "Save", tab: .file, run: actions.save),
            Command(name: "Save As", tab: .file, run: actions.saveAs),
            Command(name: "Print", tab: .file, run: actions.print),
            Command(name: "Batch Print", tab: .file, run: actions.batchPrint),
            Command(name: "Document Properties", tab: .file) { viewModel.showProperties = true },
            Command(name: "Preferences", tab: .file) { viewModel.showPreferences = true },
            Command(name: "Merge PDFs", tab: .organize, run: actions.merge),
            Command(name: "Split PDF", tab: .organize, run: actions.split),
            Command(name: "Organize Pages", tab: .organize, run: actions.organizer),
            Command(name: "Export to Word", tab: .convert, run: actions.exportDocx),
            Command(name: "Export to PNG", tab: .convert, run: actions.exportImages),
            Command(name: "Export Text", tab: .convert, run: actions.exportText),
            Command(name: "OCR Searchable PDF", tab: .convert, run: actions.ocrSearchable),
            Command(name: "OCR Text", tab: .convert, run: actions.ocrText),
            Command(name: "Compress", tab: .convert, run: actions.compress),
            Command(name: "Password Protect", tab: .protect, run: actions.protect),
            Command(name: "Apply Redactions", tab: .protect, run: actions.applyRedactions),
            Command(name: "Flatten Annotations", tab: .protect, run: actions.flatten),
            Command(name: "Reflow", tab: .view, run: actions.toggleReflow),
            Command(name: "Text Viewer", tab: .view, run: actions.toggleTextViewer),
            Command(name: "Read Mode", tab: .view, run: actions.toggleReadMode),
            Command(name: "Full Screen", tab: .view, run: actions.toggleFullScreen),
            Command(name: "AutoScroll", tab: .view, run: actions.toggleAutoScroll),
            Command(name: "Loupe", tab: .view) { viewModel.showLoupe.toggle() },
            Command(name: "Word Count", tab: .view, run: actions.wordCount),
            Command(name: "Read Out Loud", tab: .view, run: actions.readPage),
            Command(name: "Reverse View", tab: .view, run: actions.toggleReverseView),
            Command(name: "Summarize Comments", tab: .comment, run: actions.summarizeComments),
            Command(name: "Search & Highlight", tab: .comment, run: actions.searchAndHighlight),
            Command(name: "Stamps", tab: .comment) { viewModel.showStamps = true },
            Command(name: "Export Comments", tab: .comment) { actions.exportComments(false) },
            Command(name: "Import Comments", tab: .comment, run: actions.importComments),
            Command(name: "Reset Form", tab: .form, run: actions.resetForm),
            Command(name: "Export Form Data", tab: .form, run: actions.exportFormData),
            Command(name: "Keyboard Shortcuts", tab: .help, run: actions.showShortcuts),
        ]
        guard !query.isEmpty else { return list }
        let needle = query.lowercased()
        return list.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search commands", text: $query)
                .textFieldStyle(.roundedBorder)

            List(commands) { command in
                Button {
                    selectTab(command.tab)
                    command.run()
                    presentation.wrappedValue.dismiss()
                } label: {
                    HStack {
                        Text(command.name)
                        Spacer()
                        Text(command.tab.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 300)

            HStack {
                Spacer()
                Button("Close") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// Closures wiring ribbon buttons to ContentView's actions.
struct RibbonActions {
    var open: () -> Void = {}
    var save: () -> Void = {}
    var saveAs: () -> Void = {}
    var print: () -> Void = {}
    var batchPrint: () -> Void = {}
    var email: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var fitWidth: () -> Void = {}
    var fitPage: () -> Void = {}
    var actualSize: () -> Void = {}
    var previousPage: () -> Void = {}
    var nextPage: () -> Void = {}
    var rotateView: (Int) -> Void = { _ in }
    var addImage: () -> Void = {}
    var organizer: () -> Void = {}
    var signatureManager: () -> Void = {}
    var merge: () -> Void = {}
    var split: () -> Void = {}
    var compress: () -> Void = {}
    var protect: () -> Void = {}
    var flatten: () -> Void = {}
    var applyRedactions: () -> Void = {}
    var inspectActions: () -> Void = {}
    var ocrSearchable: () -> Void = {}
    var ocrText: () -> Void = {}
    var exportDocx: () -> Void = {}
    var exportImages: () -> Void = {}
    var exportText: () -> Void = {}
    var toggleInspector: () -> Void = {}
    var displayMode: () -> PDFDisplayMode = { .singlePageContinuous }
    var setDisplayMode: (PDFDisplayMode) -> Void = { _ in }
    var toggleAutoScroll: () -> Void = {}
    var toggleFullScreen: () -> Void = {}
    var toggleReflow: () -> Void = {}
    var toggleTextViewer: () -> Void = {}
    var toggleReadMode: () -> Void = {}
    var toggleReverseView: () -> Void = {}
    var readPage: () -> Void = {}
    var readFrom: () -> Void = {}
    var readPause: () -> Void = {}
    var readStop: () -> Void = {}
    var wordCount: () -> Void = {}
    var searchAndHighlight: () -> Void = {}
    var summarizeComments: () -> Void = {}
    var exportComments: (Bool) -> Void = { _ in }
    var importComments: () -> Void = {}
    var exportHighlights: (Bool) -> Void = { _ in }
    var resetForm: () -> Void = {}
    var importFormData: () -> Void = {}
    var exportFormData: () -> Void = {}
    var exportFormCSV: () -> Void = {}
    var toggleFieldHighlight: () -> Void = {}
    var showShortcuts: () -> Void = {}
    var showAbout: () -> Void = {}
    var makeDefaultReader: () -> Void = {}
}

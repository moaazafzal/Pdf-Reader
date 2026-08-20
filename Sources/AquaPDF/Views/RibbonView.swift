import AppKit
import PDFKit
import SwiftUI

/// Foxit-style ribbon: tab strip on top, grouped tool buttons below.
struct RibbonView: View {
    @ObservedObject var viewModel: DocViewModel
    let actions: RibbonActions

    @State private var tab: RibbonTab = .home

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            toolStrip
                .frame(height: 74)
            Divider()
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(tab == t ? Color.accentColor.opacity(0.15) : .clear)
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(tab == t ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
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
                case .home: homeTab
                case .comment: commentTab
                case .edit: editTab
                case .organize: organizeTab
                case .convert: convertTab
                case .protect: protectTab
                case .view: viewTab
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var homeTab: some View {
        RibbonGroup("Tools") {
            toolButton(.select, title: "Select")
            toolButton(.snapshot, title: "SnapShot")
        }
        RibbonGroup("Zoom") {
            RibbonButton(icon: "minus.magnifyingglass", title: "Out") { actions.zoomOut() }
            VStack(spacing: 3) {
                Text("\(Int(viewModel.scaleFactor * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                RibbonSmallButton(title: "Fit Width") { actions.fitWidth() }
                RibbonSmallButton(title: "100%") { actions.actualSize() }
            }
            .frame(width: 66)
            RibbonButton(icon: "plus.magnifyingglass", title: "In") { actions.zoomIn() }
        }
        RibbonGroup("Pages") {
            RibbonButton(icon: "chevron.up", title: "Previous") { actions.previousPage() }
            VStack(spacing: 2) {
                Text("\(viewModel.currentPageIndex + 1)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text("of \(viewModel.pageCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 46)
            RibbonButton(icon: "chevron.down", title: "Next") { actions.nextPage() }
        }
        RibbonGroup("Edit") {
            toolButton(.editText, title: "Edit Text")
            toolButton(.textBox, title: "Add Text")
            RibbonButton(icon: "photo.badge.plus", title: "Add Image") { actions.addImage() }
        }
        RibbonGroup("Sign") {
            toolButton(.signature, title: "Sign")
        }
        RibbonGroup("Pages") {
            RibbonButton(icon: "square.grid.3x3", title: "Organize") { actions.organizer() }
        }
    }

    @ViewBuilder private var commentTab: some View {
        RibbonGroup("Text Markup") {
            toolButton(.highlight, title: "Highlight")
            toolButton(.underline, title: "Underline")
            toolButton(.squiggly, title: "Squiggly")
            toolButton(.strikeout, title: "Strikeout")
            toolButton(.areaHighlight, title: "Area")
        }
        RibbonGroup("Notes") {
            toolButton(.note, title: "Note")
            toolButton(.textBox, title: "Text Box")
        }
        RibbonGroup("Drawing") {
            toolButton(.ink, title: "Pencil")
            toolButton(.rectangle, title: "Rectangle")
            toolButton(.ellipse, title: "Oval")
            toolButton(.line, title: "Line")
            toolButton(.arrow, title: "Arrow")
        }
        RibbonGroup("Style") {
            VStack(spacing: 4) {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: viewModel.style.color) },
                    set: { viewModel.style.color = NSColor($0) }
                ))
                .labelsHidden()
                Text("Color")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52)
        }
    }

    @ViewBuilder private var editTab: some View {
        RibbonGroup("Text") {
            toolButton(.editText, title: "Edit Text")
            toolButton(.textBox, title: "Add Text")
        }
        RibbonGroup("Objects") {
            RibbonButton(icon: "photo.badge.plus", title: "Add Image") { actions.addImage() }
            toolButton(.select, title: "Select")
        }
        RibbonGroup("Signature") {
            toolButton(.signature, title: "Place")
            RibbonButton(icon: "signature", title: "Manage") { actions.signatureManager() }
        }
    }

    @ViewBuilder private var organizeTab: some View {
        RibbonGroup("Pages") {
            RibbonButton(icon: "square.grid.3x3", title: "Organize") { actions.organizer() }
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
            toolButton(.signature, title: "Sign")
        }
    }

    @ViewBuilder private var viewTab: some View {
        RibbonGroup("Panels") {
            ForEach(DocViewModel.SidebarTab.allCases) { t in
                RibbonButton(icon: t.systemImage, title: t.rawValue, active: viewModel.sidebarTab == t) {
                    viewModel.sidebarTab = t
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
            RibbonButton(icon: "book", title: "Facing", active: actions.displayMode() == .twoUpContinuous) {
                actions.setDisplayMode(.twoUpContinuous)
            }
        }
        RibbonGroup("Visual Mode") {
            ForEach(AnnotatingPDFView.VisualMode.allCases) { mode in
                RibbonButton(icon: mode.systemImage, title: mode.rawValue, active: viewModel.visualMode == mode) {
                    viewModel.visualMode = mode
                }
            }
        }
        RibbonGroup("Reading") {
            RibbonButton(icon: "arrow.down.doc", title: "AutoScroll", active: viewModel.isAutoScrolling) {
                actions.toggleAutoScroll()
            }
            RibbonButton(icon: "rectangle.inset.filled", title: "Full Screen") { actions.toggleFullScreen() }
        }
        RibbonGroup("Read Out Loud") {
            RibbonButton(icon: "speaker.wave.2", title: "This Page") { actions.readPage() }
            RibbonButton(icon: "text.line.first.and.arrowtriangle.forward", title: "From Here") { actions.readFrom() }
            RibbonButton(icon: "playpause", title: "Pause") { actions.readPause() }
            RibbonButton(icon: "stop.fill", title: "Stop") { actions.readStop() }
        }
        RibbonGroup("Analyze") {
            RibbonButton(icon: "textformat.123", title: "Word Count") { actions.wordCount() }
        }
        RibbonGroup("Inspector") {
            RibbonButton(icon: "sidebar.right", title: "Properties") { actions.toggleInspector() }
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
    case home, comment, edit, organize, convert, protect, view
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .comment: return "Comment"
        case .edit: return "Edit"
        case .organize: return "Organize"
        case .convert: return "Convert"
        case .protect: return "Protect"
        case .view: return "View"
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
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            Divider()
                .frame(height: 58)
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
                    .font(.system(size: 17))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            .frame(minWidth: 48)
            .padding(.horizontal, 4)
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

/// Closures wiring ribbon buttons to ContentView's actions.
struct RibbonActions {
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var fitWidth: () -> Void = {}
    var actualSize: () -> Void = {}
    var previousPage: () -> Void = {}
    var nextPage: () -> Void = {}
    var addImage: () -> Void = {}
    var organizer: () -> Void = {}
    var signatureManager: () -> Void = {}
    var merge: () -> Void = {}
    var split: () -> Void = {}
    var compress: () -> Void = {}
    var protect: () -> Void = {}
    var flatten: () -> Void = {}
    var applyRedactions: () -> Void = {}
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
    var readPage: () -> Void = {}
    var readFrom: () -> Void = {}
    var readPause: () -> Void = {}
    var readStop: () -> Void = {}
    var wordCount: () -> Void = {}
}

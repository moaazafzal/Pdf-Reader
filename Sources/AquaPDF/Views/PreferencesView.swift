import AppKit
import PDFKit
import SwiftUI

/// App preferences (Foxit: File ▸ Preferences).
struct PreferencesView: View {
    @ObservedObject var viewModel: DocViewModel
    @Environment(\.presentationMode) private var presentation

    @AppStorage("authorName") private var authorName: String = NSFullUserName()
    @AppStorage("organization") private var organization: String = ""
    @AppStorage("defaultZoomPercent") private var defaultZoomPercent: Int = 100
    @AppStorage("defaultLayoutRaw") private var defaultLayoutRaw: Int = PDFDisplayMode.singlePageContinuous.rawValue
    @AppStorage("restoreLastSession") private var restoreLastSession = true
    @AppStorage("showStartPage") private var showStartPage = true
    @AppStorage("snapshotDPI") private var snapshotDPI: Int = 144
    @AppStorage("autoSaveMinutes") private var autoSaveMinutes: Int = 5
    @AppStorage("highlightFormFields") private var highlightFormFields = true
    @AppStorage("smoothText") private var smoothText = true
    @AppStorage("appearanceRaw") private var appearanceRaw: String = "system"
    @AppStorage("singleKeyAccelerators") private var singleKeyAccelerators = true
    @AppStorage("middleButtonAutoScroll") private var middleButtonAutoScroll = true
    @AppStorage("handToolWheelZoom") private var handToolWheelZoom = false

    var body: some View {
        TabView {
            identityTab.tabItem { Label("Identity", systemImage: "person") }
            commentingTab.tabItem { Label("Commenting", systemImage: "text.bubble") }
            pageDisplayTab.tabItem { Label("Page Display", systemImage: "doc.text.image") }
            measuringTab.tabItem { Label("Measuring", systemImage: "ruler") }
            inputTab.tabItem { Label("Keys & Mouse", systemImage: "keyboard") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 470, height: 330)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { presentation.wrappedValue.dismiss() }
            }
        }
    }

    private var identityTab: some View {
        Form {
            Section(header: Text("Author identity used on comments and replies")) {
                TextField("Name", text: $authorName)
                TextField("Organization", text: $organization)
            }
        }
        .groupedForm()
    }

    private var commentingTab: some View {
        Form {
            Section(header: Text("Making comments")) {
                Toggle("Copy marked text into the comment note", isOn: $viewModel.copyMarkedTextIntoNote)
            }
            Section(header: Text("Default appearance")) {
                ColorPicker("Markup color", selection: Binding(
                    get: { Color.from(viewModel.style.color) },
                    set: { viewModel.style.color = NSColor.from($0) }
                ))
                ColorPicker("Text color", selection: Binding(
                    get: { Color.from(viewModel.style.textColor) },
                    set: { viewModel.style.textColor = NSColor.from($0) }
                ))
                Slider(value: $viewModel.style.lineWidth, in: 1...12) { Text("Line width") }
                Toggle("Dashed lines", isOn: $viewModel.style.dashed)
            }
        }
        .groupedForm()
    }

    private var pageDisplayTab: some View {
        Form {
            Section(header: Text("Default layout and zoom")) {
                Picker("Page layout", selection: $defaultLayoutRaw) {
                    Text("Single Page").tag(PDFDisplayMode.singlePage.rawValue)
                    Text("Continuous").tag(PDFDisplayMode.singlePageContinuous.rawValue)
                    Text("Facing").tag(PDFDisplayMode.twoUp.rawValue)
                    Text("Continuous Facing").tag(PDFDisplayMode.twoUpContinuous.rawValue)
                }
                Stepper("Zoom: \(defaultZoomPercent)%", value: $defaultZoomPercent, in: 25...400, step: 25)
            }
            Section(header: Text("Rendering")) {
                Toggle("Smooth text and line art", isOn: $smoothText)
            }
            Section(header: Text("Appearance")) {
                Picker("Theme", selection: $appearanceRaw) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearanceRaw) { value in Self.applyAppearance(value) }
            }
        }
        .groupedForm()
    }

    private var measuringTab: some View {
        Form {
            Section(header: Text("Measurement units")) {
                Picker("Unit", selection: Binding(
                    get: { viewModel.measureScale.unit },
                    set: { unit in
                        if let preset = MeasureScale.presets.first(where: { $0.unit == unit }) {
                            viewModel.measureScale = MeasureScale(unit: preset.unit, unitsPerPoint: preset.unitsPerPoint)
                        }
                    }
                )) {
                    ForEach(MeasureScale.presets, id: \.unit) { preset in
                        Text(preset.name).tag(preset.unit)
                    }
                }
                LabeledRow("Scale", value: String(format: "%.4f %@ per point",
                                                      viewModel.measureScale.unitsPerPoint,
                                                      viewModel.measureScale.unit))
            }
        }
        .groupedForm()
    }

    private var generalTab: some View {
        Form {
            Section(header: Text("Application startup")) {
                Toggle("Show Start page", isOn: $showStartPage)
                Toggle("Restore last session", isOn: $restoreLastSession)
            }
            Section(header: Text("Documents")) {
                Stepper("Auto-save every \(autoSaveMinutes) min", value: $autoSaveMinutes, in: 1...60)
                Toggle("Highlight form fields", isOn: $highlightFormFields)
            }
            Section(header: Text("SnapShot")) {
                Picker("Resolution", selection: $snapshotDPI) {
                    Text("72 dpi").tag(72)
                    Text("144 dpi").tag(144)
                    Text("300 dpi").tag(300)
                }
            }
        }
        .groupedForm()
    }

    private var inputTab: some View {
        Form {
            Section(header: Text("Keyboard")) {
                Toggle("Use single-key accelerators", isOn: $singleKeyAccelerators)
                Text("H hand · V select · Z marquee · G snapshot · U highlight · T text · S note · P pencil · K callout · R rectangle · O oval · L line · A arrow · E eraser · D distance · X redact")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Mouse")) {
                Toggle("Middle button starts AutoScroll", isOn: $middleButtonAutoScroll)
                Toggle("Hand tool uses mouse-wheel zooming", isOn: $handToolWheelZoom)
                Text("⌘ or Control plus the wheel always zooms; Shift plus the wheel scrolls sideways.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .groupedForm()
    }

    static func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Document Properties (Foxit: File ▸ Properties, ⌘D).
struct DocumentPropertiesView: View {
    let document: PDFDocument
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        TabView {
            descriptionTab.tabItem { Label("Description", systemImage: "info.circle") }
            securityTab.tabItem { Label("Security", systemImage: "lock") }
            fontsTab.tabItem { Label("Fonts", systemImage: "textformat") }
        }
        .frame(width: 460, height: 320)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { presentation.wrappedValue.dismiss() } }
        }
    }

    private var attributes: [AnyHashable: Any] { document.documentAttributes ?? [:] }

    private func attribute(_ key: PDFDocumentAttribute) -> String {
        (attributes[key] as? String) ?? "—"
    }

    private var descriptionTab: some View {
        Form {
            Section(header: Text("Document")) {
                LabeledRow("File", value: document.documentURL?.lastPathComponent ?? "Untitled")
                LabeledRow("Title", value: attribute(.titleAttribute))
                LabeledRow("Author", value: attribute(.authorAttribute))
                LabeledRow("Subject", value: attribute(.subjectAttribute))
                LabeledRow("Keywords", value: attribute(.keywordsAttribute))
                LabeledRow("Creator", value: attribute(.creatorAttribute))
                LabeledRow("Producer", value: attribute(.producerAttribute))
            }
            Section(header: Text("Statistics")) {
                LabeledRow("Pages", value: "\(document.pageCount)")
                if let page = document.page(at: 0) {
                    let size = page.bounds(for: .mediaBox).size
                    LabeledRow("Page size", value: String(format: "%.0f × %.0f pt", size.width, size.height))
                }
                if let url = document.documentURL,
                   let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    LabeledRow("File size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                }
            }
        }
        .groupedForm()
    }

    private var securityTab: some View {
        Form {
            Section(header: Text("Security")) {
                LabeledRow("Encrypted", value: document.isEncrypted ? "Yes" : "No")
                LabeledRow("Locked", value: document.isLocked ? "Yes" : "No")
                LabeledRow("Printing", value: document.allowsPrinting ? "Allowed" : "Not allowed")
                LabeledRow("Copying", value: document.allowsCopying ? "Allowed" : "Not allowed")
                LabeledRow("Commenting", value: document.allowsCommenting ? "Allowed" : "Not allowed")
                LabeledRow("Form filling", value: document.allowsFormFieldEntry ? "Allowed" : "Not allowed")
                LabeledRow("Content changes", value: document.allowsDocumentChanges ? "Allowed" : "Not allowed")
            }
        }
        .groupedForm()
    }

    private var fontsTab: some View {
        let fonts = fontNames()
        return Group {
            if fonts.isEmpty {
                EmptyStateView("No Embedded Font Data", systemImage: "textformat")
            } else {
                List(fonts, id: \.self) { Text($0).font(.callout) }
            }
        }
    }

    /// Collects font names referenced by annotations and page text where PDFKit exposes them.
    private func fontNames() -> [String] {
        var names = Set<String>()
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for annotation in page.annotations {
                if let font = annotation.font { names.insert(font.fontName) }
            }
            guard let attributed = page.attributedString else { continue }
            attributed.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if let font = value as? NSFont { names.insert(font.fontName) }
            }
        }
        return names.sorted()
    }
}

/// Stamps palette (Foxit: Comment ▸ Stamp).
struct StampPaletteView: View {
    @ObservedObject var viewModel: DocViewModel
    @Environment(\.presentationMode) private var presentation

    private let standard = ["APPROVED", "REVIEWED", "DRAFT", "FINAL", "CONFIDENTIAL", "NOT APPROVED", "VOID", "COMPLETED"]
    private let signHere = ["SIGN HERE", "INITIAL HERE", "WITNESS", "ACCEPTED"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stamps")
                .font(.headline)

            group("Standard", stamps: standard, color: .systemRed)
            group("Sign Here", stamps: signHere, color: .systemBlue)

            Divider()

            HStack {
                Button("Dynamic Stamp…") { placeDynamic() }
                Button("From Clipboard") { placeClipboardImage() }
                Button("From File…") { placeImageFile() }
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 470)
    }

    private func group(_ title: String, stamps: [String], color: NSColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                ForEach(stamps, id: \.self) { stamp in
                    Button { choose(stamp, color: color) } label: {
                        Text(stamp)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color.from(color))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.from(color), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func choose(_ text: String, color: NSColor) {
        guard let view = viewModel.pdfView as? AnnotatingPDFView else { return }
        view.pendingStampImage = nil
        view.pendingStampText = text
        viewModel.style.color = color
        viewModel.tool = .stamp
        viewModel.flashHandler?("Click the page to place the stamp")
        presentation.wrappedValue.dismiss()
    }

    private func placeDynamic() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let text = "\(viewModel.authorName) · \(formatter.string(from: Date()))"
        choose(text, color: .systemBlue)
    }

    private func placeClipboardImage() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let view = viewModel.pdfView as? AnnotatingPDFView
        else {
            viewModel.flashHandler?("No image on the clipboard")
            return
        }
        view.pendingStampText = nil
        view.pendingStampImage = image
        viewModel.tool = .stamp
        viewModel.flashHandler?("Click the page to place the stamp")
        presentation.wrappedValue.dismiss()
    }

    private func placeImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              let view = viewModel.pdfView as? AnnotatingPDFView
        else { return }
        view.pendingStampText = nil
        view.pendingStampImage = image
        viewModel.tool = .stamp
        viewModel.flashHandler?("Click the page to place the stamp")
        presentation.wrappedValue.dismiss()
    }
}

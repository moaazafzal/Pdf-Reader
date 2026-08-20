import AppKit
import PDFKit
import SwiftUI

/// App preferences (Foxit: File ▸ Preferences).
struct PreferencesView: View {
    @ObservedObject var viewModel: DocViewModel
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        TabView {
            identityTab.tabItem { Label("Identity", systemImage: "person") }
            commentingTab.tabItem { Label("Commenting", systemImage: "text.bubble") }
            pageDisplayTab.tabItem { Label("Page Display", systemImage: "doc.text.image") }
            measuringTab.tabItem { Label("Measuring", systemImage: "ruler") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 470, height: 330)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var identityTab: some View {
        Form {
            Section("Author identity used on comments and replies") {
                TextField("Name", text: $authorName)
                TextField("Organization", text: $organization)
            }
        }
        .formStyle(.grouped)
    }

    private var commentingTab: some View {
        Form {
            Section("Making comments") {
                Toggle("Copy marked text into the comment note", isOn: $viewModel.copyMarkedTextIntoNote)
            }
            Section("Default appearance") {
                ColorPicker("Markup color", selection: Binding(
                    get: { Color(nsColor: viewModel.style.color) },
                    set: { viewModel.style.color = NSColor($0) }
                ))
                ColorPicker("Text color", selection: Binding(
                    get: { Color(nsColor: viewModel.style.textColor) },
                    set: { viewModel.style.textColor = NSColor($0) }
                ))
                Slider(value: $viewModel.style.lineWidth, in: 1...12) { Text("Line width") }
                Toggle("Dashed lines", isOn: $viewModel.style.dashed)
            }
        }
        .formStyle(.grouped)
    }

    private var pageDisplayTab: some View {
        Form {
            Section("Default layout and zoom") {
                Picker("Page layout", selection: $defaultLayoutRaw) {
                    Text("Single Page").tag(PDFDisplayMode.singlePage.rawValue)
                    Text("Continuous").tag(PDFDisplayMode.singlePageContinuous.rawValue)
                    Text("Facing").tag(PDFDisplayMode.twoUp.rawValue)
                    Text("Continuous Facing").tag(PDFDisplayMode.twoUpContinuous.rawValue)
                }
                Stepper("Zoom: \(defaultZoomPercent)%", value: $defaultZoomPercent, in: 25...400, step: 25)
            }
            Section("Rendering") {
                Toggle("Smooth text and line art", isOn: $smoothText)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearanceRaw) { _, value in Self.applyAppearance(value) }
            }
        }
        .formStyle(.grouped)
    }

    private var measuringTab: some View {
        Form {
            Section("Measurement units") {
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
                LabeledContent("Scale", value: String(format: "%.4f %@ per point",
                                                      viewModel.measureScale.unitsPerPoint,
                                                      viewModel.measureScale.unit))
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section("Application startup") {
                Toggle("Show Start page", isOn: $showStartPage)
                Toggle("Restore last session", isOn: $restoreLastSession)
            }
            Section("Documents") {
                Stepper("Auto-save every \(autoSaveMinutes) min", value: $autoSaveMinutes, in: 1...60)
                Toggle("Highlight form fields", isOn: $highlightFormFields)
            }
            Section("SnapShot") {
                Picker("Resolution", selection: $snapshotDPI) {
                    Text("72 dpi").tag(72)
                    Text("144 dpi").tag(144)
                    Text("300 dpi").tag(300)
                }
            }
        }
        .formStyle(.grouped)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            descriptionTab.tabItem { Label("Description", systemImage: "info.circle") }
            securityTab.tabItem { Label("Security", systemImage: "lock") }
            fontsTab.tabItem { Label("Fonts", systemImage: "textformat") }
        }
        .frame(width: 460, height: 320)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private var attributes: [AnyHashable: Any] { document.documentAttributes ?? [:] }

    private func attribute(_ key: PDFDocumentAttribute) -> String {
        (attributes[key] as? String) ?? "—"
    }

    private var descriptionTab: some View {
        Form {
            Section("Document") {
                LabeledContent("File", value: document.documentURL?.lastPathComponent ?? "Untitled")
                LabeledContent("Title", value: attribute(.titleAttribute))
                LabeledContent("Author", value: attribute(.authorAttribute))
                LabeledContent("Subject", value: attribute(.subjectAttribute))
                LabeledContent("Keywords", value: attribute(.keywordsAttribute))
                LabeledContent("Creator", value: attribute(.creatorAttribute))
                LabeledContent("Producer", value: attribute(.producerAttribute))
            }
            Section("Statistics") {
                LabeledContent("Pages", value: "\(document.pageCount)")
                if let page = document.page(at: 0) {
                    let size = page.bounds(for: .mediaBox).size
                    LabeledContent("Page size", value: String(format: "%.0f × %.0f pt", size.width, size.height))
                }
                if let url = document.documentURL,
                   let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var securityTab: some View {
        Form {
            Section("Security") {
                LabeledContent("Encrypted", value: document.isEncrypted ? "Yes" : "No")
                LabeledContent("Locked", value: document.isLocked ? "Yes" : "No")
                LabeledContent("Printing", value: document.allowsPrinting ? "Allowed" : "Not allowed")
                LabeledContent("Copying", value: document.allowsCopying ? "Allowed" : "Not allowed")
                LabeledContent("Commenting", value: document.allowsCommenting ? "Allowed" : "Not allowed")
                LabeledContent("Form filling", value: document.allowsFormFieldEntry ? "Allowed" : "Not allowed")
                LabeledContent("Content changes", value: document.allowsDocumentChanges ? "Allowed" : "Not allowed")
            }
        }
        .formStyle(.grouped)
    }

    private var fontsTab: some View {
        let fonts = fontNames()
        return Group {
            if fonts.isEmpty {
                ContentUnavailableView("No Embedded Font Data", systemImage: "textformat")
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
    @Environment(\.dismiss) private var dismiss

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
                Button("Cancel") { dismiss() }
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
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                ForEach(stamps, id: \.self) { stamp in
                    Button { choose(stamp, color: color) } label: {
                        Text(stamp)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(nsColor: color))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: color), lineWidth: 1.5))
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
        dismiss()
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
        dismiss()
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
        dismiss()
    }
}

import AppKit
import PDFKit
import SwiftUI

/// Insert page numbers into the document (Foxit: Organize ▸ Page Numbers).
struct PageNumbersView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel
    /// Called with the pre-change PDF data so the caller can register undo.
    var onApply: (Data?, Int) -> Void
    @Environment(\.presentationMode) private var presentation

    @State private var options = PDFOperations.PageNumberOptions()
    @State private var applyToAll = true
    @State private var fromPage = 1
    @State private var toPage = 1
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Page Numbers")
                .font(.headline)

            HStack(alignment: .top, spacing: 20) {
                settings
                preview
            }

            Divider()

            HStack {
                Text("Numbers are written into the page content, so they print and show in any reader.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Working…" : "Insert") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { toPage = max(document.pageCount, 1) }
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Position", selection: $options.position) {
                ForEach(PDFOperations.NumberPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Format", selection: $options.format) {
                ForEach(PDFOperations.NumberFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Text("Prefix")
                TextField("optional", text: $options.prefix)
                    .frame(width: 110)
            }
            Stepper("Start at: \(options.startNumber)", value: $options.startNumber, in: 1...99999)
            Stepper("Size: \(Int(options.fontSize)) pt", value: $options.fontSize, in: 6...36, step: 1)
            Stepper("Margin: \(Int(options.margin)) pt", value: $options.margin, in: 8...120, step: 2)
            ColorPicker("Color", selection: Binding(
                get: { Color.from(options.color) },
                set: { options.color = NSColor.from($0) }
            ))

            Toggle("All pages", isOn: $applyToAll)
            if !applyToAll {
                HStack {
                    Text("Pages")
                    TextField("", value: $fromPage, formatter: NumberFormatter())
                        .frame(width: 50)
                    Text("to")
                    TextField("", value: $toPage, formatter: NumberFormatter())
                        .frame(width: 50)
                }
            }
        }
        .frame(width: 260)
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 6) {
            Text("Preview")
                .font(.caption)
                .foregroundColor(.secondary)
            ZStack {
                Rectangle()
                    .fill(Color.white)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.4)))
                VStack(spacing: 3) {
                    ForEach(0..<9, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 26)

                Text(sampleText)
                    .font(.system(size: max(options.fontSize * 0.62, 6)))
                    .foregroundColor(Color.from(options.color))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: previewAlignment)
                    .padding(.horizontal, options.margin * 0.35)
                    .padding(.vertical, options.margin * 0.35)
            }
            .frame(width: 175, height: 226)
        }
    }

    private var sampleText: String {
        PDFOperations.pageNumberText(
            number: options.startNumber,
            total: applyToAll ? document.pageCount : max(toPage - fromPage + 1, 1),
            options: options
        )
    }

    private var previewAlignment: Alignment {
        switch options.position {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    // MARK: - Apply

    private func apply() {
        working = true
        var opts = options
        if !applyToAll {
            let lower = max(0, min(fromPage, toPage) - 1)
            let upper = min(document.pageCount - 1, max(fromPage, toPage) - 1)
            opts.range = lower <= upper ? lower...upper : nil
        }
        let before = document.dataRepresentation()
        let stamped = PDFOperations.insertPageNumbers(in: document, options: opts)
        working = false
        onApply(before, stamped)
        presentation.wrappedValue.dismiss()
    }
}

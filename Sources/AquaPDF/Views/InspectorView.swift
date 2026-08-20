import PDFKit
import SwiftUI

/// Properties panel for the selected annotation.
struct InspectorView: View {
    @ObservedObject var viewModel: DocViewModel
    @State private var contentsDraft = ""

    var body: some View {
        Form {
            if let annotation = viewModel.selectedAnnotation {
                Section("Annotation") {
                    LabeledContent("Type", value: annotation.type ?? "Unknown")

                    ColorPicker("Color", selection: Binding(
                        get: { Color(nsColor: annotation.color) },
                        set: { newValue in
                            annotation.color = NSColor(newValue)
                            viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
                        }
                    ))

                    TextField("Note", text: $contentsDraft, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: contentsDraft) { _, newValue in
                            annotation.contents = newValue
                        }

                    Button("Delete Annotation", role: .destructive) {
                        viewModel.deleteSelectedAnnotation()
                    }
                }
                .onAppear { contentsDraft = annotation.contents ?? "" }
            } else {
                Section("Tool Defaults") {
                    ColorPicker("Color", selection: Binding(
                        get: { Color(nsColor: viewModel.style.color) },
                        set: { viewModel.style.color = NSColor($0) }
                    ))
                    Slider(value: $viewModel.style.lineWidth, in: 1...12) {
                        Text("Line Width")
                    }
                    LabeledContent("Width", value: String(format: "%.0f pt", viewModel.style.lineWidth))
                }
                Text("Select an annotation to edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: viewModel.selectedAnnotation) { _, newValue in
            contentsDraft = newValue?.contents ?? ""
        }
    }
}

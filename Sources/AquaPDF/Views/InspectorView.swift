import PDFKit
import SwiftUI

/// Properties panel for the selected annotation.
struct InspectorView: View {
    @ObservedObject var viewModel: DocViewModel
    @State private var contentsDraft = ""

    var body: some View {
        Form {
            if let annotation = viewModel.selectedAnnotation {
                Section(header: Text("Annotation")) {
                    LabeledRow("Type", value: annotation.type ?? "Unknown")

                    ColorPicker("Color", selection: Binding(
                        get: { Color.from(annotation.color) },
                        set: { newValue in
                            annotation.color = NSColor.from(newValue)
                            viewModel.pdfView?.setNeedsDisplay(viewModel.pdfView?.bounds ?? .zero)
                        }
                    ))

                    TextField("Note", text: $contentsDraft)
                        .lineLimit(8)
                        .onChange(of: contentsDraft) { newValue in
                            annotation.contents = newValue
                        }

                    Button("Delete Annotation") {
                        viewModel.deleteSelectedAnnotation()
                    }
                }
                .onAppear { contentsDraft = annotation.contents ?? "" }
            } else {
                Section(header: Text("Tool Defaults")) {
                    ColorPicker("Color", selection: Binding(
                        get: { Color.from(viewModel.style.color) },
                        set: { viewModel.style.color = NSColor.from($0) }
                    ))
                    Slider(value: $viewModel.style.lineWidth, in: 1...12) {
                        Text("Line Width")
                    }
                    LabeledRow("Width", value: String(format: "%.0f pt", viewModel.style.lineWidth))
                }
                Text("Select an annotation to edit it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .groupedForm()
        .onChange(of: viewModel.selectedAnnotation) { newValue in
            contentsDraft = newValue?.contents ?? ""
        }
    }
}

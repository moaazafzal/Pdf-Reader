import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet with a page grid: reorder (drag), rotate, delete, extract.
struct PageOrganizerView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel
    /// Called after each mutation with the PDF data captured before it (for undo).
    var onChanged: (Data?) -> Void
    @Environment(\.presentationMode) private var presentation

    @State private var selection: Set<Int> = []
    @State private var refresh = 0

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Organize Pages")
                    .font(.headline)
                Spacer()
                Button("Rotate Left") { rotate(-90) }.disabled(selection.isEmpty)
                Button("Rotate Right") { rotate(90) }.disabled(selection.isEmpty)
                Button("Extract…") { extract() }.disabled(selection.isEmpty)
                Button("Delete") { deleteSelected() }
                    .disabled(selection.isEmpty || selection.count >= document.pageCount)
                Divider().frame(height: 16)
                Button("Done") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            ScrollView {
                let _ = refresh
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<document.pageCount, id: \.self) { i in
                        pageCell(i)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    @ViewBuilder
    private func pageCell(_ i: Int) -> some View {
        if let page = document.page(at: i) {
            VStack(spacing: 4) {
                Image(nsImage: page.thumbnail(of: CGSize(width: 130, height: 170), for: .mediaBox))
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 170)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(selection.contains(i) ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: selection.contains(i) ? 3 : 1)
                    )
                Text("\(i + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button { move(i, by: -1) } label: { Image(systemName: "arrow.left") }
                        .disabled(i == 0)
                    Button { move(i, by: 1) } label: { Image(systemName: "arrow.right") }
                        .disabled(i == document.pageCount - 1)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            }
        }
    }

    private func move(_ i: Int, by delta: Int) {
        let j = i + delta
        guard j >= 0, j < document.pageCount, let page = document.page(at: i) else { return }
        let before = document.dataRepresentation()
        document.removePage(at: i)
        document.insert(page, at: j)
        selection = []
        refresh += 1
        onChanged(before)
    }

    private func rotate(_ degrees: Int) {
        let before = document.dataRepresentation()
        for i in selection {
            guard let page = document.page(at: i) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        refresh += 1
        onChanged(before)
    }

    private func deleteSelected() {
        let before = document.dataRepresentation()
        for i in selection.sorted(by: >) {
            document.removePage(at: i)
        }
        selection = []
        refresh += 1
        onChanged(before)
    }

    private func extract() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Extracted Pages.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PDFOperations.extract(pageIndexes: Array(selection), from: document, to: url)
    }
}

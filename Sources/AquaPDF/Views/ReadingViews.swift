import AppKit
import PDFKit
import SwiftUI

/// Reflow: the document's text laid out in one readable column (does not alter the PDF).
struct ReflowView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel
    @State private var fontSize: CGFloat = 15

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reflow")
                    .font(.headline)
                Spacer()
                Button { fontSize = max(10, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                Button { fontSize = min(34, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                Button("Close") { viewModel.readingMode = .normal }
            }
            .padding(10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(0..<document.pageCount), id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Page \(i + 1)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(paragraphs(of: i))
                                .font(.system(size: fontSize))
                                .textSelectionIfAvailable()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func paragraphs(of index: Int) -> String {
        guard let text = document.page(at: index)?.string else { return "" }
        // PDF text extraction breaks lines mid-sentence; rejoin lines that are not paragraph ends.
        var output = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                output += "\n\n"
            } else if output.hasSuffix("\n\n") || output.isEmpty {
                output += trimmed
            } else if let last = output.last, ".!?:;".contains(last) {
                output += "\n\n" + trimmed
            } else {
                output += " " + trimmed
            }
        }
        return output
    }
}

/// Text Viewer: plain-text representation of the whole document.
struct TextViewerView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Text Viewer")
                    .font(.headline)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.string ?? "", forType: .string)
                    viewModel.flashHandler?("Document text copied")
                }
                Button("Close") { viewModel.readingMode = .normal }
            }
            .padding(10)
            Divider()

            ScrollView {
                Text(document.string ?? "")
                    .font(.system(size: 13, design: .monospaced))
                    .textSelectionIfAvailable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }
}

/// Floating magnifier that follows a fixed spot, showing the page region enlarged.
struct LoupeView: View {
    @ObservedObject var viewModel: DocViewModel
    @State private var zoom: CGFloat = 3
    @State private var image: NSImage?
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Loupe")
                    .font(.caption.weight(.semibold))
                Spacer()
                Slider(value: $zoom, in: 2...8)
                    .frame(width: 90)
                    .controlSize(.mini)
                Button {
                    viewModel.showLoupe = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Text("Move the pointer over the page")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 240, height: 170)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
        }
        .padding(10)
        .panelBackground(cornerRadius: 10)
        .shadow(radius: 8)
        .onAppear { start() }
        .onDisappear { timer?.invalidate() }
    }

    private func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func refresh() {
        guard let view = viewModel.pdfView, let window = view.window else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let viewPoint = view.convert(mouseInWindow, from: nil)
        guard view.bounds.contains(viewPoint), let page = view.page(for: viewPoint, nearest: false) else { return }
        let pagePoint = view.convert(viewPoint, to: page)
        let size = CGSize(width: 240 / zoom / view.scaleFactor, height: 170 / zoom / view.scaleFactor)
        let rect = CGRect(
            x: pagePoint.x - size.width / 2,
            y: pagePoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        image = PDFOperations.renderRegion(rect, of: page, scale: zoom)
    }
}

import PDFKit
import SwiftUI

struct SidebarView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewModel.sidebarTab) {
                ForEach(DocViewModel.SidebarTab.allCases) { tab in
                    Image(systemName: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch viewModel.sidebarTab {
            case .pages:
                ThumbnailListView(document: document, viewModel: viewModel)
            case .outline:
                OutlineListView(document: document, viewModel: viewModel)
            case .annotations:
                AnnotationListView(document: document, viewModel: viewModel)
            case .search:
                SearchListView(document: document, viewModel: viewModel)
            }
        }
    }
}

// MARK: - Pages

struct ThumbnailListView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    var body: some View {
        ScrollViewReader { proxy in
            List(0..<max(document.pageCount, 0), id: \.self) { i in
                if let page = document.page(at: i) {
                    VStack(spacing: 4) {
                        Image(nsImage: page.thumbnail(of: CGSize(width: 140, height: 190), for: .mediaBox))
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 140, maxHeight: 190)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(i == viewModel.currentPageIndex ? Color.accentColor : Color.secondary.opacity(0.3),
                                            lineWidth: i == viewModel.currentPageIndex ? 2 : 1)
                            )
                        Text("\(i + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.pdfView?.go(to: page)
                    }
                    .id(i)
                }
            }
            .onChange(of: viewModel.currentPageIndex) { _, newValue in
                proxy.scrollTo(newValue)
            }
        }
    }
}

// MARK: - Outline

struct OutlineListView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let depth: Int
        let destination: PDFDestination?
    }

    var items: [Item] {
        var out: [Item] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                out.append(Item(label: child.label ?? "Untitled", depth: depth, destination: child.destination))
                walk(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        return out
    }

    var body: some View {
        let list = items
        if list.isEmpty {
            ContentUnavailableView("No Outline", systemImage: "list.bullet.indent")
        } else {
            List(list) { item in
                Button {
                    if let dest = item.destination { viewModel.pdfView?.go(to: dest) }
                } label: {
                    Text(item.label)
                        .lineLimit(2)
                        .padding(.leading, CGFloat(item.depth) * 12)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Annotations

struct AnnotationListView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    var body: some View {
        // annotationsVersion read forces refresh when annotations change.
        let _ = viewModel.annotationsVersion
        let entries: [(annotation: PDFAnnotation, pageIndex: Int)] = (0..<document.pageCount).flatMap { i -> [(PDFAnnotation, Int)] in
            guard let page = document.page(at: i) else { return [] }
            return page.annotations
                .filter { !$0.isLink && !$0.isWidget }
                .map { ($0, i) }
        }

        if entries.isEmpty {
            ContentUnavailableView("No Annotations", systemImage: "text.bubble")
        } else {
            List(entries.indices, id: \.self) { idx in
                let entry = entries[idx]
                Button {
                    if let page = entry.annotation.page {
                        viewModel.pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: entry.annotation.bounds.midX, y: entry.annotation.bounds.maxY)))
                        viewModel.selectedAnnotation = entry.annotation
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Circle()
                                .fill(Color(nsColor: entry.annotation.color))
                                .frame(width: 8, height: 8)
                            Text(entry.annotation.type ?? "Annotation")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("p. \(entry.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let contents = entry.annotation.contents, !contents.isEmpty {
                            Text(contents)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Search

struct SearchListView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search document", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .onSubmit { viewModel.runSearch(in: document) }

            Divider()

            if viewModel.searchResults.isEmpty {
                ContentUnavailableView(
                    viewModel.searchText.isEmpty ? "Type to Search" : "No Results",
                    systemImage: "magnifyingglass"
                )
            } else {
                List(viewModel.searchResults.indices, id: \.self) { i in
                    let sel = viewModel.searchResults[i]
                    Button {
                        viewModel.goTo(selection: sel)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context(for: sel))
                                .font(.callout)
                                .lineLimit(2)
                            if let page = sel.pages.first {
                                Text("Page \(document.index(for: page) + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func context(for selection: PDFSelection) -> String {
        let extended = selection.copy() as! PDFSelection
        extended.extend(atStart: 20)
        extended.extend(atEnd: 30)
        return (extended.string ?? selection.string ?? "").replacingOccurrences(of: "\n", with: " ")
    }
}

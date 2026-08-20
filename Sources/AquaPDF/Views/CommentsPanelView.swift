import AppKit
import PDFKit
import SwiftUI

/// Foxit-style Comments panel: browse, search, sort, filter, reply, set status and checkmarks.
struct CommentsPanelView: View {
    let document: PDFDocument
    @ObservedObject var viewModel: DocViewModel

    enum Sort: String, CaseIterable, Identifiable {
        case page = "Page", type = "Type", author = "Author", date = "Date", status = "Status"
        var id: String { rawValue }
    }

    @State private var sort: Sort = .page
    @State private var filterText = ""
    @State private var statusFilter: CommentMeta.Status?
    @State private var checkedOnly = false
    @State private var expanded: Set<String> = []
    @State private var replyDrafts: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            let entries = filteredEntries()
            if entries.isEmpty {
                EmptyStateView("No Comments", systemImage: "text.bubble")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries, id: \.key) { entry in
                        row(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 6) {
            TextField("Search comments", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            HStack(spacing: 6) {
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)

                Menu {
                    Button("All Statuses") { statusFilter = nil }
                    ForEach(CommentMeta.Status.allCases) { status in
                        Button(status.rawValue) { statusFilter = status }
                    }
                } label: {
                    Label(statusFilter?.rawValue ?? "Status", systemImage: "line.3.horizontal.decrease.circle")
                }
                .controlSize(.small)

                Toggle(isOn: $checkedOnly) {
                    Image(systemName: "checkmark.square")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Show checked comments only")
            }
        }
        .padding(8)
    }

    // MARK: - Rows

    private struct Entry {
        let annotation: PDFAnnotation
        let pageIndex: Int
        var key: String { "\(pageIndex)-\(UInt(bitPattern: ObjectIdentifier(annotation).hashValue))" }
    }

    private func filteredEntries() -> [Entry] {
        _ = viewModel.annotationsVersion  // re-read when annotations change
        var entries = CommentExchange.allComments(in: document)
            .map { Entry(annotation: $0.annotation, pageIndex: $0.pageIndex) }

        if !filterText.isEmpty {
            let needle = filterText.lowercased()
            entries = entries.filter {
                ($0.annotation.contents ?? "").lowercased().contains(needle)
                    || ($0.annotation.userName ?? "").lowercased().contains(needle)
                    || $0.annotation.displayKind.lowercased().contains(needle)
            }
        }
        if let statusFilter {
            entries = entries.filter { $0.annotation.reviewMeta.status == statusFilter }
        }
        if checkedOnly {
            entries = entries.filter { $0.annotation.reviewMeta.checked }
        }

        switch sort {
        case .page: entries.sort { $0.pageIndex < $1.pageIndex }
        case .type: entries.sort { $0.annotation.displayKind < $1.annotation.displayKind }
        case .author: entries.sort { ($0.annotation.userName ?? "") < ($1.annotation.userName ?? "") }
        case .date:
            entries.sort {
                ($0.annotation.modificationDate ?? .distantPast) < ($1.annotation.modificationDate ?? .distantPast)
            }
        case .status:
            entries.sort { $0.annotation.reviewMeta.status.rawValue < $1.annotation.reviewMeta.status.rawValue }
        }
        return entries
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        let annotation = entry.annotation
        let meta = annotation.reviewMeta
        let key = entry.key

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    var updated = annotation.reviewMeta
                    updated.checked.toggle()
                    annotation.reviewMeta = updated
                    viewModel.annotationsVersion += 1
                } label: {
                    Image(systemName: meta.checked ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain)

                Circle()
                    .fill(Color.from(annotation.color))
                    .frame(width: 8, height: 8)

                Text(annotation.displayKind)
                    .font(.callout.weight(.medium))

                Spacer()

                Text("p. \(entry.pageIndex + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let contents = annotation.contents, !contents.isEmpty {
                Text(contents)
                    .font(.caption)
                    .lineLimit(expanded.contains(key) ? nil : 2)
            }

            if meta.status != .none || !meta.replies.isEmpty {
                HStack(spacing: 8) {
                    if meta.status != .none {
                        Label(meta.status.rawValue, systemImage: meta.status.systemImage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if !meta.replies.isEmpty {
                        Label("\(meta.replies.count)", systemImage: "arrowshape.turn.up.left")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if expanded.contains(key) {
                replySection(annotation: annotation, meta: meta, key: key)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { goTo(entry) }
        .contextMenu {
            Button("Reply…") { expanded.insert(key) }
            Menu("Set Status") {
                ForEach(CommentMeta.Status.allCases) { status in
                    Button(status.rawValue) {
                        var updated = annotation.reviewMeta
                        updated.status = status
                        annotation.reviewMeta = updated
                        viewModel.annotationsVersion += 1
                    }
                }
            }
            Divider()
            Button("Delete") {
                viewModel.selectedAnnotation = annotation
                viewModel.deleteSelectedAnnotation()
            }
        }
    }

    @ViewBuilder
    private func replySection(annotation: PDFAnnotation, meta: CommentMeta, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(meta.replies) { reply in
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.author)
                        .font(.caption2.weight(.semibold))
                    Text(reply.text)
                        .font(.caption2)
                }
                .padding(.leading, 10)
            }

            HStack(spacing: 4) {
                TextField("Reply", text: Binding(
                    get: { replyDrafts[key] ?? "" },
                    set: { replyDrafts[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

                Button("Post") { postReply(annotation: annotation, key: key) }
                    .controlSize(.small)
                    .disabled((replyDrafts[key] ?? "").isEmpty)
            }
        }
        .padding(.top, 2)
    }

    private func postReply(annotation: PDFAnnotation, key: String) {
        let text = (replyDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var meta = annotation.reviewMeta
        meta.replies.append(CommentMeta.Reply(author: viewModel.authorName, text: text, date: Date()))
        annotation.reviewMeta = meta
        replyDrafts[key] = ""
        viewModel.annotationsVersion += 1
    }

    private func goTo(_ entry: Entry) {
        guard let page = entry.annotation.page else { return }
        viewModel.pdfView?.go(to: PDFDestination(
            page: page,
            at: CGPoint(x: entry.annotation.bounds.midX, y: entry.annotation.bounds.maxY)
        ))
        viewModel.selectedAnnotation = entry.annotation
    }
}

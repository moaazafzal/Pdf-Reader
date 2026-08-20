import AppKit
import PDFKit
import SwiftUI

/// Foxit-style start dashboard: quick actions on the left, recent files grid on the right.
struct StartView: View {
    @Environment(\.openDocument) private var openDocument
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var recents: [URL] = []

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.02, green: 0.21, blue: 0.45),
                            Color(red: 0.10, green: 0.55, blue: 0.75),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            recentsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 800, height: 500)
        .onAppear { loadRecents() }
    }

    // MARK: - Left column

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AquaPDF")
                        .font(.title2.bold())
                    Text("Free PDF Editor")
                        .font(.caption)
                        .opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(.top, 28)

            Spacer().frame(height: 4)

            startButton("Open PDF…", icon: "folder") { openFromPanel() }
            startButton("New Blank PDF", icon: "doc.badge.plus") {
                newDocument { PDFFileDocument() }
                dismissWindow(id: "start")
            }

            Spacer()

            Text("All tools free: annotate, edit, sign,\nredact, OCR, convert, organize.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    private func startButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                    .fontWeight(.medium)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recents

    private var recentsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Files")
                .font(.headline)
                .padding(.top, 20)
                .padding(.horizontal, 20)

            if recents.isEmpty {
                ContentUnavailableView(
                    "No Recent Files",
                    systemImage: "clock",
                    description: Text("Files you open will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                        ForEach(recents, id: \.self) { url in
                            recentCard(url)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func recentCard(_ url: URL) -> some View {
        Button {
            open(url)
        } label: {
            VStack(spacing: 6) {
                RecentThumbnail(url: url)
                    .frame(width: 120, height: 150)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
    }

    // MARK: - Actions

    private func loadRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func openFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func open(_ url: URL) {
        Task {
            try? await openDocument(at: url)
            dismissWindow(id: "start")
        }
    }
}

/// Async-loaded first-page thumbnail for a recent file.
struct RecentThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let target = url
            let thumb = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let doc = PDFDocument(url: target), let page = doc.page(at: 0) else { return nil }
                return page.thumbnail(of: CGSize(width: 240, height: 300), for: .mediaBox)
            }.value
            image = thumb
        }
    }
}

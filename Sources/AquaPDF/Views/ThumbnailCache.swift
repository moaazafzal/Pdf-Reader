import AppKit
import PDFKit
import SwiftUI

/// Renders page thumbnails off the main thread and caches them.
///
/// Rendering thumbnails inline in a SwiftUI list body blocks the main thread on
/// every layout pass, which is what made large documents unusable.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    /// Bounded queue: scrolling a long document would otherwise fan out one page
    /// render per visible row and saturate every core at once.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    /// Bumped when a new image lands, so observing views refresh.
    @Published private(set) var generation = 0

    private init() {
        cache.countLimit = 240
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    private func key(_ document: PDFDocument, _ index: Int, _ size: CGSize) -> String {
        let doc = document.documentURL?.path ?? String(UInt(bitPattern: ObjectIdentifier(document).hashValue))
        return "\(doc)#\(index)@\(Int(size.width))x\(Int(size.height))"
    }

    /// Returns a cached thumbnail, or nil and schedules a background render.
    func thumbnail(for document: PDFDocument, index: Int, size: CGSize) -> NSImage? {
        let id = key(document, index, size)
        if let image = cache.object(forKey: id as NSString) { return image }
        guard !inFlight.contains(id), let page = document.page(at: index) else { return nil }
        inFlight.insert(id)

        queue.addOperation { [weak self] in
            let image = page.thumbnail(of: size, for: .mediaBox)
            let cost = Int(size.width * size.height * 4)
            Task { @MainActor in
                guard let self else { return }
                self.cache.setObject(image, forKey: id as NSString, cost: cost)
                self.inFlight.remove(id)
                self.generation &+= 1
            }
        }
        return nil
    }

    /// Drops cached images for a document whose pages changed.
    func invalidate() {
        queue.cancelAllOperations()
        cache.removeAllObjects()
        inFlight.removeAll()
        generation &+= 1
    }
}

/// Page thumbnail that loads asynchronously and never blocks layout.
struct PageThumbnail: View {
    let document: PDFDocument
    let index: Int
    let size: CGSize
    @ObservedObject private var cache = ThumbnailCache.shared

    var body: some View {
        // Reading `generation` subscribes this view to cache updates.
        let _ = cache.generation
        Group {
            if let image = cache.thumbnail(for: document, index: index, size: size) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

import AppKit

/// Persists drawn signatures as PNGs in Application Support.
enum SignatureStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AquaPDF/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func save(_ image: NSImage) throws -> URL {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        let url = directory.appendingPathComponent("signature-\(Int(Date().timeIntervalSince1970)).png")
        try png.write(to: url)
        return url
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

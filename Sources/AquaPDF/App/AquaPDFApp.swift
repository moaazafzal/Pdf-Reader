import SwiftUI

@main
struct AquaPDFApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PDFFileDocument() }) { configuration in
            ContentView(document: configuration.document)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

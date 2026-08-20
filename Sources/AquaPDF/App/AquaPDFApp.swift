import SwiftUI

@main
struct AquaPDFApp: App {
    var body: some Scene {
        // Start dashboard (Foxit-style): shown at launch instead of the open panel.
        Window("Welcome to AquaPDF", id: "start") {
            StartView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.presented)

        DocumentGroup(newDocument: { PDFFileDocument() }) { configuration in
            ContentView(document: configuration.document)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

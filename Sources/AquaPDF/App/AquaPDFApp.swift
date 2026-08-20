import AppKit
import SwiftUI

@main
struct AquaPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: { PDFFileDocument() }) { configuration in
            ContentView(document: configuration.document)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .windowList) {
                Button("Welcome to AquaPDF") { StartWindowController.shared.show() }
            }
        }
    }
}

/// The Start dashboard is an AppKit window so it works back to macOS 11
/// (SwiftUI's `Window` scene and launch-behavior control are macOS 13/15 only).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferencesView.applyAppearance(UserDefaults.standard.string(forKey: "appearanceRaw") ?? "system")
        if UserDefaults.standard.object(forKey: "showStartPage") == nil
            || UserDefaults.standard.bool(forKey: "showStartPage")
        {
            StartWindowController.shared.show()
        }
    }

    /// Suppresses the open panel AppKit would otherwise show at launch.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { StartWindowController.shared.show() }
        return true
    }
}

@MainActor
final class StartWindowController {
    static let shared = StartWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: StartView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to AquaPDF"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
    }
}

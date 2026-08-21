import AppKit
import SwiftUI

/// Menu commands are broadcast as notifications so they reach whichever document
/// window is focused, without the menu needing a reference to its view model.
enum AppCommand: String, CaseIterable {
    case zoomIn, zoomOut, actualSize, fitPage, fitWidth, fitVisible
    case reflow, readMode, textViewer, fullScreen, autoScroll
    case firstPage, lastPage, nextPage, previousPage, goToPage
    case previousView, nextView
    case find, findNext, findPrevious, advancedSearch
    case toggleNavigationPane, toggleProperties
    case organizePages, pageNumbers, preferences, documentProperties
    case singleKeyToolHand, singleKeyToolSelect, singleKeyToolZoom
    case singleKeyToolSnapshot, singleKeyToolHighlight, singleKeyToolTypewriter
    case singleKeyToolNote, singleKeyToolPencil

    var notification: Notification.Name { Notification.Name("AquaPDF.\(rawValue)") }

    func post() {
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

extension View {
    /// Runs `action` whenever the given command is invoked from a menu or key handler.
    func onCommand(_ command: AppCommand, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: command.notification)) { _ in action() }
    }
}

/// Menu bar mirroring Foxit's command set, with Ctrl shortcuts mapped to ⌘ for macOS.
struct AquaPDFCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { AppCommand.zoomIn.post() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { AppCommand.zoomOut.post() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { AppCommand.actualSize.post() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Fit Page") { AppCommand.fitPage.post() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Fit Width") { AppCommand.fitWidth.post() }
                .keyboardShortcut("2", modifiers: .command)
            Button("Fit Visible") { AppCommand.fitVisible.post() }
                .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("Reflow") { AppCommand.reflow.post() }
                .keyboardShortcut("4", modifiers: .command)
            Button("Read Mode") { AppCommand.readMode.post() }
                .keyboardShortcut("h", modifiers: .command)
            Button("Text Viewer") { AppCommand.textViewer.post() }
                .keyboardShortcut("6", modifiers: .command)
            Button("Full Screen") { AppCommand.fullScreen.post() }
                .keyboardShortcut(.f11Key, modifiers: [])
            Button("AutoScroll") { AppCommand.autoScroll.post() }
                .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Button("Navigation Pane") { AppCommand.toggleNavigationPane.post() }
                .keyboardShortcut(.f4Key, modifiers: [])
            Button("Properties Panel") { AppCommand.toggleProperties.post() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandGroup(after: .textEditing) {
            Button("Find") { AppCommand.find.post() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { AppCommand.findNext.post() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { AppCommand.findPrevious.post() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Advanced Search") { AppCommand.advancedSearch.post() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandMenu("Navigate") {
            Button("First Page") { AppCommand.firstPage.post() }
                .keyboardShortcut(.home, modifiers: .command)
            Button("Previous Page") { AppCommand.previousPage.post() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Page") { AppCommand.nextPage.post() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Last Page") { AppCommand.lastPage.post() }
                .keyboardShortcut(.end, modifiers: .command)

            Divider()

            Button("Go to Page…") { AppCommand.goToPage.post() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Previous View") { AppCommand.previousView.post() }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Next View") { AppCommand.nextView.post() }
                .keyboardShortcut(.rightArrow, modifiers: .option)
        }

        CommandMenu("Document") {
            Button("Organize Pages…") { AppCommand.organizePages.post() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Insert Page Numbers…") { AppCommand.pageNumbers.post() }
            Divider()
            Button("Document Properties") { AppCommand.documentProperties.post() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Preferences") { AppCommand.preferences.post() }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}

extension KeyEquivalent {
    /// SwiftUI has no F-key constants; these use the standard function-key scalars.
    static let f4Key = KeyEquivalent(Character(UnicodeScalar(NSF4FunctionKey)!))
    static let f11Key = KeyEquivalent(Character(UnicodeScalar(NSF11FunctionKey)!))
}

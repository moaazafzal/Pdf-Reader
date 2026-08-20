import AppKit
import SwiftUI

/// Live formatting state for the in-place text editor.
@MainActor
final class TextFormatState: ObservableObject {
    @Published var fontName = "Helvetica"
    @Published var fontSize: CGFloat = 14
    @Published var bold = false
    @Published var italic = false
    @Published var color: NSColor = .black

    static let fontNames = ["Helvetica", "Arial", "Times New Roman", "Georgia", "Courier New", "Verdana"]
    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48, 64]

    /// Resolved font at the given point size (page space) with bold/italic traits applied.
    func font(at size: CGFloat) -> NSFont {
        var font = NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
        let manager = NSFontManager.shared
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
}

/// Floating toolbar shown above the in-place text editor (Foxit-style format options).
struct TextFormatBar: View {
    @ObservedObject var state: TextFormatState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .help("Drag the box border to move it")

            Picker("", selection: $state.fontName) {
                ForEach(TextFormatState.fontNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Picker("", selection: $state.fontSize) {
                ForEach(TextFormatState.sizes, id: \.self) { size in
                    Text("\(Int(size))").tag(size)
                }
            }
            .labelsHidden()
            .frame(width: 58)

            Toggle(isOn: $state.bold) {
                Image(systemName: "bold")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $state.italic) {
                Image(systemName: "italic")
            }
            .toggleStyle(.checkbox)

            ColorPicker("", selection: Binding(
                get: { Color.from(state.color) },
                set: { state.color = NSColor.from($0) }
            ))
            .labelsHidden()
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .panelBackground(cornerRadius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .shadow(radius: 4, y: 2)
    }
}

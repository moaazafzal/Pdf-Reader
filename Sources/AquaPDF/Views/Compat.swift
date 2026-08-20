import AppKit
import SwiftUI

// Back-compatible replacements for SwiftUI APIs that require macOS 12–15.
// The app's deployment target is macOS 11 (Big Sur), which covers every Mac
// released from late 2013 onward plus all Apple Silicon models.

/// Stand-in for `ContentUnavailableView` (macOS 14+).
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String?

    init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stand-in for `LabeledContent` (macOS 13+).
struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelectionIfAvailable()
        }
    }
}

extension View {
    /// `.formStyle(.grouped)` is macOS 13+; on Big Sur the default form style is used.
    @ViewBuilder func groupedForm() -> some View {
        if #available(macOS 13, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
    }

    /// `.textSelection(.enabled)` is macOS 12+.
    @ViewBuilder func textSelectionIfAvailable() -> some View {
        if #available(macOS 12, *) {
            self.textSelection(.enabled)
        } else {
            self
        }
    }

    /// Material backgrounds are macOS 12+; Big Sur gets a solid control background.
    @ViewBuilder func panelBackground(cornerRadius: CGFloat = 8) -> some View {
        if #available(macOS 12, *) {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.from(.windowBackgroundColor))
            )
        }
    }

    @ViewBuilder func capsuleBackground() -> some View {
        if #available(macOS 12, *) {
            self.background(.thinMaterial, in: Capsule())
        } else {
            self.background(Capsule().fill(Color.from(.windowBackgroundColor)))
        }
    }

    /// Two-parameter `onChange` is macOS 14+; the single-parameter form works back to macOS 11.
    @ViewBuilder func onValueChange<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        self.onChange(of: value, perform: action)
    }
}

extension NSBezierPath {
    /// `NSBezierPath.cgPath` is macOS 14+; this conversion works back to macOS 10.15.
    var compatCGPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }
}

extension Color {
    /// `Color(nsColor:)` is macOS 12+; building from sRGB components works back to macOS 10.15.
    static func from(_ nsColor: NSColor) -> Color {
        let rgb = nsColor.usingColorSpace(.sRGB) ?? .black
        return Color(
            .sRGB,
            red: rgb.redComponent,
            green: rgb.greenComponent,
            blue: rgb.blueComponent,
            opacity: rgb.alphaComponent
        )
    }
}

extension NSColor {
    /// `NSColor(_ color: Color)` is macOS 12+.
    static func from(_ color: Color) -> NSColor {
        if #available(macOS 12, *) {
            return NSColor(color)
        }
        return NSColor(cgColor: color.cgColorFallback) ?? .black
    }
}

private extension Color {
    /// Rough component extraction for Big Sur, where `NSColor(Color)` does not exist.
    var cgColorFallback: CGColor {
        let mirror = String(describing: self)
        // SwiftUI renders as e.g. "#FF0000FF" or a named color; fall back to black when unparsable.
        if let hash = mirror.firstIndex(of: "#") {
            let hex = String(mirror[mirror.index(after: hash)...].prefix(8))
            if hex.count >= 6, let value = Int(hex.prefix(6), radix: 16) {
                let alpha = hex.count == 8 ? CGFloat(Int(hex.suffix(2), radix: 16) ?? 255) / 255 : 1
                return CGColor(
                    srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: alpha
                )
            }
        }
        return CGColor(gray: 0, alpha: 1)
    }
}

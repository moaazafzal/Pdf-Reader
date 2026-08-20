import AppKit
import SwiftUI

/// Freehand stroke preview. SwiftUI's `Canvas` is macOS 12+, so this draws through AppKit.
struct InkCanvas: NSViewRepresentable {
    let strokes: [[CGPoint]]
    let currentStroke: [CGPoint]

    final class StrokeView: NSView {
        var strokes: [[CGPoint]] = []
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setStroke()
            for stroke in strokes where stroke.count > 1 {
                let path = NSBezierPath()
                path.lineWidth = 2.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: stroke[0])
                for point in stroke.dropFirst() { path.line(to: point) }
                path.stroke()
            }
        }
    }

    func makeNSView(context: Context) -> StrokeView { StrokeView() }

    func updateNSView(_ view: StrokeView, context: Context) {
        view.strokes = strokes + (currentStroke.isEmpty ? [] : [currentStroke])
        view.needsDisplay = true
    }
}

/// Sheet for drawing, saving, and picking signatures.
struct SignatureManagerView: View {
    @Environment(\.presentationMode) private var presentation
    var onPick: (NSImage) -> Void

    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @State private var saved: [URL] = SignatureStore.list()

    private let canvasSize = CGSize(width: 420, height: 160)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draw Signature")
                .font(.headline)

            InkCanvas(strokes: strokes, currentStroke: currentStroke)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in currentStroke.append(value.location) }
                        .onEnded { _ in
                            if currentStroke.count > 1 { strokes.append(currentStroke) }
                            currentStroke = []
                        }
                )

            HStack {
                Button("Clear") { strokes = []; currentStroke = [] }
                Spacer()
                Button("Save & Use") {
                    if let image = renderImage() {
                        _ = try? SignatureStore.save(image)
                        onPick(image)
                        presentation.wrappedValue.dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strokes.isEmpty)
            }

            if !saved.isEmpty {
                Divider()
                Text("Saved Signatures")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(saved, id: \.self) { url in
                            if let image = NSImage(contentsOf: url) {
                                VStack(spacing: 4) {
                                    Button {
                                        onPick(image)
                                        presentation.wrappedValue.dismiss()
                                    } label: {
                                        Image(nsImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 120, height: 45)
                                            .background(Color.white)
                                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                                    }
                                    .buttonStyle(.plain)
                                    Button("Delete") {
                                        SignatureStore.delete(url)
                                        saved = SignatureStore.list()
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
                .frame(height: 80)
            }

            HStack {
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private func renderImage() -> NSImage? {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in all {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let pad: CGFloat = 6
        let rect = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        guard rect.width > 2, rect.height > 2 else { return nil }

        let image = NSImage(size: rect.size)
        image.lockFocus()
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: rect.size).fill()
        NSColor.black.setStroke()
        for stroke in strokes {
            guard stroke.count > 1 else { continue }
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // Canvas coords are top-left origin; NSImage draws bottom-left. Flip Y.
            func flip(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x - rect.origin.x, y: rect.size.height - (p.y - rect.origin.y))
            }
            path.move(to: flip(stroke[0]))
            for p in stroke.dropFirst() { path.line(to: flip(p)) }
            path.stroke()
        }
        image.unlockFocus()
        return image
    }
}

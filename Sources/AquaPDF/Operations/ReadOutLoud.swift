import AVFoundation
import PDFKit

/// Text-to-speech reading of PDF pages (Foxit's "Read Out Loud").
@MainActor
final class ReadOutLoud: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published var volume: Float = 1

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func readPage(_ page: PDFPage?) {
        guard let text = page?.string, !text.isEmpty else { return }
        speak([text])
    }

    func readFrom(page index: Int, in document: PDFDocument) {
        guard index >= 0, index < document.pageCount else { return }
        let texts = (index..<document.pageCount).compactMap { document.page(at: $0)?.string }
        speak(texts.filter { !$0.isEmpty })
    }

    private func speak(_ texts: [String]) {
        stop()
        guard !texts.isEmpty else { return }
        for text in texts {
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            utterance.volume = volume
            utterance.postUtteranceDelay = 0.2
            synthesizer.speak(utterance)
        }
        isSpeaking = true
        isPaused = false
    }

    func togglePause() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else if isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
    }
}

extension ReadOutLoud: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            isSpeaking = false
            isPaused = false
        }
    }
}

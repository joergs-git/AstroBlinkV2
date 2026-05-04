// AIsaac — Speech-to-text and text-to-speech for voice interaction
// Uses macOS built-in SFSpeechRecognizer (offline on Apple Silicon) and AVSpeechSynthesizer
import Foundation
import Speech
import AVFoundation

@MainActor
class AIsaacSpeechManager: ObservableObject {
    @Published var isListening: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var transcribedText: String = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    init() {
        // Use device locale for speech recognition
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        checkAuthorization()
    }

    // MARK: - Authorization

    private func checkAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.isAuthorized = (status == .authorized)
            }
        }
    }

    // MARK: - Speech-to-Text (hold to talk)

    func startListening() {
        guard isAuthorized, !isListening else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil
        transcribedText = ""

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }

        // On-device recognition if available (Apple Silicon)
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }
        request.shouldReportPartialResults = true

        // Configure audio session
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            print("[AIsaac Speech] Audio engine failed to start: \(error)")
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let result = result {
                    self.transcribedText = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal == true) {
                    // Recognition ended
                }
            }
        }
    }

    func stopListening() -> String {
        guard isListening else { return transcribedText }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        isListening = false
        recognitionRequest = nil
        recognitionTask = nil

        return transcribedText
    }

    // MARK: - Text-to-Speech

    func speak(_ text: String) {
        // Strip markdown formatting for natural speech
        let cleanText = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "```command", with: "")
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "#", with: "")

        let utterance = AVSpeechUtterance(string: cleanText)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1  // slightly faster
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.8

        // Try to match the user's locale for voice
        if let voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en") {
            utterance.voice = voice
        }

        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        synthesizer.speak(utterance)

        // Monitor when speech ends. Poll on the main actor so the
        // @MainActor-isolated synthesizer is read on its own actor (Swift 6
        // strict concurrency). Sleep happens on a background executor.
        Task { [weak self] in
            while await MainActor.run(body: { self?.synthesizer.isSpeaking ?? false }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run { [weak self] in
                self?.isSpeaking = false
            }
        }
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

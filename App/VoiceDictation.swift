import AVFoundation
import Observation
import Speech

/// Speak instead of typing in the command bar. Recognition runs on this Mac only:
/// if the on-device model isn't there for your language, it refuses rather than using Apple's servers.
@MainActor
@Observable
final class VoiceDictation {
    private(set) var isListening = false
    private(set) var transcript = ""
    private(set) var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isListening { stop() } else { Task { await start() } }
    }

    func start() async {
        error = nil
        transcript = ""
        guard await Self.authorize() else {
            error = "Allow Microphone and Speech Recognition for keybro in System Settings."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else {
            error = "On-device dictation isn't available for this language. Download it in System Settings, Keyboard, Dictation."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if done { self.stop() }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isListening = false
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

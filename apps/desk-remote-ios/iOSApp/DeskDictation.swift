import AVFoundation
import Speech
import SwiftUI

/// Speech to text into the message box (Traditional Chinese), without bringing up the keyboard:
/// tap the microphone to start, tap again to stop. What is heard appears in the box as it is
/// recognised, after anything already typed.
@MainActor
final class DeskDictation: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var failure: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Results still go into the box: true until the final one after a stop, false after a cancel.
    private var accepting = false
    private var typed = ""

    func toggle(_ text: Binding<String>) {
        if listening {
            stop()
        } else {
            Task { await start(text) }
        }
    }

    private func start(_ text: Binding<String>) async {
        failure = nil
        guard await Self.allowed() else {
            failure = "請到「設定」允許桌面遙控使用麥克風與語音辨識"
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")), recognizer.isAvailable else {
            failure = "語音辨識現在不能用（可能沒有網路）"
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            failure = "麥克風打不開"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        Self.feed(input, into: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            failure = "麥克風打不開"
            return
        }
        typed = text.wrappedValue
        self.request = request
        accepting = true
        listening = true
        task = Self.recognize(recognizer, request) { [weak self] spoken, done in
            Task { @MainActor in
                guard let self, self.accepting else { return }
                if let spoken { text.wrappedValue = self.typed + spoken }
                if done {
                    self.accepting = false
                    self.stop()
                }
            }
        }
    }

    // The microphone tap and the recogniser call back on their own threads: set up outside the
    // main actor, and hand only plain values back.
    nonisolated private static func feed(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              _ heard: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            heard(result?.bestTranscription.formattedString, error != nil || result?.isFinal == true)
        }
    }

    /// Stops listening; the last words still arrive in the box.
    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops and drops what has not arrived yet (the message is being sent).
    func cancel() {
        accepting = false
        stop()
    }

    nonisolated private static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

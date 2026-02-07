import AVFoundation

final class AudioRecorder {
    enum State {
        case idle
        case recording
    }

    private(set) var state: State = .idle
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var fileURL: URL?

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    func startRecording() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Write standard 16-bit interleaved PCM WAV that Whisper can decode
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: nativeFormat.sampleRate,
            AVNumberOfChannelsKey: nativeFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(UUID().uuidString + ".wav")

        // File on disk: 16-bit interleaved PCM; processing format: native tap format
        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: nativeFormat.commonFormat,
            interleaved: nativeFormat.isInterleaved
        ) else {
            return
        }

        self.engine = engine
        self.audioFile = file
        self.fileURL = url

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
            try? file.write(from: buffer)
        }

        do {
            try engine.start()
            state = .recording
        } catch {
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            self.audioFile = nil
            self.fileURL = nil
        }
    }

    func stopRecording() -> URL? {
        guard state == .recording, let engine = engine else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let url = fileURL
        self.engine = nil
        self.audioFile = nil
        self.fileURL = nil
        state = .idle

        return url
    }
}

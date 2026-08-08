import SwiftUI
import ScreenCaptureKit
import CoreML

// Spike 004: app shell. A real SwiftUI window app that:
// 1. Records screen + system audio + mic via ScreenCaptureKit (SCRecordingOutput)
// 2. Transcribes with Parakeet TDT CoreML models (from spike 003)
// 3. Shows the transcript in the window

// ---------- Capture ----------

class CaptureManager: NSObject, SCRecordingOutputDelegate, ObservableObject {
    @Published var isRecording = false
    @Published var status = "Ready"
    @Published var lastFile: String?
    @Published var lastTranscript = ""
    @Published var isTranscribing = false

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var started = false
    private var finished = false

    static let recordingsDir: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let modelsDir: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpikeMeetingLogger/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    static let hasMic: Bool = {
        AVCaptureDevice.default(for: .audio) != nil
    }()

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = Self.recordingsDir.appendingPathComponent("meeting_\(formatter.string(from: Date())).mp4")
        outputURL = url

        Task {
            do {
                try await startCapture(to: url)
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.status = "Recording to \(url.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startCapture(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 6
        config.showsCursor = false
        config.capturesAudio = true
        config.captureMicrophone = CaptureManager.hasMic
        config.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: nil)

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.videoCodecType = .h264
        recConfig.outputFileType = .mp4
        let recOutput = SCRecordingOutput(configuration: recConfig, delegate: self)
        try s.addRecordingOutput(recOutput)
        self.stream = s
        self.recordingOutput = recOutput
        started = false
        try await s.startCapture()
    }

    func stop() {
        guard let stream, let url = outputURL else { return }
        Task {
            do {
                try await stream.stopCapture()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.status = "Saved: \(url.lastPathComponent)"
                    self.lastFile = url.path
                    self.transcribe(url.path)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.status = "Stop error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: SCRecordingOutputDelegate
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        started = true
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished = true
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.status = "Recording failed: \(error.localizedDescription)"
        }
    }

    // MARK: Transcription (spike 003 pipeline, simplified)
    private func transcribe(_ filePath: String) {
        DispatchQueue.main.async { self.isTranscribing = true }
        Task.detached {
            do {
                let text = try await ParakeetTranscriber.shared.transcribe(filePath: filePath)
                DispatchQueue.main.async {
                    self.lastTranscript = text
                    self.isTranscribing = false
                    self.status = "Transcribed"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isTranscribing = false
                    self.status = "Transcribe error: \(error.localizedDescription)"
                }
            }
        }
    }
}

// ---------- Transcription (from spike 003) ----------

final class ParakeetTranscriber {
    static let shared = ParakeetTranscriber()
    private var models: [String: MLModel] = [:]
    private var vocab: [String: String] = [:]

    private func load() throws {
        guard models.isEmpty else { return }
        let dir = CaptureManager.modelsDir
        let names = ["Preprocessor", "Encoder", "Decoder", "JointDecision"]
        for name in names {
            models[name] = try MLModel(contentsOf: URL(fileURLWithPath: dir + "/\(name).mlmodelc"))
        }
        let vd = try Data(contentsOf: URL(fileURLWithPath: dir + "/parakeet_vocab.json"))
        vocab = try JSONSerialization.jsonObject(with: vd) as! [String: String]
    }

    func transcribe(filePath: String) async throws -> String {
        try load()
        // convert to 16k mono wav via AVFoundation
        let wavPath = NSTemporaryDirectory() + "spike_\(UUID().uuidString).wav"
        try await convertToWav(src: filePath, dst: wavPath)
        let audio = try readWavSamples(wavPath)
        try? FileManager.default.removeItem(atPath: wavPath)

        // chunk 15s, pad last with silence
        let chunkSamples = 16000 * 15
        var chunks: [[Int16]] = []
        var i = 0
        while i < audio.count {
            let end = min(i + chunkSamples, audio.count)
            var chunk = Array(audio[i..<end])
            if chunk.count < chunkSamples {
                chunk.append(contentsOf: [Int16](repeating: 0, count: chunkSamples - chunk.count))
            }
            chunks.append(chunk)
            i += chunkSamples
        }

        var full = ""
        for chunk in chunks {
            let (mel, melLen) = try preprocess(audio: chunk)
            let (enc, encLen) = try encode(mel: mel, melLength: melLen)
            full += try decode(enc: enc, encLen: encLen) + " "
        }
        return full.trimmingCharacters(in: .whitespaces)
    }

    private func preprocess(audio: [Int16]) throws -> (MLMultiArray, Int) {
        let n = audio.count
        var fa = [Float](repeating: 0, count: n)
        for (i, s) in audio.enumerated() { fa[i] = Float(s) / 32768.0 }
        let audioArr = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
        memcpy(audioArr.dataPointer, &fa, n * 4)
        let lenArr = try MLMultiArray(shape: [1], dataType: .int32)
        lenArr[0] = NSNumber(value: n)
        let out = try models["Preprocessor"]!.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioArr),
            "audio_length": MLFeatureValue(multiArray: lenArr),
        ]))
        let mel = out.featureValue(for: "mel")!.multiArrayValue!
        let melLen = out.featureValue(for: "mel_length")!.multiArrayValue![0].intValue
        let frames = mel.shape[2].intValue
        let padded = try MLMultiArray(shape: [1, 128, 1501], dataType: .float32)
        let src = mel.dataPointer.bindMemory(to: Float.self, capacity: 128 * frames)
        let dst = padded.dataPointer.bindMemory(to: Float.self, capacity: 128 * 1501)
        memcpy(dst, src, 128 * frames * 4)
        if frames < 1501 {
            let lc = frames > 0 ? frames - 1 : 0
            var colSum: Double = 0
            for d in 0..<128 { colSum += Double(src[d * frames + lc]) }
            let fill = Float(colSum / 128.0)
            for k in (128 * frames)..<(128 * 1501) { dst[k] = fill }
        }
        return (padded, melLen)
    }

    private func encode(mel: MLMultiArray, melLength: Int) throws -> (MLMultiArray, Int) {
        let lenArr = try MLMultiArray(shape: [1], dataType: .int32)
        lenArr[0] = NSNumber(value: melLength)
        let out = try models["Encoder"]!.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: lenArr),
        ]))
        let enc = out.featureValue(for: "encoder")!.multiArrayValue!
        let encLen = out.featureValue(for: "encoder_length")!.multiArrayValue![0].intValue
        return (enc, encLen)
    }

    private func decoderStep(target: Int32, hIn: MLMultiArray, cIn: MLMultiArray) throws -> (MLMultiArray, MLMultiArray, MLMultiArray) {
        let t = try MLMultiArray(shape: [1, 1], dataType: .int32)
        t[0] = NSNumber(value: target)
        let tl = try MLMultiArray(shape: [1], dataType: .int32)
        tl[0] = NSNumber(value: 1)
        let out = try models["Decoder"]!.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: t),
            "target_length": MLFeatureValue(multiArray: tl),
            "h_in": MLFeatureValue(multiArray: hIn),
            "c_in": MLFeatureValue(multiArray: cIn),
        ]))
        return (
            out.featureValue(for: "decoder")!.multiArrayValue!,
            out.featureValue(for: "h_out")!.multiArrayValue!,
            out.featureValue(for: "c_out")!.multiArrayValue!
        )
    }

    private func jointStep(encStep: MLMultiArray, decStep: MLMultiArray) throws -> (Int32, Int32) {
        let out = try models["JointDecision"]!.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encStep),
            "decoder_step": MLFeatureValue(multiArray: decStep),
        ]))
        let token = out.featureValue(for: "token_id")!.multiArrayValue![0].int32Value
        let dur = out.featureValue(for: "duration")!.multiArrayValue![0].int32Value
        return (token, dur)
    }

    private func sliceFrame(_ arr: MLMultiArray, _ index: Int) throws -> MLMultiArray {
        let D = arr.shape[1].intValue
        let sd = arr.strides[1].intValue
        let st = arr.strides[2].intValue
        let result = try MLMultiArray(shape: [1, NSNumber(value: D), 1], dataType: .float32)
        let src = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        let dst = result.dataPointer.bindMemory(to: Float.self, capacity: D)
        for d in 0..<D { dst[d] = src[d * sd + index * st] }
        return result
    }

    private func decode(enc: MLMultiArray, encLen: Int) throws -> String {
        let blank: Int32 = 1024
        let h = try MLMultiArray(shape: [2, 1, 640], dataType: .float32)
        let c = try MLMultiArray(shape: [2, 1, 640], dataType: .float32)
        memset(h.dataPointer, 0, h.count * 4)
        memset(c.dataPointer, 0, c.count * 4)
        var (decStep, hP, cP) = try decoderStep(target: blank, hIn: h, cIn: c)
        memcpy(h.dataPointer, hP.dataPointer, hP.count * 4)
        memcpy(c.dataPointer, cP.dataPointer, cP.count * 4)

        var tokens: [Int32] = []
        var t = 0
        var tokensThisFrame = 0
        while t < encLen {
            let encStep = try sliceFrame(enc, t)
            let (token, dur) = try jointStep(encStep: encStep, decStep: decStep)
            if token != blank {
                tokens.append(token)
                tokensThisFrame += 1
                let (d3, h3, c3) = try decoderStep(target: token, hIn: h, cIn: c)
                decStep = d3
                memcpy(h.dataPointer, h3.dataPointer, h3.count * 4)
                memcpy(c.dataPointer, c3.dataPointer, c3.count * 4)
            }
            if dur > 0 { tokensThisFrame = 0 }
            if tokensThisFrame >= 5 {
                tokensThisFrame = 0
                t += 1
            } else if token == blank && dur == 0 {
                t += 1
            } else {
                t += Int(dur)
            }
        }
        var text = ""
        for tok in tokens {
            if let piece = vocab[String(tok)] {
                text += piece.replacingOccurrences(of: "▁", with: " ")
            }
        }
        return text
    }

    private func convertToWav(src: String, dst: String) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio track"]) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        reader.startReading()
        var pcm = Data()
        while let sb = out.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sb) {
                var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data)
                pcm.append(contentsOf: data)
            }
        }
        reader.cancelReading()
        // write WAV (44-byte header, PCM16 mono 16k)
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        withUnsafeBytes(of: UInt32(36 + pcm.count).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        withUnsafeBytes(of: UInt32(16).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(16000).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(32000).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(2).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(16).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: Array("data".utf8))
        withUnsafeBytes(of: UInt32(pcm.count).littleEndian) { header.append(contentsOf: $0) }
        try (header + pcm).write(to: URL(fileURLWithPath: dst))
    }


    private func readWavSamples(_ path: String) throws -> [Int16] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

// ---------- UI ----------

struct ContentView: View {
    @StateObject var capture = CaptureManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Logger").font(.title2.bold())
            Text(capture.status).font(.callout).foregroundColor(.secondary)

            Button(capture.isRecording ? "Stop Recording" : "Start Recording") {
                capture.toggle()
            }
            .buttonStyle(.borderedProminent)
            .tint(capture.isRecording ? .red : .blue)

            if capture.isTranscribing {
                ProgressView("Transcribing locally...").controlSize(.small)
            }

            if !capture.lastTranscript.isEmpty {
                Text("Transcript").font(.headline)
                ScrollView {
                    Text(capture.lastTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
            }
            if let file = capture.lastFile {
                Text("Saved: \(file)").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }
}

@main
struct MeetingLoggerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

import Foundation
import CoreML
import AVFoundation

final class Transcriber {
    static let shared = Transcriber()

    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var vocab: [String: String] = [:]
    private var loaded = false

    static let modelsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Counterfoil/Models", isDirectory: true)
        return dir
    }()

    static let sourceModelsDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpikeMeetingLogger/Models", isDirectory: true)
    }()

    var modelsAvailable: Bool {
        let fm = FileManager.default
        let names = ["Preprocessor", "Encoder", "Decoder", "JointDecision"]
        let dir = Self.modelsDir
        for name in names {
            if !fm.fileExists(atPath: dir.appendingPathComponent("\(name).mlmodelc").path) {
                return false
            }
        }
        return fm.fileExists(atPath: dir.appendingPathComponent("parakeet_vocab.json").path)
    }

    var modelsMissingReason: String {
        let fm = FileManager.default
        let dir = Self.modelsDir
        var missing: [String] = []
        for name in ["Preprocessor", "Encoder", "Decoder", "JointDecision"] {
            if !fm.fileExists(atPath: dir.appendingPathComponent("\(name).mlmodelc").path) {
                missing.append("\(name).mlmodelc")
            }
        }
        if !fm.fileExists(atPath: dir.appendingPathComponent("parakeet_vocab.json").path) {
            missing.append("parakeet_vocab.json")
        }
        if missing.isEmpty { return "" }
        return "Missing: \(missing.joined(separator: ", "))"
    }

    func preloadModels() async {
        if loaded { return }
        let fm = FileManager.default
        let dest = Self.modelsDir
        let src = Self.sourceModelsDir

        if !fm.fileExists(atPath: dest.path) || ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).isEmpty {
            if fm.fileExists(atPath: src.path) {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                if let items = try? fm.contentsOfDirectory(atPath: src.path) {
                    for item in items {
                        let s = src.appendingPathComponent(item)
                        let d = dest.appendingPathComponent(item)
                        try? fm.removeItem(at: d)
                        try? fm.copyItem(at: s, to: d)
                    }
                }
            }
        }

        guard modelsAvailable else { return }

        do {
            preprocessor = try MLModel(contentsOf: dest.appendingPathComponent("Preprocessor.mlmodelc"))
            encoder = try MLModel(contentsOf: dest.appendingPathComponent("Encoder.mlmodelc"))
            decoder = try MLModel(contentsOf: dest.appendingPathComponent("Decoder.mlmodelc"))
            joint = try MLModel(contentsOf: dest.appendingPathComponent("JointDecision.mlmodelc"))

            let vocabData = try Data(contentsOf: dest.appendingPathComponent("parakeet_vocab.json"))
            vocab = try JSONSerialization.jsonObject(with: vocabData) as! [String: String]
            loaded = true
        } catch {
            print("model preload error: \(error)")
            loaded = false
        }
    }

    func transcribe(filePath: String, startTime: Date) async throws -> String {
        if !loaded { try await forceLoad() }

        let wavPath = NSTemporaryDirectory() + "counterfoil_\(UUID().uuidString).wav"
        try await convertTo16kMono(src: filePath, dst: wavPath)
        defer { try? FileManager.default.removeItem(atPath: wavPath) }

        let audio = try readWavSamples(wavPath)
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

        var fullText = ""
        for (ci, chunk) in chunks.enumerated() {
            let (mel, melLen) = try preprocess(audio: chunk)
            let (enc, encLen) = try encode(mel: mel, melLength: melLen)
            let text = try decode(enc: enc, encLen: encLen)
            let secOffset = Double(ci * 15)
            let timestamp = startTime.addingTimeInterval(secOffset)
            let ts = formatTimestamp(timestamp)
            if !text.isEmpty {
                fullText += "[\(ts)] \(text)\n"
            }
        }
        return applyPostProcessing(fullText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func forceLoadSync() throws {
        let fm = FileManager.default
        let dest = Self.modelsDir
        let src = Self.sourceModelsDir

        if !fm.fileExists(atPath: dest.path) {
            if fm.fileExists(atPath: src.path) {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                if let items = try? fm.contentsOfDirectory(atPath: src.path) {
                    for item in items {
                        let s = src.appendingPathComponent(item)
                        let d = dest.appendingPathComponent(item)
                        try? fm.removeItem(at: d)
                        try? fm.copyItem(at: s, to: d)
                    }
                }
            }
        }

        guard modelsAvailable else {
            throw NSError(domain: "transcribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Models not available. Copy from SpikeMeetingLogger/Models to \(dest.path)"])
        }

        preprocessor = try MLModel(contentsOf: dest.appendingPathComponent("Preprocessor.mlmodelc"))
        encoder = try MLModel(contentsOf: dest.appendingPathComponent("Encoder.mlmodelc"))
        decoder = try MLModel(contentsOf: dest.appendingPathComponent("Decoder.mlmodelc"))
        joint = try MLModel(contentsOf: dest.appendingPathComponent("JointDecision.mlmodelc"))

        let vocabData = try Data(contentsOf: dest.appendingPathComponent("parakeet_vocab.json"))
        vocab = try JSONSerialization.jsonObject(with: vocabData) as! [String: String]
        loaded = true
    }

    func forceLoad() async throws {
        try forceLoadSync()
    }

    func transcribeTest(path: String) throws -> String {
        let audio = try readWavSamples(path)
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
        var fullText = ""
        for chunk in chunks {
            let (mel, melLen) = try preprocess(audio: chunk)
            let (enc, encLen) = try encode(mel: mel, melLength: melLen)
            fullText += try decode(enc: enc, encLen: encLen) + " "
        }
        return applyPostProcessing(fullText.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Preprocessing

    private func preprocess(audio: [Int16]) throws -> (MLMultiArray, Int) {
        guard let m = preprocessor else {
            throw NSError(domain: "transcribe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Preprocessor not loaded"])
        }
        let n = audio.count
        var fa = [Float](repeating: 0, count: n)
        for (i, s) in audio.enumerated() { fa[i] = Float(s) / 32768.0 }

        let audioArr = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
        memcpy(audioArr.dataPointer, &fa, n * 4)
        let lenArr = try MLMultiArray(shape: [1], dataType: .int32)
        lenArr[0] = NSNumber(value: n)

        let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: [
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
            let lastCol = frames > 0 ? frames - 1 : 0
            var colSum: Double = 0
            for d in 0..<128 { colSum += Double(src[d * frames + lastCol]) }
            let fill = Float(colSum / 128.0)
            for k in (128 * frames)..<(128 * 1501) { dst[k] = fill }
        }
        return (padded, melLen)
    }

    // MARK: Encoder

    private func encode(mel: MLMultiArray, melLength: Int) throws -> (MLMultiArray, Int) {
        guard let m = encoder else {
            throw NSError(domain: "transcribe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Encoder not loaded"])
        }
        let lenArr = try MLMultiArray(shape: [1], dataType: .int32)
        lenArr[0] = NSNumber(value: melLength)
        let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: lenArr),
        ]))
        let enc = out.featureValue(for: "encoder")!.multiArrayValue!
        let encLen = out.featureValue(for: "encoder_length")!.multiArrayValue![0].intValue
        return (enc, encLen)
    }

    // MARK: Decoder step

    private func decoderStep(target: Int32, hIn: MLMultiArray, cIn: MLMultiArray) throws
        -> (dec: MLMultiArray, hOut: MLMultiArray, cOut: MLMultiArray) {
        guard let m = decoder else {
            throw NSError(domain: "transcribe", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Decoder not loaded"])
        }
        let t = try MLMultiArray(shape: [1, 1], dataType: .int32)
        t[0] = NSNumber(value: target)
        let tl = try MLMultiArray(shape: [1], dataType: .int32)
        tl[0] = NSNumber(value: 1)
        let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: [
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

    // MARK: Joint step

    private func jointStep(encStep: MLMultiArray, decStep: MLMultiArray) throws
        -> (token: Int32, duration: Int32) {
        guard let m = joint else {
            throw NSError(domain: "transcribe", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Joint not loaded"])
        }
        let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encStep),
            "decoder_step": MLFeatureValue(multiArray: decStep),
        ]))
        let token = out.featureValue(for: "token_id")!.multiArrayValue![0].int32Value
        let dur = out.featureValue(for: "duration")!.multiArrayValue![0].int32Value
        return (token, dur)
    }

    // MARK: Encoder frame slice

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

    // MARK: TDT greedy decode

    private func decode(enc: MLMultiArray, encLen: Int) throws -> String {
        let blank: Int32 = 1024
        let D = 640
        let h = try MLMultiArray(shape: [2, 1, NSNumber(value: D)], dataType: .float32)
        let c = try MLMultiArray(shape: [2, 1, NSNumber(value: D)], dataType: .float32)
        memset(h.dataPointer, 0, h.count * 4)
        memset(c.dataPointer, 0, c.count * 4)

        var (decStep, hP, cP) = try decoderStep(target: blank, hIn: h, cIn: c)
        memcpy(h.dataPointer, hP.dataPointer, hP.count * 4)
        memcpy(c.dataPointer, cP.dataPointer, cP.count * 4)

        var tokens: [Int32] = []
        var t = 0
        var tokensThisFrame = 0
        let maxTokensPerFrame = 5

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

            if tokensThisFrame >= maxTokensPerFrame {
                tokensThisFrame = 0
                t += 1
            } else if token == blank && dur == 0 {
                t += 1
            } else if token != blank && dur == 0 {
                // multiple tokens per frame allowed, do not advance
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
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Audio conversion

    private func convertTo16kMono(src: String, dst: String) async throws {
        let url = URL(fileURLWithPath: src)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            let ext = url.pathExtension.lowercased()
            if ext == "m4a" {
                let audioAsset = AVURLAsset(url: url)
                let m4aReader = try AVAssetReader(asset: audioAsset)
                let m4aTracks = try await audioAsset.loadTracks(withMediaType: .audio)
                guard let m4aTrack = m4aTracks.first else {
                    throw NSError(domain: "transcribe", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "No audio track"])
                }
                let output = AVAssetReaderTrackOutput(track: m4aTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                m4aReader.add(output)
                m4aReader.startReading()
                var pcm = Data()
                while let sb = output.copyNextSampleBuffer() {
                    if let block = CMSampleBufferGetDataBuffer(sb) {
                        var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data)
                        pcm.append(contentsOf: data)
                    }
                }
                m4aReader.cancelReading()
                try writeWav(path: dst, pcm: pcm)
                return
            }
            throw NSError(domain: "transcribe", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track"])
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var pcm = Data()
        while let sb = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sb) {
                var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data)
                pcm.append(contentsOf: data)
            }
        }
        reader.cancelReading()
        try writeWav(path: dst, pcm: pcm)
    }

    private func writeWav(path: String, pcm: Data) throws {
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
        try (header + pcm).write(to: URL(fileURLWithPath: path))
    }

    private func readWavSamples(_ path: String) throws -> [Int16] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Parse RIFF chunks to find data offset (handle metadata chunks after fmt)
        guard data.count > 12, data[0] == 0x52, data[1] == 0x49 else {
            return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(data: data[offset..<offset+4], encoding: .ascii) ?? "?"
            let size = data.withUnsafeBytes { buf in
                buf.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
            }
            if id == "data" {
                let payloadStart = offset + 8
                return data.dropFirst(payloadStart).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            }
            offset += 8 + Int(size) + (Int(size) % 2)
        }
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

func formatTimestamp(_ date: Date) -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    return df.string(from: date)
}

// MARK: Post-processing (filler stripping + vocabulary)

extension Transcriber {
    static func stripFillers(_ text: String) -> String {
        let fillers = ["uh-huh", "uh huh", "um", "uh", "erm", "er", "hmm", "mm", "mhm"]
        let pattern = "\\b(" + fillers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let result = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let collapsed = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return collapsed.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func applyVocabulary(_ text: String, pairs: [(String, String)]) -> String {
        guard !pairs.isEmpty else { return text }
        var result = text
        for (from, to) in pairs {
            guard !from.isEmpty, !to.isEmpty else { continue }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: to)
        }
        return result
    }

    private func applyPostProcessing(_ text: String) -> String {
        var processed = Self.stripFillers(text)
        let pairs = SettingsStore.shared.vocabularyPairs
        if !pairs.isEmpty {
            processed = Self.applyVocabulary(processed, pairs: pairs.map { ($0.from, $0.to) })
        }
        return processed
    }
}

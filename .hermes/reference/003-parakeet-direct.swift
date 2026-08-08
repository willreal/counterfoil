import Foundation
import CoreML
import AVFoundation

// Spike 003: drive Parakeet TDT 0.6b v2 CoreML models directly (no Spokenly)
// Usage: parakeet-cli <model-dir> <wav-16k-mono-int16> [--debug]
// TDT decode ported from sherpa-onnx offline-transducer-greedy-search-nemo-decoder.cc (DecodeOneTDT).

var DEBUG = false

struct ModelDir {
    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let joint: MLModel

    init(path: String) throws {
        preprocessor = try MLModel(contentsOf: URL(fileURLWithPath: path + "/Preprocessor.mlmodelc"))
        encoder = try MLModel(contentsOf: URL(fileURLWithPath: path + "/Encoder.mlmodelc"))
        decoder = try MLModel(contentsOf: URL(fileURLWithPath: path + "/Decoder.mlmodelc"))
        joint = try MLModel(contentsOf: URL(fileURLWithPath: path + "/JointDecision.mlmodelc"))
        print("loaded 4 models")
    }

    func preprocess(audio: [Int16]) throws -> (mel: MLMultiArray, melLength: Int) {
        let n = audio.count
        var floatAudio = [Float](repeating: 0, count: n)
        for (i, s) in audio.enumerated() {
            floatAudio[i] = Float(s) / 32768.0
        }
        let audioArr = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
        memcpy(audioArr.dataPointer, &floatAudio, n * MemoryLayout<Float>.size)
        let lenArr = try MLMultiArray(shape: [1], dataType: .int32)
        lenArr[0] = NSNumber(value: n)

        let out = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioArr),
            "audio_length": MLFeatureValue(multiArray: lenArr),
        ]))
        let mel = out.featureValue(for: "mel")!.multiArrayValue!
        let melLen = out.featureValue(for: "mel_length")!.multiArrayValue![0].intValue
        // encoder expects fixed (1, 128, 1501): pad mel with silence-value (mean of real mel) not zeros
        let padded = try MLMultiArray(shape: [1, 128, 1501], dataType: .float32)
        let frames = mel.shape[2].intValue
        let src = mel.dataPointer.bindMemory(to: Float.self, capacity: 128 * frames)
        let dst = padded.dataPointer.bindMemory(to: Float.self, capacity: 128 * 1501)
        memcpy(dst, src, 128 * frames * MemoryLayout<Float>.size)
        if frames < 1501 {
            // fill padding with the mean of the last real mel column (silence-like)
            let lastCol = (frames > 0 ? frames - 1 : 0)
            var colSum: Double = 0
            for d in 0..<128 { colSum += Double(src[d * frames + lastCol]) }
            let fill = Float(colSum / 128.0)
            for i in (128 * frames)..<(128 * 1501) { dst[i] = fill }
        }
        return (padded, melLen)
    }

    func encode(mel: MLMultiArray, melLength: Int) throws -> (enc: MLMultiArray, encLen: Int) {
        let lenArr = try MLMultiArray(shape: [1], dataType: .int32)
        lenArr[0] = NSNumber(value: melLength)
        let out = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: lenArr),
        ]))
        let enc = out.featureValue(for: "encoder")!.multiArrayValue!
        let encLen = out.featureValue(for: "encoder_length")!.multiArrayValue![0].intValue
        return (enc, encLen)
    }

    func decoderStep(target: Int32, hIn: MLMultiArray, cIn: MLMultiArray) throws
        -> (dec: MLMultiArray, hOut: MLMultiArray, cOut: MLMultiArray) {
        let t = try MLMultiArray(shape: [1, 1], dataType: .int32)
        t[0] = NSNumber(value: target)
        let tl = try MLMultiArray(shape: [1], dataType: .int32)
        tl[0] = NSNumber(value: 1)
        let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
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

    func jointStep(encStep: MLMultiArray, decStep: MLMultiArray) throws -> (token: Int32, duration: Int32, prob: Float) {
        let out = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encStep),
            "decoder_step": MLFeatureValue(multiArray: decStep),
        ]))
        let token = out.featureValue(for: "token_id")!.multiArrayValue![0].int32Value
        let duration = out.featureValue(for: "duration")!.multiArrayValue![0].int32Value
        let prob = out.featureValue(for: "token_prob")!.multiArrayValue![0].floatValue
        return (token, duration, prob)
    }
}

func slice(_ arr: MLMultiArray, dim: Int, index: Int) throws -> MLMultiArray {
    // MLMultiArray may have padded strides (e.g. [196608, 192, 1] for shape [1,1024,188]).
    // Element [0, d, t] is at offset d * strides[1] + t * strides[2].
    let D = arr.shape[1].intValue
    let result = try MLMultiArray(shape: [1, NSNumber(value: D), 1], dataType: arr.dataType)
    let strideD = arr.strides[1].intValue
    let strideT = arr.strides[2].intValue
    let src = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
    let dst = result.dataPointer.bindMemory(to: Float.self, capacity: D)
    for d in 0..<D {
        dst[d] = src[d * strideD + index * strideT]
    }
    return result
}

@main
struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: parakeet-cli <model-dir> <wav-16k-mono> [--debug]")
            exit(2)
        }
        DEBUG = args.contains("--debug")
        let models = try ModelDir(path: args[1])

        // read wav (16k mono int16) with proper chunk walking
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard data.count > 12, data[0] == 0x52, data[1] == 0x49 else {
            print("not a RIFF file")
            exit(2)
        }
        var offset = 12
        var payloadStart = -1
        while offset + 8 <= data.count {
            let id = String(data: data[offset..<offset+4], encoding: .ascii) ?? "?"
            let size = data.withUnsafeBytes { buf in
                buf.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
            }
            if id == "data" {
                payloadStart = offset + 8
                break
            }
            offset += 8 + Int(size) + (Int(size) % 2)
        }
        guard payloadStart > 0 else {
            print("no data chunk found")
            exit(2)
        }
        let audio = data.dropFirst(payloadStart).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        print("audio samples: \(audio.count) (\(Double(audio.count) / 16000.0)s)")

        // chunk audio into ~15s pieces, padding the LAST chunk with silence to full 15s
        // (padding at AUDIO level so preprocessor produces real mel for padding)
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
        print("chunks: \(chunks.count)")

        let vocabPath = args[1] + "/parakeet_vocab.json"
        let vocabData = try Data(contentsOf: URL(fileURLWithPath: vocabPath))
        let vocab = try JSONSerialization.jsonObject(with: vocabData) as! [String: String]

        var fullText = ""
        for (ci, chunk) in chunks.enumerated() {
            let (mel, melLen) = try models.preprocess(audio: chunk)
            let (enc, encLen) = try models.encode(mel: mel, melLength: melLen)
            print("chunk \(ci): melLen=\(melLen) encLen=\(encLen)")

            // TDT greedy decode (sherpa-onnx DecodeOneTDT port)
            let blankID: Int32 = 1024
            let D = 640
            let h = try MLMultiArray(shape: [2, 1, NSNumber(value: D)], dataType: .float32)
            let c = try MLMultiArray(shape: [2, 1, NSNumber(value: D)], dataType: .float32)
            memset(h.dataPointer, 0, h.count * MemoryLayout<Float>.size)
            memset(c.dataPointer, 0, c.count * MemoryLayout<Float>.size)

            // prime decoder with blank + zero states; keep output until token emitted
            var (decStep, hP, cP) = try models.decoderStep(target: blankID, hIn: h, cIn: c)
            memcpy(h.dataPointer, hP.dataPointer, hP.count * MemoryLayout<Float>.size)
            memcpy(c.dataPointer, cP.dataPointer, cP.count * MemoryLayout<Float>.size)

            var tokens: [Int32] = []
            let maxTokensPerFrame = 5
            var tokensThisFrame = 0
            var t = 0
            while t < encLen {
                let encStep = try slice(enc, dim: 1, index: t)
                let (token, duration, prob) = try models.jointStep(encStep: encStep, decStep: decStep)
                if DEBUG {
                    print("  t=\(t) token=\(token) dur=\(duration) prob=\(prob)")
                }
                if token != blankID {
                    tokens.append(token)
                    tokensThisFrame += 1
                    // decoder advances ONLY on token emission, states carried
                    let (d3, h3, c3) = try models.decoderStep(target: token, hIn: h, cIn: c)
                    decStep = d3
                    memcpy(h.dataPointer, h3.dataPointer, h3.count * MemoryLayout<Float>.size)
                    memcpy(c.dataPointer, c3.dataPointer, c3.count * MemoryLayout<Float>.size)
                }
                if duration > 0 {
                    tokensThisFrame = 0
                }
                if tokensThisFrame >= maxTokensPerFrame {
                    tokensThisFrame = 0
                    t += 1
                } else if token == blankID && duration == 0 {
                    t += 1
                } else if token != blankID && duration == 0 {
                    // multiple tokens per frame allowed, do not advance
                } else {
                    t += Int(duration)
                }
            }

            var text = ""
            for tok in tokens {
                if let piece = vocab[String(tok)] {
                    text += piece.replacingOccurrences(of: "▁", with: " ")
                }
            }
            fullText += text + " "
            print("chunk \(ci) text: \(text)")
        }
        print("FULL: \(fullText)")
    }
}

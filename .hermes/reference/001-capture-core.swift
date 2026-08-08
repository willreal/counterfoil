import Foundation
import ScreenCaptureKit
import AVFoundation

// Spike 001: capture-core (v2, SCRecordingOutput)
// Usage: capture-core <out.mp4> <seconds> [--no-mic] [--include-self-audio]
// Records primary display + all system audio + microphone into one mp4
// via ScreenCaptureKit's native SCRecordingOutput. No AVAssetWriter plumbing.
// Verifies the result afterwards (duration, tracks, non-silence).

final class RecorderDelegate: NSObject, SCRecordingOutputDelegate {
    private(set) var didStart = false
    private(set) var didFinish = false
    var failure: String?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        print("recording started")
        didStart = true
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        print("recording finished")
        didFinish = true
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        failure = error.localizedDescription
        print("recording FAILED: \(error.localizedDescription)")
        didStart = true
        didFinish = true
    }
}

func waitFor(_ condition: @escaping () -> Bool, timeout: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return true
}

func runCapture(outputURL: URL, seconds: Double, withMic: Bool, includeSelfAudio: Bool) async throws {
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
    config.captureMicrophone = withMic
    config.excludesCurrentProcessAudio = !includeSelfAudio

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)

    let recConfig = SCRecordingOutputConfiguration()
    recConfig.outputURL = outputURL
    recConfig.videoCodecType = .h264
    recConfig.outputFileType = .mp4
    let delegate = RecorderDelegate()
    let recordingOutput = SCRecordingOutput(configuration: recConfig, delegate: delegate)

    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: outputURL)

    try stream.addRecordingOutput(recordingOutput)

    try await stream.startCapture()
    // wait for recording to actually start
    if !(await waitFor({ delegate.didStart }, timeout: 10)) {
        throw NSError(domain: "capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "recording never started"])
    }
    if let failure = delegate.failure { throw NSError(domain: "capture", code: 4, userInfo: [NSLocalizedDescriptionKey: failure]) }

    print("capturing for \(seconds)s ...")
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    try await stream.stopCapture()

    if !(await waitFor({ delegate.didFinish }, timeout: 10)) {
        print("WARN: finish callback timed out (file may still be finalizing)")
    }
    if let failure = delegate.failure { throw NSError(domain: "capture", code: 5, userInfo: [NSLocalizedDescriptionKey: failure]) }
    print("done: \(outputURL.path)")
}

@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3, let secs = Double(args[2]) else {
            print("usage: capture-core <out.mp4> <seconds> [--no-mic]")
            exit(2)
        }
        let url = URL(fileURLWithPath: args[1])
        let withMic = !args.contains("--no-mic")

        if args.contains("--verify-only") {
            await verify(url)
            exit(0)
        }

        do {
            try await runCapture(outputURL: url, seconds: secs, withMic: withMic,
                                 includeSelfAudio: args.contains("--include-self-audio"))
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
        await verify(url)
    }

    static func verify(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let vtracks = try await asset.loadTracks(withMediaType: .video)
            let atracks = try await asset.loadTracks(withMediaType: .audio)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print(String(format: "verify: duration=%.1fs videoTracks=%d audioTracks=%d size=%d bytes",
                         CMTimeGetSeconds(duration), vtracks.count, atracks.count, size))

            // audio non-silence check on first audio track
            if let first = atracks.first {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: first, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                reader.add(output)
                reader.startReading()
                var peak: Float = 0
                var sampleCount = 0
                while let sb = output.copyNextSampleBuffer(), reader.status == .reading {
                    if let block = CMSampleBufferGetDataBuffer(sb) {
                        let len = CMBlockBufferGetDataLength(block)
                        var data = [UInt8](repeating: 0, count: len)
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &data)
                        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                        for s in samples {
                            let f = abs(Float(s) / 32768.0)
                            if f > peak { peak = f }
                            sampleCount += 1
                        }
                    }
                }
                print(String(format: "audio peak: %.4f (%d samples)", peak, sampleCount))
                if peak < 0.001 {
                    print("verify: FAIL (audio track silent)")
                } else {
                    print("verify: OK")
                }
            } else if vtracks.isEmpty || CMTimeGetSeconds(duration) < 1 {
                print("verify: FAIL (missing video track or too short)")
            }

            // video content check: luminance stats at 1s and mid-recording
            if let vtrack = vtracks.first {
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 200)
                let dur = CMTimeGetSeconds(duration)
                for t in [min(1.0, dur / 2), dur / 2] {
                    let time = CMTime(seconds: t, preferredTimescale: 600)
                    if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                        let stats = luminanceStats(cg)
                        print(String(format: "frame@%.1fs: size=%dx%d meanLum=%.3f stdLum=%.3f",
                                     t, cg.width, cg.height, stats.mean, stats.std))
                    }
                }
            }
        } catch {
            print("verify error: \(error)")
        }
    }

    static func luminanceStats(_ image: CGImage) -> (mean: Double, std: Double) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return (0, 0)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sum = data.reduce(0, { $0 + Int($1) })
        let mean = Double(sum) / Double(data.count)
        let variance = data.reduce(0.0, { $0 + (Double($1) - mean) * (Double($1) - mean) }) / Double(data.count)
        return (mean, sqrt(variance))
    }
}

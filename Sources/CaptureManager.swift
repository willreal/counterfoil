import Foundation
import ScreenCaptureKit
import AVFoundation
import SwiftUI
import Combine

class CaptureManager: NSObject, SCStreamOutput, ObservableObject {
    @Published var isRecording = false
    @Published var status = "Ready"
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingStartTime: Date?
    @Published var showTitlePrompt = false

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var sessionStem: String = ""
    private var sessionTitle: String = ""
    private var sessionDir: URL?
    private var systemFileURL: URL?
    private var micFileURL: URL?
    private var started = false
    private var finished = false
    private var failure: String?

    private var audioEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var durationTimer: AnyCancellable?

    static let hasMic: Bool = {
        AVCaptureDevice.default(for: .audio) != nil
    }()

    static let baseDir: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Counterfoil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func dayDir(date: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let d = Self.baseDir.appendingPathComponent(fmt.string(from: date), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func sanitizeTitle(_ title: String) -> String {
        var s = title
        for ch in ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"] {
            s = s.replacingOccurrences(of: ch, with: "")
        }
        if s.count > 60 { s = String(s.prefix(60)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func formatDateTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        return df.string(from: date)
    }

    func start(title: String) {
        let now = Date()
        recordingStartTime = now
        let sanitized = Self.sanitizeTitle(title)
        let dateStr = Self.formatDateTime(now)
        let stem = "\(sanitized) \(dateStr)"
        sessionStem = stem
        sessionTitle = title
        sessionDir = Self.dayDir(date: now)
        systemFileURL = sessionDir!.appendingPathComponent("\(stem).m4a")
        micFileURL = sessionDir!.appendingPathComponent("\(stem).mic.m4a")

        Task {
            do {
                try await startSystemCapture(to: systemFileURL!)
                if Self.hasMic {
                    try startMicCapture(to: micFileURL!)
                }
                await MainActor.run {
                    self.isRecording = true
                    self.status = "Recording"
                    self.startDurationTimer()
                }
            } catch {
                await MainActor.run {
                    self.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop(store: TranscriptStore) {
        guard isRecording else { return }
        let stem = sessionStem
        let dir = sessionDir
        let sysURL = systemFileURL
        let micURL = micFileURL
        let startTime = recordingStartTime ?? Date()
        let isMicPresent = micURL != nil && Self.hasMic
        let recDuration = recordingDuration
        let title = sessionTitle

        durationTimer?.cancel()
        durationTimer = nil

        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                print("stop capture error: \(error)")
            }

            await finishWriter()

            micFile = nil
            audioEngine?.stop()
            audioEngine = nil

            await MainActor.run {
                self.isRecording = false
                self.status = "Saving..."
            }

            let waitDeadline = Date().addingTimeInterval(15)
            while !finished && Date() < waitDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            if let f = failure {
                await MainActor.run { self.status = "Recording failed: \(f)" }
                return
            }

            await MainActor.run {
                self.status = "Transcribing..."
            }

            var sysText = ""
            var micText = ""

            await withTaskGroup(of: (String, String).self) { group in
                group.addTask {
                    if let url = sysURL {
                        do {
                            let text = try await Transcriber.shared.transcribe(
                                filePath: url.path, startTime: startTime)
                            return ("system", text)
                        } catch {
                            print("system transcribe error: \(error)")
                            return ("system", "[transcribe error]")
                        }
                    }
                    return ("system", "")
                }
                if isMicPresent, let url = micURL {
                    group.addTask {
                        do {
                            let text = try await Transcriber.shared.transcribe(
                                filePath: url.path, startTime: startTime)
                            return ("mic", text)
                        } catch {
                            print("mic transcribe error: \(error)")
                            return ("mic", "[transcribe error]")
                        }
                    }
                }
                for await (source, text) in group {
                    if source == "system" { sysText = text }
                    if source == "mic" { micText = text }
                }
            }

            let finalSysText = sysText
            let finalMicText = micText

            await MainActor.run {
                store.addSession(
                    stem: stem,
                    title: title,
                    dayDir: dir,
                    startTime: startTime,
                    systemText: finalSysText,
                    micText: finalMicText,
                    hasMicFile: isMicPresent,
                    duration: recDuration
                )
                self.status = "Ready"
                self.recordingDuration = 0
                self.sessionStem = ""
                self.sessionTitle = ""
                self.systemFileURL = nil
                self.micFileURL = nil
                self.finished = false
                self.started = false
                self.failure = nil
            }
        }
    }

    // MARK: System capture (ScreenCaptureKit, audio-only)

    private func startSystemCapture(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 6
        config.showsCursor = false
        config.capturesAudio = true
        config.captureMicrophone = false
        config.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: nil)

        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)

        try FileManager.default.createDirectory(at: sessionDir!, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
        ])
        writer.add(input)
        assetWriter = writer
        assetWriterInput = input

        stream = s
        started = false
        finished = false
        failure = nil

        try await s.startCapture()

        let waitDeadline = Date().addingTimeInterval(10)
        while !started && Date() < waitDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !started {
            throw NSError(domain: "capture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Recording never started"])
        }
        if let f = failure {
            throw NSError(domain: "capture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: f])
        }
    }

    // MARK: Mic capture (AVAudioEngine)

    private func startMicCapture(to url: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]

        try? FileManager.default.removeItem(at: url)

        let file = try AVAudioFile(forWriting: url, settings: settings)
        micFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                print("mic write error: \(error)")
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func startDurationTimer() {
        durationTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
    }

    private func finishWriter() async {
        guard let writer = assetWriter else { return }
        assetWriterInput?.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status == .failed {
            failure = writer.error?.localizedDescription ?? "writer failed"
        }
        finished = true
        assetWriter = nil
        assetWriterInput = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let writer = assetWriter, let input = assetWriterInput else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }

        if writer.status == .writing, input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                failure = writer.error?.localizedDescription ?? "append failed"
                started = true
                finished = true
            }
        }
    }
}

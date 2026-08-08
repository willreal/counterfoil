import Foundation
import ScreenCaptureKit
import AVFoundation
import SwiftUI
import Combine

class CaptureManager: NSObject, SCRecordingOutputDelegate, ObservableObject {
    @Published var isRecording = false
    @Published var status = "Ready"
    @Published var recordingDuration: TimeInterval = 0
    @Published var micEnabled = true
    @Published var recordingStartTime: Date?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var sessionStem: String = ""
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

    func start() {
        let now = Date()
        recordingStartTime = now
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let stem = "meeting_" + df.string(from: now)
        sessionStem = stem
        sessionDir = Self.dayDir(date: now)
        systemFileURL = sessionDir!.appendingPathComponent("\(stem).mp4")
        micFileURL = sessionDir!.appendingPathComponent("\(stem).mic.m4a")

        Task {
            do {
                try await startSystemCapture(to: systemFileURL!)
                if micEnabled && Self.hasMic {
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
        let isMicPresent = micURL != nil && micEnabled && Self.hasMic
        let recDuration = recordingDuration

        durationTimer?.cancel()
        durationTimer = nil

        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                print("stop capture error: \(error)")
            }

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
                self.systemFileURL = nil
                self.micFileURL = nil
                self.finished = false
                self.started = false
                self.failure = nil
            }
        }
    }

    // MARK: System capture (ScreenCaptureKit)

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

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.videoCodecType = .h264
        recConfig.outputFileType = .mp4

        try FileManager.default.createDirectory(at: sessionDir!, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let recOutput = SCRecordingOutput(configuration: recConfig, delegate: self)
        try s.addRecordingOutput(recOutput)

        stream = s
        recordingOutput = recOutput
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

        if let micFileURL = url as URL? {
            try? FileManager.default.removeItem(at: micFileURL)
        }

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

    // MARK: SCRecordingOutputDelegate

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        started = true
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished = true
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        failure = error.localizedDescription
        started = true
        finished = true
    }
}

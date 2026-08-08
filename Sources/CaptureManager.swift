import Foundation
import ScreenCaptureKit
import AVFoundation
import SwiftUI
import Combine

class CaptureManager: NSObject, SCStreamOutput, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var status = "Ready"
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingStartTime: Date?
    @Published var showTitlePrompt = false
    @Published var micLevel: CGFloat = 0
    @Published var showLowDiskAlert = false

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
    private var pendingTitleForLowDisk: String = ""

    private var audioEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var durationTimer: AnyCancellable?

    private var activityToken: NSObjectProtocol?
    var totalPausedDuration: TimeInterval = 0
    private var pauseStartTime: Date?

    var flaggedOffsets: [TimeInterval] = []
    var notes: [(TimeInterval, String)] = []

    private var segmentSystemURLs: [URL] = []
    private var segmentMicURLs: [URL] = []
    private var segmentStartDates: [Date] = []

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

    func currentElapsedTime() -> TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        var elapsed = Date().timeIntervalSince(start) - totalPausedDuration
        if isPaused, let pauseStart = pauseStartTime {
            elapsed -= Date().timeIntervalSince(pauseStart)
        }
        return max(0, elapsed)
    }

    func flagCurrentMoment() {
        guard isRecording, !isPaused else { return }
        flaggedOffsets.append(currentElapsedTime())
    }

    func addNote(_ text: String) {
        guard isRecording else { return }
        let t = currentElapsedTime()
        notes.append((t, text))
    }

    func start(title: String) {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let values = try? docsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            let twoGB: Int64 = 2 * 1024 * 1024 * 1024
            if available < twoGB {
                pendingTitleForLowDisk = title
                DispatchQueue.main.async { self.showLowDiskAlert = true }
                return
            }
        }
        startInternal(title: title)
    }

    func confirmLowDiskStart() {
        startInternal(title: pendingTitleForLowDisk)
    }

    private func startInternal(title: String) {
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

        totalPausedDuration = 0
        pauseStartTime = nil
        flaggedOffsets = []
        notes = []
        segmentSystemURLs = [systemFileURL!]
        segmentMicURLs = []
        if Self.hasMic { segmentMicURLs.append(micFileURL!) }
        segmentStartDates = [now]

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Recording meeting")

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
                endActivityToken()
                await MainActor.run {
                    self.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    func pauseCapture() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseStartTime = Date()
        status = "Paused"

        stream?.stopCapture()
        stream = nil
        assetWriterInput?.markAsFinished()
        if let writer = assetWriter {
            Task {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    writer.finishWriting { c.resume() }
                }
            }
        }
        assetWriter = nil
        assetWriterInput = nil
        started = false
        finished = false
        failure = nil

        micFile = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    func resumeCapture() {
        guard isRecording, isPaused else { return }
        if let pauseStart = pauseStartTime {
            totalPausedDuration += Date().timeIntervalSince(pauseStart)
        }
        pauseStartTime = nil

        guard let dir = sessionDir else { return }
        let segIndex = segmentSystemURLs.count
        let segSysURL = dir.appendingPathComponent("\(sessionStem).\(segIndex + 1).m4a")
        systemFileURL = segSysURL
        segmentSystemURLs.append(segSysURL)
        segmentStartDates.append(Date())

        if Self.hasMic {
            let segMicURL = dir.appendingPathComponent("\(sessionStem).mic.\(segIndex + 1).m4a")
            micFileURL = segMicURL
            segmentMicURLs.append(segMicURL)
        }

        Task {
            do {
                try await startSystemCapture(to: segSysURL)
                if Self.hasMic, let micURL = micFileURL {
                    try startMicCapture(to: micURL)
                }
                await MainActor.run {
                    self.isPaused = false
                    self.status = "Recording"
                }
            } catch {
                await MainActor.run {
                    self.isPaused = false
                    self.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop(store: TranscriptStore) {
        guard isRecording else { return }
        let stem = sessionStem
        let dir = sessionDir
        let startTime = recordingStartTime ?? Date()
        let isMicPresent = Self.hasMic && !segmentMicURLs.isEmpty
        let recDuration = recordingDuration
        let title = sessionTitle
        let flags = flaggedOffsets
        let notesList = notes
        let pausedDuration = totalPausedDuration
        let sysURLs = segmentSystemURLs
        let micURLs = segmentMicURLs
        let segStartDates = segmentStartDates

        durationTimer?.cancel()
        durationTimer = nil

        if isPaused {
            if let pauseStart = pauseStartTime {
                totalPausedDuration += Date().timeIntervalSince(pauseStart)
            }
            isPaused = false
        }

        endActivityToken()

        if stream != nil {
            Task {
                do {
                    try await stream?.stopCapture()
                } catch {
                    print("stop capture error: \(error)")
                }
                await finishWriter()
                proceedWithStop()
            }
        } else {
            Task { proceedWithStop() }
        }

        func proceedWithStop() {
            micFile = nil
            audioEngine?.stop()
            audioEngine = nil

            Task {
                await MainActor.run {
                    self.isRecording = false
                    self.status = "Saving..."
                }

                let waitDeadline = Date().addingTimeInterval(15)
                while !finished && Date() < waitDeadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                await MainActor.run {
                    self.status = "Transcribing..."
                }

                var allSysLines: [String] = []
                var allMicLines: [String] = []

                for i in 0..<sysURLs.count {
                    let segStart = segStartDates[i]
                    if let url = sysURLs[safe: i] {
                        do {
                            let text = try await Transcriber.shared.transcribe(
                                filePath: url.path, startTime: segStart)
                            allSysLines.append(text)
                        } catch {
                            print("system transcribe error: \(error)")
                            allSysLines.append("[transcribe error]")
                        }
                    }
                    if isMicPresent, let url = micURLs[safe: i] {
                        do {
                            let text = try await Transcriber.shared.transcribe(
                                filePath: url.path, startTime: segStart)
                            allMicLines.append(text)
                        } catch {
                            print("mic transcribe error: \(error)")
                            allMicLines.append("[transcribe error]")
                        }
                    }
                }

                let finalSysText = allSysLines.joined(separator: "\n")
                let finalMicText = allMicLines.joined(separator: "\n")

                await MainActor.run {
                    store.addSession(
                        stem: stem,
                        title: title,
                        dayDir: dir,
                        startTime: startTime,
                        systemText: finalSysText,
                        micText: finalMicText,
                        hasMicFile: isMicPresent,
                        duration: recDuration,
                        flaggedOffsets: flags,
                        notes: notesList,
                        totalPausedDuration: pausedDuration
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
                    self.segmentSystemURLs = []
                    self.segmentMicURLs = []
                    self.segmentStartDates = []
                    self.flaggedOffsets = []
                    self.notes = []
                    self.totalPausedDuration = 0
                }

                for i in 1..<sysURLs.count {
                    try? FileManager.default.removeItem(at: sysURLs[i])
                }
                for i in 1..<micURLs.count {
                    try? FileManager.default.removeItem(at: micURLs[i])
                }
            }
        }
    }

    private func endActivityToken() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
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

        // ONE tap on bus 0: writes the file AND computes the mic level.
        // (Two taps with different buffer sizes on the same bus crash AVAudioEngine:
        // "AUGraphNodeBaseV3::CreateRecordingTap" NSException — seen on MacBook.)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try file.write(from: buffer)
            } catch {
                print("mic write error: \(error)")
            }
            let frameLen = Int(buffer.frameLength)
            guard frameLen > 0,
                  let channelData = buffer.floatChannelData else { return }
            let ptr = channelData[0]
            var sum: Float = 0
            for i in 0..<frameLen {
                let s = ptr[i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(frameLen))
            let level = min(rms * 4, 1.0)
            DispatchQueue.main.async {
                self.micLevel = CGFloat(level)
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
                if self.isPaused { return }
                self.recordingDuration = Date().timeIntervalSince(start) - self.totalPausedDuration
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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

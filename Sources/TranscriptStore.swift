import Foundation
import SwiftUI

struct Session: Identifiable, Codable {
    let id: String
    let stem: String
    let title: String
    let startTime: Date
    let duration: TimeInterval
    let hasSystemFile: Bool
    let hasMicFile: Bool
    let hasTranscript: Bool
    let dayDir: String
}

class TranscriptStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var transcriptContent: [String: String] = [:]
    @Published var selectedSession: String?

    private let fm = FileManager.default
    private var autoDeleteTimer: Timer?

    func loadSessions() async {
        let baseDir = CaptureManager.baseDir
        var found: [Session] = []

        guard let dayDirs = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else {
            await MainActor.run { self.sessions = [] }
            return
        }

        for dayDir in dayDirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard (try? dayDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) else { continue }

            var stems = Set<String>()

            for url in files {
                let name = url.lastPathComponent
                if name.hasPrefix("meeting_") && name.hasSuffix(".mic.m4a") {
                    stems.insert(String(name.dropLast(8)))
                } else if name.hasPrefix("meeting_") && name.hasSuffix(".mp4") {
                    stems.insert(String(name.dropLast(4)))
                } else if name.hasPrefix("meeting_") && name.hasSuffix(".md") {
                    stems.insert(String(name.dropLast(3)))
                } else if name.hasSuffix(".mic.m4a") && !name.hasPrefix("meeting_") {
                    stems.insert(String(name.dropLast(8)))
                } else if name.hasSuffix(".m4a") && !name.hasPrefix("meeting_") && !name.hasSuffix(".mic.m4a") {
                    let n = name.dropLast(4)
                    if !n.contains(".mic") {
                        stems.insert(String(name.dropLast(4)))
                    }
                } else if name.hasSuffix(".md") && !name.hasPrefix("meeting_") {
                    stems.insert(String(name.dropLast(3)))
                }
            }

            for stem in stems {
                let systemPath = dayDir.appendingPathComponent("\(stem).mp4").path
                let systemM4aPath = dayDir.appendingPathComponent("\(stem).m4a").path
                let micPath = dayDir.appendingPathComponent("\(stem).mic.m4a").path
                let mdPath = dayDir.appendingPathComponent("\(stem).md").path

                let hasSystem = fm.fileExists(atPath: systemPath) || fm.fileExists(atPath: systemM4aPath)
                let hasMic = fm.fileExists(atPath: micPath)
                let hasMD = fm.fileExists(atPath: mdPath)

                var duration: TimeInterval = 0
                var title = "Meeting"
                var startTime: Date

                if stem.hasPrefix("meeting_") {
                    let dateStr = String(stem.dropFirst("meeting_".count))
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd_HHmmss"
                    startTime = df.date(from: dateStr) ?? Date()
                } else {
                    let pattern = try! NSRegularExpression(pattern: #"^(.*?) (\d{4}-\d{2}-\d{2}) (\d{4})$"#, options: [])
                    if let m = pattern.firstMatch(in: stem, options: [], range: NSRange(location: 0, length: stem.utf16.count)) {
                        title = (stem as NSString).substring(with: m.range(at: 1))
                        let datePart = (stem as NSString).substring(with: m.range(at: 2))
                        let timePart = (stem as NSString).substring(with: m.range(at: 3))
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd HHmm"
                        startTime = df.date(from: "\(datePart) \(timePart)") ?? Date()
                    } else {
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd"
                        startTime = df.date(from: dayDir.lastPathComponent) ?? Date()
                    }
                }

                if hasMD {
                    let content = (try? String(contentsOfFile: mdPath, encoding: .utf8)) ?? ""
                    let lines = content.components(separatedBy: "\n")
                    let firstLine = lines.first ?? ""
                    if firstLine.hasPrefix("# ") && !firstLine.hasPrefix("# Counterfoil") {
                        title = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    }
                    if lines.count > 1 {
                        let metaLine = lines[1]
                        let durMatch = metaLine.range(of: #"(\d+) min"#, options: .regularExpression)
                        if let r = durMatch {
                            let durStr = String(metaLine[r]).components(separatedBy: " ").first ?? "0"
                            duration = TimeInterval(Int(durStr) ?? 0) * 60
                        }
                    }
                    if duration == 0 {
                        let durMatch = firstLine.range(of: #"Duration (\d+)"#, options: .regularExpression)
                        if let r = durMatch {
                            duration = TimeInterval(Int(firstLine[r].components(separatedBy: " ").last ?? "0") ?? 0) * 60
                        }
                    }
                }

                let id = stem
                let session = Session(
                    id: id,
                    stem: stem,
                    title: title,
                    startTime: startTime,
                    duration: duration > 0 ? duration : 0,
                    hasSystemFile: hasSystem,
                    hasMicFile: hasMic,
                    hasTranscript: hasMD,
                    dayDir: dayDir.path
                )
                found.append(session)
            }
        }

        let sorted = found.sorted(by: { $0.startTime > $1.startTime })
        await MainActor.run {
            self.sessions = sorted
        }
        await MainActor.run {
            self.autoDeleteOldAudio()
            self.startAutoDeleteTimer()
        }
    }

    func addSession(stem: String, title: String, dayDir: URL?, startTime: Date,
                    systemText: String, micText: String, hasMicFile: Bool, duration: TimeInterval,
                    flaggedOffsets: [TimeInterval] = [], notes: [(TimeInterval, String)] = [],
                    totalPausedDuration: TimeInterval = 0) {
        guard let dir = dayDir else { return }

        let interleaved = interleaveTranscript(
            systemText: systemText, micText: micText, startTime: startTime, duration: duration,
            flaggedOffsets: flaggedOffsets, notes: notes)

        let sysLineCount = systemText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let micLineCount = micText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count

        let head = mdHeader(title: title, startTime: startTime, duration: duration,
                            youCount: micLineCount, themCount: sysLineCount)
        let mdContent = head + "\n" + interleaved
        let mdPath = dir.appendingPathComponent("\(stem).md")
        try? mdContent.write(to: mdPath, atomically: true, encoding: .utf8)

        let session = Session(
            id: stem,
            stem: stem,
            title: title,
            startTime: startTime,
            duration: duration,
            hasSystemFile: true,
            hasMicFile: hasMicFile,
            hasTranscript: true,
            dayDir: dir.path
        )

        DispatchQueue.main.async {
            self.sessions.insert(session, at: 0)
            self.selectedSession = stem
        }
    }

    func loadTranscript(for session: Session) {
        let mdPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).md")
        if let content = try? String(contentsOfFile: mdPath, encoding: .utf8) {
            transcriptContent[session.id] = content
        }
    }

    func deleteAudioFiles(_ session: Session) {
        let sysPaths = [
            (session.dayDir as NSString).appendingPathComponent("\(session.stem).mp4"),
            (session.dayDir as NSString).appendingPathComponent("\(session.stem).m4a"),
        ]
        let micPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).mic.m4a")

        for sp in sysPaths {
            let url = URL(fileURLWithPath: sp)
            if fm.fileExists(atPath: sp) {
                _ = try? fm.trashItem(at: url, resultingItemURL: nil)
            }
        }
        let micURL = URL(fileURLWithPath: micPath)
        if fm.fileExists(atPath: micPath) {
            _ = try? fm.trashItem(at: micURL, resultingItemURL: nil)
        }

        DispatchQueue.main.async {
            if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                let updated = self.sessions[idx]
                let updatedSession = Session(
                    id: updated.id,
                    stem: updated.stem,
                    title: updated.title,
                    startTime: updated.startTime,
                    duration: updated.duration,
                    hasSystemFile: false,
                    hasMicFile: false,
                    hasTranscript: updated.hasTranscript,
                    dayDir: updated.dayDir
                )
                self.sessions[idx] = updatedSession
            }
        }
    }

    func deleteEverything(_ session: Session) {
        deleteAudioFiles(session)
        let mdPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).md")
        let mdURL = URL(fileURLWithPath: mdPath)
        if fm.fileExists(atPath: mdPath) {
            _ = try? fm.trashItem(at: mdURL, resultingItemURL: nil)
        }
        DispatchQueue.main.async {
            self.sessions.removeAll(where: { $0.id == session.id })
            if self.selectedSession == session.id {
                self.selectedSession = nil
            }
        }
    }

    func deleteSession(_ session: Session) {
        deleteAudioFiles(session)
    }

    func autoDeleteOldAudio() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for session in sessions {
            guard session.hasSystemFile || session.hasMicFile else { continue }
            let sysPaths = [
                (session.dayDir as NSString).appendingPathComponent("\(session.stem).mp4"),
                (session.dayDir as NSString).appendingPathComponent("\(session.stem).m4a"),
            ]
            var shouldDelete = false
            for sp in sysPaths {
                if fm.fileExists(atPath: sp),
                   let attrs = try? fm.attributesOfItem(atPath: sp),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate < cutoff {
                    shouldDelete = true
                    break
                }
            }
            let micPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).mic.m4a")
            if !shouldDelete && fm.fileExists(atPath: micPath),
               let attrs = try? fm.attributesOfItem(atPath: micPath),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < cutoff {
                shouldDelete = true
            }
            if shouldDelete {
                deleteAudioFiles(session)
            }
        }
    }

    private func startAutoDeleteTimer() {
        autoDeleteTimer?.invalidate()
        autoDeleteTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.autoDeleteOldAudio()
        }
    }

    private func mdHeader(title: String, startTime: Date, duration: TimeInterval,
                          youCount: Int, themCount: Int) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = df.string(from: startTime)
        let min = Int(duration / 60)
        return "# \(title)\n*\(dateStr) · \(min) min · You \(youCount) · Them \(themCount)*"
    }

    private func interleaveTranscript(systemText: String, micText: String,
                                       startTime: Date, duration: TimeInterval,
                                       flaggedOffsets: [TimeInterval] = [],
                                       notes: [(TimeInterval, String)] = []) -> String {
        struct Line: Comparable {
            let time: TimeInterval
            let speaker: String
            let text: String
            let isAnnotation: Bool
            static func < (lhs: Line, rhs: Line) -> Bool { lhs.time < rhs.time }
        }

        var lines: [Line] = []

        func parse(_ raw: String, speaker: String, baseTime: Date) {
            let pattern = try! NSRegularExpression(pattern: #"^\[(\d{2}:\d{2}:\d{2})\]\s*(.+)$"#, options: [])
            for line in raw.components(separatedBy: "\n") {
                if let m = pattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
                    let tsStr = (line as NSString).substring(with: m.range(at: 1))
                    let parts = tsStr.components(separatedBy: ":")
                    let secs = (Int(parts[0]) ?? 0) * 3600 + (Int(parts[1]) ?? 0) * 60 + (Int(parts[2]) ?? 0)
                    let elapsed = TimeInterval(secs)
                    let text = (line as NSString).substring(with: m.range(at: 2))
                    lines.append(Line(time: elapsed, speaker: speaker, text: text, isAnnotation: false))
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(Line(time: duration / 2, speaker: speaker, text: line, isAnnotation: false))
                }
            }
        }

        parse(systemText, speaker: "Them", baseTime: startTime)
        parse(micText, speaker: "You", baseTime: startTime)

        for offset in flaggedOffsets {
            lines.append(Line(time: offset, speaker: "", text: "[FLAG]", isAnnotation: true))
        }

        for (offset, noteText) in notes {
            lines.append(Line(time: offset, speaker: "", text: "NOTE: \(noteText)", isAnnotation: true))
        }

        lines.sort()

        if lines.isEmpty {
            return "_No transcript available_"
        }

        return lines.map { line in
            let secs = Int(line.time)
            let h = secs / 3600
            let m = (secs % 3600) / 60
            let s = secs % 60
            let ts = String(format: "%02d:%02d:%02d", h, m, s)
            if line.isAnnotation {
                return "**[\(ts)] \(line.text)**"
            }
            return "**[\(ts)] \(line.speaker):** \(line.text)"
        }.joined(separator: "\n")
    }
}

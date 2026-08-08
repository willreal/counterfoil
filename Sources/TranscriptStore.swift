import Foundation
import SwiftUI

struct Session: Identifiable, Codable {
    let id: String
    let stem: String
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

            let stems = Set(files.compactMap { url -> String? in
                let name = url.lastPathComponent
                let ext = url.pathExtension
                if name.hasPrefix("meeting_") && name.hasSuffix(".mic.m4a") {
                    return String(name.dropLast(8))
                }
                if name.hasPrefix("meeting_") && ext == "mp4" {
                    return String(name.dropLast(4))
                }
                if name.hasPrefix("meeting_") && ext == "md" {
                    return String(name.dropLast(3))
                }
                return nil
            })

            for stem in stems {
                let systemPath = dayDir.appendingPathComponent("\(stem).mp4").path
                let micPath = dayDir.appendingPathComponent("\(stem).mic.m4a").path
                let mdPath = dayDir.appendingPathComponent("\(stem).md").path

                let hasSystem = fm.fileExists(atPath: systemPath)
                let hasMic = fm.fileExists(atPath: micPath)
                let hasMD = fm.fileExists(atPath: mdPath)

                var duration: TimeInterval = 0
                if hasSystem {
                    let attrs = try? fm.attributesOfItem(atPath: systemPath)
                    if let date = attrs?[.creationDate] as? Date {
                        duration = abs(date.timeIntervalSinceNow) < 86400 * 365 ? 0 : 0
                    }
                }

                let dateStr = String(stem.dropFirst("meeting_".count))
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd_HHmmss"
                let startTime = df.date(from: dateStr) ?? Date()

                let id = stem
                if hasMD {
                    let content = (try? String(contentsOfFile: mdPath, encoding: .utf8)) ?? ""
                    let firstLine = content.components(separatedBy: "\n").first ?? ""
                    let durMatch = firstLine.range(of: #"Duration (\d+)"#, options: .regularExpression)
                    if let r = durMatch {
                        duration = TimeInterval(Int(firstLine[r].components(separatedBy: " ").last ?? "0") ?? 0) * 60
                    }
                }

                let session = Session(
                    id: id,
                    stem: stem,
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
    }

    func addSession(stem: String, dayDir: URL?, startTime: Date,
                    systemText: String, micText: String, hasMicFile: Bool, duration: TimeInterval) {
        guard let dir = dayDir else { return }

        let interleaved = interleaveTranscript(
            systemText: systemText, micText: micText, startTime: startTime, duration: duration)

        let head = mdHeader(startTime: startTime, duration: duration)
        let mdContent = head + "\n" + interleaved
        let mdPath = dir.appendingPathComponent("\(stem).md")
        try? mdContent.write(to: mdPath, atomically: true, encoding: .utf8)

        let session = Session(
            id: stem,
            stem: stem,
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

    func deleteSession(_ session: Session) {
        let sysPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).mp4")
        let micPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).mic.m4a")

        let sysURL = URL(fileURLWithPath: sysPath)
        let micURL = URL(fileURLWithPath: micPath)

        var resultURL: NSURL?
        do {
            try fm.trashItem(at: sysURL, resultingItemURL: &resultURL)
        } catch {
            _ = try? fm.trashItem(at: sysURL, resultingItemURL: nil)
        }
        if fm.fileExists(atPath: micPath) {
            do {
                var result: NSURL?
                try fm.trashItem(at: micURL, resultingItemURL: &result)
            } catch {
                // ignore
            }
        }

        DispatchQueue.main.async {
            if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                let updated = Session(
                    id: session.id,
                    stem: session.stem,
                    startTime: session.startTime,
                    duration: session.duration,
                    hasSystemFile: false,
                    hasMicFile: false,
                    hasTranscript: session.hasTranscript,
                    dayDir: session.dayDir
                )
                self.sessions[idx] = updated
            }
        }
    }

    private func mdHeader(startTime: Date, duration: TimeInterval) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = df.string(from: startTime)
        let min = Int(duration / 60)
        return "# Counterfoil — \(dateStr)\nDuration \(min) min"
    }

    private func interleaveTranscript(systemText: String, micText: String,
                                       startTime: Date, duration: TimeInterval) -> String {
        struct Line: Comparable {
            let time: TimeInterval
            let speaker: String
            let text: String
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
                    lines.append(Line(time: elapsed, speaker: speaker, text: text))
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(Line(time: duration / 2, speaker: speaker, text: line))
                }
            }
        }

        parse(systemText, speaker: "Them", baseTime: startTime)
        parse(micText, speaker: "You", baseTime: startTime)
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
            return "**[\(ts)] \(line.speaker):** \(line.text)"
        }.joined(separator: "\n")
    }
}

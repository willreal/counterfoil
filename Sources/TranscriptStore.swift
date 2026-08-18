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
    let processingState: SessionProcessingState
    let failureMessage: String?
    let systemAudioFilename: String?
    let microphoneAudioFilename: String?
    let transcriptFilename: String
    let metadataFilename: String?

    init(
        id: String,
        stem: String,
        title: String,
        startTime: Date,
        duration: TimeInterval,
        hasSystemFile: Bool,
        hasMicFile: Bool,
        hasTranscript: Bool,
        dayDir: String,
        processingState: SessionProcessingState = .legacy,
        failureMessage: String? = nil,
        systemAudioFilename: String? = nil,
        microphoneAudioFilename: String? = nil,
        transcriptFilename: String? = nil,
        metadataFilename: String? = nil
    ) {
        self.id = id
        self.stem = stem
        self.title = title
        self.startTime = startTime
        self.duration = duration
        self.hasSystemFile = hasSystemFile
        self.hasMicFile = hasMicFile
        self.hasTranscript = hasTranscript
        self.dayDir = dayDir
        self.processingState = processingState
        self.failureMessage = failureMessage
        self.systemAudioFilename = systemAudioFilename
        self.microphoneAudioFilename = microphoneAudioFilename
        self.transcriptFilename = transcriptFilename ?? "\(stem).md"
        self.metadataFilename = metadataFilename
    }
}

struct OrphanInfo: Identifiable {
    let id = UUID()
    let stem: String
    let dayDir: URL
    let systemFile: URL?
    let micFile: URL?
    let modDate: Date
}

enum TranscriptAnnotationKind: Equatable {
    case flag
    case note
}

struct TranscriptAnnotation {
    let timestamp: TimeInterval
    let kind: TranscriptAnnotationKind
    let text: String?
}

struct StoredTranscriptNote: Identifiable, Equatable {
    let id: Int
    let timestamp: TimeInterval
    var text: String
}

struct TranscriptAnnotations {
    var flags: [TimeInterval] = []
    var notes: [StoredTranscriptNote] = []
}

func transcriptAnnotation(from rawLine: String) -> TranscriptAnnotation? {
    let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
    guard let open = trimmed.firstIndex(of: "["),
          let close = trimmed.firstIndex(of: "]"),
          close > open else { return nil }

    let timestampText = String(trimmed[trimmed.index(after: open)..<close])
    let parts = timestampText.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    let timestamp = TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])

    var payload = String(trimmed[trimmed.index(after: close)...])
        .trimmingCharacters(in: .whitespaces)
    while payload.hasPrefix("**") {
        payload.removeFirst(2)
    }
    while payload.hasSuffix("**") {
        payload.removeLast(2)
    }
    payload = payload.trimmingCharacters(in: .whitespaces)

    if payload == "[FLAG]" {
        return TranscriptAnnotation(timestamp: timestamp, kind: .flag, text: nil)
    }
    if payload.hasPrefix("NOTE:") {
        let noteText = String(payload.dropFirst("NOTE:".count))
            .trimmingCharacters(in: .whitespaces)
        return TranscriptAnnotation(timestamp: timestamp, kind: .note, text: noteText)
    }
    return nil
}

class TranscriptStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var transcriptContent: [String: String] = [:]
    @Published private(set) var sessionAnnotations: [String: TranscriptAnnotations] = [:]
    @Published var selectedSession: String?
    @Published var searchQuery: String = ""
    @Published var searchScope: TranscriptSearchScope = .all
    @Published var orphanSessions: [OrphanInfo] = []
    @Published var isRecovering = false
    @Published private var searchIndexes: [String: TranscriptSearchIndex] = [:]

    private let fm = FileManager.default
    private var autoDeleteTimer: Timer?
    private let transcriptCacheLimit = 3
    private var transcriptAccessOrder: [String] = []

    var displayedSessions: [Session] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            if searchScope == .all,
               session.title.localizedCaseInsensitiveContains(query) || session.stem.localizedCaseInsensitiveContains(query) {
                return true
            }
            return searchIndexes[session.id]?.matches(query, scope: searchScope) == true
        }
    }

    /// Returns the most useful one-line context for a sidebar search hit.
    /// Title/filename hits get a quiet explanation; transcript hits use the
    /// matching markdown line so the result is actionable at a glance.
    func searchContext(for session: Session) -> String? {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if searchScope == .all,
           session.title.localizedCaseInsensitiveContains(query) || session.stem.localizedCaseInsensitiveContains(query) {
            return "Title match · \(session.stem)"
        }
        guard let index = searchIndexes[session.id] else { return nil }
        return TranscriptSearchSupport.context(in: index, query: query, scope: searchScope)
    }

    func loadSessions() async {
        let baseDir = CaptureManager.baseDir
        var found: [Session] = []
        var knownStems = Set<String>()
        var managedFileNames = Set<String>()
        var dirs: [URL] = []
        var indexedSearchIndexes: [String: TranscriptSearchIndex] = [:]

        guard let dayDirs = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else {
            await MainActor.run {
                self.sessions = []
                self.transcriptContent.removeAll(keepingCapacity: false)
                self.sessionAnnotations.removeAll(keepingCapacity: false)
                self.searchIndexes.removeAll(keepingCapacity: false)
                self.transcriptAccessOrder.removeAll(keepingCapacity: false)
            }
            return
        }

        dirs = dayDirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })

        for dayDir in dirs {
            guard (try? dayDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) else { continue }

            var metadataTranscriptStems = Set<String>()
            let metadataFiles = files.filter { $0.pathExtension.lowercased() == "json" }
            for metadataFile in metadataFiles {
                guard let loadedMetadata = try? SessionMetadataIO.read(from: metadataFile),
                      loadedMetadata.schemaVersion == SessionMetadataV1.currentSchemaVersion else { continue }

                let transcriptURL = dayDir.appendingPathComponent(loadedMetadata.transcriptFilename)
                let systemURL = loadedMetadata.systemAudioFilename.map { dayDir.appendingPathComponent($0) }
                let microphoneURL = loadedMetadata.microphoneAudioFilename.map { dayDir.appendingPathComponent($0) }
                let hasTranscript = fm.fileExists(atPath: transcriptURL.path)
                let hasSystem = systemURL.map { fm.fileExists(atPath: $0.path) } ?? false
                let hasMicrophone = microphoneURL.map { fm.fileExists(atPath: $0.path) } ?? false
                let metadata = SessionCrashRecovery.recovered(
                    metadata: loadedMetadata,
                    transcriptExists: hasTranscript,
                    audioExists: hasSystem || hasMicrophone
                )
                if metadata != loadedMetadata {
                    try? SessionMetadataIO.write(metadata, to: metadataFile)
                }
                let id = metadata.id.uuidString.lowercased()

                let session = Session(
                    id: id,
                    stem: metadata.stem,
                    title: metadata.title,
                    startTime: metadata.startTime,
                    duration: metadata.durationSeconds,
                    hasSystemFile: hasSystem,
                    hasMicFile: hasMicrophone,
                    hasTranscript: hasTranscript,
                    dayDir: dayDir.path,
                    processingState: metadata.processingState,
                    failureMessage: metadata.failureMessage,
                    systemAudioFilename: metadata.systemAudioFilename,
                    microphoneAudioFilename: metadata.microphoneAudioFilename,
                    transcriptFilename: metadata.transcriptFilename,
                    metadataFilename: metadataFile.lastPathComponent
                )
                found.append(session)
                knownStems.insert(metadata.stem)
                metadataTranscriptStems.insert(metadata.stem)
                managedFileNames.insert(metadataFile.lastPathComponent)
                managedFileNames.insert(metadata.transcriptFilename)
                if let filename = metadata.systemAudioFilename { managedFileNames.insert(filename) }
                if let filename = metadata.microphoneAudioFilename { managedFileNames.insert(filename) }

                if hasTranscript,
                   let content = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                    indexedSearchIndexes[id] = TranscriptSearchSupport.makeIndex(from: content)
                }
            }

            var stems = Set<String>()

            for url in files {
                let name = url.lastPathComponent
                if managedFileNames.contains(name) { continue }
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

            for stem in stems where !metadataTranscriptStems.contains(stem) {
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
                    indexedSearchIndexes[stem] = TranscriptSearchSupport.makeIndex(from: content)
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
                knownStems.insert(stem)
            }
        }

        let sorted = found.sorted(by: { $0.startTime > $1.startTime })
        let finalSearchIndexes = indexedSearchIndexes
        await MainActor.run {
            self.sessions = sorted
            self.searchIndexes = finalSearchIndexes
            self.transcriptContent.removeAll(keepingCapacity: false)
            self.sessionAnnotations.removeAll(keepingCapacity: false)
            self.transcriptAccessOrder.removeAll(keepingCapacity: false)
        }

        // Detect orphans after building known stems
        var orphans: [OrphanInfo] = []
        for dayDir in dirs {
            guard (try? dayDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            orphans.append(contentsOf: detectOrphans(
                in: dayDir,
                knownStems: knownStems,
                managedFileNames: managedFileNames
            ))
        }

        let finalOrphans = orphans
        await MainActor.run {
            self.orphanSessions = finalOrphans
            if SettingsStore.shared.autoDeleteEnabled {
                self.autoDeleteOldAudio()
            }
            self.startAutoDeleteTimer()
        }
    }

    // MARK: Orphan detection

    private func detectOrphans(
        in dayDir: URL,
        knownStems: Set<String>,
        managedFileNames: Set<String>
    ) -> [OrphanInfo] {
        var orphans: [OrphanInfo] = []
        guard let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return orphans
        }

        var candidates: [String: (systemFile: URL?, micFile: URL?, modDate: Date)] = [:]

        for file in files {
            let name = file.lastPathComponent
            if managedFileNames.contains(name) { continue }
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            if name.hasSuffix(".mic.m4a") {
                let stem = String(name.dropLast(8))
                let mdPath = dayDir.appendingPathComponent("\(stem).md")
                if !fm.fileExists(atPath: mdPath.path) && !knownStems.contains(stem) {
                    var entry = candidates[stem] ?? (nil, nil, modDate)
                    entry.micFile = file
                    if modDate < entry.modDate { entry.modDate = modDate }
                    candidates[stem] = entry
                }
            } else if name.hasSuffix(".m4a") && !name.hasSuffix(".mic.m4a") {
                let stem = String(name.dropLast(4))
                let mdPath = dayDir.appendingPathComponent("\(stem).md")
                if !fm.fileExists(atPath: mdPath.path) && !knownStems.contains(stem) {
                    var entry = candidates[stem] ?? (nil, nil, modDate)
                    entry.systemFile = file
                    if modDate < entry.modDate { entry.modDate = modDate }
                    candidates[stem] = entry
                }
            }
        }

        for (stem, info) in candidates {
            orphans.append(OrphanInfo(
                stem: stem, dayDir: dayDir,
                systemFile: info.systemFile,
                micFile: info.micFile,
                modDate: info.modDate
            ))
        }

        return orphans
    }

    // MARK: Orphan recovery actions

    func recoverOrphan(_ orphan: OrphanInfo) async {
        await MainActor.run { self.isRecovering = true }
        defer { Transcriber.shared.releaseModels() }

        var sysText = ""
        var micText = ""

        if let sysFile = orphan.systemFile {
            do {
                sysText = try await Transcriber.shared.transcribe(
                    filePath: sysFile.path, baseOffset: 0)
            } catch {
                sysText = "[transcribe error: \(error.localizedDescription)]"
            }
        }

        if let micFile = orphan.micFile {
            do {
                micText = try await Transcriber.shared.transcribe(
                    filePath: micFile.path, baseOffset: 0)
            } catch {
                micText = "[transcribe error: \(error.localizedDescription)]"
            }
        }

        let finalSysText = sysText
        let finalMicText = micText
        await MainActor.run {
            addSession(
                stem: orphan.stem,
                title: orphan.stem,
                dayDir: orphan.dayDir,
                startTime: orphan.modDate,
                systemText: finalSysText,
                micText: finalMicText,
                hasMicFile: orphan.micFile != nil,
                duration: 0,
                flaggedOffsets: [],
                notes: [],
                totalPausedDuration: 0
            )
            self.isRecovering = false
            self.orphanSessions.removeAll(where: { $0.id == orphan.id })
        }
    }

    func deleteOrphan(_ orphan: OrphanInfo) {
        if let sys = orphan.systemFile {
            try? fm.trashItem(at: sys, resultingItemURL: nil)
        }
        if let mic = orphan.micFile {
            try? fm.trashItem(at: mic, resultingItemURL: nil)
        }
        DispatchQueue.main.async {
            self.orphanSessions.removeAll(where: { $0.id == orphan.id })
        }
    }

    // MARK: Session management

    @MainActor
    func beginProcessingSession(metadata: SessionMetadataV1, dayDir: URL) {
        let session = session(from: metadata, dayDir: dayDir)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        selectedSession = session.id
    }

    @MainActor
    func completeProcessingSession(
        metadata: SessionMetadataV1,
        dayDir: URL,
        systemText: String,
        microphoneText: String
    ) throws {
        let interleaved = interleaveTranscript(
            systemText: systemText,
            micText: microphoneText,
            startTime: metadata.startTime,
            duration: metadata.durationSeconds,
            flaggedOffsets: metadata.flags,
            notes: metadata.notes.map { ($0.timestamp, $0.text) }
        )
        let systemLineCount = transcriptLineCount(systemText)
        let microphoneLineCount = transcriptLineCount(microphoneText)
        let header = mdHeader(
            title: metadata.title,
            startTime: metadata.startTime,
            duration: metadata.durationSeconds,
            youCount: microphoneLineCount,
            themCount: systemLineCount
        )
        let content = header + "\n" + interleaved
        let transcriptURL = dayDir.appendingPathComponent(metadata.transcriptFilename)
        try Data(content.utf8).write(to: transcriptURL, options: [.atomic])

        var completedMetadata = metadata
        completedMetadata.processingState = .ready
        completedMetadata.failureMessage = nil
        try persist(completedMetadata, in: dayDir)

        let completedSession = session(from: completedMetadata, dayDir: dayDir)
        replaceSession(completedSession)
        cacheTranscriptContent(content, for: completedSession.id)
        selectedSession = completedSession.id
    }

    @MainActor
    func failProcessingSession(
        metadata: SessionMetadataV1,
        dayDir: URL,
        message: String
    ) {
        var failedMetadata = metadata
        failedMetadata.processingState = .failed
        failedMetadata.failureMessage = message
        try? persist(failedMetadata, in: dayDir)
        let failedSession = session(from: failedMetadata, dayDir: dayDir)
        replaceSession(failedSession)
        selectedSession = failedSession.id
    }

    @MainActor
    func retryTranscription(for session: Session) {
        guard let metadataFilename = session.metadataFilename else { return }
        let directory = URL(fileURLWithPath: session.dayDir, isDirectory: true)
        let metadataURL = directory.appendingPathComponent(metadataFilename)
        guard var metadata = try? SessionMetadataIO.read(from: metadataURL) else { return }

        metadata.processingState = .transcribing
        metadata.failureMessage = nil
        metadata.selectedModel = SettingsStore.shared.selectedModel
        try? persist(metadata, in: directory)
        replaceSession(self.session(from: metadata, dayDir: directory))

        Task {
            defer { Transcriber.shared.releaseModels() }
            do {
                guard let systemFilename = metadata.systemAudioFilename else {
                    throw NSError(
                        domain: "CounterfoilTranscription",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The system audio file is unavailable."]
                    )
                }
                let systemURL = directory.appendingPathComponent(systemFilename)
                let systemText = try await Transcriber.shared.transcribe(
                    filePath: systemURL.path,
                    baseOffset: 0
                )
                var microphoneText = ""
                if let microphoneFilename = metadata.microphoneAudioFilename {
                    let microphoneURL = directory.appendingPathComponent(microphoneFilename)
                    if fm.fileExists(atPath: microphoneURL.path) {
                        microphoneText = try await Transcriber.shared.transcribe(
                            filePath: microphoneURL.path,
                            baseOffset: 0
                        )
                    }
                }
                try completeProcessingSession(
                    metadata: metadata,
                    dayDir: directory,
                    systemText: systemText,
                    microphoneText: microphoneText
                )
            } catch {
                failProcessingSession(
                    metadata: metadata,
                    dayDir: directory,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func transcriptLineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private func persist(_ metadata: SessionMetadataV1, in directory: URL) throws {
        let metadataURL = directory.appendingPathComponent("\(metadata.stem).json")
        try SessionMetadataIO.write(metadata, to: metadataURL)
    }

    private func session(from metadata: SessionMetadataV1, dayDir: URL) -> Session {
        let systemExists = metadata.systemAudioFilename.map {
            fm.fileExists(atPath: dayDir.appendingPathComponent($0).path)
        } ?? false
        let microphoneExists = metadata.microphoneAudioFilename.map {
            fm.fileExists(atPath: dayDir.appendingPathComponent($0).path)
        } ?? false
        let transcriptExists = fm.fileExists(
            atPath: dayDir.appendingPathComponent(metadata.transcriptFilename).path
        )
        return Session(
            id: metadata.id.uuidString.lowercased(),
            stem: metadata.stem,
            title: metadata.title,
            startTime: metadata.startTime,
            duration: metadata.durationSeconds,
            hasSystemFile: systemExists,
            hasMicFile: microphoneExists,
            hasTranscript: transcriptExists,
            dayDir: dayDir.path,
            processingState: transcriptExists ? .ready : metadata.processingState,
            failureMessage: metadata.failureMessage,
            systemAudioFilename: metadata.systemAudioFilename,
            microphoneAudioFilename: metadata.microphoneAudioFilename,
            transcriptFilename: metadata.transcriptFilename,
            metadataFilename: "\(metadata.stem).json"
        )
    }

    @MainActor
    private func replaceSession(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
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
            // load the transcript content NOW so the detail pane doesn't
            // sit on "Loading..." (selection set programmatically bypasses
            // the sidebar Binding setter that normally calls loadTranscript)
            if let content = try? String(contentsOf: mdPath, encoding: .utf8) {
                self.cacheTranscriptContent(content, for: session.id)
            }
        }
    }

    func loadTranscript(for session: Session) {
        if transcriptContent[session.id] != nil {
            touchTranscriptCache(session.id)
            return
        }

        let mdPath = (session.dayDir as NSString).appendingPathComponent(session.transcriptFilename)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let content = try? String(contentsOfFile: mdPath, encoding: .utf8) else { return }

            DispatchQueue.main.async {
                guard self.transcriptContent[session.id] == nil else {
                    self.touchTranscriptCache(session.id)
                    return
                }
                self.cacheTranscriptContent(content, for: session.id)
            }
        }
    }

    func removeFlag(from session: Session, at lineIndex: Int) {
        rewriteTranscript(for: session, at: lineIndex) { lines, index in
            guard let annotation = transcriptAnnotation(from: lines[index]), annotation.kind == .flag else {
                return nil
            }
            var updatedLines = lines
            updatedLines.remove(at: index)
            return updatedLines
        }
    }

    func removeNote(from session: Session, at lineIndex: Int) {
        rewriteTranscript(for: session, at: lineIndex) { lines, index in
            guard let annotation = transcriptAnnotation(from: lines[index]), annotation.kind == .note else {
                return nil
            }
            var updatedLines = lines
            updatedLines.remove(at: index)
            return updatedLines
        }
    }

    func updateNote(in session: Session, at lineIndex: Int, with text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            removeNote(from: session, at: lineIndex)
            return
        }

        rewriteTranscript(for: session, at: lineIndex) { lines, index in
            guard let annotation = transcriptAnnotation(from: lines[index]), annotation.kind == .note else {
                return nil
            }
            var updatedLines = lines
            updatedLines[index] = replacingNoteText(in: lines[index], with: trimmedText)
            return updatedLines
        }
    }

    func deleteAudioFiles(_ session: Session) {
        let systemPaths: [String]
        if let filename = session.systemAudioFilename {
            systemPaths = [(session.dayDir as NSString).appendingPathComponent(filename)]
        } else {
            systemPaths = [
                (session.dayDir as NSString).appendingPathComponent("\(session.stem).mp4"),
                (session.dayDir as NSString).appendingPathComponent("\(session.stem).m4a"),
            ]
        }
        let microphonePath = (session.dayDir as NSString).appendingPathComponent(
            session.microphoneAudioFilename ?? "\(session.stem).mic.m4a"
        )

        for sp in systemPaths {
            let url = URL(fileURLWithPath: sp)
            if fm.fileExists(atPath: sp) {
                _ = try? fm.trashItem(at: url, resultingItemURL: nil)
            }
        }
        let micURL = URL(fileURLWithPath: microphonePath)
        if fm.fileExists(atPath: microphonePath) {
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
                    dayDir: updated.dayDir,
                    processingState: updated.processingState,
                    failureMessage: updated.failureMessage,
                    systemAudioFilename: updated.systemAudioFilename,
                    microphoneAudioFilename: updated.microphoneAudioFilename,
                    transcriptFilename: updated.transcriptFilename,
                    metadataFilename: updated.metadataFilename
                )
                self.sessions[idx] = updatedSession
            }
        }
    }

    func deleteEverything(_ session: Session) {
        deleteAudioFiles(session)
        let mdPath = (session.dayDir as NSString).appendingPathComponent(session.transcriptFilename)
        let mdURL = URL(fileURLWithPath: mdPath)
        if fm.fileExists(atPath: mdPath) {
            _ = try? fm.trashItem(at: mdURL, resultingItemURL: nil)
        }
        if let metadataFilename = session.metadataFilename {
            let metadataPath = (session.dayDir as NSString).appendingPathComponent(metadataFilename)
            if fm.fileExists(atPath: metadataPath) {
                _ = try? fm.trashItem(at: URL(fileURLWithPath: metadataPath), resultingItemURL: nil)
            }
        }
        DispatchQueue.main.async {
            self.sessions.removeAll(where: { $0.id == session.id })
            self.transcriptContent.removeValue(forKey: session.id)
            self.searchIndexes.removeValue(forKey: session.id)
            self.sessionAnnotations.removeValue(forKey: session.id)
            self.transcriptAccessOrder.removeAll(where: { $0 == session.id })
            if self.selectedSession == session.id {
                self.selectedSession = nil
            }
        }
    }

    func deleteSession(_ session: Session) {
        deleteAudioFiles(session)
    }

    func autoDeleteOldAudio() {
        if !SettingsStore.shared.autoDeleteEnabled { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for session in sessions {
            guard session.hasSystemFile || session.hasMicFile else { continue }
            let sysPaths = session.systemAudioFilename.map {
                [(session.dayDir as NSString).appendingPathComponent($0)]
            } ?? [
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
            let micPath = (session.dayDir as NSString).appendingPathComponent(
                session.microphoneAudioFilename ?? "\(session.stem).mic.m4a"
            )
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
        if SettingsStore.shared.autoDeleteEnabled {
            autoDeleteTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                self?.autoDeleteOldAudio()
            }
        }
    }

    private func cacheTranscriptContent(_ content: String, for sessionID: String) {
        transcriptContent[sessionID] = content
        searchIndexes[sessionID] = TranscriptSearchSupport.makeIndex(from: content)
        refreshAnnotations(for: sessionID, content: content)
        transcriptAccessOrder.removeAll(where: { $0 == sessionID })
        transcriptAccessOrder.append(sessionID)
        trimTranscriptCache()
    }

    private func touchTranscriptCache(_ sessionID: String) {
        transcriptAccessOrder.removeAll(where: { $0 == sessionID })
        transcriptAccessOrder.append(sessionID)
        trimTranscriptCache()
    }

    private func trimTranscriptCache() {
        while transcriptAccessOrder.count > transcriptCacheLimit {
            guard let removalIndex = transcriptAccessOrder.firstIndex(where: { $0 != selectedSession }) else {
                break
            }
            let sessionID = transcriptAccessOrder.remove(at: removalIndex)
            transcriptContent.removeValue(forKey: sessionID)
            sessionAnnotations.removeValue(forKey: sessionID)
        }
    }

    private func refreshAnnotations(for sessionID: String, content: String) {
        var annotations = TranscriptAnnotations()
        for (lineIndex, rawLine) in content.components(separatedBy: "\n").enumerated() {
            guard let annotation = transcriptAnnotation(from: rawLine) else { continue }
            switch annotation.kind {
            case .flag:
                annotations.flags.append(annotation.timestamp)
            case .note:
                annotations.notes.append(StoredTranscriptNote(
                    id: lineIndex,
                    timestamp: annotation.timestamp,
                    text: annotation.text ?? ""
                ))
            }
        }
        sessionAnnotations[sessionID] = annotations
    }

    private func rewriteTranscript(
        for session: Session,
        at lineIndex: Int,
        transform: ([String], Int) -> [String]?
    ) {
        let mdURL = URL(fileURLWithPath: session.dayDir, isDirectory: true)
            .appendingPathComponent(session.transcriptFilename)
        let content: String
        if let loaded = transcriptContent[session.id] {
            content = loaded
        } else if let loaded = try? String(contentsOf: mdURL, encoding: .utf8) {
            content = loaded
        } else {
            return
        }

        let lines = content.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex), let updatedLines = transform(lines, lineIndex) else {
            return
        }

        let updatedContent = updatedLines.joined(separator: "\n")
        guard let data = updatedContent.data(using: .utf8) else { return }
        do {
            try data.write(to: mdURL, options: [.atomic])
            cacheTranscriptContent(updatedContent, for: session.id)
        } catch {
            print("transcript rewrite error: \(error)")
        }
    }

    private func replacingNoteText(in rawLine: String, with text: String) -> String {
        let leading = String(rawLine.prefix { $0 == " " || $0 == "\t" })
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "["),
              let close = trimmed.firstIndex(of: "]"),
              close > open else { return rawLine }

        let timestampToken = String(trimmed[open...close])
        let isBold = trimmed.hasPrefix("**") && trimmed.hasSuffix("**")
        let replacement = timestampToken + " NOTE: " + text
        return leading + (isBold ? "**" : "") + replacement + (isBold ? "**" : "")
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
            return "No transcript available"
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

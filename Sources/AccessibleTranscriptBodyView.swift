import SwiftUI
import AppKit
import Combine

private enum AccessibleTranscriptEventKind: Equatable {
    case meeting
    case you
    case note
    case flag
}

private struct AccessibleTranscriptEvent: Identifiable, Equatable {
    let id: Int
    let kind: AccessibleTranscriptEventKind
    let text: String
    let timestamp: TimeInterval?
    let lineIndex: Int

    var isSpeech: Bool { kind == .meeting || kind == .you }
    var isNote: Bool { kind == .note }
    var isFlag: Bool { kind == .flag }
    var isAnnotation: Bool { isNote || isFlag }
}

private struct AccessibleTranscriptEventSnapshot {
    let events: [AccessibleTranscriptEvent]
    let byID: [Int: AccessibleTranscriptEvent]
    let timedEvents: [AccessibleTranscriptEvent]
    let speechEvents: [AccessibleTranscriptEvent]
    let annotations: [AccessibleTranscriptEvent]
    let timedAnnotations: [AccessibleTranscriptEvent]
    let overviewMarks: [TranscriptOverviewMark]
    let lastTimestamp: TimeInterval

    static let empty = AccessibleTranscriptEventSnapshot(
        events: [],
        byID: [:],
        timedEvents: [],
        speechEvents: [],
        annotations: [],
        timedAnnotations: [],
        overviewMarks: [],
        lastTimestamp: 0
    )
}

private final class AccessibleTranscriptEventCache {
    private var source: String?
    private var cachedSnapshot = AccessibleTranscriptEventSnapshot.empty

    func snapshot(
        for source: String,
        parse: () -> [AccessibleTranscriptEvent]
    ) -> AccessibleTranscriptEventSnapshot {
        if self.source == source {
            return cachedSnapshot
        }

        let events = parse()
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let timedEvents = events
            .filter { $0.timestamp != nil }
            .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        let speechEvents = timedEvents.filter(\.isSpeech)
        let annotations = events.filter(\.isAnnotation)
        let timedAnnotations = timedEvents.filter(\.isAnnotation)
        let overviewMarks = timedEvents.map { event in
            let kind: TranscriptOverviewMarkKind
            switch event.kind {
            case .meeting, .you: kind = .speech
            case .note: kind = .note
            case .flag: kind = .flag
            }
            return TranscriptOverviewMark(id: event.id, timestamp: event.timestamp ?? 0, kind: kind)
        }
        let snapshot = AccessibleTranscriptEventSnapshot(
            events: events,
            byID: byID,
            timedEvents: timedEvents,
            speechEvents: speechEvents,
            annotations: annotations,
            timedAnnotations: timedAnnotations,
            overviewMarks: overviewMarks,
            lastTimestamp: timedEvents.last?.timestamp ?? 0
        )
        self.source = source
        cachedSnapshot = snapshot
        return snapshot
    }
}

struct AccessibleTranscriptBodyView: View {
    let session: Session
    @ObservedObject var store: TranscriptStore
    let player: TranscriptPlayer
    let reduceMotion: Bool

    @State private var eventCache = AccessibleTranscriptEventCache()
    @State private var playbackTime: TimeInterval = 0
    @State private var playbackDuration: TimeInterval = 0
    @State private var playbackIsPlaying = false
    @State private var playbackHasAudio = false
    @State private var collapsedNoteIDs: Set<Int> = []
    @State private var editingNoteID: Int?
    @State private var noteEditText = ""
    @State private var searchCursor = 0
    @State private var transcriptPositionTime: TimeInterval?
    @State private var followPlayback = true
    @FocusState private var noteEditorFocused: Bool

    private let accent = Color(nsColor: .systemRed)

    private var source: String {
        store.transcriptContent[session.id] ?? ""
    }

    private var snapshot: AccessibleTranscriptEventSnapshot {
        eventCache.snapshot(for: source) {
            Self.parse(source)
        }
    }

    private var events: [AccessibleTranscriptEvent] { snapshot.events }
    private var annotations: [AccessibleTranscriptEvent] { snapshot.annotations }

    private var query: String {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchMatches: [AccessibleTranscriptEvent] {
        guard !query.isEmpty else { return [] }
        return events.filter(matchesSearch)
    }

    private var timelineDuration: TimeInterval {
        max(max(0.1, session.duration), max(playbackDuration, snapshot.lastTimestamp + 1))
    }

    private var activeEventID: Int? {
        guard playbackIsPlaying else { return nil }
        return activeSpeechEvent(at: playbackTime)?.id
    }

    private var displayedPosition: TimeInterval {
        if playbackIsPlaying && followPlayback {
            return playbackTime
        }
        return transcriptPositionTime ?? playbackTime
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    if events.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 64)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(events) { event in
                                eventRow(event)
                                    .id(event.id)
                                    .padding(.vertical, event.isAnnotation ? 7 : 11)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 28)
                        .padding(.top, 22)
                        .padding(.bottom, 52)
                        .frame(maxWidth: 920)
                        .frame(maxWidth: .infinity)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if shouldShowNavigator {
                        navigationBar(proxy: proxy)
                    }
                }
                .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.2) { ids in
                    guard let visible = ids
                        .compactMap({ snapshot.byID[$0] })
                        .filter({ $0.timestamp != nil })
                        .min(by: { $0.lineIndex < $1.lineIndex }),
                          let timestamp = visible.timestamp else { return }
                    transcriptPositionTime = timestamp
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .interacting {
                        followPlayback = false
                    }
                }

                if events.count >= 18 {
                    TranscriptOverviewRail(
                        marks: overviewMarks,
                        duration: timelineDuration,
                        position: displayedPosition,
                        accentColor: accent
                    ) { targetTime in
                        guard let target = nearestEvent(to: targetTime) else { return }
                        followPlayback = false
                        jump(to: target, proxy: proxy)
                    }
                    .padding(.trailing, 7)
                    .padding(.vertical, 12)
                }
            }
            .onChange(of: activeEventID) { _, id in
                guard followPlayback, playbackIsPlaying,
                      let id,
                      let event = snapshot.byID[id] else { return }
                jump(to: event, proxy: proxy, preserveFollow: true)
            }
            .onChange(of: store.searchQuery) { _, newValue in
                searchCursor = 0
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.searchScope = .all
                } else {
                    revealFirstSearchMatch(proxy: proxy)
                }
            }
            .onChange(of: store.searchScope) { _, _ in
                searchCursor = 0
                revealFirstSearchMatch(proxy: proxy)
            }
            .onChange(of: source) { _, _ in
                editingNoteID = nil
                collapsedNoteIDs.removeAll()
                searchCursor = 0
            }
            .onAppear {
                playbackTime = player.currentTime
                playbackDuration = player.duration
                playbackIsPlaying = player.isPlaying
                playbackHasAudio = player.hasAudio
            }
            .onReceive(
                player.$currentTime.throttle(
                    for: .seconds(1),
                    scheduler: RunLoop.main,
                    latest: true
                )
            ) { playbackTime = $0 }
            .onReceive(player.$duration.removeDuplicates()) { playbackDuration = $0 }
            .onReceive(player.$isPlaying.removeDuplicates()) { isPlaying in
                playbackIsPlaying = isPlaying
                if !isPlaying { playbackTime = player.currentTime }
            }
            .onReceive(player.$hasAudio.removeDuplicates()) { playbackHasAudio = $0 }
        }
    }

    private var shouldShowNavigator: Bool {
        events.count >= 18 || !query.isEmpty
    }

    private var overviewMarks: [TranscriptOverviewMark] { snapshot.overviewMarks }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No transcript available")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func eventRow(_ event: AccessibleTranscriptEvent) -> some View {
        switch event.kind {
        case .meeting:
            speechRow(event, isYou: false)
        case .you:
            speechRow(event, isYou: true)
        case .note:
            noteRow(event)
        case .flag:
            flagRow(event)
        }
    }

    @ViewBuilder
    private func speechRow(_ event: AccessibleTranscriptEvent, isYou: Bool) -> some View {
        let active = activeEventID == event.id
        if isYou {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 96)
                VStack(alignment: .trailing, spacing: 7) {
                    HStack(spacing: 7) {
                        Text("You")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        timestampText(event.timestamp)
                    }
                    Text(highlighted(event.text))
                        .font(.body)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.065))
                        }
                        .overlay {
                            if active {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(accent.opacity(0.42), lineWidth: 1)
                            }
                        }
                        .frame(maxWidth: 430, alignment: .trailing)
                }
                .frame(maxWidth: 500, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { play(event) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySpeechLabel(event, speaker: "You"))
            .contextMenu {
                Button {
                    copyText(event.text)
                } label: {
                    Label("Copy Speech", systemImage: "doc.on.doc")
                }
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? accent.opacity(0.11) : Color.primary.opacity(0.055))
                    Text("M")
                        .font(.body.weight(.medium))
                        .foregroundStyle(active ? accent : Color.primary.opacity(0.76))
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text("Meeting")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        timestampText(event.timestamp)
                    }
                    Text(highlighted(event.text))
                        .font(.body)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: 640, alignment: .leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { play(event) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySpeechLabel(event, speaker: "Meeting"))
            .contextMenu {
                Button {
                    copyText(event.text)
                } label: {
                    Label("Copy Speech", systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private func noteRow(_ event: AccessibleTranscriptEvent) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: 54, height: 1)

            if editingNoteID == event.id {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Label("Note", systemImage: "note.text")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.84))
                        Spacer()
                    }
                    TextEditor(text: $noteEditText)
                        .font(.body)
                        .foregroundStyle(Color.white.opacity(0.78))
                        .scrollContentBackground(.hidden)
                        .focused($noteEditorFocused)
                        .frame(minHeight: 54, maxHeight: 118)
                        .padding(7)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        }
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") { cancelNoteEditing() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.white.opacity(0.72))
                        Button("Save") { saveNote(event) }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(.black)
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 430, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black)
                }
            } else {
                let searchMatch = matchesSearch(event)
                let collapsed = collapsedNoteIDs.contains(event.id) && !searchMatch
                TranscriptNoteCard(
                    text: highlighted(event.text),
                    plainText: event.text,
                    collapsed: collapsed,
                    searchMatch: searchMatch,
                    onToggleCollapse: { toggleNote(event) },
                    onEdit: { beginNoteEditing(event) },
                    onCopy: { copyText(event.text) },
                    onDelete: { store.removeNote(from: session, at: event.lineIndex) }
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func flagRow(_ event: AccessibleTranscriptEvent) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: 0)
            Label("Flagged moment", systemImage: "flag.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    Capsule(style: .continuous)
                        .fill(accent.opacity(matchesSearch(event) ? 0.15 : 0.075))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(accent.opacity(matchesSearch(event) ? 0.42 : 0.14), lineWidth: 1)
                }
                .contentShape(Capsule())
                .onTapGesture { play(event) }
                .contextMenu {
                    Button(role: .destructive) {
                        store.removeFlag(from: session, at: event.lineIndex)
                    } label: {
                        Label("Remove Flag", systemImage: "flag.slash")
                    }
                }
                .accessibilityLabel(accessibilityFlagLabel(event))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func timestampText(_ timestamp: TimeInterval?) -> some View {
        if let timestamp {
            Text(formatTranscriptTimestamp(timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func navigationBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 9) {
                if !query.isEmpty {
                    Picker("Search scope", selection: $store.searchScope) {
                        ForEach(TranscriptSearchScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)

                    Text(searchMatches.isEmpty ? "No matches" : "\(min(searchCursor, searchMatches.count - 1) + 1) of \(searchMatches.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70)

                    Button { moveSearch(-1, proxy: proxy) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(searchMatches.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Previous Search Match")

                    Button { moveSearch(1, proxy: proxy) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(searchMatches.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command])
                    .help("Next Search Match")

                    Divider().frame(height: 18)
                }

                if !annotations.isEmpty {
                    Button { moveAnnotation(-1, proxy: proxy) } label: {
                        Image(systemName: "chevron.up.square")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .help("Previous Note or Flag")
                    .accessibilityLabel("Previous Note or Flag")

                    Button { moveAnnotation(1, proxy: proxy) } label: {
                        Image(systemName: "chevron.down.square")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .help("Next Note or Flag")
                    .accessibilityLabel("Next Note or Flag")
                }

                Text("\(formatTranscriptTimestamp(displayedPosition)) of \(formatTranscriptTimestamp(timelineDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if playbackHasAudio {
                    Button {
                        followPlayback.toggle()
                        if followPlayback, let active = activeSpeechEvent(at: playbackTime) {
                            jump(to: active, proxy: proxy, preserveFollow: true)
                        }
                    } label: {
                        Image(systemName: followPlayback ? "location.fill" : "location")
                            .foregroundStyle(followPlayback ? accent : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(followPlayback ? "Following playback" : "Follow playback")
                    .accessibilityLabel(followPlayback ? "Following playback" : "Follow playback")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 7)
        .padding(.bottom, 5)
    }

    private func matchesSearch(_ event: AccessibleTranscriptEvent) -> Bool {
        guard !query.isEmpty else { return false }
        let scopeAllows: Bool
        switch store.searchScope {
        case .all: scopeAllows = true
        case .speech: scopeAllows = event.isSpeech
        case .notes: scopeAllows = event.isNote
        case .flags: scopeAllows = event.isFlag
        }
        guard scopeAllows else { return false }
        if event.isFlag {
            return "flag flagged flagged moment".localizedCaseInsensitiveContains(query)
        }
        let prefix: String
        switch event.kind {
        case .meeting: prefix = "meeting "
        case .you: prefix = "you "
        case .note: prefix = "note "
        case .flag: prefix = ""
        }
        return (prefix + event.text).localizedCaseInsensitiveContains(query)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let match = text.range(of: query, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            if let range = Range(match, in: attributed) {
                attributed[range].foregroundColor = .white
                attributed[range].backgroundColor = accent
                attributed[range].font = .body.bold()
            }
            searchStart = match.upperBound
        }
        return attributed
    }

    private func play(_ event: AccessibleTranscriptEvent) {
        guard let timestamp = event.timestamp, player.hasAudio else { return }
        followPlayback = true
        playbackTime = timestamp
        playbackIsPlaying = true
        player.play(from: timestamp)
    }

    private func activeSpeechEvent(at time: TimeInterval) -> AccessibleTranscriptEvent? {
        let speech = snapshot.speechEvents
        guard !speech.isEmpty else { return nil }
        let target = time + 0.05
        var low = 0
        var high = speech.count
        while low < high {
            let mid = (low + high) / 2
            if (speech[mid].timestamp ?? 0) <= target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? speech[low - 1] : nil
    }

    private func nearestEvent(to time: TimeInterval) -> AccessibleTranscriptEvent? {
        let timed = snapshot.timedEvents
        guard !timed.isEmpty else { return nil }
        var low = 0
        var high = timed.count
        while low < high {
            let mid = (low + high) / 2
            if (timed[mid].timestamp ?? 0) < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return timed[0] }
        if low == timed.count { return timed[timed.count - 1] }
        let before = timed[low - 1]
        let after = timed[low]
        return abs((before.timestamp ?? 0) - time) <= abs((after.timestamp ?? 0) - time)
            ? before
            : after
    }

    private func jump(to event: AccessibleTranscriptEvent, proxy: ScrollViewProxy, preserveFollow: Bool = false) {
        transcriptPositionTime = event.timestamp
        if !preserveFollow { followPlayback = false }
        if reduceMotion {
            proxy.scrollTo(event.id, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(event.id, anchor: .center)
            }
        }
    }

    private func revealFirstSearchMatch(proxy: ScrollViewProxy) {
        guard let first = searchMatches.first else { return }
        DispatchQueue.main.async {
            jump(to: first, proxy: proxy)
        }
    }

    private func moveSearch(_ direction: Int, proxy: ScrollViewProxy) {
        guard !searchMatches.isEmpty else { return }
        let count = searchMatches.count
        let current = min(max(searchCursor, 0), count - 1)
        searchCursor = (current + direction + count) % count
        jump(to: searchMatches[searchCursor], proxy: proxy)
    }

    private func moveAnnotation(_ direction: Int, proxy: ScrollViewProxy) {
        let timed = snapshot.timedAnnotations
        guard !timed.isEmpty else { return }
        let position = transcriptPositionTime ?? playbackTime
        let target: AccessibleTranscriptEvent
        if direction > 0 {
            target = timed.first(where: { ($0.timestamp ?? 0) > position + 0.05 }) ?? timed[0]
        } else {
            target = timed.last(where: { ($0.timestamp ?? 0) < position - 0.05 }) ?? timed[timed.count - 1]
        }
        jump(to: target, proxy: proxy)
    }

    private func toggleNote(_ event: AccessibleTranscriptEvent) {
        if collapsedNoteIDs.contains(event.id) {
            collapsedNoteIDs.remove(event.id)
        } else {
            collapsedNoteIDs.insert(event.id)
        }
    }

    private func beginNoteEditing(_ event: AccessibleTranscriptEvent) {
        collapsedNoteIDs.remove(event.id)
        editingNoteID = event.id
        noteEditText = event.text
        DispatchQueue.main.async { noteEditorFocused = true }
    }

    private func cancelNoteEditing() {
        noteEditorFocused = false
        editingNoteID = nil
        noteEditText = ""
    }

    private func saveNote(_ event: AccessibleTranscriptEvent) {
        store.updateNote(in: session, at: event.lineIndex, with: noteEditText)
        cancelNoteEditing()
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func accessibilitySpeechLabel(_ event: AccessibleTranscriptEvent, speaker: String) -> String {
        if let timestamp = event.timestamp {
            return "\(speaker), at \(formatTranscriptTimestamp(timestamp)). \(event.text)"
        }
        return "\(speaker). \(event.text)"
    }

    private func accessibilityFlagLabel(_ event: AccessibleTranscriptEvent) -> String {
        if let timestamp = event.timestamp {
            return "Flagged moment, at \(formatTranscriptTimestamp(timestamp))"
        }
        return "Flagged moment"
    }

    private static func parse(_ markdown: String) -> [AccessibleTranscriptEvent] {
        let trimmedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMarkdown.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == "No transcript available" {
            return []
        }

        var events: [AccessibleTranscriptEvent] = []
        for (lineIndex, raw) in markdown.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("# ") { continue }
            if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") && !trimmed.hasPrefix("**[") { continue }
            if trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == "No transcript available" { continue }

            guard let close = timestampCloseIndex(in: trimmed) else {
                events.append(AccessibleTranscriptEvent(
                    id: lineIndex,
                    kind: .meeting,
                    text: stripMarkdown(trimmed),
                    timestamp: nil,
                    lineIndex: lineIndex
                ))
                continue
            }

            let timestamp = timestampValue(in: trimmed, close: close)
            var payload = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            payload = stripOuterBold(payload)

            let kind: AccessibleTranscriptEventKind
            let text: String
            if payload == "[FLAG]" {
                kind = .flag
                text = "Flagged moment"
            } else if payload.hasPrefix("NOTE:") {
                kind = .note
                text = String(payload.dropFirst("NOTE:".count)).trimmingCharacters(in: .whitespaces)
            } else if payload.hasPrefix("You:**") {
                kind = .you
                text = String(payload.dropFirst("You:**".count)).trimmingCharacters(in: .whitespaces)
            } else if payload.hasPrefix("Them:**") {
                kind = .meeting
                text = String(payload.dropFirst("Them:**".count)).trimmingCharacters(in: .whitespaces)
            } else if payload.hasPrefix("You:") {
                kind = .you
                text = String(payload.dropFirst("You:".count)).trimmingCharacters(in: .whitespaces)
            } else if payload.hasPrefix("Them:") {
                kind = .meeting
                text = String(payload.dropFirst("Them:".count)).trimmingCharacters(in: .whitespaces)
            } else {
                kind = .meeting
                text = stripMarkdown(payload)
            }

            events.append(AccessibleTranscriptEvent(
                id: lineIndex,
                kind: kind,
                text: text,
                timestamp: timestamp,
                lineIndex: lineIndex
            ))
        }
        return events
    }

    private static func timestampCloseIndex(in line: String) -> String.Index? {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]"),
              close > open else { return nil }
        let timestamp = line[line.index(after: open)..<close]
        let parts = timestamp.split(separator: ":")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return close
    }

    private static func timestampValue(in line: String, close: String.Index) -> TimeInterval? {
        guard let open = line.firstIndex(of: "[") else { return nil }
        let timestamp = line[line.index(after: open)..<close]
        let parts = timestamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    private static func stripOuterBold(_ text: String) -> String {
        var result = text
        while result.hasPrefix("**") { result.removeFirst(2) }
        while result.hasSuffix("**") { result.removeLast(2) }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func stripMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

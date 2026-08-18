import Foundation

enum TranscriptSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case speech = "Speech"
    case notes = "Notes"
    case flags = "Flags"

    var id: String { rawValue }
}

struct TranscriptSearchIndex: Equatable, Sendable {
    let all: String
    let speech: String
    let notes: String
    let flags: String

    func text(for scope: TranscriptSearchScope) -> String {
        switch scope {
        case .all: return all
        case .speech: return speech
        case .notes: return notes
        case .flags: return flags
        }
    }
}

enum TranscriptSearchSupport {
    private enum Kind {
        case speech(String, String)
        case note(String)
        case flag
        case ignored
    }

    static func makeIndex(from markdown: String) -> TranscriptSearchIndex {
        var speech: [String] = []
        var notes: [String] = []
        var flags: [String] = []

        for rawLine in markdown.components(separatedBy: .newlines) {
            switch classify(rawLine) {
            case .speech(let speaker, let text):
                speech.append("\(speaker) \(text)")
            case .note(let text):
                notes.append("note \(text)")
            case .flag:
                flags.append("flag flagged flagged moment")
            case .ignored:
                break
            }
        }

        let speechText = speech.joined(separator: "\n")
        let noteText = notes.joined(separator: "\n")
        let flagText = flags.joined(separator: "\n")
        return TranscriptSearchIndex(
            all: [speechText, noteText, flagText].filter { !$0.isEmpty }.joined(separator: "\n"),
            speech: speechText,
            notes: noteText,
            flags: flagText
        )
    }

    static func context(in markdown: String, query: String, scope: TranscriptSearchScope) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        for rawLine in markdown.components(separatedBy: .newlines) {
            switch classify(rawLine) {
            case .speech(let speaker, let text):
                guard scope == .all || scope == .speech else { continue }
                guard "\(speaker) \(text)".localizedCaseInsensitiveContains(trimmedQuery) else { continue }
                return clipped("\(speaker) · \(text)")
            case .note(let text):
                guard scope == .all || scope == .notes else { continue }
                guard "note \(text)".localizedCaseInsensitiveContains(trimmedQuery) else { continue }
                return clipped("Note · \(text)")
            case .flag:
                guard scope == .all || scope == .flags else { continue }
                guard "flag flagged flagged moment".localizedCaseInsensitiveContains(trimmedQuery) else { continue }
                return "Flagged moment"
            case .ignored:
                continue
            }
        }
        return nil
    }

    private static func classify(_ rawLine: String) -> Kind {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        if trimmed.hasPrefix("# ") { return .ignored }
        if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") && !trimmed.hasPrefix("**[") {
            return .ignored
        }
        if trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == "No transcript available" {
            return .ignored
        }

        guard let close = timestampCloseIndex(in: trimmed) else {
            return .speech("Meeting", stripMarkdown(trimmed))
        }

        var payload = String(trimmed[trimmed.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        payload = stripOuterBold(payload)

        if payload == "[FLAG]" { return .flag }
        if payload.hasPrefix("NOTE:") {
            let text = String(payload.dropFirst("NOTE:".count)).trimmingCharacters(in: .whitespaces)
            return .note(text)
        }
        if payload.hasPrefix("You:**") {
            return .speech("You", String(payload.dropFirst("You:**".count)).trimmingCharacters(in: .whitespaces))
        }
        if payload.hasPrefix("Them:**") {
            return .speech("Meeting", String(payload.dropFirst("Them:**".count)).trimmingCharacters(in: .whitespaces))
        }
        if payload.hasPrefix("You:") {
            return .speech("You", String(payload.dropFirst("You:".count)).trimmingCharacters(in: .whitespaces))
        }
        if payload.hasPrefix("Them:") {
            return .speech("Meeting", String(payload.dropFirst("Them:".count)).trimmingCharacters(in: .whitespaces))
        }
        return .speech("Meeting", stripMarkdown(payload))
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

    private static func clipped(_ text: String) -> String {
        guard text.count > 94 else { return text }
        return String(text.prefix(91)) + "…"
    }
}

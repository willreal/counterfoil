import SwiftUI

enum TranscriptOverviewMarkKind {
    case speech
    case note
    case flag
}

struct TranscriptOverviewMark: Identifiable {
    let id: Int
    let timestamp: TimeInterval
    let kind: TranscriptOverviewMarkKind
}

struct TranscriptOverviewRail: View {
    let marks: [TranscriptOverviewMark]
    let duration: TimeInterval
    let position: TimeInterval
    let accentColor: Color
    let onJump: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let safeDuration = max(duration, 0.1)

            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 4)

                Canvas { context, size in
                    for mark in marks {
                        let fraction = min(max(mark.timestamp / safeDuration, 0), 1)
                        let y = CGFloat(fraction) * size.height
                        let width: CGFloat
                        let markHeight: CGFloat
                        let color: Color
                        switch mark.kind {
                        case .speech:
                            width = 6
                            markHeight = 1
                            color = Color.secondary.opacity(0.28)
                        case .note:
                            width = 10
                            markHeight = 2
                            color = Color.primary.opacity(0.72)
                        case .flag:
                            width = 12
                            markHeight = 2
                            color = accentColor
                        }
                        let rect = CGRect(
                            x: (size.width - width) / 2,
                            y: y - markHeight / 2,
                            width: width,
                            height: markHeight
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }

                Rectangle()
                    .fill(accentColor)
                    .frame(width: 14, height: 2)
                    .position(
                        x: geometry.size.width / 2,
                        y: CGFloat(min(max(position / safeDuration, 0), 1)) * height
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let fraction = min(max(value.location.y / height, 0), 1)
                        onJump(TimeInterval(fraction) * safeDuration)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Transcript overview")
            .accessibilityValue("\(formatTranscriptTimestamp(position)) of \(formatTranscriptTimestamp(safeDuration))")
            .accessibilityAdjustableAction { direction in
                let step = max(safeDuration / 20, 15)
                switch direction {
                case .increment:
                    onJump(min(position + step, safeDuration))
                case .decrement:
                    onJump(max(position - step, 0))
                @unknown default:
                    break
                }
            }
            .help("Transcript overview. Click or drag to jump through the meeting.")
        }
        .frame(width: 20)
    }
}

struct TranscriptNoteCard: View {
    let text: AttributedString
    let plainText: String
    let collapsed: Bool
    let searchMatch: Bool
    let onToggleCollapse: () -> Void
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: collapsed ? 6 : 8) {
            HStack(spacing: 8) {
                Label("Note", systemImage: "note.text")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.84))

                Spacer(minLength: 12)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.white.opacity(0.62))
                .help("Edit Note")
                .accessibilityLabel("Edit Note")

                Button(action: onToggleCollapse) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.white.opacity(0.62))
                .help(collapsed ? "Expand Note" : "Collapse Note")
                .accessibilityLabel(collapsed ? "Expand Note" : "Collapse Note")
            }

            Text(text)
                .font(.body)
                .lineSpacing(2)
                .foregroundStyle(Color.white.opacity(0.72))
                .multilineTextAlignment(.leading)
                .lineLimit(collapsed ? 1 : nil)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)
        }
        .overlay {
            if searchMatch {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.32), lineWidth: 1)
            }
        }
        .frame(maxWidth: 430, alignment: .leading)
        .contextMenu {
            Button(action: onCopy) {
                Label("Copy Note", systemImage: "doc.on.doc")
            }
            Button(action: onEdit) {
                Label("Edit Note", systemImage: "pencil")
            }
            Button(action: onToggleCollapse) {
                Label(
                    collapsed ? "Expand Note" : "Collapse Note",
                    systemImage: collapsed ? "chevron.right" : "chevron.down"
                )
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Remove Note", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note, \(collapsed ? "collapsed" : "expanded"). \(plainText)")
    }
}

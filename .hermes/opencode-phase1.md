# Counterfoil Phase 1 — Redesign (OpenCode task, attempt 2)

You are modifying the existing Counterfoil macOS app in this repo (/Users/wchai/counterfoil). The app works (v1: two-channel recorder + local Parakeet transcription). This phase is a redesign per the locked plan.

**A previous session read all the files but died before writing anything. The working tree is CLEAN except `.hermes/plan.md` (updated plan, committed state: HEAD is `e64ca40`). Do not commit unless you complete a full item; commit as you go.**

**EVERY file you need is inside this repo.** Reference code at `.hermes/reference/`, plan at `.hermes/plan.md`. Do NOT read anything outside this repo — it will be rejected and kill the session.

## Read these first (in order)
1. `.hermes/plan.md` — the locked v3 plan (authoritative)
2. `Sources/App.swift`, `Sources/CaptureManager.swift`, `Sources/Transcribe.swift`, `Sources/TranscriptStore.swift`, `Sources/Views.swift` — current state
3. `.hermes/reference/001-capture-core.swift` — validated SCK capture code (audio buffer capture pattern)
4. `build.sh`, `Info.plist`, `cli/CLIMain.swift` — build + CLI harness

## Phase 1 scope (implement ALL items)

### 1. Audio-only recording (the engine change)
Drop video entirely. No SCRecordingOutput, no MP4.
- System channel: SCStream (display filter, `capturesAudio = true`, `captureMicrophone = false`) + `SCStreamOutput` with type `.audio` → collect CMSampleBuffers → write to `.m4a` via AVAssetWriter (audio input) or AVAudioFile. Screen Recording TCC still required (SCK audio needs it). See `.hermes/reference/001-capture-core.swift` for the validated buffer-capture pattern.
- Mic channel: keep existing AVAudioEngine → .m4a (validated, unchanged).
- File extensions: `.mp4` → `.m4a` for the system channel. Session model: `hasSystemFile` semantics unchanged but file is .m4a audio, not video. Remove ALL "Video present"/"Video deleted"/video icon references from UI.

### 2. Title prompt on Record
When the user clicks Record (or ⌘R), show a small sheet first: "Meeting title" text field with placeholder (e.g. "Q3 budget review"). Enter starts recording, Cancel cancels. Empty title → auto-title "Meeting HH:mm".
- Filename stem: `Title 2026-08-07 1430` — sanitize title for filenames (strip `/ :` and other invalid chars, cap ~60 chars), append date + time.
- Session model gains a `title` field. Sidebar shows **title bold as primary line**, time + duration as secondary.
- .md header: `# <Title>` instead of `# Counterfoil`, plus a meta line: `*2026-08-07 14:30 · 42 min · You 18 · Them 24*` (duration + speaker line counts; compute from transcript).
- Filename frozen after creation (no rename in this phase).

### 3. Record control — proper red record button
Voice Memos style: idle = red circular record button (red circle with dot, e.g. `record.circle.fill` tinted red or a custom circle). Recording = red stop square + live timer (red, monospaced). Currently a plain toolbar button — make it look like a real record control. Keep ⌘R shortcut. It must be clearly visible (toolbar is fine if it reads as a record control, or center-bottom of window — your call).

### 4. Red/coral sidebar tint
Sidebar gets a warm red/coral tint: `.ultraThinMaterial` with red-tinted background or subtle coral background. Subtle, not alarm-red.

### 5. Mic mute button — REMOVE entirely
Delete the mic toggle button from the toolbar. Mic always records when present. Keep the "no microphone detected" indicator (mic.slash, secondary) for machines without a mic. Remove `micEnabled` toggle logic and the ⌘M shortcut.

### 6. Emoji removal
The 📄 in session rows goes away. Use SF Symbol (`doc.text` or similar) instead.

### 7. Markdown rendering — fix
`parseMarkdown` currently uses `interpretedSyntax: .inlineOnlyPreservingWhitespace` — headers render as literal text. Switch to full markdown parsing so `# Title`, `*meta*`, and `**[time] You:**` bold lines render properly. Keep `.textSelection(.enabled)`.

### 8. Reveal in Finder + Copy Transcript
Transcript view header gets two buttons:
- "Reveal in Finder" — NSWorkspace.shared.activateFileViewerSelecting([session file URLs])
- "Copy Transcript" — NSPasteboard.general with the raw .md content
Both with SF Symbol icons + help tooltips.

### 9. Delete UX — two explicit actions
Replace the single delete with two clear actions (context menu AND a button/menu in the transcript header):
- **Delete Audio**: trash the .m4a + .mic.m4a (FileManager.trashItem), KEEP the .md. Confirmation dialog.
- **Delete Everything**: trash audio + transcript. Confirmation dialog with stronger wording.
Rows with only a transcript show "transcript only" state (already exists, keep it).

### 10. 7-day auto-delete
On launch (and periodically while running), find sessions whose audio files are older than 7 days (file modification date) → trash the audio files automatically, KEEP transcripts. Silent, no UI, no prompt. Runs on launch + a periodic timer (e.g. hourly).

### 11. Icon fix
Info.plist is missing `CFBundleIconFile` — the .icns is built into Resources but never referenced, so the app shows the generic icon. Add `CFBundleIconFile` = `AppIcon` to Info.plist. (build.sh already converts Assets/AppIcon.png → AppIcon.icns.)

## Constraints

- Do NOT touch transcription pipeline correctness (Transcribe.swift internals beyond title/meta needs), the CLI harness, model loading/copy logic, or .md persistence format beyond the header change.
- Keep the app working on mic-less machines (Mini): system-audio-only sessions, mic channel skipped.
- Keep build.sh idempotent and passing. Run `./build.sh` after your changes — it MUST complete (app + CLI compile, bundle, sign).
- Test: launch the app (`open /Applications/Counterfoil.app`), confirm it runs and shows a window, no crash in unified log.
- Transcription regression: `build/cli/counterfoil-cli --transcribe /tmp/test.wav` (generate: `say -o /tmp/test.aiff "meeting audio segment number one discussing the quarterly plan" && afconvert /tmp/test.aiff -f WAVE -d LEI16@16000 -c 1 /tmp/test.wav`) — must output the phrase.
- The full record-test needs TCC permissions the agent doesn't have; do NOT attempt real recording. Verify capture code compiles + is structurally correct; note in the report what needs user testing.
- Git: commit as you go (use `git -c user.name="willchai" -c user.email="me@willchai.com" commit -m "..."`), do NOT push.

## Report format
- What changed (files + summary per item 1-11)
- Verification results (build, launch, CLI regression — real output)
- What needs user testing on a real Mac (recording, permissions, delete flows)
- Deviations from this task, if any

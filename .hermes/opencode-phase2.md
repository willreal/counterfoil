# Counterfoil Phase 2 — The Meeting Experience (OpenCode task)

You are extending the Counterfoil macOS app in this repo (/Users/wchai/counterfoil). Phase 1 shipped and works on real hardware (audio-only two-channel recording, title prompt, red record control, red sidebar, delete UX, 7-day auto-delete, markdown rendering, icon). This phase adds the live-meeting features.

**EVERY file you need is inside this repo.** Plan at `.hermes/plan.md` (v3, authoritative), reference code at `.hermes/reference/`. Do NOT read anything outside this repo — it will be rejected and kill the session.

## Read first (in order)
1. `.hermes/plan.md` — locked plan, Phase 2 section
2. `Sources/App.swift`, `Sources/CaptureManager.swift`, `Sources/Transcribe.swift`, `Sources/TranscriptStore.swift`, `Sources/Views.swift` — current state (Phase 1 done, all working)
3. `build.sh`, `cli/CLIMain.swift`, `Info.plist`

Current state context: `Session` has `title`, `stem`, `dayDir`, `hasSystemFile` (.m4a), `hasMicFile` (.mic.m4a), `hasTranscript` (.md). Transcription produces interleaved `**[HH:mm:ss] You:** text` / `**[HH:mm:ss] Them:** text` lines into the .md. `build.sh` compiles app + CLI harness. App is installed at /Applications/Counterfoil.app.

## Phase 2 scope (implement ALL items)

### 1. Click-to-play from transcript
Clicking a transcript line plays the audio from that moment.
- Need playback: an AVAudioPlayer or AVPlayer that can play the session's system .m4a (and/or mic .m4a) from a given time offset.
- Transcript lines carry timestamps (`[HH:mm:ss]`). Parse the timestamp from the clicked line → seek player to that offset → play.
- UI: make transcript lines tappable (Button or onTapGesture), visual affordance (hover highlight, pointer cursor). A subtle "playing" indicator on the active line while it plays.
- Controls: play/pause button in the transcript header, and while playing, auto-scroll to the active line.
- Keep it native and quiet: no big player chrome. A small play/pause control + current time in the header is enough. Playback speed control comes in item 2.
- If audio files were deleted (transcript-only session), disable playback with a tooltip.

### 2. Playback speed control
0.5x, 1x, 1.5x, 2x selector near the play control (Menu or segmented picker, quiet). Applies to the player in item 1.

### 3. Live mic level meter
While recording, show a small live level meter showing the microphone input level (the user removed the mute button; this is the reassurance that the mic is live).
- AVAudioEngine's input node already exists in the mic capture path. Install a tap (or use `AVAudioEngine.inputNode` + `installTap`) to read RMS/peak levels during recording, publish to the UI.
- UI: small horizontal level bar (or a few bars) next to the recording timer, subtle. Moves with voice. On mic-less machines, hidden (no mic = nothing to meter).
- Must NOT interfere with the existing AVAudioFile writing on the same engine — the tap coexists with the file tap; be careful with tap install on the same node (use a separate tap with the same format; AVAudioEngine supports multiple taps per node).

### 4. Keep Mac awake while recording
While recording, prevent display sleep / system sleep. Use `ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "Recording meeting")` when recording starts, `endActivity` when it stops. Simple and standard.

### 5. Flag moments during recording
During recording, the user can flag the current moment (button next to the timer + keyboard shortcut ⌥⌘F).
- CaptureManager records `flaggedTimes: [Date]` or time-offsets (relative to session start).
- On stop/transcribe, flagged moments appear in the transcript as a line: `**[HH:mm:ss] ⚑ Flagged**` (or similar) at the right position in the interleaved output.
- Button: small flag icon (flag.fill) visible only while recording, next to the timer. Shortcut ⌥⌘F (Option+Cmd+F) added to the Recording menu, only enabled while recording.
- The flag timestamp must map to the same clock as transcript timestamps (session-relative seconds → HH:mm:ss from session start time).

### 6. Pause / resume (yellow)
During recording, a pause button (yellow, distinct from the red stop). Pausing stops audio capture temporarily without ending the session.
- Yellow pause button next to the red record/stop control, only while recording.
- Pause semantics: stop the SCStream audio writing + mic engine input (or simply stop writing while keeping the stream? — cleanest: stop the AVAudioEngine and the AVAssetWriter session pause, or stop capture and resume). Implement the simplest robust approach: `pauseCapture()` stops both capture paths; `resumeCapture()` restarts them, and the session start time / timeline accounts for the paused gap (transcript timestamps must not include paused wall-clock time — offset the timeline by paused duration).
- Keyboard shortcut ⌘P (or ⌥⌘P — pick what doesn't collide; ⌘P is print but this app has no print, so ⌘P is fine) in the Recording menu.
- The yellow button is intentionally a caution color — it should read as "you probably don't want to press this" (user's explicit design request).
- Transcript timestamps must remain correct after pauses (pause duration subtracted from subsequent timestamps).

### 7. Timestamped notes during recording
During recording, the user can type a note that gets inserted into the transcript at the current moment.
- A small note field or "Add note" button while recording (button opens a tiny popover/text field; Enter commits).
- Note is timestamped at the moment it's committed (session-relative, same clock as flags).
- On transcribe, notes appear in the interleaved output at their timestamp: `**[HH:mm:ss] 📝 Note:** text` (or a clean SF-symbol-based marker; the user dislikes emoji — use a text marker like `**[HH:mm:ss] Note:**` styled distinctly, or "NOTE" in small caps — keep it clean and typographic).
- Notes must also survive even if the transcript is regenerated? No — keep it simple: notes are written into the .md at transcribe time. Store them in the session (in memory) during recording; persist them in the .md. If transcription is off (auto-transcribe toggle), notes still need to land somewhere — write them into the .md header area or a notes section. Simplest correct: always write notes into the .md regardless of transcription status (a Notes section if no transcript, interleaved if transcript exists).

## Constraints

- PURE SwiftUI, Apple-standard look, system fonts. Quiet native controls. No custom design language. The yellow pause button is the one intentional color deviation.
- Do NOT touch transcription pipeline internals (Transcribe.swift correctness), model loading, CLI harness, or the .md format beyond adding flag/note lines.
- Keep working on mic-less machines (Mini): no level meter, no mic channel; pause/flags/notes/keep-awake still work.
- `./build.sh` MUST complete (app + CLI + bundle + sign). Launch test: app opens, window shows, no crash.
- CLI regression: `build/cli/counterfoil-cli --transcribe /tmp/test.wav` (generate with say/afconvert: "meeting audio segment number one discussing the quarterly plan") → outputs the phrase.
- Real recording needs TCC the agent doesn't have — do NOT attempt real recording. Verify code compiles + structure is correct; list what needs user testing.
- Git: commit as you go (`git -c user.name="willchai" -c user.email="me@willchai.com" commit -m "..."`), do NOT push. Current HEAD: c77e29d. Do NOT modify anything outside this repo.

## Report format
- What changed (files + summary per item 1-7)
- Verification results (build, launch, CLI regression — real output)
- What needs user testing on a real Mac
- Deviations, if any

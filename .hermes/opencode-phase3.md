# Counterfoil Phase 3 — The Archive (OpenCode task)

You are extending the Counterfoil macOS app in this repo (/Users/wchai/counterfoil). Phases 1-2 shipped and work (audio-only two-channel recording, titles, red record control, delete UX, auto-delete, markdown rendering, click-to-play, playback speed, mic meter, keep-awake, flags, yellow pause/resume, timestamped notes). This phase adds the post-meeting archive features.

**EVERY file you need is inside this repo.** Plan at `.hermes/plan.md` (v3, authoritative — Phase 3 section). Reference code at `.hermes/reference/`. Do NOT read anything outside this repo — it will be rejected and kill the session.

## Read first (in order)
1. `.hermes/plan.md` — locked plan, Phase 3 section
2. `Sources/App.swift`, `Sources/CaptureManager.swift`, `Sources/Transcribe.swift`, `Sources/TranscriptStore.swift`, `Sources/Views.swift` — current state (all working)
3. `build.sh`, `cli/CLIMain.swift`, `Info.plist`

Current state context: `Session` has `title`, `stem`, `dayDir`, `hasSystemFile` (.m4a), `hasMicFile` (.mic.m4a), `hasTranscript` (.md). Transcript .md lines: `**[HH:mm:ss] You:** text` / `**[HH:mm:ss] Them:** text`, annotations `[FLAG]` and `NOTE: ...`. Recording files: `Title 2026-08-07 1430.m4a` + `.mic.m4a` + `.md` in `~/Documents/Counterfoil/<day>/`. Auto-delete (7-day) exists and runs on launch + hourly. `build.sh` compiles app + CLI harness; app installed at /Applications/Counterfoil.app. Git HEAD: 0f7e30b.

## Phase 3 scope (implement ALL items)

### 1. Search across transcripts and filenames
A search field (toolbar, with ⌘F shortcut) that searches:
- Session titles and filenames (stem)
- Transcript .md content (all sessions, or within the selected session — implement: global search across ALL sessions, results shown as matching sessions; selecting a result opens the session and highlights the matching lines)
- UI: toolbar search field; when searching, the sidebar filters to matching sessions; in the detail view, matching lines are highlighted (background tint). Clearing search restores everything. Quiet, Apple-standard (searchable modifier or a custom toolbar field — your call, must feel native).

### 2. Custom vocabulary (name training)
Settings list of replacement pairs: "always write X as Y" (e.g. "tachy board" → "Tachyboard").
- Persisted (UserDefaults or a small JSON in Application Support — pick the cleanest).
- Applied at transcription time as a post-pass on the transcribed text (both channels, before interleaving) — word-boundary-aware replacements (case-insensitive source match, preserve the replacement's casing).
- UI: settings page (item 6) gets an editable list: add/remove rows, each with "from" and "to" fields.

### 3. Silent um/uh stripping (no UI, no advertising)
Automatically strip filler words from the transcript text at transcription time (both channels): standalone `um`, `uh`, `erm`, `er`, `hmm`, `mm`, `mhm`, `uh huh` (word-boundary, case-insensitive; only standalone words, never inside words like "number" or "summer"). Also collapse doubled spaces after removal, and trim line ends. No settings, no button, no mention in UI. The .md output is simply clean. (User's stated reason: the .md files are exported to AI agents, fillers waste tokens.)

### 4. Import existing audio
User can import an audio file (m4a/wav/mp3/aiff) and it becomes a normal session:
- "Import" button in the toolbar or sidebar footer (SF Symbol `square.and.arrow.down` or similar) + file picker (NSOpenPanel via SwiftUI fileImporter).
- The imported file is copied into today's Counterfoil day folder as `<Title> 2026-08-07 HHmm.m4a` (title = filename without extension, sanitized; if a file with that name exists, append a number).
- It becomes a system-only session (no mic channel), gets transcribed immediately like a normal stop, and produces its .md. Appears in the sidebar like any other session (source could be noted subtly in the header meta if trivial, e.g. "imported" — optional).
- Transcription uses the same pipeline (convert → 15s chunks → Parakeet). Long files work (chunking already handles it).

### 5. Disk space check before recording
Before starting a recording, check free disk space; if free space is below a threshold (e.g. < 2 GB), show a warning alert and let the user choose Continue or Cancel. Only warn when below threshold (silent otherwise). Compute via `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])` on the Documents volume or `FileManager.default.attributesOfFileSystem`.

### 6. Crash recovery on launch
On launch, detect orphaned/partial sessions and offer recovery:
- What counts as orphaned: .m4a / .mic.m4a files in Counterfoil day folders that don't correspond to a known session (no session entry, or session has audio but no .md and wasn't finalized — i.e. the app died mid-recording or mid-transcribe).
- On launch, scan day folders; for each orphan, show a small banner/row in the sidebar ("Recoverable recording") with two actions: **Transcribe** (run the normal transcription on the orphan's audio → creates its .md → becomes a normal session) and **Delete** (trash the orphan files). Dismissible.
- This must not interfere with normal sessions. If no orphans, nothing shows.
- Detect "app died mid-recording": a session that was recording when the process died has audio files but no .md. A finalized session always has a .md (or a "transcript only" state). Use .md existence as the finalized marker.

### 7. Settings page (⌘,)
A proper macOS Settings window (SwiftUI `Settings` scene — automatic ⌘, hotkey, Apple-standard layout) containing:
- **Vocabulary** (item 2): editable list of replacement pairs (add/remove rows).
- **Auto-delete**: toggle on/off for the 7-day audio auto-delete + a note that transcripts are always kept.
- **Model selection**: picker listing available models in `~/Library/Application Support/Counterfoil/Models/` (currently: parakeet v2 — the dir contains Preprocessor/Encoder/Decoder/JointDecision + vocab). The picker shows installed models; if only one is installed it shows it. (The v3 model + download flow is Phase 4 — do NOT build downloading now; just the selection UI wired to whatever model dirs exist. If no models at all, show the existing "Models missing" guidance.)
- Keep it minimal and native: a TabView or Form with the sections above. System fonts, standard controls.

## Constraints

- PURE SwiftUI, Apple-standard look, system fonts, quiet native controls.
- Do NOT touch: transcription pipeline internals beyond adding the vocabulary post-pass + filler stripping (both are pure text transforms on the decoded text — keep them isolated functions), model loading, CLI harness, the .md format beyond existing conventions.
- Keep working on mic-less machines. Keep the 7-day auto-delete working.
- `./build.sh` MUST complete (app + CLI + bundle + sign). Launch test: app opens, window shows, no crash. CLI regression: `build/cli/counterfoil-cli --transcribe /tmp/test.wav` (generate with say/afconvert: "meeting audio segment number one discussing the quarterly plan") → outputs the phrase.
- Real recording needs TCC the agent doesn't have — do NOT attempt real recording. Verify code compiles + structure correct; list what needs user testing. You CAN test: import flow structure, search logic, settings UI rendering (screenshot), filler stripping + vocabulary as pure functions (write a tiny test harness if helpful — e.g. a debug CLI flag or swiftc one-off that prints the transform result; verify "um uh hello um world" → "hello world" and vocabulary replacement works).
- Git: commit as you go (`git -c user.name="willchai" -c user.email="me@willchai.com" commit -m "..."`), do NOT push. Do NOT modify anything outside this repo.

## Report format
- What changed (files + summary per item 1-7)
- Verification results (build, launch, CLI regression, filler/vocab transform tests — real output)
- What needs user testing on a real Mac
- Deviations, if any

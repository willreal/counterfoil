# Counterfoil Design Pass — Luna Ultra (gpt-5.6-luna, ultra)

You are redesigning Counterfoil, a native macOS meeting recorder + local transcriber in this repo (/Users/wchai/counterfoil). The user's directive: **"build useful, intuitive, breathtaking design. generate mockups when necessary."** The app must stay as small and lightweight as possible, using ONLY Swift (pure SwiftUI, system frameworks, no third-party deps, no bundled assets beyond the icon).

**EVERY file you need is inside this repo.** Do not read outside it (external reads are rejected). Plan at `.hermes/plan.md`. Current source: `Sources/App.swift`, `Sources/CaptureManager.swift`, `Sources/Transcribe.swift`, `Sources/TranscriptStore.swift`, `Sources/Views.swift`, `Sources/SettingsStore.swift`, `cli/CLIMain.swift`, `build.sh`, `Info.plist`. Everything works: recording (audio-only, two channels: system audio "Them" + mic "You"), local Parakeet transcription (v2 + v3), interleaved timestamped .md transcripts, click-to-play, search, vocabulary, import, crash recovery, delete UX, 7-day auto-delete.

## Design context (user's words, locked)

The app currently stuffs recording controls into the toolbar. The user hates it. Locked design decisions from the design conversation:

1. **Recording gets its own floating panel.** When recording starts, a small floating glass panel appears (liquid glass, macOS 26 native material). It can be dragged anywhere, floats above other windows, and disappears when recording stops. The MAIN WINDOW NEVER CHANGES while recording — no toolbar buttons, no timer, no red dot. The main window remains a normal, fully usable window (browse old transcripts, search) while the panel floats on top.
2. **Panel contents (top to bottom):** meeting title (small, truncated, EDITABLE — click it to edit; the filename stays frozen, the sidebar title updates), a big monospaced timer (red while recording, yellow while paused), a live mic waveform (thin strip drawing the user's voice, Voice Memos style — data comes from the existing mic RMS level), one quiet row of controls: pause (yellow), flag, note, and a big red square stop button at the bottom. The stop button is the ONLY loud element. Apple-clean, Voice Memos DNA, quiet gray glyphs, glass background, subtle blur.
3. **Notes:** the note button expands a small text field inline in the panel, ⌘↩ commits, note lands timestamped in the transcript.
4. **Flag:** button flashes briefly when pressed for feedback.
5. **⌘R must NOT exist.** Recording starts only via the record button in the main window (or the title sheet flow). Remove the ⌘R shortcut.
6. **Import = a "+" button at the bottom of the sidebar** (Mail/Notes pattern), NOT a toolbar button. Toolbar should end up nearly empty: record button only, plus anything the design genuinely needs.
7. **Search lives in the sidebar**, not the toolbar: a search field pinned at the top of the sidebar. Searches transcript content AND titles/filenames. When searching, show each hit session with a line of context under the title (Notes-style), so the user can tell which meeting actually contains the term.
8. **Sidebar date sections are collapsible** (DisclosureGroup-style), labeled "Today", "Yesterday", then dates.
9. **Two-voice transcript rendering (the signature feature).** The transcript is currently one column with speaker labels. Redesign: You and Them as two interleaved streams, visually distinct — one solid, one subtly tinted (NOT loud colors; quiet distinction, like two ribbons). The reader can follow the meeting as two conversations. This is the feature no other app has.
10. **Synced playhead.** During playback, a thin line sweeps down the transcript and the line it passes glows (Apple Music lyrics style). Click-to-play from any line already exists.
11. **A real transport bar** above the transcript: play/pause, playback speed (0.5x/1x/1.5x/2x), and a time scrubber. Currently these are scattered buttons.
12. **Waveform on every session row** in the sidebar (Voice Memos style). We have the audio files; render a light waveform per session (compute peaks once, cache).
13. **Flags as a filmstrip.** Flagged moments appear as small markers along the edge of the transcript (like a video editor timeline). Click a marker to jump to that moment.
14. **Designed empty state.** No meetings yet → a quiet, composed empty state: soft waveform glyph, "No meetings yet", nothing else. No placeholder look.
15. **Sound feedback.** Subtle native system sounds (use NSSound with system sounds like "Pop", "Tink" from /System/Library/Sounds — never bundle audio) on record start, stop, and flag.
16. **Settings redesign.** Settings is currently 4 tabs (Vocabulary, General, Models, About) and feels unintuitive. Redesign to be intuitive and calm: keep vocabulary list, auto-delete toggle, model picker (v2/v3, with download buttons for missing models — URLs are placeholders, keep them), and the privacy note ("100% local. Audio and transcripts never leave your Mac. No accounts, no cloud, no tracking."). Structure it the way the user would expect an Apple settings pane to be organized. Show installed models with status.
17. **App icon is broken for the user** (shows generic on the MacBook despite AppIcon.icns being in the bundle with CFBundleIconFile=AppIcon). Investigate and fix properly: check Info.plist (maybe CFBundleIconName needed too), the icns contents (it's generated from Assets/AppIcon.png by build.sh), and note that Dock/Finder may need re-registration (lsregister) — if it's a cache issue, document the fix in build.sh or a comment. The icon itself (red W monogram, coral) is correct — do NOT replace the asset.

## Hard constraints

- **PURE SwiftUI, system frameworks only.** No third-party UI, no custom design language, no external packages. macOS 26 native materials (liquid glass) are encouraged.
- **Lightweight is sacred:** keep the binary small (currently ~1.4MB binary / ~950KB bundle). No bundled sounds/images/fonts. SF Symbols only. The 451MB models live OUTSIDE the app in Application Support — never bundle them.
- **Audio-only recording. No video. NEVER live transcript. NEVER AI summaries.** These are locked out forever.
- **Do NOT break:** v2 + v3 transcription (blank tokens 1024/8192, stride-aware mel copy in Transcribe.swift — delicate, do not touch unless necessary), filler stripping, vocabulary, import, crash recovery, delete Audio/Everything UX, 7-day auto-delete, the CLI harness (`counterfoil-cli --transcribe`), the stable signing identity in build.sh ("Counterfoil Dev" cert, ad-hoc fallback).
- The floating panel: implement with a SwiftUI Window scene (openWindow/Window with isPresented binding) or NSPanel via representable — your call, but it must be draggable, float above other windows, and not appear in the Dock as a second app. Panel visibility must follow recording state exactly. Closing the panel should not stop recording (or it reopens on next state change — decide and keep it consistent; the stop button is the way to end).
- Quit mid-recording must still work: relaunch offers recovery (existing orphan detection). Don't break that path.
- Models preload at launch (existing). Transcription stays local and fast.

## Mockups

For the recording panel and the two-voice transcript (the two centerpiece designs), FIRST create HTML mockups under `design/mockups/` (recording-panel.html, transcript.html, sidebar.html, empty-state.html if useful) that nail the layout, spacing, colors, and hierarchy — realistic macOS-styled mockups, not wireframes. Iterate on them in your own review before touching SwiftUI. Then implement the SwiftUI to match. The mockups are deliverables the user will look at; make them beautiful. (Use system font stacks in the mockups — SF Pro / -apple-system — and the red/coral accent: primary red like #FF3B30, accent coral for You-vs-Them distinction.)

## Work order (implement ALL)

1. Recording panel (items 1-4 above): new Window scene + all controls + editable title + mic waveform + sounds on start/stop/flag. Remove recording controls from the toolbar; main window keeps only its record button.
2. Sidebar redesign: search field pinned top (item 7), collapsible day sections Today/Yesterday/dates (item 8), "+" import button bottom (item 6), waveform on session rows (item 12), remove search from toolbar.
3. Transcript redesign: two-voice rendering (item 9), synced playhead + glowing line (item 10), transport bar with scrubber + speed (item 11), flag filmstrip markers (item 13).
4. Empty state (item 14), sound feedback (item 15).
5. Settings redesign (item 16).
6. Icon fix (item 17).
7. Remove ⌘R (item 5).
8. Verify: build.sh clean, app launches (window appears, 0% CPU idle), CLI regressions for BOTH models verbatim ("meeting audio segment number one discussing the quarterly plan" — v2 and v3 via `--model parakeet-tdt-0.6b-v3-coreml`). Recording itself needs TCC + a mic — the Mini has NO mic, so do NOT attempt a real recording test; note it as user-testing. You CAN verify panel/window structure via the launch + CGWindowList approach or code inspection.

## Git

Commit as you go with `git -c user.name="willchai" -c user.email="me@willchai.com" commit -m "..."`. Do NOT push. Do NOT reset/rebase. Keep HEAD history intact.

## Report format

- Mockup summary (what you designed, where the mockups are)
- What changed per work order item (files + summary)
- Verification results with REAL output (build, launch, both CLI regressions)
- What needs user testing (recording on the MacBook, panel feel, transcript feel)
- Deviations, if any, and why

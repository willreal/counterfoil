# Counterfoil Implementation Plan (v3 — post-goal-alignment)

**Goal:** A local-first macOS meeting recorder + transcriber. Records system audio + mic as separate channels, transcribes locally with Parakeet, produces an interleaved You/Them meeting log with titles. Built publish-ready; publishing decided later.

**Fork decision (locked):** build for (b) publish-ready, publish later. Models hosted on HuggingFace (converted CoreML, Apache-2.0 compliant), in-app download flow, signing stays ad-hoc until the publish day.

**Locked-out forever:** AI summaries, live transcript, bot joins, CRM integrations, speaker diarization inside "Them".

---

## Phase 1 — The redesign (IN PROGRESS)
- **Audio-only recording** (drop video, ~7x smaller files): system audio via SCStreamOutput(.audio) buffers → .m4a; mic via AVAudioEngine → .mic.m4a (unchanged). No SCRecordingOutput, no video.
- **Title prompt on Record** → titled files (`Title 2026-08-07 1430.m4a`), titled sidebar rows, `# Title` + meta line in the .md.
- **Record control**: proper red record button (red circle + dot idle, red square + timer recording), Voice Memos style.
- **Red/coral sidebar tint.**
- **Mic mute button removed entirely** (mic always records when present).
- **Emoji removed** (📄 → SF Symbol).
- **Markdown rendering fixed** (full parsing, headers + styled speaker lines).
- **Reveal in Finder + Copy Transcript buttons.**
- **Delete UX**: Delete Audio (trash .m4a files, keep .md) + Delete Everything (trash all). Explicit buttons.
- **7-day auto-delete** of audio files (transcripts always kept), runs on launch.
- **Icon fixed** (CFBundleIconFile in Info.plist).

**Done when:** record a titled meeting, see title in sidebar, transcript renders like a document, delete audio keeps .md, old audio auto-trashes after 7 days.

## Phase 2 — The meeting experience
Click-to-play from transcript + playback speed · live mic level meter · keep Mac awake while recording · flag moments (button + ⌥⌘F) · yellow pause/resume · timestamped notes woven into transcript.

## Phase 3 — The archive
Search across content + filenames · custom vocabulary (name training, applied at transcription) + silent um/uh stripping · import existing audio → session · disk space check · crash recovery · settings page (⌘,) with vocabulary, model selection, auto-delete toggle.

## Phase 4 — Publish-ready
Models on HuggingFace + in-app download · Parakeet V3 as settings option · privacy note in About · documented one-time signing/notarization step.

---

## Capture architecture (v3 — audio-only)

**System channel:** SCStream (display filter, `capturesAudio = true`, `captureMicrophone = false`) + `SCStreamOutput(.audio)` → write CMSampleBuffers to .m4a (AVAssetWriter audio input or AVAudioFile). NO SCRecordingOutput, NO video. Screen Recording TCC still required (SCK audio needs it).

**Mic channel:** AVCaptureDevice → AVAudioEngine → AVAudioFile .m4a (unchanged, validated). No mic device → channel skipped gracefully, UI shows mic disabled.

**Sync:** both start at same wall-clock instant; transcription times relative to file start → same t=0.

**File layout per session (same stem):**
- `Title 2026-08-07 1430.m4a` — system audio ("Them")
- `Title 2026-08-07 1430.mic.m4a` — mic ("You")
- `Title 2026-08-07 1430.md` — interleaved transcript (kept forever)

Title sanitized for filenames (strip / : etc.), capped ~60 chars. Empty title → "Meeting HH:mm". Filename frozen after creation.

**.md format:**
```markdown
# Q3 Budget Review
*2026-08-07 14:30 · 42 min · You 18 · Them 24*

**[14:30:05] You:** hi everyone
**[14:30:12] Them:** welcome, let's start
```

## Transcription pipeline
Ported from spike 003 (validated verbatim). Gotchas: encoder output [1,1024,188] stride 192/channel (slice via arr.strides), blank=1024, pad AUDIO with silence never mel, 15s chunks, zero-init LSTM states, RIFF chunk parsing. Section-level timestamps baseline. CLI harness `build/cli/counterfoil-cli --transcribe <wav>` for regression.

## Build
`build.sh` — swiftc app (Sources/*.swift) + CLI (Transcribe.swift + cli/CLIMain.swift), bundle, icon conversion, ad-hoc sign, install /Applications. Idempotent. Repo: /Users/wchai/counterfoil (private GitHub, Mini).

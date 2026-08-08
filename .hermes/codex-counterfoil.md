# Counterfoil — Build Task (Codex Sol medium)

You are building a complete native macOS app called **Counterfoil** from scratch, in this repo (`/Users/wchai/counterfoil`). The design plan is fully locked (see `.hermes/plan.md` — read it FIRST, it is the source of truth). The user has approved this plan and wants the app built now.

## What Counterfoil is

A meeting recorder + local transcriber:
- Records screen + system audio + microphone as separate channels
- Transcribes locally with NVIDIA Parakeet TDT 0.6b v2 CoreML models (no cloud, no API)
- Produces an interleaved "You vs Them" meeting log with timestamps, saved as .md
- Pure SwiftUI, Apple-standard look (macOS 26 liquid glass), swiftc-built (NO Xcode, NO external deps), arm64-only

## Locked decisions (user-approved, do NOT deviate)

1. Name Counterfoil, bundle id `com.willchai.counterfoil`
2. Recordings live in `~/Documents/Counterfoil/`, per-day subfolders
3. Per session, three files with the same stem: `meeting_YYYY-MM-DD_HHMMSS.mp4` (video + system audio), `meeting_YYYY-MM-DD_HHMMSS.mic.m4a` (mic only), `meeting_YYYY-MM-DD_HHMMSS.md` (interleaved transcript)
4. Full-screen capture only. NO window-targeted capture.
5. v1: single file per session (no rotation)
6. Auto-transcribe ON at Stop. Two passes (system track + mic file) run in PARALLEL in background
7. Delete session: trash .mp4 + .mic.m4a, KEEP the .md. Rows with only a transcript show a "transcript only" state
8. UI: PURE SwiftUI, system fonts, native controls, macOS 26 liquid-glass materials. Apple-standard look. No custom design language.
9. **NEVER**: live transcript while recording. **NEVER**: AI summary. These are permanently out of scope — do not add stubs, settings, or mentions of them.
10. Timestamps: section-level baseline (each 15s transcription section gets its section's start time; everything in it shares that stamp). Word-level timestamps ONLY as a free upgrade IF the model's per-token durations verify accurate — capture them if trivial (the decode loop already tracks frame position), but do not build complexity around them; section-level must always work.
11. Models dir: `~/Library/Application Support/Counterfoil/Models/`. On first launch, if absent, copy from `~/Library/Application Support/SpikeMeetingLogger/Models/` (source of truth, already on disk — copy, don't move). If BOTH missing, show a "Models missing" state with instructions.
12. Preload the 4 models in background at launch (kills cold-start delay).

## Architecture (from the locked plan)

**Two independent capture subsystems:**
- **System channel:** ScreenCaptureKit — `SCStream` (display filter, `capturesAudio = true`, `captureMicrophone = false`) + `SCRecordingOutput` → MP4 (video + system audio). Port from `.hermes/reference/001-capture-core.swift` (validated: 191s recording, clean video+audio; use `SCRecordingOutputConfiguration`, `config.excludesCurrentProcessAudio = true` — note: for the real app the meeting app is a separate process so excluding self is correct and required).
- **Mic channel:** AVAudioEngine — AVCaptureDevice input → AVAudioEngine → AVAudioFile (.m4a AAC). Standard macOS mic path, fully independent of SCK. If no mic device (`AVCaptureDevice.default(for: .audio)` returns nil — Mini has no mic), skip mic channel gracefully, UI shows mic disabled, transcript is "Them" only.

**Sync:** both start at the same wall-clock instant (same `Date()` when Record is clicked). Each file's audio time maps to wall-clock via its own start. Transcription word/section times are relative to file start → same t=0 → directly comparable.

**Permissions:** Screen Recording (SCK throws if missing → in-app notice + button to open the settings pane). Microphone (AVAudioEngine auth → same pattern).

## Transcription pipeline (port from spike 003)

Port from `.hermes/reference/003-parakeet-direct.swift` — this is the VALIDATED working pipeline (produced exact transcripts at ~200x realtime on Mini, ~80x on MBP warm). CRITICAL gotchas already solved there — port them exactly:
- Encoder output is `[1, 1024, 188]` with **padded stride 192 per channel** — slice via `arr.strides`, NOT contiguous 188 math
- Blank token = 1024 (vocab_size − 1)
- Pad AUDIO with silence (never pad mel — FastConformer full attention poisons on padded mel)
- 15s chunks (1501 mel frames), encoder requires exactly 1501 frames
- Decoder LSTM states must be explicitly zero-initialized
- WAV data may start at offset ≠ 44 (metadata chunks) — parse RIFF chunks properly
- Preprocessor output mel shape [1, 128, frames], mel_length from output

The app's transcription entry: convert MP4 system track + mic .m4a to 16k mono PCM (AVAsset/AVAudioFile), chunk 15s, preprocess → encode → decode per chunk, collect section start times.

**EVERY file you need is inside this repo** — reference code is at `.hermes/reference/` (001-capture-core.swift, 003-parakeet-direct.swift, 004-app-shell.swift), the plan is `.hermes/plan.md`. Do NOT attempt to read anything outside this repo — it will be rejected and kill the session.

**Models:** Preprocessor, Encoder, Decoder, JointDecision (.mlmodelc) + parakeet_vocab.json, all in the Models dir.

## File structure to create

```
/Users/wchai/counterfoil/
├── build.sh                  # swiftc compile → .app bundle → ad-hoc sign → install to /Applications (Mini) 
├── Info.plist                # CFBundleIdentifier com.willchai.counterfoil, usage descriptions
├── Assets/AppIcon.png        # user's icon (exists — use it, do NOT replace; convert to .icns for the bundle)
├── Sources/
│   ├── App.swift             # @main, WindowGroup, menu commands (Cmd+R record), model preload at launch
│   ├── CaptureManager.swift  # SCK stream + SCRecordingOutput + AVAudioEngine mic
│   ├── Transcribe.swift      # Parakeet port: preprocess/encode/decode + section times
│   ├── TranscriptStore.swift # interleave, .md persistence, session list, delete
│   └── Views.swift           # sidebar list + log pane + toolbar + settings
└── README.md
```

## UI spec

- One window. Toolbar: Record/Stop button (red recording dot + timer while active), mic toggle (disabled if no mic).
- NavigationSplitView: sidebar = sessions grouped by day (date, duration, transcript status badge); main pane = interleaved log with speaker labels (You = primary, Them = secondary color, subtle).
- Sidebar/toolbar use `.ultraThinMaterial` (liquid glass); content readable white.
- Delete: trash icon per row → confirmation → `FileManager.trashItem` on .mp4 + .mic.m4a (recoverable), .md stays; row becomes "transcript only".
- Empty states: "No recordings yet" · "Models missing" (with setup path) · "Permission needed" (button to open System Settings pane).
- Apple-standard: system fonts, native controls, standard window chrome.

## build.sh requirements

```bash
#!/bin/bash
# swiftc compile all Sources/*.swift → Counterfoil binary
# assemble Counterfoil.app bundle (Info.plist, binary, Resources/AppIcon.icns)
# convert Assets/AppIcon.png → .icns (sips + iconutil)
# codesign --force --sign - 
# cp -R to /Applications
```
Must be idempotent (safe to re-run). Use `swiftc -O -swift-version 5 -parse-as-library Sources/*.swift -o ...`.

## Verification (do all of these, report results)

1. `./build.sh` completes, app bundle exists, `codesign -dv` shows valid signature
2. Launch test: `open /Applications/Counterfoil.app`, verify process alive, screenshot the window (screencapture), verify no crash in log
3. **Transcription regression** (critical): build a small CLI harness or add a hidden `--transcribe <wav>` mode to the app binary that runs the pipeline and prints text. Test with real speech: generate a test WAV with `say -o /tmp/test.aiff "meeting audio segment number one discussing the quarterly plan" && afconvert /tmp/test.aiff -f WAVE -d LEI16@16000 -c 1 /tmp/test.wav`, then transcribe it. EXPECT: the spoken phrase comes out (close to verbatim, punctuation may differ). This proves the ported pipeline works.
4. Check the two-channel recording code paths compile and the mic-less path works on this machine (Mini has NO mic — run the app, start recording, verify MP4 gets created with video+system audio, mic channel gracefully disabled)

## Git

Commit as you go (frequent commits). Do NOT push, do NOT create the GitHub repo — Hermes handles remote setup after you finish. Do NOT modify files outside this repo.

## Report format (final message)

- What was built (files + line counts)
- Verification results for each check above (real output, not claims)
- Any deviations from the plan (with reasons)
- Known issues / what needs user testing

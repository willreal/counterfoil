# Counterfoil Implementation Plan (v2 — deepened)

> **For Hermes:** implement task-by-task; port validated code from spikes, don't reinvent.

**Goal:** A native macOS meeting recorder that captures screen + system audio + mic as separate channels, transcribes locally with Parakeet, and produces an interleaved "You vs Them" meeting log with per-word timestamps.

**Architecture:** Windowed SwiftUI app (macOS 26+, arm64-only, swiftc build, zero external deps). Two independent capture subsystems, each doing what it's proven at: (A) ScreenCaptureKit → MP4 with video + system audio (validated in spike 001), (B) AVAudioEngine → mic .m4a (the standard macOS mic API, fully independent of SCK). Parakeet TDT CoreML pipeline ported from spike 003 (validated, ~80x realtime warm). Interleave = merge two time-stamped word streams.

---

## Decisions (locked with user)

1. **Name / bundle id:** Counterfoil, `com.willchai.counterfoil`
2. **Recording location:** `~/Documents/Counterfoil/`, per-day subfolders. iCloud syncs both Macs; noted tradeoff, easy to move later.
3. **File layout per session** (same stem, three extensions):
   - `meeting_2026-08-07_143000.mp4` — video + system audio (plays normally; source of "Them")
   - `meeting_2026-08-07_143000.mic.m4a` — microphone only (source of "You")
   - `meeting_2026-08-07_143000.md` — interleaved transcript (kept forever)
4. **Capture target:** full screen only. Window-targeting dropped (user: "what's the point").
5. **Chunking:** v1 single file per session; transcription internally processes 15s chunks. File rotation Phase 2.
6. **Auto-transcribe:** ON at Stop. Two passes (sys + mic) run in parallel in background.
7. **Delete session:** trashes .mp4 + .mic.m4a, KEEPS .md (user spec). Rows with only a transcript get a "transcript only" state.
8. **UI:** PURE SwiftUI, Apple-standard look. System fonts, native controls, macOS 26 liquid-glass materials. No custom design language (user: "I want it to look like an Apple app").
9. **Repo:** private GitHub `counterfoil`, built on Mini, installed on both Macs.
10. **AI summary: NEVER** (user locked: "I never want an AI summary"). **Live transcript while recording: NEVER** (user locked). Both are out of scope permanently, not deferred.

---

## Capture architecture (the key thinking)

**Why two subsystems instead of SCK doing everything:**
SCK can deliver mic buffers via `SCStreamOutput(.microphone)`, but mixing mic into the SCRecordingOutput file is uncontrolled — the MP4 would get mic+system blended, which ruins the "Them" channel. Configuring SCK to exclude mic from the file while still delivering mic buffers is unproven territory. AVAudioEngine mic capture is the boring, standard, 100%-proven path, completely independent, and gives us a clean separate file with zero ambiguity.

- **System channel:** SCStream (display filter, capturesAudio=true, captureMicrophone=false) + SCRecordingOutput → MP4. Exact code validated in spike 001 (191s recording, clean video+audio).
- **Mic channel:** AVCaptureDevice input → AVAudioEngine → AVAudioFile (.m4a AAC). Both start at the same wall-clock instant; AVAudioFile gets the same session start time for alignment.
- **Mini (no mic):** `AVCaptureDevice.default(for: .audio)` returns nil → mic channel skipped, UI shows mic disabled, transcript is "Them" only. Graceful, no error.

**Sync between the two files:** both start when Record is clicked (same `Date()`). Each file's audio time maps to wall-clock via its own start. Word timestamps from the transcriber are relative to file start → same t=0 → directly comparable. No sample-accurate A/V sync needed for a text log.

**Permissions:** Screen Recording (SCK throws if missing → in-app notice + button to open the settings pane). Microphone (AVAudioEngine auth → same pattern). Two one-time prompts on first Record per machine.

---

## Transcription + interleaving (the other key thinking)

**Timestamps — section-level is the baseline (user's call):** each 15s section gets its section's start time; everything in it shares that stamp. Ordering between sections is exact (section offsets are file read positions). Overlap within a section is inherently unordered — acceptable, that's the point of a log.

**Free upgrade if it proves accurate:** the model emits every word with a duration (TDT = Transducer with Duration Prediction; the decode loop already tracks each word's frame position, so capturing it is a few lines, zero extra compute). If word times verify clean in Task 4, stamp words individually within each section — same code path, better log. If mushy, ship section-level and never look back. You/Them separation itself never depends on timestamps — it comes from the two separate files.

**Utterance grouping:** tokens → words (concat, split on boundaries), words → lines: break on pause > 1.5s or sentence punctuation. Each line = one row.

**Interleave:** merge two time-sorted word streams; both files share t=0. Result rows:
`[14:30:05] You: hi everyone, thanks for joining`

**.md format** (readable everywhere, renders in GitHub/Obsidian/Discord):
```markdown
# Counterfoil — 2026-08-07 14:30
Duration 42 min · You 18 · Them 24

**[14:30:05] You:** hi everyone, thanks for joining
**[14:30:12] Them:** welcome, let's start with the budget
**[14:30:15] You:** sure, first slide
```

**Models:** `~/Library/Application Support/Counterfoil/Models/`. First launch: if absent, copy from `SpikeMeetingLogger/Models` (already on both machines; copy, don't move). Preload all 4 models in background at launch (kills the cold-start surprise; 1-2s warm). "Models missing" state in UI with a one-click setup path.

---

## App structure (all SwiftUI, swiftc-built, no Xcode)

```
~/counterfoil/
├── build.sh                  # compile → bundle → sign → install to /Applications
├── Info.plist
├── Sources/
│   ├── App.swift             # @main, WindowGroup, menu commands (Cmd+R record)
│   ├── CaptureManager.swift  # SCK stream + SCRecordingOutput + AVAudioEngine mic
│   ├── Transcribe.swift      # Parakeet port: preprocess/encode/decode + word times
│   ├── TranscriptStore.swift # interleave, .md persistence, session list, delete
│   └── Views.swift           # sidebar list + log pane + toolbar + settings
└── README.md
```

**UI sketch (Apple-standard):**
- One window. Toolbar: Record/Stop button (with red recording dot + timer while active), mic toggle.
- NavigationSplitView: sidebar = sessions grouped by day (date, duration, transcript status badge), main pane = the interleaved log with speaker labels (You = primary, Them = secondary color, subtle).
- Sidebar/toolbar use `.ultraThinMaterial` (liquid glass); content stays readable white.
- Delete: trash icon per row → confirmation → `FileManager.trashItem` on .mp4 + .mic.m4a (recoverable from Trash), .md stays; row becomes "transcript only".
- Empty states: "No recordings yet" · "Models missing" · "Permission needed" (each with the right action button).

**Transcribe-on-stop flow:** Stop → finalize both files → two parallel Tasks (sys track, mic file) → each: convert to 16k mono PCM (AVAsset, validated) → chunk 15s → preprocess/encode/decode with word times → drift-correct → interleave → write .md → refresh list. Status line shows "Transcribing 40%…". An hour of meeting ≈ ~90s of compute (2 × 45s at ~80x realtime) — acceptable; progress is visible.

**Quit mid-recording:** SCK writes progressively (spike proved a reboot leaves a valid partial MP4); mic .m4a likewise. Next launch just shows the partial session. v1: leave as-is, user deletes.

---

## Build / install / test

- **Build:** `build.sh` — swiftc (arm64, -O, macOS 26 SDK) → .app bundle → ad-hoc sign → copy to `/Applications` on Mini → rsync to MBP `/Applications` (SSH `mbp` alias works).
- **Git:** `git init` + `gh repo create counterfoil --private --source . --push` on the Mini.
- **Test sequence:**
  1. Transcriber regression: known spike WAVs → expected text (existing baseline).
  2. Two-channel integration: 2 min — user speaks + YouTube plays → MP4 audio = YouTube only, mic file = voice only (verify by playback), interleaved log correct order, word timestamps sane (±2s spot checks). If mushy → enable chunk fallback, re-verify.
  3. Long run: 10 min continuous, stability + accuracy.
  4. Delete flow: trash audio, .md survives, Trash has the files.
  5. Mini: no mic → system-only recording, transcript = Them only, no crash.
  6. MBP full loop: record a real-ish meeting (voice + call audio), both channels, fast transcribe, pretty UI, delete, re-record.
  7. Both machines: cold launch, warm launch, quit mid-record, relaunch.

## Risks (updated, honest)

| Risk | Status |
|---|---|
| Mic separation via SCK | ELIMINATED — AVAudioEngine is a separate proven path, zero SCK mic dependency |
| Word timestamps mushy | Mitigated: drift correction + chunk fallback; verified in test 2 |
| AVAudioEngine + SCK running simultaneously | Low risk on macOS (no iOS-style session conflicts); verified in test 2 |
| iCloud syncing big videos | Accepted tradeoff (user chose Documents); move folder in ~2 min if it bites |
| TCC prompts (screen + mic) | One-time per machine, in-app guidance buttons |
| Model cache recompile | One-time 34s if cache cleared; preload at launch masks it |

## Explicitly NOT in v1 / NEVER planned
- **NEVER (user locked):** live transcript while recording · AI summary
- **Phase 2 candidates (v1 not required):** file rotation · search across recordings · incremental transcript polish

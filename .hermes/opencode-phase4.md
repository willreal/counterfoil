# Counterfoil Phase 4 — Publish-Ready (OpenCode task)

You are extending the Counterfoil macOS app in this repo (/Users/wchai/counterfoil). Phases 1-3 shipped and work (audio-only recording, titles, delete UX, markdown, click-to-play, flags, pause, notes, search, vocabulary, filler stripping, import, disk check, crash recovery, settings). This phase makes the app publish-ready: model download flow, Parakeet V3 support, privacy note, signing documentation.

**EVERY file you need is inside this repo.** Plan at `.hermes/plan.md` (v3, authoritative — Phase 4 section). Reference code at `.hermes/reference/`. Do NOT read anything outside this repo — it will be rejected and kill the session.

## Read first (in order)
1. `.hermes/plan.md` — locked plan, Phase 4 section
2. `Sources/App.swift`, `Sources/CaptureManager.swift`, `Sources/Transcribe.swift`, `Sources/TranscriptStore.swift`, `Sources/Views.swift`, `Sources/SettingsStore.swift` — current state (all working)
3. `build.sh`, `cli/CLIMain.swift`, `Info.plist`

Current state context: Transcription uses Parakeet TDT models from `~/Library/Application Support/Counterfoil/Models/` — currently flat: `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecision.mlmodelc`, `config.json`, `parakeet_vocab.json` (this is Parakeet v2, 1024-token vocab, blank=1024). Settings (⌘,) has a model picker stub listing installed models. Transcriber loads the 4 models + vocab at launch (preloadModels).

**IMPORTANT — Parakeet v3 is being copied into the Models dir as `parakeet-tdt-0.6b-v3-coreml/` (subdirectory) by Hermes in parallel (rsync, ~461MB). It may not be fully present when you start — if the dir is missing/incomplete, design for it anyway and note it; do NOT wait for it. The v3 contract (verified from metadata): IDENTICAL input/output shapes to v2 (JointDecision: encoder_step [1,1024,1], decoder_step [1,640,1] → token_id/token_prob/duration [1,1,1]). Difference: vocab is 8192 entries (parakeet_v3_vocab.json, keys 0-8191, special tokens `<unk>`,`<|nospeech|>`,`<pad>` at 0/1/2), so blank token is NOT 1024. Blank = vocab_size (8192) or vocab_size-1 (8191) — determine empirically: the blank token appears at ~99% confidence on silence frames and must never map to a real word. v3 also has `parakeet_vocab.json` (same size as v3 vocab, 151122 bytes — the v3 dir has BOTH files; the v2 flat dir has one 18762-byte file).**

## Phase 4 scope (implement ALL items)

### 1. Multi-model support in Transcriber (v2 + v3)
- Model resolution: if `Models/parakeet-tdt-0.6b-v3-coreml/` exists (or the settings-selected model dir), load models from there with the v3 vocab + correct blank token; else load the flat v2 dir as today.
- Settings model picker (already stubbed) becomes functional: lists installed model dirs (scan Models/ for subdirs containing the 4 .mlmodelc files; plus the flat v2 layout as "Parakeet v2 (default)"), selection persisted in SettingsStore, applied at next transcription/preload.
- The transcriber's decode loop must use the model's own vocab size to compute blank (vocab_size - 1 or 8192 — empirical, see above) and map tokens to text from the right vocab file. Do NOT hardcode 1024.
- Keep v2 working exactly as before (it's the default and validated).

### 2. In-app model download flow
Settings gets a Models section:
- Shows installed models (from item 1) with status (Installed / version).
- If models are MISSING entirely (fresh install): Settings shows a "Download models" button + the existing "Models missing" empty state gains a download button too.
- Download: fetches a model bundle archive from a URL (see below), shows progress (ProgressView, bytes or fraction), verifies it contains the expected files (4 .mlmodelc dirs + vocab), extracts into Models/, then reloads/preloads. On failure: clear error, retry allowed.
- The download URL is a constant in the code (single place, easy to change): `https://huggingface.co/willchai/counterfoil-models/resolve/main/parakeet-v2.tar.gz` (placeholder — Hermes will host the real bundle; keep it a single `static let modelDownloadURL` so it's a one-line change). Support v2 and v3 download URLs (two constants).
- Also: a "Check for updates / Download Parakeet v3" button that fetches v3 when installed v3 is absent.
- Size note: ~450MB per model; show the size in the button title. Downloads go to a temp file, then extract (tar.gz — use Process with /usr/bin/tar, or Compression framework; tar via Process is simplest and reliable).

### 3. Privacy note in About
About panel (or Settings → About section): one-line privacy statement: "100% local. Audio and transcripts never leave your Mac. No accounts, no cloud, no tracking." Plus version + build. Apple-standard About (use the standard About panel via `NSApplication.shared.orderFrontStandardAboutPanel` or a Settings About section — your call, must be native).

### 4. Signing/notarization documentation
Create `PUBLISHING.md` in the repo root documenting the exact one-time steps to publish (for the day the user decides to):
- Apple Developer Program enrollment ($99/yr, developer.apple.com)
- Developer ID Application certificate (Xcode → Settings → Accounts, or developer.apple.com certs)
- codesign with the Developer ID identity + hardened runtime + entitlements if needed
- Notarization: `xcrun notarytool submit` + staple
- Optionally: App Store path (same certs, Archive in Xcode) — brief
- Keep it a practical checklist, not an essay. This is documentation only — do NOT change build.sh signing (stays ad-hoc for now).

### 5. Fresh-install behavior
If Models/ is empty at first launch: app opens, shows the "Models missing" empty state with a Download button (item 2), and recording is still possible but transcription shows "models needed" state. No crash. This is the publish test scenario.

## Constraints

- PURE SwiftUI, Apple-standard, system fonts, quiet native controls.
- Do NOT break: v2 transcription (default, validated — regression test REQUIRED), filler stripping, vocabulary, CLI harness, existing settings tabs.
- Do NOT attempt network calls in your verification beyond a HEAD check if useful (the HF URL is a placeholder that may 404 — the flow must handle failure gracefully; that's actually a valid test).
- `./build.sh` MUST complete. Launch test: app opens, window shows, no crash. CLI regression: `build/cli/counterfoil-cli --transcribe /tmp/test.wav` (generate with say/afconvert: "meeting audio segment number one discussing the quarterly plan") → outputs the phrase. ALSO: if v3 dir is present, add a v3 regression (same WAV, `--model v3` flag or env var on the CLI harness) — expect the same phrase (exact text may differ slightly in punctuation; must contain "meeting audio segment" and "quarterly plan").
- Real recording needs TCC — do NOT attempt. Verify code compiles + structure; list what needs user testing.
- Git: commit as you go (`git -c user.name="willchai" -c user.email="me@willchai.com" commit -m "..."`), do NOT push. Do NOT modify anything outside this repo.

## Report format
- What changed (files + summary per item 1-5)
- Verification results (build, launch, CLI v2 regression, v3 regression if possible — real output)
- What needs user testing
- Deviations, if any

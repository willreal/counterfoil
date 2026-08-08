# Counterfoil Build Batch — bugs + redesigns + onboarding (Luna Ultra, gpt-5.6-luna, ultra)

You are reworking Counterfoil (native macOS meeting recorder + local transcriber) in this repo (/Users/wchai/counterfoil). Pure SwiftUI, system frameworks only, lightweight, NO third-party deps. Everything currently works: two-channel recording (system audio "Them" + mic "You"), local Parakeet transcription (v2/v3), interleaved .md transcripts, click-to-play, search, vocabulary, import, crash recovery, delete UX, 7-day auto-delete, floating recording panel, two-voice transcript rendering. The user locked a bugfix + redesign batch and said "build this first." Implement ALL items.

**EVERY file you need is inside this repo** (Sources/*.swift, cli/CLIMain.swift, build.sh, Info.plist, Assets/AppIcon.png, design/mockups/). Do NOT read outside the repo. Read Sources/Views.swift, Sources/App.swift, Sources/CaptureManager.swift, Sources/TranscriptStore.swift, Sources/SettingsStore.swift, Sources/WaveformStore.swift first.

---

## A. BUG FIXES (user-confirmed)

### A1. Recording panel does NOT close when recording ends
The panel window stays open after Stop. Root cause candidates (verify): `dismissWindow(id:)` is called from ContentView's environment (a different window's scene) in `.onChange(of: capture.isRecording)` — this can silently fail across scenes. FIX: make RecordingPanelView observe `capture.isRecording` itself with its OWN `@Environment(\.dismissWindow)` and dismiss on false; ALSO keep the ContentView dismiss. Belt and suspenders: if environment dismiss still fails, fall back to `NSApp.windows.first { $0.identifier?.rawValue == ... }?.close()`. The panel must ALWAYS close when recording stops (success, error, or crash-recovery path).

### A2. Recording panel visual bugs: deceptive hit areas + illegible gray-on-gray
- The control buttons' clickable area is much smaller than their visible size (users click the visible button and miss). Fix: every panel button gets an explicit generous frame + `.contentShape(Rectangle())` so the entire visible button (including padding) is clickable. Consistent 32-36pt minimum hit targets.
- The liquid glass panel is mostly gray; gray text/icons are illegible. Fix: DARKEN the glass (darker material / stronger tint / explicit dark background with transparency) and LIGHTEN text (near-white primary text, brighter icon contrast). All panel text and icons must pass clear contrast on the glass.
- REMOVE the "RECORDING" caption text and the "stop when you're done" subtitle — they add nothing. The timer + red stop square communicate state. Keep only: title (editable), timer, mic waveform, control row (pause yellow / flag / note), red stop square.

### A3. App icon still broken
The user still sees a generic icon (bundle has AppIcon.icns + CFBundleIconFile=AppIcon; a previous session claimed CFBundleIconName was added and a sips fallback icns path). Investigate for REAL:
- Verify the icns actually contains the user's red-W artwork: convert it back to PNG (`sips -s format png AppIcon.icns --out /tmp/icon.png` or `iconutil -c iconset`) and inspect the pixel content (non-blank, colored, correct design). If the icns is blank/corrupt/wrong, regenerate it properly from Assets/AppIcon.png (build.sh icon pipeline) so it contains all standard sizes INCLUDING 16px (ic04/ic05/ic07/ic08/ic09/ic10/ic11/ic12/ic13/ic14 as available).
- Confirm Info.plist keys are correct for macOS 26 (CFBundleIconFile, CFBundleIconName if needed).
- Dock/Finder caching: add `touch` + LaunchServices re-registration (`lsregister -f`) of the installed app to build.sh's install step so a fresh install always shows the icon, and note in the report if the user-side fix is a Dock restart.
- Deliverable: the app's Dock/Finder icon reliably shows the red-W artwork after install.

### A4. Speed control truncates "1.5x" → reads "1...."
The playback speed control's box is too small. Fix: widen the control or use shorter labels that fit ("0.5" "1" "1.5" "2" without the ×, or "1.5×" in a wider box). Must display fully at every speed.

### A5. Empty transcript shows literal "_No transcript available_" with visible underscores
The placeholder text contains markdown emphasis characters (underscores) that render raw. Fix: plain text, no markdown markup in the empty-transcript state.

### A6. Settings elements misaligned / almost clipping
Redesign (B3) must fix alignment, spacing, and padding so no element clips or misaligns (check at default settings window size and when the window is resized small).

---

## B. REDESIGNS (user-locked)

### B1. Record button: big red liquid-glass pill, "Record Meeting", floating at bottom of sidebar, right of Import
- Remove the record button from the toolbar entirely (toolbar becomes empty/clean).
- The record control becomes a capsule pill with SF Symbol (record.circle.fill or similar) + text "Record Meeting", red accent, liquid-glass material (macOS 26 glass effect — `.glassEffect` if available, else `.ultraThinMaterial` with red tint and rounded capsule), sized generously (height ~34-38pt).
- Placement: floating at the BOTTOM of the sidebar, to the RIGHT of the Import button, in a single bottom bar (see B2). Use `.safeAreaInset(edge: .bottom)` on the sidebar (or equivalent) so it floats over content.
- Clicking it opens the existing title prompt sheet (do not change that flow). Disabled while recording.

### B2. Import button: labeled, bottom of sidebar, LEFT of Record
- The "+" icon-only button becomes a labeled pill: SF Symbol plus + text "Import" (user chose "import" exactly).
- Same bottom bar as B1: HStack [ Import pill, Spacer, Record Meeting pill ], floating at sidebar bottom with padding, liquid-glass/quiet material. Import stays disabled while recording.
- The toolbar must no longer contain import or record controls.

### B3. Settings redesign: top tabs (NO sidebar), add Permissions tab, fix alignment
- Current Settings is a TabView — the user says it renders like a sidebar and wants a TYPICAL TOP TABS menu instead. Restructure to top-aligned tabs (segmented or tab bar across the top of the settings window). If SwiftUI's TabView with `.tabViewStyle` on macOS renders side tabs, use an explicit top tab bar (Picker with segmented style + switch, or a custom top tab row) that matches macOS Settings' older top-tab look.
- Tabs: General (auto-delete toggle, model picker v2/v3), Vocabulary, Models (installed models + download buttons, keep placeholder URLs), **Permissions (NEW)**, About (privacy note).
- Permissions tab: one row per permission — Microphone and Screen Recording. Each row: name, current status (Granted / Not Granted / Unknown), a button to open the exact System Settings pane via deep link (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` and `...Privacy_ScreenCapture`), and a short explanation line. For Screen Recording, the explanation MUST include: "macOS requires screen recording permission to capture system audio, even though Counterfoil records audio only." Also a "Check status" refresh that re-reads permission state (TCC status via simple checks: mic via AVCaptureDevice authorization, screen via CGPreflightScreenCaptureAccess if available).
- Fix all alignment/clipping issues across tabs (A6).

### B4. Remove "You + Them" text
The transcript header legend "You + Them" (or similar) is redundant — the two-voice rendering already distinguishes speakers. Remove it entirely.

### B5. Notes tray: recording panel expands rightwards into a notes tray (NOT a separate window)
- The note button in the recording panel expands the panel rightwards into a tray (same window, wider) containing the note editor: a multi-line text field + hint text. ⌘↩ (or a send button) commits the note → timestamped into the transcript at the current moment (existing notes mechanism). The tray should feel like a drawer that slides out and collapses back.
- Notes only exist during a meeting — this is a meeting tool. No standalone notes outside recording.
- The expanded panel must stay within reasonable bounds (max width ~ panel + 260pt), still draggable, still floating.

---

## C. NEW FEATURE: Onboarding + setup splash (first run only, skippable)
- First launch (fresh install, or after a "show onboarding" reset): show a 3-screen onboarding window/sheet BEFORE/over the main window: (1) Welcome — what Counterfoil is, 100% local, no accounts/cloud; (2) Permissions — the Permissions-tab content as a guided flow (Mic + Screen Recording status + deep-link buttons + the system-audio explanation); (3) Ready — lands on the empty state with the big Record Meeting pill visible.
- Skippable at any point (Skip button; also ⌘W or Escape closes it and shows the main window).
- Only shows once (UserDefaults flag `hasSeenOnboarding`). Never shows again after completion or skip.
- If models are missing on first run, the onboarding Ready screen (or Welcome) shows a "Download models" affordance using the existing download flow (placeholder URLs).
- Keep it native, quiet, Apple-clean. Small window (~480x360), top tabs or page dots for the 3 steps.

---

## D. HARD CONSTRAINTS
- PURE SwiftUI, system frameworks only. macOS 26 native materials encouraged (liquid glass). No new files outside Sources/ except build artifacts. No third-party deps. Keep the binary small.
- Do NOT break: transcription (v2 blank=1024, v3 blank=8192, stride-aware mel copy in Transcribe.swift — do not touch unless a fix needs it), filler stripping, vocabulary, import, crash recovery, delete UX, 7-day auto-delete, CLI harness (counterfoil-cli --transcribe), stable signing in build.sh ("Counterfoil Dev" cert, ad-hoc fallback), ApplePersistenceIgnoreState in App.swift (window-restoration ghost bug), audio-only recording, no live transcript, no AI summaries.
- The recording panel must still: appear on record start, be draggable, float above other windows, not appear in Dock as a second app, and now ALSO close reliably on stop (A1).
- Keep ⌘R absent. Search stays in sidebar. Day sections collapsible. No toolbar recording/import controls after this batch.

## E. VERIFICATION (run what you can; the Mini has NO mic and recording needs TCC — do not attempt a real recording)
1. `./build.sh` clean, no errors.
2. App launches: window appears (CGWindowList/AX shows 1 real window), idle ~0% CPU.
3. CLI regressions BOTH models: generate speech with `say -o /tmp/t.aiff "meeting audio segment number one discussing the quarterly plan"` + `afconvert`, then `./build/cli/counterfoil-cli --transcribe /tmp/t.wav` and `--model parakeet-tdt-0.6b-v3-coreml --transcribe /tmp/t.wav` — both must return the phrase, no "warming" spam.
4. Verify by code inspection: panel self-dismiss path (A1), hit-area fixes (A2), icon pipeline (A3), speed labels (A4), no underscores placeholder (A5), toolbar emptied + sidebar bottom bar (B1/B2), top tabs + Permissions tab (B3), "You + Them" gone (B4), notes tray (B5), onboarding gating + skippability (C).
5. Onboarding is first-run UI — verify the flag logic and that the main window still appears when skipped/on subsequent launches.

## F. GIT
Commit as you go: `git -c user.name="willchai" -c user.email="me@willchai.com" commit -m "..."`. Do NOT push, reset, or rebase. Keep HEAD intact. If the sandbox blocks .git writes, leave the tree dirty and say so — Hermes will commit.

## G. REPORT
- Per item A1-A6, B1-B5, C: what changed (files + summary) and how you verified it
- Real CLI output for both models
- What needs user testing on the MacBook (panel close, tray, onboarding, permissions tab, icon on Dock)
- Deviations, if any, and why

# Counterfoil Build Batch 3 — toolbar reorganization + transcript interactions (Luna Ultra, gpt-5.6-luna, ultra)

Follow-up batch in /Users/wchai/counterfoil. Batch 2 (panel close/dark glass, sidebar Record+Import pills, settings top tabs + Permissions, notes tray, onboarding, icon, speed label, underscores, alignment) has LANDED and been committed by Hermes — read the current Sources/*.swift as the true state. Implement ALL items below.

**EVERY file you need is inside this repo.** Read Sources/Views.swift, Sources/TranscriptStore.swift, Sources/CaptureManager.swift, Sources/SettingsStore.swift, Sources/App.swift first.

## A. Toolbar reorganization

### A1. Move transcript action buttons to the top bar (toolbar), liquid glass
The buttons "Copy Transcript", "Reveal in Finder", "Delete" currently live in the transcript detail header. MOVE them to the app toolbar (top bar) as liquid glass buttons (macOS 26 glass effect / ultraThinMaterial, rounded). They act on the SELECTED session — DISABLED (grayed out, not hidden) when nothing is selected. Delete is ONE button that opens a small menu (chevron) with the two options: "Delete Audio" and "Delete Everything" (existing confirmations preserved). Toolbar layout: these actions + search (see A2). Keep it clean — icons with help tooltips or compact labeled buttons, your call; must look native and quiet.

### A2. Search bar moves to the top bar, FARTHEST RIGHT
Search leaves the sidebar entirely and goes to the top bar, rightmost position. Its placeholder text: "[magnifyingglass icon] Titles, Transcripts" — icon + placeholder text exactly: "Titles, Transcripts". Keep ⌘F focusing it. Behavior unchanged (searches titles/filenames + transcript content, context snippets in sidebar results).

## B. Sidebar item redesign

### B1. Remove the waveform from sidebar meeting rows
WaveformStore usage in the sidebar list goes away. Each row is exactly: Title (primary), subtitle underneath = DATE RECORDED + rough time to the NEAREST HOUR ("~2pm", "~11am"), and on the RIGHT side the duration. Nothing else per item.

### B2. Right-click context menu on sidebar meetings
Add a context menu on each meeting row: "Copy Transcript", "Show in Finder", "Delete Audio", "Delete Everything". Same actions as the toolbar buttons / existing delete flows (confirmations preserved). (These duplicate the A1 toolbar actions by design — context menu for right-click users.)

## C. Transcript interactions

### C1. Remove flags and notes while reading; notes editable + distinct
- When viewing a transcript, flags and notes can be REMOVED (delete a flag marker / delete a note from the transcript view). Removal is PERMANENT: updates the session's stored flags/notes AND rewrites the .md file without that flag/note (keep the rest intact, atomic write).
- Notes must stand out MORE with a colored bar. The note accent color = the same color notes use in the recording panel (currently white/light text on the dark glass — carry that identity into the transcript bar; adapt contrast for the transcript background so it stays visible, but keep the same hue/family). Flags keep their current gray/neutral bar.
- Notes are EDITABLE in place: click/tap a note to edit its text, save updates the .md and the store. (Flags stay uneditable — they're just markers.)

### C2. Remove "You + Them" AND "Transcript" header text
Both legend texts are gone. The transcript section shows no redundant label. (Batch 2 already removed "You + Them" if present — remove "Transcript" too; subtitle needs neither.)

### C3. Remove repeated title at top of transcript section
The session title is currently repeated at the top of the transcript detail. REMOVE it — the sidebar already shows the title; the detail pane starts directly with the transcript content (transport bar may stay).

### D. Auto-delete: 7 days → 30 days
- Default and copy change: "Automatically delete audio after 30 days" (Settings General tab). Transcripts still always kept. Existing auto-delete logic uses 7 * 86400 — change to 30 days. Also update any copy/tooltip mentioning 7 days.
## E. Constraints
- Pure SwiftUI, system frameworks only, no new deps, keep binary small.
- Do NOT break: batch-2 changes (panel close/dark glass, sidebar Record+Import bottom bar, settings top tabs + Permissions tab, notes tray, onboarding, icon, speed labels), transcription v2/v3, filler stripping, vocabulary, import, crash recovery, delete UX, CLI harness, stable signing in build.sh, ApplePersistenceIgnoreState, audio-only, no live transcript, no AI summaries, ⌘R absent.
- The transcript .md rewrite in C1 must preserve formatting/timestamps of untouched lines (parse lines, drop/replace the target flag/note lines, write back atomically).

## F. Verification
1. `./build.sh` clean.
2. App launches, 1 real window, ~0% CPU.
3. CLI regressions BOTH models: `say` phrase → v2 and v3 verbatim, no "warming".
4. Code inspection for every item: toolbar actions + search rightmost (A1/A2), sidebar row = title/date/duration only + context menu (B1/B2), flag/note removal + note edit + colored note bar (C1), no "You + Them"/"Transcript"/repeated title (C2/C3), 30-day constant + copy (D).
5. Note in report anything needing user testing on the MacBook.

## G. Git
Commit as you go with `git -c user.name="willchai" -c user.email="me@willchai.com" commit -m "..."`. Do NOT push/reset/rebase. If sandbox blocks .git, leave tree dirty and say so.

## H. Report
Per item: what changed + how verified. Real CLI output both models. User-testing list. Deviations.

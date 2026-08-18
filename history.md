# Counterfoil recording panel handoff

## 1. Purpose

This document records the recording panel history, the requested interaction model, the visual decisions, the known regressions, the current source state, the last installed bundle, and the performance investigation.

The recording panel is a small floating macOS window used while audio capture runs. The panel contains a meeting title, a recording clock, pause, flag, note, and stop controls, plus an expandable note tray.

The next agent should read this file before changing the recording panel. Preserve the existing project work. The repository already contains many user changes outside the panel.

## 2. Desired interaction model

The whole visible panel should drag from any empty area.

The pause, flag, note, stop, and send controls should keep their click actions.

The title should enter editing when clicked. A drag that begins on the title should move the window when the gesture becomes a drag.

The recording clock should participate in window dragging.

The note editor should accept text input and the send control should remain black.

The panel should have one continuous rounded outer surface. A lower strip, a second panel, a titlebar remnant, and square outer corners should never appear.

The pause, flag, and note controls should be smaller than the stop control, separated from one another, and rendered with native glass treatment. The flag icon should retain its red icon color while its glass surface matches the neutral controls. The stop control should use a strong red fill.

The panel background should stay darker and readable. Native glass diffraction is desired for controls. Full window diffraction requires a transparent window with one aligned material surface. A solid gray window fill gives diffraction very little background variation.

## 3. Conversation history

### 3.1 Interaction failures

The first reported issue was a recording panel with failed drag and click interaction. The notes field was unreachable. The title editing path was unavailable.

The required behavior became clear during discussion. The title needs a click target for editing. Empty title and clock space needs a drag target. Buttons need their own hit regions.

### 3.2 Visual regressions

The panel later showed a strange container above the content. The user described it as two panels overlapping. A hidden titlebar still appeared visually. Corner radiuses differed between surfaces. Some controls became bright red. The glass became too bright and reduced text legibility. Pause, flag, and note controls grew larger than the stop control.

The desired visual reference was supplied as a screenshot. It showed a compact gray panel with a small top handle, an editable meeting title, a monospaced clock, three small circular controls, a red stop control, and a note area.

The user then reported an annoying outer edge, loss of liquid glass diffraction, and a send control that needed a black appearance.

The user requested diagnosis before further code changes. The panel controls were then isolated from the panel background. Native glass styling was applied to the small controls while preserving their icon colors. The stop control used a separate red capsule treatment. This isolated styling preserved the earlier geometry better than changing the entire panel surface.

### 3.3 Regression recovery

One later pass changed many unrelated visual properties. The user requested an undo and asked that future work avoid changing random parts of the app. The working rule became narrow changes inside the recording panel, followed by a preview check and a compile check.

The bottom strip remained. The user again requested smaller pause, flag, and note controls, a full red stop control, a neutral flag surface, and an explanation of why full panel diffraction differs from individual native glass control diffraction.

The explanation established the current material constraint. An individual native glass button owns a small glass region and receives useful background variation. The panel was using a solid window fill plus SwiftUI content. A full transparent window introduced AppKit titlebar and content regions with doubled corners and a lower strip. Full panel diffraction requires one transparent window, one aligned surface, and one corner system.

### 3.4 Spacing and lower strip work

The controls visually overlapped even when their SwiftUI frames were small. The native glass style drew a larger halo than its nominal frame. The control row spacing was increased to ten points. The controls received mini control sizing and fixed thirty point frames.

The lower strip matched the reserved AppKit titlebar height. An earlier source pass added repeated window frame corrections, a resize observer, and several delayed correction calls. This reduced the visible strip in some states and introduced a strong performance risk during animation.

The window was later changed to a borderless full size content configuration. The AppKit content layer received a continuous corner radius and masking. The panel root received a rounded SwiftUI surface and clipping. Preview screenshots showed rounded corners and a continuous lower edge in compact and expanded note states.

### 3.5 Whole panel dragging

The user requested that the entire panel drag except for controls. A transparent drag surface was placed behind the visible content in a root stack. The title row also received a simultaneous window drag gesture. Buttons and text fields remained above the drag surface.

This solved several empty area cases in preview. It also introduced more gesture participation in the SwiftUI view tree. The current performance investigation treats this full panel gesture as a possible contributor and needs a dedicated AppKit drag surface test.

### 3.6 Performance report

The latest user report described roughly two frames per second. Dragging felt delayed. Tray animation felt especially slow. The user stated that the panel had been smooth earlier.

Source inspection and sampling showed the main thread spending time in AppKit window layout, SwiftUI hosting layout, SwiftUI ViewGraph updates, AttributeGraph work, and the AppKit window toolbar appearance bridge. Earlier samples also showed the repeated frame correction code running alongside content size negotiation.

The key performance risk is the combination of a SwiftUI root animation, dynamic lower tray height, window content size negotiation, TextEditor layout, full window gesture handling, native glass surfaces, and AppKit window configuration performed during view updates.

## 4. Current source state

The current source is in `/Volumes/wchai/counterfoil`.

The panel implementation is in `Sources/Views.swift`.

The recording window scene is in `Sources/App.swift`.

The deterministic preview is in `Verification/RecordingPanelPreview.swift`.

The current root panel uses a stack. A transparent `RecordingDragSurface` sits behind the visible stack. The visible stack contains the drag handle, the main surface, and the lower tray.

The panel width is 280 points. The note tray height is 146 points. The failure tray height is 190 points.

The root view has a fixed width, safe area coverage at the top and bottom, a rounded gray background, a continuous rounded clip, a window container background, and a root animation keyed to lower tray height.

The main surface contains the title text field and recording clock in one row. The row has a simultaneous window drag gesture. A small transparent drag region also separates the title from the clock.

The capture row uses ten points of spacing between the three small controls. Each small control uses a thirty point frame, mini control sizing, a circular border shape, and native glass styling. The flag keeps the red icon color while using the neutral glass tint.

The note tray contains a SwiftUI TextEditor. The send control is a black native prominent glass button with a circular border shape and a thirty six point frame.

The current lower tray height is dynamic. It is zero while the note tray is collapsed and 146 points while the note tray is expanded. Failure state uses 190 points.

The current tray animation is an ease out animation with a duration of 0.18 seconds unless reduced motion is active.

The current AppKit window surface configuration sets a clear window background, removes the titled style, keeps the full size content style, hides standard window buttons, and gives the content view a continuous sixteen point layer corner radius with masking.

The repeated frame correction system was removed from the current source during the performance investigation. The current `RecordingWindowAccessor.Coordinator` keeps the Escape key monitor and window attachment logic. It no longer owns a resize observer or delayed frame correction calls.

The current source passes Swift type checking after the cleanup described above.

## 5. Installed bundle state

The last installed bundle is `/Applications/Counterfoil.app`.

It was built before the latest performance investigation. It contains the earlier frame correction system. The current source has that system removed, so the installed binary and the source are different in this area.

The installed bundle was compiled with a direct Swift compiler invocation, signed with an ad hoc signature, and verified with deep strict code signing.

The last installed executable was produced at a temporary path named `/tmp/CounterfoilPanelFinal3` during the prior panel pass. Temporary paths can be recreated. The source remains the authoritative handoff state.

The optimized `build.sh` route entered a long whole module optimization phase during earlier work. The direct debug style compile finished reliably in roughly fifteen to thirty seconds for the panel source set. Type checking finished in roughly fifteen seconds during the latest cleanup.

## 6. Performance evidence

The most useful sample output was written under `/tmp` during the investigation. The sampled process was the deterministic recording panel preview.

The main thread call tree repeatedly entered `NSWindow.layoutIfNeeded`, `NSView.layoutSubtreeIfNeeded`, `NSHostingView.layout`, `ViewGraphRootValueUpdater.render`, `ViewGraph.updateOutputs`, and `AttributeGraph` updates.

The same samples showed `NSHostingView.updateEnvironment`, `AppKitWindowController.hostingView`, `BarAppearanceBridge.updateWindowToolbarAppearance`, and `NSLocalWindowSharingWindow` work.

The earlier source also scheduled frame correction on the main queue when the window attached, after every update, after a resize, after 0.35 seconds, and after another 0.5 seconds. This repeated work is a strong candidate for the reported lag.

The preview process often returned to near zero CPU after a state settled. During note tray opening it could reach roughly forty to seventy percent CPU in the debug preview. A frame counter was absent from the measurement. The user report of roughly two frames per second remains the primary visual measurement.

## 7. Recommended next investigation

1. Start from the current source and build a fresh deterministic preview. Keep the installed bundle separate.

2. Remove recording window content size negotiation in the preview and app scene for one test build. Use a fixed AppKit frame for compact and expanded states. This test determines whether SwiftUI and AppKit are negotiating height repeatedly.

3. Replace the root animation with a stable window frame and an internal tray transition. A tray opacity and offset transition can animate inside a fixed window. A single explicit AppKit frame change can handle height changes when the user opens the note tray.

4. Bound the TextEditor with a fixed height. Avoid an infinite maximum height inside a view whose parent height is changing.

5. Test the full panel drag gesture separately. A dedicated transparent AppKit view that calls the window drag API may produce fewer SwiftUI graph updates than a gesture attached to the full root stack.

6. Keep buttons and text fields above the drag view. Confirm button clicks, title editing, note typing, and window movement with accessibility inspection and coordinate testing.

7. Profile compact idle, title editing, window movement, note tray opening, note typing, and note tray closing separately. Use a short sample for each state and record CPU behavior.

8. Rebuild the installed bundle after the preview shows stable frame behavior and the note editor works.

## 8. Useful verification files

`Verification/RecordingPanelPreview.swift` creates a deterministic recording state with a title, duration, active channels, and menu commands for state changes.

`Verification/RecordingPanelPreviewInfo.plist` defines the preview bundle metadata.

`Sources/CaptureManager.swift` contains deterministic preview support under the debug configuration.

`Sources/App.swift` defines the production recording window scene.

`Sources/Views.swift` contains the panel layout, controls, note tray, drag surfaces, native glass modifiers, and AppKit window accessor.

`build.sh` contains the production bundle recipe, icon generation, and CLI build steps.

## 9. Worktree caution

The repository was already dirty before this handoff. The status includes changes in `.gitignore`, `Sources/App.swift`, `Sources/CaptureManager.swift`, `Sources/SettingsStore.swift`, `Sources/Transcribe.swift`, `Sources/TranscriptStore.swift`, `Sources/Views.swift`, and `build.sh`.

The status also includes a deleted `Sources/WaveformStore.swift`, a new `Package.swift`, new recording model and reliability files, a `Tests` directory, and a `Verification` directory.

Preserve these changes. Avoid broad resets or checkout operations. Make panel edits in small, reviewable patches.

## 10. Handoff summary

The visual target is close. The unresolved priority is smoothness. The strongest evidence points to AppKit and SwiftUI content size negotiation combined with repeated window frame correction and dynamic tray layout. The current source has removed repeated frame correction, restored the functional note editor, restored dynamic tray visibility, and retained the rounded borderless surface. The installed app still contains the earlier frame correction behavior.

The next agent should treat performance as a layout architecture issue. A fixed window frame with an internally animated tray is the cleanest test path. The final result should preserve the compact visual geometry, native glass controls, black send control, red stop control, title editing, full empty area dragging, and continuous rounded corners.

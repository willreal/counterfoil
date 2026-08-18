# Counterfoil engineering history

## Current recorder architecture

The recorder is a compact native macOS titled floating window. The meeting title remains large and editable inside the content. Notes are always visible. Pause and Flag are secondary controls, Stop remains red, and note submission is black with Command Return support. The recorder uses a fixed 280 point width and a fixed content layout.

System audio uses ScreenCaptureKit audio output at 48 kHz stereo. Counterfoil windows are excluded from the display filter. The unused visual stream is reduced to a tiny low frequency configuration. Microphone audio is recorded separately. Each channel persists a segment manifest containing timeline offset, initial trim, and logical duration so pause and resume can be reconstructed without channel drift.

The main navigation view does not observe the recorder clock. Capture observation is isolated to the recorder window, the live sidebar row, the record button, and a zero size lifecycle observer. This keeps one second recorder updates from invalidating the full transcript interface.

## Transcription

Parakeet V2 is the English model. Parakeet V3 is the multilingual model. Counterfoil does not label either model as inherently more accurate or as a product default. A stored user selection is used when valid. With one installed model it is selected automatically. With multiple installed models and no saved choice, Counterfoil asks the user to choose.

Production transcription jobs are serialized through TranscriptionCoordinator. A meeting snapshots its selected model and uses the same model for system and microphone transcription. CoreML models load only for the active job and release afterward. Audio decoding streams bounded 15 second PCM chunks.

Model downloads are file backed, report transfer progress, extract into a temporary staging directory, validate the complete model and vocabulary, and then move the validated model into its final directory with rollback protection.

## Sessions and recovery

Session metadata is the source of truth for title, audio filenames, processing state, flags, notes, and persisted audio segment manifests. Older metadata without segment fields remains decodable. Segment filenames are treated as managed files during startup, deletion, retention, Finder reveal, and crash recovery. Retry finalizes persisted segments onto their recorded timeline before transcription.

Meeting renaming is available from the sidebar context menu, sidebar double click, and detail title double click. Renames update metadata and the transcript heading. Processing completion reloads the latest persisted title so a rename made during transcription is preserved.

Playback builds one AVFoundation composition containing both finalized system and microphone recordings.

## Transcript performance

Raw transcript bodies use a bounded three session cache. Search stores semantic indexes rather than duplicate transcript bodies. Parsed transcript events cache direct ID lookup, timestamp ordered events, annotations, and overview marks. Playback driven transcript updates are throttled and timestamp navigation uses binary lookup.

## Verification

Package tests cover recording state, persistence, crash recovery, note timing, search behavior, and segment timeline metadata. The permanent macOS CI workflow also runs the complete native build and a production integration harness which verifies rename persistence across stale processing completion and segment manifest persistence.

`Verification/RecordingPanelPreview.swift` mirrors the production native title bar and recorder dimensions for deterministic visual checks.

# SoccerShots for macOS

SoccerShots is a native Apple-silicon Mac app for scoring soccer photos locally. The primary scorer is Gemma 3 running in-process through Apple MLX; an API key and network connection are not required after the model has downloaded. Gemini is reserved for an explicit, optional Deep Review of a photo selected by the user.

This repository is a Swift/SwiftUI rewrite of the validated Electron prototype at [`rickmakla-cmd/soccer-photos`](https://github.com/rickmakla-cmd/soccer-photos). It reuses the calibrated seven-dimension scoring prompt and deterministic composite formula rather than porting the Electron runtime.

## Current milestone

- Native SwiftUI folder selection and photo-count confirmation.
- Recursive discovery of the validated image/RAW formats.
- RAW+JPEG basename deduplication, preferring RAW.
- ImageIO/Core Image orientation correction and 2400-pixel scoring cap.
- In-process MLX VLM loading with visible download/inference progress.
- Gemma 3 4B 4-bit scoring, defensive JSON parsing, and one repair attempt.
- Deterministic composite calculation and the sharpness-only auto-reject rule.
- SwiftData score persistence with size/mtime cache validation and session folder tracking.
- Filtered/sorted gallery, native focus ring, arrow-key navigation, Space export selection, Enter detail, and X reject controls.
- Full score-detail view with Lightroom guidance, metadata, selection/reject actions, and previous/next navigation.
- Settings UI for the local model and Keychain-backed optional Gemini configuration.
- Explicit per-photo Gemini Deep Review with structured JSON stored beside the unchanged local score.
- Automatic restoration of the active folder, cached scores, gallery filter/sort, focused photo, and review decisions.
- Security-scoped folder bookmarks with a path fallback and a clean close-session action.
- EXIF-time burst detection and a rapid comparison workspace with keyboard-driven frame/burst navigation.
- One-command burst winner selection that keeps the strongest frame and marks the remaining frames rejected.
- Lightroom-compatible XMP generation primitives.

Complete Lightroom export (including JPEG XMP embedding), editable metadata, comparison zoom synchronization, and signed release automation remain follow-on milestones.

## Requirements

- Apple silicon Mac
- macOS 15 or newer
- Xcode 16 or newer (the Command Line Tools alone can run Swift package tests, but cannot build the `.app` project)

## Build

Generate the Xcode project after changing `project.yml`:

```bash
xcodegen generate
```

Then open `SoccerShots.xcodeproj`, choose the `SoccerShots` scheme, and run. The first score downloads `mlx-community/gemma-3-4b-it-4bit` into the app's Application Support model cache.

Run the domain tests with:

```bash
swift test
```

## Privacy boundary

Folder discovery, image preparation, scoring, caching, and XMP generation are local. The Gemini client is not called by the normal scoring pipeline; Deep Review will require explicit user action and a Keychain-stored key when its UI is added.

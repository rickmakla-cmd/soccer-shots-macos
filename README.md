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
- Guarded local A/B benchmarking against Gemma 4 E4B, with evenly distributed sampling, per-photo timing, persisted candidate scores, and no changes to authoritative keeper decisions.
- Deterministic composite calculation and the sharpness-only auto-reject rule.
- SwiftData score persistence with size/mtime cache validation and session folder tracking.
- Filtered/sorted gallery, filter-aware Select All/Deselect All, visible click-drag marquee selection, native focus ring, arrow-key navigation, Space export selection, Enter detail, and X reject controls.
- Full score-detail view with Lightroom guidance, exact generated develop values, metadata, selection/reject actions, and previous/next navigation.
- Settings UI for the local model and Keychain-backed optional Gemini configuration.
- Explicit per-photo Gemini Deep Review with structured JSON stored beside the unchanged local score.
- Automatic restoration of the active folder, cached scores, gallery filter/sort, focused photo, and review decisions.
- Security-scoped folder bookmarks with a path fallback and a clean close-session action.
- Responsive background RAW discovery during folder selection and session restoration, with cancellation support.
- EXIF-time burst detection and a rapid comparison workspace with keyboard-driven frame/burst navigation.
- One-command burst winner selection that keeps the strongest frame and marks the remaining frames rejected.
- Selected-photo export that copies originals and writes matching Lightroom-compatible XMP sidecars containing star ratings, guidance, and structured Camera Raw develop settings.
- Collision-safe export naming: existing originals or sidecars are never overwritten.

JPEG/TIFF metadata embedding, editable metadata, comparison zoom synchronization, and signed release automation remain follow-on milestones.

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

Choose **A/B Benchmark…** after a folder has stored primary scores. The benchmark uses those Gemma 3 results as the baseline, unloads Gemma 3, and runs the selected sample through `mlx-community/gemma-4-e4b-it-8bit` sequentially. The first benchmark downloads about 8.9 GB. Results are stored separately and never replace the primary score, selection, or rejection state. The 8-bit checkpoint is the default because the stock Gemma 4 4-bit MLX checkpoint still has a reported quantized vision-projection loader defect. MLX Swift is pinned to upstream commit `09deb8c`, which fixes the E-series VLM loader incorrectly requiring K/V weights on shared layers.

## Lightroom export

Select photos in the gallery, then choose **Export Selected + XMP…** in the sidebar. SoccerShots copies each original to the folder you choose and creates a sidecar with the same basename—for example, `IMG_0042.CR3` and `IMG_0042.xmp`. Import the exported originals into Lightroom Classic with their sidecars kept beside them. If a RAW was already imported before its sidecar existed, use **Metadata > Read Metadata from File** in Lightroom Classic.

Automatic develop-setting application is intended for proprietary camera RAW files. SoccerShots also exports an XMP record beside raster files, but it does not yet embed metadata into JPEG, TIFF, PSD, or DNG files.

Run the domain tests with:

```bash
swift test
```

## Privacy boundary

Folder discovery, image preparation, scoring, caching, and XMP generation are local. The Gemini client is not called by the normal scoring pipeline; Deep Review will require explicit user action and a Keychain-stored key when its UI is added.

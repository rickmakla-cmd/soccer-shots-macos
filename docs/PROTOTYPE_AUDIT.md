# Claude prototype audit

The Electron prototype is valuable because it contains calibrated product decisions, not because its runtime should be ported. The native rewrite keeps those decisions while replacing the parts that caused friction.

## Carry over unchanged

- The full `SCORING_PROMPT` v2 text.
- Seven dimensions and weights, including nullable ball score for celebration photos.
- Sharpness of 0–2 as the only auto-reject trigger.
- Deterministic composite calculation in application code.
- Lightroom suggestion and `develop_settings` shapes.
- RAW+JPEG basename deduplication, EXIF orientation correction, and 2400-pixel long-edge cap.
- File size plus modification-time cache identity.
- Session-folder grouping, burst grouping, collision-safe export naming, and XML escaping.
- Gemini as explicit Deep Review whose result sits beside—not over—the local score.
- Keyboard-first gallery behavior described in the native specification.

## Replace in the native app

| Prototype | Native replacement | Reason |
|---|---|---|
| Electron/React renderer | SwiftUI | Native keyboard, window, gallery, dark-mode, and file-picker behavior |
| Ollama localhost API | MLX Swift in-process VLM | Removes the separate install/service/port requirement |
| `sharp` and embedded-JPEG scan | ImageIO/Core Image first | Uses macOS RAW/HEIC support and preserves orientation natively |
| `sql.js` whole-database rewrites | SwiftData | Native incremental persistence and schema evolution |
| `.env` Gemini key | macOS Keychain | Correct secret storage for a distributed app |
| Electron JPEG mutation | ImageIO/CGImageDestination metadata path | Native XMP embedding; implementation still required |

## Risks found

- The prototype README says packaged builds do not require Node.js, but local scoring still requires separately installed/running Ollama and a pulled model. The native app removes that hidden runtime dependency.
- The Electron scorer requested Ollama JSON mode; MLX Swift does not currently expose an equivalent guarantee in the reused FlightReels path. The native parser therefore extracts defensively and performs one constrained repair attempt. Grammar-constrained decoding remains an investigation item.
- The specification proposes a 12B-class default, while FlightReels proves a 4B 4-bit checkpoint on this code path. Start with the proven 4B integration, then benchmark current larger MLX Gemma VLM checkpoints on the actual 16 GB machine before changing the default.
- ImageIO support varies by camera model and installed macOS RAW compatibility. Unsupported formats need a measured fallback, not an assumption that every listed extension decodes.
- JPEG XMP embedding is materially different from writing sidecars and must be tested with Lightroom imports before it is considered finished.

## Remaining product work

1. Settings UI for model storage/checkpoint and Keychain-backed Gemini configuration.
2. Full gallery filters/sorts, focus-ring keyboard navigation, detail view, and manual reject/export selection.
3. Session resume UI and stale-cache replacement tests.
4. CSV, collision-safe copy, RAW sidecars, JPEG XMP embedding, and Finder reveal.
5. Burst detection using EXIF plus filename fallback and side-by-side compare.
6. Explicit post-processed mode warning and in-place JPEG metadata write.
7. Signed/notarized release decision and model-license review.

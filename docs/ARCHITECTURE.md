# Native architecture

## Product boundary

SoccerShots has one primary scoring engine and one optional second opinion:

1. `PhotoDiscovery` enumerates supported images, collapses RAW+JPEG pairs, and records file identity.
2. `ImagePreparer` decodes and orients one image at a time with ImageIO/Core Image, then caps the long edge at 2400 pixels.
3. `LocalGemmaService` loads Gemma once per app session in the app process through MLX and scores images sequentially.
4. `ScoringParser` treats model output as untrusted, enforces the sharpness auto-reject, and recalculates the weighted composite deterministically.
5. `ScoreRecord` persists the result through SwiftData and validates cache entries with file size plus modification time.
6. `GeminiDeepReviewClient` is a separate path. It can only analyze a specific prepared image when a caller provides a Keychain-stored key; the normal scoring pipeline never invokes it.

## FlightReels patterns reused

- Swift Package Manager plus XcodeGen, with the generated Xcode project committed for easy opening.
- macOS 15 deployment target and an Apple-silicon-first MLX stack.
- `MLXVLM`, `MLXLMCommon`, `MLXHuggingFace`, and an app-selected Hugging Face cache directory.
- A single actor-owned `ModelContainer`, zero-temperature generation, visible model progress, and a JSON repair pass.
- Keychain secrets and explicit cloud boundaries.
- GitHub Actions that test the package and build an unsigned arm64 artifact.

## Important differences from FlightReels

SoccerShots feeds one still image per inference instead of dense video frame pairs. It owns a photography-specific deterministic rubric, requires RAW/HEIC decoding and Lightroom metadata export, and uses SwiftData session records rather than FlightReels project JSON.

## Memory and concurrency

The model actor serializes inference. The app does not decode an entire folder into memory. Each image is prepared immediately before inference, scored, persisted, and released. Image preparation can gain a small bounded look-ahead queue later, but inference should remain serial until profiling proves otherwise on the target 16 GB Mac mini.

## Model plan

The first proven checkpoint is `mlx-community/gemma-3-4b-it-4bit`, matching FlightReels. It is a practical first milestone, not a claim that 4B is the final quality target. Once end-to-end scoring is field-tested, the settings/catalog layer should support a larger quantized Gemma checkpoint and compare it against 4B using the same representative photo set and rubric.

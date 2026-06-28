# Build Status

**Date:** 2026-06-28 · Autonomous build against `MASTER_PLAN.md` (phases 0→5) and `ARCHITECTURE.md`.

## Summary

The plugin is **code-complete across all five phases**. Everything verifiable
**without physical camera hardware** has been verified green. The runtime/perf
gates that require a real device (and an iPhone + Xcode for iOS) are **not**
verifiable in the build environment and remain open.

## What is verified ✅

| Check | Result |
| --- | --- |
| `dart analyze` — all 4 packages + example | **No issues** |
| App-facing unit tests (controller ↔ mock platform) | **5/5 pass** |
| Example widget test | **pass** |
| Android debug APK build (compiles ALL native Kotlin) | **builds** |
| App launches on emulator; plugin registers; Pigeon round-trips | **no crash** |
| Capability detection + graceful single-cam fallback (emulator) | **works** (`noConcurrentCamera`) |
| **On-device instrumented test: real `VideoEncoder`→`Muxer` runtime path** | **passes** — encodes 30 synthetic GL frames → valid `.mp4`, `MediaExtractor` confirms a 1280×720 video track (`EncoderPipelineTest`, `connectedDebugAndroidTest` on emulator) |
| **On-device instrumented test: real `DualCompositor` runtime path** | **passes** — synthetic frames through actual `SurfaceTexture`s → real OES/SDF compositor → FBO/blit → encoder → valid 1280×720 `.mp4` (`CompositorPipelineTest`) |
| `dart pub publish --dry-run` — all 4 packages | **0 warnings** (benign monorepo override hints only) |

> The encoder/muxer runtime path — the most failure-prone code (surface-input
> timing, presentation timestamps, EOS, muxer track ordering) — is now
> **runtime-verified on-device** with synthetic frames. What remains unverified
> is specifically the **camera-concurrency + compositor-with-real-camera-frames**
> stage, which the emulator cannot provide.

## What is code-complete but NOT runtime-verified ⛔ (hardware-gated)

These require hardware the environment does not have:

- **Android record/photo on real frames** — the emulator **cannot run two
  cameras concurrently**, so the GLES compositor → MediaCodec/MediaMuxer path,
  the produced `.mp4`/photo, A/V sync, and the perf-HUD numbers cannot execute
  or be measured here. The code compiles; it has not run.
- **iOS entirely** — this is a Linux box. The Swift/Metal implementation
  (`AVCaptureMultiCamSession` + Metal compositor + `AVAssetWriter`) is written
  to spec and reviewed, but **cannot be compiled or run** without macOS + Xcode
  + a physical iPhone.

### To close the remaining gates

1. Plug a concurrent-camera Android phone (Pixel 6+/Galaxy S22+) into `adb` and
   run the example: record a clip, take a photo, watch the HUD hit the
   `ARCHITECTURE.md §10` targets (composite < 16 ms, zero dropped frames).
2. Open `example/ios` on a Mac with Xcode, run on a physical iPhone (A12+), and
   repeat.

## Known follow-ups

- Flutter warns the Android plugin applies the Kotlin Gradle Plugin; migrate to
  Flutter's built-in Kotlin before that becomes mandatory.
- iOS perf-HUD telemetry (`onFrameStats`) is currently Android-only; add the
  equivalent Metal-side timing for parity.
- Orientation handling is minimal (composite is sensor-landscape 1280×720);
  full device-orientation baking is a polish item.
- Photo is WYSIWYG composite resolution; full-res individual stills (iOS dual
  `AVCapturePhotoOutput` / Android sequential) remain an opt-in upgrade.

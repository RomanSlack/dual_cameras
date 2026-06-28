# dual_camera_recorder

A native **dual-camera recorder** for Flutter — records the **front and back cameras simultaneously**, composites them in real time (picture-in-picture / split) on the GPU, and writes a **single portrait `.mp4`** (plus a composited photo). The BeReal / Snapchat dual-camera capture, as a proper federated Flutter plugin.

> **Status:** **Android — working alpha**, verified end-to-end on a real device (Pixel 8): simultaneous front+back → live preview, recorded composite `.mp4` with in-sync audio, and composited stills. **iOS — scaffolded** (Swift/Metal written to spec) but **not yet compiled or run**.

- **pub.dev package name (planned):** `dual_camera_recorder`
- **Repo:** `github.com/RomanSlack/dual_camera_recorder_flutter`
- **License:** MIT (open-source from day one)

---

## The gap this fills

As of mid-2026, **no Flutter plugin records a composited dual-cam video.** The OS APIs can do it — iOS `AVCaptureMultiCamSession`, Android CameraX concurrent camera — but every Flutter option (`camera`, `camerawesome`, `multicamera`, `dual_camera`) stops at preview/photos or single-camera recording. This plugin owns the native compositor on both platforms and emits one clean `.mp4`. The hard, novel part is the **recorded composite** — not the live preview overlay (which is trivial).

## What works today (Android)

- **Simultaneous front + back** via CameraX concurrent camera (texture sources only — no `CompositionSettings`).
- **Unified GPU compositor** (GLES): one composite per frame fans out to the **live preview**, the **encoder**, and **photo** — so preview, video, and stills can never drift.
- **Portrait, vertical video** — each camera is rotated upright from its sensor orientation and **aspect-cover-cropped** (never stretched) into a 9:16 canvas.
- **Layouts:** picture-in-picture (rounded-rect **or** circle inset) and split; **live swap** of the full-frame camera; mirrored front feed.
- **H.264 (MediaCodec, surface input) + AAC (AudioRecord)** muxed by `MediaMuxer`, on a single monotonic clock for A/V sync.
- **Composited photo** (FBO read-back, JPEG) at the same WYSIWYG geometry.
- **Capability detection** + graceful single-camera fallback; thermal monitoring; a perf HUD (FPS / composite-ms / dropped frames).
- Verified on a **Pixel 8**: composited front+back `.mp4` (720×1280, h264 + aac) and photo, saved to the gallery from the example app.

## Architecture (federated plugin)

```
dual_camera_recorder/                     (app-facing Dart API)
dual_camera_recorder_platform_interface/  (Pigeon contract: host + flutter APIs)
dual_camera_recorder_android/             (Kotlin: CameraX concurrent → SurfaceTexture → GLES compositor → MediaCodec/MediaMuxer)
dual_camera_recorder_ios/                 (Swift: AVCaptureMultiCamSession → Metal compositor → AVAssetWriter)
```

**One unified manual GPU compositor** — GLES on Android, Metal on iOS — is the single core for preview, video, and photo. Cameras are texture sources; we own the compositor, encoder, muxer, and A/V sync. Capture → external (OES/CVMetal) texture → one GPU composite → fan out to encoder + preview (+ photo). Full engine design in **[`ARCHITECTURE.md`](ARCHITECTURE.md)**.

## Dart API

```dart
final cam = DualCameraController();
if (!await DualCameraController.isSupported()) { /* single-cam fallback */ }

await cam.initialize(
  layout: DualLayout.pictureInPicture(
    primary: CameraLens.back,
    insetCorner: InsetCorner.bottomRight,
    insetScale: 0.32,
    cornerRadius: 18,
    circleInset: false,   // true → round inset
  ),
  resolution: DualResolution.hd720, // capped by hardware
);

// Live preview (letterboxed to the composite's 9:16 — never stretched):
DualCameraPreview(cam);

await cam.startRecording();
cam.swapPrimary();                              // flip full-frame camera, live
final String clip  = await cam.stopRecording(); // single composited portrait mp4
final String photo = await cam.takePhoto();     // single composited still
await cam.dispose();
```

Add permissions in the **consuming app** (camera + microphone on Android; `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` on iOS) and request them at runtime before `initialize`.

## Key constraints (read before coding)

- **Concurrent dual-camera is hardware-limited** — only devices advertising support; **≤720p/1440p** per camera; two cameras max. Capability check + single-camera fallback is **mandatory**.
- **FOV / look ≠ the native single-camera app.** Concurrent mode caps resolution and bypasses the vendor's computational pipeline (HDR+, etc.); fitting a 4:3 sensor into 9:16 portrait also crops FOV. This is inherent to the public dual-camera API, not a bug.
- **iOS:** A12+ / iOS 13+. Multicam is power/thermal-heavy — cap clip duration, downscale under thermal pressure, stop cleanly on `thermalStateDidChange`.
- Audio is captured once (mic) and muxed into the output. Front-camera mirroring must be correct in the recorded file.

## Roadmap

- [x] **0.** Federated skeleton + simultaneous preview + capability detection (Android).
- [x] **1.** Android manual GL compositor → MediaCodec → MediaMuxer; AudioRecord + one-clock A/V sync.
- [x] **2.** Android photo (FBO re-render) + perf HUD; portrait orientation, sensor-rotation, aspect-fill, circle/PiP/split.
- [ ] **3.** iOS `AVCaptureMultiCamSession` → Metal compositor → `AVAssetWriter` (+ photo) — **scaffolded, not yet built/run** (needs macOS + Xcode + an A12+ iPhone).
- [ ] **4.** Resolution options (1440p where supported), richer layout controls, device-orientation handling beyond portrait.
- [ ] **5.** Polish, docs, pub.dev publish.

## Why it exists / who uses it

Built first for [belo](https://github.com/RomanSlack)'s short-form capture surfaces (pops / peeks / circles) — a BeReal-style "reaction + scene in one authentic clip" that drops straight into the existing media-upload pipeline. Open-sourced because the gap is real and the official `camera` issues (flutter#51928, #102427, #119858) have hundreds of 👍.

---

### For agents working in this repo

- **[`MASTER_PLAN.md`](MASTER_PLAN.md)** and **[`ARCHITECTURE.md`](ARCHITECTURE.md)** are the engineering source of truth — native approach per platform, the federated layout, threading model, A/V sync, and perf targets. **Read them first.** **[`BUILD_STATUS.md`](BUILD_STATUS.md)** tracks what is verified vs. hardware-gated.
- The example app (`packages/dual_camera_recorder/example`) is the live test harness; run it on a concurrent-camera device with `flutter run`.
- This is a **standalone repo**; the belo app consumes it via a path/git dependency. Do not assume belo's code is importable here.

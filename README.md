<p align="center">
  <img src="readme_assets/banner.png" alt="Dual Cameras — record the front and back cameras simultaneously in Flutter, composited into a single portrait video" width="820">
</p>

<h1 align="center">dual_cameras</h1>

<p align="center">
  <b>Record the front and back cameras at the same time in Flutter</b> — composited live on the GPU into a <b>single portrait <code>.mp4</code></b> and photo, with a real-time preview. Picture-in-picture, circle inset, or split. The BeReal / Snapchat–style dual-camera capture, as a proper open-source federated plugin for <b>Android &amp; iOS</b>.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Android%20%7C%20iOS-1d1d1f?style=flat-square" alt="Platform: Android and iOS">
  <img src="https://img.shields.io/badge/Flutter-%E2%89%A5%203.24-027DFD?style=flat-square&logo=flutter&logoColor=white" alt="Flutter 3.24+">
  <img src="https://img.shields.io/badge/license-MIT-3DDC84?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/badge/Android-working%20alpha-027DFD?style=flat-square&logo=android&logoColor=white" alt="Android: working alpha">
  <img src="https://img.shields.io/badge/iOS-running%20on%20device-000000?style=flat-square&logo=apple&logoColor=white" alt="iOS: running on device">
  <img src="https://img.shields.io/badge/PRs-welcome-027DFD?style=flat-square" alt="PRs welcome">
</p>

<p align="center">
  <a href="https://romanslack.com"><img src="https://img.shields.io/badge/Website-romanslack.com-027DFD?style=flat-square&logo=googlechrome&logoColor=white" alt="romanslack.com"></a>
  <a href="https://github.com/RomanSlack"><img src="https://img.shields.io/badge/GitHub-RomanSlack-181717?style=flat-square&logo=github&logoColor=white" alt="GitHub @RomanSlack"></a>
  <a href="https://www.linkedin.com/in/roman-slack-a91a6a266/"><img src="https://img.shields.io/badge/LinkedIn-Roman%20Slack-0A66C2?style=flat-square&logo=linkedin&logoColor=white" alt="LinkedIn — Roman Slack"></a>
</p>

<p align="center">
  Built and maintained by <a href="https://romanslack.com"><b>Roman Slack</b></a> ·
  <a href="https://github.com/RomanSlack/dual_cameras_flutter">RomanSlack/dual_cameras_flutter</a>
</p>

> **Status:** **Android — working alpha**, verified end-to-end on a real device (Pixel 8): simultaneous front+back → live preview, recorded composite `.mp4` with in-sync audio, and composited stills. **iOS — alpha, now running on a real iPhone** (iOS 26): the Metal compositor brings up a live composited front+back preview on `AVCaptureMultiCamSession`, with rotate-upright + aspect-cover and the rounded/circle PiP working. Recording and photo run through the same unified compositor (Android parity by construction); full on-device A/V-sync verification is in progress.

**Keywords:** Flutter dual camera · record front and back camera simultaneously · both cameras at once · picture-in-picture video · composite video to mp4 · CameraX concurrent camera · AVCaptureMultiCamSession · BeReal-style capture · multi-camera recording plugin.

- **pub.dev package name (planned):** `dual_cameras`
- **Repo:** [`github.com/RomanSlack/dual_cameras_flutter`](https://github.com/RomanSlack/dual_cameras_flutter)
- **Author:** [Roman Slack](https://romanslack.com) — [GitHub](https://github.com/RomanSlack) · [LinkedIn](https://www.linkedin.com/in/roman-slack-a91a6a266/)
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

## What works today (iOS)

- **Builds and runs on a real iPhone** (iOS 26, A12+) — `AVCaptureMultiCamSession` with manual connection wiring delivers both feeds into one **Metal** compositor.
- **Live composited dual preview** confirmed on device: primary full-frame + secondary inset (rounded-rect / circle SDF), front mirrored.
- **Orientation + aspect-cover in the shader** — iOS hands you the raw *landscape* `CVPixelBuffer` (no free rotation like Android's `SurfaceTexture`), so the Metal shader rotates each feed upright and cover-crops it into the portrait canvas itself (port of Android's `texXform`).
- **Multicam `hardwareCost` gating** — picks a binned ≤720p `activeFormat` per camera and steps frame rate down if the session would exceed the cost budget, so it actually starts.
- **Same unified compositor** feeds the Flutter preview texture, the `AVAssetWriter` (H.264 + AAC, video PTS off the primary sample buffer / audio passthrough → synced), and the photo — so preview, video, and stills can't drift.
- **Live debug-tuning** over the shared `dual_cameras/debug` channel (rotation / mirror / source-aspect) to dial in orientation on-device without native rebuilds.
- **In progress:** full on-device A/V-sync verification over a long clip, proactive thermal downscale, and iOS perf-HUD telemetry.

## Architecture (federated plugin)

```
dual_cameras/                     (app-facing Dart API)
dual_cameras_platform_interface/  (Pigeon contract: host + flutter APIs)
dual_cameras_android/             (Kotlin: CameraX concurrent → SurfaceTexture → GLES compositor → MediaCodec/MediaMuxer)
dual_cameras_ios/                 (Swift: AVCaptureMultiCamSession → Metal compositor → AVAssetWriter)
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
- **Orientation/aspect (Android):** the camera delivers a *landscape* buffer, but its `SurfaceTexture` transform matrix already rotates it 90° upright into the portrait canvas before the shader samples it — so the compositor's aspect-cover uses the **rotated** aspect (`h/w`), not `w/h`. A 4:3 source → `0.75` (verified un-stretched on **Pixel 8**, front *and* back). If a new device looks stretched, the example app's **Debug tuning** panel (live rotation-offset / mirror / source-aspect override over the `dual_cameras/debug` MethodChannel) dials it in without rebuilding native code.
- **Orientation/aspect (iOS):** unlike Android, `AVCaptureVideoDataOutput` delivers the buffer in the sensor's *native landscape* orientation with **no** free rotation — so the Metal shader does the full rotate-upright + aspect-cover itself (it sees the true `w/h`). The same `dual_cameras/debug` panel tunes the per-feed rotation and aspect on-device; the found values then get baked as defaults.

## Roadmap

- [x] **0.** Federated skeleton + simultaneous preview + capability detection (Android).
- [x] **1.** Android manual GL compositor → MediaCodec → MediaMuxer; AudioRecord + one-clock A/V sync.
- [x] **2.** Android photo (FBO re-render) + perf HUD; portrait orientation, sensor-rotation, aspect-fill, circle/PiP/split.
- [x] **3.** iOS `AVCaptureMultiCamSession` → Metal compositor → `AVAssetWriter` (+ photo) — **builds and runs on a real iPhone**; live composited preview, orientation/aspect, `hardwareCost` gating, debug tuning. Full A/V-sync verification + thermal downscale in progress.
- [ ] **4.** Resolution options (1440p where supported), richer layout controls, device-orientation handling beyond portrait.
- [ ] **5.** Polish, docs, pub.dev publish.

## Why it exists / who uses it

Built first for [belo](https://github.com/RomanSlack)'s short-form capture surfaces (pops / peeks / circles) — a BeReal-style "reaction + scene in one authentic clip" that drops straight into the existing media-upload pipeline. Open-sourced because the gap is real and the official `camera` issues (flutter#51928, #102427, #119858) have hundreds of 👍.

## Author

**dual_cameras** is built and maintained by **[Roman Slack](https://romanslack.com)** — software engineer and creator of [belo](https://github.com/RomanSlack).

- 🌐 Website — [romanslack.com](https://romanslack.com)
- 💻 GitHub — [@RomanSlack](https://github.com/RomanSlack)
- 💼 LinkedIn — [Roman Slack](https://www.linkedin.com/in/roman-slack-a91a6a266/)

If this plugin saved you from writing a native dual-camera compositor, a ⭐ on [the repo](https://github.com/RomanSlack/dual_cameras_flutter) is appreciated. Issues and PRs welcome.

## License

[MIT](LICENSE) © [Roman Slack](https://romanslack.com)

---

### For agents working in this repo

- **[`MASTER_PLAN.md`](MASTER_PLAN.md)** and **[`ARCHITECTURE.md`](ARCHITECTURE.md)** are the engineering source of truth — native approach per platform, the federated layout, threading model, A/V sync, and perf targets. **Read them first.** **[`BUILD_STATUS.md`](BUILD_STATUS.md)** tracks what is verified vs. hardware-gated.
- The example app (`packages/dual_cameras/example`) is the live test harness; run it on a concurrent-camera device with `flutter run`.
- This is a **standalone repo**; the belo app consumes it via a path/git dependency. Do not assume belo's code is importable here.

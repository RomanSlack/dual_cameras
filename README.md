# dual_camera_recorder

A native **dual-camera recorder** for Flutter — records the **front and back cameras simultaneously**, composites them in real time (picture-in-picture / split), and writes a **single `.mp4`**. The BeReal / Snapchat dual-camera capture, as a proper federated Flutter plugin for Android and iOS.

> **Status:** scaffolding / pre-alpha. Nothing is built yet — see [`SCOPE.md`](SCOPE.md) for the full design, milestones, and open questions.

- **pub.dev package name (planned):** `dual_camera_recorder`
- **Repo:** `github.com/RomanSlack/dual_camera_recorder_flutter`
- **License:** MIT (planned, open-source from day one)

---

## The gap this fills

As of mid-2026, **no Flutter plugin records a composited dual-cam video.** The OS APIs can do it — iOS `AVCaptureMultiCamSession`, Android CameraX 1.6 concurrent camera — but every Flutter option (`camera`, `camerawesome`, `multicamera`, `dual_camera`) stops at preview/photos or single-camera recording. This plugin owns the native compositor on both platforms and emits one clean `.mp4`.

The hard, novel part is the **recorded composite** — not the live preview overlay (which is trivial). See `SCOPE.md §1`.

## Architecture (federated plugin)

```
dual_camera_recorder/                     (app-facing Dart API)
dual_camera_recorder_platform_interface/  (abstract contract + method/event channels)
dual_camera_recorder_android/             (Kotlin: CameraX/Camera2 → SurfaceTexture → GLES compositor → MediaCodec/MediaMuxer)
dual_camera_recorder_ios/                 (Swift: AVCaptureMultiCamSession → Metal compositor → AVAssetWriter)
```

**One unified manual GPU compositor** — GLES on Android, Metal on iOS — is the single core for **preview, video, and photo** on both platforms. Cameras are texture sources; we own the compositor, encoder, muxer, and A/V sync (we do *not* use CameraX `CompositionSettings`). Chosen for performance + quality + parity over a smaller codebase. The two platforms mirror each other: capture → external texture → one GPU composite → fan out to encoder + preview (+ photo). iOS is the longer pole (more manual session/thermal handling), but the design is symmetric. Full engine design in **[`ARCHITECTURE.md`](ARCHITECTURE.md)**.

## Target Dart API (draft)

```dart
final cam = DualCameraController();
if (!await DualCameraController.isSupported()) { /* single-cam fallback */ }

await cam.initialize(
  layout: DualLayout.pictureInPicture(
    primary: CameraLens.back,
    insetCorner: Corner.bottomRight,
    insetScale: 0.28, cornerRadius: 18, margin: 12,
  ),
  resolution: DualResolution.hd720, // capped by hardware
);

await cam.startRecording();
cam.swapPrimary();                            // flip full-frame camera, live
final XFile clip = await cam.stopRecording(); // single composited mp4
await cam.dispose();
```

## Key constraints (read before coding)

- **iOS:** A12+ / iOS 13+. Multicam is power/thermal-heavy — cap clip duration, downscale under thermal pressure, stop cleanly on `thermalStateDidChange`.
- **Android:** only devices advertising concurrent-camera support; **≤720p/1440p**; two cameras max. Capability check + single-camera fallback is **mandatory**, not optional.
- Audio captured once (mic), muxed into the output. Front-camera mirroring must be correct in the recorded file.

## Roadmap (see `MASTER_PLAN.md §9`)

0. Spike: federated skeleton + simultaneous **preview** + capability detection on both platforms.
1. **Android** manual GL compositor → MediaCodec → MediaMuxer; AudioRecord + one-clock A/V sync.
2. **Android** photo (hi-res FBO re-render of the same shaders) + the perf-measurement HUD.
3. **iOS** `AVCaptureMultiCamSession` → Metal compositor → `AVAssetWriter` (+ photo); same perf targets.
4. Unify Dart API, layouts (PiP + split), live swap, ThermalGovernor, error events.
5. Polish, docs, pub.dev publish.

## Why it exists / who uses it

Built first for [belo](https://github.com/RomanSlack)'s short-form capture surfaces (pops / peeks / circles) — a BeReal-style "reaction + scene in one authentic clip" that drops straight into the existing media-upload pipeline. Open-sourced because the gap is real and the official `camera` issues (flutter#51928, #102427, #119858) have hundreds of 👍.

---

### For agents working in this repo

- **[`MASTER_PLAN.md`](MASTER_PLAN.md)** is the engineering source of truth — native approach per platform (video + photo), the federated layout, device matrix, risks, and the phased build order. **Read it first.**
- **[`SCOPE.md`](SCOPE.md)** is the product scope and open sign-off questions.
- This is a **standalone repo**; the belo app will consume it via a path/git dependency. Do not assume belo's code is importable here.
- Decided so far: open-source from day one, MIT, package name `dual_camera_recorder`, federated layout. Still open (see `SCOPE.md §9`): PiP-only vs PiP+split for v1, resolution parity, and build sequencing (Phase 0 spike vs straight to Android record path).

# Dual-Camera Recording Plugin — Scope

> **⚠️ Historical proposal.** This is the original scoping doc. Two things have since been decided and superseded below:
> 1. **Name** is now `dual_cameras` (repo `dual_cameras_flutter`), open-source from day one under the RomanSlack brand — not `belo_dual_camera`/`flutter_dual_camera` (the latter is already taken on pub.dev).
> 2. **Android approach** is now a **unified manual GLES compositor** (not CameraX `CompositionSettings`). The "Android is easy via CompositionSettings" framing in §3/§6 below is **superseded** — see **[`MASTER_PLAN.md`](MASTER_PLAN.md)** (what/phasing) and **[`ARCHITECTURE.md`](ARCHITECTURE.md)** (engine) for the current design.
>
> The product scope, capabilities, device matrix, and open sign-off questions below still stand.

**Status:** proposed / scoping (superseded on engineering — see banner)
**Date:** 2026-06-28
**Owner:** TBD
**Working name:** `belo_dual_camera` (internal) → `flutter_dual_camera` (community release) — *superseded; now `dual_cameras`*

A Flutter federated plugin that records **front + back cameras simultaneously**, composites them in real time (picture-in-picture / split), and writes a **single recorded video file** — the BeReal / Snapchat-dual-camera capture, done right. Built for belo's capture surfaces (pops / peeks / circles) and open-sourced because the gap below is real and unfilled.

---

## 1. Why build this

The native OS APIs are mature, but **no Flutter plugin records a composited dual-cam video** as of mid-2026:

| Layer | State |
| --- | --- |
| iOS `AVCaptureMultiCamSession` (AVFoundation) | Simultaneous capture **+ recording**. iOS 13+, **A12 chip or newer** (iPhone XS/XR+). |
| Android `concurrent camera` → CameraX 1.3+ | Dual streams; **CameraX 1.6.0-beta01 (Jan 2026) composites the two streams natively** via `SingleCameraConfig` + `CompositionSettings` (PiP / side-by-side). Dual only, **≤720p or 1440p**, hardware-gated. |
| Flutter official `camera` plugin | **Single camera only.** Open since 2020 (flutter#51928, #102427, #119858). |
| `camerawesome` (`SensorConfig.multiple()`) | Simultaneous **preview/photos** on both platforms, **beta**. **No multi-sensor video recording, no PiP compositing.** |
| `multicamera`, `dual_camera` | Immature; not production-grade for recorded composite video. |

So: the OS can do it, but a Flutter app that wants a **recorded** dual-cam clip has to drop to native on both platforms. That's the plugin. It's genuinely useful to the community (the official issues have hundreds of 👍) and it's a capability belo wants regardless.

**Non-goal of this doc:** the live *preview* overlay alone (trivial — two textures in a `Stack`, or `camerawesome`). This scope is specifically the **recorded composite**, which is the hard part.

---

## 2. What it does (capabilities)

- Start a session that opens **front + back simultaneously** on supported hardware.
- Live **preview** of both, exposed as Flutter textures, plus a server-/native-composited preview option.
- **Record** to a single `.mp4` with the two feeds composited:
  - layouts: **picture-in-picture** (primary full-frame + secondary rounded inset), **split** (top/bottom or left/right).
  - configurable inset corner, size (scale), margin, corner radius, and which camera is primary; **swap primary/secondary** live.
- **Capability detection** (`isSupported()`) + graceful **single-camera fallback**.
- Audio captured once (mic) and muxed into the output.
- Front-camera mirroring handled correctly in the recorded file.

### Explicitly out of scope (v1)
- More than two cameras; logical/ultrawide multi-lens combos beyond front+back.
- Live streaming / WebRTC of the composite (belo calling already owns RTC).
- In-app post-edit / filters / AR. Output is a clean composited clip the app can hand to existing pipelines.
- Web / desktop.

---

## 3. Architecture — federated Flutter plugin

```
flutter_dual_camera/                     (app-facing Dart API)
flutter_dual_camera_platform_interface/  (abstract contract + method/event channels)
flutter_dual_camera_android/             (Kotlin: CameraX dual-concurrent + CompositionSettings)
flutter_dual_camera_ios/                 (Swift: AVCaptureMultiCamSession + Metal compositor)
```

Standard federated layout so platforms version independently and the community can contribute one side without touching the other.

### iOS implementation
- `AVCaptureMultiCamSession` with two `AVCaptureDeviceInput`s (front + back) and two `AVCaptureVideoDataOutput`s.
- **Compositor:** per-frame composite on the GPU — **Metal** (preferred) or Core Image — drawing primary full-frame + secondary inset with the configured transform.
- **Recording:** `AVAssetWriter` fed the composited `CVPixelBuffer` stream + one audio input from the mic. (AVFoundation has no automatic PiP-to-file like CameraX, so we own the compositor — this is the bulk of the iOS work.)
- Preview: expose the composited buffer (and/or each raw feed) as a Flutter external texture via `FlutterTexture`.
- Guard everything behind `AVCaptureMultiCamSession.isMultiCamSupported`.

### Android implementation
- **CameraX 1.6+** dual concurrent camera. Lean on the **built-in `CompositionSettings`** (alpha/offset/scale) so CameraX composites for us — far less custom code than iOS.
- `VideoCapture` use case on the composited config for recording; preview use case for the live feed.
- Guard behind the concurrent-camera hardware capability query; respect the **720p/1440p** ceiling.
- Fallback path: if `CompositionSettings` proves too rigid for our exact PiP look, composite manually with an `OpenGL`/`GLSurface` pass (kept as a contingency, not the default).

---

## 4. Dart API (draft)

```dart
final cam = DualCameraController();

if (!await DualCameraController.isSupported()) {
  // fall back to single-camera capture
}

await cam.initialize(
  layout: DualLayout.pictureInPicture(
    primary: CameraLens.back,
    insetCorner: Corner.bottomRight,
    insetScale: 0.28,
    cornerRadius: 18,
    margin: 12,
  ),
  resolution: DualResolution.hd720, // capped by hardware
);

// Live preview (composited or per-feed textures)
DualCameraPreview(controller: cam);

await cam.startRecording();
cam.swapPrimary();          // flip which camera is full-frame, live
final XFile clip = await cam.stopRecording(); // single composited mp4
await cam.dispose();
```

Events surfaced via an `EventChannel`: `onReady`, `onError`, `onRecordingStarted/Stopped`, `onCapabilityChanged`.

---

## 5. Constraints & device matrix

- **iOS:** A12+ / iOS 13+ (belo iOS is iOS 17+, so fully covered). Multicam is power/thermal-heavy — cap duration, drop resolution under thermal pressure, stop cleanly on `thermalStateDidChange`.
- **Android:** only devices that advertise concurrent-camera support; **≤720p/1440p**; two cameras / two use-cases max. Wide fragmentation → the capability check + fallback is **mandatory**, not optional.
- Battery/heat: document expected limits; default to short clips (belo capture is short-form anyway).

---

## 6. Milestones

| Phase | Deliverable | Est. |
| --- | --- | --- |
| 0 | Spike: prove simultaneous **preview** both platforms (can reuse `camerawesome` to de-risk) + capability detection | 2–3 days |
| 1 | **Android** record path on CameraX `CompositionSettings` → single mp4 (the easy win) | 3–5 days |
| 2 | **iOS** `AVCaptureMultiCamSession` + Metal compositor + `AVAssetWriter` record | 1.5–2.5 wks |
| 3 | Unify Dart API, layouts (PiP + split), live swap, mirroring, audio mux | ~1 wk |
| 4 | Fallback, thermal/lifecycle handling, error surfacing, example app | ~1 wk |
| 5 | Polish, docs, pub.dev publish (community release) | 3–5 days |

**Rough total:** ~4–6 weeks of focused native work, iOS-dominant. Android is comparatively cheap thanks to CameraX 1.6 doing the compositing.

---

## 7. Risks

- **iOS compositor is the long pole** — getting smooth 30fps GPU compositing + AVAssetWriter timing right (buffer pacing, audio sync, orientation/mirroring) is the real engineering.
- **Android fragmentation** — concurrent-camera support and the resolution ceiling vary widely; the matrix is unknowable without device testing. Mitigate with capability gating + telemetry on real users.
- **CameraX `CompositionSettings` rigidity** — if its PiP layout can't match our exact look, we fall to a manual GL composite (contingency cost).
- **Thermals** — sustained multicam recording heats devices fast; enforce short clips + adaptive downscale.

---

## 8. belo integration & community angle

- **Internal use:** a BeReal-style dual capture for **pops / peeks / circles** — reaction + scene in one authentic clip. Output is a normal mp4 that drops straight into the existing media-upload pipeline.
- **Community:** publish as `flutter_dual_camera` (MIT/BSD-3 to match the ecosystem) — fills a years-old gap in the official `camera` plugin, gives belo engineering visibility, and invites OEM/community contributions to the device matrix. Federated layout means contributors can improve one platform in isolation.

---

## 9. Open questions (for sign-off)

1. v1 layouts — **PiP only**, or PiP **+ split** at launch?
2. Resolution target — accept Android's 720p ceiling for parity, or allow per-platform max (iOS higher)?
3. Build now, or **prototype the preview overlay first** (Phase 0) and decide on the recording investment after seeing it on real devices?
4. Open-source from day one, or ship internal-first and release once hardened?

## References
- AVCaptureMultiCamSession — https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession
- CameraX releases (1.6.0-beta01, Jan 2026) — https://developer.android.com/jetpack/androidx/releases/camera
- CameraX dual concurrent + composition (Android Developers Blog) — https://android-developers.googleblog.com/2024/10/camerax-update-makes-dual-concurrent-camera-easier.html
- Flutter camera multi-cam issues — flutter/flutter #51928, #102427, #119858
- camerawesome — https://pub.dev/packages/camerawesome

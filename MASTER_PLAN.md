# dual_cameras — Master Plan

**Status:** research complete, pre-build · **Date:** 2026-06-28 · **Primary platform:** Android · **Also:** iOS
**Objective:** A federated Flutter plugin that, on supported hardware, captures **front + back cameras simultaneously**, composites them on the GPU in real time, and produces **(a) a single recorded `.mp4`** and **(b) a single composited still photo** — plus a live composited preview. Open-source (MIT) under the RomanSlack brand; consumed by belo for pops/peeks/circles.

This document is the single source of truth for *what* to build and *in what order*. The **deep engine design** (real-time pipeline, performance discipline, threading/sync) lives in its companion **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — read that for the hot path. Read [`SCOPE.md`](SCOPE.md) for product scope. It synthesizes six research passes (Android CameraX, iOS AVFoundation, existing-plugin landscape, federated architecture, the Android manual GL→MediaCodec pipeline, and cross-platform real-time perf engineering).

---

## 0. TL;DR — the decisive facts

1. **The gap is real.** No Flutter package records a composited front+back video as of mid-2026. The OS APIs exist; every plugin stops *before* compositing + encoding. (`camerawesome` is closest: multicam preview + *unmerged* photos, **video explicitly "not ready"**.) See §2.
2. **The OS never composites stills for you, and on iOS never composites *anything* for you.** Compositing + encoding into one file is *our* job — this is exactly where everyone else stops.
3. **We own one unified GPU compositor (locked decision).** GLES on Android, Metal on iOS — a single rendering core for **preview, video, and photo** on both platforms. We **reject** CameraX `CompositionSettings`/auto-mux (it would mean two compositing implementations on Android, a rigid PiP, video-only compositing, and platform divergence). Performance + quality + one mental model over a smaller codebase. The deep engine design is in **[`ARCHITECTURE.md`](ARCHITECTURE.md)**.
4. **One compositor → all three outputs.** Video and photo are the *same* shaders; the still is just a higher-res re-render off the recording cadence. No separate photo pipeline, no `CompositionSettings`/`ImageCapture` split. (This supersedes the earlier "Android photo is a separate path" framing — the manual compositor makes them one path.)
5. **iOS is the long pole.** `AVCaptureMultiCamSession` hands you two raw `CVPixelBuffer` streams; we own a **Metal compositor** → `AVAssetWriter`. The three things that break you: **frame-sync/PTS**, **mirroring-in-the-file**, and the **`hardwareCost < 1.0`** wall (full-res-on-both is impossible).
6. **Concurrency is hardware-gated and rare.** ~23% of recent Android devices support true front+back concurrency, capped at **720p/camera**. iOS needs **A12+ / iOS 13+** (belo iOS is 17+, fully covered). **Capability detection + graceful fallback is mandatory, not optional.**
7. **One composite, two consumers.** The single composited GPU buffer feeds *both* the encoder *and* the Flutter preview texture. Never composite twice.

---

## 1. Architecture — federated plugin

Standard 4-package split (mirrors the official `camera` plugin: `camera` / `camera_platform_interface` / `camera_android_camerax` / `camera_avfoundation`). Monorepo, each impl versions independently.

```
dual_cameras_flutter/                  # repo root (this repo)
├─ packages/
│  ├─ dual_cameras/                     # APP-FACING — belo depends on THIS only
│  │  ├─ lib/dual_cameras.dart          #   DualCameraController + DualCameraPreview widget
│  │  ├─ example/                               #   canonical example app = manual test harness
│  │  └─ pubspec.yaml                           #   endorses android+ios via default_package
│  ├─ dual_cameras_platform_interface/  # PLATFORM INTERFACE — pure Dart, no plugin block
│  │  └─ lib/ … platform_interface.dart, events.dart, messages.g.dart (Pigeon shared types)
│  ├─ dual_cameras_android/             # ANDROID — Kotlin + CameraX
│  └─ dual_cameras_ios/                 # iOS — Swift + AVFoundation + Metal
```

- **pub.dev package name:** `dual_cameras` (no `_flutter` suffix on the published package; the repo keeps it).
- **Endorsement:** app-facing pubspec lists the two impls under `dependencies` *and* `flutter: plugin: platforms: { android: {default_package: …_android}, ios: {default_package: …_ios} }`. Consumers depend only on the app-facing package; impls come transitively.
- **Interface package** depends on `plugin_platform_interface` and has **no** `flutter: plugin:` block (it's a plain Dart package).
- **SDK floor:** `flutter: ">=3.24.0"` (the minimum that has the `SurfaceProducer` texture API), `sdk: ^3.5.0`. Pin to the lowest version that has the APIs we actually call.

### Channels: use **Pigeon** (not hand-written MethodChannels)
The official `camera` plugin migrated to Pigeon; for a stateful controller with many commands + event streams it's the right call. Keep all Pigeon definitions + generated DTOs in the **platform_interface** package so both impls share identical types.

| Concern | Pigeon construct |
| --- | --- |
| Commands: `initialize / startRecording / stopRecording / takePhoto / swapPrimary / setLayout / dispose` | `@HostApi` with `@async` |
| Live state stream: `onReady / onError / onRecordingStarted / onRecordingStopped / onCapabilityChanged / onThermal` | `@EventChannelApi` (generates the EventChannel + StreamHandler boilerplate) |
| Shared DTOs: `RecordingConfig`, `LayoutConfig`, `CameraCapabilities`, error codes | Pigeon `class` |

`initialize()` returns the **texture id**; Dart renders it with `Texture(textureId: id)`.

> **Trap (killed the `dual_camera` package):** keep Dart↔native channel **and** method names in lockstep. A `takePhoto` vs `takePicture` mismatch is a silent dead-on-arrival bug. Pigeon eliminates this class of error — another reason to use it.

---

## 2. Landscape — why we're building this

| Plugin | Platforms | Simul. preview | Photos (both) | **Composited video** | Maturity |
| --- | --- | --- | --- | --- | --- |
| `camera` (official) | iOS/Android/Web | ❌ (1 controller) | ❌ | ❌ | canonical |
| `camerawesome` | iOS/Android | ✅ PiP (beta) | ✅ but **unmerged** (1 file/sensor) | ❌ "not ready yet" | mature (1.1k★) |
| `multicamera` | iOS/Android | ✅ separate | ✅ per-camera | ❌ (no video at all) | young (4★) |
| `dual_camera` | iOS/Android | ❌ | single-cam | ❌ | abandoned scaffold |
| `flutter_dual_camera` | Android | ❌ | ❌ (TODO stub) | ❌ | non-functional stub |

**Official-camera stance:** flutter/flutter **#51928** ("multiple cameras at once") is **OPEN, P3, 84 👍** — strong demand, low maintainer priority; #102427 and #119858 closed as duplicates. The maintainers' posted workaround is literally "use a third-party plugin or write native." That's us.

**Borrow:** capability-gate-first (`isMultiCamSupported`/`getAvailableConcurrentCameraInfos`); separate concurrent streams → composite in a render pass (Apple `AVMultiCamPiP`, `Liampronan/DualCameraKit`); a single **layout resolver** that drives *both* on-screen preview and recorded composite so they match exactly.

**Avoid:** assuming hardware support; designing for 1080p/4K dual (CameraX caps at 720p); the **post-hoc ffmpeg-merge** instinct for video (fights frame-sync/drift, doubles CPU/storage — composite live instead); shipping unmerged stills like camerawesome.

---

## 3. The one principle that unifies everything

```
  front stream ─┐                              ┌─► recorder  (AVAssetWriter / VideoCapture)
                ├─► GPU composite (1 buffer) ──┤
  back  stream ─┘     (PiP / split layout)     └─► Flutter preview texture
```

Two independent camera streams → **one GPU composite per frame** → fan out to the encoder **and** the preview texture. The layout resolver (primary lens, inset corner/scale/radius/margin, mirror flags, rotation) is computed once and applied identically to preview, recording, and the still composite. `swapPrimary()` just flips which feed is full-frame in that resolver.

The **photo** path reuses the *same* compositor on both platforms — a higher-res re-render of the same shaders off the recording cadence. No separate photo pipeline.

---

## 4. Android implementation (PRIMARY)

**Stack:** cameras as **texture sources only** → our **GLES compositor** → **MediaCodec** (surface-input) → **MediaMuxer**, with **AudioRecord**+AAC and our own A/V sync. `minSdkVersion 24`. **Full pipeline, threading, and sync details are in [`ARCHITECTURE.md`](ARCHITECTURE.md §2–§5); this is the summary.** We use CameraX only to negotiate the concurrent session and deliver frames into *our* `SurfaceTexture`s — **`CompositionSettings` and CameraX muxing are not used.**

### 4.1 Capability detection (gate everything)
```kotlin
val provider = ProcessCameraProvider.getInstance(context).get()
val combos = provider.availableConcurrentCameraInfos   // List<List<CameraInfo>>; empty ⇒ unsupported
```
Secondary probe (some devices — Z Flip, certain Xiaomi — do concurrent via Camera2 but report empty here): Camera2 `CameraManager.getConcurrentCameraIds()` (API 30+) / `isConcurrentSessionConfigurationSupported()`. Below API 30: `PackageManager.hasSystemFeature(FEATURE_CAMERA_CONCURRENT)`. Always handle `CameraDevice.StateCallback` → **`ERROR_MAX_CAMERAS_IN_USE`** and degrade. **~23% device support; assume false until proven true.**

### 4.2 The pipeline (video + preview share one composite)
Bind two concurrent `Preview` use-cases into **our** two `SurfaceTexture`s (`GL_TEXTURE_EXTERNAL_OES`) via `bindToLifecycle(listOf(primary, secondary))` — Camera2 fallback for control. On a **single GL thread / one shared `EGLContext`**: per back-camera `onFrameAvailable` (the record clock), `updateTexImage()` + **re-query** `getTransformMatrix()` for both, composite once into an FBO (back full-frame + front PiP with SDF rounded corners + mirror), then blit that FBO to **both** consumer surfaces via `eglMakeCurrent`:
- **encoder** `MediaCodec.createInputSurface()` window → `eglPresentationTimeANDROID(display, encSurface, backTs − startNs)` (**ns!**) → `swapBuffers()`;
- **preview** `SurfaceProducer` window → `swapBuffers()`.

`VideoCapture`/`Recorder` is **not used** — we drain the encoder ourselves (async `MediaCodec.setCallback`; surface-input means **no `onInputBufferAvailable`** — `signalEndOfInputStream()` to finish) and write to `MediaMuxer`. Audio: `AudioRecord` → AAC `MediaCodec`, PTS from `getTimestamp(TIMEBASE_MONOTONIC) − startNs`. **Muxer rules** (corrupt-file traps): `addTrack` only on `INFO_OUTPUT_FORMAT_CHANGED`, `start()` only after both tracks, serialize all calls under one lock, skip `BUFFER_FLAG_CODEC_CONFIG`, `stop()` only after both EOS. Default **H.264 CBR ~4 Mbps, GOP 1–2s, no B-frames** (thermal headroom). See [`ARCHITECTURE.md §3–§6, §12`].

### 4.3 Photo — same compositor, hi-res FBO
On shutter, re-run the *same* composite shaders into a **separate larger FBO** (off the recording cadence) and read it back (PBO / `ImageReader`-backed async to avoid the `glReadPixels` stall) → JPEG/HEIC. Front is mirrored in the shader, so the still matches preview. No separate bind, no mode-switch — one pipeline for video, preview, and photo.

### 4.4 Preview texture bridge — `SurfaceProducer`
```kotlin
val producer = binding.textureRegistry.createSurfaceProducer()
val textureId = producer.id()                       // → Dart Texture(textureId:)
producer.setCallback(object : SurfaceProducer.Callback {
  override fun onSurfaceAvailable() { /* (re)bind Preview to producer.getSurface() */ }
  override fun onSurfaceDestroyed() { /* unbind */ }
})
```
**Rules:** never cache the `Surface` — call `getSurface()` each draw; `onSurfaceCreated` is deprecated (3.27) → use `onSurfaceAvailable/Destroyed`; Android may destroy the surface on background → recreate on resume; if `handlesCropAndRotation()` is false, rotate via `SENSOR_ORIENTATION`.

### 4.5 Source fallback (only if needed)
The compositor/encoder/muxer are fixed (manual GL); only the **frame source** has a fallback. If CameraX won't deliver concurrent frames into our `SurfaceTexture`s on a given device, drop to **Camera2** directly (open both `CameraDevice`s, one `CameraCaptureSession` each with our `SurfaceTexture` as a `PRIV` output) — same GL pipeline downstream. Don't confuse logical-multi-camera (multiple back lenses) with front+back concurrency. If concurrency is unavailable entirely (~77% of devices), degrade to single-camera or sequential capture and surface it via `onCapabilityChanged`.

---

## 5. iOS implementation (the long pole)

**Stack:** `AVCaptureMultiCamSession` + **Metal** compositor + `AVAssetWriter`. iOS 13+ / A12+ (belo is iOS 17+, covered).

### 5.1 Session — manual connection wiring
Multicam forbids auto-connect. For each camera: `addInputWithNoConnections` + `addOutputWithNoConnections` + explicit `AVCaptureConnection(inputPorts:output:)` + `addConnection`. Two `AVCaptureVideoDataOutput`s + one `AVCaptureAudioDataOutput`. Preset must be `.inputPriority`; set each device's `activeFormat` manually. Discover legal pairs via `supportedMultiCamDeviceSets` (don't hardcode). Gate on `AVCaptureMultiCamSession.isMultiCamSupported`.

**The `hardwareCost < 1.0` wall** (checked after `commitConfiguration`): at ≥1.0 the session refuses to run. Levers, in order: lower-res `activeFormat` → prefer **binned** formats (`format.isVideoBinned`) → cap fps via `videoMinFrameDurationOverride` → disable a feed with `connection.isEnabled=false`. Also watch `systemPressureCost` (1–2 ≈ 15 min, 2–3 ≈ 10 min before forced interruption). **Full-res on both cameras is not an option** — downscale formats until `hardwareCost < 1.0` with margin.

### 5.2 Metal compositor (own it)
Two outputs fire on separate callbacks with different timestamps. **Sync strategy:** the `AVMultiCamPiP` **latch** — keep the latest *secondary (front)* buffer in an ivar; on each *primary (back)* frame, composite primary + last-known front, driving **PTS off the primary**. (Alternatively `AVCaptureDataOutputSynchronizer` if you want audio time-matched in the same callback.) Composite with **Metal** (zero-copy `CVPixelBuffer`↔`MTLTexture` via `CVMetalTextureCache`, output into an **IOSurface-backed BGRA `CVPixelBufferPool`**): draw primary full-frame quad, then the inset PiP quad with rounded-corner SDF mask, **front mirroring (flip UVs)**, and rotation baked in the vertex stage. (Core Image = acceptable fallback, higher latency; vImage = reject, too slow/hot.)

### 5.3 Recording → single mp4
`AVAssetWriter(.mp4)` + `AVAssetWriterInput`(**H.264 default**, HEVC opt-in — see [`ARCHITECTURE.md §6`]) via `AVAssetWriterInputPixelBufferAdaptor` + one audio input. On first composite: `startWriting()` + `startSession(atSourceTime: firstPTS)`. Append composite only when `isReadyForMoreMediaData` (else **drop** — that's back-pressure; never block the capture queue). **PTS = primary sample buffer's PTS**; pass audio straight through with capture-clock PTS → **A/V sync for free**. Clean finish: `markAsFinished` (both) → `finishWriting{}` → surface file only when `status == .completed` (a system-killed session mid-write risks a corrupt mp4 — cap duration and stop cleanly).

### 5.4 Photo
- **Path B (default):** grab the latest **composited** buffer → JPEG/HEIC. Exact WYSIWYG framing, **zero** extra hardware cost, trivial. Resolution = composite size.
- **Path A (upgrade):** dual `AVCapturePhotoOutput` (multicam supports multiple photo outputs) for full-res individual stills — raises `hardwareCost`, may force lower video res, flash effectively unavailable. Add only if full-res individual stills are a product requirement.

Ship Path B; offer Path A behind a flag later.

### 5.5 Mirroring, orientation, thermal
**Fix mirroring in the shader, not the preview connection** (preview-only fixes are the classic "correct in preview, wrong in file" bug). **Bake orientation+mirror in the Metal shader** (strategy 1) rather than `AVAssetWriterInput.transform` — one affine transform can't express "mirror only the inset." Consider locking UI orientation for v1 to de-risk. **Thermal:** observe `thermalState` + `systemPressureCost` + `AVCaptureSessionWasInterrupted`; adaptively downscale (fps first, then resolution, then disable PiP), cap duration, finalize file on interruption.

### 5.6 Preview texture bridge — `FlutterTexture`
Implement `FlutterTexture.copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?` returning the latest composite (retained); `registry.register(...)` once → return id to Dart; call `registry.textureFrameAvailable(id)` per composite. **Buffers must be `kCVPixelFormatType_32BGRA` + IOSurface-backed** (Flutter iOS embedder requirement) — which the Metal output pool already produces, so the **same buffer** feeds both the writer and the texture. Never composite twice.

---

## 6. Dart API (target)

```dart
final cam = DualCameraController();
if (!await DualCameraController.isSupported()) { /* single-cam fallback path */ }

await cam.initialize(
  layout: DualLayout.pictureInPicture(
    primary: CameraLens.back, insetCorner: Corner.bottomRight,
    insetScale: 0.28, cornerRadius: 18, margin: 12,
  ),
  resolution: DualResolution.hd720,   // capped by hardware
);

DualCameraPreview(cam);                       // Texture(textureId:) under the hood
await cam.startRecording();
cam.swapPrimary();                            // flip full-frame feed, live
final XFile clip  = await cam.stopRecording(); // single composited mp4
final XFile photo = await cam.takePhoto();     // single composited still
await cam.dispose();
```
Events via the Pigeon `@EventChannelApi`: `onReady`, `onError`, `onRecordingStarted/Stopped`, `onCapabilityChanged`, `onThermal`.

---

## 7. Constraints & device matrix

| | Android | iOS |
| --- | --- | --- |
| Concurrency gate | `getAvailableConcurrentCameraInfos()` non-empty (~23% devices) | `isMultiCamSupported` (A12+/iOS13+; belo iOS17+ ✅) |
| Cameras | 2 max | 2 (physical, one input each) |
| Resolution ceiling | **≤720p/camera** (some 1440p) | format-limited by `hardwareCost < 1.0` |
| Compositor (preview+video+photo) | our GLES (manual, one core) | our Metal (manual, one core) |
| Duration limiter | thermal throttling | systemPressureCost (~10–15 min) |
| Reference devices | Pixel 6+, Galaxy S22+ | iPhone XS+ |

Universal: capability-gate first, single-camera/sequential fallback, short clips by default, mirror the front feed, document expected thermal limits.

---

## 8. Risks

1. **iOS compositor is the long pole** — smooth 30fps GPU composite + AVAssetWriter timing (buffer pacing, audio sync, mirroring/orientation). Mitigate: start from `AVMultiCamPiP`/`DualCameraKit`, lock orientation in v1, latch-on-primary PTS.
2. **Android fragmentation** — concurrent support + resolution ceiling vary wildly and are unknowable without device testing. Mitigate: capability gating + real-device matrix + telemetry on belo's real users.
3. **Manual-compositor surface area** — owning GL/EGL + MediaCodec + MediaMuxer + A/V sync (Android) is more code + more bug surface than leaning on CameraX. Accepted deliberately for quality/parity. Mitigate by reusing Grafika's proven building blocks (`EglCore`/`WindowSurface`/`FullFrameRect`) and the single-monotonic-clock sync discipline ([`ARCHITECTURE.md §5`]).
4. **Thermals** — sustained dual-sensor recording heats fast. Enforce short clips + adaptive downscale on both platforms.
5. **Low addressable hardware** — only a minority of devices can do this. The fallback UX (single-cam / sequential) must be genuinely good, not an afterthought.

---

## 9. Build plan (phased, Android-led)

| Phase | Deliverable | Verify | Est. |
| --- | --- | --- | --- |
| **0 · Spike** | Federated skeleton (4 packages, Pigeon wired, example app). Capability detection + **simultaneous preview** on both platforms (two textures in a Stack). | On a real Pixel 6+/S22+ and an iPhone: both feeds render live; `isSupported()` correct; unsupported device degrades cleanly. | 2–3 d |
| **1 · Android video** | Manual GL compositor (FBO) → MediaCodec surface-input → MediaMuxer; AudioRecord+AAC; one-monotonic-clock A/V sync. SurfaceProducer preview from the same FBO. | Recorded mp4 on-device is PiP front+back with **synced** audio (lips match over a 3-min clip); start/stop clean, no corrupt files; ≤720p; preview == recording pixels. | 5–8 d |
| **2 · Android photo** | Same compositor → **hi-res FBO** re-render → async readback → JPEG/HEIC. Front mirrored. | Still matches preview framing; front not backwards; no recording hitch during capture; photo res > preview res. | 2–3 d |
| **2.5 · Perf harness** | Debug HUD (FPS / composite-ms / drop / thermal) in example app; meet the [`ARCHITECTURE.md §10`] targets on Android. | Sustained 30fps@720p, composite <16ms, zero dropped frames, no encoder-not-ready on a mid-range device. | 2–3 d |
| **3 · iOS** | `AVCaptureMultiCamSession` + Metal compositor + `AVAssetWriter` (video) + photo; same perf targets. | mp4 + still on a real iPhone; A/V synced; mirroring correct **in the file**; `hardwareCost`/`systemPressureCost` ≤ 1.0; thermal stop clean. | 1.5–2.5 wk |
| **4 · Unify** | Final Dart API, layouts (PiP + optional split), live `swapPrimary`, orientation, ThermalGovernor, error surfacing via events. | Same Dart code drives both platforms; example app exercises every command; interface mocks pass in CI. | ~1 wk |
| **5 · Ship** | Docs, CHANGELOGs, LICENSE, example screenshots, verified publisher, `pub publish` (interface → android → ios → app-facing). | `dart pub publish --dry-run` clean on all four; pana platform support = android+ios; belo consumes via path dep. | 3–5 d |

**Total ≈ 5–7 weeks**, iOS-dominant (the unified manual compositor adds Android pipeline work vs leaning on CameraX, bought back in quality + parity). Android phases 1–2 produce a usable artifact for belo early.

**Sequencing recommendation:** do **Phase 0 first** (cheapest way to hit real-device reality), then go straight to **Phase 1 Android video** for the early win, before committing to the iOS Metal push.

---

## 10. Decisions

**Resolved (locked):**
- ✅ **Open-source from day one** (MIT), standalone repo under RomanSlack, consumed by belo via path/git dep.
- ✅ **Unified manual GPU compositor** (GLES/Metal) for preview+video+photo on both platforms — *not* CameraX `CompositionSettings`. Performance + quality + parity over smaller codebase. (Roman, June 28.) See [`ARCHITECTURE.md`].

**Still open (need sign-off — see `SCOPE.md §9`):**
1. **v1 layouts** — PiP only, or PiP + split? (PiP-only is the simpler shader path; recommend PiP-only for v1, add split in Phase 4 — the SDF compositor makes split cheap to add later.)
2. **Resolution** — accept 720p parity across platforms, or allow iOS to exceed Android's 720p ceiling where `hardwareCost` permits?
3. **Photo fidelity** — is the hi-res-FBO composite still (one composited image) sufficient for v1, or do we also want full-res *individual* stills (iOS dual `AVCapturePhotoOutput` / Android sequential full-res) as a separate output?
4. **Sequencing** — confirm Phase 0 spike → Android video, as recommended above.

---

## 11. Consumer integration (belo)

belo (`/home/roman/balo/frontend/messaging_app/`) depends on the **app-facing package only**:
```yaml
# dev (both repos on disk)
dual_cameras:
  path: ../../dual_cameras_flutter/packages/dual_cameras
# or git (monorepo subdir)
dual_cameras:
  git: { url: https://github.com/RomanSlack/dual_cameras_flutter.git, ref: main, path: packages/dual_cameras }
```
Permissions the **consumer** must add (the plugin can't inject them): iOS `NSCameraUsageDescription` + `NSMicrophoneUsageDescription`; Android `CAMERA` + `RECORD_AUDIO`, `minSdkVersion 24`. Runtime prompts remain belo's responsibility (`permission_handler`). Output is a normal `.mp4`/photo that drops straight into belo's existing media-upload pipeline.

## 12. Publishing checklist
Verified publisher (own-domain) · LICENSE (MIT) + README + CHANGELOG per package · pubspec `description`/`repository`/`issue_tracker`/`topics: [camera, video, recording]`/`screenshots` · publish order **interface → android → ios → app-facing** (hosted deps only, no path/git) · `dart pub publish --dry-run` clean · `.pubignore` excludes `pigeons/`/build artifacts · declare `platforms:` explicitly so pana scores android+ios (not "0 platforms") · keep `dart:io/html` out of the interface package's import graph.

---

## Sources (read directly during research)
**Android:** [CameraX dual-concurrent blog](https://android-developers.googleblog.com/2024/10/camerax-update-makes-dual-concurrent-camera-easier.html) · [CameraX 1.5 blog](https://developer.android.com/blog/posts/introducing-camera-x-powerful-video-recording-and-pro-level-image-capture) · [CameraX release notes](https://developer.android.com/jetpack/androidx/releases/camera) · [Concurrent streaming (AOSP)](https://source.android.com/docs/core/camera/concurrent-streaming) · [ConcurrentCamera ref](https://developer.android.com/reference/androidx/camera/core/ConcurrentCamera) · [STRV: front+back ~23%](https://www.strv.com/blog/can-we-use-the-front-back-cameras-at-the-same-time-on-android-engineering) · [SurfaceProducer breaking change](https://docs.flutter.dev/release/breaking-changes/android-surface-plugins)
**iOS:** [AVMultiCamPiP sample](https://developer.apple.com/documentation/avfoundation/capture_setup/avmulticampip_capturing_from_multiple_cameras) · [AVCaptureMultiCamSession](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession) · [WWDC19 s249 transcript](https://asciiwwdc.com/2019/sessions/249) · [AVCaptureDataOutputSynchronizer](https://developer.apple.com/documentation/avfoundation/avcapturedataoutputsynchronizer) · [FlutterTexture BGRA/IOSurface (#147242)](https://github.com/flutter/flutter/issues/147242) · [DualCameraKit](https://github.com/Liampronan/DualCameraKit)
**Landscape:** [camerawesome multicam docs](https://docs.page/Apparence-io/camera_awesome/getting_started/multicam) · [flutter/flutter #51928 (open, P3, 84👍)](https://github.com/flutter/flutter/issues/51928) · pub.dev: camerawesome, multicamera, dual_camera, flutter_dual_camera
**Architecture:** [Developing packages & plugins](https://docs.flutter.dev/packages-and-plugins/developing-packages) · [Platform channels](https://docs.flutter.dev/platform-integration/platform-channels) · [Pigeon](https://pub.dev/packages/pigeon) · [camera plugin pubspecs (federated reference)](https://github.com/flutter/packages/tree/main/packages/camera) · [Publishing](https://dart.dev/tools/pub/publishing) · [Scoring](https://pub.dev/help/scoring)

# dual_camera_recorder — Engine Architecture & Performance

**Status:** design locked, pre-build · **Date:** 2026-06-28
**Companion to:** [`MASTER_PLAN.md`](MASTER_PLAN.md) (what to build / phasing) and [`SCOPE.md`](SCOPE.md) (product). This doc is the **deep engine design** — the real-time pipeline, the performance discipline, and the threading/sync model that make it lag-free. It is the binding reference when the high-level plan and the hot path disagree: **the hot path wins.**

> **Design decision (locked):** a **unified manual GPU compositor** — GLES on Android, Metal on iOS — is the single rendering core for **preview, video, and photo** on both platforms. We do **not** use CameraX `CompositionSettings` to composite or mux. We own the compositor, the encoder (`MediaCodec` / `AVAssetWriter`), the muxer (`MediaMuxer` / built-in), and audio/video sync. Chosen deliberately for **performance + quality + one mental model over a smaller codebase** (Roman's explicit call). The two platforms become mirror images of each other: capture → external texture → one GPU composite → fan out.

---

## 1. The invariant (the whole architecture in five lines)

```
  cam A (back)  ─┐   external      ┌──────────────► ENCODER  (MediaCodec surface-in / AVAssetWriter adaptor)
                 ├─ texture ─► ONE GPU COMPOSITE ──┼──────────────► PREVIEW  (SurfaceProducer / FlutterTexture)
  cam B (front) ─┘   (zero-copy)   (FBO / IOSurface)└──(on shutter)► PHOTO   (hi-res re-render of same shaders)
            mic ─► audio encode ──────────────────────────────────► muxed with video on ONE monotonic clock
```

**Composite exactly once per frame; never touch the CPU with pixels after capture; never block the capture thread.** Everything below is the disciplined execution of those three sentences.

---

## 2. Per-platform data flow

### Android (GLES + MediaCodec + MediaMuxer)
```
back  cam ─ SurfaceTexture A (GL_TEXTURE_EXTERNAL_OES) ─┐
front cam ─ SurfaceTexture B (GL_TEXTURE_EXTERNAL_OES) ─┤   [ GL THREAD · 1 shared EGLContext ]
                                                        ├─► updateTexImage×2, getTransformMatrix×2 (re-query!)
                                                        └─► composite → offscreen FBO (one scene render)
                                                                 │
   eglMakeCurrent(encoderWinSurface) → draw FBO quad → eglPresentationTimeANDROID(ns) → swapBuffers ─► MediaCodec(H.264) ─┐
   eglMakeCurrent(flutterWinSurface) → draw FBO quad → swapBuffers ─► preview                                            │
                                                                                                                         ├─► MediaMuxer(mp4)
   mic ─► AudioRecord ─► AAC MediaCodec ─────── PTS = getTimestamp(MONOTONIC) − startNs ─────────────────────────────────┘
```
Cameras are **texture sources only** (CameraX concurrent `Preview`×2 into *our* `SurfaceTexture`s, or Camera2 for control). We ignore `CompositionSettings` entirely.

### iOS (Metal + AVAssetWriter)
```
back  cam ─ AVCaptureVideoDataOutput ─┐
front cam ─ AVCaptureVideoDataOutput ─┤  latch front, drive on back frame (PTS source)
                                      ├─► Metal pass: CVMetalTextureCache (R8 luma + RG8 chroma, zero-copy)
                                      └─► composite → IOSurface-backed BGRA CVPixelBuffer (from adaptor.pixelBufferPool)
                                               │
                                               ├─► AVAssetWriterInputPixelBufferAdaptor.append(_, withPTS: backPTS)
                                               └─► FlutterTexture.copyPixelBuffer (same IOSurface)
   mic ─► AVCaptureAudioDataOutput ─── pass-through, capture-clock PTS ─► AVAssetWriter audio input (A/V synced for free)
```
`AVCaptureMultiCamSession` with manual connection wiring (`addInputWithNoConnections` + explicit `AVCaptureConnection`).

---

## 3. Performance principles (the discipline)

Each is a hard rule. Violating one is how you get jank. (iOS / Android mechanism in parentheses.)

1. **The frame never touches the CPU after capture.** No `glReadPixels`/`memcpy`/CPU-map of composited pixels on the hot path — readback forces a pipeline stall (~3 frames + DMA). *(iOS: `CVMetalTextureCache` in, IOSurface `CVPixelBufferPool` out, `appendPixelBuffer`. Android: external-OES in, `MediaCodec.createInputSurface()` EGLSurface out.)*
2. **Composite once, present to many.** One render → blit to encoder **and** preview (**and** photo on shutter). Re-rendering preview doubles bandwidth and lets recorded/previewed pixels drift. *(iOS: one IOSurface served to writer + `copyPixelBuffer`. Android: one FBO, `eglMakeCurrent` per consumer surface — Grafika `RecordFBOActivity`.)*
3. **Sample native YUV in-shader; never force BGRA out of the camera.** NV12 4:2:0 is **12 bpp** vs BGRA **32 bpp** → forcing BGRA capture is **2.67× the memory bandwidth** *plus* an extra ISP conversion pass. Bandwidth is the thermal budget (~120 mW per GB/s on Mali; memory traffic is the #1 GPU power cost). *(iOS: capture `420YpCbCr8BiPlanarVideoRange`, bind plane0=R8/plane1=RG8, matrix in fragment shader. Android: `samplerExternalOES` does YUV→RGB in the driver sampler.)*
4. **Color range + matrix must match the source.** BT.709 + limited range (16–235) is the HD/720p default; decoding limited as full washes out, full as limited crushes. Tag the output file. *(iOS: pick shader coefficients per Video/FullRange. Android: set `KEY_COLOR_RANGE`/`KEY_COLOR_STANDARD`/`KEY_COLOR_TRANSFER` on the encoder format.)*
5. **Zero allocation on the hot path.** No `new`/object creation inside capture or render callbacks — GC pauses (Android) and ARC churn (iOS) = dropped frames. Pre-allocate matrices, `BufferInfo`, PCM buffers, pools at init. *(iOS: reuse `MTLTexture`/`MTLBuffer`, `CVPixelBufferPool`. Android: `BufferQueue` recycles; pre-create FBOs/programs/Surface.)*
6. **Buffer pool depth 2–4.** Double-buffer for latency, triple to absorb camera/display jitter; deeper only adds latency. *(iOS: `CAMetalLayer.maximumDrawableCount` 2–3 + in-flight semaphore. Android: triple-buffered FBO rotation.)*
7. **Capture never stalls — drop at the encoder boundary only.** Capture/preview free-run; if the writer isn't ready, drop the frame (the mp4 just gets slightly lower effective fps — **PTS still comes from the real capture timestamp, so no desync**). *(iOS: gate on `isReadyForMoreMediaData`, `alwaysDiscardsLateVideoFrames=true`. Android: async `MediaCodec`, skip when saturated.)*
8. **Never block the GPU per frame.** Async submit + completion handlers; no synchronous GPU wait. *(iOS: `addCompletedHandler`, **never `waitUntilCompleted`**; acquire `nextDrawable()` late. Android: single GL thread, **never `glFinish`**.)*
9. **Pre-compile and cache all pipeline state at init.** First-use shader/PSO compilation is a cold-start hitch. *(iOS: build `MTLRenderPipelineState` once + ship a `MTLBinaryArchive`. Android: compile GLES programs + create `EGLContext` once.)*
10. **One GL/Metal owner thread.** GL/EGL state is thread-local; Metal hot path stays off main. Camera `onFrameAvailable`/delegate callbacks do **zero** GPU work — they only signal the render thread. *(Android: dedicated `HandlerThread` owns the sole `EGLContext`; `onFrameAvailable` posts a message. iOS: dedicated serial capture + render queues.)*

---

## 4. Threading & frame-pacing model

**Three independent clocks that never cross-block: capture rate · display vsync · encoder drain.**

### Android thread topology
| Thread | Owns | Hot-path work | Hand-off |
|---|---|---|---|
| Camera/binder (HAL) | `onFrameAvailable` | **none** (no GL) | atomically signal GL `Handler` (coalesce to latest) |
| **GL render** (1, `HandlerThread`) | sole `EGLContext`, both `SurfaceTexture`s, FBO, encoder+Flutter `WindowSurface`s | `updateTexImage`×2, `getTransformMatrix`×2, composite→FBO, blit + `eglPresentationTimeANDROID` + `swapBuffers` ×2 | drives encoder via swap |
| Video drain | video `MediaCodec` async cb | `onOutputBufferAvailable` → muxer | lock → muxer |
| Audio capture+encode | `AudioRecord` + AAC codec | read PCM, stamp PTS, queue, drain | lock → muxer |
| Muxer (shared) | `MediaMuxer` | `addTrack`/`writeSampleData` | **single mutex** (MediaMuxer is not thread-safe) |

The **back camera's `onFrameAvailable` is the record clock.** Front is latched latest-available so a rate mismatch never stalls. Preview is decoupled — a busy encoder never freezes the viewfinder.

### iOS queue topology
- **Session/control queue** (serial, off-main): `startRunning()` blocks; batch all setup in one `beginConfiguration`/`commitConfiguration`.
- **Capture queue** (serial, `setSampleBufferDelegate(_:queue:)`): must finish within one frame interval; **never retain sample buffers** (AVF stops delivering). Watch `didDrop` + `DroppedFrameReason` for back-pressure telemetry.
- **Composite/encode:** Metal pass → `AVAssetWriter` gated by `isReadyForMoreMediaData`.
- **Preview:** clocked by `CADisplayLink`, reads the latest completed frame independent of capture rate.

---

## 5. A/V sync — one monotonic timebase (the part that desyncs if wrong)

### Android (we mux ourselves → this is the whole game)
Both `SurfaceTexture.getTimestamp()` and `AudioRecord.getTimestamp(…, TIMEBASE_MONOTONIC)` report **CLOCK_MONOTONIC nanoseconds** = the same base as `System.nanoTime()`. Capture one `startNs` at record start; every PTS is `(thatClock − startNs)`.
- **Video PTS:** `eglPresentationTimeANDROID(display, encSurface, backSurfaceTexture.getTimestamp() − startNs)` **before** `swapBuffers()`. **Units: ns for EGL, µs for MediaCodec/Muxer — convert, or you get wrong duration / silent audio.**
- **Audio PTS:** extrapolate from the `AudioTimestamp` anchor, don't trust read-wall-clock:
  `ptsNs = anchor.nanoTime + (chunkStartFrame − anchor.framePosition) · 1e9 / sampleRate`, then `(ptsNs − startNs)/1000` µs. Pre-API-24 fallback: `nextPts += frames·1e6/sampleRate` accumulator.
- **Monotonic clamp per track:** `pts = max(pts, lastPts+1)` — extrapolation can hiccup and the muxer rejects out-of-order samples.

### iOS (AVAssetWriter shares the capture clock → mostly free)
- **Video PTS** = the **primary (back)** sample buffer's `CMSampleBufferGetPresentationTimeStamp` for the composited frame. Don't synthesize off a wall clock.
- **Audio:** pass `AVCaptureAudioDataOutput` buffers straight through; same session clock ⇒ A/V stay synced. Don't re-stamp.

---

## 6. Encoder tuning (thermal + latency)

**Default H.264 (AVC), not HEVC.** Lower per-frame encode complexity → lower media-engine duty cycle → cooler → more recording minutes before throttle, plus universal hardware encode. Two concurrent encoders share one media engine, so cheap-per-frame matters more than file size. HEVC is opt-in only when storage outweighs heat *and* a hardware HEVC encoder is confirmed. Always select a **hardware** encoder (Android: `MediaCodecInfo.isHardwareAccelerated()` + `getSupportedPerformancePoints()` covering `HD_30` for **two** sessions).

| Goal | iOS (VideoToolbox / AVAssetWriter) | Android (`MediaFormat`) |
|---|---|---|
| Realtime priority | `RealTime=true`; `EnableLowLatencyRateControl=true` | `KEY_PRIORITY=0`; `KEY_OPERATING_RATE≥fps` |
| No B-frames (latency) | `AllowFrameReordering=false` | `KEY_MAX_B_FRAMES=0` |
| Even thermal load | CBR (`ConstantBitRate`, iOS16+) | `KEY_BITRATE_MODE=CBR` |
| Keyframe interval | `MaxKeyFrameInterval≈1–2s` | `KEY_I_FRAME_INTERVAL≈1–2` |
| Bitrate @720p30 | ≈4 Mbps H.264 | `KEY_BIT_RATE≈4_000_000` |
| FPS hint | `AVVideoExpectedSourceFrameRateKey=30` | `KEY_FRAME_RATE=30` |
| Min latency | `PrioritizeEncodingSpeedOverQuality` | `KEY_LATENCY=1` |

*Why cooler buys minutes:* keyframes ≫ inter-frames (short GOP inflates bitrate/heat); B-frames add a reorder buffer (~100 ms latency) + compute; VBR spikes thermally — CBR gives the even, predictable load you want when two encoders share the engine.

---

## 7. The compositor pass (shared shaders, both platforms)

Single scene render: **back full-frame quad**, then **front PiP inset quad**. The PiP quad applies, in order: the camera OES/sensor transform, then the layout transform (offset/scale/corner/margin from the resolver), then **horizontal mirror** for the front lens, with **rounded corners via a signed-distance-field in the fragment shader** (`smoothstep` the alpha against a rounded-rect SDF — one pass, no stencil, no extra geometry). `swapPrimary()` just swaps which feed is the full-frame quad vs the inset.

**One layout resolver, computed in Dart**, emits normalized rects/flags passed to both natives so preview, recording, and the still are bit-identical and the two platforms can't drift. The natives are dumb renderers of that resolver output.

---

## 8. Photo path (same compositor, higher-res target)

Reuse the exact composite shaders into a **separate, larger FBO/texture** rendered on demand off the recording cadence — decouples photo resolution from the 720p video path. Then encode the still.
- **Android:** recommended = dedicated hi-res FBO render → read back (or PBO/`ImageReader`-backed async readback to avoid the `glReadPixels` stall). Avoid plain live-FBO `glReadPixels` except for a quick thumbnail (synchronous stall, drops video frames, 720p-capped).
- **iOS:** default = grab the latest composited buffer → HEIC/JPEG (zero extra hardware cost, WYSIWYG). Full-res individual stills (dual `AVCapturePhotoOutput`) only if the product needs them — raises `hardwareCost`, may force lower video res.

Front feed is mirrored in the shader, so the still matches preview automatically.

---

## 9. Cold-start (time-to-first-frame)

**iOS:** session setup + `startRunning()` on a serial off-main queue; one `begin/commitConfiguration`; build `MTLRenderPipelineState` once + harvest a `MTLBinaryArchive`; pre-create `CVMetalTextureCache` + pool; gate on `isMultiCamSupported`/`supportedMultiCamDeviceSets` first.
**Android:** `CameraXConfig.setAvailableCamerasLimiter(...)` (camera-open is hundreds-of-ms blocking IPC — the long pole; start early); create `EGLContext` + compile programs once; pre-create encoder + input Surface; pre-allocate FBOs/pool; keep the render thread spun up.

---

## 10. Measurement harness (how we *prove* lag-free)

Build a **debug HUD** in the example app fed from native: live **FPS**, **composite GPU ms** (target line 16 ms), **dropped-frame counter**, **encoder-not-ready count**, **thermal state**, and on iOS **hardwareCost / systemPressureCost** bars. This is the single most useful "are we lag-free" instrument.

| Metric | iOS | Android |
|---|---|---|
| GPU frame time | `MTLCommandBuffer.gpuEndTime − gpuStartTime` | AGI / Perfetto GPU counters |
| FPS / interval | `CADisplayLink` | `Choreographer.doFrame(frameTimeNanos)` |
| Dropped / jank | `didDrop` + `DroppedFrameReason` | `JankStats.isJank`/`frameOverrunNanos`; `dumpsys gfxinfo` |
| Encoder saturation | `isReadyForMoreMediaData` false-rate | persistent `INFO_TRY_AGAIN_LATER` |
| Thermal | `ProcessInfo.thermalState` + notification | `getThermalHeadroom()` (0.0–1.0+, **dimensionless not ms**, poll ≤1 Hz) + `addThermalStatusListener` |
| Dual-cam sustainability | `hardwareCost` & `systemPressureCost` (**>1.0 = unsustainable**) | `getSupportedPerformancePoints()` for 2 sessions |

**Targets defining "lag-free" at 720p30:** per-frame budget **33.3 ms**; **composite GPU < 16 ms** (one 60 Hz vsync); **zero** dropped/jank frames; encoder drains every frame; iOS `hardwareCost ≤ 1.0` **and** `systemPressureCost ≤ 1.0`; thermal ≤ `.fair` (iOS) / headroom < ~0.9 (Android) for sustained record — degrade res/fps proactively beyond that. Red line: any frame > **700 ms** = "app frozen."

---

## 11. How this maps to the codebase

Native side of each impl package, organized so the compositor is platform-mirrored and everything else is thin:

```
android/.../  CameraSource (CameraX/Camera2 → 2× SurfaceTexture)
              GlThread (sole EGLContext) · Compositor (FBO + SDF shaders) · LayoutResolver(in)
              VideoEncoder (MediaCodec surface-in) · AudioEncoder (AudioRecord+AAC) · Muxer (MediaMuxer, locked)
              PhotoCapturer (hi-res FBO) · FlutterSurfaceSink (SurfaceProducer) · CapabilityProbe · ThermalGovernor
ios/Classes/  CameraSource (AVCaptureMultiCamSession, manual connections)
              MetalCompositor (CVMetalTextureCache + pool + SDF shaders) · LayoutResolver(in)
              MovieWriter (AVAssetWriter + adaptor + audio) · PhotoCapturer
              FlutterTextureSink (copyPixelBuffer) · CapabilityProbe · ThermalGovernor
```
- **`LayoutResolver`** lives in Dart (shared); natives consume normalized rects/flags.
- **`ThermalGovernor`** is the proactive degrade controller (fps → res → shader cost), per §10 gates.
- Pigeon (`@HostApi` commands + `@EventChannelApi` for `onThermal`/`onCapabilityChanged`/`onError`) is the only cross-boundary surface; `initialize()` returns the texture id.

---

## 12. Gotchas (the ones that will actually bite)

1. **One `EGLContext`, one GL thread.** All `updateTexImage`/`getTransformMatrix`/draws there; camera callbacks do zero GL.
2. **Re-query the OES transform matrix every `updateTexImage()`** — it changes per frame; caching it tears/letterboxes.
3. **ns vs µs** — `eglPresentationTimeANDROID` is ns, `MediaCodec`/`MediaMuxer` PTS is µs. One slip = wrong duration / no audio.
4. **One monotonic timebase** for video + audio (`SurfaceTexture.getTimestamp()` and `AudioRecord.getTimestamp(MONOTONIC)` minus one `startNs`). Never `System.currentTimeMillis`.
5. **Surface-input encoder has no `onInputBufferAvailable`** — feed via GL `swapBuffers`, end via `signalEndOfInputStream()`.
6. **MediaMuxer:** `addTrack` only on `INFO_OUTPUT_FORMAT_CHANGED`; `start()` only after both tracks; serialize all calls under one lock; `stop()` only after both EOS; skip `BUFFER_FLAG_CODEC_CONFIG` buffers. Else corrupt mp4.
7. **iOS: fix mirroring in the shader, not the preview connection** (preview-only fixes are the classic "right in preview, wrong in file").
8. **iOS: never retain capture sample buffers** and **never `waitUntilCompleted`** on the hot path.
9. **iOS Flutter texture wants BGRA/IOSurface** — composite YUV→ one BGRA IOSurface that serves both writer and `copyPixelBuffer`. Non-BGRA is misread.
10. **Flutter Android: `createSurfaceProducer()`**, call `getSurface()` fresh each draw (never cache), stop on `onSurfaceDestroyed` (backgrounding destroys it).
11. **Concurrency is hardware-gated** (~23% Android, 720p cap; iOS A12+) — probe first, degrade gracefully, handle `ERROR_MAX_CAMERAS_IN_USE` / `isMultiCamSupported==false`.

---

## Sources
Consolidated in the four research briefs that produced this doc; the load-bearing primary sources:
**Android pipeline:** [AOSP SurfaceTexture](https://source.android.com/docs/core/graphics/arch-st) · [AOSP concurrent streaming](https://source.android.com/docs/core/camera/concurrent-streaming) · [MediaCodec](https://developer.android.com/reference/android/media/MediaCodec) · [Grafika](https://github.com/google/grafika) · [bigflake MediaCodec](https://bigflake.com/mediacodec/) · [AudioTimestamp](https://developer.android.com/reference/android/media/AudioTimestamp) · [Thermal API](https://developer.android.com/games/optimize/adpf/thermal) · [SurfaceProducer](https://docs.flutter.dev/release/breaking-changes/android-surface-plugins)
**iOS pipeline:** [AVMultiCamPiP](https://developer.apple.com/documentation/avfoundation/capture_setup/avmulticampip_capturing_from_multiple_cameras) · [WWDC19 s249 (cost model)](https://asciiwwdc.com/2019/sessions/249) · [CVMetalTextureCache](https://developer.apple.com/documentation/corevideo) · [TN2445 frame drops](https://developer.apple.com/library/archive/technotes/tn2445/_index.html) · [low-latency rate control (WWDC21)](https://developer.apple.com/videos/play/wwdc2021/10158/) · [FlutterTexture BGRA (#147242)](https://github.com/flutter/flutter/issues/147242)
**Bandwidth/color:** [Mali tile-based rendering / 120 mW per GB·s](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/the-mali-gpu-an-abstract-machine-part-2---tile-based-rendering) · [8-bit YUV (NV12 12bpp, BT.601/709)](https://learn.microsoft.com/en-us/windows/win32/medfound/recommended-8-bit-yuv-formats-for-video-rendering) · [Android render perf / 16ms budget](https://developer.android.com/topic/performance/vitals/render)

# iOS Handoff — `dual_cameras` on iPhone 12 mini

**To:** the iOS/Flutter (Swift/Metal) agent
**From:** the Android engine work, June 28 2026
**Goal:** take the **scaffolded-but-never-compiled** iOS implementation and make it actually record a composited front+back portrait `.mp4` + photo + live preview on a real **iPhone 12 mini** — reaching parity with the working Android path.

Read this first, then `MASTER_PLAN.md §5` and `ARCHITECTURE.md §2,§5–§9` for the deep engine design. This doc is the *delta*: what's already there, what's missing, and the lessons Android paid for that you can collect for free.

---

## 0. Device target

- **iPhone 12 mini** — A14 Bionic, multicam-capable (`AVCaptureMultiCamSession.isMultiCamSupported == true`; A12+). Fully in scope.
- The **`hardwareCost < 1.0` wall is real on this class of device** — full-res on both cameras will refuse to run. You *must* select downscaled `activeFormat`s (see §3.2). Don't skip it; the scaffold currently doesn't do it and will likely fail to start.

---

## 1. Current state of the iOS package

Everything compiles *in theory* (written to spec) but **has never been built or run** — no Mac was available. Files (`packages/dual_cameras_ios/ios/Classes/`):

| File | Lines | State |
| --- | --- | --- |
| `DualCamerasPlugin.swift` | 195 | Pigeon host API wiring, texture registry, command handlers. Review against the regenerated `Messages.g.swift`. |
| `DualCameraSession.swift` | 169 | `AVCaptureMultiCamSession` setup, manual connection wiring, AVMultiCamPiP latch, sample delivery, record/photo. **No format selection / no `hardwareCost` handling.** |
| `MetalCompositor.swift` | 180 | Zero-copy `CVMetalTextureCache` in, BGRA/IOSurface pool out, blend pipeline, rounded-corner SDF. **No rotate-upright / no aspect-cover.** |
| `Shaders.metal` | 60 | YUV→RGB in-shader, mirror, rounded SDF. **Samples texcoords directly — no orientation/aspect transform.** |
| `MovieWriter.swift` | 82 | `AVAssetWriter` + pixel-buffer adaptor + audio input. Verify `startSession(atSourceTime:)` on first PTS. |
| `DualCameraTexture.swift` | 27 | `FlutterTexture.copyPixelBuffer` bridge. |
| `Messages.g.swift` | 749 | Generated Pigeon. **Regenerate** (`dart run pigeon --input pigeons/messages.dart` from the platform-interface package) so all three sides match. |

Android is the working reference — when a behavior is ambiguous, **read the Kotlin** in `packages/dual_cameras_android/.../`:
`gl/DualCompositor.kt`, `pipeline/RenderThread.kt`, `camera/CameraSource.kt`, `DualCamerasPlugin.kt`.

---

## 2. ⭐ The #1 lesson from Android: orientation + aspect-cover (this WILL bite you)

On Android the front (selfie) feed came out **stretched and squished**. Root cause and fix (now baked into `DualCompositor.kt`):

- Cameras deliver a **landscape** buffer (e.g. 4:3, `w/h ≈ 1.333`).
- The compositor cover-crops the source into the portrait 9:16 canvas using a `mat2` (`texXform`) that **rotates the source upright** *and* **aspect-cover-crops without distortion** (verified to be a uniform-scale similarity transform for 0°/90°).
- The bug was feeding it the **wrong source aspect**. On Android, the `SurfaceTexture` transform matrix *already rotates the frame 90° upright* before sampling, so the aspect the cover math needs is the **rotated** one, `h/w` — for a 4:3 source that's **`0.75`**, verified perfect on Pixel 8 for front *and* back. The fix: `setSourceSize` uses `h/w`, not `w/h`.

### Why iOS is HARDER here, not easier

**iOS gives you none of that rotation for free.** `AVCaptureVideoDataOutput` hands you a raw `CVPixelBuffer` in the **sensor's native landscape orientation** — there is no `SurfaceTexture` transform doing a silent 90° rotate. So on iOS you must do the **full** rotate-upright + aspect-cover **yourself in the Metal shader**. Right now `Shaders.metal` does neither — it samples `uv` straight, so both feeds will be sideways *and* stretched.

### What to build (port Android's `texXform`)

1. Add a texture-transform to `QuadUniforms` (both `MetalCompositor.swift` and `Shaders.metal`) — a `float2x2` (+ optional center offset) that maps quad-normalized coords → source-texcoords, exactly like Android's `texXform(srcAspect, targetAspect, rotationDeg)` in `DualCompositor.kt` (lines ~127–145). Apply it in the **vertex** shader to the centered texcoord (`uv - 0.5`), *then* mirror, like the Android GLSL `VERTEX` does.
2. Compute it on the CPU per feed from: the feed's **source aspect** (`CVPixelBufferGetWidth/Height`), the **target rect aspect** (full canvas for primary, inset for secondary), and the **rotation** needed to bring the sensor upright.
3. **Rotation on iOS:** derive from `AVCaptureConnection.videoRotationAngle` (iOS 17+) or device/sensor orientation — *don't* rely on a free transform. Bake it in the shader (ARCHITECTURE §5.5: "fix mirroring in the shader, not the preview connection"). For v1 you may lock UI to portrait to de-risk.
4. **Front aspect ≠ back aspect is normal** (front is often 4:3, back 16:9). Compute each feed's transform from its *own* buffer dims — exactly what Android does with separate `frontSrcAspect`/`backSrcAspect`.

> Expect to spend real time tuning this on the device. **Build the debug tuning channel (§6) early** — it's how Android nailed `0.75` in minutes instead of guessing. The empirical knobs are: rotation (90° steps), mirror, and source-aspect override.

---

## 3. Prioritized work items

### P0 — make it compile and run on the device
- **Metal library bundling.** `MetalCompositor` loads `makeDefaultLibrary(bundle: Bundle(for:))`. Confirm `Shaders.metal` is compiled into the pod's resource bundle and the bundle path resolves (classic plugin gotcha — a default-library load returning nil = black output). Check `dual_cameras_ios.podspec` (`resource_bundles` / `s.resources`).
- **Regenerate Pigeon** and reconcile `DualCamerasPlugin.swift` against it.
- Get a clean `flutter build ios` / Xcode run on a provisioned iPhone 12 mini. Add `NSCameraUsageDescription` + `NSMicrophoneUsageDescription` to the **example** app's `Info.plist`.

### P0 — multicam format selection + `hardwareCost` (else the session won't run)
`DualCameraSession.addCamera` currently sets only `videoSettings` pixel format and leaves formats at default. On the 12 mini this risks `hardwareCost ≥ 1.0` → session refuses to run. Per `MASTER_PLAN §5.1`:
- Preset must be `.inputPriority`; set each device's `activeFormat` manually (prefer **binned** formats, `format.isVideoBinned`).
- After `commitConfiguration`, check `session.hardwareCost` (and `systemPressureCost`); if `≥ 1.0`, step down: lower-res `activeFormat` → cap fps via `videoMinFrameDurationOverride` → last resort disable a feed. Target both **< 1.0 with margin**.
- Discover legal pairs via `supportedMultiCamDeviceSets` — don't hardcode.

### P0 — orientation + aspect-cover in the shader
Per §2 above. This is the bulk of the visual-correctness work.

### P1 — mirroring correct *in the recorded file*
The latch + mirror flags are wired; verify the selfie is mirrored in the **mp4**, not just preview (ARCHITECTURE §12.7). Mirror is applied in the vertex shader after the texture transform — match Android's order.

### P1 — A/V sync + clean finish
- Video PTS = the **back (primary)** sample buffer's `CMSampleBufferGetPresentationTimeStamp` (ARCHITECTURE §5). Audio passes through with capture-clock PTS → synced for free. **Do not** synthesize PTS off a wall clock.
- `MovieWriter`: `startWriting()` + `startSession(atSourceTime: firstPTS)` on the first composite; append only when `isReadyForMoreMediaData` (else drop — back-pressure, never block the capture queue); finish via `markAsFinished` → `finishWriting{}`; surface the file only when `status == .completed`.

### P1 — photo + thermal
- Photo (Path B, default): the scaffold grabs `latestComposite` → JPEG via `CIImage`/`CIContext`. Fine for WYSIWYG; just confirm orientation/mirror match preview once §2 lands.
- Thermal: `thermalChanged` is wired to a callback; connect it to proactive downscale (fps → res → disable PiP) and surface via the `onThermal` event.

### P2 — debug-tuning parity (do this on day 1, see §6)

---

## 4. Build / test

- **Needs:** a Mac with Xcode + a provisioned **iPhone 12 mini** (multicam can't run on the simulator). Linux/emulator can't exercise any of this.
- Example app = harness: `packages/dual_cameras/example`, `flutter run -d <iphone>`.
- Signing: set a development team on the Runner target. Camera + mic usage strings in the example `Info.plist`.
- Pull/validate output the same way as Android: record a clip, AirDrop/extract the `.mp4`, `ffprobe` it (expect h264/hevc video + aac audio, portrait dims, sane duration).

---

## 5. Verification checklist (definition of done)

- [ ] Session starts on the 12 mini with `hardwareCost < 1.0` and `systemPressureCost < 1.0`.
- [ ] Live preview shows both feeds composited, **upright and un-stretched**, primary full-frame + secondary inset (rounded/circle), front mirrored.
- [ ] Recorded `.mp4` is the same WYSIWYG composite, **A/V in sync** over a 3-min clip (lips match), no corrupt files on start/stop.
- [ ] Photo matches preview framing; front not backwards.
- [ ] `swapPrimary` flips the full-frame feed live; layout/mirror changes apply live.
- [ ] Thermal observed; clip caps / downscales under pressure; clean finalize on interruption.
- [ ] Same Dart code drives iOS and Android (the example app already does).

---

## 6. ⭐ Build the debug tuning channel first (it paid for itself on Android)

Android has a live tuning panel that made the orientation/aspect problem solvable on-device without native rebuilds. **Port it to iOS before fighting the shader** — it's the fastest path through §2.

Reference implementation (Android), copy the shape:
- **Native:** a `MethodChannel("dual_cameras/debug")` registered in `DualCamerasPlugin.kt` (`onAttachedToEngine`) with handlers `setRotationOffset {front, offset}`, `setAspectOverride {front, aspect}`, `setMirrorFront {on}`. They forward to live-mutable vars on the compositor (`DualCompositor.setRotationOffset/setAspectOverride`) — raw sensor degrees and the offset are stored separately so the offset re-applies cleanly.
- **Dart (shared example):** the panel already exists in `packages/dual_cameras/example/lib/main.dart` (`_debugPanel`, `_rotationRow`, `_aspectRow`, `_setRotation/_setAspect/_setMirror`) talking to that same channel. **It is platform-agnostic** — once the iOS plugin registers the same `dual_cameras/debug` channel and wires the same three methods into `MetalCompositor`, the existing UI drives iOS for free.

iOS plumbing:
1. `MetalCompositor`: add live vars `frontRotationOffset`/`backRotationOffset` (degrees) and `frontAspectOverride`/`backAspectOverride` (`<= 0` = use reported), feeding the per-feed texture-transform computed in §2. Add setters.
2. `DualCameraSession`: forward setters to the compositor (hop to `dataQueue`).
3. `DualCamerasPlugin.swift`: register the `FlutterMethodChannel` and route the three methods, mirroring `handleDebug` in `DualCamerasPlugin.kt`.

Find the right values on the 12 mini, then bake them as defaults (and, like Android, fold a permanent aspect correction into the equivalent of `setSourceSize` so the knob isn't needed in release). **Strip the debug channel/panel or gate behind `kDebugMode` before pub.dev publish.**

---

## 7. Known scaffold gaps to fix (quick list)

1. `Shaders.metal` / `QuadUniforms`: no texture transform → add rotate-upright + aspect-cover (§2). **Biggest item.**
2. `DualCameraSession.addCamera`: no `activeFormat` / no `hardwareCost` gating (§3.2).
3. Metal default-library bundling unverified (§3 P0) — black output if the bundle path is wrong.
4. `MovieWriter` `startSession(atSourceTime:)` and `.completed`-gated file surfacing — verify.
5. Pigeon `Messages.g.swift` may be stale — regenerate.
6. iOS perf-HUD telemetry (`onFrameStats`) is Android-only; add Metal-side timing (`gpuEndTime − gpuStartTime`) for parity (BUILD_STATUS follow-up).
7. Front mirroring must be verified **in the file**, not just preview (§12.7).

---

## 8. Pointers

- Engine design: `ARCHITECTURE.md` (§2 data flow, §5 sync, §5.2 Metal, §6 encoder, §9 cold-start, §12 gotchas).
- What to build / phasing: `MASTER_PLAN.md §5`.
- Android reference (the working truth): `packages/dual_cameras_android/android/src/main/kotlin/com/romanslack/dual_cameras_android/` — especially `gl/DualCompositor.kt` (`texXform`, `setSourceSize`, rotation offsets) and `pipeline/RenderThread.kt`.
- Orientation/aspect finding (memory): a 4:3 source needs aspect `0.75` on Pixel 8 because the source is consumed rotated-upright; iOS must produce that rotation itself.

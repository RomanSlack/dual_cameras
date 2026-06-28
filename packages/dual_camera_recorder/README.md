# dual_camera_recorder

Record the **front and back cameras simultaneously** into a single composited
`.mp4` (and photo), with a live composited preview. Android + iOS.

The OS APIs can do this, but no Flutter plugin records the *composited* result —
they stop at preview or unmerged photos. `dual_camera_recorder` owns a unified
manual GPU compositor (OpenGL ES on Android, Metal on iOS) so one composite per
frame feeds the encoder **and** the preview, producing a clean PiP/split clip
that drops straight into your existing media pipeline.

> **Hardware-gated.** Simultaneous front+back requires concurrent-camera support:
> ~A12+/iOS 13+ on iOS, and a subset of Android devices (Pixel 6+, Galaxy S22+,
> …) capped at 720p per camera. Always check `isSupported()` and provide a
> single-camera fallback.

## Install

```yaml
dependencies:
  dual_camera_recorder: ^0.1.0
```

Add permissions in the **consuming app**:

- **iOS** `Info.plist`: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`
- **Android** `AndroidManifest.xml`: `CAMERA`, `RECORD_AUDIO` (`minSdkVersion 24`)

Request them at runtime (e.g. with `permission_handler`) before `initialize`.

## Usage

```dart
import 'package:dual_camera_recorder/dual_camera_recorder.dart';

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

// Live composited preview:
DualCameraPreview(cam);

await cam.startRecording();
cam.swapPrimary();                            // flip the full-frame camera, live
final String clip  = await cam.stopRecording(); // single composited mp4
final String photo = await cam.takePhoto();      // single composited still
await cam.dispose();
```

### Layouts

`DualLayout.pictureInPicture(...)`, `DualLayout.splitVertical(...)`,
`DualLayout.splitHorizontal(...)`. The geometry is computed once and applied
identically to preview, recording, and photo so they never drift. Pass an
updated layout to `cam.setLayout(...)` live.

### Performance HUD

`DualCameraStatsOverlay(cam)` renders a debug overlay (FPS, composite ms,
dropped frames, thermal state) sourced from native telemetry — useful for
validating the lag-free targets on real hardware.

## How it works

`dual_camera_recorder` is a federated plugin. The Android side feeds two
concurrent `SurfaceTexture`s into a single-GL-thread compositor →
`MediaCodec`/`MediaMuxer`; iOS uses `AVCaptureMultiCamSession` → a Metal
compositor → `AVAssetWriter`. Audio and video share one monotonic clock so they
stay in sync. See `ARCHITECTURE.md` in the repository for the full engine
design and performance discipline.

## License

MIT © RomanSlack

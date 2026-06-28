# dual_camera_recorder_android

The Android implementation of
[`dual_camera_recorder`](https://pub.dev/packages/dual_camera_recorder).

CameraX/Camera2 concurrent capture → a single-GL-thread manual compositor
(OpenGL ES, SDF rounded PiP + front mirror) → `MediaCodec` surface-input encode
→ `MediaMuxer`, with `AudioRecord`+AAC and a single-`CLOCK_MONOTONIC` A/V sync.

This package is endorsed by `dual_camera_recorder`; you do not need to depend on
it directly.

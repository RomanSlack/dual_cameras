# dual_camera_recorder_ios

The iOS implementation of
[`dual_camera_recorder`](https://pub.dev/packages/dual_camera_recorder).

`AVCaptureMultiCamSession` (manual connection wiring) → a Metal compositor
(zero-copy `CVMetalTextureCache`, BGRA/IOSurface pool, SDF rounded PiP + front
mirror) → `AVAssetWriter`, with capture-clock A/V sync.

This package is endorsed by `dual_camera_recorder`; you do not need to depend on
it directly.

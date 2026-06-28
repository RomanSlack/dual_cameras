# dual_cameras_ios

The iOS implementation of
[`dual_cameras`](https://pub.dev/packages/dual_cameras).

`AVCaptureMultiCamSession` (manual connection wiring) → a Metal compositor
(zero-copy `CVMetalTextureCache`, BGRA/IOSurface pool, SDF rounded PiP + front
mirror) → `AVAssetWriter`, with capture-clock A/V sync.

This package is endorsed by `dual_cameras`; you do not need to depend on
it directly.

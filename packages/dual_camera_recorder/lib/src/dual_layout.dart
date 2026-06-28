import 'package:dual_camera_recorder_platform_interface/dual_camera_recorder_platform_interface.dart';

/// Friendly Dart-side builders for the composite [LayoutConfig].
///
/// The geometry is computed here, once, and applied identically to preview,
/// recording, and stills on the native side — so they can never drift.
abstract final class DualLayout {
  /// Picture-in-picture: [primary] full-frame, the other lens as a rounded
  /// inset anchored to [insetCorner].
  static LayoutConfig pictureInPicture({
    CameraLens primary = CameraLens.back,
    InsetCorner insetCorner = InsetCorner.bottomRight,
    double insetScale = 0.28,
    double cornerRadius = 18,
    double margin = 12,
    bool mirrorFront = true,
    bool circleInset = false,
  }) {
    assert(insetScale > 0 && insetScale <= 1, 'insetScale must be in (0, 1]');
    return LayoutConfig(
      mode: DualLayoutMode.pictureInPicture,
      primary: primary,
      insetCorner: insetCorner,
      insetScale: insetScale,
      cornerRadius: cornerRadius,
      margin: margin,
      mirrorFront: mirrorFront,
      circleInset: circleInset,
    );
  }

  /// Two equal halves stacked vertically ([primary] on top).
  static LayoutConfig splitVertical({
    CameraLens primary = CameraLens.back,
    bool mirrorFront = true,
  }) =>
      _split(DualLayoutMode.splitVertical, primary, mirrorFront);

  /// Two equal halves side by side ([primary] on the left).
  static LayoutConfig splitHorizontal({
    CameraLens primary = CameraLens.back,
    bool mirrorFront = true,
  }) =>
      _split(DualLayoutMode.splitHorizontal, primary, mirrorFront);

  static LayoutConfig _split(
    DualLayoutMode mode,
    CameraLens primary,
    bool mirrorFront,
  ) =>
      LayoutConfig(
        mode: mode,
        primary: primary,
        // Inset fields are unused for split layouts but the DTO is non-null.
        insetCorner: InsetCorner.bottomRight,
        insetScale: 0.5,
        cornerRadius: 0,
        margin: 0,
        mirrorFront: mirrorFront,
        circleInset: false,
      );
}

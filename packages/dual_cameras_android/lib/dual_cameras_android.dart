import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';

/// The Android implementation of `dual_cameras`.
///
/// Registered automatically at startup via `dartPluginClass`. The Dart side is
/// the shared Pigeon-backed implementation; all Android-specific work lives in
/// the native `DualCamerasPlugin`.
class DualCamerasAndroid {
  /// Registers this class as the default [DualCamerasPlatform] instance.
  static void registerWith() {
    DualCamerasPlatform.instance = PigeonDualCameras();
  }
}

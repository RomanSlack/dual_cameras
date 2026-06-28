import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';

/// The iOS implementation of `dual_cameras`.
///
/// Registered automatically at startup via `dartPluginClass`. The Dart side is
/// the shared Pigeon-backed implementation; all iOS-specific work lives in the
/// native `DualCamerasPlugin`.
class DualCamerasIOS {
  /// Registers this class as the default [DualCamerasPlatform] instance.
  static void registerWith() {
    DualCamerasPlatform.instance = PigeonDualCameras();
  }
}

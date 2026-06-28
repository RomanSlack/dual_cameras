import 'package:dual_camera_recorder_platform_interface/dual_camera_recorder_platform_interface.dart';

/// The Android implementation of `dual_camera_recorder`.
///
/// Registered automatically at startup via `dartPluginClass`. The Dart side is
/// the shared Pigeon-backed implementation; all Android-specific work lives in
/// the native `DualCameraRecorderPlugin`.
class DualCameraRecorderAndroid {
  /// Registers this class as the default [DualCameraRecorderPlatform] instance.
  static void registerWith() {
    DualCameraRecorderPlatform.instance = PigeonDualCameraRecorder();
  }
}

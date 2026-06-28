import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'events.dart';
import 'messages.g.dart';
import 'pigeon_dual_camera_recorder.dart';

/// The interface that platform implementations of dual_camera_recorder must
/// implement.
///
/// Platform implementations should extend this class rather than implement it
/// as `dual_camera_recorder` does not consider newly added methods to be
/// breaking changes. Extending this class (using `extends`) ensures that the
/// subclass will get the default implementation, while platform implementations
/// that `implements` this interface will be broken by newly added
/// [DualCameraRecorderPlatform] methods.
abstract class DualCameraRecorderPlatform extends PlatformInterface {
  DualCameraRecorderPlatform() : super(token: _token);

  static final Object _token = Object();

  static DualCameraRecorderPlatform _instance = PigeonDualCameraRecorder();

  /// The default instance to use.
  ///
  /// Defaults to the Pigeon-backed implementation, which works identically on
  /// every platform that registers the native side. Both the Android and iOS
  /// implementation packages re-affirm this instance via their `registerWith`.
  static DualCameraRecorderPlatform get instance => _instance;

  static set instance(DualCameraRecorderPlatform value) {
    PlatformInterface.verify(value, _token);
    _instance = value;
  }

  /// Broadcast stream of native events (ready / error / recording / thermal).
  Stream<DualCameraEvent> get events =>
      throw UnimplementedError('events has not been implemented.');

  /// Probe whether this device can run front+back concurrently, without
  /// bringing the pipeline up.
  Future<CameraCapabilities> probeSupport() =>
      throw UnimplementedError('probeSupport() has not been implemented.');

  /// Bring up the session + compositor. Returns the init result whose
  /// [InitResult.textureId] feeds a Flutter `Texture` widget.
  Future<InitResult> initialize(RecordingConfig config) =>
      throw UnimplementedError('initialize() has not been implemented.');

  Future<void> startRecording() =>
      throw UnimplementedError('startRecording() has not been implemented.');

  /// Stop recording; resolves to the composited .mp4 path.
  Future<String> stopRecording() =>
      throw UnimplementedError('stopRecording() has not been implemented.');

  /// Capture a composited still; resolves to the image path.
  Future<String> takePhoto() =>
      throw UnimplementedError('takePhoto() has not been implemented.');

  Future<void> swapPrimary() =>
      throw UnimplementedError('swapPrimary() has not been implemented.');

  Future<void> setLayout(LayoutConfig layout) =>
      throw UnimplementedError('setLayout() has not been implemented.');

  Future<void> dispose() =>
      throw UnimplementedError('dispose() has not been implemented.');
}

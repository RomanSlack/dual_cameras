import 'dart:async';

import 'dual_cameras_platform.dart';
import 'events.dart';
import 'messages.g.dart';

/// Default [DualCamerasPlatform] implementation backed by the Pigeon
/// channels. The same Dart code drives Android and iOS; only the native side
/// differs. Implements [DualCameraFlutterApi] so native state/telemetry lands
/// in [events].
///
/// Channel setup is deferred until first use: `registerWith()` constructs this
/// during plugin registration, which can run *before* the Flutter binding is
/// initialized — touching the [BinaryMessenger] there would throw. We wire the
/// host + flutter APIs lazily, by which point the binding is up.
class PigeonDualCameras extends DualCamerasPlatform
    implements DualCameraFlutterApi {
  PigeonDualCameras({DualCameraHostApi? hostApi})
      : _injectedHost = hostApi;

  final DualCameraHostApi? _injectedHost;
  DualCameraHostApi? _host;
  bool _flutterApiWired = false;
  final StreamController<DualCameraEvent> _events =
      StreamController<DualCameraEvent>.broadcast();

  /// Lazily construct the host API and register ourselves for native events.
  /// Safe to call repeatedly.
  DualCameraHostApi get _api {
    _host ??= _injectedHost ?? DualCameraHostApi();
    if (!_flutterApiWired) {
      DualCameraFlutterApi.setUp(this);
      _flutterApiWired = true;
    }
    return _host!;
  }

  @override
  Stream<DualCameraEvent> get events {
    // Ensure the flutter API is wired so native events are delivered even if
    // the caller listens before issuing any command.
    _api;
    return _events.stream;
  }

  @override
  Future<CameraCapabilities> probeSupport() => _api.probeSupport();

  @override
  Future<InitResult> initialize(RecordingConfig config) =>
      _api.initialize(config);

  @override
  Future<void> startRecording() => _api.startRecording();

  @override
  Future<String> stopRecording() => _api.stopRecording();

  @override
  Future<String> takePhoto() => _api.takePhoto();

  @override
  Future<void> swapPrimary() => _api.swapPrimary();

  @override
  Future<void> setLayout(LayoutConfig layout) => _api.setLayout(layout);

  @override
  Future<void> dispose() => _api.dispose();

  // --- DualCameraFlutterApi (native -> Dart) ---

  @override
  void onReady(int textureId) => _events.add(DualCameraReady(textureId));

  @override
  void onError(String code, String message) =>
      _events.add(DualCameraErrorEvent(code, message));

  @override
  void onRecordingStarted() => _events.add(const DualCameraRecordingStarted());

  @override
  void onRecordingStopped(String path) =>
      _events.add(DualCameraRecordingStopped(path));

  @override
  void onCapabilityChanged(CameraCapabilities capabilities) =>
      _events.add(DualCameraCapabilityChanged(capabilities));

  @override
  void onThermal(ThermalLevel level) =>
      _events.add(DualCameraThermalEvent(level));

  @override
  void onFrameStats(FrameStats stats) =>
      _events.add(DualCameraStatsEvent(stats));
}

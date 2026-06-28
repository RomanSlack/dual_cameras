import 'dart:async';

import 'package:dual_camera_recorder_platform_interface/dual_camera_recorder_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'dual_layout.dart';

/// Immutable snapshot of the controller's state, exposed via [ValueListenable].
@immutable
class DualCameraValue {
  const DualCameraValue({
    required this.isInitialized,
    required this.isRecording,
    required this.textureId,
    required this.capabilities,
    required this.thermal,
    required this.stats,
    required this.errorMessage,
  });

  const DualCameraValue.uninitialized()
      : isInitialized = false,
        isRecording = false,
        textureId = null,
        capabilities = null,
        thermal = ThermalLevel.nominal,
        stats = null,
        errorMessage = null;

  final bool isInitialized;
  final bool isRecording;

  /// The preview texture id; null until the pipeline is ready.
  final int? textureId;

  final CameraCapabilities? capabilities;
  final ThermalLevel thermal;

  /// Latest performance telemetry for the debug HUD; null until frames flow.
  final FrameStats? stats;
  final String? errorMessage;

  DualCameraValue copyWith({
    bool? isInitialized,
    bool? isRecording,
    int? textureId,
    CameraCapabilities? capabilities,
    ThermalLevel? thermal,
    FrameStats? stats,
    String? errorMessage,
  }) {
    return DualCameraValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isRecording: isRecording ?? this.isRecording,
      textureId: textureId ?? this.textureId,
      capabilities: capabilities ?? this.capabilities,
      thermal: thermal ?? this.thermal,
      stats: stats ?? this.stats,
      errorMessage: errorMessage,
    );
  }
}

/// Controls a dual-camera (front+back simultaneous) capture session.
///
/// ```dart
/// final cam = DualCameraController();
/// if (!await DualCameraController.isSupported()) { /* single-cam fallback */ }
/// await cam.initialize(layout: DualLayout.pictureInPicture());
/// // DualCameraPreview(cam) renders the live composite
/// await cam.startRecording();
/// final clip = await cam.stopRecording();
/// await cam.dispose();
/// ```
class DualCameraController extends ValueNotifier<DualCameraValue> {
  DualCameraController() : super(const DualCameraValue.uninitialized());

  DualCameraRecorderPlatform get _platform =>
      DualCameraRecorderPlatform.instance;
  StreamSubscription<DualCameraEvent>? _eventSub;

  /// Probe whether this device can run front+back concurrently without bringing
  /// the pipeline up. Cheap; safe to call before [initialize].
  static Future<CameraCapabilities> probeSupport() =>
      DualCameraRecorderPlatform.instance.probeSupport();

  /// Convenience wrapper over [probeSupport].
  static Future<bool> isSupported() async =>
      (await probeSupport()).isSupported;

  /// Bring up the session + compositor and start the live preview.
  Future<void> initialize({
    LayoutConfig? layout,
    DualResolution resolution = DualResolution.hd720,
    VideoCodec codec = VideoCodec.h264,
    bool recordAudio = true,
    Duration maxDuration = Duration.zero,
  }) async {
    _eventSub ??= _platform.events.listen(_onEvent);
    final config = RecordingConfig(
      layout: layout ?? DualLayout.pictureInPicture(),
      resolution: resolution,
      codec: codec,
      recordAudio: recordAudio,
      maxDurationMs: maxDuration.inMilliseconds,
    );
    final result = await _platform.initialize(config);
    value = value.copyWith(
      isInitialized: true,
      textureId: result.textureId,
      capabilities: result.capabilities,
    );
  }

  Future<void> startRecording() async {
    await _platform.startRecording();
    value = value.copyWith(isRecording: true);
  }

  /// Stop recording; returns the composited `.mp4` path.
  Future<String> stopRecording() async {
    final path = await _platform.stopRecording();
    value = value.copyWith(isRecording: false);
    return path;
  }

  /// Capture a composited still; returns the image path.
  Future<String> takePhoto() => _platform.takePhoto();

  /// Flip which feed is full-frame, live.
  Future<void> swapPrimary() => _platform.swapPrimary();

  /// Update the layout geometry live.
  Future<void> setLayout(LayoutConfig layout) => _platform.setLayout(layout);

  void _onEvent(DualCameraEvent event) {
    switch (event) {
      case DualCameraReady(:final textureId):
        value = value.copyWith(isInitialized: true, textureId: textureId);
      case DualCameraRecordingStarted():
        value = value.copyWith(isRecording: true);
      case DualCameraRecordingStopped():
        value = value.copyWith(isRecording: false);
      case DualCameraCapabilityChanged(:final capabilities):
        value = value.copyWith(capabilities: capabilities);
      case DualCameraThermalEvent(:final level):
        value = value.copyWith(thermal: level);
      case DualCameraStatsEvent(:final stats):
        value = value.copyWith(stats: stats);
      case DualCameraErrorEvent(:final message):
        value = value.copyWith(errorMessage: message);
    }
  }

  @override
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _platform.dispose();
    } finally {
      super.dispose();
    }
  }
}

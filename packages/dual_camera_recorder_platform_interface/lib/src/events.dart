import 'messages.g.dart';

/// Events emitted by the native pipeline, surfaced as a broadcast stream on
/// [DualCameraRecorderPlatform.events].
sealed class DualCameraEvent {
  const DualCameraEvent();
}

/// The pipeline is up and the preview texture (id) is producing frames.
class DualCameraReady extends DualCameraEvent {
  const DualCameraReady(this.textureId);
  final int textureId;
}

/// A non-fatal or fatal error from the native side.
class DualCameraErrorEvent extends DualCameraEvent {
  const DualCameraErrorEvent(this.code, this.message);
  final String code;
  final String message;
}

/// Recording has begun.
class DualCameraRecordingStarted extends DualCameraEvent {
  const DualCameraRecordingStarted();
}

/// Recording finished; [path] is the composited .mp4.
class DualCameraRecordingStopped extends DualCameraEvent {
  const DualCameraRecordingStopped(this.path);
  final String path;
}

/// Capability changed at runtime (e.g. degraded to single-camera fallback).
class DualCameraCapabilityChanged extends DualCameraEvent {
  const DualCameraCapabilityChanged(this.capabilities);
  final CameraCapabilities capabilities;
}

/// Thermal pressure changed; the app may want to warn or shorten clips.
class DualCameraThermalEvent extends DualCameraEvent {
  const DualCameraThermalEvent(this.level);
  final ThermalLevel level;
}

/// Periodic performance telemetry for the debug HUD.
class DualCameraStatsEvent extends DualCameraEvent {
  const DualCameraStatsEvent(this.stats);
  final FrameStats stats;
}

// Pigeon contract for dual_cameras.
//
// Regenerate with:
//   dart run pigeon --input pigeons/messages.dart
//
// Generated outputs are checked in (lib/src/messages.g.dart and the native
// files in the android/ios implementation packages).
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartPackageName: 'dual_cameras_platform_interface',
    kotlinOut:
        '../dual_cameras_android/android/src/main/kotlin/com/romanslack/dual_cameras_android/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.romanslack.dual_cameras_android',
    ),
    swiftOut: '../dual_cameras_ios/ios/Classes/Messages.g.swift',
  ),
)

/// Which physical camera a feed comes from.
enum CameraLens { back, front }

/// Corner the picture-in-picture inset is anchored to.
enum InsetCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Composition layout of the two feeds.
enum DualLayoutMode {
  /// Primary full-frame, secondary as a rounded inset.
  pictureInPicture,

  /// Two equal halves, stacked vertically.
  splitVertical,

  /// Two equal halves, side by side.
  splitHorizontal,
}

/// Target capture resolution (the hardware caps this; 720p is the safe ceiling
/// for Android concurrent cameras).
enum DualResolution { sd480, hd720, hd1080 }

/// Recorded video codec.
enum VideoCodec { h264, hevc }

/// Thermal pressure buckets, normalized across platforms.
enum ThermalLevel { nominal, fair, serious, critical }

/// Why a capability probe failed, when it did.
enum UnsupportedReason {
  /// The device hardware cannot run front+back concurrently.
  noConcurrentCamera,

  /// The OS version is too old for the multi-cam API.
  osTooOld,

  /// Camera permission has not been granted.
  permissionDenied,
}

/// Result of probing whether this device can run the dual-camera pipeline.
class CameraCapabilities {
  CameraCapabilities({
    required this.isSupported,
    this.maxWidth,
    this.maxHeight,
    this.reason,
  });

  bool isSupported;

  /// Max composite width the device can sustain concurrently (null if unknown).
  int? maxWidth;
  int? maxHeight;

  /// Populated only when [isSupported] is false.
  UnsupportedReason? reason;
}

/// The picture-in-picture / split geometry. Computed once in Dart and applied
/// identically to preview, recording, and stills so they can never drift.
class LayoutConfig {
  LayoutConfig({
    required this.mode,
    required this.primary,
    required this.insetCorner,
    required this.insetScale,
    required this.cornerRadius,
    required this.margin,
    required this.mirrorFront,
    required this.circleInset,
  });

  DualLayoutMode mode;

  /// Which lens is full-frame (PiP) / first half (split).
  CameraLens primary;

  InsetCorner insetCorner;

  /// Inset size as a fraction of the full frame's shorter side (PiP only).
  double insetScale;

  /// Inset corner radius in logical px (PiP only).
  double cornerRadius;

  /// Inset margin from the anchored corner in logical px (PiP only).
  double margin;

  /// Whether the front feed is horizontally mirrored (selfie convention).
  bool mirrorFront;

  /// PiP inset is a centered circle instead of a rounded rectangle (PiP only).
  bool circleInset;
}

/// Everything needed to bring the pipeline up.
class RecordingConfig {
  RecordingConfig({
    required this.layout,
    required this.resolution,
    required this.codec,
    required this.recordAudio,
    required this.maxDurationMs,
  });

  LayoutConfig layout;
  DualResolution resolution;
  VideoCodec codec;
  bool recordAudio;

  /// Hard cap on recording length; 0 = no cap (the ThermalGovernor may still
  /// stop earlier).
  int maxDurationMs;
}

/// Live performance telemetry for the debug HUD (ARCHITECTURE.md §10).
class FrameStats {
  FrameStats({
    required this.fps,
    required this.compositeMs,
    required this.droppedFrames,
    required this.thermal,
  });

  /// Composited frames per second over the last window.
  double fps;

  /// Mean GPU composite time in ms over the last window (target < 16).
  double compositeMs;

  /// Frames dropped at the encoder boundary since recording began.
  int droppedFrames;

  ThermalLevel thermal;
}

/// Returned by [initialize]; the texture id renders via Flutter's `Texture`.
class InitResult {
  InitResult({required this.textureId, required this.capabilities});

  int textureId;
  CameraCapabilities capabilities;
}

/// Commands: Dart -> native.
@HostApi()
abstract class DualCameraHostApi {
  /// Probe hardware support without bringing the pipeline up.
  @async
  CameraCapabilities probeSupport();

  /// Bring up the session + compositor; returns the preview texture id.
  @async
  InitResult initialize(RecordingConfig config);

  @async
  void startRecording();

  /// Returns the path to the finished composited .mp4.
  @async
  String stopRecording();

  /// Returns the path to a composited still (JPEG/HEIC).
  @async
  String takePhoto();

  /// Flip which feed is full-frame, live.
  @async
  void swapPrimary();

  /// Update layout geometry live (e.g. user drags the inset).
  @async
  void setLayout(LayoutConfig layout);

  @async
  void dispose();
}

/// State + telemetry: native -> Dart.
@FlutterApi()
abstract class DualCameraFlutterApi {
  void onReady(int textureId);
  void onError(String code, String message);
  void onRecordingStarted();
  void onRecordingStopped(String path);
  void onCapabilityChanged(CameraCapabilities capabilities);
  void onThermal(ThermalLevel level);
  void onFrameStats(FrameStats stats);
}

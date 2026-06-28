/// Common platform interface for the dual_camera_recorder plugin.
library dual_camera_recorder_platform_interface;

export 'src/dual_camera_recorder_platform.dart';
export 'src/events.dart';
export 'src/pigeon_dual_camera_recorder.dart';
export 'src/messages.g.dart'
    show
        CameraCapabilities,
        CameraLens,
        DualCameraFlutterApi,
        DualCameraHostApi,
        DualLayoutMode,
        DualResolution,
        FrameStats,
        InitResult,
        InsetCorner,
        LayoutConfig,
        RecordingConfig,
        ThermalLevel,
        UnsupportedReason,
        VideoCodec;

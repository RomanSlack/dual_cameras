/// Common platform interface for the dual_cameras plugin.
library dual_cameras_platform_interface;

export 'src/dual_cameras_platform.dart';
export 'src/events.dart';
export 'src/pigeon_dual_cameras.dart';
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

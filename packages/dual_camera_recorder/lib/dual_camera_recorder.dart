/// Record front + back cameras simultaneously into one composited video and
/// photo, with a live composited preview. Android + iOS.
library dual_camera_recorder;

export 'package:dual_camera_recorder_platform_interface/dual_camera_recorder_platform_interface.dart'
    show
        CameraCapabilities,
        CameraLens,
        DualLayoutMode,
        DualResolution,
        FrameStats,
        InsetCorner,
        LayoutConfig,
        ThermalLevel,
        UnsupportedReason,
        VideoCodec;

export 'src/dual_camera_controller.dart' show DualCameraController, DualCameraValue;
export 'src/dual_camera_hud.dart' show DualCameraStatsOverlay;
export 'src/dual_camera_preview.dart' show DualCameraPreview;
export 'src/dual_layout.dart' show DualLayout;

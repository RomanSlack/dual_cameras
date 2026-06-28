import 'package:flutter/widgets.dart';

import 'dual_camera_controller.dart';

/// Renders the live composited preview produced by [controller].
///
/// Shows nothing until the pipeline reports a texture id. The native side
/// composites front+back into a single texture, so this is a single
/// [Texture] — the same pixels that get recorded.
class DualCameraPreview extends StatelessWidget {
  const DualCameraPreview(
    this.controller, {
    super.key,
    this.placeholder,
    this.aspectRatio = 9 / 16,
  });

  final DualCameraController controller;

  /// Shown before the first composited frame is available.
  final Widget? placeholder;

  /// Aspect ratio of the composited output (the native canvas is portrait,
  /// 9:16). The preview is letterboxed to this so it shows exactly what gets
  /// recorded — never stretched to fill a differently-shaped box.
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DualCameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final id = value.textureId;
        if (id == null) {
          return placeholder ?? const SizedBox.shrink();
        }
        return Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Texture(textureId: id),
          ),
        );
      },
    );
  }
}

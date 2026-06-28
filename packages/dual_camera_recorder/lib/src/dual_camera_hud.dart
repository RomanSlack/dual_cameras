import 'package:dual_camera_recorder_platform_interface/dual_camera_recorder_platform_interface.dart';
import 'package:flutter/material.dart';

import 'dual_camera_controller.dart';

/// A debug performance overlay showing live FPS, composite time, dropped
/// frames, and thermal state (ARCHITECTURE.md §10). Color-codes against the
/// "lag-free" targets: composite < 16 ms, zero dropped frames.
class DualCameraStatsOverlay extends StatelessWidget {
  const DualCameraStatsOverlay(this.controller, {super.key});

  final DualCameraController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DualCameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final s = value.stats;
        if (s == null) return const SizedBox.shrink();
        final overBudget = s.compositeMs > 16;
        final dropped = s.droppedFrames > 0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Colors.white,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${s.fps.toStringAsFixed(0)} fps'),
                const SizedBox(width: 8),
                Text(
                  '${s.compositeMs.toStringAsFixed(1)} ms',
                  style: TextStyle(color: overBudget ? Colors.red : Colors.green),
                ),
                const SizedBox(width: 8),
                Text(
                  'drop ${s.droppedFrames}',
                  style: TextStyle(color: dropped ? Colors.red : Colors.green),
                ),
                const SizedBox(width: 8),
                Text(
                  s.thermal.name,
                  style: TextStyle(color: _thermalColor(s.thermal)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _thermalColor(ThermalLevel level) => switch (level) {
        ThermalLevel.nominal => Colors.green,
        ThermalLevel.fair => Colors.yellow,
        ThermalLevel.serious => Colors.orange,
        ThermalLevel.critical => Colors.red,
      };
}

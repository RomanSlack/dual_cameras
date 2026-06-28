import 'dart:async';

import 'package:dual_cameras/dual_cameras.dart';
import 'package:dual_cameras_platform_interface/dual_cameras_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePlatform extends DualCamerasPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<DualCameraEvent> controller =
      StreamController<DualCameraEvent>.broadcast();
  bool recording = false;

  @override
  Stream<DualCameraEvent> get events => controller.stream;

  @override
  Future<CameraCapabilities> probeSupport() async =>
      CameraCapabilities(isSupported: true, maxWidth: 1280, maxHeight: 720);

  @override
  Future<InitResult> initialize(RecordingConfig config) async => InitResult(
        textureId: 42,
        capabilities: CameraCapabilities(isSupported: true),
      );

  @override
  Future<void> startRecording() async => recording = true;

  @override
  Future<String> stopRecording() async {
    recording = false;
    return '/tmp/clip.mp4';
  }

  @override
  Future<String> takePhoto() async => '/tmp/shot.jpg';

  @override
  Future<void> swapPrimary() async {}

  @override
  Future<void> setLayout(LayoutConfig layout) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late _FakePlatform fake;

  setUp(() {
    fake = _FakePlatform();
    DualCamerasPlatform.instance = fake;
  });

  test('isSupported reflects the platform probe', () async {
    expect(await DualCameraController.isSupported(), isTrue);
  });

  test('initialize publishes the texture id', () async {
    final cam = DualCameraController();
    expect(cam.value.isInitialized, isFalse);
    await cam.initialize(layout: DualLayout.pictureInPicture());
    expect(cam.value.isInitialized, isTrue);
    expect(cam.value.textureId, 42);
  });

  test('record / stop toggles state and returns a path', () async {
    final cam = DualCameraController();
    await cam.initialize();
    await cam.startRecording();
    expect(cam.value.isRecording, isTrue);
    final path = await cam.stopRecording();
    expect(path, '/tmp/clip.mp4');
    expect(cam.value.isRecording, isFalse);
  });

  test('events update value (thermal + stats)', () async {
    final cam = DualCameraController();
    await cam.initialize();
    fake.controller.add(const DualCameraThermalEvent(ThermalLevel.serious));
    fake.controller.add(
      DualCameraStatsEvent(
        FrameStats(
          fps: 30,
          compositeMs: 9.5,
          droppedFrames: 0,
          thermal: ThermalLevel.serious,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(cam.value.thermal, ThermalLevel.serious);
    expect(cam.value.stats?.fps, 30);
    expect(cam.value.stats?.compositeMs, 9.5);
  });

  test('takePhoto returns a path', () async {
    final cam = DualCameraController();
    await cam.initialize();
    expect(await cam.takePhoto(), '/tmp/shot.jpg');
  });
}

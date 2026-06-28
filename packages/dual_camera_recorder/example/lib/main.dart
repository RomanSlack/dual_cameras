import 'package:dual_camera_recorder/dual_camera_recorder.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dual_camera_recorder',
      theme: ThemeData.dark(useMaterial3: true),
      home: const DemoScreen(),
    );
  }
}

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final DualCameraController _controller = DualCameraController();
  CameraCapabilities? _caps;
  String _status = 'Probing…';
  String? _lastFile;
  bool _circle = false;

  LayoutConfig _layout() => DualLayout.pictureInPicture(
        insetScale: 0.32,
        margin: 16,
        circleInset: _circle,
      );

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final caps = await DualCameraController.probeSupport();
    if (!mounted) return;
    setState(() {
      _caps = caps;
      _status = caps.isSupported
          ? 'Supported (up to ${caps.maxWidth}×${caps.maxHeight}) — grant permissions to start'
          : 'Not supported on this device (${caps.reason?.name ?? 'unknown'})';
    });
  }

  Future<void> _start() async {
    final granted = await [Permission.camera, Permission.microphone].request();
    if (granted.values.any((s) => !s.isGranted)) {
      setState(() => _status = 'Camera/microphone permission denied');
      return;
    }
    try {
      await _controller.initialize(layout: _layout());
      setState(() => _status = 'Initialized');
    } catch (e) {
      setState(() => _status = 'initialize failed: $e');
    }
  }

  Future<void> _guard(Future<void> Function() action, String label) async {
    try {
      await action();
      setState(() => _status = '$label ok');
    } catch (e) {
      setState(() => _status = '$label failed: $e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dual_camera_recorder')),
      body: ValueListenableBuilder<DualCameraValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          return Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.black,
                      child: DualCameraPreview(
                        _controller,
                        placeholder: const Center(
                          child: Text('Live preview appears on a real device'),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: DualCameraStatsOverlay(_controller),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_status, textAlign: TextAlign.center),
                    if (value.thermal != ThermalLevel.nominal)
                      Text('Thermal: ${value.thermal.name}',
                          style: const TextStyle(color: Colors.orange)),
                    if (_lastFile != null) Text('Saved: $_lastFile'),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: (_caps?.isSupported ?? false) &&
                                  !value.isInitialized
                              ? _start
                              : null,
                          child: const Text('Initialize'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized && !value.isRecording
                              ? () =>
                                  _guard(_controller.startRecording, 'record')
                              : null,
                          child: const Text('Record'),
                        ),
                        FilledButton(
                          onPressed: value.isRecording
                              ? () => _guard(() async {
                                    _lastFile =
                                        await _controller.stopRecording();
                                    await Gal.putVideo(_lastFile!);
                                  }, 'stop → gallery')
                              : null,
                          child: const Text('Stop'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized
                              ? () => _guard(() async {
                                    _lastFile = await _controller.takePhoto();
                                    await Gal.putImage(_lastFile!);
                                  }, 'photo → gallery')
                              : null,
                          child: const Text('Photo'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized
                              ? () => _guard(_controller.swapPrimary, 'swap')
                              : null,
                          child: const Text('Swap'),
                        ),
                        FilledButton(
                          onPressed: value.isInitialized
                              ? () => _guard(() async {
                                    setState(() => _circle = !_circle);
                                    await _controller.setLayout(_layout());
                                  }, _circle ? 'circle off' : 'circle on')
                              : null,
                          child: Text(_circle ? 'Square' : 'Circle'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

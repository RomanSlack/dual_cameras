import 'package:dual_cameras/dual_cameras.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dual_cameras',
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

  // Live geometry tuning (debug channel) — to dial in the front/back
  // orientation and fix any stretch directly on the device.
  static const MethodChannel _debug = MethodChannel('dual_cameras/debug');
  int _frontOffset = 90; // matches FRONT_ROTATION_OFFSET default
  int _backOffset = -90; // matches BACK_ROTATION_OFFSET default
  bool _mirrorFront = true;
  double _frontAspect = 0; // 0 = auto (use camera-reported)
  double _backAspect = 0;

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

  int _norm(int deg) => ((deg % 360) + 360) % 360;

  Future<void> _setRotation(bool front, int offset) async {
    final norm = _norm(offset);
    setState(() => front ? _frontOffset = norm : _backOffset = norm);
    await _debug.invokeMethod('setRotationOffset', {'front': front, 'offset': norm});
  }

  Future<void> _setAspect(bool front, double aspect) async {
    setState(() => front ? _frontAspect = aspect : _backAspect = aspect);
    await _debug.invokeMethod('setAspectOverride', {'front': front, 'aspect': aspect});
  }

  Future<void> _setMirror(bool on) async {
    setState(() => _mirrorFront = on);
    await _debug.invokeMethod('setMirrorFront', {'on': on});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _rotationRow(String label, bool front, int offset) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        IconButton(
          icon: const Icon(Icons.rotate_left),
          onPressed: () => _setRotation(front, offset - 90),
        ),
        SizedBox(
          width: 44,
          child: Text('$offset°', textAlign: TextAlign.center),
        ),
        IconButton(
          icon: const Icon(Icons.rotate_right),
          onPressed: () => _setRotation(front, offset + 90),
        ),
        const SizedBox(width: 4),
        for (final d in const [0, 90, 180, 270])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: ChoiceChip(
              label: Text('$d'),
              selected: offset == d,
              onSelected: (_) => _setRotation(front, d),
            ),
          ),
      ],
    );
  }

  Widget _aspectRow(String label, bool front, double aspect) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(
          child: Slider(
            min: 0,
            max: 2,
            divisions: 40,
            label: aspect == 0 ? 'auto' : aspect.toStringAsFixed(2),
            value: aspect,
            onChanged: (v) => _setAspect(front, v),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            aspect == 0 ? 'auto' : aspect.toStringAsFixed(2),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _debugPanel() {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text('Debug tuning'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          _rotationRow('Front rot', true, _frontOffset),
          _rotationRow('Back rot', false, _backOffset),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Mirror front'),
            value: _mirrorFront,
            onChanged: _setMirror,
          ),
          _aspectRow('Front aspect', true, _frontAspect),
          _aspectRow('Back aspect', false, _backAspect),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                _setAspect(true, 0);
                _setAspect(false, 0);
              },
              child: const Text('Reset aspect → auto'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dual_cameras')),
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
                    if (value.isInitialized) _debugPanel(),
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

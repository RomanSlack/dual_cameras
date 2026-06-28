// Smoke test for the example app. The native pipeline isn't exercised here
// (it needs a real device); this just confirms the widget tree builds.
import 'package:dual_cameras_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Demo app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const DemoApp());
    expect(find.text('dual_cameras'), findsWidgets);
  });
}

// The app asks to be paired until a bundle is stored, and refuses one that is
// not a bundle. Connecting is not covered: that needs a deck to connect to.

import 'dart:io';

import 'package:agents_deck_mobile/main.dart';
import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('deck_test');
    // path_provider is a platform channel; in a test it has to be answered.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? docs.path
              : null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    docs.deleteSync(recursive: true);
  });

  testWidgets('an unpaired device is asked to pair', (tester) async {
    await tester.pumpWidget(const DeckApp());
    await tester.pumpAndSettle();
    expect(
      find.text('This device is not paired yet. On the Mac, run:'),
      findsOneWidget,
    );
  });

  test('a bundle that is not https is refused', () {
    expect(
      () => AgentsConfig.fromJson({'url': 'http://10.0.0.2:7341'}),
      throwsA(isA<FormatException>()),
    );
  });
}

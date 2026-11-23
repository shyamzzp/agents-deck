// The app asks to be paired until a bundle is stored, and refuses one that is
// not a bundle. Connecting is not covered: that needs a deck to connect to.

import 'dart:io';

import 'package:agents_deck_mobile/main.dart';
import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _pathChannels = [
  MethodChannel('plugins.flutter.io/path_provider'),
  MethodChannel('plugins.flutter.io/path_provider_foundation'),
  MethodChannel('plugins.flutter.io/path_provider_macos'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('deck_test');
    // path_provider is a platform channel with no implementation under
    // flutter test. The host decides which one answers: the Apple
    // implementation asks for a directory by name, the legacy channel has a
    // method per directory, so both are answered here.
    for (final channel in _pathChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => docs.path);
    }
  });

  tearDown(() {
    for (final channel in _pathChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    docs.deleteSync(recursive: true);
  });

  testWidgets('an unpaired device is asked to pair', (tester) async {
    // Startup asks the platform for a directory and reads two files. That is
    // real I/O on the real event loop, which tester.pump cannot advance, so it
    // runs outside the fake clock.
    await tester.runAsync(() async {
      await tester.pumpWidget(const DeckApp());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.byType(PairingScreen), findsOneWidget);
  });

  test('a bundle that is not https is refused', () {
    expect(
      () => AgentsConfig.fromJson({'url': 'http://10.0.0.2:7341'}),
      throwsA(isA<FormatException>()),
    );
  });
}

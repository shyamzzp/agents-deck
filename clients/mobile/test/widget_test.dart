// The app shows the pairing screen until a bundle is stored, and refuses a
// bundle that is not one. Connecting is not covered here: that needs a deck.

import 'package:agents_deck_mobile/main.dart';
import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('an unpaired device is asked to pair', (tester) async {
    await tester.pumpWidget(const DeckApp());
    await tester.pump();
    expect(find.text('agents deck'), findsOneWidget);
    expect(
      find.text('This device is not paired yet. On the Mac, run:'),
      findsOneWidget,
    );
  });

  test('a bundle without https is refused', () {
    expect(
      () => AgentsConfig.fromJson({'url': 'http://10.0.0.2:7341'}),
      throwsA(isA<FormatException>()),
    );
  });
}

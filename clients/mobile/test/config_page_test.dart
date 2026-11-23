// The settings page lists the deck's pages and one spare. Shaping the spare
// must not add another, or the list grows with every tap.

import 'package:agents_deck_mobile/main.dart';
import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget page(List<DeckShape> shapes) => Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(820, 1180)),
      child: ConfigPage(
        shapes: shapes,
        onShape: (_, _) {},
        source: FakeAgentsSource.demo(),
      ),
    ),
  );

  int rows(WidgetTester t) =>
      t.widgetList<Text>(find.byType(Text))
          .where((w) => (w.data ?? '').startsWith('page '))
          .length;

  testWidgets('the list does not grow as pages are shaped', (tester) async {
    await tester.pumpWidget(page(const [DeckShape(5, 5)]));
    await tester.pump();
    final one = rows(tester);

    // Shaping the spare stores a second shape; the list must stay as it was.
    await tester.pumpWidget(page(const [DeckShape(5, 5), DeckShape(3, 6)]));
    await tester.pump();
    expect(rows(tester), one);

    await tester.pumpWidget(
      page(const [DeckShape(5, 5), DeckShape(3, 6), DeckShape(2, 2)]),
    );
    await tester.pump();
    expect(rows(tester), one);
  });

  testWidgets('a page with no agents on it says so', (tester) async {
    await tester.pumpWidget(page(const [DeckShape(5, 5)]));
    await tester.pump();
    expect(find.textContaining('· empty'), findsWidgets);
  });
}

// The settings page itself: a tap must move the row it belongs to and nothing
// else, and must not add pages to the list.

import 'package:agents_deck_mobile/main.dart';
import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Builds the page for [layout] and records what a tap asks for, rather than
  /// folding it in: what matters here is which row a tap belongs to.
  Future<List<String>> pump(WidgetTester tester, DeckLayout layout) async {
    final log = <String>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(820, 1180)),
          child: ConfigPage(
            layout: layout,
            source: FakeAgentsSource.demo(),
            onPage: (p, sh) => log.add('page $p -> $sh'),
            onFallback: (sh) => log.add('all -> $sh'),
          ),
        ),
      ),
    );
    await tester.pump();
    return log;
  }

  /// One row's columns stepper, so a test aims at the row it means rather than
  /// at whatever happens to be first on screen.
  Finder step(String row, String glyph) => find.descendant(
    of: find.descendant(
      of: find.byKey(Key(row)),
      matching: find.byKey(const Key('cols')),
    ),
    matching: find.text(glyph),
  );

  List<String> titles(WidgetTester t) => t
      .widgetList<Text>(find.byType(Text))
      .map((w) => w.data ?? '')
      .where((s) => s.startsWith('page '))
      .toList();

  testWidgets('a page row asks for that page alone', (tester) async {
    final log = await pump(
      tester,
      const DeckLayout(fallback: DeckShape(5, 5)),
    );
    await tester.tap(step('shape-row-page-0', '−'));
    await tester.pump();
    expect(log, ['page 0 -> 4x5'], reason: 'page 1, not every page');
  });

  testWidgets('the all-pages row asks for the default', (tester) async {
    final log = await pump(
      tester,
      const DeckLayout(fallback: DeckShape(5, 5)),
    );
    expect(find.text('all pages'), findsOneWidget);
    await tester.tap(step('shape-row-default', '−'));
    await tester.pump();
    expect(log, ['all -> 4x5']);
  });

  testWidgets('the list is the deck, not the settings', (tester) async {
    // One page, so one row, whatever has been stored.
    await pump(tester, const DeckLayout(fallback: DeckShape(5, 5)));
    expect(titles(tester), ['page 1']);

    // Overrides stored for pages the deck does not have add no rows: the old
    // list grew by one on every tap because its floor came from the settings.
    await pump(
      tester,
      const DeckLayout(fallback: DeckShape(5, 5)).
          withPage(3, const DeckShape(2, 2)).
          withPage(6, const DeckShape(3, 3)),
    );
    expect(titles(tester), ['page 1']);
  });

  testWidgets('a page with its own grid says so', (tester) async {
    await pump(tester, const DeckLayout(fallback: DeckShape(5, 5)));
    expect(find.text('as above'), findsOneWidget);

    await pump(
      tester,
      const DeckLayout(
        fallback: DeckShape(5, 5),
      ).withPage(0, const DeckShape(3, 3)),
    );
    expect(find.text('its own'), findsOneWidget);
  });
}

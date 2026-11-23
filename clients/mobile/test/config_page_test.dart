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
            onAttention: (sh) => log.add('needs you -> $sh'),
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

  /// The note inside one row, so two rows reading "as above" cannot be
  /// mistaken for each other.
  Finder noteIn(String row, String text) =>
      find.descendant(of: find.byKey(Key(row)), matching: find.text(text));

  testWidgets('the deck list holds deck pages and nothing else', (
    tester,
  ) async {
    await pump(tester, const DeckLayout(fallback: DeckShape(5, 5)));

    // The order of every row title on the screen. "needs you" must not be the
    // first thing under the deck's pages, which is what it was.
    final rows = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where(
          (t) =>
              t == 'all pages' ||
              t == '\u201cneeds you\u201d page' ||
              t.startsWith('page '),
        )
        .toList();
    expect(rows.first, 'all pages');
    expect(
      rows.indexOf('page 1') < rows.lastIndexOf('\u201cneeds you\u201d page'),
      isTrue,
      reason: 'the deck pages come before the needs you page',
    );

    // The heading above the page rows names the deck, not the screens.
    expect(find.text('the deck: one page'), findsOneWidget);
    expect(find.text('the pages you can swipe to'), findsNothing);
  });

  testWidgets('a page with its own grid says so', (tester) async {
    await pump(tester, const DeckLayout(fallback: DeckShape(5, 5)));
    expect(noteIn('shape-row-page-0', 'as above'), findsOneWidget);

    await pump(
      tester,
      const DeckLayout(
        fallback: DeckShape(5, 5),
      ).withPage(0, const DeckShape(3, 3)),
    );
    expect(noteIn('shape-row-page-0', 'its own'), findsOneWidget);
  });

  group('the Needs you screen, set on its own', () {
    testWidgets('it has a row, and follows the default until set', (
      tester,
    ) async {
      await pump(tester, const DeckLayout(fallback: DeckShape(5, 5)));
      // Its heading and its row share the words, so match the row.
      expect(find.byKey(const Key('shape-row-attention')), findsOneWidget);
      expect(noteIn('shape-row-attention', 'as above'), findsOneWidget);
    });

    testWidgets('its row asks for it alone', (tester) async {
      final log = await pump(
        tester,
        const DeckLayout(fallback: DeckShape(5, 5)),
      );
      await tester.tap(step('shape-row-attention', '\u2212'));
      await tester.pump();
      expect(log, ['needs you -> 4x5']);
    });

    testWidgets('once set, it says it has its own', (tester) async {
      await pump(
        tester,
        const DeckLayout(
          fallback: DeckShape(5, 5),
        ).withAttention(const DeckShape(4, 4)),
      );
      expect(noteIn('shape-row-attention', 'its own'), findsOneWidget);
      expect(noteIn('shape-row-page-0', 'as above'), findsOneWidget);
    });
  });
}

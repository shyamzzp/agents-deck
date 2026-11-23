// The deck's shape, and the sequence that went wrong on the iPad:
// page 1 changed from 5x5 to 3x3, which also changed page 2 and left behind a
// page that stayed when page 1 was put back.

import 'package:agents_deck_mobile/main.dart';
import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The deck as it was: sixteen agents, slots 0..15.
  final slots = [for (var i = 0; i < 16; i++) i];
  int pagesOf(DeckLayout l) => deckPageCount(l.pageShapes, slots);

  group('a page of its own does not move the others', () {
    test('setting page 1 leaves page 2 on the default', () {
      const start = DeckLayout(fallback: DeckShape(5, 5));
      expect(start.shapeOf(0), const DeckShape(5, 5));
      expect(start.shapeOf(1), const DeckShape(5, 5));

      final after = start.withPage(0, const DeckShape(3, 3));
      expect(after.shapeOf(0), const DeckShape(3, 3), reason: 'page 1 changed');
      expect(
        after.shapeOf(1),
        const DeckShape(5, 5),
        reason: 'page 2 must not follow page 1',
      );
      expect(after.shapeOf(2), const DeckShape(5, 5));
    });

    test('the shapes handed to the deck end on the default', () {
      final l = const DeckLayout(
        fallback: DeckShape(5, 5),
      ).withPage(0, const DeckShape(3, 3));
      expect(l.pageShapes, const [DeckShape(3, 3), DeckShape(5, 5)]);
      expect(deckShapeOf(l.pageShapes, 9), const DeckShape(5, 5));
    });
  });

  group('the reported sequence, end to end', () {
    test('5x5 -> page 1 at 3x3 -> back to 5x5 leaves nothing behind', () {
      const start = DeckLayout(fallback: DeckShape(5, 5));
      expect(pagesOf(start), 1, reason: '16 agents fit one 5x5 page');

      // Page 1 alone is made smaller.
      final small = start.withPage(0, const DeckShape(3, 3));
      expect(small.shapeOf(1), const DeckShape(5, 5));
      // 9 cells on page 1 cannot hold 16 agents, so a second page is real.
      expect(pagesOf(small), 2);

      // Put page 1 back. The override must go, not merely match.
      final back = small.withPage(0, const DeckShape(5, 5));
      expect(back.perPage, isEmpty, reason: 'no override left pinned');
      expect(back.pageShapes, const [DeckShape(5, 5)]);
      expect(pagesOf(back), 1, reason: 'the extra page goes with it');
      expect(back.toJson(), start.toJson(), reason: 'back where it started');
    });

    test('changing the default does not strand an identical override', () {
      final l = const DeckLayout(
        fallback: DeckShape(5, 5),
      ).withPage(1, const DeckShape(3, 3));
      expect(l.perPage.keys, [1]);

      // The default becomes what page 2 was overridden to: it is no longer an
      // override, and must not stay pinned when the default moves again.
      final same = l.withFallback(const DeckShape(3, 3));
      expect(same.perPage, isEmpty);
      expect(same.withFallback(const DeckShape(6, 6)).shapeOf(1),
          const DeckShape(6, 6));
    });
  });

  group('the Needs you screen', () {
    test('follows the default until given its own', () {
      const l = DeckLayout(fallback: DeckShape(5, 5));
      expect(l.attention, isNull);
      expect(l.attentionShape, const DeckShape(5, 5));

      final own = l.withAttention(const DeckShape(4, 4));
      expect(own.attentionShape, const DeckShape(4, 4));
      expect(own.shapeOf(0), const DeckShape(5, 5), reason: 'the deck is not');
    });

    test('set back to the default stops being its own', () {
      final l = const DeckLayout(
        fallback: DeckShape(5, 5),
      ).withAttention(const DeckShape(4, 4));
      expect(l.withAttention(const DeckShape(5, 5)).attention, isNull);
    });

    test('a default that matches it clears it, so it is not pinned', () {
      final l = const DeckLayout(
        fallback: DeckShape(5, 5),
      ).withAttention(const DeckShape(3, 3));
      final moved = l.withFallback(const DeckShape(3, 3));
      expect(moved.attention, isNull);
      expect(
        moved.withFallback(const DeckShape(6, 6)).attentionShape,
        const DeckShape(6, 6),
      );
    });

    test('it survives a round trip, and is left out when unset', () {
      final own = const DeckLayout(
        fallback: DeckShape(5, 5),
      ).withAttention(const DeckShape(2, 6));
      expect(own.toJson()['needsYou'], [2, 6]);
      expect(DeckLayout.fromJson(own.toJson()).attention,
          const DeckShape(2, 6));
      expect(
        const DeckLayout(fallback: DeckShape(5, 5)).toJson().containsKey('needsYou'),
        isFalse,
      );
    });
  });

  group('what is stored', () {
    test('survives a round trip', () {
      final l = const DeckLayout(
        fallback: DeckShape(4, 6),
      ).withPage(2, const DeckShape(2, 3));
      final back = DeckLayout.fromJson(l.toJson());
      expect(back.fallback, l.fallback);
      expect(back.perPage, l.perPage);
    });

    test('a default with no overrides stores none', () {
      expect(
        const DeckLayout(fallback: DeckShape(3, 3)).toJson(),
        {'default': [3, 3], 'pages': <String, Object?>{}},
      );
    });

    test('nonsense is refused, not crashed on', () {
      expect(DeckLayout.fromJson(null).fallback, defaultShape);
      expect(DeckLayout.fromJson('nope').fallback, defaultShape);
      expect(DeckLayout.fromJson({'default': [99, 1]}).fallback, defaultShape);
      expect(
        DeckLayout.fromJson({
          'default': [4, 4],
          'pages': {'-1': [3, 3], 'x': [3, 3], '0': [9, 9]},
        }).perPage,
        isEmpty,
      );
    });

    test('the earlier file, whose pages were a list, is read not crashed on', () {
      // What the iPad actually holds from the previous build.
      final l = DeckLayout.fromJson({
        'pages': [
          [5, 5],
          [3, 6],
        ],
      });
      expect(l.fallback, defaultShape);
      expect(l.perPage, isEmpty, reason: 'a list is not a page map');
    });

    test('an override equal to the default is not kept', () {
      final l = DeckLayout.fromJson({
        'default': [5, 5],
        'pages': {'0': [5, 5]},
      });
      expect(l.perPage, isEmpty);
    });
  });
}

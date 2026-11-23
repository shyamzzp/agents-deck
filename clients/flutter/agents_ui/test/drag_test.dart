// Long press and drag a tile onto another cell: the deck must ask the service
// to move it.
//
// These run as iOS. The host is macOS, whose scroll physics and gesture arena
// are not the same, so a drag that works under the host's defaults proves
// nothing about an iPad or an iPhone.

import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the deck asks the service for.
class _Spy implements AgentsSource {
  _Spy(this.inner);
  final FakeAgentsSource inner;
  final moves = <String>[];

  @override
  ValueListenable<AgentsSnapshot> get snapshot => inner.snapshot;

  @override
  Future<AgentsResult> move(String agentId, int slot) {
    moves.add('$agentId -> $slot');
    return inner.move(agentId, slot);
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      Function.apply((inner as dynamic).noSuchMethod, [i]);
}

void main() {
  Future<_Spy> deck(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final spy = _Spy(FakeAgentsSource.demo());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: DeckHud.bg),
        home: Scaffold(body: AgentsApp(source: spy, animate: false)),
      ),
    );
    await tester.pump();
    return spy;
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    group('on $platform', () {
      testWidgets('a long press and drag moves the agent', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final spy = await deck(tester);

        final from = tester.getCenter(find.byType(AgentTile).first);
        final to = tester.getCenter(find.byType(AgentsEmptyTile).last);

        final g = await tester.startGesture(from);
        await tester.pump(const Duration(milliseconds: 600)); // past the hold
        // A finger moves in many small steps, which is what lets the PageView's
        // horizontal drag compete for the pointer. One jump does not.
        const steps = 20;
        for (var i = 1; i <= steps; i++) {
          await g.moveTo(Offset.lerp(from, to, i / steps)!);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await g.up();
        await tester.pumpAndSettle();

        final moves = [...spy.moves];
        debugDefaultTargetPlatformOverride = null;
        expect(moves, isNotEmpty, reason: 'the drop should ask for a move');
      });

      testWidgets('a long press that does not move asks for nothing', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        final spy = await deck(tester);

        // Held and let go on the same cell: a cell refuses its own tile, so
        // this is a no-op by design. It is what a long press alone looks like.
        final g = await tester.startGesture(
          tester.getCenter(find.byType(AgentTile).first),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await g.up();
        await tester.pumpAndSettle();

        final moves = [...spy.moves];
        debugDefaultTargetPlatformOverride = null;
        expect(moves, isEmpty);
      });
    });
  }
}

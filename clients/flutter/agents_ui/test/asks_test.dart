// The quick list: a double tap on a card's title opens it, and tapping an ask
// puts that line on the agent's queue (POST /v1/agents/{id}/prompt).

import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<FakeAgentsSource> card(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final source = FakeAgentsSource.demo();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: DeckHud.bg),
        home: Scaffold(
          body: AgentDetail(source: source, agentId: 'k3f9a2', onClose: () {}),
        ),
      ),
    );
    await tester.pump();
    return source;
  }

  Future<void> openAsks(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump();
  }

  testWidgets('a double tap on the title opens the quick list', (tester) async {
    await card(tester);
    expect(find.byKey(const Key('asks-pages')), findsNothing);
    await openAsks(tester);
    expect(find.byKey(const Key('asks-pages')), findsOneWidget);
    expect(find.text('verify changes'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('tapping an ask types it into the session', (tester) async {
    final source = await card(tester);
    await openAsks(tester);
    await tester.tap(find.byKey(const Key('ask-0')));
    await tester.pump();

    final sent = source.calls.where((c) => c.$1 == 'prompt').toList();
    expect(sent, hasLength(1));
    expect(sent.single.$2, 'k3f9a2');
    expect(sent.single.$3?['text'], agentAsks.first.text);
    // Queued, so asking while it works does not cut the turn short.
    expect(sent.single.$3?['mode'], 'queue');
    // The card says "sent" for a moment before it closes itself.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('asks-pages')), findsNothing);
  });

  testWidgets('it can be closed again without sending anything', (
    tester,
  ) async {
    final source = await card(tester);
    await openAsks(tester);
    await tester.tap(find.byKey(const Key('asks-close')));
    await tester.pump();
    expect(find.byKey(const Key('asks-pages')), findsNothing);
    expect(source.calls.where((c) => c.$1 == 'prompt'), isEmpty);
    await tester.pumpAndSettle();
  });

  test('every ask has a label and one line to say', () {
    expect(agentAsks, isNotEmpty);
    for (final a in agentAsks) {
      expect(a.label.trim(), isNotEmpty);
      expect(a.text.trim().length, greaterThan(10));
      // The API takes a single line of at most 8192 bytes.
      expect(a.text.contains('\n'), isFalse);
      expect(a.text.length, lessThanOrEqualTo(8192));
    }
  });
}

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
    expect(find.byKey(const Key('asks-grid')), findsNothing);
    await openAsks(tester);
    expect(find.byKey(const Key('asks-grid')), findsOneWidget);
    expect(find.text('verify changes'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('the grid shows every ask, and scrolls to the last', (
    tester,
  ) async {
    await card(tester);
    await openAsks(tester);
    // A grid, not a slider: more than one is on the screen at once.
    expect(find.text('verify changes'), findsOneWidget);
    expect(find.text('run the tests'), findsOneWidget);

    // The last one is reachable by scrolling, not by swiping through the rest.
    await tester.scrollUntilVisible(
      find.byKey(Key('ask-${agentAsks.length - 1}')),
      240,
      scrollable: find.descendant(
        of: find.byKey(const Key('asks-grid')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text(agentAsks.last.label), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a double tap on empty space opens it too', (tester) async {
    await card(tester);
    expect(find.byKey(const Key('asks-grid')), findsNothing);
    // The detector sits under the content, so an empty part of the card
    // reaches it while a button over it does not.
    // The gap the Spacer leaves between the card's text and its buttons is
    // empty by construction, so a tap there reaches the layer beneath.
    final gap = tester.getCenter(find.byType(Spacer).first);
    await tester.tapAt(gap);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(gap);
    await tester.pump();
    expect(find.byKey(const Key('asks-grid')), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('the card\'s own buttons still answer a single tap', (
    tester,
  ) async {
    final source = await card(tester);
    // focus terminal is the running card's first button; one tap must act,
    // not wait out a double-tap timeout.
    await tester.tap(find.text('focus terminal'));
    await tester.pump();
    expect(source.calls.where((c) => c.$1 == 'focus'), hasLength(1));
    expect(find.byKey(const Key('asks-grid')), findsNothing);
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
    // "now": typed in and entered, not queued behind the current turn.
    expect(sent.single.$3?['mode'], 'now');
    // The card says "sent" for a moment before it closes itself.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('asks-grid')), findsNothing);
  });

  testWidgets('it can be closed again without sending anything', (
    tester,
  ) async {
    final source = await card(tester);
    await openAsks(tester);
    await tester.tap(find.byKey(const Key('asks-close')));
    await tester.pump();
    expect(find.byKey(const Key('asks-grid')), findsNothing);
    expect(source.calls.where((c) => c.$1 == 'prompt'), isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('a watched terminal session can be told', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // A session started by hand in a terminal and added to the deck. The
    // service types into iTerm through iTerm, so the card must offer the asks.
    final json = FakeAgentsSource.demo().toJson();
    final a = (json['agents'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((x) => x['id'] == 'd0cs1t');
    a['external'] = true;
    a['app'] = '';
    a['tool'] = 'claude';
    final source = FakeAgentsSource.demo()..load(json);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: DeckHud.bg),
        home: Scaffold(
          body: AgentDetail(source: source, agentId: 'd0cs1t', onClose: () {}),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump();

    expect(find.byKey(const Key('asks-grid')), findsOneWidget);
    expect(find.byKey(const Key('asks-refused')), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('an agent inside another app says it cannot be told', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // docs-site in the demo fixture is a watched session.
    final json = FakeAgentsSource.demo().toJson();
    final a = (json['agents'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((x) => x['id'] == 'd0cs1t');
    a['external'] = true;
    a['app'] = 'orca';
    final source = FakeAgentsSource.demo()..load(json);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: DeckHud.bg),
        home: Scaffold(
          body: AgentDetail(source: source, agentId: 'd0cs1t', onClose: () {}),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump();

    expect(find.byKey(const Key('asks-refused')), findsOneWidget);
    expect(find.byKey(const Key('asks-grid')), findsNothing);
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

// The tasks on an agent's card: they sit under the last prompt, in the cells
// of the page the agent was picked from, and tapping one types that line into
// the session (POST /v1/agents/{id}/prompt). A double tap on the title or on
// an empty part of the card scrolls down to them.

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

  /// The tasks sit at the bottom of the card, so a test that taps one scrolls
  /// the card's own scroller to it first, as a thumb would.
  Future<void> scrollToAsks(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('ask-0')),
      300,
      // The grid inside is a Scrollable too (it just never scrolls), so the
      // card's own one is the first of the two.
      scrollable: find
          .descendant(
            of: find.byKey(const Key('agent-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
  }

  Future<void> openAsks(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('agent-title')));
    await tester.pump();
  }

  testWidgets('the tasks are on the card itself', (tester) async {
    await card(tester);
    expect(find.byKey(const Key('asks-grid')), findsOneWidget);
    expect(find.text('verify-changes'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a double tap on the title brings them into view', (
    tester,
  ) async {
    await card(tester);
    await openAsks(tester);
    expect(find.byKey(const Key('asks-grid')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('the board shows every ask at once', (tester) async {
    await card(tester);
    await openAsks(tester);
    // A board, not a slider and no longer a scroller: the tasks sit in the
    // cells of the page the agent was picked from, all of them on the screen.
    for (final ask in agentAsks) {
      expect(find.text(ask.label), findsOneWidget, reason: ask.label);
    }
    expect(find.byKey(Key('ask-${agentAsks.length - 1}')), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a double tap on empty space reaches them too', (tester) async {
    await card(tester);
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
    expect(tester.takeException(), isNull);
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
    await tester.pumpAndSettle();
  });

  testWidgets('tapping an ask types it into the session', (tester) async {
    final source = await card(tester);
    await scrollToAsks(tester);
    await tester.tap(find.byKey(const Key('ask-0')));
    await tester.pump();

    final sent = source.calls.where((c) => c.$1 == 'prompt').toList();
    expect(sent, hasLength(1));
    expect(sent.single.$2, 'k3f9a2');
    expect(sent.single.$3?['text'], agentAsks.first.text);
    // Queued, so asking while it works does not cut the turn short.
    // "now": typed in and entered, not queued behind the current turn.
    expect(sent.single.$3?['mode'], 'now');
    // The tile says "sent" for a moment, then goes back to its name.
    expect(find.text('sent'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('sent'), findsNothing);
    expect(find.text(agentAsks.first.label), findsOneWidget);
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

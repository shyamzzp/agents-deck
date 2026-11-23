// Changing a page's shape has to change the page.

import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a new shape redraws the deck', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final source = FakeAgentsSource.demo();

    Widget app(List<DeckShape> shapes) => MaterialApp(
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: DeckHud.bg),
      home: Scaffold(
        body: AgentsApp(source: source, animate: false, pageShapes: shapes),
      ),
    );

    await tester.pumpWidget(app(const [DeckShape(4, 4)]));
    await tester.pump();
    final at4 = tester.widgetList(find.byType(AgentsEmptyTile)).length;

    await tester.pumpWidget(app(const [DeckShape(5, 5)]));
    await tester.pump();
    final at5 = tester.widgetList(find.byType(AgentsEmptyTile)).length;

    expect(at5, greaterThan(at4), reason: '5x5 has 9 more cells than 4x4');
  });
}

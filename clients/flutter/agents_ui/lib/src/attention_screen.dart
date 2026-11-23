import 'package:flutter/widgets.dart';

import 'agents_app.dart' show AgentsEmptyTile;
import 'agents_model.dart';
import 'attention.dart';
import 'widgets.dart';

/// The "Needs you" screen: one page that looks exactly like a page of the
/// deck (same grid, same tiles, same empty cells), holding only the agents
/// that need you, each in the spot the service gave it ([NeedsYou]): spot n
/// in cell n. Only its mark in the page bars tells it apart.
///
/// The grid holds [needsYouSpots] spots, which the service fixes, while the
/// host picks the shape it draws them in. The two need not agree: a shape with
/// more cells leaves the rest free, and one with fewer packs the spots in
/// order ([NeedsYou.packed]) so nothing falls off the bottom.
class AttentionScreen extends StatelessWidget {
  const AttentionScreen({
    super.key,
    required this.needsYou,
    required this.tile,
    this.columns = DeckGrid.defaultColumns,
    this.rows = DeckGrid.defaultRows,
  });

  final NeedsYou needsYou;

  /// The screen's shape, so it matches the deck the host draws.
  final int columns;
  final int rows;

  /// The deck's own tile for an agent (same look, same tap).
  final Widget Function(Agent agent) tile;

  /// Exactly as many cells as the shape has, whatever the service's spot
  /// count: a Column of more rows than it was measured for overflows.
  List<Widget> _cells() {
    final room = columns * rows;
    if (room < needsYouSpots) {
      final packed = needsYou.packed(room);
      return [
        for (var i = 0; i < room; i++)
          if (i < packed.length)
            tile(packed[i])
          else
            const AgentsEmptyTile(key: Key('attention-spot-empty')),
      ];
    }
    return [
      for (var i = 0; i < room; i++)
        if (i < needsYou.spots.length && needsYou.spots[i] != null)
          tile(needsYou.spots[i]!)
        else
          const AgentsEmptyTile(key: Key('attention-spot-empty')),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('attention-screen'),
      child: DeckGrid(
        square: false,
        columns: columns,
        rows: rows,
        cells: _cells(),
      ),
    );
  }
}

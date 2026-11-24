import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'theme.dart';

/// A tap target that rebuilds with `pressed` while a finger or the mouse is
/// down, for the deck's ink-invert press feedback.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.behavior = HitTestBehavior.opaque,
    this.onLongPress,
  });

  final VoidCallback? onTap;

  /// Held rather than tapped; null leaves the gesture to whatever is above.
  final VoidCallback? onLongPress;
  final Widget Function(BuildContext context, bool pressed) builder;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  var _down = false;

  void _press(bool down) {
    if (down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final tap = widget.onTap;
    if (tap == null && widget.onLongPress == null) {
      return widget.builder(context, false);
    }
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => _press(true),
      onTapUp: (_) => _press(false),
      onTapCancel: () => _press(false),
      onTap: tap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _press(false);
              widget.onLongPress!();
            },
      child: widget.builder(context, _down),
    );
  }
}

/// A meter drawn as a row of thin ticks with a solid bar over the filled
/// part (context used, and the like).
class TickBar extends StatelessWidget {
  const TickBar({
    super.key,
    required this.value,
    required this.color,
    this.height = 14,
  });

  /// 0..1.
  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: CustomPaint(
      size: Size.infinite,
      painter: _TicksPainter(value.clamp(0.0, 1.0), color),
    ),
  );
}

class _TicksPainter extends CustomPainter {
  _TicksPainter(this.value, this.color);

  final double value;
  final Color color;

  static const _pitch = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final thin = Paint()
      ..color = color
      ..strokeWidth = 1.6;
    for (var x = 0.0; x < size.width; x += _pitch) {
      canvas.drawLine(Offset(x, mid - 3.5), Offset(x, mid + 3.5), thin);
    }
    if (value <= 0) return;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width * value, mid),
      Paint()
        ..color = color
        ..strokeWidth = 7,
    );
  }

  @override
  bool shouldRepaint(_TicksPainter old) =>
      old.value != value || old.color != color;
}

/// HH:MM, redrawn only when the minute changes.
class HudClock extends StatefulWidget {
  const HudClock({super.key, this.color, this.size = 24});

  final Color? color;
  final double size;

  @override
  State<HudClock> createState() => _HudClockState();
}

class _HudClockState extends State<HudClock> {
  late DateTime _shown = DateTime.now();
  late final Timer _timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final now = DateTime.now();
    if (now.minute != _shown.minute || now.hour != _shown.hour) {
      setState(() => _shown = now);
    }
  });

  @override
  void initState() {
    super.initState();
    _timer; // start ticking
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int v) => v.toString().padLeft(2, '0');
    return RepaintBoundary(
      child: Text(
        '${two(_shown.hour)}:${two(_shown.minute)}',
        style: DeckHud.rm(widget.size, widget.color ?? DeckHud.ink),
      ),
    );
  }
}

/// The deck's 4×4 board: square cells with an 8 px gap, as large as the
/// space allows, centred. With [square] false the cells fill the space
/// instead (a little shorter than wide when room is needed below the grid).
/// How many cells a page of the deck is drawn in. The desk panel and the
/// boards draw 4 x 4, which is also how the service numbers slots, so that is
/// the default everywhere; a host with more room can ask for more, and pages
/// need not all be the same shape.
class DeckShape {
  const DeckShape(this.columns, this.rows)
    : assert(columns > 0 && rows > 0, 'a page needs at least one cell');

  final int columns;
  final int rows;

  int get cells => columns * rows;

  /// This shape's rows, or more where something taller has to fit in it.
  int rowsFor(int needed) => needed > rows ? needed : rows;

  static const panel = DeckShape(DeckGrid.defaultColumns, DeckGrid.defaultRows);

  @override
  bool operator ==(Object other) =>
      other is DeckShape && other.columns == columns && other.rows == rows;

  @override
  int get hashCode => Object.hash(columns, rows);

  @override
  String toString() => '${columns}x$rows';
}

/// The shape of page [i] of a deck shaped by [shapes], the last entry
/// standing in for every page beyond it.
DeckShape deckShapeOf(List<DeckShape> shapes, int i) =>
    shapes[math.min(i < 0 ? 0 : i, shapes.length - 1)];

/// Which page of a deck shaped by [shapes] holds [slot]. Pages hold as many
/// agents as they have cells, so this walks the shapes rather than dividing.
int deckPageOf(List<DeckShape> shapes, int slot) {
  var page = 0, end = deckShapeOf(shapes, 0).cells;
  while (slot >= end) {
    page++;
    end += deckShapeOf(shapes, page).cells;
  }
  return page;
}

/// Enough pages for every slot in [slots], and never fewer than one.
int deckPageCount(List<DeckShape> shapes, Iterable<int> slots) =>
    slots.isEmpty ? 1 : deckPageOf(shapes, slots.reduce(math.max)) + 1;

/// Marks a subtree as drawn in little space -- a phone in portrait -- so the
/// house controls can draw shorter without every one of them measuring.
class DeckCompact extends InheritedWidget {
  const DeckCompact({super.key, required this.compact, required super.child});

  final bool compact;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeckCompact>()?.compact ??
      false;

  @override
  bool updateShouldNotify(DeckCompact old) => old.compact != compact;
}

/// Rebuilds once a second, so a label holding elapsed time counts up without
/// the whole deck being rebuilt for it.
class Ticking extends StatefulWidget {
  const Ticking({
    super.key,
    required this.builder,
    this.every = const Duration(seconds: 1),
  });

  final WidgetBuilder builder;
  final Duration every;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(widget.every, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class DeckGrid extends StatelessWidget {
  const DeckGrid({
    super.key,
    required this.cells,
    this.square = true,
    this.columns = defaultColumns,
    this.rows = defaultRows,
  });

  final List<Widget> cells;
  final bool square;

  /// How the page is laid out. The desk panel and the boards draw 4x4 and the
  /// "Needs you" grid is 4x4 in the protocol, so that stays the default; a
  /// host with more room (a tablet) can ask for more.
  final int columns;
  final int rows;

  static const defaultColumns = 4, defaultRows = 4;
  static const gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = math.max(0.0, (box.maxWidth - gap * (columns - 1)) / columns);
        final h = math.max(0.0, (box.maxHeight - gap * (rows - 1)) / rows);
        final side = math.min(w, h);
        final cellW = square ? side : w, cellH = square ? side : h;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var r = 0; r * columns < cells.length; r++) ...[
                if (r > 0) const SizedBox(height: gap),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var c = 0; c < columns; c++) ...[
                      if (c > 0) const SizedBox(width: gap),
                      SizedBox(
                        width: cellW,
                        height: cellH,
                        child: r * columns + c < cells.length
                            ? cells[r * columns + c]
                            : null,
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Opens an agent's card from its tile. The desk panel passes its own
/// tile-to-card morph (with the shell's back gesture); [CardMorph] is the
/// built-in one.
typedef AgentCardOpener =
    void Function(
      BuildContext tileContext,
      GlobalKey tileKey, {
      required String id,
      required Color fill,
      required Widget Function(VoidCallback close) builder,
    });

/// The built-in card opener: the card grows out of its tile to fill this
/// widget, and shrinks back into it on close.
class CardMorph extends StatefulWidget {
  const CardMorph({super.key, required this.child});

  final Widget child;

  static CardMorphState? of(BuildContext context) =>
      context.findAncestorStateOfType<CardMorphState>();

  /// An [AgentCardOpener] that uses the nearest [CardMorph].
  static void open(
    BuildContext tileContext,
    GlobalKey tileKey, {
    required String id,
    required Color fill,
    required Widget Function(VoidCallback close) builder,
  }) => of(tileContext)?.open(tileKey, fill: fill, builder: builder);

  @override
  State<CardMorph> createState() => CardMorphState();
}

class CardMorphState extends State<CardMorph>
    with SingleTickerProviderStateMixin {
  // Created in initState, not lazily: a lazy controller would be built for
  // the first time inside dispose() when no card was ever opened.
  late final AnimationController _t;
  final _area = GlobalKey();
  // The open card takes keyboard focus (Esc closes it); whatever had it
  // before (the deck, for its arrow keys) gets it back on close.
  final _cardFocus = FocusNode(debugLabel: 'card');
  FocusNode? _focusBefore;
  Rect? _from;
  Color _fill = DeckHud.bg;
  Widget Function(VoidCallback close)? _card;

  bool get isOpen => _card != null;

  @override
  void initState() {
    super.initState();
    _t = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  void open(
    GlobalKey tileKey, {
    required Color fill,
    required Widget Function(VoidCallback close) builder,
  }) {
    if (isOpen) return;
    final tile = tileKey.currentContext?.findRenderObject() as RenderBox?;
    final area = _area.currentContext?.findRenderObject() as RenderBox?;
    if (tile != null && area != null && tile.hasSize) {
      final topLeft = tile.localToGlobal(Offset.zero, ancestor: area);
      _from = topLeft & tile.size;
    } else {
      _from = null;
    }
    setState(() {
      _fill = fill;
      _card = builder;
    });
    _focusBefore = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && isOpen) _cardFocus.requestFocus();
    });
    _t.forward(from: 0);
  }

  void close() {
    final before = _focusBefore;
    _focusBefore = null;
    if (before != null && before.context != null) before.requestFocus();
    _t.reverse().whenComplete(() {
      if (mounted) setState(() => _card = null);
    });
  }

  @override
  void dispose() {
    _t.dispose();
    _cardFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    return LayoutBuilder(
      key: _area,
      builder: (context, box) {
        final full = Offset.zero & Size(box.maxWidth, box.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (card != null)
              AnimatedBuilder(
                animation: _t,
                builder: (context, child) {
                  if (_t.isDismissed) return const SizedBox.shrink(); // closed
                  final v = Curves.easeOutCubic.transform(_t.value);
                  final r = Rect.lerp(_from ?? full.deflate(40), full, v)!;
                  return Positioned.fromRect(
                    rect: r,
                    child: ClipRRect(
                      borderRadius: BorderRadius.zero,
                      child: ColoredBox(
                        color: _fill,
                        child: Opacity(
                          opacity: ((v - 0.35) / 0.65).clamp(0.0, 1.0),
                          child: child,
                        ),
                      ),
                    ),
                  );
                },
                // Esc closes the card (keyboard hosts: the menu bar app).
                child: Focus(
                  focusNode: _cardFocus,
                  onKeyEvent: (_, e) {
                    if (e is KeyDownEvent &&
                        e.logicalKey == LogicalKeyboardKey.escape) {
                      close();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: SizedBox.fromSize(
                    size: full.size,
                    child: FittedBox(
                      fit: BoxFit.cover,
                      alignment: Alignment.topLeft,
                      child: SizedBox.fromSize(
                        size: full.size,
                        child: card(close),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

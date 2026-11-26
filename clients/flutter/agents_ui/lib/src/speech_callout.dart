// Speaking to an agent without leaving the deck.
//
// Holding an agent on the "Needs you" screen opens the phone's ear, and what
// is said is typed into a callout beside that very tile: the deck stays where
// it is, the tile keeps its place, and the words grow in a bubble pointing at
// the agent they are for. Letting go stops the listening and puts two
// buttons in the bubble's bottom corner: a tick to send it to the agent's
// terminal, a cross to throw it away.
//
// The bubble goes where there is room. An agent on the left of the screen
// gets its bubble on the right and the other way round; where neither side
// can hold it (a phone, a long sentence) it goes under the tile, or over it
// when the tile is near the bottom. It is measured before it is placed, so
// nothing is ever drawn off the screen and nothing jumps as it grows.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'theme.dart';

/// The phone's ear, as the deck needs it. The host (which owns the platform
/// channels) implements it; a deck without one does nothing on a hold.
abstract class DeckEar {
  /// Opens the microphone. What is heard arrives on [heard].
  Future<void> start();

  /// Closes it and keeps what was said.
  Future<void> stop();

  /// Closes it and throws away what was said.
  Future<void> cancel();

  /// Everything heard in this turn of speaking, growing as it is said.
  ValueListenable<String> get heard;

  /// Why nothing is being heard, when something went wrong (the microphone
  /// is off for this app, speech recognition is not allowed): null while all
  /// is well.
  ValueListenable<String?> get problem;
}

/// How wide a bubble may be drawn, and how far it keeps from the edges.
const _bubbleMax = 320.0;
const _bubbleMin = 160.0;
const _edge = 10.0;
const _gap = 10.0; // between the tile and the bubble
const _pad = EdgeInsets.fromLTRB(12, 10, 12, 10);

/// Which way the bubble's tail points, which is also which side of the tile
/// it sits on.
enum CalloutSide { right, left, below, above }

/// Where the bubble goes and how big it is.
typedef CalloutLayout = (Offset at, CalloutSide side, Size size);

/// Lays the bubble out for [text] beside [tile] on a screen of [screen].
///
/// The side the tile is on decides where it is tried first: an agent on the
/// left of the screen speaks to the right, as a speech bubble does. The
/// bubble takes the width that side has, down to [_bubbleMin]; where even
/// that will not fit (a phone, a tile in the middle) it goes under the tile,
/// or over it when the tile sits low, at the width of the screen. It is
/// measured before it is placed, so nothing is drawn off the screen and
/// nothing jumps as the words arrive.
CalloutLayout calloutLayout(
  Rect tile,
  Size screen,
  String text, {
  required bool deciding,
}) {
  final roomRight = screen.width - tile.right - _gap - _edge;
  final roomLeft = tile.left - _gap - _edge;
  final full = (screen.width - 2 * _edge).clamp(_bubbleMin, _bubbleMax);
  double top(Size size) => (tile.center.dy - size.height / 2).clamp(
    _edge,
    (screen.height - size.height - _edge).clamp(_edge, double.infinity),
  );
  // The far side of the screen from the tile, then the near one.
  final sides = tile.center.dx > screen.width / 2
      ? [(CalloutSide.left, roomLeft), (CalloutSide.right, roomRight)]
      : [(CalloutSide.right, roomRight), (CalloutSide.left, roomLeft)];
  for (final (side, room) in sides) {
    if (room < _bubbleMin) continue;
    final size = _measure(text, room.clamp(_bubbleMin, _bubbleMax), deciding);
    final at = side == CalloutSide.right
        ? Offset(tile.right + _gap, top(size))
        : Offset(tile.left - _gap - size.width, top(size));
    return (at, side, size);
  }
  // Neither side holds it: under the tile, or over it when the tile is low.
  final size = _measure(text, full, deciding);
  final left = (tile.center.dx - size.width / 2).clamp(
    _edge,
    (screen.width - size.width - _edge).clamp(_edge, double.infinity),
  );
  final under = tile.bottom + _gap;
  if (under + size.height + _edge <= screen.height) {
    return (Offset(left, under), CalloutSide.below, size);
  }
  final over = tile.top - _gap - size.height;
  if (over >= _edge) return (Offset(left, over), CalloutSide.above, size);
  return (
    Offset(
      left,
      (screen.height - size.height - _edge).clamp(_edge, double.infinity),
    ),
    CalloutSide.below,
    size,
  );
}

/// How much room [text] takes in a bubble at most [room] wide.
Size _measure(String text, double room, bool deciding) {
  final style = DeckHud.rm(15, DeckHud.ink).copyWith(height: 1.35);
  final painter = TextPainter(
    text: TextSpan(text: text.isEmpty ? 'listening\u2026' : text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 12,
  )..layout(maxWidth: room - _pad.horizontal);
  return Size(
    (painter.width + _pad.horizontal).clamp(_bubbleMin, room),
    painter.height + _pad.vertical + (deciding ? 40 : 0),
  );
}

/// The bubble itself: the words so far, and, once the finger is lifted, a
/// tick and a cross in its bottom corner.
class SpeechCallout extends StatelessWidget {
  const SpeechCallout({
    super.key,
    required this.text,
    required this.side,
    required this.size,
    required this.deciding,
    required this.onSend,
    required this.onDiscard,
    this.problem,
  });

  /// What has been heard so far ("" before the first word).
  final String text;
  final CalloutSide side;
  final Size size;

  /// The finger has been lifted: the two buttons are shown.
  final bool deciding;
  final VoidCallback onSend;
  final VoidCallback onDiscard;

  /// Shown instead of the words when the phone could not listen.
  final String? problem;

  @override
  Widget build(BuildContext context) {
    final said = problem ?? (text.isEmpty ? 'listening…' : text);
    final dim = problem != null || text.isEmpty;
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: DeckHud.panel,
                border: Border.all(color: DeckHud.ink, width: 2),
              ),
              child: Padding(
                padding: _pad,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    said,
                    maxLines: 12,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.rm(
                      15,
                      dim ? DeckHud.dim : DeckHud.ink,
                    ).copyWith(height: 1.35),
                  ),
                ),
              ),
            ),
          ),
          // The tail: a square nub on the side the tile is, in the deck's
          // pixel style rather than a drawn triangle.
          Align(
            alignment: switch (side) {
              CalloutSide.right => Alignment.centerLeft,
              CalloutSide.left => Alignment.centerRight,
              CalloutSide.below => Alignment.topCenter,
              CalloutSide.above => Alignment.bottomCenter,
            },
            child: Transform.translate(
              offset: switch (side) {
                CalloutSide.right => const Offset(-6, 0),
                CalloutSide.left => const Offset(6, 0),
                CalloutSide.below => const Offset(0, -6),
                CalloutSide.above => const Offset(0, 6),
              },
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: DeckHud.panel,
                  border: Border.all(color: DeckHud.ink, width: 2),
                ),
              ),
            ),
          ),
          if (deciding)
            Positioned(
              right: 8,
              bottom: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CalloutButton(
                    key: const Key('callout-discard'),
                    glyph: _Glyph.cross,
                    color: DeckHud.bad,
                    onTap: onDiscard,
                  ),
                  const SizedBox(width: 8),
                  _CalloutButton(
                    key: const Key('callout-send'),
                    glyph: _Glyph.tick,
                    color: DeckHud.ok,
                    onTap: onSend,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

enum _Glyph { tick, cross }

/// One of the two answers: drawn, not written, so it reads at a glance.
class _CalloutButton extends StatelessWidget {
  const _CalloutButton({
    super.key,
    required this.glyph,
    required this.color,
    required this.onTap,
  });

  final _Glyph glyph;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(border: Border.all(color: color, width: 2)),
      child: CustomPaint(painter: _GlyphPainter(glyph, color)),
    ),
  );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter;
    final c = size.center(Offset.zero);
    switch (glyph) {
      case _Glyph.tick:
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - 7, c.dy)
            ..lineTo(c.dx - 2, c.dy + 5)
            ..lineTo(c.dx + 7, c.dy - 5),
          p,
        );
      case _Glyph.cross:
        canvas
          ..drawLine(Offset(c.dx - 6, c.dy - 6), Offset(c.dx + 6, c.dy + 6), p)
          ..drawLine(Offset(c.dx + 6, c.dy - 6), Offset(c.dx - 6, c.dy + 6), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}

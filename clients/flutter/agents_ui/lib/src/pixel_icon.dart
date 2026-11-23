// One pixel icon, drawn in a colour of the theme rather than the brand's own.
//
// The data is in pixel_icons.dart, generated from the icon set's 32 x 32
// one-colour SVGs: a flat list of x, y, width triples. Drawing it is one pass
// of rectangles snapped to whole device pixels, so it stays crisp at any size
// the grid is scaled to, as the critters do.

import 'package:flutter/widgets.dart';

import 'pixel_icons.dart';

class PixelIcon extends StatelessWidget {
  const PixelIcon({
    super.key,
    required this.name,
    required this.color,
    this.size = 24,
  });

  /// A key of [pixelIcons]; an unknown one draws nothing, which is what a
  /// task with no icon of its own should look like.
  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final runs = pixelIcons[name];
    if (runs == null) return SizedBox.square(dimension: size);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _PixelPainter(runs, color)),
    );
  }
}

class _PixelPainter extends CustomPainter {
  _PixelPainter(this.runs, this.color);

  final List<int> runs;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / pixelIconGrid;
    if (unit <= 0) return;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    for (var i = 0; i + 2 < runs.length; i += 3) {
      canvas.drawRect(
        Rect.fromLTWH(
          runs[i] * unit,
          runs[i + 1] * unit,
          runs[i + 2] * unit,
          unit,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PixelPainter old) =>
      old.color != color || !identical(old.runs, runs);
}

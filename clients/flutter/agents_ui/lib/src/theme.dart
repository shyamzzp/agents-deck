import 'package:flutter/widgets.dart';

import 'theme_catalogue.dart';

/// The deck's design tokens: near-black surfaces, warm ink, one accent, and
/// two monospace faces (Share Tech Mono for labels, Roboto Mono for values).
abstract final class DeckHud {
  // Not const: a chosen iTerm2 colour scheme replaces these at startup, and
  // again when one is picked. Everything that draws reads them through
  // DeckHud, so a rebuild is all that a change needs.
  static Color bg = stockBg;
  static Color panel = stockPanel;
  static Color ink = stockInk;
  static Color dim = stockDim;
  static Color accent = stockAccent;

  /// The colours a theme brings besides those four: the three tools' own, and
  /// the two that mean "went well" and "went wrong". The deck draws tiles and
  /// tasks with them, so a scheme colours more than the text.
  static Color toolClaude = stockToolClaude;
  static Color toolCodex = stockToolCodex;
  static Color toolGemini = stockToolGemini;
  static Color ok = stockOk;
  static Color bad = stockBad;

  /// The deck as it has always looked, kept to return to.
  static const stockBg = Color(0xFF0A0A0A);
  static const stockPanel = Color(0xFF141412);
  static const stockInk = Color(0xFFE8E4DC);
  static const stockDim = Color(0xFF7A776F);
  static const stockAccent = Color(0xFFFF4D00);
  static const stockToolClaude = Color(0xFFC98B6B);
  static const stockToolCodex = Color(0xFF4FB3A6);
  static const stockToolGemini = Color(0xFF6F8FD8);
  static const stockOk = Color(0xFF6FD69A);
  static const stockBad = Color(0xFFF2766B);

  /// Paints the deck in [theme]; a null theme restores the stock colours.
  static void apply(DeckTheme? theme) {
    bg = theme?.bg ?? stockBg;
    panel = theme?.panel ?? stockPanel;
    ink = theme?.ink ?? stockInk;
    dim = theme?.dim ?? stockDim;
    accent = theme?.accent ?? stockAccent;
    toolClaude = theme?.toolClaude ?? stockToolClaude;
    toolCodex = theme?.toolCodex ?? stockToolCodex;
    toolGemini = theme?.toolGemini ?? stockToolGemini;
    ok = theme?.ok ?? stockOk;
    bad = theme?.bad ?? stockBad;
  }

  /// Where the font families come from. This package bundles both faces; an
  /// app that registers the same families itself (the desk panel) sets this
  /// to null so text resolves to its own fonts.
  static String? fontPackage = 'agents_deck_ui';

  /// Values and headings: Roboto Mono (variable weight).
  static TextStyle rm(
    double size,
    Color color, {
    double weight = 400,
    double? spacing,
  }) => TextStyle(
    fontFamily: 'RobotoMono',
    package: fontPackage,
    fontSize: size,
    color: color,
    height: 1.0,
    letterSpacing: spacing,
    fontVariations: [FontVariation('wght', weight)],
  );

  /// Labels and status lines: Share Tech Mono, slightly tracked.
  static TextStyle mono({double size = 13, Color? color}) => TextStyle(
    fontFamily: 'ShareTechMono',
    package: fontPackage,
    fontSize: size,
    color: color ?? ink,
    letterSpacing: 0.5,
  );
}

// What the deck feels like: the taps the phone gives back.
//
// One place decides whether a buzz happens at all, how hard it is, which
// kinds of moment are worth one, and the shape of the one that is played.
// Everything that wants to buzz asks here rather than calling the platform,
// so a person can turn the lot off in Settings and nothing has to be hunted
// down.
//
// The deck is a board you prod with a thumb, often without looking at it: a
// tap that answers is worth feeling, and a long press that picks a card up is
// worth feeling more.

import 'dart:async';

import 'package:flutter/services.dart';

/// The kinds of moment that can buzz. Each is switched on or off and shaped
/// on its own, so someone who wants only the heavy ones can have that.
enum HapticWhen {
  /// A tile, a button, a row: something answered a tap.
  tap,

  /// A long press that did something: a card picked up, a task's dialog.
  hold,

  /// A prompt or a task went to the agent.
  sent,

  /// Something would not go: a failed send, a refused action.
  problem,

  /// A page of the deck went by under a finger.
  page,

  /// An agent started needing you.
  needsYou,
}

/// How hard a buzz is. The platform gives three weights and a selection
/// click; these are those, named for what they feel like.
enum HapticStrength { soft, medium, hard }

/// The shape of one buzz: how many pulses, and how far apart.
enum HapticPattern {
  /// One pulse.
  single,

  /// Two, close together.
  double,

  /// Three, close together.
  triple,

  /// Two, the second softer: something arrived and settled.
  settle,
}

/// Which pulses a pattern plays, as delays from the start.
const _patternBeats = <HapticPattern, List<int>>{
  HapticPattern.single: [0],
  HapticPattern.double: [0, 90],
  HapticPattern.triple: [0, 80, 160],
  HapticPattern.settle: [0, 140],
};

/// The deck's haptics, as a person has set them.
class HapticSettings {
  const HapticSettings({
    this.on = false,
    this.strength = HapticStrength.medium,
    this.kinds = const {
      HapticWhen.tap,
      HapticWhen.hold,
      HapticWhen.sent,
      HapticWhen.problem,
      HapticWhen.needsYou,
    },
    this.patterns = const {},
  });

  /// Off means nothing buzzes, whatever the rest of this says.
  ///
  /// Off is the default, and the host switches it on: a Mac has nothing to
  /// buzz with, and a package that buzzed by itself would also leave the
  /// timers of a two-pulse pattern behind in anyone's tests. The phone turns
  /// them on as it reads its settings.
  final bool on;

  /// How hard every buzz is.
  final HapticStrength strength;

  /// Which kinds of moment buzz at all. A page turn is left out by default:
  /// a deck of eight pages would buzz eight times under one thumb.
  final Set<HapticWhen> kinds;

  /// The shape of a kind's buzz, where it is not the single pulse.
  final Map<HapticWhen, HapticPattern> patterns;

  HapticPattern patternOf(HapticWhen when) =>
      patterns[when] ?? defaultPatterns[when] ?? HapticPattern.single;

  /// What each kind feels like until someone changes it.
  static const defaultPatterns = <HapticWhen, HapticPattern>{
    HapticWhen.tap: HapticPattern.single,
    HapticWhen.hold: HapticPattern.single,
    HapticWhen.sent: HapticPattern.double,
    HapticWhen.problem: HapticPattern.triple,
    HapticWhen.page: HapticPattern.single,
    HapticWhen.needsYou: HapticPattern.settle,
  };

  HapticSettings copyWith({
    bool? on,
    HapticStrength? strength,
    Set<HapticWhen>? kinds,
    Map<HapticWhen, HapticPattern>? patterns,
  }) => HapticSettings(
    on: on ?? this.on,
    strength: strength ?? this.strength,
    kinds: kinds ?? this.kinds,
    patterns: patterns ?? this.patterns,
  );

  /// With one kind switched on or off.
  HapticSettings withKind(HapticWhen when, bool wanted) {
    final next = {...kinds};
    if (wanted) {
      next.add(when);
    } else {
      next.remove(when);
    }
    return copyWith(kinds: next);
  }

  /// With one kind's shape set (the default shape clears the entry).
  HapticSettings withPattern(HapticWhen when, HapticPattern pattern) {
    final next = {...patterns};
    if (pattern == (defaultPatterns[when] ?? HapticPattern.single)) {
      next.remove(when);
    } else {
      next[when] = pattern;
    }
    return copyWith(patterns: next);
  }

  @override
  bool operator ==(Object other) =>
      other is HapticSettings &&
      other.on == on &&
      other.strength == strength &&
      other.kinds.length == kinds.length &&
      other.kinds.containsAll(kinds) &&
      other.patterns.length == patterns.length &&
      other.patterns.entries.every((e) => patterns[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    on,
    strength,
    Object.hashAllUnordered(kinds),
    Object.hashAllUnordered(patterns.entries.map((e) => (e.key, e.value))),
  );

  Map<String, Object?> toJson() => {
    'on': on,
    'strength': strength.name,
    'kinds': [for (final k in kinds) k.name],
    if (patterns.isNotEmpty)
      'patterns': {for (final e in patterns.entries) e.key.name: e.value.name},
  };

  static HapticSettings fromJson(Object? j) {
    if (j is! Map) return const HapticSettings();
    final kinds = <HapticWhen>{};
    if (j['kinds'] case final List l) {
      for (final name in l) {
        for (final w in HapticWhen.values) {
          if (w.name == name) kinds.add(w);
        }
      }
    }
    final patterns = <HapticWhen, HapticPattern>{};
    if (j['patterns'] case final Map m) {
      for (final e in m.entries) {
        final when = HapticWhen.values
            .where((w) => w.name == e.key)
            .firstOrNull;
        final pattern = HapticPattern.values
            .where((p) => p.name == e.value)
            .firstOrNull;
        if (when != null && pattern != null) patterns[when] = pattern;
      }
    }
    return HapticSettings(
      on: j['on'] != false,
      strength:
          HapticStrength.values
              .where((s) => s.name == j['strength'])
              .firstOrNull ??
          HapticStrength.medium,
      kinds: j['kinds'] is List ? kinds : const HapticSettings().kinds,
      patterns: patterns,
    );
  }
}

/// The deck's haptics. Set once by the host (the phone reads them out of its
/// settings file); everything that buzzes calls [Haptics.fire].
abstract final class Haptics {
  static HapticSettings settings = const HapticSettings();

  /// Where the pulses actually go. The phone leaves this alone; a test puts
  /// a recorder here instead of the platform channel.
  static void Function(HapticStrength strength)? pulse;

  /// Buzzes for [when], if that kind buzzes at all.
  static void fire(HapticWhen when) {
    final s = settings;
    if (!s.on || !s.kinds.contains(when)) return;
    final beats = _patternBeats[s.patternOf(when)] ?? const [0];
    for (final at in beats) {
      if (at == 0) {
        _beat(s.strength);
      } else {
        Timer(Duration(milliseconds: at), () => _beat(s.strength));
      }
    }
  }

  static void _beat(HapticStrength strength) {
    final send = pulse;
    if (send != null) {
      send(strength);
      return;
    }
    switch (strength) {
      case HapticStrength.soft:
        unawaited(HapticFeedback.lightImpact());
      case HapticStrength.medium:
        unawaited(HapticFeedback.mediumImpact());
      case HapticStrength.hard:
        unawaited(HapticFeedback.heavyImpact());
    }
  }
}

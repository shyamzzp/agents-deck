// agents deck on iPhone and iPad.
//
// The deck is the shared package (`agents_deck_ui`), the same one the desk
// panel and the menu bar app draw. What differs here is only how the device
// reaches the service: not the daemon's unix socket, which a phone cannot
// open, but the network listener (`deviceAddr`, :7341) over HTTPS with the
// deck's own CA pinned -- the path the panel already uses, so
// `HttpAgentsClient` needs nothing new.
//
// Pairing is the bundle `agentctl pair <name> --bundle agents.json` writes:
// the deck's CA, this device's certificate and its key. It is kept in the
// app's Documents directory, found with path_provider: iOS does not put HOME
// in the environment the way a desktop does, so the directory has to be asked
// for rather than assembled. `docs/phone.md` sets out a stronger
// scheme -- a QR code, a key made in the Secure Enclave, a CSR -- which keeps
// the key off disk entirely; this takes the bundle route first because the
// server side of it is already built.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'deck_ear.dart';
import 'dictate_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DeckApp());
}

/// Where the pairing bundle lives, inside the app's own container.
Future<String> configPath() async =>
    '${(await getApplicationDocumentsDirectory()).path}/${AgentsConfig.fileName}';

/// The loader [HttpAgentsClient] calls on every reconnect, so a bundle
/// replaced while the app runs is picked up. It has to be synchronous, hence
/// the resolved path rather than another lookup.
(AgentsConfig?, String?) Function() bundleLoader(String path) =>
    () => AgentsConfig.load(env: const {}, paths: [path]);

/// What the config page remembers, beside the bundle.
const _settingsFile = 'settings.json';

/// How wide and tall a page may be set, as far as a saved file is concerned.
/// Below 2 a page is not a grid; 8 x 8 is 64 tiles, which only a tablet has
/// the room for.
const gridRange = [2, 3, 4, 5, 6, 7, 8];

/// The most a page may be set to on this device: 8 on a tablet, 7 on a phone.
/// 600 points of shortest side is the usual line between the two.
int gridMax(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= 600 ? 8 : 7;

/// A tablet has the room for 25 agents at once.
const defaultShape = DeckShape(5, 5);

/// How thick the context gauge around an agent card may be drawn, in points.
/// That line is the card's border and its context meter at once: the orange
/// fills it as the agent's context fills up. Belongs to the device showing
/// the deck rather than to the service.
const ringWidths = [1.0, 2.0, 3.0, 4.0, 6.0, 8.0];
const defaultRingWidth = 4.0;

/// The deck's shape: one shape for every page, and any page that wants its
/// own.
///
/// It is held this way, rather than as a list where the last entry repeats,
/// because the two read differently when a page is changed. In a list of one,
/// "page 1" is also every other page, so setting it sets them all. Here a page
/// is either its own or the default, and nothing else moves.
class DeckLayout {
  const DeckLayout({
    this.fallback = defaultShape,
    this.perPage = const {},
    this.attention,
    this.ring = defaultRingWidth,
    this.theme,
    this.titles = const {},
    this.haptics = const HapticSettings(on: true),
    this.artifactKind = '',
  });

  /// Every page that has not been given its own shape.
  final DeckShape fallback;

  /// By page index, 0 first. Never holds a shape equal to [fallback]: that is
  /// not an override, it is the default, and keeping it would leave a page
  /// pinned behind later changes to the default.
  final Map<int, DeckShape> perPage;

  /// The "Needs you" screen's own shape, or null to follow [fallback].
  final DeckShape? attention;

  /// How thick the context gauge around each card is drawn, in points.
  final double ring;

  /// The chosen iTerm2 colour scheme by name, or null for the stock deck.
  final String? theme;

  /// What each page is called, by index; -1 is the "Needs you" screen. A page
  /// with no name of its own is called "page N".
  final Map<int, String> titles;

  /// What the deck feels like on this device. On by default here: a phone
  /// has a taptic engine and the deck is prodded without looking at it.
  final HapticSettings haptics;

  /// Which kind the artifacts page is showing: one of [artifactKinds], "" for
  /// all of them. Kept here so the page opens on the same one next time.
  final String artifactKind;

  DeckShape shapeOf(int page) => perPage[page] ?? fallback;

  /// The "Needs you" screen, which is a page you swipe to like any other even
  /// though the deck does not number it.
  DeckShape get attentionShape => attention ?? fallback;

  DeckLayout withAttention(DeckShape shape) => DeckLayout(
    fallback: fallback,
    perPage: perPage,
    attention: shape == fallback ? null : shape,
    ring: ring,
    theme: theme,
    titles: titles,
    haptics: haptics,
    artifactKind: artifactKind,
  );

  DeckLayout withRing(double width) => DeckLayout(
    fallback: fallback,
    perPage: perPage,
    attention: attention,
    ring: ringWidths.contains(width) ? width : ring,
    theme: theme,
    titles: titles,
    haptics: haptics,
    artifactKind: artifactKind,
  );

  /// With a page set to [shape], or back to the default when they are equal.
  DeckLayout withPage(int page, DeckShape shape) {
    final next = {...perPage};
    if (shape == fallback) {
      next.remove(page);
    } else {
      next[page] = shape;
    }
    return DeckLayout(
      fallback: fallback,
      perPage: next,
      attention: attention,
      ring: ring,
      theme: theme,
      titles: titles,
      haptics: haptics,
      artifactKind: artifactKind,
    );
  }

  /// With the default set to [shape]; any page that was overridden to exactly
  /// that stops being an override.
  DeckLayout withFallback(DeckShape shape) => DeckLayout(
    fallback: shape,
    perPage: {
      for (final e in perPage.entries)
        if (e.value != shape) e.key: e.value,
    },
    attention: attention == shape ? null : attention,
    ring: ring,
    theme: theme,
    titles: titles,
    haptics: haptics,
    artifactKind: artifactKind,
  );

  /// With the deck painted in the scheme called [name]; null is the stock
  /// deck, which is also what an unknown name falls back to.
  DeckLayout withTheme(String? name) => DeckLayout(
    fallback: fallback,
    perPage: perPage,
    attention: attention,
    ring: ring,
    theme: name == stockThemeName ? null : name,
    titles: titles,
    haptics: haptics,
    artifactKind: artifactKind,
  );

  /// With the artifacts page looking at one kind of thing.
  DeckLayout withArtifactKind(String kind) => DeckLayout(
    fallback: fallback,
    perPage: perPage,
    attention: attention,
    ring: ring,
    theme: theme,
    titles: titles,
    haptics: haptics,
    artifactKind: artifactKinds.contains(kind) ? kind : '',
  );

  /// With the haptics set as they have been changed.
  DeckLayout withHaptics(HapticSettings h) => DeckLayout(
    fallback: fallback,
    perPage: perPage,
    attention: attention,
    ring: ring,
    theme: theme,
    titles: titles,
    haptics: h,
  );

  /// With a page renamed, or back to its default name when [name] is empty.
  DeckLayout withTitle(int page, String name) {
    final next = {...titles};
    if (name.trim().isEmpty) {
      next.remove(page);
    } else {
      next[page] = name.trim();
    }
    return DeckLayout(
      fallback: fallback,
      perPage: perPage,
      attention: attention,
      ring: ring,
      theme: theme,
      titles: next,
      haptics: haptics,
      artifactKind: artifactKind,
    );
  }

  /// The shapes [AgentsApp] wants: one per page, the last repeating. The
  /// default goes last so every page past the overrides gets it.
  List<DeckShape> get pageShapes {
    if (perPage.isEmpty) return [fallback];
    final highest = perPage.keys.reduce((a, b) => a > b ? a : b);
    return [for (var p = 0; p <= highest + 1; p++) shapeOf(p)];
  }

  Map<String, Object?> toJson() => {
    'default': [fallback.columns, fallback.rows],
    if (attention case final a?) 'needsYou': [a.columns, a.rows],
    'ring': ring,
    if (artifactKind.isNotEmpty) 'artifacts': artifactKind,
    'theme': ?theme,
    if (titles.isNotEmpty)
      'titles': {for (final e in titles.entries) '${e.key}': e.value},
    // Only when they have been changed, as the page names are: a settings
    // file of defaults says nothing.
    if (haptics != const HapticSettings(on: true)) 'haptics': haptics.toJson(),
    'pages': {
      for (final e in perPage.entries)
        '${e.key}': [e.value.columns, e.value.rows],
    },
  };

  static Map<int, String> _titles(Object? j) {
    if (j is! Map) return const {};
    final out = <int, String>{};
    for (final e in j.entries) {
      final page = int.tryParse('${e.key}');
      final name = e.value;
      if (page != null && name is String && name.trim().isNotEmpty) {
        out[page] = name.trim();
      }
    }
    return out;
  }

  static DeckShape? _shape(Object? j) {
    if (j is! List || j.length != 2) return null;
    final c = j[0], r = j[1];
    if (c is! int || r is! int) return null;
    if (!gridRange.contains(c) || !gridRange.contains(r)) return null;
    return DeckShape(c, r);
  }

  static DeckLayout fromJson(Object? j) {
    if (j is! Map) return const DeckLayout();
    final fallback = _shape(j['default']) ?? defaultShape;
    final pages = <int, DeckShape>{};
    final raw = j['pages'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final page = int.tryParse('${e.key}');
        final shape = _shape(e.value);
        if (page != null && page >= 0 && shape != null && shape != fallback) {
          pages[page] = shape;
        }
      }
    }
    final att = _shape(j['needsYou']);
    final r = j['ring'];
    return DeckLayout(
      fallback: fallback,
      perPage: pages,
      attention: att == fallback ? null : att,
      ring: r is num && ringWidths.contains(r.toDouble())
          ? r.toDouble()
          : defaultRingWidth,
      theme: j['theme'] is String ? j['theme'] as String : null,
      titles: _titles(j['titles']),
      haptics: j['haptics'] == null
          ? const HapticSettings(on: true)
          : HapticSettings.fromJson(j['haptics']),
      artifactKind:
          j['artifacts'] is String && artifactKinds.contains(j['artifacts'])
          ? j['artifacts'] as String
          : '',
    );
  }
}

Future<DeckLayout> loadLayout(String docs) async {
  try {
    return DeckLayout.fromJson(
      jsonDecode(await File('$docs/$_settingsFile').readAsString()),
    );
  } catch (_) {
    return const DeckLayout(); // not written yet, or unreadable
  }
}

Future<void> saveLayout(String docs, DeckLayout layout) async {
  final f = File('$docs/$_settingsFile');
  await f.parent.create(recursive: true);
  await f.writeAsString(jsonEncode(layout.toJson()));
}

class DeckApp extends StatefulWidget {
  const DeckApp({super.key});

  @override
  State<DeckApp> createState() => _DeckAppState();
}

class _DeckAppState extends State<DeckApp> {
  AgentsSource? _source;
  String? _path;
  String? _docs;
  String? _reason;
  bool _looked = false;
  DeckLayout _layout = const DeckLayout();

  /// Someone waiting on what is being said: a new task spoken into an empty
  /// cell of a card's quick list. The deck asks for it, the sheet fills it.
  Completer<String?>? _speaking;

  /// The agent being spoken to, while the dictation sheet is open.
  Agent? _dictating;

  /// The phone's ear, for speaking to an agent from the "Needs you" screen.
  /// One for the app: only one callout is open at a time.
  final _ear = PhoneEar();

  /// Whether this device has anything to buzz with. An iPad has no Taptic
  /// Engine of any kind, so a page of haptics switches there is a page of
  /// promises nothing keeps: the settings leave the section out, and nothing
  /// asks the platform to buzz. Null until the device has answered.
  bool? _canBuzz;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
    unawaited(_askBuzz());
  }

  /// Asks the device whether it can buzz (ios/Runner/Buzz.swift). A platform
  /// that does not answer is taken as one that cannot: the switches are
  /// hidden rather than shown over nothing.
  Future<void> _askBuzz() async {
    var can = false;
    try {
      can =
          await const MethodChannel(
            'deck/buzz',
          ).invokeMethod<bool>('supported') ??
          false;
    } on PlatformException {
      can = false;
    } on MissingPluginException {
      can = false;
    }
    if (!mounted) return;
    setState(() => _canBuzz = can);
    if (!can) {
      // Nothing to feel: whatever the file says, this device stays quiet.
      Haptics.settings = Haptics.settings.copyWith(on: false);
    }
  }

  /// Reads the bundle before connecting, so an unpaired app shows the pairing
  /// screen rather than a deck that can never arrive.
  Future<void> _check() async {
    final docs = _docs ?? (await getApplicationDocumentsDirectory()).path;
    final path = '$docs/${AgentsConfig.fileName}';
    final layout = await loadLayout(docs);
    // Before the first frame: the deck should open in the chosen colours
    // rather than flash the stock ones on the way to them.
    DeckHud.apply(await deckTheme(layout.theme));
    final (cfg, why) = AgentsConfig.load(env: const {}, paths: [path]);
    if (!mounted) return;
    setState(() {
      _docs = docs;
      _path = path;
      _layout = layout;
      _reason = why;
      _looked = true;
      if (cfg != null) {
        _source ??= HttpAgentsClient(loadConfig: bundleLoader(path));
      }
    });
  }

  /// Sets one page's shape. Only that page moves: the others keep whatever
  /// they had, which is the whole point of holding a default separately.
  Future<void> _setPage(int page, DeckShape shape) =>
      _store(_layout.withPage(page, shape));

  /// Sets the shape every page without one of its own is drawn in.
  Future<void> _setFallback(DeckShape shape) =>
      _store(_layout.withFallback(shape));

  /// Sets the "Needs you" screen's shape.
  Future<void> _setAttention(DeckShape shape) =>
      _store(_layout.withAttention(shape));

  /// Sets how thick the context gauge around every card is drawn.
  Future<void> _setRing(double width) => _store(_layout.withRing(width));

  /// Paints the deck in a colour scheme. The tokens are statics, so the whole
  /// tree is rebuilt from the root rather than any one page redrawn.
  Future<void> _setTheme(DeckTheme? theme) async {
    DeckHud.apply(theme);
    await _store(_layout.withTheme(theme?.name));
  }

  /// Which kind of thing the artifacts page is showing. Kept on this device,
  /// so it opens on the same one next time.
  Future<void> _setArtifactKind(String kind) =>
      _store(_layout.withArtifactKind(kind));

  /// Renames the page shown, from the footer.
  Future<void> _setTitle(int page, String name) =>
      _store(_layout.withTitle(page, name));

  /// Sets what the deck feels like, and lets it be felt at once rather than
  /// after the next launch.
  Future<void> _setHaptics(HapticSettings h) async {
    Haptics.settings = h;
    await _store(_layout.withHaptics(h));
  }

  Future<void> _store(DeckLayout layout) async {
    final docs = _docs;
    if (docs == null) return;
    setState(() => _layout = layout);
    await saveLayout(docs, layout);
  }

  /// The deck this device is paired with, for the config page to name.
  String? _deckName() {
    final path = _path;
    if (path == null) return null;
    final (cfg, _) = AgentsConfig.load(env: const {}, paths: [path]);
    return cfg == null ? null : '${cfg.name} \u00b7 ${cfg.url.host}';
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final dictating = _dictating;
    return WidgetsApp(
      color: DeckHud.accent,
      debugShowCheckedModeBanner: false,
      builder: (context, _) => ColoredBox(
        color: DeckHud.bg,
        child: Stack(
          children: [
            SafeArea(
              child: switch ((source, _looked)) {
                // backButton: false. Dragging the card to the right goes back
                // (agent_detail's own gesture), so the "<" was only taking 63
                // points of a 357 point row off "focus terminal".
                //
                // 5x5 rather than the panel's 4x4: a tablet has the room for 25
                // agents at once, and paging through a long deck four at a time is
                // the thing that wears thin on a screen you hold. The cost is that
                // pages no longer begin where the panel's do, since a slot's page
                // is its number over the page size.
                (final AgentsSource s, _) => AgentsApp(
                  source: s,
                  backButton: false,
                  // The usage line follows the Mac's "Report usage from
                  // every Claude session": turning that off clears it from
                  // the phone too, not only from Claude's own settings.
                  usageFollowsSetting: true,
                  // On the tablet the card's two actions ride beside the
                  // agent's name rather than at the foot of a tall card.
                  headerActions: true,
                  pageShapes: _layout.pageShapes,
                  attentionShape: _layout.attentionShape,
                  contextRingWidth: _layout.ring,
                  pageTitles: _layout.titles,
                  onRenamePage: _setTitle,
                  // Held on the "Needs you" screen: speak the answer. The sheet
                  // opens over the deck rather than as a route, since this app
                  // has no navigator of its own.
                  // Holding an agent there speaks into a callout beside its
                  // tile (the deck draws it); the sheet is only for a task
                  // spoken into a card's empty cell.
                  ear: _ear,
                  // Holding an empty cell of a card's quick list: the phone
                  // listens, and the card keeps what was said as a task in
                  // that cell, named by the service in its own short way.
                  onSpeakTask: (agent) {
                    final waiting = Completer<String?>();
                    setState(() {
                      _speaking = waiting;
                      _dictating = agent;
                    });
                    return waiting.future;
                  },
                  // A phone has no menu bar to hang settings off, so they get a
                  // page of their own at the far left. The deck still opens.
                  // Past the deck's own pages, at the far end: what the
                  // agents made, which opens on the Mac when tapped.
                  trailingPages: [
                    ArtifactsPage(
                      source: s,
                      kind: _layout.artifactKind,
                      onKind: _setArtifactKind,
                    ),
                  ],
                  leadingPage: ConfigPage(
                    layout: _layout,
                    onPage: _setPage,
                    onFallback: _setFallback,
                    onAttention: _setAttention,
                    onRing: _setRing,
                    onTheme: _setTheme,
                    onHaptics: _setHaptics,
                    canBuzz: _canBuzz ?? false,
                    deck: _deckName(),
                    source: s,
                  ),
                ),
                // Until the directory has been asked for there is nothing to say:
                // showing "not paired yet" first would be a lie on every launch.
                (_, false) => const SizedBox.shrink(),
                _ => PairingScreen(
                  reason: _reason,
                  path: _path,
                  onPaired: () => unawaited(_check()),
                ),
              },
            ),
            if (dictating != null && source != null)
              Positioned.fill(
                child: DictateSheet(
                  key: ValueKey('dictate-${dictating.id}'),
                  // Speaking a task: what is said comes back to the card,
                  // which keeps it in the cell that was held. Otherwise it
                  // goes to the agent's terminal.
                  onSaid: _speaking == null
                      ? null
                      : (said) {
                          _speaking?.complete(said);
                          _speaking = null;
                        },
                  heading: _speaking == null ? null : 'say the task',
                  sendLabel: _speaking == null ? 'send' : 'make task',
                  agent:
                      source.snapshot.value.state?.agents
                          .where((x) => x.id == dictating.id)
                          .firstOrNull ??
                      dictating,
                  source: source,
                  onClose: () => setState(() {
                    // Closed without saying anything: whoever asked gets
                    // nothing rather than waiting for ever.
                    _speaking?.complete(null);
                    _speaking = null;
                    _dictating = null;
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Takes the bundle `agentctl pair --bundle` writes. Pasting is the whole of
/// it: a QR scanner would want a camera permission and a package, and this is
/// a one-off step.
class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    this.reason,
    this.path,
    required this.onPaired,
  });

  final String? reason;

  /// Where a pasted bundle is written; null until the directory is known.
  final String? path;
  final VoidCallback onPaired;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text case final t? when t.trim().isNotEmpty) {
      _text.text = t.trim();
      setState(() => _error = null);
    } else {
      setState(() => _error = 'the clipboard has no text');
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final raw = _text.text.trim();
      if (raw.isEmpty) throw const FormatException('paste the bundle first');
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) {
        throw const FormatException('that is not a bundle object');
      }
      AgentsConfig.fromJson(j); // validate before anything is written
      final path = widget.path ?? await configPath();
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
      widget.onPaired();
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on FileSystemException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('agents deck', style: DeckHud.rm(26, DeckHud.ink, weight: 700)),
        const SizedBox(height: 14),
        Text(
          'This device is not paired yet. On the Mac, run:',
          style: DeckHud.mono(size: 15, color: DeckHud.ink),
        ),
        const SizedBox(height: 10),
        _Code('agentctl pair ipad --scope act --bundle agents.json'),
        const SizedBox(height: 10),
        Text(
          'Paste that file below. It carries this device’s private key, '
          'so delete it on the Mac once this says paired.',
          style: DeckHud.mono(size: 13, color: DeckHud.dim),
        ),
        const SizedBox(height: 18),
        _Field(controller: _text, focus: _focus),
        const SizedBox(height: 14),
        Row(
          children: [
            _Button(label: 'Paste', onTap: _saving ? null : _paste),
            const SizedBox(width: 10),
            _Button(
              label: _saving ? 'checking…' : 'Pair',
              onTap: _saving ? null : _save,
              filled: true,
            ),
          ],
        ),
        if (_error case final e?) ...[
          const SizedBox(height: 14),
          Text(e, style: DeckHud.mono(size: 13, color: DeckHud.accent)),
        ] else if (widget.reason case final r?) ...[
          const SizedBox(height: 14),
          Text(r, style: DeckHud.mono(size: 13, color: DeckHud.dim)),
        ],
      ],
    );
  }
}

class _Code extends StatelessWidget {
  const _Code(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    color: DeckHud.panel,
    child: Text(text, style: DeckHud.rm(13, DeckHud.ink)),
  );
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.focus});

  final TextEditingController controller;
  final FocusNode focus;

  @override
  Widget build(BuildContext context) => Container(
    height: 190,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: DeckHud.panel,
      border: Border.all(color: DeckHud.dim),
    ),
    child: EditableText(
      controller: controller,
      focusNode: focus,
      style: DeckHud.rm(12, DeckHud.ink),
      cursorColor: DeckHud.accent,
      backgroundCursorColor: DeckHud.dim,
      maxLines: null,
      expands: true,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.multiline,
      selectionColor: DeckHud.accent.withValues(alpha: 0.35),
    ),
  );
}

class _Button extends StatelessWidget {
  const _Button({required this.label, this.onTap, this.filled = false});

  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final off = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: filled ? DeckHud.ink : null,
          border: Border.all(color: filled ? DeckHud.ink : DeckHud.dim),
        ),
        child: Opacity(
          opacity: off ? 0.5 : 1,
          child: Text(
            label,
            style: DeckHud.mono(
              size: 14,
              color: filled ? DeckHud.bg : DeckHud.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// The page at the far left of the deck: what a menu bar would hold on a
/// desktop. The deck opens on its own first page, so this is somewhere you go
/// rather than somewhere you land.
class ConfigPage extends StatefulWidget {
  const ConfigPage({
    super.key,
    required this.layout,
    required this.onPage,
    required this.onFallback,
    required this.onAttention,
    required this.onRing,
    required this.onTheme,
    required this.onHaptics,
    required this.canBuzz,
    required this.source,
    this.deck,
  });

  final DeckLayout layout;
  final void Function(int page, DeckShape shape) onPage;
  final void Function(DeckShape shape) onFallback;
  final void Function(DeckShape shape) onAttention;
  final void Function(double width) onRing;
  final void Function(DeckTheme? theme) onTheme;

  /// Sets what the deck feels like: on or off, how hard, which moments, and
  /// the shape of each.
  final void Function(HapticSettings haptics) onHaptics;

  /// Whether this device has a Taptic Engine. Without one the haptics are
  /// left out of the page entirely: an iPad cannot buzz, and switches that
  /// do nothing are worse than no switches.
  final bool canBuzz;

  /// Watched for how many pages the deck currently has.
  final AgentsSource source;

  /// The paired deck, named for confirmation; null before it is read.
  final String? deck;

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  // 611 schemes: the list shows a window of them, and typing narrows it.
  static const _shown = 40;

  List<DeckTheme>? _themes;
  String _query = '';
  bool _open = false;

  DeckLayout get layout => widget.layout;

  @override
  void initState() {
    super.initState();
    unawaited(_loadThemes());
  }

  Future<void> _loadThemes() async {
    final all = await deckThemes();
    if (mounted) setState(() => _themes = all);
  }

  /// The themes to draw: the chosen one first, so the list always opens on it.
  List<DeckTheme> _matches(List<DeckTheme> all) {
    final q = _query.trim().toLowerCase();
    final hits = [
      for (final t in all)
        if (q.isEmpty || t.name.toLowerCase().contains(q)) t,
    ];
    final name = layout.theme ?? stockThemeName;
    final i = hits.indexWhere((t) => t.name == name);
    if (i > 0) hits.insert(0, hits.removeAt(i));
    return hits;
  }

  /// The colours section: what is on now, and the list once it is opened.
  List<Widget> _themeSection() {
    final all = _themes;
    final current = layout.theme ?? stockThemeName;
    final head = _ThemeRow(
      key: const Key('theme-current'),
      name: current,
      theme: all?.where((t) => t.name == current).firstOrNull,
      selected: true,
      trailing: _open ? 'close' : 'change',
      onTap: () => setState(() => _open = !_open),
    );
    if (!_open) return [head];
    if (all == null) {
      return [
        head,
        const SizedBox(height: 10),
        Text(
          'reading the schemes\u2026',
          style: DeckHud.mono(size: 12, color: DeckHud.dim),
        ),
      ];
    }
    final hits = _matches(all);
    return [
      head,
      const SizedBox(height: 10),
      _Search(
        key: const Key('theme-search'),
        hint: 'search ${all.length} themes',
        onChanged: (q) => setState(() => _query = q),
      ),
      const SizedBox(height: 6),
      Text(
        hits.length > _shown
            ? '${hits.length} themes \u00b7 first $_shown shown, keep typing'
            : '${hits.length} theme${hits.length == 1 ? '' : 's'}',
        style: DeckHud.mono(size: 12, color: DeckHud.dim),
      ),
      const SizedBox(height: 8),
      for (final t in hits.take(_shown)) ...[
        _ThemeRow(
          key: Key('theme-${t.name}'),
          name: t.name,
          theme: t,
          selected: t.name == current,
          onTap: () {
            widget.onTheme(t.name == stockThemeName ? null : t);
            setState(() {});
          },
        ),
        const SizedBox(height: 6),
      ],
    ];
  }

  /// What a moment is called in the settings, in the deck's own words.
  /// Where two settings go side by side. A tablet held upright is 810 points
  /// across and one of these settings uses about 350 of it, so two fit with
  /// room to spare and the page is half as tall; a phone held upright (390)
  /// has room for one.
  static const _twoColumnsFrom = 700.0;

  /// One setting: its name, what it is, and the rows that set it.
  Widget _section(String title, String about, List<Widget> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: DeckHud.mono(size: 14, color: DeckHud.ink)),
      const SizedBox(height: 6),
      Text(about, style: DeckHud.mono(size: 12, color: DeckHud.dim)),
      const SizedBox(height: 12),
      ...rows,
    ],
  );

  /// [blocks] laid out one or two to a line, with the gaps between them. They
  /// are hung from the top rather than stretched: each carries its own
  /// heading, and a section with three pages in it must not drag the height
  /// of the one beside it.
  List<Widget> _inColumns(BuildContext context, List<Widget> blocks) {
    const gap = 22.0;
    if (MediaQuery.sizeOf(context).width < _twoColumnsFrom) {
      return [
        for (final b in blocks) ...[const SizedBox(height: gap), b],
      ];
    }
    final out = <Widget>[];
    for (var i = 0; i < blocks.length; i += 2) {
      out.add(const SizedBox(height: gap));
      out.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: blocks[i]),
            const SizedBox(width: 16),
            Expanded(
              child: i + 1 < blocks.length ? blocks[i + 1] : const SizedBox(),
            ),
          ],
        ),
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final h = layout.haptics;
    return ValueListenableBuilder<AgentsSnapshot>(
      valueListenable: widget.source.snapshot,
      builder: (context, snap, _) {
        final slots = snap.state?.agents.map((a) => a.slot) ?? const <int>[];
        final pages = deckPageCount(layout.pageShapes, slots);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          children: [
            Text('settings', style: DeckHud.rm(22, DeckHud.ink, weight: 700)),
            const SizedBox(height: 4),
            Text(
              widget.deck == null ? 'not paired' : 'paired with ${widget.deck}',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            ..._inColumns(context, [
              _section(
                'every page',
                'The grid each page of the deck is drawn in. A page holds as '
                    'many agents as it has cells, so making this smaller '
                    'spreads the same agents over more pages. They keep their '
                    'places.',
                [
                  _ShapeRow(
                    key: const Key('shape-row-default'),
                    title: 'all pages',
                    shape: layout.fallback,
                    accent: true,
                    onShape: widget.onFallback,
                  ),
                ],
              ),
              _section(
                pages == 1 ? 'the deck: one page' : 'the deck: $pages pages',
                'Each page can be given a grid of its own; the rest stay as '
                'above. The deck gains a page when the ones it has are '
                'full.',
                [
                  for (var i = 0; i < pages; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _ShapeRow(
                      key: Key('shape-row-page-$i'),
                      title: 'page ${i + 1}',
                      note: layout.perPage.containsKey(i)
                          ? 'its own'
                          : 'as above',
                      shape: layout.shapeOf(i),
                      onShape: (sh) => widget.onPage(i, sh),
                    ),
                  ],
                ],
              ),
              _section(
                'the \u201cneeds you\u201d page',
                'The page before the deck, holding the agents waiting on you. '
                    'The deck does not number it, and it holds sixteen spots '
                    'whatever grid it is drawn in.',
                [
                  _ShapeRow(
                    key: const Key('shape-row-attention'),
                    title: '\u201cneeds you\u201d page',
                    note: layout.attention == null ? 'as above' : 'its own',
                    shape: layout.attentionShape,
                    onShape: widget.onAttention,
                  ),
                ],
              ),
              _section(
                'context gauge',
                'The line around each card is its context meter: the orange '
                    'fills it as the agent\u2019s context fills up. This is '
                    'how thick that line is drawn.',
                [_RingRow(width: layout.ring, onWidth: widget.onRing)],
              ),
            ]),
            const SizedBox(height: 22),
            Text('colours', style: DeckHud.mono(size: 14, color: DeckHud.ink)),
            const SizedBox(height: 6),
            Text(
              'The deck in an iTerm2 colour scheme: its own presets, and the '
              'set published as mbadolato/iTerm2-Color-Schemes. The choice is '
              'kept on this device; the deck and the other screens are '
              'unaffected.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            const SizedBox(height: 12),
            ..._themeSection(),
            if (widget.canBuzz) ...[
              const SizedBox(height: 22),
              Text(
                'haptics',
                style: DeckHud.mono(size: 14, color: DeckHud.ink),
              ),
              const SizedBox(height: 6),
              Text(
                'What the deck feels like under a thumb: a soft pulse when a '
                'tap answers, when something is held, when a prompt goes, when '
                'something will not go, and when an agent starts needing you. '
                'Kept on this device.',
                style: DeckHud.mono(size: 12, color: DeckHud.dim),
              ),
              const SizedBox(height: 12),
              _HapticRow(
                key: const Key('haptics-on'),
                title: 'haptics',
                note: h.on ? 'on' : 'off',
                child: _Switch(
                  on: h.on,
                  onTap: () {
                    final next = h.copyWith(on: !h.on);
                    widget.onHaptics(next);
                    // Felt, not just read: switching them on answers with the
                    // buzz it has just turned on. Switching them off is
                    // silent, which is what off means.
                    Haptics.settings = next;
                    Haptics.fire(HapticWhen.tap);
                  },
                ),
              ),
            ],
            const SizedBox(height: 22),
            Text(
              'Swipe right for the deck.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
          ],
        );
      },
    );
  }
}

/// One grid setting: a title, its columns and its rows.
class _ShapeRow extends StatelessWidget {
  const _ShapeRow({
    super.key,
    required this.title,
    required this.shape,
    required this.onShape,
    this.note,
    this.accent = false,
  });

  final String title;

  /// Whether this page follows the default or has been given its own.
  final String? note;
  final DeckShape shape;
  final bool accent;
  final void Function(DeckShape) onShape;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      color: DeckHud.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: DeckHud.mono(size: 13, color: DeckHud.ink),
                ),
              ),
              if (note case final n?)
                Text(n, style: DeckHud.mono(size: 11, color: DeckHud.dim)),
              const SizedBox(width: 10),
              Text(
                'holds ${shape.cells}',
                style: DeckHud.mono(
                  size: 12,
                  color: accent ? DeckHud.accent : DeckHud.dim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stepper(
                key: const Key('cols'),
                label: 'cols',
                value: shape.columns,
                max: gridMax(context),
                onChange: (v) => onShape(DeckShape(v, shape.rows)),
              ),
              const SizedBox(width: 14),
              _Stepper(
                key: const Key('rows'),
                label: 'rows',
                value: shape.rows,
                max: gridMax(context),
                onChange: (v) => onShape(DeckShape(shape.columns, v)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    super.key,
    required this.label,
    required this.value,
    required this.onChange,
    required this.max,
  });

  final String label;
  final int value;
  final void Function(int) onChange;

  /// The largest this device allows (gridMax), not what a file may hold.
  final int max;

  @override
  Widget build(BuildContext context) {
    final lo = gridRange.first, hi = max;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: DeckHud.mono(size: 12, color: DeckHud.dim)),
        const SizedBox(width: 6),
        _Tap(glyph: '\u2212', on: value > lo, onTap: () => onChange(value - 1)),
        Container(
          width: 34,
          alignment: Alignment.center,
          child: Text('$value', style: DeckHud.rm(15, DeckHud.ink)),
        ),
        _Tap(glyph: '+', on: value < hi, onTap: () => onChange(value + 1)),
      ],
    );
  }
}

/// One haptics setting: what it is called, what it is set to, and the control
/// that changes it. Laid out like the grid rows above it.
class _HapticRow extends StatelessWidget {
  const _HapticRow({
    super.key,
    required this.title,
    required this.child,
    this.note,
  });

  final String title;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    color: DeckHud.panel,
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.mono(size: 13, color: DeckHud.ink),
          ),
        ),
        if (note case final n?) ...[
          Text(n, style: DeckHud.mono(size: 11, color: DeckHud.dim)),
          const SizedBox(width: 10),
        ],
        child,
      ],
    ),
  );
}

/// A switch in the deck's own style: a square that fills when it is on.
class _Switch extends StatelessWidget {
  const _Switch({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      width: 46,
      height: 26,
      alignment: on ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        border: Border.all(color: on ? DeckHud.accent : DeckHud.dim),
      ),
      child: Container(
        width: 18,
        height: 18,
        color: on ? DeckHud.accent : DeckHud.dim,
      ),
    ),
  );
}

/// One scheme: its five colours, its name, and whether it is a light one.
class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    super.key,
    required this.name,
    required this.theme,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final String name;

  /// Null only while themes.json is still being read, for the heading row.
  final DeckTheme? theme;
  final bool selected;
  final VoidCallback onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final chips = t == null
        ? const <Color>[]
        : [t.bg, t.panel, t.ink, t.dim, t.accent];
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          // The row wears the scheme it offers, so the list is a preview.
          color: t?.panel ?? DeckHud.panel,
          border: Border.all(
            color: selected ? DeckHud.accent : DeckHud.panel,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            for (final c in chips) ...[
              Container(width: 12, height: 20, color: c),
              const SizedBox(width: 2),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DeckHud.mono(size: 13, color: t?.ink ?? DeckHud.ink),
              ),
            ),
            Text(
              trailing ?? (t?.light == true ? 'light' : 'dark'),
              style: DeckHud.mono(size: 11, color: t?.dim ?? DeckHud.dim),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of text, for narrowing the list of schemes.
class _Search extends StatefulWidget {
  const _Search({super.key, required this.hint, required this.onChanged});

  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_Search> createState() => _SearchState();
}

class _SearchState extends State<_Search> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => widget.onChanged(_controller.text));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      color: DeckHud.panel,
      border: Border.all(color: DeckHud.dim),
    ),
    child: Stack(
      alignment: Alignment.centerLeft,
      children: [
        if (_controller.text.isEmpty)
          Text(widget.hint, style: DeckHud.mono(size: 12, color: DeckHud.dim)),
        EditableText(
          controller: _controller,
          focusNode: _focus,
          style: DeckHud.rm(13, DeckHud.ink),
          cursorColor: DeckHud.accent,
          backgroundCursorColor: DeckHud.dim,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          selectionColor: DeckHud.accent.withValues(alpha: 0.35),
        ),
      ],
    ),
  );
}

class _Tap extends StatelessWidget {
  const _Tap({required this.glyph, required this.on, required this.onTap});

  final String glyph;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: on ? onTap : null,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: on ? DeckHud.dim : DeckHud.panel),
        ),
        child: Text(
          glyph,
          style: DeckHud.rm(16, on ? DeckHud.ink : DeckHud.dim),
        ),
      ),
    );
  }
}

/// How thick the context gauge is drawn.
class _RingRow extends StatelessWidget {
  const _RingRow({required this.width, required this.onWidth});

  final double width;
  final void Function(double) onWidth;

  static String _label(double w) => '${w.toInt()}';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      color: DeckHud.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'thickness',
                  style: DeckHud.mono(size: 13, color: DeckHud.ink),
                ),
              ),
              Text(
                '${_label(width)} pt',
                style: DeckHud.mono(size: 12, color: DeckHud.accent),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final w in ringWidths) ...[
                if (w != ringWidths.first) const SizedBox(width: 6),
                Expanded(
                  child: GestureDetector(
                    key: Key('ring-$w'),
                    onTap: () => onWidth(w),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      decoration: BoxDecoration(
                        color: w == width ? DeckHud.ink : null,
                        border: Border.all(
                          color: w == width ? DeckHud.ink : DeckHud.dim,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          _label(w),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DeckHud.mono(
                            size: 12,
                            color: w == width ? DeckHud.bg : DeckHud.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

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

/// How wide and tall a page may be set. Below 2 a page is not a grid; above 6
/// the tiles stop being readable on a tablet, let alone a phone.
const gridRange = [2, 3, 4, 5, 6];

/// A tablet has the room for 25 agents at once.
const defaultShape = DeckShape(5, 5);

/// How thick the border around an agent card may be, in points. The browser
/// deck offers the same steps (agents.tileBorderWidth) and, like it, this
/// belongs to the device showing the deck rather than to the service.
const borderWidths = [0.0, 0.5, 1.0, 2.0, 3.0];
const defaultBorderWidth = 0.5;

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
    this.border = defaultBorderWidth,
  });

  /// Every page that has not been given its own shape.
  final DeckShape fallback;

  /// By page index, 0 first. Never holds a shape equal to [fallback]: that is
  /// not an override, it is the default, and keeping it would leave a page
  /// pinned behind later changes to the default.
  final Map<int, DeckShape> perPage;

  /// The "Needs you" screen's own shape, or null to follow [fallback].
  final DeckShape? attention;

  /// The border around each agent card, in points; 0 draws none.
  final double border;

  DeckShape shapeOf(int page) => perPage[page] ?? fallback;

  /// The "Needs you" screen, which is a page you swipe to like any other even
  /// though the deck does not number it.
  DeckShape get attentionShape => attention ?? fallback;

  DeckLayout withAttention(DeckShape shape) => DeckLayout(
    fallback: fallback,
    perPage: perPage,
    attention: shape == fallback ? null : shape,
    border: border,
  );

  DeckLayout withBorder(double width) => DeckLayout(
    fallback: fallback,
    perPage: perPage,
    attention: attention,
    border: borderWidths.contains(width) ? width : border,
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
      border: border,
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
    border: border,
  );

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
    'border': border,
    'pages': {
      for (final e in perPage.entries)
        '${e.key}': [e.value.columns, e.value.rows],
    },
  };

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
    final b = j['border'];
    return DeckLayout(
      fallback: fallback,
      perPage: pages,
      attention: att == fallback ? null : att,
      border: b is num && borderWidths.contains(b.toDouble())
          ? b.toDouble()
          : defaultBorderWidth,
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

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  /// Reads the bundle before connecting, so an unpaired app shows the pairing
  /// screen rather than a deck that can never arrive.
  Future<void> _check() async {
    final docs = _docs ?? (await getApplicationDocumentsDirectory()).path;
    final path = '$docs/${AgentsConfig.fileName}';
    final layout = await loadLayout(docs);
    final (cfg, why) = AgentsConfig.load(env: const {}, paths: [path]);
    if (!mounted) return;
    setState(() {
      _docs = docs;
      _path = path;
      _layout = layout;
      _reason = why;
      _looked = true;
      if (cfg != null) _source ??= HttpAgentsClient(loadConfig: bundleLoader(path));
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

  /// Sets the border drawn around every agent card.
  Future<void> _setBorder(double width) => _store(_layout.withBorder(width));

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
    return WidgetsApp(
      color: DeckHud.accent,
      debugShowCheckedModeBanner: false,
      builder: (context, _) => ColoredBox(
        color: DeckHud.bg,
        child: SafeArea(
          child: switch ((source, _looked)) {
            // backButton: a phone has no Esc and no edge swipe of its own,
            // so without it an opened agent card is a one-way door.
            //
            // 5x5 rather than the panel's 4x4: a tablet has the room for 25
            // agents at once, and paging through a long deck four at a time is
            // the thing that wears thin on a screen you hold. The cost is that
            // pages no longer begin where the panel's do, since a slot's page
            // is its number over the page size.
            (final AgentsSource s, _) => AgentsApp(
              source: s,
              backButton: true,
              pageShapes: _layout.pageShapes,
              attentionShape: _layout.attentionShape,
              cardBorderWidth: _layout.border,
              // A phone has no menu bar to hang settings off, so they get a
              // page of their own at the far left. The deck still opens.
              leadingPage: ConfigPage(
                layout: _layout,
                onPage: _setPage,
                onFallback: _setFallback,
                onAttention: _setAttention,
                onBorder: _setBorder,
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
            style: DeckHud.mono(size: 14, color: filled ? DeckHud.bg : DeckHud.ink),
          ),
        ),
      ),
    );
  }
}

/// The page at the far left of the deck: what a menu bar would hold on a
/// desktop. The deck opens on its own first page, so this is somewhere you go
/// rather than somewhere you land.
class ConfigPage extends StatelessWidget {
  const ConfigPage({
    super.key,
    required this.layout,
    required this.onPage,
    required this.onFallback,
    required this.onAttention,
    required this.onBorder,
    required this.source,
    this.deck,
  });

  final DeckLayout layout;
  final void Function(int page, DeckShape shape) onPage;
  final void Function(DeckShape shape) onFallback;
  final void Function(DeckShape shape) onAttention;
  final void Function(double width) onBorder;

  /// Watched for how many pages the deck currently has.
  final AgentsSource source;

  /// The paired deck, named for confirmation; null before it is read.
  final String? deck;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AgentsSnapshot>(
      valueListenable: source.snapshot,
      builder: (context, snap, _) {
        final slots = snap.state?.agents.map((a) => a.slot) ?? const <int>[];
        final pages = deckPageCount(layout.pageShapes, slots);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          children: [
            Text('settings', style: DeckHud.rm(22, DeckHud.ink, weight: 700)),
            const SizedBox(height: 4),
            Text(
              deck == null ? 'not paired' : 'paired with $deck',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            const SizedBox(height: 22),
            Text(
              'every page',
              style: DeckHud.mono(size: 14, color: DeckHud.ink),
            ),
            const SizedBox(height: 6),
            Text(
              'The grid each page of the deck is drawn in. A page holds as many '
              'agents as it has cells, so making this smaller spreads the same '
              'agents over more pages. They keep their places.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            const SizedBox(height: 12),
            _ShapeRow(
              key: const Key('shape-row-default'),
              title: 'all pages',
              shape: layout.fallback,
              accent: true,
              onShape: onFallback,
            ),
            const SizedBox(height: 22),
            Text(
              pages == 1 ? 'the deck: one page' : 'the deck: $pages pages',
              style: DeckHud.mono(size: 14, color: DeckHud.ink),
            ),
            const SizedBox(height: 6),
            Text(
              'Each page can be given a grid of its own; the rest stay as '
              'above. The deck gains a page when the ones it has are full.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < pages; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _ShapeRow(
                key: Key('shape-row-page-$i'),
                title: 'page ${i + 1}',
                note: layout.perPage.containsKey(i) ? 'its own' : 'as above',
                shape: layout.shapeOf(i),
                onShape: (sh) => onPage(i, sh),
              ),
            ],
            const SizedBox(height: 22),
            Text(
              'the \u201cneeds you\u201d page',
              style: DeckHud.mono(size: 14, color: DeckHud.ink),
            ),
            const SizedBox(height: 6),
            Text(
              'The page before the deck, holding the agents waiting on you. '
              'The deck does not number it, and it holds sixteen spots '
              'whatever grid it is drawn in.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            const SizedBox(height: 12),
            _ShapeRow(
              key: const Key('shape-row-attention'),
              title: '\u201cneeds you\u201d page',
              note: layout.attention == null ? 'as above' : 'its own',
              shape: layout.attentionShape,
              onShape: onAttention,
            ),
            const SizedBox(height: 22),
            Text(
              'card border',
              style: DeckHud.mono(size: 14, color: DeckHud.ink),
            ),
            const SizedBox(height: 6),
            Text(
              'A line around each agent card. The browser deck has the same '
              'setting; both belong to the screen showing the deck, not to '
              'the service.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            const SizedBox(height: 12),
            _BorderRow(width: layout.border, onWidth: onBorder),
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
                onChange: (v) => onShape(DeckShape(v, shape.rows)),
              ),
              const SizedBox(width: 14),
              _Stepper(
                key: const Key('rows'),
                label: 'rows',
                value: shape.rows,
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
  });

  final String label;
  final int value;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    final lo = gridRange.first, hi = gridRange.last;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: DeckHud.mono(size: 12, color: DeckHud.dim)),
        const SizedBox(width: 6),
        _Tap(
          glyph: '\u2212',
          on: value > lo,
          onTap: () => onChange(value - 1),
        ),
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


/// The card border: the same steps the browser deck offers.
class _BorderRow extends StatelessWidget {
  const _BorderRow({required this.width, required this.onWidth});

  final double width;
  final void Function(double) onWidth;

  static String _label(double w) =>
      w == 0 ? 'none' : (w % 1 == 0 ? '${w.toInt()} pt' : '$w pt');

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
                _label(width),
                style: DeckHud.mono(size: 12, color: DeckHud.accent),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final w in borderWidths) ...[
                if (w != borderWidths.first) const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    key: Key('border-$w'),
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

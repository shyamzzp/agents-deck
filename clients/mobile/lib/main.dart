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

/// The deck as it is shaped before anyone says otherwise: a tablet has the
/// room for 25 at once, and the last page's shape repeats for the rest.
const defaultShapes = [DeckShape(5, 5)];

List<DeckShape> _shapesFromJson(Object? j) {
  if (j is! List || j.isEmpty) return defaultShapes;
  final out = <DeckShape>[];
  for (final row in j) {
    if (row is! List || row.length != 2) continue;
    final c = row[0], r = row[1];
    if (c is int && r is int && gridRange.contains(c) && gridRange.contains(r)) {
      out.add(DeckShape(c, r));
    }
  }
  return out.isEmpty ? defaultShapes : out;
}

Future<List<DeckShape>> loadShapes(String docs) async {
  try {
    final j = jsonDecode(await File('$docs/$_settingsFile').readAsString());
    return _shapesFromJson(j is Map ? j['pages'] : null);
  } catch (_) {
    return defaultShapes; // not written yet, or unreadable
  }
}

Future<void> saveShapes(String docs, List<DeckShape> shapes) async {
  final f = File('$docs/$_settingsFile');
  await f.parent.create(recursive: true);
  await f.writeAsString(
    jsonEncode({
      'pages': [
        for (final s in shapes) [s.columns, s.rows],
      ],
    }),
  );
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
  List<DeckShape> _shapes = defaultShapes;

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
    final shapes = await loadShapes(docs);
    final (cfg, why) = AgentsConfig.load(env: const {}, paths: [path]);
    if (!mounted) return;
    setState(() {
      _docs = docs;
      _path = path;
      _shapes = shapes;
      _reason = why;
      _looked = true;
      if (cfg != null) _source ??= HttpAgentsClient(loadConfig: bundleLoader(path));
    });
  }

  /// Sets page [i]'s shape, lengthening the list when a later page is given
  /// one of its own (every page up to it has to be written down first, since
  /// the list is read in order).
  Future<void> _setShape(int i, DeckShape shape) async {
    final docs = _docs;
    if (docs == null) return;
    final next = [
      for (var p = 0; p <= (i > _shapes.length - 1 ? i : _shapes.length - 1); p++)
        p == i ? shape : deckShapeOf(_shapes, p),
    ];
    setState(() => _shapes = next);
    await saveShapes(docs, next);
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
              pageShapes: _shapes,
              // A phone has no menu bar to hang settings off, so they get a
              // page of their own at the far left. The deck still opens.
              leadingPage: ConfigPage(
                shapes: _shapes,
                onShape: _setShape,
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
///
/// Each page of the deck gets its own shape here. A page holds as many agents
/// as it has cells, so changing one moves where the later pages begin; the
/// agents keep their places.
class ConfigPage extends StatelessWidget {
  const ConfigPage({
    super.key,
    required this.shapes,
    required this.onShape,
    required this.source,
    this.deck,
  });

  final List<DeckShape> shapes;
  final void Function(int page, DeckShape shape) onShape;

  /// Watched for how many pages the deck currently needs.
  final AgentsSource source;

  /// The paired deck, named for confirmation; null before it is read.
  final String? deck;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AgentsSnapshot>(
      valueListenable: source.snapshot,
      builder: (context, snap, _) {
        final slots = snap.state?.agents.map((a) => a.slot) ?? const <int>[];
        final used = deckPageCount(shapes, slots);
        // The pages the deck actually has, and one spare so the next can be
        // shaped before an agent lands on it. Deliberately not driven by how
        // many shapes are stored: shaping the spare would then add another,
        // and that one another, without end.
        final listed = (used + 1).clamp(2, 8);
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
              'agents per page',
              style: DeckHud.mono(size: 14, color: DeckHud.ink),
            ),
            const SizedBox(height: 6),
            Text(
              'Each page of the deck is drawn in its own grid. A page holds '
              'as many agents as it has cells, so changing one moves where the '
              'pages after it begin. An agent keeps its place either way.\n\n'
              'A page marked empty has no agents on it yet, so reshaping it '
              'changes nothing you can see until the pages before it fill. The '
              'desk panel and the boards always draw 4 x 4.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < listed; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _PageRow(
                page: i,
                shape: deckShapeOf(shapes, i),
                inUse: i < used,
                onShape: (sh) => onShape(i, sh),
              ),
            ],
            const SizedBox(height: 22),
            Text(
              'Swipe right for the deck. The page before its first one holds '
              'the agents that need you.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
          ],
        );
      },
    );
  }
}

/// One page's shape: its columns and its rows, each a stepper.
class _PageRow extends StatelessWidget {
  const _PageRow({
    required this.page,
    required this.shape,
    required this.inUse,
    required this.onShape,
  });

  final int page;
  final DeckShape shape;

  /// False for a page no agent has reached yet: shown, but dimmed.
  final bool inUse;
  final void Function(DeckShape) onShape;

  @override
  Widget build(BuildContext context) {
    final ink = inUse ? DeckHud.ink : DeckHud.dim;
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
                  inUse ? 'page ${page + 1}' : 'page ${page + 1} \u00b7 empty',
                  style: DeckHud.mono(size: 13, color: ink),
                ),
              ),
              Text(
                'holds ${shape.cells}',
                style: DeckHud.mono(
                  size: 12,
                  color: inUse ? DeckHud.accent : DeckHud.dim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stepper(
                label: 'cols',
                value: shape.columns,
                onChange: (v) => onShape(DeckShape(v, shape.rows)),
              ),
              const SizedBox(width: 14),
              _Stepper(
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

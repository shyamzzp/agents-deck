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

class DeckApp extends StatefulWidget {
  const DeckApp({super.key});

  @override
  State<DeckApp> createState() => _DeckAppState();
}

class _DeckAppState extends State<DeckApp> {
  AgentsSource? _source;
  String? _path;
  String? _reason;
  bool _looked = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  /// Reads the bundle before connecting, so an unpaired app shows the pairing
  /// screen rather than a deck that can never arrive.
  Future<void> _check() async {
    final path = _path ?? await configPath();
    final (cfg, why) = AgentsConfig.load(env: const {}, paths: [path]);
    if (!mounted) return;
    setState(() {
      _path = path;
      _reason = why;
      _looked = true;
      if (cfg != null) _source ??= HttpAgentsClient(loadConfig: bundleLoader(path));
    });
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
              gridColumns: 5,
              gridRows: 5,
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

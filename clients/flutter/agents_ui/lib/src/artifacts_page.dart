// What the agents made.
//
// An agent's work leaves things behind that are meant to be looked at rather
// than read as code: a page, a document, a chart, a sheet. This is the deck's
// page of them, drawn as the deck draws its agents: a grid of tiles, newest
// first, each saying what it is and what made it.
//
// Tapping one opens it in the browser on the Mac the deck runs on: the phone
// cannot show the file itself, and the thing is on that computer anyway.

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'agents_app.dart' show AgentsEmptyTile;
import 'agents_client.dart';
import 'agents_model.dart';
import 'critter.dart';
import 'critter_look.dart';
import 'theme.dart';
import 'widgets.dart';

/// The kinds an artifact can be, in the order the filters offer them. "" is
/// all of them.
const artifactKinds = ['', 'link', 'page', 'document', 'image', 'sheet'];

/// The grid the artifacts are drawn in. Seven across on a tablet, which has
/// the width for it; four on a phone, where seven tiles to a row leaves each
/// one too narrow to read, and seven rows down instead.
///
/// Six rows on the tablet rather than seven: a taller tile has the room for a
/// name on two lines. Forty-two is then all the page holds, and the forty
/// third thing, which is the one longest since anybody opened it, is not
/// shown at all.
DeckShape artifactShapeFor(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= 600
    ? const DeckShape(7, 6)
    : const DeckShape(4, 7);

class ArtifactsPage extends StatefulWidget {
  const ArtifactsPage({
    super.key,
    required this.source,
    this.kind = '',
    this.onKind,
    this.shape,
  });

  final AgentsSource source;

  /// Which kind is shown: one of [artifactKinds], "" for all of them. The
  /// host keeps it, so the page opens on the same one next time.
  final String kind;
  final void Function(String kind)? onKind;

  /// The grid it is drawn in; null takes the shape this screen has room for
  /// ([artifactShapeFor]).
  final DeckShape? shape;

  @override
  State<ArtifactsPage> createState() => _ArtifactsPageState();
}

/// How often the page asks the deck again. The deck sweeps what the agents
/// made every fifteen seconds and hands back what it has in a few
/// milliseconds, so the page can keep up with it: a page opened and left
/// alone still shows what was opened since, in the order it was opened, and
/// every tile's "7m" turns into "8m" where it stands.
const _retime = Duration(seconds: 20);

class _ArtifactsPageState extends State<ArtifactsPage> {
  /// What the last answer held, kept across a reload so the page never blinks
  /// back to "looking…" while the next one is on its way.
  List<AgentArtifact>? _made;
  Object? _trouble;

  /// The clock the tiles read their times off.
  DateTime _now = DateTime.now();
  Timer? _clock;

  /// The one the deck is opening now, and what went wrong with the last one.
  String? _opening;
  String? _note;

  @override
  void initState() {
    super.initState();
    _ask();
    _clock = Timer.periodic(_retime, (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _ask();
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  /// Asks the deck what there is, and keeps what it had until the answer
  /// comes back.
  Future<void> _ask() async {
    try {
      final made = await widget.source.artifacts();
      if (!mounted) return;
      setState(() {
        _made = made;
        _trouble = null;
        _now = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _trouble = e);
    }
  }

  Future<void> _reload() async {
    setState(() => _note = null);
    await _ask();
  }

  Future<void> _open(AgentArtifact a) async {
    setState(() {
      _opening = a.path;
      _note = null;
    });
    final r = await widget.source.openArtifact(a.path);
    if (!mounted) return;
    setState(() {
      _opening = null;
      _note = r.isOk ? null : (r.message ?? 'could not open it');
    });
  }

  @override
  Widget build(BuildContext context) {
    final tight = MediaQuery.sizeOf(context).width < 480;
    final shape = widget.shape ?? artifactShapeFor(context);
    return Padding(
      key: const Key('artifacts-page'),
      padding: tight
          ? const EdgeInsets.fromLTRB(8, 14, 8, 8)
          : const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'artifacts',
                style: DeckHud.rm(22, DeckHud.ink, weight: 700, spacing: -0.3),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'opens on the Mac',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DeckHud.mono(size: 11, color: DeckHud.dim),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // What to show: kept by the host, so the page opens on the same
          // one next time.
          // Six kinds do not fit across a phone, so they wrap rather than
          // run off the edge.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final kind in artifactKinds) ...[
                Pressable(
                  key: Key('artifact-kind-${kind.isEmpty ? 'all' : kind}'),
                  onTap: () => widget.onKind?.call(kind),
                  builder: (context, pressed) {
                    final on = kind == widget.kind;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: on ? DeckHud.ink : null,
                        border: Border.all(
                          color: on || pressed ? DeckHud.ink : DeckHud.dim,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        kind.isEmpty ? 'all' : kind,
                        style: DeckHud.mono(
                          size: 11,
                          color: on ? DeckHud.bg : DeckHud.dim,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
          if (_note case final n?) ...[
            const SizedBox(height: 6),
            Text(n, style: DeckHud.mono(size: 11, color: DeckHud.accent)),
          ],
          // Air between the row of kinds and the grid under it.
          const SizedBox(height: 16),
          Expanded(
            child: ValueListenableBuilder<AgentsSnapshot>(
              valueListenable: widget.source.snapshot,
              builder: (context, deck, _) {
                final all = _made;
                if (all == null) {
                  if (_trouble case final e?) {
                    return Text(
                      'could not ask the deck: $e',
                      key: const Key('artifacts-error'),
                      style: DeckHud.mono(size: 12, color: DeckHud.accent),
                    );
                  }
                  return Text(
                    'looking…',
                    style: DeckHud.mono(size: 12, color: DeckHud.dim),
                  );
                }
                final made = [
                  for (final m in all)
                    if (widget.kind.isEmpty || m.kind == widget.kind) m,
                ];
                if (made.isEmpty) {
                  return Text(
                    all.isEmpty
                        ? 'nothing yet. A page, a document or a chart an '
                              'agent writes shows up here.'
                        : 'nothing of that kind yet.',
                    key: const Key('artifacts-empty'),
                    style: DeckHud.mono(size: 12, color: DeckHud.dim),
                  );
                }
                final room = shape.cells;
                return DeckGrid(
                  key: const Key('artifacts-grid'),
                  square: false,
                  columns: shape.columns,
                  rows: shape.rows,
                  cells: [
                    for (var i = 0; i < room; i++)
                      if (i < made.length)
                        _ArtifactTile(
                          key: Key('artifact-$i'),
                          made: made[i],
                          // Whose it is, so the tile can wear its mascot.
                          by: deck.state?.byId(made[i].agent),
                          small: shape.columns >= 7,
                          now: _now,
                          opening: _opening == made[i].path,
                          onTap: () => _open(made[i]),
                        )
                      else
                        const AgentsEmptyTile(key: Key('artifact-empty')),
                  ],
                );
              },
            ),
          ),
          // Asking the deck again, under the grid where it is out of the
          // way: the page keeps itself up to date, so this is for when you
          // want it now rather than in a few seconds.
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Pressable(
                  key: const Key('artifacts-reload'),
                  onTap: _reload,
                  builder: (context, pressed) => Text(
                    'refresh',
                    style:
                        DeckHud.mono(
                          size: 11,
                          color: pressed ? DeckHud.accent : DeckHud.dim,
                        ).copyWith(
                          decoration: TextDecoration.underline,
                          decorationColor: pressed
                              ? DeckHud.accent
                              : DeckHud.dim,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One thing made, as a tile of the deck's own grid: what it is, what it is
/// called, and how long ago it was written.
class _ArtifactTile extends StatelessWidget {
  const _ArtifactTile({
    super.key,
    required this.made,
    required this.opening,
    required this.onTap,
    required this.now,
    this.by,
    this.small = false,
  });

  /// The moment the page is drawing, which moves on its own (the page
  /// retimes itself), so "7m" becomes "8m" without anybody touching it.
  final DateTime now;

  /// Drawn for a seven-across grid: the same tile with less in it.
  final bool small;

  final AgentArtifact made;

  /// The agent that made it, where it is still on the deck: the tile wears
  /// its mascot, hat and all, so a glance says whose work this is.
  final Agent? by;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, pressed) {
      final on = pressed || opening;
      final ink = on ? DeckHud.bg : DeckHud.ink;
      return Container(
        color: on ? DeckHud.ink : DeckHud.panel,
        // The same air on both sides: the time stands off the right edge by
        // what the kind stands off the left.
        padding: const EdgeInsets.all(4),
        child: LayoutBuilder(
          builder: (context, box) {
            // The deck's tile is drawn for a cell about 120 points across.
            // A narrower one (a phone's four to a row) takes everything down
            // with it; a wider one keeps the drawn size rather than blowing
            // the mascot up.
            //
            // The cell itself is the width the row is laid out in, so the
            // time ends where the tile ends: the fixed box it used to be
            // drawn in was narrower than the cell, and left the time short
            // of the edge by whatever the cell had spare.
            final scale = (box.maxWidth / 120).clamp(0.5, 1.0);
            // A phone's tile is drawn at about three quarters of the design
            // size, so its numbers start higher to land where the tablet's
            // do: what the eye gets is the same small tile either way.
            final meta = (small ? 8.0 : 10.5) * scale;
            final label = (small ? 9.0 : 11.5) * scale;
            final mascot = (small ? 54.0 : 64.0) * scale;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // What it is on the left, when it was last opened on the
                // right, hard against the tile's own edges.
                Row(
                  children: [
                    Text(
                      made.kind,
                      maxLines: 1,
                      style: DeckHud.mono(
                        size: meta,
                        color: on ? DeckHud.bg : DeckHud.accent,
                      ),
                    ),
                    const Spacer(),
                    if (made.at case final wrote?)
                      Text(
                        _ago(wrote, now),
                        maxLines: 1,
                        style: DeckHud.mono(
                          size: meta,
                          color: on ? DeckHud.bg : DeckHud.dim,
                        ),
                      ),
                  ],
                ),
                // Its maker, at the size the deck draws its agents, taking
                // whatever the tile has left between the two lines.
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: by == null
                          ? CritterSprite(
                              pose: CritterPose.read,
                              width: mascot,
                              centerBody: true,
                              showBubble: false,
                              body: on ? DeckHud.bg : DeckHud.dim,
                              cut: on ? DeckHud.ink : DeckHud.panel,
                            )
                          : agentMascot(
                              by!,
                              pose: CritterPose.idle,
                              width: mascot,
                              centerBody: true,
                              showBubble: false,
                              body: on ? DeckHud.bg : DeckHud.ink,
                              cut: on ? DeckHud.ink : DeckHud.panel,
                            ),
                    ),
                  ),
                ),
                Text(
                  opening ? 'opening…' : made.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: DeckHud.mono(size: label, color: ink),
                ),
              ],
            );
          },
        ),
      );
    },
  );
}

/// The ask-again glyph: a ring broken at the top with an arrow head on it,
/// drawn square like everything else on the deck rather than set as a word.
/// How long ago it was opened, in the deck's own short way.
String _ago(DateTime at, DateTime now) {
  final d = now.difference(at.toLocal());
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inHours < 48) return '${d.inHours}h';
  return '${d.inDays}d';
}

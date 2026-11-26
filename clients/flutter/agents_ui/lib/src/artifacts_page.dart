// What the agents made.
//
// An agent's work leaves things behind that are meant to be looked at rather
// than read as code: a page, a document, a chart, a sheet. This is the deck's
// page of them, drawn as the deck draws its agents: a grid of tiles, newest
// first, each saying what it is and what made it.
//
// Tapping one opens it in the browser on the Mac the deck runs on: the phone
// cannot show the file itself, and the thing is on that computer anyway.

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
DeckShape artifactShapeFor(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= 600
    ? const DeckShape(7, 7)
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

class _ArtifactsPageState extends State<ArtifactsPage> {
  late Future<List<AgentArtifact>> _made = widget.source.artifacts();

  /// The one the deck is opening now, and what went wrong with the last one.
  String? _opening;
  String? _note;

  Future<void> _reload() async {
    setState(() {
      _note = null;
      _made = widget.source.artifacts();
    });
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
              Pressable(
                key: const Key('artifacts-reload'),
                onTap: _reload,
                builder: (context, pressed) => Text(
                  'refresh',
                  style: DeckHud.mono(
                    size: 11,
                    color: pressed ? DeckHud.accent : DeckHud.dim,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // What to show: kept by the host, so the page opens on the same
          // one next time.
          Row(
            children: [
              for (final kind in artifactKinds) ...[
                if (kind != artifactKinds.first) const SizedBox(width: 6),
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
              builder: (context, deck, _) => FutureBuilder<List<AgentArtifact>>(
                future: _made,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Text(
                      'could not ask the deck: ${snap.error}',
                      key: const Key('artifacts-error'),
                      style: DeckHud.mono(size: 12, color: DeckHud.accent),
                    );
                  }
                  final all = snap.data;
                  if (all == null) {
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
    this.by,
  });

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
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topLeft,
          child: SizedBox(
            // A tile of the design grid, scaled to whatever cell it lands in,
            // so a 7 x 7 page and a 4 x 4 one read the same.
            width: 120,
            height: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // What it is on the left, when it was last written on the
                // right, as far apart as the tile allows.
                Row(
                  children: [
                    Text(
                      made.kind,
                      maxLines: 1,
                      style: DeckHud.mono(
                        size: 13,
                        color: on ? DeckHud.bg : DeckHud.accent,
                      ),
                    ),
                    const Spacer(),
                    if (made.at case final wrote?)
                      Text(
                        _ago(wrote),
                        style: DeckHud.mono(
                          size: 13,
                          color: on ? DeckHud.bg : DeckHud.dim,
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                // Its maker, at the size the deck draws its agents: the
                // mascot is what the eye lands on, here as on the board. A
                // published Artifact nobody on the deck still owns gets the
                // reading critter instead.
                Center(
                  child: by == null
                      ? CritterSprite(
                          pose: CritterPose.read,
                          width: 86,
                          centerBody: true,
                          showBubble: false,
                          body: on ? DeckHud.bg : DeckHud.dim,
                          cut: on ? DeckHud.ink : DeckHud.panel,
                        )
                      : agentMascot(
                          by!,
                          pose: CritterPose.idle,
                          width: 86,
                          centerBody: true,
                          showBubble: false,
                          body: on ? DeckHud.bg : DeckHud.ink,
                          cut: on ? DeckHud.ink : DeckHud.panel,
                        ),
                ),
                const Spacer(),
                Text(
                  opening ? 'opening…' : made.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: DeckHud.mono(size: 14, color: ink),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// How long ago it was written, in the deck's own short way.
String _ago(DateTime at) {
  final d = DateTime.now().difference(at.toLocal());
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inHours < 48) return '${d.inHours}h';
  return '${d.inDays}d';
}

// What the agents made.
//
// An agent's work leaves things behind that are meant to be looked at rather
// than read as code: a page, a document, a chart, a sheet. This is the deck's
// page of them, newest first, each saying what made it and where it sits.
//
// Tapping one opens it in the browser on the Mac the deck runs on: the phone
// cannot show the file itself, and the thing is on that computer anyway.

import 'package:flutter/widgets.dart';

import 'agents_client.dart';
import 'agents_model.dart';
import 'theme.dart';
import 'widgets.dart';

class ArtifactsPage extends StatefulWidget {
  const ArtifactsPage({super.key, required this.source});

  final AgentsSource source;

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
    return Padding(
      key: const Key('artifacts-page'),
      padding: tight
          ? const EdgeInsets.fromLTRB(14, 18, 14, 10)
          : const EdgeInsets.fromLTRB(24, 24, 24, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'made',
                style: DeckHud.rm(25, DeckHud.ink, weight: 700, spacing: -0.3),
              ),
              const Spacer(),
              Pressable(
                key: const Key('artifacts-reload'),
                onTap: _reload,
                builder: (context, pressed) => Text(
                  'refresh',
                  style: DeckHud.mono(
                    size: 13,
                    color: pressed ? DeckHud.accent : DeckHud.dim,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'pages, documents and charts the agents wrote. Tapping one opens '
            'it in the browser on the Mac.',
            style: DeckHud.mono(size: 12, color: DeckHud.dim),
          ),
          if (_note case final n?) ...[
            const SizedBox(height: 8),
            Text(n, style: DeckHud.mono(size: 12, color: DeckHud.accent)),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<AgentArtifact>>(
              future: _made,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text(
                    'could not ask the deck: ${snap.error}',
                    key: const Key('artifacts-error'),
                    style: DeckHud.mono(size: 13, color: DeckHud.accent),
                  );
                }
                final made = snap.data;
                if (made == null) {
                  return Text(
                    'looking…',
                    style: DeckHud.mono(size: 13, color: DeckHud.dim),
                  );
                }
                if (made.isEmpty) {
                  return Text(
                    'nothing yet. A page, a document or a chart an agent '
                    'writes shows up here.',
                    key: const Key('artifacts-empty'),
                    style: DeckHud.mono(size: 13, color: DeckHud.dim),
                  );
                }
                return ListView.separated(
                  key: const Key('artifacts-list'),
                  padding: EdgeInsets.zero,
                  itemCount: made.length,
                  separatorBuilder: (context, i) => const SizedBox(height: 6),
                  itemBuilder: (context, i) => _ArtifactRow(
                    key: Key('artifact-$i'),
                    made: made[i],
                    opening: _opening == made[i].path,
                    onTap: () => _open(made[i]),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Swipe for the deck.',
            style: DeckHud.mono(size: 12, color: DeckHud.dim),
          ),
        ],
      ),
    );
  }
}

/// How long ago it was written, in the deck's own short way.
String _ago(DateTime at) {
  final d = DateTime.now().difference(at.toLocal());
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inHours < 48) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// One thing made: what it is called, what made it, and where it sits.
class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({
    super.key,
    required this.made,
    required this.opening,
    required this.onTap,
  });

  final AgentArtifact made;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, pressed) {
      final on = pressed || opening;
      final ink = on ? DeckHud.bg : DeckHud.ink;
      return Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
        color: on ? DeckHud.ink : DeckHud.panel,
        child: Row(
          children: [
            // What kind of thing it is, in a word rather than an icon.
            SizedBox(
              width: 64,
              child: Text(
                made.kind,
                maxLines: 1,
                style: DeckHud.mono(
                  size: 11,
                  color: on ? DeckHud.bg : DeckHud.accent,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    opening ? 'opening…' : made.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.mono(size: 13, color: ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (made.title.isNotEmpty) made.title,
                      if (made.folder.isNotEmpty) made.folder,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.mono(
                      size: 11,
                      color: on ? DeckHud.bg : DeckHud.dim,
                    ),
                  ),
                ],
              ),
            ),
            if (made.at case final wrote?) ...[
              const SizedBox(width: 8),
              Text(
                _ago(wrote),
                maxLines: 1,
                style: DeckHud.mono(
                  size: 11,
                  color: on ? DeckHud.bg : DeckHud.dim,
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

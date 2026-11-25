import 'package:flutter/material.dart';

import 'agent_detail.dart' show CardBackButton;
import 'agents_client.dart';
import 'agents_model.dart';
import 'critter.dart';
import 'theme.dart';
import 'widgets.dart';

/// "add a session": Claude sessions started by hand in other terminals, opened
/// from a free cell of the deck. The one you pick goes into that cell
/// ([slot]), watched: status, context and cost; you answer it in its own
/// terminal.
class LivePicker extends StatefulWidget {
  const LivePicker({
    super.key,
    required this.source,
    required this.slot,
    required this.onClose,
    this.showBack = false,
  });

  final AgentsSource source;
  final int slot;
  final VoidCallback onClose;

  /// A ‹ button at the bottom, for hosts without an edge swipe.
  final bool showBack;

  @override
  State<LivePicker> createState() => _LivePickerState();
}

class _LivePickerState extends State<LivePicker> {
  late Future<List<LiveSession>> _sessions = widget.source.liveSessions();

  /// How far it has been dragged sideways, for the swipe that closes it.
  double _swipe = 0;
  String? _adding;
  String? _note;

  Future<void> _add(LiveSession s) async {
    setState(() {
      _adding = s.sessionId;
      _note = null;
    });
    final r = await widget.source.addLive(s.sessionId, slot: widget.slot);
    if (!mounted) return;
    if (r.isOk) {
      widget.onClose();
    } else {
      setState(() {
        _adding = null;
        _note = r.message ?? 'failed';
        _sessions = widget.source.liveSessions();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Dragged to the right, it closes, as an agent's card does: a sheet
      // over the deck should go the same way as everything else over it.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) => _swipe += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final away =
            _swipe > 80 || (d.primaryVelocity ?? 0) > 420 && _swipe > 24;
        _swipe = 0;
        if (away) widget.onClose();
      },
      onHorizontalDragCancel: () => _swipe = 0,
      child: Container(
        key: const Key('live-picker'),
        decoration: BoxDecoration(
          color: DeckHud.bg,
          borderRadius: BorderRadius.zero,
        ),
        // 14 each side on a phone: 36 was a fifth of its width spent on
        // air, and the session names are what paid for it.
        padding: DeckCompact.of(context)
            ? const EdgeInsets.fromLTRB(14, 20, 14, 18)
            : const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CritterSprite(
              pose: CritterPose.wait,
              width: 54,
              body: DeckHud.ink,
              cut: DeckHud.bg,
            ),
            const SizedBox(height: 10),
            Text(
              'add a session',
              style: DeckHud.rm(25, DeckHud.ink, weight: 700, spacing: -0.3),
            ),
            const SizedBox(height: 10),
            Text(
              'claude sessions running in your own terminals. added ones are '
              'watched: status, context and cost; answer them in their terminal.',
              style: DeckHud.mono(
                size: 13,
                color: DeckHud.dim,
              ).copyWith(height: 1.4),
            ),
            const SizedBox(height: 22),
            Expanded(
              child: FutureBuilder<List<LiveSession>>(
                future: _sessions,
                builder: (context, snap) {
                  if (snap.hasError) {
                    // A device paired to look only, or one the deck refused:
                    // saying "none running" would be a lie.
                    return Text(
                      'could not read the sessions: ${snap.error}',
                      key: const Key('live-error'),
                      style: DeckHud.mono(size: 13, color: DeckHud.accent),
                    );
                  }
                  if (!snap.hasData) {
                    return Text(
                      'looking…',
                      style: DeckHud.mono(size: 13, color: DeckHud.dim),
                    );
                  }
                  final list = snap.data!;
                  if (list.isEmpty) {
                    return Text(
                      'no other claude sessions running in your terminals',
                      key: const Key('live-empty'),
                      style: DeckHud.mono(size: 13, color: DeckHud.dim),
                    );
                  }
                  return ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) => _row(list[i]),
                  );
                },
              ),
            ),
            if (_note != null) ...[
              const SizedBox(height: 10),
              Text(
                _note!,
                style: DeckHud.mono(size: 13, color: DeckHud.accent),
              ),
            ],
            if (widget.showBack) ...[
              const SizedBox(height: 18),
              CardBackButton(
                onTap: widget.onClose,
                ink: DeckHud.ink,
                outline: DeckHud.dim,
                pressedFill: DeckHud.ink,
                pressedInk: DeckHud.bg,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(LiveSession s) {
    final busy = _adding == s.sessionId;
    final label = s.onBoard ? 'on the deck' : (busy ? 'adding…' : 'add');
    return Pressable(
      key: Key('live-${s.sessionId}'),
      onTap: s.onBoard || _adding != null ? null : () => _add(s),
      builder: (context, pressed) => Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: BoxDecoration(
          color: pressed ? DeckHud.ink : DeckHud.panel,
          borderRadius: BorderRadius.zero,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title.isEmpty ? s.folder : s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.rm(
                      15,
                      pressed ? DeckHud.bg : DeckHud.ink,
                      weight: 600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.background ? '${s.folder} · background' : s.folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.mono(
                      size: 12,
                      color: pressed ? DeckHud.bg : DeckHud.dim,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: DeckHud.mono(
                size: 13,
                color: s.onBoard
                    ? DeckHud.dim
                    : (pressed ? DeckHud.bg : DeckHud.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

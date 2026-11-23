import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';
import 'agents_client.dart';
import 'agents_model.dart';
import 'agents_style.dart';
import 'critter.dart';

/// How long the "sent" invert holds before the card closes itself.
const _sentHold = Duration(milliseconds: 600);

/// Feedback on the button that was pressed last.
enum _Flash { sent, error }

/// Full-screen card for one agent. Follows the live state: a prompt that
/// appears, changes or gets answered at the terminal swaps the layout in
/// place; an agent that disappears shows "gone" and the card closes.
///
/// * running / idle / error / exited / starting — dark overview.
/// * waiting · permission — accent card, one big button per option; a tap
///   answers at once.
/// * waiting · question — dark card with an accent frame; pick a row, send.
/// * waiting · input — free text can't be typed here: focus the terminal.
class AgentDetail extends StatefulWidget {
  const AgentDetail({
    super.key,
    required this.source,
    required this.agentId,
    required this.onClose,
    this.onVisible,
    this.showBack = false,
  });

  final AgentsSource source;
  final String agentId;
  final VoidCallback onClose;

  /// Mounted (true) / unmounted (false) — the grid pauses its critters
  /// while the card covers it.
  final ValueChanged<bool>? onVisible;

  /// A back button left of the mascot, for hosts without an edge swipe
  /// (the menu bar app). The desk panel closes cards with its swipe.
  final bool showBack;

  @override
  State<AgentDetail> createState() => _AgentDetailState();
}

class _AgentDetailState extends State<AgentDetail> {
  /// Prompt the per-prompt UI state (selection, notes) belongs to.
  String? _promptId;
  String? _selected;

  /// A command is in flight (or succeeded and the card is about to close).
  bool _busy = false;

  /// The hat picker is open (tap the mascot).
  bool _hats = false;

  /// "stop" on a live agent needs a second tap; this arms it for a few seconds.
  bool _confirmStop = false;
  Timer? _confirmTimer;

  /// "continue on …" armed for its second tap (the account's name).
  String? _confirmHandoff;

  /// The Claude accounts set up on the Mac, fetched when the card opens on
  /// an agent that has one (null until then).
  List<AgentAccount>? _accounts;
  bool _closing = false;

  /// Which control flashes, and how (key = option key, 'focus', 'interrupt',
  /// 'send').
  String? _flashKey;
  _Flash? _flash;

  /// One-line feedback ("prompt changed", "timed out").
  String? _note;
  Timer? _timer;
  bool _goneScheduled = false;

  /// What the last build showed (frozen while closing).
  (AgentsState, Agent, AgentPrompt?)? _shown;

  @override
  void initState() {
    super.initState();
    widget.onVisible?.call(true);
    final a = widget.source.snapshot.value.state?.byId(widget.agentId);
    if (a?.account != null) {
      unawaited(
        widget.source.accounts().then((list) {
          if (mounted) setState(() => _accounts = list);
        }),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _confirmTimer?.cancel();
    widget.onVisible?.call(false);
    super.dispose();
  }

  void _syncPrompt(AgentPrompt? p) {
    if (p?.id == _promptId) return;
    _promptId = p?.id;
    _selected = p == null
        ? null
        : (p.options.where((o) => o.primary).firstOrNull ??
                  p.options.firstOrNull)
              ?.key;
    if (!_closing) {
      _note = null;
      _flash = null;
      _flashKey = null;
    }
  }

  /// Runs [action] with the shared busy / flash / note handling; returns its
  /// result (null when another command was still in flight).
  Future<AgentsResult?> _run(
    String key,
    Future<AgentsResult> Function() action, {
    bool closeOnOk = false,
  }) async {
    if (_busy || _closing) return null;
    final asked = _promptId;
    setState(() {
      _busy = true;
      _flashKey = key;
      _flash = null;
      _note = null;
    });
    final r = await action();
    if (!mounted) return r;
    _timer?.cancel();
    switch (r.kind) {
      case AgentsResultKind.ok:
        // A question form's next step already showed up: stay on the card.
        if (closeOnOk && _promptId != asked && _liveQuestion() != null) {
          closeOnOk = false;
        }
        setState(() {
          _flash = _Flash.sent;
          _closing = closeOnOk;
          _busy = closeOnOk;
        });
        _timer = Timer(
          closeOnOk ? _sentHold : const Duration(milliseconds: 450),
          () {
            if (!mounted) return;
            if (closeOnOk) {
              widget.onClose();
            } else {
              setState(() => _flash = null);
            }
          },
        );
      case AgentsResultKind.conflict:
        setState(() {
          _busy = false;
          _flash = null;
          _note = 'prompt changed';
        });
        unawaited(widget.source.refresh());
      case AgentsResultKind.rejected:
      case AgentsResultKind.failed:
        setState(() {
          _busy = false;
          _flash = _Flash.error;
          _note = r.message ?? 'failed';
        });
        _timer = Timer(const Duration(milliseconds: 450), () {
          if (mounted) setState(() => _flash = null);
        });
    }
    return r;
  }

  void _answer(Agent a, AgentPrompt p, String key) =>
      _run(key, () => widget.source.answer(a.id, p.id, key), closeOnOk: true);

  void _focus(Agent a) => _run('focus', () => widget.source.focus(a.id));

  void _interrupt(Agent a) =>
      _run('interrupt', () => widget.source.interrupt(a.id));

  void _resume(Agent a) => _run('resume', () => widget.source.resume(a.id));

  /// Accounts the agent's conversation could move to (every one but its own).
  List<AgentAccount> _otherAccounts(Agent a) => [
    if (a.canHandoff)
      for (final acc in _accounts ?? const <AgentAccount>[])
        if (acc.name != a.account!.name) acc,
  ];

  /// What "continue on [account]" does, from the user's side.
  static String _handoffNote(Agent a, String account) => a.external
      ? 'starts a copy in $account; this terminal keeps running'
      : 'stops it and continues the conversation in $account';

  /// Continues the conversation in another account, on a second tap.
  Future<void> _handoff(Agent a, AgentAccount to) async {
    if (_confirmHandoff != to.name) {
      _confirmTimer?.cancel();
      setState(() {
        _confirmHandoff = to.name;
        _confirmStop = false;
        _note = null;
      });
      _confirmTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _confirmHandoff = null);
      });
      return;
    }
    _confirmTimer?.cancel();
    _confirmHandoff = null;
    final r = await _run('handoff:${to.name}', () async {
      final r = await widget.source.handoff(a.id, to.name);
      // Not a prompt answer: a 409/400 here is a plain refusal.
      return r.isOk ? r : AgentsResult(AgentsResultKind.failed, r.message);
    });
    if (mounted && a.external && (r?.isOk ?? false)) {
      setState(() => _note = 'started in ${to.name}');
    }
  }

  /// Exited agents go at once; a live agent is stopped only on a second tap.
  void _dismiss(Agent a) {
    if (a.status != AgentStatus.exited && !a.external && !_confirmStop) {
      _confirmTimer?.cancel();
      setState(() {
        _confirmStop = true;
        _confirmHandoff = null;
      });
      _confirmTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _confirmStop = false);
      });
      return;
    }
    _confirmTimer?.cancel();
    _confirmStop = false;
    _run('dismiss', () => widget.source.dismiss(a.id), closeOnOk: true);
  }

  Widget _removeButton(Agent a, (Color, Color)? flash) {
    final exited = a.status == AgentStatus.exited;
    final armed = _confirmStop && !exited;
    return AgentButton(
      key: const Key('agent-remove'),
      label: _flashKey == 'dismiss' && _flash == _Flash.sent
          ? 'removed'
          : a.codexThread || a.inApp
          ? 'hide'
          : a.watched
          ? 'remove from deck'
          : exited
          ? 'remove'
          : armed
          ? 'tap again to stop'
          : 'stop',
      onTap: _busy ? null : () => _dismiss(a),
      // Sized by its label on a phone, so the points it does not spend on air
      // go to "focus terminal" beside it.
      padX: 6,
      fill: flash?.$1 ?? (armed ? DeckHud.accent : const Color(0x00000000)),
      ink: flash?.$2 ?? (armed ? DeckHud.bg : DeckHud.ink),
      outline: flash?.$1 ?? (armed ? DeckHud.accent : DeckHud.dim),
      pressedFill: DeckHud.accent,
      pressedInk: DeckHud.bg,
    );
  }

  /// Colours for a control given the shared flash state.
  (Color, Color)? _flashColors(String key, {required bool onAccent}) {
    if (_flashKey != key || _flash == null) return null;
    return switch (_flash!) {
      _Flash.sent => (DeckHud.ink, DeckHud.bg),
      // Error = accent invert; on the accent card that would vanish, so it
      // inverts to ink-on-accent text instead.
      _Flash.error =>
        onAccent ? (DeckHud.bg, DeckHud.ink) : (DeckHud.accent, DeckHud.bg),
    };
  }

  /// The id of the question the agent waits on now, if it does. A question
  /// form (several questions, or ticking the answers of a pick-any one) comes
  /// one step at a time, each step a new prompt.
  String? _liveQuestion([AgentsSnapshot? snap]) {
    final a = (snap ?? widget.source.snapshot.value).state?.byId(
      widget.agentId,
    );
    final p = a?.status == AgentStatus.waiting ? a?.waiting : null;
    return p?.kind == PromptKind.question ? p!.id : null;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AgentsSnapshot>(
      valueListenable: widget.source.snapshot,
      builder: (context, snap, _) {
        final next = _closing ? _liveQuestion(snap) : null;
        if (next != null && next != _promptId) {
          // The answer opened the form's next step: show it instead of closing.
          _timer?.cancel();
          _closing = false;
          _busy = false;
        }
        // While an answer's "sent" holds, keep showing the prompt it
        // answered — the live state has usually moved on already.
        final frozen = _closing ? _shown : null;
        final state = frozen?.$1 ?? snap.state;
        final a = frozen?.$2 ?? state?.byId(widget.agentId);
        if (state == null || a == null) return _gone();
        if (_hats) return _hatPicker(a);
        final p = frozen != null
            ? frozen.$3
            : (a.status == AgentStatus.waiting ? a.waiting : null);
        if (frozen == null) {
          _syncPrompt(p);
          _shown = (state, a, p);
        }
        return switch (p?.kind) {
          PromptKind.permission => _permission(state, a, p!),
          PromptKind.question => _question(state, a, p!),
          PromptKind.input => _input(state, a, p!),
          null => _overview(state, a),
        };
      },
    );
  }

  // ---- shared pieces ---------------------------------------------------------

  Widget _card({required Color fill, Color? border, required Widget child}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.zero,
        border: border == null ? null : Border.all(color: border, width: 3),
      ),
      // Dragged to the right, the card goes back, as a phone's screens do.
      // The buttons at the bottom stay where they are, so the gesture is the
      // only way back that does not need them to be reachable.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => _swipe += d.delta.dx,
        onHorizontalDragEnd: (d) {
          final back =
              _swipe > 80 || (d.primaryVelocity ?? 0) > 420 && _swipe > 24;
          _swipe = 0;
          if (back) widget.onClose();
        },
        onHorizontalDragCancel: () => _swipe = 0,
        child: LayoutBuilder(
          builder: (context, box) {
            // A phone in portrait has little height. The padding closes up and
            // the buttons draw shorter, so the row at the bottom of the card
            // stays on the screen instead of being pushed off it. Scrolling
            // the card is not an option: each one puts its buttons at the
            // bottom with a Spacer, which needs a bounded height.
            final tight = box.maxHeight < 620 || box.maxWidth < 420;
            return DeckCompact(
              compact: tight,
              child: Stack(
                children: [
                  // Under the content, not around it: a double tap wrapped
                  // around the card puts every button on it behind the
                  // double-tap timeout, so taps that land on one are answered
                  // late or not at all. Beneath it, this is only reached by a
                  // tap no child took -- the empty space.
                  Positioned.fill(
                    child: GestureDetector(
                      key: const Key('card-empty'),
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: _openAsks,
                    ),
                  ),
                  Padding(
                    padding: tight
                        ? const EdgeInsets.fromLTRB(18, 16, 18, 14)
                        : const EdgeInsets.fromLTRB(36, 34, 36, 30),
                    child: child,
                  ),
                  if (_asks) Positioned.fill(child: _askSheet(tight)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// How far the card has been dragged sideways, for the swipe back.
  double _swipe = 0;

  /// Opens the quick list. Reached by a double tap on the title or on any
  /// empty part of the card.
  void _openAsks() => setState(() {
    _asks = true;
    _askSent = -1;
    _note = null;
  });

  /// The quick list: swipe through the asks, tap one to send it.
  ///
  /// It is a page per ask rather than a list, so a thumb can reach every one
  /// of them on a phone without stretching for a row near the top.
  Widget _askSheet(bool tight) {
    return ColoredBox(
      color: DeckHud.bg,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              tight ? 18 : 36,
              tight ? 14 : 24,
              12,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'ask it to\u2026',
                    style: DeckHud.rm(
                      tight ? 22 : 28,
                      DeckHud.ink,
                      weight: 700,
                    ),
                  ),
                ),
                GestureDetector(
                  key: const Key('asks-close'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _asks = false),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '\u00d7',
                      style: DeckHud.rm(26, DeckHud.dim, weight: 700),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The deck can only type into a session it started itself. A watched
          // one, running in someone else's terminal, refuses with 422 and
          // explains why -- so say it here rather than on every tap.
          if (_shown?.$2 case final a? when !a.canBeTold)
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  tight ? 18 : 36,
                  8,
                  tight ? 18 : 36,
                  8,
                ),
                child: Column(
                  key: const Key('asks-refused'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'this one cannot be told',
                      style: DeckHud.rm(
                        tight ? 18 : 22,
                        DeckHud.accent,
                        weight: 700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'It runs inside another app, which the deck cannot type '
                      'into. Give it tasks where it lives.\n\nA session in a '
                      'terminal is fine, including one you started yourself: '
                      'the deck types into iTerm through iTerm.',
                      style: DeckHud.mono(
                        size: tight ? 13 : 15,
                        color: DeckHud.dim,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: GridView.builder(
                key: const Key('asks-grid'),
                padding: EdgeInsets.fromLTRB(
                  tight ? 18 : 36,
                  tight ? 10 : 16,
                  tight ? 18 : 36,
                  tight ? 10 : 16,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: tight ? 2 : 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: tight ? 1.25 : 1.5,
                ),
                itemCount: agentAsks.length,
                itemBuilder: (context, i) {
                  final ask = agentAsks[i];
                  final sent = _askSent == i;
                  return GestureDetector(
                    key: Key('ask-$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _busy ? null : () => _ask(i),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: sent ? DeckHud.ink : DeckHud.panel,
                        border: Border.all(
                          color: sent ? DeckHud.ink : DeckHud.dim,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sent ? 'sent' : ask.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: DeckHud.rm(
                              tight ? 16 : 19,
                              sent ? DeckHud.bg : DeckHud.ink,
                              weight: 700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: Text(
                              ask.text,
                              overflow: TextOverflow.fade,
                              style: DeckHud.mono(
                                size: tight ? 11 : 12,
                                color: sent ? DeckHud.bg : DeckHud.dim,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          if (_note case final n?)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                n,
                style: DeckHud.mono(size: 14, color: DeckHud.accent),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, tight ? 12 : 20),
            child: Text(
              'Tapping one puts it on the agent\u2019s queue, so asking while '
              'it works does not cut the turn short.',
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
          ),
        ],
      ),
    );
  }

  /// Sends one ask, and says so on its card.
  Future<void> _ask(int i) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    // "now": typed into the session and entered, rather than queued behind
    // whatever it is doing.
    final r = await widget.source.prompt(
      widget.agentId,
      agentAsks[i].text,
      mode: 'now',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _askSent = r.isOk ? i : -1;
      _note = r.isOk ? null : (r.message ?? 'could not send');
    });
    if (r.isOk) {
      Timer(_sentHold, () {
        if (mounted) setState(() => _asks = false);
      });
    }
  }

  /// The quick list, opened by a double tap on the card.
  bool _asks = false;
  int _askSent = -1;

  // ---- hat picker ------------------------------------------------------------

  Future<void> _setHat(
    Agent a, {
    String? shape,
    String? color,
    bool auto = false,
  }) async {
    final r = await widget.source.setHat(
      a.id,
      shape: shape,
      color: color,
      auto: auto,
    );
    if (!mounted) return;
    setState(() => _note = r.isOk ? null : (r.message ?? 'failed'));
  }

  /// Every hat shape in the current colour, the colours, and "auto". A hat
  /// belongs to the working folder: every agent there wears it.
  Widget _hatPicker(Agent a) {
    final hat = a.hat ?? autoHatFor(a.cwd);
    return _card(
      fill: DeckHud.bg,
      child: Column(
        key: const Key('hat-picker'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              CritterSprite(
                pose: CritterPose.idle,
                species: critterSpeciesFor(a.tool),
                hat: a.hat,
                width: 54,
                body: DeckHud.ink,
                cut: DeckHud.bg,
              ),
              const SizedBox(width: 16),
              Text(
                'hat',
                style: DeckHud.rm(30, DeckHud.ink, weight: 700, spacing: -0.3),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'for ${tildePath(a.cwd)} · every agent working there wears it'
            '${a.hat?.auto ?? true ? ' · now automatic' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.mono(
              size: 15,
              color: DeckHud.dim,
            ).copyWith(height: 1.4),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final shape in hatShapes)
                Pressable(
                  key: Key('hat-shape-$shape'),
                  onTap: () => _setHat(a, shape: shape, color: hat.color),
                  builder: (context, pressed) => Container(
                    width: 84,
                    height: 80,
                    decoration: BoxDecoration(
                      color: pressed ? DeckHud.ink : DeckHud.panel,
                      borderRadius: BorderRadius.zero,
                      border: Border.all(
                        color: shape == hat.shape && !hat.auto
                            ? DeckHud.ink
                            : DeckHud.panel,
                        width: 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: CritterSprite(
                      pose: CritterPose.wait,
                      species: critterSpeciesFor(a.tool),
                      hat: AgentHat(shape: shape, color: hat.color),
                      showBubble: false,
                      centerBody: true,
                      width: 64,
                      body: pressed ? DeckHud.bg : DeckHud.dim,
                      cut: pressed ? DeckHud.ink : DeckHud.panel,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              for (final color in hatColors) ...[
                Pressable(
                  key: Key('hat-color-$color'),
                  onTap: () => _setHat(a, shape: hat.shape, color: color),
                  builder: (context, pressed) => Container(
                    width: 52,
                    height: 44,
                    decoration: BoxDecoration(
                      color: hatColor(color).$1,
                      borderRadius: BorderRadius.zero,
                      border: Border.all(
                        color: color == hat.color && !hat.auto || pressed
                            ? DeckHud.ink
                            : DeckHud.bg,
                        width: 3,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          const Spacer(),
          if (_note != null) ...[
            Text(_note!, style: DeckHud.mono(size: 15, color: DeckHud.accent)),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              ..._back(
                ink: DeckHud.ink,
                outline: DeckHud.dim,
                pressedFill: DeckHud.ink,
                pressedInk: DeckHud.bg,
              ),
              Expanded(
                child: AgentButton(
                  key: const Key('hat-auto'),
                  label: hat.auto ? 'automatic' : 'back to automatic',
                  onTap: hat.auto ? null : () => _setHat(a, auto: true),
                  fill: const Color(0x00000000),
                  ink: hat.auto ? DeckHud.dim : DeckHud.ink,
                  outline: DeckHud.dim,
                  pressedFill: DeckHud.ink,
                  pressedInk: DeckHud.bg,
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 200,
                child: AgentButton(
                  key: const Key('hat-done'),
                  label: 'done',
                  onTap: () => setState(() => _hats = false),
                  fill: DeckHud.ink,
                  ink: DeckHud.bg,
                  outline: DeckHud.ink,
                  pressedFill: DeckHud.accent,
                  pressedInk: DeckHud.bg,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _topBar(
    AgentsState state,
    Agent a, {
    required Color ink,
    required Color pillFill,
    required Color pillInk,
    required Color body,
    required Color cut,
  }) {
    // The clock, which sits against the mascot: the pose says which state
    // this is, the number says the deck is still hearing from it.
    final clock = Ticking(
      key: const Key('agent-pill'),
      // Ten frames a second is enough to read as moving without spending a
      // frame on every thousandth.
      every: const Duration(milliseconds: 100),
      // Bare text, no box: the number carries the state's colour instead,
      // which is what the fill was for.
      builder: (context) => Text(
        agentPillLabel(a, state),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DeckHud.mono(size: 15, color: pillFill),
      ),
    );
    // Whose it is, kept at the far end so the clock can have the mascot's
    // side to itself. The colour square that used to sit beside the clock is
    // gone: the critter is already drawn in the tool's own colour.
    final who = a.account == null
        ? const SizedBox.shrink()
        : ConstrainedBox(
            key: const Key('agent-account'),
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              a.account!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.mono(size: 15, color: ink),
            ),
          );
    // The status sits where the clock used to, beside the critter, so the
    // title below has the whole width. A phone has little of it to spare.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Tap the mascot to pick its hat.
            GestureDetector(
              key: const Key('agent-hat'),
              behavior: HitTestBehavior.opaque,
              onTap: a.cwd.isEmpty
                  ? null
                  : () => setState(() {
                      _hats = true;
                      _note = null;
                    }),
              child: CritterSprite(
                pose: critterPoseOf(a, inStatus: state.inStatus(a)),
                celebrateUntil: DateTime.now().add(
                  critterCelebration - state.inStatus(a),
                ),
                afterCelebrate: a.unseen
                    ? CritterPose.hungry
                    : CritterPose.idle,
                species: critterSpeciesFor(a.tool),
                hat: a.hat,
                width: 54,
                body: body,
                cut: cut,
              ),
            ),
            const SizedBox(width: 4),
            // Both sit on the row's bottom edge, so the clock lines up with
            // the mascot's feet rather than floating beside its head, and it
            // sits right against the sprite.
            Flexible(child: clock),
            const SizedBox(width: 12),
            Expanded(
              child: Align(alignment: Alignment.bottomRight, child: who),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Double tapping the title opens the quick list. It is on the title
        // and not on the card or the header because anything with a tap of
        // its own underneath a double tap -- a button, the mascot -- has to
        // wait out the double-tap timeout before it answers.
        GestureDetector(
          key: const Key('agent-title'),
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _openAsks,
          child: Text(
            a.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.rm(30, ink, weight: 700, spacing: -0.3),
          ),
        ),
      ],
    );
  }

  /// The back button at the start of a card's bottom row (hosts without an
  /// edge swipe): a square in the house button style, with a chevron.
  List<Widget> _back({
    required Color ink,
    required Color outline,
    required Color pressedFill,
    required Color pressedInk,
  }) => [
    if (widget.showBack) ...[
      CardBackButton(
        onTap: widget.onClose,
        ink: ink,
        outline: outline,
        pressedFill: pressedFill,
        pressedInk: pressedInk,
      ),
      const SizedBox(width: 14),
    ],
  ];

  /// The table's hairlines: the dim ink at a third, so the rules hold the
  /// figures apart without drawing the eye themselves.
  Color get _rule => DeckHud.dim.withValues(alpha: 0.35);

  Widget _label(String text, Color color) =>
      Text(text, style: DeckHud.mono(size: 14, color: color));

  /// Text link variant of "focus terminal" (prompt cards' footers).
  Widget _focusLink(Agent a, {required Color ink, required Color surface}) {
    final flash = _flashColors('focus', onAccent: surface == DeckHud.accent);
    return Pressable(
      key: const Key('agent-focus'),
      onTap: _closing ? null : () => _focus(a),
      builder: (context, pressed) {
        final fill = flash?.$1 ?? (pressed ? ink : null);
        final color = flash?.$2 ?? (pressed ? surface : ink);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: fill == null
              ? null
              : BoxDecoration(color: fill, borderRadius: BorderRadius.zero),
          child: Text(
            _flashKey == 'focus' && _flash == _Flash.sent
                ? 'focused'
                : 'focus terminal',
            style: DeckHud.mono(size: 15, color: color).copyWith(
              decoration: TextDecoration.underline,
              decorationColor: color,
            ),
          ),
        );
      },
    );
  }

  // ---- overview (not blocked) ----------------------------------------------

  Widget _overview(AgentsState state, Agent a) {
    final (pillFill, pillInk) = switch (a.status) {
      AgentStatus.running => (DeckHud.ink, DeckHud.bg),
      AgentStatus.error => (DeckHud.accent, DeckHud.bg),
      _ => (DeckHud.panel, DeckHud.ink),
    };
    final body = AgentLook.of(a).body;
    final (nowLabel, nowValue) = _doingNow(a);
    final footer = [
      a.modelLabel,
      tildePath(a.cwd),
      a.branch,
    ].where((s) => s.isNotEmpty).join(' · ');
    final running = a.status == AgentStatus.running;
    final exited = a.status == AgentStatus.exited;
    final focusFlash = _flashColors('focus', onAccent: false);
    final intFlash = _flashColors('interrupt', onAccent: false);
    final rmFlash = _flashColors('dismiss', onAccent: false);
    final resumeFlash = _flashColors('resume', onAccent: false);
    final others = _otherAccounts(a);
    final armed = others.where((x) => x.name == _confirmHandoff).firstOrNull;
    // On a phone the row's fixed widths do not fit: 68 for the back button,
    // 200 for the second action and two 14pt gaps leave the main action about
    // 60 points, most of which is its own padding. There the row is divided
    // by share instead, three parts to two.
    final tight = DeckCompact.of(context);
    // On a phone the second action is as wide as its own label and no wider,
    // and the main action takes everything that leaves. Flexible rather than
    // a bare child so a long label ("tap again to stop") still shrinks rather
    // than running the row off the card.
    Widget second(Widget button) => tight
        ? Flexible(fit: FlexFit.loose, child: button)
        : SizedBox(width: 200, child: button);
    return _card(
      fill: DeckHud.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(
            state,
            a,
            ink: DeckHud.ink,
            pillFill: pillFill,
            pillInk: pillInk,
            body: body,
            cut: DeckHud.bg,
          ),
          const SizedBox(height: 14),
          // Doing now, and how many subagents work for it on the right.
          Row(
            children: [
              Expanded(child: _label(nowLabel, DeckHud.dim)),
              if (a.subagents.isNotEmpty)
                Text(
                  subagentCount(a.subagents.length),
                  key: const Key('agent-subagent-count'),
                  style: DeckHud.mono(size: 14, color: DeckHud.dim),
                ),
            ],
          ),
          const SizedBox(height: 6),
          nowValue,
          if (_nowAside(state, a) case final aside?) ...[
            const SizedBox(height: 6),
            aside,
          ],
          // The working subagents, one to a row, like the boards draw them.
          if (a.subagents.isNotEmpty) ...[
            const SizedBox(height: 12),
            SubagentRows(
              subagents: a.subagents,
              body: body,
              cut: DeckHud.bg,
              // The other account's row below takes the room of two.
              maxRows: others.isEmpty ? 4 : 2,
            ),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('context', style: DeckHud.rm(22, DeckHud.ink, weight: 700)),
              const SizedBox(width: 12),
              Text(
                a.contextWindow > 0
                    ? '${compactCount(a.contextUsed)} / ${compactCount(a.contextWindow)}'
                    : '--',
                style: DeckHud.mono(size: 14, color: DeckHud.dim),
              ),
              const Spacer(),
              Text(
                a.contextWindow > 0 ? '${a.contextPercent}%' : '--',
                style: DeckHud.rm(22, DeckHud.ink, weight: 700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TickBar(value: a.contextFraction, color: DeckHud.ink),
          const SizedBox(height: 16),
          // Four figures as a table: one hairline round the lot and one
          // between each pair, so a column is a cell rather than a gap. Half
          // a point and a third of the dim ink: a rule has to be found rather
          // than seen, or it reads as heavier than the figures it holds.
          DecoratedBox(
            key: const Key('agent-figures'),
            decoration: BoxDecoration(
              border: Border.all(color: _rule, width: 0.5),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, (label, value)) in [
                    ('tokens out', compactCount(a.tokensOutput)),
                    ('cache read', compactCount(a.cacheRead)),
                    (
                      'cost · est',
                      a.codexThread ? '—' : '\$${a.costUsd.toStringAsFixed(2)}',
                    ),
                    ('turns', '${a.turns}'),
                  ].indexed)
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                        decoration: BoxDecoration(
                          border: i == 0
                              ? null
                              : Border(
                                  left: BorderSide(color: _rule, width: 0.5),
                                ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          // The label at the top of the cell and the figure on
                          // its floor: a cell whose label wraps to two lines
                          // would otherwise lift its figure above the rest.
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _label(label, DeckHud.dim),
                            const SizedBox(height: 6),
                            // 18, not 22: four of these across a phone was
                            // the widest thing on the card, and "3.1m" does
                            // not need to be read from across the desk.
                            Text(
                              value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DeckHud.rm(18, DeckHud.ink, weight: 600),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (state.lastActiveText(a) case final active when active.isNotEmpty)
            Row(
              children: [
                _label('last prompt', DeckHud.dim),
                const Spacer(),
                Text(
                  active,
                  key: const Key('agent-last-active'),
                  style: DeckHud.mono(size: 14, color: DeckHud.dim),
                ),
              ],
            )
          else
            _label('last prompt', DeckHud.dim),
          const SizedBox(height: 8),
          // As many lines of it as fit, and never none: what the agent was
          // last asked is half of why the card is open. On a phone that
          // leaves one line, clipped rather than dropped.
          Expanded(
            child: ClipRect(
              child: LayoutBuilder(
                builder: (context, box) {
                  const style = TextStyle(height: 1.45);
                  // Keep clear of the footer under it.
                  final lines = ((box.maxHeight - 10) / (17 * 1.45))
                      .floor()
                      .clamp(1, 4);
                  return Text(
                    a.lastPrompt.isEmpty ? '—' : a.lastPrompt,
                    key: const Key('agent-last-prompt'),
                    maxLines: lines,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.rm(17, DeckHud.ink).merge(style),
                  );
                },
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  _note ?? footer,
                  key: _note == null ? null : const Key('agent-note'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DeckHud.mono(
                    size: 14,
                    color: _note == null ? DeckHud.dim : DeckHud.accent,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Text(
                state.server.name,
                style: DeckHud.mono(size: 14, color: DeckHud.dim),
              ),
            ],
          ),
          // Another Claude account (when this one runs out of usage).
          if (others.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _handoffNote(a, (armed ?? others.first).name),
                    key: const Key('agent-handoff-note'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.mono(
                      size: 14,
                      color: armed == null ? DeckHud.dim : DeckHud.accent,
                    ),
                  ),
                ),
                for (final to in others) ...[
                  const SizedBox(width: 14),
                  if (tight)
                    Expanded(child: _handoffButton(a, to))
                  else
                    SizedBox(width: 240, child: _handoffButton(a, to)),
                ],
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              ..._back(
                ink: DeckHud.ink,
                outline: DeckHud.dim,
                pressedFill: DeckHud.ink,
                pressedInk: DeckHud.bg,
              ),
              if (!exited)
                Expanded(
                  child: AgentButton(
                    key: const Key('agent-focus'),
                    label: _flashKey == 'focus' && _flash == _Flash.sent
                        ? 'focused'
                        : a.codexThread
                        ? 'open in codex'
                        : a.inApp
                        ? 'open in ${a.app}'
                        : a.hungry
                        ? 'review in terminal'
                        : 'focus terminal',
                    onTap: _busy ? null : () => _focus(a),
                    fill: focusFlash?.$1 ?? DeckHud.ink,
                    ink: focusFlash?.$2 ?? DeckHud.bg,
                    outline: focusFlash?.$1 ?? DeckHud.ink,
                    pressedFill: DeckHud.accent,
                    pressedInk: DeckHud.bg,
                  ),
                ),
              if (running && (!a.external || a.inApp)) ...[
                const SizedBox(width: 14),
                second(
                  AgentButton(
                    key: const Key('agent-interrupt'),
                    label: _flashKey == 'interrupt' && _flash == _Flash.sent
                        ? 'sent'
                        : 'interrupt',
                    onTap: _busy ? null : () => _interrupt(a),
                    fill: intFlash?.$1 ?? const Color(0x00000000),
                    ink: intFlash?.$2 ?? DeckHud.ink,
                    outline: intFlash?.$1 ?? DeckHud.dim,
                    pressedFill: DeckHud.ink,
                    pressedInk: DeckHud.bg,
                  ),
                ),
              ] else if (exited && a.resumable) ...[
                Expanded(
                  child: AgentButton(
                    key: const Key('agent-resume'),
                    label: _flashKey == 'resume' && _flash == _Flash.sent
                        ? 'resuming'
                        : 'resume',
                    onTap: _busy ? null : () => _resume(a),
                    fill: resumeFlash?.$1 ?? DeckHud.ink,
                    ink: resumeFlash?.$2 ?? DeckHud.bg,
                    outline: resumeFlash?.$1 ?? DeckHud.ink,
                    pressedFill: DeckHud.accent,
                    pressedInk: DeckHud.bg,
                  ),
                ),
                const SizedBox(width: 14),
                second(_removeButton(a, rmFlash)),
              ] else if (exited)
                Expanded(child: _removeButton(a, rmFlash))
              else ...[
                const SizedBox(width: 14),
                second(_removeButton(a, rmFlash)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _handoffButton(Agent a, AgentAccount to) {
    final key = 'handoff:${to.name}';
    final flash = _flashColors(key, onAccent: false);
    final armed = _confirmHandoff == to.name;
    return AgentButton(
      key: Key('agent-handoff-${to.name}'),
      label: _flashKey == key && _flash == _Flash.sent
          ? (a.external ? 'started' : 'continuing')
          : armed
          ? 'tap again'
          : 'continue on ${to.name}',
      onTap: _busy ? null : () => _handoff(a, to),
      fill: flash?.$1 ?? (armed ? DeckHud.accent : const Color(0x00000000)),
      ink: flash?.$2 ?? (armed ? DeckHud.bg : DeckHud.ink),
      outline: flash?.$1 ?? (armed ? DeckHud.accent : DeckHud.dim),
      pressedFill: DeckHud.accent,
      pressedInk: DeckHud.bg,
      height: 52,
      fontSize: 16,
    );
  }

  /// The second line of "doing now": the things worth a glance that are not
  /// already a figure of their own below, each dropped when it has nothing to
  /// say. Joined with the deck's dot so a narrow phone can cut it anywhere.
  Widget? _nowAside(AgentsState state, Agent a) {
    // The context, the turn and the subagents are figures of their own
    // further down the card; repeating them here was saying it twice. What
    // belongs here is the call itself: which tool, as the agent named it.
    final act = a.activity;
    final bits = <String>[
      if (a.status == AgentStatus.running && act != null && act.tool.isNotEmpty)
        act.tool,
      if (a.queued > 0) '${a.queued} queued',
      if (state.upText(a) case final up when up.isNotEmpty) 'up $up',
      if (a.attached) 'attached',
      if (a.external) a.inApp ? 'watched · ${a.app}' : 'watched',
    ];
    if (bits.isEmpty) return null;
    return Text(
      bits.join(' · '),
      key: const Key('agent-now-aside'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DeckHud.mono(size: 13, color: DeckHud.dim),
    );
  }

  (String, Widget) _doingNow(Agent a) {
    Widget line(String text, {Color? color, int lines = 1}) => Text(
      text,
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
      style: DeckHud.rm(20, color ?? DeckHud.ink),
    );
    switch (a.status) {
      case AgentStatus.running:
        final act = a.activity;
        if (act == null) return ('doing now', line('thinking'));
        return (
          'doing now',
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: act.verb),
                if (act.detail.isNotEmpty) ...[
                  TextSpan(
                    text: ' · ',
                    style: TextStyle(color: DeckHud.dim),
                  ),
                  // What the call touches is small print: a command or a path
                  // runs long, and the verb is what is read first.
                  TextSpan(
                    text: act.detail,
                    style: DeckHud.rm(13, DeckHud.ink),
                  ),
                ],
              ],
            ),
            // Three lines of it, now that it is smaller: a path or a command
            // is the thing you came to read, and one line of a phone's width
            // cuts most of them off.
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.rm(17, DeckHud.ink),
            // The verb is 17 and the detail 13, so without a strut the line
            // holding the verb is taller than the ones under it. Forced to
            // the larger of the two, every line of the paragraph is the same
            // height whichever sizes happen to fall on it.
            strutStyle: StrutStyle(
              fontFamily: 'RobotoMono',
              // The panel registers the same faces itself and sets this to
              // null; naming the package there would miss the font and take
              // the strut's metrics from a fallback.
              package: DeckHud.fontPackage,
              fontSize: 17,
              height: 1.25,
              forceStrutHeight: true,
            ),
          ),
        );
      case AgentStatus.error:
        return (
          'error',
          line(a.errorMessage ?? 'error', color: DeckHud.accent, lines: 2),
        );
      case AgentStatus.starting:
        return (
          'starting',
          line('launching ${a.tool.isEmpty ? 'agent' : a.tool}…'),
        );
      case AgentStatus.idle:
      case AgentStatus.exited:
      case AgentStatus.unknown:
      case AgentStatus.waiting:
        final t = a.aiTitle.isNotEmpty ? a.aiTitle : a.folder;
        return ('session', line(t.isEmpty ? '—' : t.toLowerCase(), lines: 2));
    }
  }

  // ---- waiting: permission ---------------------------------------------------

  Widget _permission(AgentsState state, Agent a, AgentPrompt p) {
    return _card(
      fill: DeckHud.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(
            state,
            a,
            ink: DeckHud.bg,
            pillFill: DeckHud.bg,
            pillInk: DeckHud.accent,
            body: DeckHud.bg,
            cut: DeckHud.accent,
          ),
          const SizedBox(height: 22),
          Text(
            p.title.isEmpty ? 'allow this?' : p.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.rm(
              24,
              DeckHud.bg,
              weight: 700,
            ).copyWith(height: 1.25),
          ),
          if (p.detail.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: DeckHud.bg,
                borderRadius: BorderRadius.zero,
              ),
              child: Text(
                p.detail,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: DeckHud.rm(17, DeckHud.ink).copyWith(height: 1.45),
              ),
            ),
          ],
          if (p.context.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              p.context,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.mono(size: 14, color: DeckHud.bg),
            ),
          ],
          const SizedBox(height: 22),
          Expanded(
            child: _options([
              for (final o in p.options) _permissionButton(a, p, o),
            ], bottom: true),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              ..._back(
                ink: DeckHud.bg,
                outline: DeckHud.bg,
                pressedFill: DeckHud.bg,
                pressedInk: DeckHud.accent,
              ),
              Expanded(
                child: Text(
                  _note ?? 'answer here or at the terminal',
                  key: _note == null ? null : const Key('agent-note'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DeckHud.mono(size: 15, color: DeckHud.bg),
                ),
              ),
              _focusLink(a, ink: DeckHud.bg, surface: DeckHud.accent),
            ],
          ),
        ],
      ),
    );
  }

  Widget _permissionButton(Agent a, AgentPrompt p, AgentOption o) {
    final flash = _flashColors(o.key, onAccent: true);
    final sent = _flashKey == o.key && _flash == _Flash.sent;
    final fill =
        flash?.$1 ?? (o.primary ? DeckHud.bg : const Color(0x00000000));
    final ink = flash?.$2 ?? (o.primary ? DeckHud.accent : DeckHud.bg);
    final button = AgentButton(
      key: Key('agent-option-${o.key}'),
      label: '${o.key}  ${sent ? 'sent' : o.label}',
      onTap: _busy ? null : () => _answer(a, p, o.key),
      fill: fill,
      ink: ink,
      outline: flash?.$1 ?? DeckHud.bg,
      pressedFill: o.primary ? DeckHud.ink : DeckHud.bg,
      pressedInk: o.primary ? DeckHud.bg : DeckHud.accent,
      height: 64,
      fontSize: o.primary ? 20 : 18,
      alignLeft: true,
    );
    // Once one answer is out, the others step back.
    return Opacity(opacity: _closing && !sent ? 0.4 : 1, child: button);
  }

  /// Option stack: natural height, scrolls only if a prompt brings more
  /// options than fit.
  Widget _options(List<Widget> children, {bool bottom = false}) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          c,
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Align(
            alignment: bottom ? Alignment.bottomCenter : Alignment.topCenter,
            child: column,
          ),
        ),
      ),
    );
  }

  // ---- waiting: question ----------------------------------------------------

  Widget _question(AgentsState state, Agent a, AgentPrompt p) {
    final selected = p.options.where((o) => o.key == _selected).firstOrNull;
    final sendFlash = _flashColors('send', onAccent: false);
    final sent = _flashKey == 'send' && _flash == _Flash.sent;
    return _card(
      fill: DeckHud.bg,
      border: DeckHud.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(
            state,
            a,
            ink: DeckHud.ink,
            pillFill: DeckHud.accent,
            pillInk: DeckHud.bg,
            body: DeckHud.accent,
            cut: DeckHud.bg,
          ),
          const SizedBox(height: 20),
          // Which question of a form this is. The pill above is a clock now,
          // so the card has to say it.
          if (p.context.isNotEmpty) ...[
            Text(
              p.context,
              key: const Key('agent-question-context'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.mono(size: 14, color: DeckHud.dim),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            p.title.isEmpty ? 'question' : p.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.rm(
              23,
              DeckHud.ink,
              weight: 700,
            ).copyWith(height: 1.35),
          ),
          if (p.detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              p.detail,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.rm(16, DeckHud.dim).copyWith(height: 1.4),
            ),
          ],
          const SizedBox(height: 20),
          Expanded(
            child: _options([for (final o in p.options) _questionRow(o)]),
          ),
          if (_note != null) ...[
            const SizedBox(height: 10),
            Text(
              _note!,
              key: const Key('agent-note'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.mono(size: 15, color: DeckHud.accent),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              ..._back(
                ink: DeckHud.ink,
                outline: DeckHud.dim,
                pressedFill: DeckHud.ink,
                pressedInk: DeckHud.bg,
              ),
              Expanded(
                child: AgentButton(
                  key: const Key('agent-send'),
                  label: sent
                      ? 'sent'
                      : (selected == null ? 'send' : 'send ${selected.key}'),
                  onTap: _busy || selected == null
                      ? null
                      : () => _run(
                          'send',
                          () => widget.source.answer(a.id, p.id, selected.key),
                          closeOnOk: true,
                        ),
                  fill:
                      sendFlash?.$1 ??
                      (selected == null ? DeckHud.panel : DeckHud.accent),
                  ink:
                      sendFlash?.$2 ??
                      (selected == null ? DeckHud.dim : DeckHud.bg),
                  outline:
                      sendFlash?.$1 ??
                      (selected == null ? DeckHud.panel : DeckHud.accent),
                  pressedFill: DeckHud.ink,
                  pressedInk: DeckHud.bg,
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 260,
                child: _terminalButton(a, 'type in terminal'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _questionRow(AgentOption o) {
    final on = o.key == _selected;
    final (title, sub) = o.titleAndSub;
    return Pressable(
      key: Key('agent-option-${o.key}'),
      onTap: _busy
          ? null
          : () => setState(() {
              _selected = o.key;
              _note = null;
            }),
      builder: (context, pressed) {
        final ink = on || pressed;
        final fg = ink ? DeckHud.bg : DeckHud.ink;
        return Container(
          constraints: const BoxConstraints(minHeight: 74),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: ink ? DeckHud.ink : DeckHud.panel,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: ink ? DeckHud.ink : agentsRowOutline),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(o.key, style: DeckHud.rm(22, fg, weight: 700)),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DeckHud.mono(size: 18, color: fg),
                    ),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DeckHud.mono(
                          size: 13.5,
                          color: ink ? agentsRowSubOnInk : DeckHud.dim,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (o.selected) ...[
                const SizedBox(width: 14),
                Text(
                  '✓', // ticked answer of a pick-any question
                  key: Key('agent-option-${o.key}-ticked'),
                  style: DeckHud.rm(22, fg, weight: 700),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Outlined "focus the terminal" button for the dark prompt cards.
  Widget _terminalButton(Agent a, String label) {
    final flash = _flashColors('focus', onAccent: false);
    return AgentButton(
      key: const Key('agent-focus'),
      label: _flashKey == 'focus' && _flash == _Flash.sent ? 'focused' : label,
      onTap: _busy ? null : () => _focus(a),
      fill: flash?.$1 ?? const Color(0x00000000),
      ink: flash?.$2 ?? DeckHud.ink,
      outline: flash?.$1 ?? DeckHud.dim,
      pressedFill: DeckHud.ink,
      pressedInk: DeckHud.bg,
    );
  }

  // ---- waiting: free-text input ------------------------------------------------

  Widget _input(AgentsState state, Agent a, AgentPrompt p) {
    return _card(
      fill: DeckHud.bg,
      border: DeckHud.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(
            state,
            a,
            ink: DeckHud.ink,
            pillFill: DeckHud.accent,
            pillInk: DeckHud.bg,
            body: DeckHud.accent,
            cut: DeckHud.bg,
          ),
          const SizedBox(height: 24),
          Text(
            p.title.isEmpty ? 'needs input' : p.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.rm(
              23,
              DeckHud.ink,
              weight: 700,
            ).copyWith(height: 1.35),
          ),
          if (p.detail.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: DeckHud.panel,
                borderRadius: BorderRadius.zero,
              ),
              child: Text(
                p.detail,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: DeckHud.rm(17, DeckHud.ink).copyWith(height: 1.45),
              ),
            ),
          ],
          if (p.context.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              p.context,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.mono(size: 14, color: DeckHud.dim),
            ),
          ],
          const Spacer(),
          Text(
            _note ?? 'free-text answer · type it at the terminal',
            key: _note == null ? null : const Key('agent-note'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DeckHud.mono(
              size: 15,
              color: _note == null ? DeckHud.dim : DeckHud.accent,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              ..._back(
                ink: DeckHud.ink,
                outline: DeckHud.dim,
                pressedFill: DeckHud.ink,
                pressedInk: DeckHud.bg,
              ),
              Expanded(child: _terminalButton(a, 'focus terminal')),
            ],
          ),
        ],
      ),
    );
  }

  // ---- agent gone ------------------------------------------------------------

  Widget _gone() {
    if (!_goneScheduled) {
      _goneScheduled = true;
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) widget.onClose();
      });
    }
    return _card(
      fill: DeckHud.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CritterSprite(
              pose: CritterPose.exited,
              width: 92,
              body: DeckHud.dim,
              cut: DeckHud.bg,
            ),
            const SizedBox(height: 22),
            Text('agent gone', style: DeckHud.rm(26, DeckHud.ink, weight: 700)),
            const SizedBox(height: 10),
            Text(
              'it left the fleet',
              style: DeckHud.mono(size: 15, color: DeckHud.dim),
            ),
          ],
        ),
      ),
    );
  }
}

/// "3 subagents", "1 subagent".
String subagentCount(int n) => '$n subagent${n == 1 ? '' : 's'}';

/// An agent's working subagents, one to a row: a small critter posed by its
/// latest tool, its task, and its type after it when there's room (the
/// boards' card draws them the same way). Past [max] the last row says how
/// many more there are.
class SubagentRows extends StatelessWidget {
  const SubagentRows({
    super.key,
    required this.subagents,
    required this.body,
    required this.cut,
    this.maxRows = 4,
  });

  /// Rows at most, the "+N more" row included.
  final int maxRows;
  static const rowHeight = 32.0;

  final List<AgentSubagent> subagents;
  final Color body;
  final Color cut;

  @override
  Widget build(BuildContext context) {
    final fits = subagents.length <= maxRows;
    final shown = subagents.take(fits ? maxRows : maxRows - 1).toList();
    final more = subagents.length - shown.length;
    return Semantics(
      label:
          '${subagentCount(subagents.length)}: '
          '${subagents.map((s) => s.title).join(', ')}',
      child: Column(
        key: const Key('agent-subagents'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in shown)
            SizedBox(
              key: Key('agent-subagent-${s.id}'),
              height: rowHeight,
              child: Row(
                children: [
                  _Lead(
                    child: CritterSprite(
                      pose: critterPoseForTool(s.tool),
                      showBubble: false,
                      // Whole-pixel cells: 36 is two pixels to a cell.
                      width: 36,
                      body: body,
                      cut: cut,
                    ),
                  ),
                  Expanded(child: _SubagentLine(subagent: s)),
                ],
              ),
            ),
          if (more > 0)
            SizedBox(
              height: rowHeight,
              child: Row(
                children: [
                  const _Lead(child: SizedBox.shrink()),
                  Text(
                    '+$more more',
                    key: const Key('agent-subagents-more'),
                    style: DeckHud.mono(size: 15, color: DeckHud.dim),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The critter's column at the start of a subagent row.
class _Lead extends StatelessWidget {
  const _Lead({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 50,
    child: Align(alignment: Alignment.centerLeft, child: child),
  );
}

/// A subagent's task, then " · type" in dim when the whole of it fits.
class _SubagentLine extends StatelessWidget {
  const _SubagentLine({required this.subagent});

  final AgentSubagent subagent;

  @override
  Widget build(BuildContext context) {
    final s = subagent;
    final titleStyle = DeckHud.rm(17, DeckHud.ink);
    final typeStyle = DeckHud.mono(
      size: 15,
      color: DeckHud.dim,
    ).copyWith(height: 1.0);
    final title = s.title.isNotEmpty
        ? s.title
        : s.type.isNotEmpty
        ? s.type
        : 'subagent';
    final type = s.title.isNotEmpty && s.type.isNotEmpty ? ' · ${s.type}' : '';
    return LayoutBuilder(
      builder: (context, box) {
        final span = TextSpan(
          children: [
            TextSpan(text: title, style: titleStyle),
            if (type.isNotEmpty) TextSpan(text: type, style: typeStyle),
          ],
        );
        final tp = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final fits = tp.width <= box.maxWidth;
        tp.dispose();
        return Text.rich(
          fits ? span : TextSpan(text: title, style: titleStyle),
          // The same line box with or without the type: rows stay level.
          strutStyle: StrutStyle.fromTextStyle(
            titleStyle,
            forceStrutHeight: true,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// A square "‹" button that closes the card (hosts without an edge swipe),
/// the same height and outline as the [AgentButton]s beside it.
class CardBackButton extends StatelessWidget {
  const CardBackButton({
    super.key,
    required this.onTap,
    required this.ink,
    required this.outline,
    required this.pressedFill,
    required this.pressedInk,
  });

  final VoidCallback onTap;
  final Color ink;
  final Color outline;
  final Color pressedFill;
  final Color pressedInk;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'back',
      child: Pressable(
        key: const Key('agent-back'),
        onTap: onTap,
        // 49 on a phone, which is what AgentButton's 68 becomes there: a
        // square that keeps its full size stands taller than the row it is in.
        builder: (context, pressed) => Container(
          width: DeckCompact.of(context) ? 49 : 68,
          height: DeckCompact.of(context) ? 49 : 68,
          decoration: BoxDecoration(
            color: pressed ? pressedFill : null,
            borderRadius: BorderRadius.zero,
            border: Border.all(
              color: pressed ? pressedFill : outline,
              width: 2,
            ),
          ),
          child: CustomPaint(
            painter: _ChevronPainter(pressed ? pressedInk : ink),
          ),
        ),
      ),
    );
  }
}

/// A square-capped "<", the deck's pixel style.
class _ChevronPainter extends CustomPainter {
  _ChevronPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawPath(
      Path()
        ..moveTo(c.dx + 4, c.dy - 8)
        ..lineTo(c.dx - 4, c.dy)
        ..lineTo(c.dx + 4, c.dy + 8),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.miter,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}

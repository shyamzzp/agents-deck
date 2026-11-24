import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'theme.dart';
import 'widgets.dart';
import 'agents_client.dart';
import 'agents_model.dart';
import 'agents_style.dart';
import 'critter.dart';
import 'agents_app.dart';

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
    this.taskShape,
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

  /// The shape of the page this agent was opened from, so the quick list is
  /// drawn as that same board: the tasks sit in its cells, the same size as
  /// the agents they were opened over. Null draws the list as a plain grid.
  final DeckShape? taskShape;

  @override
  State<AgentDetail> createState() => _AgentDetailState();
}

class _AgentDetailState extends State<AgentDetail> {
  /// The card's one scroller: everything between the mascot and the buttons.
  final _scroll = ScrollController();

  /// The tasks, for the double tap to bring into view.
  final _asksKey = GlobalKey();

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

  /// What the second action is called, which is also how wide it is drawn:
  /// "hide" needs a quarter of what "tap again to stop" does.
  String _removeLabel(Agent a) {
    final exited = a.status == AgentStatus.exited;
    final armed = _confirmStop && !exited;
    return _flashKey == 'dismiss' && _flash == _Flash.sent
        ? 'removed'
        : a.codexThread || a.inApp
        ? 'hide'
        : a.watched
        ? 'remove from deck'
        : exited
        ? 'remove'
        : armed
        ? 'tap again to stop'
        : 'stop';
  }

  Widget _removeButton(Agent a, (Color, Color)? flash) {
    final exited = a.status == AgentStatus.exited;
    final armed = _confirmStop && !exited;
    return AgentButton(
      key: const Key('agent-remove'),
      label: _removeLabel(a),
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
                  if (_history)
                    Positioned.fill(
                      child: _PromptDrawer(
                        key: const Key('prompt-drawer'),
                        source: widget.source,
                        agentId: widget.agentId,
                        tight: tight,
                        onClose: () => setState(() => _history = false),
                        onSend: (text) => unawaited(_sendAgain(text)),
                        onKeep: (text) => unawaited(_keep(text)),
                      ),
                    ),
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

  /// Brings the tasks into view. Reached by a double tap on the title or on
  /// any empty part of the card: they live on the card now, so nothing opens
  /// over it.
  void _openAsks() {
    final box = _asksKey.currentContext;
    if (box == null) return;
    unawaited(
      Scrollable.ensureVisible(
        box,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        alignment: 0.1,
      ),
    );
  }

  Future<void> _ask(Agent a, int i) async {
    final asks = _asksFor(a);
    if (i >= asks.length) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    // "now": typed into the session and entered, rather than queued behind
    // whatever it is doing.
    final r = await widget.source.prompt(
      widget.agentId,
      asks[i].text,
      mode: 'now',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _askSent = r.isOk ? i : -1;
      _note = r.isOk ? null : (r.message ?? 'could not send');
    });
    if (r.isOk) {
      // The tile says "sent" for a moment, then goes back to its name.
      Timer(_sentHold, () {
        if (mounted) setState(() => _askSent = -1);
      });
    }
  }

  /// Which task said "sent" last; -1 for none.
  int _askSent = -1;

  /// The prompts drawer, opened from the turn count.
  bool _history = false;

  /// Takes one of the agent's own tasks off its grid (held, not tapped).
  Future<void> _dropTask(Agent a, String taskId) async {
    final r = await widget.source.removeTask(a.id, taskId);
    if (!mounted) return;
    setState(
      () => _note = r.isOk ? null : (r.message ?? 'could not remove it'),
    );
  }

  /// Keeps a prompt from the history as one of the agent's own tasks, which
  /// puts it in the quick list beside the built-in ones.
  Future<void> _keep(String text) async {
    final r = await widget.source.addTask(widget.agentId, text);
    if (!mounted) return;
    setState(() {
      _note = r.isOk ? null : (r.message ?? 'could not keep it');
      if (r.isOk) _history = false;
    });
  }

  /// Sends a prompt from the history again, as a task tile does.
  Future<void> _sendAgain(String text) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    final r = await widget.source.prompt(widget.agentId, text, mode: 'now');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = r.isOk ? 'sent' : (r.message ?? 'could not send');
      if (r.isOk) _history = false;
    });
  }

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

  /// The tasks as the deck's own board: as many columns as the page the
  /// agent was picked from, its cells the same shape, and the deck's empty
  /// cells past the end of the list.
  ///
  /// It measures itself rather than filling a screen, since it sits in the
  /// card's scroller. A page with fewer cells than the list has simply takes
  /// more rows: a task that cannot be reached is worse than a board a row
  /// taller than the deck's.
  /// Everything the quick list offers for [a]: the eight every agent has, and
  /// then the ones kept for this agent (newest last, as they were made).
  List<AgentAsk> _asksFor(Agent a) => [
    ...agentAsks,
    for (final t in a.tasks)
      AgentAsk(
        t.name.isEmpty ? 'task' : t.name,
        t.text,
        // A task made from a prompt is a prompt: the critter is thinking.
        CritterPose.think,
        id: t.id,
      ),
  ];

  Widget _askBoard(bool tight, Agent a) {
    // The deck can only type into a session it can reach. One inside another
    // app refuses with 422 and says why, so the card says it here rather than
    // on every tap.
    if (!a.canBeTold) {
      return Text(
        'This one cannot be told: it runs inside another app, which the deck '
        'cannot type into. Give it tasks where it lives.',
        key: const Key('asks-refused'),
        style: DeckHud.mono(size: tight ? 13 : 15, color: DeckHud.dim),
      );
    }
    final asks = _asksFor(a);
    final shape = widget.taskShape ?? const DeckShape(3, 3);
    final columns = shape.columns;
    final rows = shape.rowsFor((asks.length + columns - 1) ~/ columns);
    return GridView.count(
      key: const Key('asks-grid'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      crossAxisCount: columns,
      mainAxisSpacing: DeckGrid.gap,
      crossAxisSpacing: DeckGrid.gap,
      children: [
        for (final (i, ask) in asks.indexed)
          _AskTile(
            key: Key('ask-$i'),
            ask: ask,
            sent: _askSent == i,
            onTap: _busy ? null : () => _ask(a, i),
            // A task of the agent's own can be taken away again; the eight
            // every agent has cannot.
            onHold: ask.id == null
                ? null
                : () => unawaited(_dropTask(a, ask.id!)),
          ),
        for (var i = asks.length; i < columns * rows; i++)
          const AgentsEmptyTile(),
      ],
    );
  }

  /// The hat picker: every colour and shape a folder's critter can wear.
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

  /// A button in the card's bottom row, given room in proportion to the text
  /// it holds: "review in terminal" is eighteen characters and "stop" four,
  /// so the row is divided 18 to 4 rather than by a number picked in advance.
  /// Where the card is not compact (the desk panel) the old widths stand: a
  /// main action that fills the row and 200 points for the one beside it.
  ///
  /// [context] has to come from inside the card, where DeckCompact is.
  Widget _share(
    BuildContext context,
    String label,
    Widget button, {
    bool main = false,
  }) {
    if (!DeckCompact.of(context)) {
      return main
          ? Expanded(child: button)
          : SizedBox(width: 200, child: button);
    }
    return Flexible(
      flex: label.length.clamp(4, 40),
      fit: FlexFit.tight,
      child: button,
    );
  }

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
    final tight = DeckCompact.of(context);
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
    final focusLabel = _flashKey == 'focus' && _flash == _Flash.sent
        ? 'focused'
        : a.codexThread
        ? 'open in codex'
        : a.inApp
        ? 'open in ${a.app}'
        : a.hungry
        ? 'review in terminal'
        : 'focus terminal';
    final interruptLabel = _flashKey == 'interrupt' && _flash == _Flash.sent
        ? 'sent'
        : 'interrupt';
    final resumeLabel = _flashKey == 'resume' && _flash == _Flash.sent
        ? 'resuming'
        : 'resume';
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
          // Everything between the mascot and the buttons scrolls as one:
          // what it is doing, its numbers, the last prompt and the tasks.
          // The title above and the two actions below stay where they are,
          // since those are what a glance and a thumb want.
          Expanded(
            child: SingleChildScrollView(
              key: const Key('agent-scroll'),
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                      Text(
                        'context',
                        style: DeckHud.rm(22, DeckHud.ink, weight: 700),
                      ),
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
                              a.codexThread
                                  ? '—'
                                  : '\$${a.costUsd.toStringAsFixed(2)}',
                            ),
                            ('turns', '${a.turns}'),
                          ].indexed)
                            Expanded(
                              child: GestureDetector(
                                // The turn count is a door: behind it are the
                                // prompts it counts.
                                behavior: HitTestBehavior.opaque,
                                onTap: label == 'turns' && a.turns > 0
                                    ? () => setState(() => _history = true)
                                    : null,
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    7,
                                    8,
                                    8,
                                  ),
                                  decoration: BoxDecoration(
                                    border: i == 0
                                        ? null
                                        : Border(
                                            left: BorderSide(
                                              color: _rule,
                                              width: 0.5,
                                            ),
                                          ),
                                  ),
                                  child: Column(
                                    // Centred in the cell, not pushed to its left edge:
                                    // "turns" holds the shortest figure of the four, so
                                    // left-aligned it looked as though its cell had been
                                    // given all its room on the right.
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    // The label at the top of the cell and the figure on
                                    // its floor: a cell whose label wraps to two lines
                                    // would otherwise lift its figure above the rest.
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
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
                                        style: DeckHud.rm(
                                          18,
                                          DeckHud.ink,
                                          weight: 600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (state.lastActiveText(a) case final active
                      when active.isNotEmpty)
                    Row(
                      children: [
                        _label(
                          a.queuedNext.isEmpty ? 'last prompt' : 'queued next',
                          DeckHud.dim,
                        ),
                        const Spacer(),
                        Text(
                          active,
                          key: const Key('agent-last-active'),
                          style: DeckHud.mono(size: 14, color: DeckHud.dim),
                        ),
                      ],
                    )
                  else
                    _label(
                      a.queuedNext.isEmpty ? 'last prompt' : 'queued next',
                      DeckHud.dim,
                    ),
                  const SizedBox(height: 8),
                  // A prompt the deck has queued is shown instead of the last one: it
                  // is what goes in next, and it is the thing someone looking at the
                  // card wants to see arrive. Four lines of it, now that the card
                  // scrolls: there is no leftover height left to measure.
                  Text(
                    a.queuedNext.isNotEmpty
                        ? a.queuedNext
                        : (a.lastPrompt.isEmpty ? '—' : a.lastPrompt),
                    key: const Key('agent-last-prompt'),
                    // Five lines at 13: it is the longest thing on the card,
                    // and smaller text shows more of it in less room.
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: DeckHud.rm(
                      13,
                      a.queuedNext.isNotEmpty ? DeckHud.accent : DeckHud.ink,
                    ).merge(const TextStyle(height: 1.45)),
                  ),
                  // The tasks, in the cells of the page this agent was picked from.
                  const SizedBox(height: 18),
                  _label('ask it to\u2026', DeckHud.dim),
                  const SizedBox(height: 8),
                  Padding(
                    key: _asksKey,
                    padding: EdgeInsets.zero,
                    child: _askBoard(tight, a),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
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
                  Builder(
                    builder: (context) => DeckCompact.of(context)
                        ? Expanded(child: _handoffButton(a, to))
                        : SizedBox(width: 240, child: _handoffButton(a, to)),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 14),
          // Built here, not above: DeckCompact is put in the tree by _card,
          // which is below this method, so a flag read in _overview itself is
          // always false -- which is how this row kept the desk panel's fixed
          // widths on a phone.
          Builder(
            builder: (context) => Row(
              children: [
                ..._back(
                  ink: DeckHud.ink,
                  outline: DeckHud.dim,
                  pressedFill: DeckHud.ink,
                  pressedInk: DeckHud.bg,
                ),
                if (!exited)
                  _share(
                    context,
                    focusLabel,
                    main: true,
                    AgentButton(
                      key: const Key('agent-focus'),
                      label: focusLabel,
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
                  _share(
                    context,
                    interruptLabel,
                    AgentButton(
                      key: const Key('agent-interrupt'),
                      label: interruptLabel,
                      onTap: _busy ? null : () => _interrupt(a),
                      fill: intFlash?.$1 ?? const Color(0x00000000),
                      ink: intFlash?.$2 ?? DeckHud.ink,
                      outline: intFlash?.$1 ?? DeckHud.dim,
                      pressedFill: DeckHud.ink,
                      pressedInk: DeckHud.bg,
                    ),
                  ),
                ] else if (exited && a.resumable) ...[
                  _share(
                    context,
                    resumeLabel,
                    main: true,
                    AgentButton(
                      key: const Key('agent-resume'),
                      label: resumeLabel,
                      onTap: _busy ? null : () => _resume(a),
                      fill: resumeFlash?.$1 ?? DeckHud.ink,
                      ink: resumeFlash?.$2 ?? DeckHud.bg,
                      outline: resumeFlash?.$1 ?? DeckHud.ink,
                      pressedFill: DeckHud.accent,
                      pressedInk: DeckHud.bg,
                    ),
                  ),
                  const SizedBox(width: 14),
                  _share(context, _removeLabel(a), _removeButton(a, rmFlash)),
                ] else if (exited)
                  _share(
                    context,
                    _removeLabel(a),
                    main: true,
                    _removeButton(a, rmFlash),
                  )
                else ...[
                  const SizedBox(width: 14),
                  _share(context, _removeLabel(a), _removeButton(a, rmFlash)),
                ],
              ],
            ),
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

/// Every prompt of the session, behind the turn count that counts them.
///
/// It comes in from the left over the card and takes part of its width, so
/// the agent it belongs to is still there behind it. A row carries what was
/// asked; its three actions send it again, keep it as a task on the agent's
/// grid, or copy it.
class _PromptDrawer extends StatefulWidget {
  const _PromptDrawer({
    super.key,
    required this.source,
    required this.agentId,
    required this.tight,
    required this.onClose,
    required this.onSend,
    required this.onKeep,
  });

  final AgentsSource source;
  final String agentId;
  final bool tight;
  final VoidCallback onClose;
  final void Function(String text) onSend;
  final void Function(String text) onKeep;

  @override
  State<_PromptDrawer> createState() => _PromptDrawerState();
}

class _PromptDrawerState extends State<_PromptDrawer> {
  List<AgentPrompted>? _rows;
  String? _problem;

  /// Which row has its actions open; one at a time, so a list of two hundred
  /// stays a list.
  int? _open;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await widget.source.prompts(widget.agentId);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Stack(
      children: [
        // The rest of the card closes it.
        Positioned.fill(
          child: GestureDetector(
            key: const Key('prompt-drawer-scrim'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: ColoredBox(color: DeckHud.bg.withValues(alpha: 0.72)),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            // Part of the card, not all of it: the agent stays in sight.
            widthFactor: widget.tight ? 0.82 : 0.46,
            child: GestureDetector(
              // Taps inside the drawer are the drawer's own.
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              onHorizontalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -240) widget.onClose();
              },
              child: Container(
                color: DeckHud.panel,
                padding: EdgeInsets.fromLTRB(
                  widget.tight ? 14 : 20,
                  widget.tight ? 14 : 20,
                  widget.tight ? 10 : 16,
                  widget.tight ? 10 : 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'prompts',
                            style: DeckHud.rm(
                              widget.tight ? 20 : 24,
                              DeckHud.ink,
                              weight: 700,
                            ),
                          ),
                        ),
                        GestureDetector(
                          key: const Key('prompt-drawer-close'),
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onClose,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              '\u00d7',
                              style: DeckHud.rm(22, DeckHud.dim, weight: 700),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(switch ((rows, _problem)) {
                      (_, final String p) => p,
                      (null, _) => 'reading the session\u2026',
                      (final List<AgentPrompted> r, _) =>
                        r.isEmpty
                            ? 'nothing asked yet'
                            : '${r.length} asked, newest first',
                    }, style: DeckHud.mono(size: 12, color: DeckHud.dim)),
                    const SizedBox(height: 10),
                    if (rows != null)
                      Expanded(
                        child: ListView.builder(
                          key: const Key('prompt-list'),
                          padding: EdgeInsets.zero,
                          itemCount: rows.length,
                          itemBuilder: (context, i) => _PromptRow(
                            key: Key('prompt-$i'),
                            row: rows[i],
                            open: _open == i,
                            tight: widget.tight,
                            onTap: () =>
                                setState(() => _open = _open == i ? null : i),
                            onSend: () => widget.onSend(rows[i].text),
                            onKeep: () => widget.onKeep(rows[i].text),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One prompt in the drawer: its turn number, what was asked, and the three
/// things that can be done with it once it is tapped.
class _PromptRow extends StatelessWidget {
  const _PromptRow({
    super.key,
    required this.row,
    required this.open,
    required this.tight,
    required this.onTap,
    required this.onSend,
    required this.onKeep,
  });

  final AgentPrompted row;
  final bool open;
  final bool tight;
  final VoidCallback onTap;
  final VoidCallback onSend;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Pressable(
            onTap: onTap,
            builder: (context, pressed) => Container(
              color: pressed || open ? DeckHud.bg : const Color(0x00000000),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${row.turn}',
                      style: DeckHud.mono(size: 12, color: DeckHud.dim),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.text,
                      maxLines: open ? 8 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: DeckHud.rm(
                        tight ? 13 : 15,
                        DeckHud.ink,
                      ).merge(const TextStyle(height: 1.35)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 34),
                _PromptAction(
                  key: const Key('prompt-send'),
                  label: 'send again',
                  onTap: onSend,
                ),
                const SizedBox(width: 8),
                _PromptAction(
                  key: const Key('prompt-keep'),
                  label: 'make a task',
                  onTap: onKeep,
                ),
                const SizedBox(width: 8),
                _PromptAction(
                  key: const Key('prompt-copy'),
                  label: 'copy',
                  onTap: () => unawaited(
                    Clipboard.setData(ClipboardData(text: row.text)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PromptAction extends StatelessWidget {
  const _PromptAction({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, pressed) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: pressed ? DeckHud.ink : const Color(0x00000000),
        border: Border.all(color: DeckHud.dim, width: 0.5),
      ),
      child: Text(
        label,
        style: DeckHud.mono(
          size: 12,
          color: pressed ? DeckHud.bg : DeckHud.ink,
        ),
      ),
    ),
  );
}

/// One task on the quick list, drawn as the deck draws an agent: the picture
/// where the critter goes, the name under it, and the ink invert on a press.
///
/// Laid out on the deck's own 170 point cell and scaled to whatever the real
/// one is, so a 3 x 3 page and an 8 x 8 page both keep the composition.
class _AskTile extends StatelessWidget {
  const _AskTile({
    super.key,
    required this.ask,
    required this.sent,
    required this.onTap,
    this.onHold,
  });

  final AgentAsk ask;
  final bool sent;
  final VoidCallback? onTap;

  /// Held rather than tapped: takes a task of the agent's own away. Null for
  /// the eight every agent has, which cannot be removed.
  final VoidCallback? onHold;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      onLongPress: onHold,
      builder: (context, pressed) {
        final on = pressed || sent;
        final fill = on ? DeckHud.ink : DeckHud.panel;
        // One colour for every task, the agent colour of whichever theme is
        // on: what tells them apart is the hat, as it does on the deck. No
        // frame around it either, since the deck's own tiles have none.
        final ink = on ? DeckHud.bg : DeckHud.ink;
        return DecoratedBox(
          decoration: BoxDecoration(color: fill),
          child: FittedBox(
            child: SizedBox.square(
              dimension: 170,
              // The name is Flexible so a two-line one cannot push the
              // column past the design cell: 21 points of it fits, and a
              // longer word is ellipsised rather than overflowing.
              child: Column(
                children: [
                  const SizedBox(height: 18),
                  CritterSprite(
                    pose: ask.pose,
                    species: CritterSpecies.claude,
                    hat: autoHatFor(ask.label),
                    centerBody: true,
                    showBubble: false,
                    width: 92,
                    body: ink,
                    cut: fill,
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: SizedBox(
                      width: 158,
                      child: Text(
                        sent ? 'sent' : ask.label,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: DeckHud.mono(size: 21, color: ink),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'widgets.dart';
import 'agent_detail.dart';
import 'agents_client.dart';
import 'agents_model.dart';
import 'agents_style.dart';
import 'attention.dart';
import 'attention_screen.dart';
import 'critter.dart';
import 'critter_look.dart';
import 'speech_callout.dart';
import 'haptics.dart';
import 'live_picker.dart';
import 'pet_art.dart';
import 'usage_limits.dart';

/// Agents app: a Stream-Deck-style board of the Mac's coding agents
/// (`agentctl serve`). Chrome-less 4×4 grid, one tile per agent by slot,
/// each tile morphing into that agent's card. The host decides how cards
/// open ([openCard] + [cardHost]); by default the built-in [CardMorph].
///
/// Tiles sit at their slot, so the board can have gaps: arrange it freely.
/// Pages hold 16 slots each (page = slot ~/ 16), with bars underneath.
///
/// One step to the left of the first page is the "Needs you" screen
/// ([AttentionScreen]): only the agents that need you, each in the spot the
/// service gave it ([NeedsYou]). The deck always opens on its first
/// page; swipe right, scroll, press the left arrow or tap the mark at the
/// far left of the bars to get there.
class AgentsApp extends StatefulWidget {
  const AgentsApp({
    super.key,
    required this.source,
    this.animate = true,
    this.openCard,
    this.cardHost,
    this.pairingCard,
    this.visible,
    this.backButton = false,
    this.pageShapes = const [DeckShape.panel],
    this.attentionShape,
    this.contextRingWidth = ContextRingPainter.defaultStroke,
    this.leadingPage,
    this.leadingPages = const [],
    this.trailingPages = const [],
    this.pageTitles = const {},
    this.onRenamePage,
    this.onHoldAttention,
    this.ear,
    this.onSpeakTask,
    this.menuBar = false,
    this.usageFollowsSetting = false,
    this.headerActions = false,
  }) : assert(pageShapes.length > 0, 'the deck needs a shape'),
       assert(
         (openCard == null) == (cardHost == null),
         'openCard and cardHost come together',
       );

  final AgentsSource source;

  /// Opens an agent's card from its tile; null = [CardMorph.open].
  final AgentCardOpener? openCard;

  /// Wraps the board so [openCard] can find its host; null = [CardMorph].
  final Widget Function(Widget board)? cardHost;

  /// A back button on agent cards, for hosts without an edge swipe.
  final bool backButton;

  /// How thick the context gauge around each card is drawn, in points. It is
  /// the card's border and its context meter at once, so this is the width of
  /// the line the orange fills. Belongs to the display showing the deck
  /// rather than to the service.
  final double contextRingWidth;

  /// The shape the "Needs you" screen is drawn in; null follows the first
  /// page. It holds the sixteen spots the service gives it whatever the shape
  /// (docs/protocol.md), so a larger grid leaves the rest free and a smaller
  /// one packs them.
  final DeckShape? attentionShape;

  /// A page of the host's own, before the "Needs you" screen: somewhere to
  /// put settings on a device that has no menu bar to hang them off. Null
  /// leaves the deck as it was, opening on its first page.
  final Widget? leadingPage;

  /// More pages of the host's own, between [leadingPage] and "Needs you".
  /// They are swiped through like any other page of the deck.
  final List<Widget> leadingPages;

  /// Pages of the host's own after the deck's own: the artifacts page lives
  /// here, at the far end, so the agents keep the pages in front.
  final List<Widget> trailingPages;

  /// The shape of each page in turn; the last one repeats for any page beyond
  /// it, so a single entry shapes the whole deck. 4 x 4 is what the desk panel
  /// and the boards draw.
  ///
  /// Pages need not match each other. A page holds as many agents as it has
  /// cells, so where a page begins is the sum of the ones before it rather
  /// than a multiple: a deck of 5 x 5 then 4 x 4 starts its second page at
  /// slot 25 and its third at 41. An agent keeps its slot through all of it;
  /// only which page shows it moves.
  final List<DeckShape> pageShapes;

  /// Asks the host to listen and hands back what was said, for holding an
  /// empty cell of an agent's quick list: what comes back is kept as a task
  /// in that cell. Null on a host with no microphone.
  final Future<String?> Function(Agent agent)? onSpeakTask;

  /// Holding an agent on the "Needs you" screen, for a host that answers it
  /// with a page of its own. Null leaves the hold to [ear], or to nothing.
  final void Function(Agent a)? onHoldAttention;

  /// The phone's ear. With one, holding an agent on the "Needs you" screen
  /// listens and the words are typed into a callout beside its tile; letting
  /// go offers a tick to send them to its terminal and a cross to throw them
  /// away. Null on a host that cannot listen: the hold then does whatever
  /// [onHoldAttention] says, or nothing.
  final DeckEar? ear;

  /// What each page is called, by page index; -1 is the "Needs you" screen.
  /// A page with no name of its own is called "page N".
  final Map<int, String> pageTitles;

  /// Renames the page shown. Null leaves the footer's title as a label: a
  /// host that cannot keep a name should not offer to take one.
  final void Function(int page, String title)? onRenamePage;

  /// In the menu bar app: an agent's page has no clock and no text under
  /// 16 design pixels (the deck is shown at 0.61 there).
  final bool menuBar;

  /// On a tablet: an agent's card puts the terminal and remove buttons on
  /// the title's own row instead of at the foot of the card. A phone ignores
  /// it, since it has no width beside the name.
  final bool headerActions;

  /// On a phone or a tablet: the usage line is drawn only while "Report
  /// usage from every Claude session" is on, so turning that off clears it
  /// from the screen in your hand as well as from Claude's own settings.
  final bool usageFollowsSetting;

  /// Whether anyone can see the board (a menu bar window that hides): the
  /// critters stop animating while false. Null = always visible.
  final ValueListenable<bool>? visible;

  /// Shown while there are no pairing values (with why saved ones failed);
  /// null = [AgentsPairingCard], the desk panel's setup steps.
  final Widget Function(String? problem)? pairingCard;

  /// False freezes every critter on its first frame (goldens, tests).
  final bool animate;

  @override
  State<AgentsApp> createState() => _AgentsAppState();
}

class _AgentsAppState extends State<AgentsApp> {
  /// How many agents needed you when the deck was last drawn, so a new one
  /// buzzes once rather than on every frame.
  int _wasNeeded = 0;

  late final _gridClock = CritterClock(animate: widget.animate);
  late final _cardClock = CritterClock(animate: widget.animate)
    ..running = false;

  /// The view shown: 0 = "Needs you", 1 + n = page n. Opens on page 0.
  /// 0 is the leading page when there is one, then the "Needs you" screen,
  /// then the deck's pages. The deck is what opens, not either of them.
  /// True while a tile is in hand. The deck's pages scroll sideways and a
  /// drag moves sideways too, so the two fight over the pointer: on iOS the
  /// page scroll wins and the tile is dropped as soon as it is moved. The
  /// pager is held still until the tile lands.
  bool _dragging = false;

  /// Picking a card up and carrying it. [_heldId] is the agent in hand,
  /// [_heldSlot] where it came from, [_overSlot] the cell it is over now.
  static const _holdDelay = Duration(milliseconds: 220);
  final _cellKeys = <int, GlobalKey>{};
  final _deckKey = GlobalKey();
  Timer? _holdTimer;
  Timer? _edgeTimer;

  /// Speaking to an agent from the "Needs you" screen: whose tile is held,
  /// where that tile is on the screen, what has been heard, and whether the
  /// finger has been lifted (so the tick and the cross are shown).
  Agent? _speakingTo;
  Rect? _speakingAt;
  bool _speakingDone = false;
  Timer? _listenTimer;
  Timer? _emptyTimer;
  final _speakKeys = <String, GlobalKey>{};

  String? _heldId;
  int? _heldSlot;
  int? _overSlot;
  Offset _pointer = Offset.zero;
  Size _heldSize = const Size(120, 120);

  /// The host's own pages, in the order they are swiped through.
  List<Widget> get _leading => [?widget.leadingPage, ...widget.leadingPages];

  int get _lead => _leading.length;

  /// How many deck pages the last build drew.
  int _pages = 1;
  late int _view = 1 + _lead;
  late final _pager = PageController(initialPage: 1 + _lead);

  /// The shape of page [i], the last entry standing in for the rest.
  DeckShape _shape(int i) => deckShapeOf(widget.pageShapes, i);

  /// The slot page [i] begins at: the cells of every page before it.
  int _start(int i) {
    var n = 0;
    for (var p = 0; p < i; p++) {
      n += _shape(p).cells;
    }
    return n;
  }

  int _pageOf(int slot) => deckPageOf(widget.pageShapes, slot);

  int _pageCount(Iterable<int> slots) =>
      deckPageCount(widget.pageShapes, slots);

  @override
  void dispose() {
    widget.visible?.removeListener(_syncClocks);
    _listenTimer?.cancel();
    _emptyTimer?.cancel();
    _pager.dispose();
    _gridClock.dispose();
    _cardClock.dispose();
    super.dispose();
  }

  bool _cardShown = false;

  // The magic trick (docs/features.md), when the deck made this screen its
  // giver: when the receiver takes the agents this screen shows, their tiles
  // fly off to its leave corner together; given back, they fly in from its
  // arrive corner. It tells the deck which agents it shows (the open page).
  Map<String, Agent> _seen = const {};
  List<Agent> _leaving = const [];
  Set<String> _arriving = const {};
  int _flight = 0; // a new number per flight, so the tiles start again
  bool _wasTaken = false;
  String _leaveCorner = 'bottom-left', _arriveCorner = 'top-left';

  void _watchFlights(AgentsState state) {
    final now = {for (final a in state.agents) a.id: a};
    final m = state.magic;
    final taken = m != null && m.giver && m.taken;
    if (m != null && m.giver) {
      _leaveCorner = m.leave;
      _arriveCorner = m.arrive;
    }
    if (taken && !_wasTaken) {
      _leaving = [
        for (final e in _seen.entries)
          if (!now.containsKey(e.key)) e.value,
      ];
      _arriving = const {};
      _flight++;
    } else if (!taken && _wasTaken) {
      _arriving = {
        for (final id in now.keys)
          if (!_seen.containsKey(id)) id,
      };
      _leaving = const [];
      _flight++;
    }
    _wasTaken = taken;
    _seen = now;
  }

  // What this screen shows, for the deck (the giver only): on a change and
  // every 5 s.
  String _viewSent = '';
  DateTime _viewAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _reportView(AgentsState state) {
    final m = state.magic;
    if (m == null || !m.giver || m.taken || _view < 1) return;
    final page = _view - 1 - _lead;
    final start = _start(page), end = start + _shape(page).cells;
    final ids = [
      for (final a in state.agents)
        if (a.slot >= start && a.slot < end) a.id,
    ];
    final key = ids.join(',');
    final now = DateTime.now();
    if (ids.isEmpty ||
        (key == _viewSent && now.difference(_viewAt).inSeconds < 5)) {
      return;
    }
    _viewSent = key;
    _viewAt = now;
    widget.source.magicView(ids);
  }

  @override
  void initState() {
    super.initState();
    widget.visible?.addListener(_syncClocks);
    _syncClocks();
  }

  @override
  void didUpdateWidget(AgentsApp old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) {
      old.visible?.removeListener(_syncClocks);
      widget.visible?.addListener(_syncClocks);
      _syncClocks();
    }
  }

  /// The card covers the grid: only one set of critters runs at a time, and
  /// none while the board is hidden.
  void _cardVisible(bool shown) {
    _cardShown = shown;
    _syncClocks();
  }

  void _syncClocks() {
    final seen = widget.visible?.value ?? true;
    _gridClock.running = seen && !_cardShown;
    _cardClock.running = seen && _cardShown;
  }

  void _open(BuildContext tileContext, GlobalKey tileKey, Agent a) {
    // A hold that spoke ends with the finger lifting off the tile, which is
    // also a tap: without this, the agent's card opened over the words the
    // moment they were finished, and the tick and the cross went with it.
    // Nothing opens a card while a bubble is up; the cross closes it.
    if (_speakingTo != null) return;
    final p = a.status == AgentStatus.waiting ? a.waiting : null;
    (widget.openCard ?? CardMorph.open)(
      tileContext,
      tileKey,
      id: 'agent/${a.id}',
      // The flight's colour = the card it lands as.
      fill: p?.kind == PromptKind.permission ? DeckHud.accent : DeckHud.bg,
      builder: (close) => agentsOwnText(
        CritterScope(
          clock: _cardClock,
          child: AgentDetail(
            source: widget.source,
            agentId: a.id,
            onClose: close,
            onVisible: _cardVisible,
            showBack: widget.backButton,
            onSpeakTask: widget.onSpeakTask,
            ringWidth: widget.contextRingWidth,
            menuBar: widget.menuBar,
            headerActions: widget.headerActions,
          ),
        ),
      ),
    );
  }

  // ---- speaking to an agent from the "Needs you" screen ----------------------

  /// How long a tile is held before the phone starts listening.
  static const _listenDelay = Duration(milliseconds: 260);

  /// One tile of the "Needs you" screen, with the hold that opens the ear.
  ///
  /// A Listener rather than a long-press recognizer, for the reason the deck's
  /// carry is one: the pager either side of this screen takes a gesture that
  /// travels, and what matters here is the moment the finger lands and the
  /// moment it leaves, not what it did in between.
  Widget _speakCell(Agent a, Widget child) {
    if (widget.ear == null) return child;
    final key = _speakKeys.putIfAbsent(a.id, GlobalKey.new);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _armListen(a, key),
      onPointerMove: (e) {
        // A finger that wanders off the tile before the ear opens was going
        // somewhere else: a page, or another agent.
        if (_speakingTo != null || _listenTimer == null) return;
        final box = key.currentContext?.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final r = box.localToGlobal(Offset.zero) & box.size;
          if (!r.contains(e.position)) _disarmListen();
        }
      },
      onPointerUp: (_) => _stopListening(),
      onPointerCancel: (_) => _disarmListen(),
      child: KeyedSubtree(key: key, child: child),
    );
  }

  void _armListen(Agent a, GlobalKey key) {
    if (_speakingTo != null) return; // one callout at a time
    _listenTimer?.cancel();
    _listenTimer = Timer(_listenDelay, () {
      final ear = widget.ear;
      final box = key.currentContext?.findRenderObject();
      if (!mounted || ear == null || box is! RenderBox || !box.hasSize) return;
      Haptics.fire(HapticWhen.hold);
      setState(() {
        _speakingTo = a;
        _speakingAt = box.localToGlobal(Offset.zero) & box.size;
        _speakingDone = false;
      });
      unawaited(ear.start());
    });
  }

  void _disarmListen() {
    _listenTimer?.cancel();
    _listenTimer = null;
  }

  /// How long a bubble with nothing in it waits before closing itself. The
  /// recogniser can land the last word just after the microphone closes, so
  /// a hold that has heard nothing yet is given that long before the deck
  /// decides nothing was said.
  static const _emptyGrace = Duration(milliseconds: 600);

  /// The finger is lifted: the microphone closes and the two answers appear.
  /// Nothing goes anywhere until one of them is tapped.
  ///
  /// A hold that heard nothing closes itself instead: there is nothing to
  /// send, and a tick over an empty bubble is a question with one answer.
  void _stopListening() {
    _disarmListen();
    if (_speakingTo == null || _speakingDone) return;
    setState(() => _speakingDone = true);
    unawaited(widget.ear?.stop());
    _emptyTimer?.cancel();
    _emptyTimer = Timer(_emptyGrace, () {
      final ear = widget.ear;
      if (!mounted || ear == null || _speakingTo == null) return;
      if (ear.problem.value == null && ear.heard.value.trim().isEmpty) {
        _closeCallout();
      }
    });
  }

  /// The tick: what was said goes to the agent's terminal, as a prompt typed
  /// in now.
  Future<void> _sendSpoken(Agent a, String text) async {
    _closeCallout();
    if (text.trim().isEmpty) return;
    await widget.source.focus(a.id);
    await widget.source.prompt(a.id, text.trim(), mode: 'now');
    Haptics.fire(HapticWhen.sent);
  }

  void _closeCallout() {
    _disarmListen();
    _emptyTimer?.cancel();
    _emptyTimer = null;
    unawaited(widget.ear?.cancel());
    if (mounted) {
      setState(() {
        _speakingTo = null;
        _speakingAt = null;
        _speakingDone = false;
      });
    }
  }

  /// The callout itself, over the deck: placed beside the held tile, growing
  /// with what is said, and never off the screen (speech_callout.dart).
  Widget _speechCallout(Agent a, Rect tile) {
    final ear = widget.ear!;
    return ValueListenableBuilder<String?>(
      valueListenable: ear.problem,
      builder: (context, problem, _) => ValueListenableBuilder<String>(
        valueListenable: ear.heard,
        builder: (context, heard, _) {
          // Nothing to send, nothing to decide: an empty bubble shows no
          // buttons while it waits out its last word.
          final deciding =
              _speakingDone && (problem != null || heard.trim().isNotEmpty);
          final (at, side, size) = calloutLayout(
            tile,
            MediaQuery.sizeOf(context),
            problem ?? heard,
            deciding: deciding,
          );
          return Positioned(
            left: at.dx,
            top: at.dy,
            child: SpeechCallout(
              key: const Key('speech-callout'),
              text: heard,
              problem: problem,
              side: side,
              size: size,
              deciding: deciding,
              onSend: () => unawaited(_sendSpoken(a, heard)),
              onDiscard: _closeCallout,
            ),
          );
        },
      ),
    );
  }

  /// A free cell opens "add a session" (hand-started Claude sessions); the
  /// one you pick lands in that cell.
  void _openPicker(BuildContext cellContext, GlobalKey cellKey, int slot) {
    (widget.openCard ?? CardMorph.open)(
      cellContext,
      cellKey,
      id: 'add/$slot',
      fill: DeckHud.bg,
      builder: (close) => agentsOwnText(
        LivePicker(
          source: widget.source,
          slot: slot,
          onClose: close,
          showBack: widget.backButton,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CritterScope(
      clock: _gridClock,
      child: (widget.cardHost ?? (board) => CardMorph(child: board))(
        agentsOwnText(
          ValueListenableBuilder<AgentsSnapshot>(
            valueListenable: widget.source.snapshot,
            builder: (context, snap, _) => _body(snap),
          ),
        ),
      ),
    );
  }

  Widget _body(AgentsSnapshot snap) {
    final state = snap.state;
    if (snap.link == AgentsLink.unconfigured) {
      return widget.pairingCard?.call(snap.problem) ??
          AgentsPairingCard(problem: snap.problem);
    }
    if (state == null) {
      return _Notice(
        pose: CritterPose.starting,
        title: snap.link == AgentsLink.offline
            ? 'offline · retrying'
            : 'connecting',
        lines: [if (snap.problem != null) snap.problem!],
      );
    }
    final offline = snap.link != AgentsLink.connected;
    final Widget content;
    if (state.agents.isEmpty) {
      content = const _Notice(
        pose: CritterPose.idle,
        title: 'no agents running',
        lines: ['start one with', 'agentctl new'],
        codeLine: 1,
      );
    } else {
      content = _deck(state);
    }
    if (!offline) return content;
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 0.35, child: content),
        Positioned(
          left: 0,
          right: 0,
          bottom: 22,
          child: Center(child: _OfflineChip(problem: snap.problem)),
        ),
      ],
    );
  }

  /// Long-press a tile and drop it on another to swap the two agents, or on
  /// a free cell to move it there. Positions are stored by the daemon, so the
  /// web board follows.
  /// A cell of the deck, and the whole of picking a tile up and putting it
  /// down.
  ///
  /// This does not use LongPressDraggable. That recognizer competes in the
  /// gesture arena with the pager either side of it and loses: measured on a
  /// phone, holds of 0.7 to 1.2 s that travelled 170 px started nothing at
  /// all, because DelayedMultiDragGestureRecognizer gives up once the pointer
  /// passes touch slop before its delay is up -- which is what a drag is.
  ///
  /// A Listener sees the pointer without entering the arena, so nothing can
  /// take it away. The tile arms on a timer whether or not the finger has
  /// moved, and from then on the tile itself follows the finger; the cell
  /// under it is found by asking each cell where it is.
  Widget _swapCell(
    AgentsState state, {
    required int slot,
    String? id,
    String title = '',
    required Widget child,
  }) {
    final key = _cellKeys.putIfAbsent(slot, GlobalKey.new);
    final held = _heldId != null && _heldSlot == slot;
    final over = _heldId != null && _overSlot == slot && _heldSlot != slot;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: id == null ? null : (e) => _armHold(id, slot, e),
      onPointerMove: _heldId == null ? null : (e) => _holdMoved(e),
      onPointerUp: (e) => _holdEnded(),
      onPointerCancel: (e) => _holdEnded(),
      child: Stack(
        key: key,
        fit: StackFit.expand,
        children: [
          // The tile it came from stays in place, faded, so where it was is
          // still readable while it is in hand.
          held ? Opacity(opacity: 0.25, child: child) : child,
          if (over)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // As thick as the gauge round every tile, which is set in
                  // Settings: a frame of its own width read as a heavier
                  // line than anything else on the deck.
                  border: Border.all(
                    color: DeckHud.ink,
                    width: widget.contextRingWidth,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Picks a tile up after [_holdDelay], moved or not.
  void _armHold(String id, int slot, PointerDownEvent e) {
    _holdTimer?.cancel();
    _pointer = e.position;
    final box = _cellKeys[slot]?.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) _heldSize = box.size;
    _holdTimer = Timer(_holdDelay, () {
      if (!mounted) return;
      Haptics.fire(HapticWhen.hold);
      setState(() {
        _heldId = id;
        _heldSlot = slot;
        _overSlot = slot;
        _dragging = true;
      });
    });
  }

  void _holdMoved(PointerMoveEvent e) {
    if (_heldId == null) return;
    final slot = _slotUnder(e.position);
    setState(() {
      _pointer = e.position;
      if (slot != null) _overSlot = slot;
    });
    _turnPageAtEdge(e.position);
  }

  /// Carried to the left or right edge of the deck, the page turns, the way
  /// an icon carried to the edge of a home screen does.
  void _turnPageAtEdge(Offset p) {
    if (_edgeTimer != null) return; // one turn at a time
    final box = _deckKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    const margin = 44.0;
    final step = p.dx <= rect.left + margin
        ? -1
        : p.dx >= rect.right - margin
        ? 1
        : 0;
    if (step == 0) return;
    final next = _view + step;
    // Never back past the "Needs you" page: a card belongs to the deck.
    if (next < 1 + _lead || next > _pages + _lead) return;
    _goTo(next);
    _edgeTimer = Timer(const Duration(milliseconds: 700), () {
      _edgeTimer = null;
    });
  }

  void _holdEnded() {
    _holdTimer?.cancel();
    _holdTimer = null;
    final id = _heldId, from = _heldSlot, to = _overSlot;
    if (id != null && to != null && to != from) {
      widget.source.move(id, to);
    }
    if (_heldId != null) {
      setState(() {
        _heldId = null;
        _heldSlot = null;
        _overSlot = null;
        _dragging = false;
      });
    }
  }

  /// Which cell is under [p], by asking every cell on this page where it is.
  int? _slotUnder(Offset p) {
    for (final e in _cellKeys.entries) {
      final box = e.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(p)) return e.key;
    }
    return null;
  }

  /// Pages of 16 slots (page = slot ~/ 16), side by side, with the "Needs
  /// you" screen before the first: swipe between them, scroll, use the arrow
  /// keys or click a bar. The tiles keep their width and get a little shorter
  /// so the bar row fits in the same square.
  Widget _deck(AgentsState state) {
    _watchFlights(state);
    _reportView(state);
    // While a card is in hand there is always one more page than the deck
    // needs, so it can be carried somewhere new; it stays only if something
    // is put on it.
    final pages =
        _pageCount(state.agents.map((a) => a.slot)) + (_heldId == null ? 0 : 1);
    _pages = pages;
    // The host's own pages sit past the deck's, so the view may legitimately
    // be beyond the last deck page.
    final last = pages + _lead + widget.trailingPages.length;
    if (_view > last) _view = last;
    final hot = {
      for (final a in state.agents)
        if (a.needsYou) _pageOf(a.slot),
    };
    final needsYou = NeedsYou.of(state);
    // One buzz when the deck starts needing you, not one per rebuild.
    if (needsYou.count > _wasNeeded) {
      Haptics.fire(HapticWhen.needsYou);
    }
    _wasNeeded = needsYou.count;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final step = switch (e.logicalKey) {
          LogicalKeyboardKey.arrowLeft => -1,
          LogicalKeyboardKey.arrowRight => 1,
          _ => 0,
        };
        if (step == 0) return KeyEventResult.ignored;
        _goTo((_view + step).clamp(0, pages + _lead));
        return KeyEventResult.handled;
      },
      child: Padding(
        key: _deckKey,
        // On whole device pixels when the host scales the deck.
        padding: EdgeInsets.fromLTRB(
          DeckPixels.snap(context, 8),
          DeckPixels.snap(context, 8),
          DeckPixels.snap(context, 8),
          0,
        ),
        child: Stack(
          children: [
            Column(
              children: [
                // Each account's week, on the panel (the menu bar says it in
                // its status line).
                if (!widget.menuBar &&
                    state.limits.isNotEmpty &&
                    (!widget.usageFollowsSetting || state.usageAsked))
                  SizedBox(
                    height: 26,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: UsageLine(state: state),
                    ),
                  ),
                Expanded(
                  child: PageView.builder(
                    key: const Key('agents-pages'),
                    controller: _pager,
                    // Still while a card is in hand, and still while someone
                    // is speaking to an agent: a page turning under the
                    // finger would take the tile the words are for away.
                    physics: _dragging || _speakingTo != null
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    itemCount: pages + 1 + _lead + widget.trailingPages.length,
                    onPageChanged: (v) {
                      Haptics.fire(HapticWhen.page);
                      setState(() => _view = v);
                    },
                    itemBuilder: (context, v) => v < _lead
                        ? _leading[v]
                        : v >= pages + 1 + _lead
                        ? widget.trailingPages[v - pages - 1 - _lead]
                        : v == _lead
                        ? AttentionScreen(
                            needsYou: needsYou,
                            columns:
                                (widget.attentionShape ?? _shape(0)).columns,
                            rows: (widget.attentionShape ?? _shape(0)).rows,
                            tile: (a) => _speakCell(
                              a,
                              AgentTile(
                                key: ValueKey('attention-tile-${a.id}'),
                                agent: a,
                                state: state,
                                onOpen: _open,
                                // With an ear, the hold is the callout's
                                // (below); without one it is the host's, if
                                // the host wants it.
                                onHold: widget.ear == null
                                    ? widget.onHoldAttention
                                    : null,
                                ringWidth: widget.contextRingWidth,
                              ),
                            ),
                          )
                        : DeckGrid(
                            cells: _cellsFor(state, v - 1 - _lead),
                            square: false,
                            columns: _shape(v - 1 - _lead).columns,
                            rows: _shape(v - 1 - _lead).rows,
                          ),
                  ),
                ),
                SizedBox(
                  height: _barsHeight,
                  child: _PageBars(
                    pages: pages,
                    current: _view - 1 - _lead,
                    hot: hot,
                    attention: needsYou.count,
                    onTap: (p) => _goTo(p + 1 + _lead),
                    onAttention: () => _goTo(_lead),
                    titles: widget.pageTitles,
                    onRename: widget.onRenamePage,
                  ),
                ),
              ],
            ),
            // The card in hand: the tile itself, following the finger. Not a
            // stand-in for it.
            if (_carried(state) case final a?) _carriedCard(a, state),
            // Speaking to an agent on the "Needs you" screen: the words land
            // in a bubble beside its tile rather than on a page of their own.
            if (_speakingTo case final a?)
              if (_speakingAt case final tile?) _speechCallout(a, tile),
          ],
        ),
      ),
    );
  }

  Agent? _carried(AgentsState state) {
    final id = _heldId;
    if (id == null) return null;
    for (final a in state.agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// The carried card, centred on the finger and a little larger, so it reads
  /// as lifted off the deck.
  Widget _carriedCard(Agent a, AgentsState state) {
    final box = _deckKey.currentContext?.findRenderObject();
    final origin = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero)
        : Offset.zero;
    final local = _pointer - origin;
    return Positioned(
      left: local.dx - _heldSize.width / 2,
      top: local.dy - _heldSize.height / 2,
      width: _heldSize.width,
      height: _heldSize.height,
      child: IgnorePointer(
        child: Transform.scale(
          scale: 1.08,
          child: AgentTile(
            key: ValueKey('carried-${a.id}'),
            agent: a,
            state: state,
            onOpen: (_, _, _) {},
          ),
        ),
      ),
    );
  }

  static const _barsHeight = 34.0;

  void _goTo(int view) {
    if (!_pager.hasClients || view == _view) return;
    _pager.animateToPage(
      view,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  List<Widget> _cellsFor(AgentsState state, int page) {
    final bySlot = {for (final a in state.agents) a.slot: a};
    final leftFrom = {for (final a in _leaving) a.slot: a};
    final shape = _shape(page);
    final start = _start(page);
    // The order the tiles fly in: by place, as on the board.
    final order = <String, int>{};
    for (final a in [
      ..._leaving,
      ...state.agents.where((a) => _arriving.contains(a.id)),
    ]..sort((a, b) => a.slot.compareTo(b.slot))) {
      order[a.id] = order.length;
    }
    Widget fly(Agent a, int slot, Widget tile, {required bool leave}) => _Fly(
      key: ValueKey('fly-$_flight-${a.id}'),
      col: (slot - start) % shape.columns,
      row: (slot - start) ~/ shape.columns,
      columns: shape.columns,
      rows: shape.rows,
      leave: leave,
      corner: leave ? _leaveCorner : _arriveCorner,
      delay: Duration.zero, // all at once: a swarm
      child: tile,
    );
    return [
      for (var slot = start; slot < start + shape.cells; slot++)
        if (bySlot[slot] case final a?)
          _swapCell(
            state,
            slot: slot,
            id: a.id,
            title: a.title,
            child: _arriving.contains(a.id)
                ? fly(
                    a,
                    slot,
                    AgentTile(
                      key: ValueKey('agent-tile-${a.id}'),
                      agent: a,
                      state: state,
                      onOpen: _open,
                      ringWidth: widget.contextRingWidth,
                    ),
                    leave: false,
                  )
                : AgentTile(
                    key: ValueKey('agent-tile-${a.id}'),
                    agent: a,
                    state: state,
                    onOpen: _open,
                    ringWidth: widget.contextRingWidth,
                  ),
          )
        else
          _swapCell(
            state,
            slot: slot,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _FreeCell(onOpen: (ctx, key) => _openPicker(ctx, key, slot)),
                if (leftFrom[slot] case final a?)
                  IgnorePointer(
                    child: fly(
                      a,
                      slot,
                      AgentTile(
                        key: ValueKey('gone-tile-${a.id}'),
                        agent: a,
                        state: state,
                        onOpen: (_, _, _) {},
                      ),
                      leave: true,
                    ),
                  ),
              ],
            ),
          ),
    ];
  }
}

/// One agent on the board: tool chip, critter, title, status line.
class AgentTile extends StatefulWidget {
  const AgentTile({
    super.key,
    required this.agent,
    required this.state,
    this.ringWidth = ContextRingPainter.defaultStroke,
    required this.onOpen,
    this.onHold,
  });

  final Agent agent;
  final AgentsState state;

  /// Held rather than tapped: dictation on the "Needs you" screen, where a
  /// tile is not carried anywhere. Null leaves the gesture alone.
  final void Function(Agent a)? onHold;
  final void Function(BuildContext tileContext, GlobalKey tileKey, Agent a)
  onOpen;

  /// How thick the context gauge around the card is drawn, in points.
  final double ringWidth;

  @override
  State<AgentTile> createState() => _AgentTileState();
}

class _AgentTileState extends State<AgentTile> {
  static const _tileDesign = 170.0;
  final _tileKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final a = widget.agent;
    final look = AgentLook.of(a);
    // Out of usage: an orange edge, the pet dimmed, until when it is back.
    final out = a.needsYou ? null : widget.state.outUntil(a);
    return Pressable(
      key: _tileKey,
      onLongPress: widget.onHold == null ? null : () => widget.onHold!(a),
      onTap: () => widget.onOpen(context, _tileKey, a),
      builder: (context, pressed) {
        // Pressed = the deck's ink invert.
        final fill = pressed ? DeckHud.ink : look.fill;
        Color c(Color v) => pressed ? DeckHud.bg : v;
        return RepaintBoundary(
          child: CustomPaint(
            // Over the content so the ring never shifts the layout.
            foregroundPainter: pressed
                ? null
                : out != null
                ? const _OutEdgePainter()
                : ContextRingPainter(
                    fraction: a.contextFraction,
                    color: look.ring,
                    track: look.ringTrack,
                    stroke: widget.ringWidth,
                  ),
            child: Container(
              color: fill,
              child: Stack(
                children: [
                  if (look.stripes && !pressed)
                    const Positioned.fill(child: HungryStripes()),
                  // The tool's colour, or (with more than one Claude account
                  // set up) the colour of the account it runs in.
                  if (!pressed)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Semantics(
                        label: a.account == null
                            ? null
                            : '${a.account!.name} account',
                        child: Container(
                          key: a.account == null
                              ? null
                              : const Key('agent-tile-account'),
                          width: 8,
                          height: 8,
                          color: a.account == null
                              ? look.chip
                              : hatColor(a.account!.color).$1,
                        ),
                      ),
                    ),
                  // Subagents at work, with pets on: only how many, in the
                  // top-left corner (the pet shows a mini pet in tow when
                  // its agent delegates).
                  if (a.subagents.isNotEmpty && a.pet != null)
                    Positioned(
                      top: 9,
                      left: 10,
                      child: Text(
                        '${a.subagents.length} SUB',
                        key: const Key('agent-tile-subagents'),
                        style: DeckHud.rm(
                          11,
                          c(look.meta),
                          weight: 700,
                          spacing: 1.3,
                        ),
                      ),
                    )
                  // Without pets: a small critter in the top-left corner
                  // (body only), with a count when there are more.
                  else if (a.subagents.isNotEmpty)
                    Positioned(
                      top: 8,
                      left: 9,
                      child: Row(
                        key: const Key('agent-tile-subagents'),
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              widthFactor: 14 / 18,
                              child: CritterSprite(
                                pose: critterPoseForTool(
                                  a.subagents.first.tool,
                                ),
                                width: 36,
                                body: c(look.body),
                                cut: fill,
                              ),
                            ),
                          ),
                          if (a.subagents.length > 1)
                            Padding(
                              padding: const EdgeInsets.only(left: 3),
                              child: Text(
                                '×${a.subagents.length}',
                                style: DeckHud.mono(
                                  size: 11,
                                  color: c(look.meta),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  // Laid out on the deck's 170 px cell and scaled to the
                  // real one, so any grid size keeps the same composition.
                  Positioned.fill(
                    child: FittedBox(
                      child: SizedBox.square(
                        dimension: _tileDesign,
                        child: Column(
                          children: [
                            // With Agent pets on, its pet takes the
                            // critter's place: on its baseline (no line
                            // drawn), at the critter's scale, smaller when its glow, hat
                            // or bubble would leave the tile (nothing
                            // does). It does its agent's pose, in its own
                            // colours with its black stroke (on orange
                            // too).
                            if (a.pet case final pet?) ...[
                              const SizedBox(height: 8),
                              Opacity(
                                opacity: out == null ? 1 : 0.55,
                                child: PetSprite(
                                  fit: true,
                                  cell: 92 / 18,
                                  height: 96,
                                  pet: pet,
                                  hat: a.hat,
                                  pose: critterPoseOf(
                                    a,
                                    inStatus: widget.state.inStatus(a),
                                  ),
                                  celebrateUntil: DateTime.now().add(
                                    critterCelebration -
                                        widget.state.inStatus(a),
                                  ),
                                  afterCelebrate: a.unseen
                                      ? CritterPose.hungry
                                      : CritterPose.idle,
                                  width: _tileDesign - 12,
                                ),
                              ),
                              const SizedBox(height: 6),
                            ] else ...[
                              const SizedBox(height: 30),
                              agentMascot(
                                a,
                                pose: critterPoseOf(
                                  a,
                                  inStatus: widget.state.inStatus(a),
                                ),
                                celebrateUntil: DateTime.now().add(
                                  critterCelebration - widget.state.inStatus(a),
                                ),
                                afterCelebrate: a.unseen
                                    ? CritterPose.hungry
                                    : CritterPose.idle,
                                centerBody: true,
                                width: 92,
                                body: c(look.body),
                                bubbleColor: look.bubble == null
                                    ? null
                                    : c(look.bubble!),
                                cut: fill,
                              ),
                              const SizedBox(height: 14),
                            ],
                            _line(
                              a.title,
                              DeckHud.mono(size: 16, color: c(look.label)),
                            ),
                            const SizedBox(height: 5),
                            _line(
                              out != null
                                  ? 'out · ${resetText(out)}'
                                  : agentMetaLine(a, widget.state),
                              DeckHud.mono(
                                size: 12.5,
                                color: c(
                                  out != null ? DeckHud.accent : look.meta,
                                ),
                              ).copyWith(letterSpacing: 0.4),
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
        );
      },
    );
  }

  static Widget _line(String text, TextStyle style) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: style,
    ),
  );
}

/// A tile out of usage: a solid orange edge, inside it.
class _OutEdgePainter extends CustomPainter {
  const _OutEdgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      (Offset.zero & size).deflate(1.5),
      Paint()
        ..color = DeckHud.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_OutEdgePainter old) => false;
}

/// Diagonal accent stripes sliding across a hungry tile (a finished agent
/// whose result nobody has looked at yet), driven by the shared critter clock.
class HungryStripes extends StatefulWidget {
  const HungryStripes({super.key});

  @override
  State<HungryStripes> createState() => _HungryStripesState();
}

class _HungryStripesState extends State<HungryStripes> {
  final _step = ValueNotifier<int>(0);
  CritterClock? _clock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = CritterScope.of(context);
    if (c != _clock) {
      _clock?.removeListener(_tick);
      _clock = c?..addListener(_tick);
    }
    _tick();
  }

  // One step every 100 ms: a calm, stepped slide.
  void _tick() => _step.value = ((_clock?.value ?? 0) ~/ 2) % 6;

  @override
  void dispose() {
    _clock?.removeListener(_tick);
    _step.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: CustomPaint(painter: _StripesPainter(_step)));
}

class _StripesPainter extends CustomPainter {
  _StripesPainter(this.step) : super(repaint: step);
  final ValueListenable<int> step;

  static const period = 24.0; // stripe + gap, along x

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final p = Paint()..color = DeckHud.accent.withValues(alpha: 0.16);
    final shift = step.value * period / 6;
    for (var x = -size.height - period + shift; x < size.width; x += period) {
      canvas.drawPath(
        Path()
          ..moveTo(x, size.height)
          ..lineTo(x + period / 2, size.height)
          ..lineTo(x + period / 2 + size.height, 0)
          ..lineTo(x + size.height, 0)
          ..close(),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_StripesPainter old) => false;
}

/// What follows the finger while a tile is dragged.

/// The tile's border as a context gauge: [fraction] of the perimeter, drawn
/// clockwise from the top centre over a faint full-length track.
class ContextRingPainter extends CustomPainter {
  ContextRingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    this.stroke = defaultStroke,
  });

  final double fraction;
  final Color color;
  final Color track;

  /// How thick the gauge is drawn, in points.
  final double stroke;

  static const defaultStroke = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final h = stroke / 2;
    final w = size.width, ht = size.height;
    final path = Path()
      ..moveTo(w / 2, h)
      ..lineTo(w - h, h)
      ..lineTo(w - h, ht - h)
      ..lineTo(h, ht - h)
      ..lineTo(h, h)
      ..close();
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;
    canvas.drawPath(path, paint..color = track);
    final f = fraction.clamp(0.0, 1.0);
    if (f > 0) {
      final metric = path.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * f),
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(ContextRingPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.track != track ||
      old.stroke != stroke;
}

/// Unused slot: near-black block with a faint frame.
/// A free cell: tap it to add a session there.
/// A tile on its way: from its place to just past the bottom-left corner of
/// the grid (leave), or from just past the top-left corner to its place,
/// shrinking toward the corner and fading there.
class _Fly extends StatefulWidget {
  const _Fly({
    super.key,
    required this.col,
    required this.row,
    required this.columns,
    required this.rows,
    required this.leave,
    required this.corner,
    required this.delay,
    required this.child,
  });

  final int col, row;

  /// The page's shape, so a tile flies off the edge it is actually nearest.
  final int columns, rows;
  final bool leave;
  final String corner; // top-left | top-right | bottom-left | bottom-right
  final Duration delay;
  final Widget child;

  @override
  State<_Fly> createState() => _FlyState();
}

class _FlyState extends State<_Fly> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.leave) _c.value = 0;
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // In cells: the corner one cell past the grid's edge.
    final left = widget.corner.endsWith('left');
    final top = widget.corner.startsWith('top');
    final corner = Offset(
      left ? -1.0 - widget.col : widget.columns - widget.col.toDouble(),
      top ? -1.0 - widget.row : widget.rows - widget.row.toDouble(),
    );
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // Leaving: place -> corner, speeding up. Coming: corner -> place, slowing down.
        final t = widget.leave
            ? Curves.easeInCubic.transform(_c.value)
            : 1 - Curves.easeOutCubic.transform(_c.value);
        return FractionalTranslation(
          translation: corner * t,
          child: Transform.scale(
            scale: 1 - 0.6 * t,
            alignment: Alignment.center,
            child: Opacity(opacity: (1 - t * t).clamp(0.0, 1.0), child: child),
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _FreeCell extends StatefulWidget {
  const _FreeCell({required this.onOpen});

  final void Function(BuildContext context, GlobalKey key) onOpen;

  @override
  State<_FreeCell> createState() => _FreeCellState();
}

class _FreeCellState extends State<_FreeCell> {
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: _key,
    behavior: HitTestBehavior.opaque,
    onTap: () => widget.onOpen(context, _key),
    child: const AgentsEmptyTile(),
  );
}

class AgentsEmptyTile extends StatelessWidget {
  const AgentsEmptyTile({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: agentsEmptyFill,
        border: Border.all(color: agentsEmptyOutline),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// One rounded bar per page under the deck: the current one wide and bright,
/// another page's orange when an agent there needs you. Tap one to go there.
/// At the far left, an outlined mark for the "Needs you" screen, with how
/// many agents are on it while you are elsewhere.
class _PageBars extends StatefulWidget {
  const _PageBars({
    required this.pages,
    required this.current,
    required this.hot,
    required this.attention,
    required this.onTap,
    required this.onAttention,
    this.titles = const {},
    this.onRename,
  });

  final int pages;

  /// The page shown; -1 = the "Needs you" screen.
  final int current;
  final Set<int> hot;

  /// Agents on the "Needs you" screen.
  final int attention;
  final ValueChanged<int> onTap;
  final VoidCallback onAttention;

  /// What each page is called, by index; -1 is the "Needs you" screen.
  final Map<int, String> titles;

  /// Null means the name cannot be changed here, so it is drawn as a label.
  final void Function(int page, String title)? onRename;

  @override
  State<_PageBars> createState() => _PageBarsState();
}

class _PageBarsState extends State<_PageBars> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    // Tapping away is "done", the same as the keyboard's own return.
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// What the page shown is called: its own name, or what it is by default.
  String get _title => widget.titles[widget.current] ?? _fallback;

  String get _fallback =>
      widget.current < 0 ? 'needs you' : 'page ${widget.current + 1}';

  void _start() {
    _controller.text = _title;
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  /// A name that is empty, or the default spelled out, is no name at all: the
  /// page goes back to being called what it is.
  void _commit() {
    final name = _controller.text.trim();
    widget.onRename?.call(widget.current, name == _fallback ? '' : name);
    setState(() => _editing = false);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final here = widget.current < 0;
    final lit = here || widget.attention > 0;
    final pages = widget.pages;
    final current = widget.current;
    final attention = widget.attention;
    final hot = widget.hot;
    final onTap = widget.onTap;
    final onAttention = widget.onAttention;
    return Semantics(
      label: here ? 'needs you' : 'page ${current + 1} of $pages',
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          // The name sits at the far left and the bars stay centred, so
          // neither moves the other as a name gets longer.
          Positioned(
            left: 8,
            right: 0,
            child: _PageName(
              title: _title,
              editing: _editing,
              controller: _controller,
              focus: _focus,
              onStart: widget.onRename == null ? null : _start,
              onDone: _commit,
            ),
          ),
          Row(
            key: const Key('agents-pager'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Semantics(
                button: true,
                label: attention == 0 ? 'needs you' : '$attention need you',
                child: GestureDetector(
                  key: const Key('agents-page-attention'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onAttention,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
                    child: Row(
                      children: [
                        if (!here && attention > 0) ...[
                          Text(
                            '$attention',
                            key: const Key('agents-attention-count'),
                            style: DeckHud.rm(15, DeckHud.accent, weight: 600),
                          ),
                          const SizedBox(width: 7),
                        ],
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: here ? 56 : 30,
                          height: 10,
                          decoration: BoxDecoration(
                            color: here ? DeckHud.accent : null,
                            border: Border.all(
                              color: lit ? DeckHud.accent : DeckHud.dim,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.zero,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              for (var p = 0; p < pages; p++)
                GestureDetector(
                  key: Key('agents-page-$p'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(p),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: p == current ? 56 : 30,
                      height: 8,
                      decoration: BoxDecoration(
                        // Where you are is always bright; other pages turn
                        // orange when an agent there needs you.
                        color: p == current
                            ? DeckHud.ink
                            : (hot.contains(p)
                                  ? DeckHud.accent
                                  : const Color(0xFF2A2925)),
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The page's name at the left of the pager: a label, or a line to type in
/// once it is tapped.
class _PageName extends StatelessWidget {
  const _PageName({
    required this.title,
    required this.editing,
    required this.controller,
    required this.focus,
    required this.onStart,
    required this.onDone,
  });

  final String title;
  final bool editing;
  final TextEditingController controller;
  final FocusNode focus;

  /// Null where the host cannot keep a name: then this is only a label.
  final VoidCallback? onStart;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    if (editing) {
      return SizedBox(
        width: 150,
        child: EditableText(
          key: const Key('agents-page-name-field'),
          controller: controller,
          focusNode: focus,
          style: DeckHud.mono(size: 12, color: DeckHud.ink),
          cursorColor: DeckHud.accent,
          backgroundCursorColor: DeckHud.dim,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onDone(),
          selectionColor: DeckHud.accent.withValues(alpha: 0.35),
        ),
      );
    }
    return Semantics(
      button: onStart != null,
      label: onStart == null ? title : '$title, rename',
      child: GestureDetector(
        key: const Key('agents-page-name'),
        behavior: HitTestBehavior.opaque,
        onTap: onStart,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: SizedBox(
            width: 150,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.mono(size: 12, color: DeckHud.dim),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineChip extends StatelessWidget {
  const _OfflineChip({this.problem});

  final String? problem;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('agents-offline'),
      constraints: const BoxConstraints(maxWidth: 640),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: DeckHud.panel,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: DeckHud.accent, width: 1.5),
      ),
      child: Text(
        'offline · retrying${problem == null ? '' : ' · $problem'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DeckHud.rm(14, DeckHud.accent),
      ),
    );
  }
}

/// Centred critter + a few lines (connecting, empty fleet).
class _Notice extends StatelessWidget {
  const _Notice({
    required this.pose,
    required this.title,
    this.lines = const [],
    this.codeLine,
  });

  final CritterPose pose;
  final String title;
  final List<String> lines;

  /// Index into [lines] rendered as a command (ink, Roboto Mono).
  final int? codeLine;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CritterSprite(
              pose: pose,
              width: 126,
              body: DeckHud.dim,
              cut: DeckHud.bg,
              centerBody: true,
            ),
            const SizedBox(height: 28),
            Text(
              title,
              textAlign: TextAlign.center,
              style: DeckHud.rm(28, DeckHud.ink, weight: 700),
            ),
            for (final (i, l) in lines.indexed) ...[
              const SizedBox(height: 12),
              Text(
                l,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: i == codeLine
                    ? DeckHud.rm(20, DeckHud.accent)
                    : DeckHud.mono(size: 16, color: DeckHud.dim),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Not paired yet: how to get the three values onto the panel.
class AgentsPairingCard extends StatelessWidget {
  const AgentsPairingCard({super.key, this.problem});

  /// Why saved values were not usable (e.g. a malformed agents.json).
  final String? problem;

  @override
  Widget build(BuildContext context) {
    Widget step(String n, List<InlineSpan> text) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(n, style: DeckHud.rm(20, DeckHud.accent, weight: 700)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: text),
              style: DeckHud.mono(
                size: 17,
                color: DeckHud.ink,
              ).copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
    TextSpan code(String s) =>
        TextSpan(text: s, style: DeckHud.rm(17, DeckHud.accent));
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Container(
        key: const Key('agents-pairing'),
        color: DeckHud.panel,
        padding: const EdgeInsets.fromLTRB(40, 44, 40, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CritterSprite(
              pose: CritterPose.wait,
              width: 90,
              body: DeckHud.ink,
              cut: DeckHud.panel,
            ),
            const SizedBox(height: 26),
            Text(
              'pair with your mac',
              style: DeckHud.rm(30, DeckHud.ink, weight: 700),
            ),
            const SizedBox(height: 10),
            Text(
              'the agents board needs a pairing bundle from your mac: '
              'its address, its certificate and a key for this panel.',
              style: DeckHud.mono(
                size: 16,
                color: DeckHud.dim,
              ).copyWith(height: 1.4),
            ),
            const SizedBox(height: 34),
            step('1', [
              const TextSpan(text: 'on the mac, run '),
              code('agentctl pair desk-panel --bundle -'),
            ]),
            step('2', [
              const TextSpan(text: 'open the panel setup page '),
              code(agentsSetupUrl()),
            ]),
            step('3', [
              const TextSpan(text: 'paste the whole output into '),
              TextSpan(
                text: 'agents',
                style: TextStyle(color: DeckHud.accent),
              ),
              const TextSpan(text: ' and save'),
            ]),
            const Spacer(),
            Text(
              problem ??
                  'the board connects by itself once the bundle is saved.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: DeckHud.mono(
                size: 14,
                color: problem == null ? DeckHud.dim : DeckHud.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The deck's text, whatever the host app's theme: every style here names
/// its own font and size, and this keeps the rest from inheriting the host's
/// (a Material theme's font, underlines outside a Material, a system text
/// scale). The deck is laid out in design pixels; hosts scale it as a
/// whole.
Widget agentsOwnText(Widget child) => Builder(
  builder: (context) => MediaQuery(
    data: (MediaQuery.maybeOf(context) ?? const MediaQueryData()).copyWith(
      textScaler: TextScaler.noScaling,
    ),
    child: DefaultTextStyle(
      style: DeckHud.rm(
        16,
        DeckHud.ink,
      ).copyWith(decoration: TextDecoration.none),
      child: child,
    ),
  ),
);

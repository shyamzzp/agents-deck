// Hold an agent on the "Needs you" screen and speak to it.
//
// The microphone opens as the sheet does, the words appear as they are
// recognised, and then it is sent or thrown away. Sending focuses the
// agent's terminal first, so what arrives is typed where you can see it.

import 'dart:async';

import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'dictation.dart';

class DictateSheet extends StatefulWidget {
  const DictateSheet({
    super.key,
    required this.agent,
    required this.source,
    required this.onClose,
  });

  final Agent agent;
  final AgentsSource source;
  final VoidCallback onClose;

  @override
  State<DictateSheet> createState() => _DictateSheetState();
}

enum _Stage { listening, paused, held, sending, sent, failed }

class _DictateSheetState extends State<DictateSheet> {
  StreamSubscription<Heard>? _sub;
  String _text = '';
  String? _problem;
  _Stage _stage = _Stage.listening;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(Dictation.stop());
    super.dispose();
  }

  Future<void> _open() async {
    _sub = Dictation.listen().listen((heard) {
      if (!mounted) return;
      setState(() {
        if (heard.error != null) {
          if (_text.isEmpty) _problem = heard.error;
          if (_stage == _Stage.listening) _stage = _Stage.held;
          return;
        }
        if (heard.text.isNotEmpty) _text = heard.text;
        // heard.done is a pause in the middle of a sentence, not the end of
        // what is being said: the recogniser starts a new piece and the
        // sheet keeps listening. Only "done", "pause" or "send" stop it.
        if (heard.paused) _stage = _Stage.paused;
      });
    });
    try {
      await Dictation.start();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = e.message ?? 'the microphone could not be opened';
        _stage = _Stage.held;
      });
    }
  }

  Future<void> _hold() async {
    await Dictation.stop();
    if (mounted) setState(() => _stage = _Stage.held);
  }

  /// Takes as long as you like: the microphone closes, the words stay, and
  /// resume carries on the same sentence.
  Future<void> _pause() async {
    await Dictation.pause();
    if (mounted) setState(() => _stage = _Stage.paused);
  }

  Future<void> _resume() async {
    setState(() => _stage = _Stage.listening);
    try {
      await Dictation.resume();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = e.message ?? 'the microphone could not be opened';
        _stage = _Stage.paused;
      });
    }
  }

  /// Focus the terminal, then put the text in it and press Enter: the same
  /// as pasting it there yourself.
  ///
  /// "now" is that, for an agent that can take it. An agent in the middle of
  /// a turn refuses it, so "type" puts it in anyway, which is typing ahead in
  /// its chat; one that is waiting on a question refuses both, and then it is
  /// queued and goes in when that turn ends.
  Future<void> _send() async {
    final text = _text.trim();
    if (text.isEmpty) return;
    setState(() => _stage = _Stage.sending);
    await Dictation.stop();
    await widget.source.focus(widget.agent.id);
    var sent = await widget.source.prompt(widget.agent.id, text, mode: 'now');
    for (final mode in ['type', 'queue']) {
      if (sent.isOk) break;
      sent = await widget.source.prompt(widget.agent.id, text, mode: mode);
    }
    if (!mounted) return;
    setState(() {
      _stage = sent.isOk ? _Stage.sent : _Stage.failed;
      _problem = sent.isOk ? null : (sent.message ?? 'it did not go in');
    });
    if (sent.isOk) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.agent;
    final listening = _stage == _Stage.listening;
    final busy = _stage == _Stage.sending;
    return ColoredBox(
      color: DeckHud.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      a.title.isEmpty ? a.id : a.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DeckHud.rm(20, DeckHud.ink, weight: 700),
                    ),
                  ),
                  Text(
                    switch (_stage) {
                      _Stage.listening => 'listening',
                      _Stage.paused => 'paused',
                      _Stage.held => 'ready',
                      _Stage.sending => 'sending',
                      _Stage.sent => 'sent',
                      _Stage.failed => 'not sent',
                    },
                    key: const Key('dictate-stage'),
                    style: DeckHud.mono(
                      size: 13,
                      color: listening ? DeckHud.accent : DeckHud.dim,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                a.waiting?.title.isNotEmpty == true
                    ? a.waiting!.title
                    : 'speak your answer',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DeckHud.mono(size: 13, color: DeckHud.dim),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    _text.isEmpty ? (_problem ?? '…') : _text,
                    key: const Key('dictate-text'),
                    style: DeckHud.rm(
                      20,
                      _text.isEmpty && _problem != null
                          ? DeckHud.accent
                          : DeckHud.ink,
                    ).copyWith(height: 1.4),
                  ),
                ),
              ),
              if (_problem != null && _text.isNotEmpty) ...[
                Text(
                  _problem!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: DeckHud.mono(size: 13, color: DeckHud.accent),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  // Pause while listening, resume while paused: speaking is
                  // not on a clock, and a long think should not end it.
                  if (listening || _stage == _Stage.paused) ...[
                    Flexible(
                      fit: FlexFit.loose,
                      child: AgentButton(
                        key: const Key('dictate-pause'),
                        label: listening ? 'pause' : 'resume',
                        padX: 6,
                        onTap: listening ? _pause : _resume,
                        fill: const Color(0x00000000),
                        ink: DeckHud.ink,
                        outline: DeckHud.dim,
                        pressedFill: DeckHud.ink,
                        pressedInk: DeckHud.bg,
                      ),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: AgentButton(
                      key: const Key('dictate-send'),
                      label: listening ? 'done' : 'send',
                      onTap: busy
                          ? null
                          : listening
                          ? _hold
                          : (_text.trim().isEmpty ? null : _send),
                      fill: DeckHud.ink,
                      ink: DeckHud.bg,
                      outline: DeckHud.ink,
                      pressedFill: DeckHud.accent,
                      pressedInk: DeckHud.bg,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Flexible(
                    fit: FlexFit.loose,
                    child: AgentButton(
                      key: const Key('dictate-cancel'),
                      label: 'cancel',
                      padX: 6,
                      onTap: busy ? null : widget.onClose,
                      fill: const Color(0x00000000),
                      ink: DeckHud.ink,
                      outline: DeckHud.dim,
                      pressedFill: DeckHud.ink,
                      pressedInk: DeckHud.bg,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

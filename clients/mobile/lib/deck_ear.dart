// The phone's ear, for the callout on the "Needs you" screen.
//
// The deck asks for this (DeckEar in the package) and knows nothing of
// platform channels; this is the other end, on Apple's on-device speech
// recognition (dictation.dart, Dictation.swift). Nothing is uploaded: the
// Swift side sets requiresOnDeviceRecognition.
//
// One turn of speaking at a time: start opens the microphone and clears what
// was heard before, stop closes it and keeps the words for the tick, cancel
// closes it and throws them away.

import 'dart:async';

import 'package:agents_deck_ui/agents_deck_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dictation.dart';

class PhoneEar implements DeckEar {
  final _heard = ValueNotifier<String>('');
  final _problem = ValueNotifier<String?>(null);
  StreamSubscription<Heard>? _sub;

  @override
  ValueListenable<String> get heard => _heard;

  @override
  ValueListenable<String?> get problem => _problem;

  @override
  Future<void> start() async {
    _heard.value = '';
    _problem.value = null;
    await _sub?.cancel();
    _sub = Dictation.listen().listen((h) {
      if (h.error != null) {
        _problem.value = h.error;
        return;
      }
      // Everything heard this turn, not the latest word: the bubble grows
      // rather than flickering between fragments.
      if (h.text.isNotEmpty) _heard.value = h.text;
    });
    try {
      await Dictation.start();
    } on PlatformException catch (e) {
      // The microphone or speech recognition is off for this app: the bubble
      // says so instead of the words.
      _problem.value = e.message ?? 'this phone cannot listen';
      await _sub?.cancel();
      _sub = null;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await Dictation.stop();
    } on PlatformException {
      // Already closed: what was heard is what there is.
    }
    // The recogniser finishes its sentence after the microphone closes, so
    // the subscription stays until the callout is done with.
  }

  @override
  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await Dictation.stop();
    } on PlatformException {
      // Nothing was listening.
    }
    _heard.value = '';
    _problem.value = null;
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _heard.dispose();
    _problem.dispose();
  }
}

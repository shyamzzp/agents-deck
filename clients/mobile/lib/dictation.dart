// Speaking to an agent: the app's side of Dictation.swift.
//
// Apple's speech recognition runs on the phone (the Swift side sets
// requiresOnDeviceRecognition), so what is said is turned into text here and
// nothing is uploaded. This file is only the channel: the sheet that shows
// the words and sends them is in dictate_sheet.dart.

import 'dart:async';

import 'package:flutter/services.dart';

/// What has been heard so far, or why listening stopped.
class Heard {
  const Heard({this.text = '', this.done = false, this.error});

  /// Everything recognised in this turn of speaking, not just the latest word.
  final String text;

  /// The recogniser considers this the finished sentence.
  final bool done;

  /// Set instead of text when listening ended badly (or was stopped with
  /// nothing said, which the recogniser also reports as an error).
  final String? error;
}

class Dictation {
  static const _methods = MethodChannel('deck/dictation');
  static const _events = EventChannel('deck/dictation/events');

  /// Whether this device can recognise speech at all (a simulator cannot).
  static Future<bool> available() async =>
      await _methods.invokeMethod<bool>('available') ?? false;

  /// Opens the microphone. Throws a [PlatformException] when the microphone or
  /// speech recognition is off for this app, with a line to show the person.
  static Future<void> start() => _methods.invokeMethod<void>('start');

  /// Closes the microphone and lets the recogniser finish its sentence.
  static Future<void> stop() => _methods.invokeMethod<void>('stop');

  /// What is being heard, as it arrives.
  static Stream<Heard> listen() => _events.receiveBroadcastStream().map((e) {
    final m = (e as Map).cast<Object?, Object?>();
    final error = m['error'];
    if (error is String) return Heard(error: error);
    return Heard(
      text: m['text'] as String? ?? '',
      done: m['final'] as bool? ?? false,
    );
  });
}

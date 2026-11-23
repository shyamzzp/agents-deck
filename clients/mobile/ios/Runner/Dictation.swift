// Speaking to an agent: Apple's own speech recognition, on the device.
//
// Held on the "Needs you" screen, a tile opens the microphone; what is said
// is transcribed here and shown in the app as it comes, and the text is then
// sent to the agent's terminal. requiresOnDeviceRecognition is set, so the
// audio does not leave the phone: the same model dictation uses.
//
// Two channels, the shape Flutter expects: methods to start and stop, and a
// stream of what has been heard so far.

import AVFoundation
import Flutter
import Speech

final class Dictation: NSObject, FlutterStreamHandler {
  static let methodChannel = "deck/dictation"
  static let eventChannel = "deck/dictation/events"

  private let recognizer = SFSpeechRecognizer(locale: Locale.current)
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var sink: FlutterEventSink?

  /// Speech recognition hands back a finished sentence as soon as it hears a
  /// pause, and that ends its task. Thinking mid-sentence is not the end of
  /// what someone has to say, so each finished piece is kept here and the
  /// next task starts on a clean request; what the app shows is this plus
  /// whatever the current task has heard.
  private var kept = ""

  /// Set while the microphone is deliberately closed (pause) or finished, so
  /// a task ending does not start another one.
  private var paused = false
  private var stopped = true

  /// When the last task was started, to tell a pause from a recogniser that
  /// fails the moment it is asked.
  private var startedAt = Date.distantPast

  /// Which task's results count. A task that has handed back its sentence can
  /// still deliver a late partial of the same words, which would be added to
  /// the kept text and read as the words appearing twice.
  private var generation = 0

  // MARK: channels

  static func register(with registrar: FlutterPluginRegistrar) {
    let d = Dictation()
    let methods = FlutterMethodChannel(
      name: methodChannel, binaryMessenger: registrar.messenger())
    methods.setMethodCallHandler { call, result in d.handle(call, result) }
    FlutterEventChannel(name: eventChannel, binaryMessenger: registrar.messenger())
      .setStreamHandler(d)
    // The handler is the only strong reference the channels keep.
    objc_setAssociatedObject(registrar.messenger(), &Dictation.key, d, .OBJC_ASSOCIATION_RETAIN)
  }

  private static var key = 0

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(recognizer?.isAvailable == true)
    case "start":
      start(result)
    case "pause":
      // The words stay; the microphone closes until resume.
      holdOn()
      result(nil)
    case "resume":
      guard let recognizer, !stopped else {
        result(nil)
        return
      }
      paused = false
      do {
        try listen(recognizer)
        result(true)
      } catch {
        result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
      }
    case "stop":
      finish()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: listening

  /// Asks for the two permissions it needs, then opens the microphone. The
  /// result is true once audio is flowing, or a FlutterError saying which
  /// permission was refused.
  private func start(_ result: @escaping FlutterResult) {
    guard let recognizer, recognizer.isAvailable else {
      result(FlutterError(code: "unavailable",
                          message: "speech recognition is not available on this device",
                          details: nil))
      return
    }
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          result(FlutterError(code: "denied",
                              message: "speech recognition is off for this app (Settings › agents deck)",
                              details: nil))
          return
        }
        // AVAudioApplication is iOS 17; the app runs on older iPads too.
        let ask: (@escaping (Bool) -> Void) -> Void = { done in
          if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: done)
          } else {
            AVAudioSession.sharedInstance().requestRecordPermission(done)
          }
        }
        ask { granted in
          DispatchQueue.main.async {
            guard granted else {
              result(FlutterError(code: "denied",
                                  message: "the microphone is off for this app (Settings › agents deck)",
                                  details: nil))
              return
            }
            do {
              try self.listen(recognizer)
              result(true)
            } catch {
              result(FlutterError(code: "failed",
                                  message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    }
  }

  private func listen(_ recognizer: SFSpeechRecognizer) throws {
    endTask(keepText: true)
    stopped = false
    startedAt = Date()

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: .duckOthers)
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // The whole point: Apple's model, running here, with nothing uploaded.
    request.requiresOnDeviceRecognition = true
    self.request = request

    generation += 1
    let gen = generation
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self, gen == self.generation else { return } // a late word
      if let result {
        let heard = result.bestTranscription.formattedString
        if result.isFinal {
          // Stopped speaking: keep the sentence and close the microphone,
          // rather than listen on or end the whole thing. Resume carries on.
          self.keep(heard)
          self.holdOn()
          return
        }
        self.send(["text": self.text(heard), "final": false])
        return
      }
      if error != nil {
        // A recogniser that fails the instant it is asked is a real failure;
        // otherwise this is the same silence, reported the other way.
        if Date().timeIntervalSince(self.startedAt) < 0.5, self.kept.isEmpty {
          self.send(["error": "speech recognition stopped; hold the tile again"])
          self.finish()
          return
        }
        self.holdOn()
      }
    }

    let input = engine.inputNode
    if !engine.isRunning {
      input.removeTap(onBus: 0)
      // The tap reads self.request rather than this one, so a task that ends
      // on a pause can be replaced without the microphone missing a word.
      input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
        [weak self] buffer, _ in
        self?.request?.append(buffer)
      }
      engine.prepare()
      try engine.start()
    }
  }

  /// Everything said so far: the pieces already finished, and the piece being
  /// spoken now.
  private func text(_ current: String) -> String {
    if kept.isEmpty { return current }
    if current.isEmpty { return kept }
    return kept + " " + current
  }

  private func keep(_ piece: String) {
    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    kept = kept.isEmpty ? trimmed : kept + " " + trimmed
  }

  /// Waits, with the words kept: the microphone closes and the app shows
  /// "paused", so resume picks the sentence up where it was left.
  private func holdOn() {
    guard !stopped else { return }
    paused = true
    generation += 1 // nothing more from the task that just ended
    closeAudio()
    endTask(keepText: true)
    send(["text": text(""), "final": false, "paused": true])
  }

  /// Stops listening for good: the microphone closes and the text is cleared,
  /// since the next hold is a new thing to say.
  private func finish() {
    stopped = true
    paused = false
    closeAudio()
    endTask(keepText: false)
  }

  private func closeAudio() {
    if engine.isRunning {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func endTask(keepText: Bool) {
    request?.endAudio()
    request = nil
    task?.finish()
    task = nil
    if !keepText { kept = "" }
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async { self.sink?(event) }
  }
}

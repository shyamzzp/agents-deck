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
    finish() // whatever was running before

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: .duckOthers)
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // The whole point: Apple's model, running here, with nothing uploaded.
    request.requiresOnDeviceRecognition = true
    self.request = request

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        self.send([
          "text": result.bestTranscription.formattedString,
          "final": result.isFinal,
        ])
        if result.isFinal { self.finish() }
        return
      }
      if let error {
        // A stop with nothing said ends the task with an error; the app has
        // the text already, so it is reported and not treated as a failure.
        self.send(["error": error.localizedDescription])
        self.finish()
      }
    }

    let input = engine.inputNode
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
      buffer, _ in
      request.append(buffer)
    }
    engine.prepare()
    try engine.start()
  }

  /// Stops the microphone and lets the recogniser finish what it has.
  private func finish() {
    if engine.isRunning {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
    }
    request?.endAudio()
    request = nil
    task?.finish()
    task = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async { self.sink?(event) }
  }
}

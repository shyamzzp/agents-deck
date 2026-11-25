// Whether this device can buzz at all.
//
// The deck's haptics settings are a page of switches, and on a device with no
// Taptic Engine every one of them is a lie: an iPad has no vibration motor of
// any kind, so a tap, a hold or an agent that needs you can be felt on an
// iPhone and never on the tablet beside it. The app asks here once and leaves
// the whole section out where the answer is no.
//
// Core Haptics is the only public answer to the question. supportsHaptics is
// true for the devices with a Taptic Engine that UIKit's feedback generators
// drive (iPhone 8 and later), false on every iPad and in the simulator.

import CoreHaptics
import Flutter

enum Buzz {
  static let channel = "deck/buzz"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: Buzz.channel, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "supported":
        result(CHHapticEngine.capabilitiesForHardware().supportsHaptics)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

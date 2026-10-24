import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var audioTransitionChannel: FlutterMethodChannel?
  private var audioTransitionTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "tacto/audio_transition", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(nil)
          return
        }
        switch call.method {
        case "begin":
          self.beginAudioTransition()
          result(nil)
        case "end":
          self.endAudioTransition()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      audioTransitionChannel = channel
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func beginAudioTransition() {
    guard audioTransitionTask == .invalid else { return }
    audioTransitionTask = UIApplication.shared.beginBackgroundTask(
      withName: "Prepare next audio track"
    ) { [weak self] in
      self?.endAudioTransition()
    }
  }

  private func endAudioTransition() {
    guard audioTransitionTask != .invalid else { return }
    let task = audioTransitionTask
    audioTransitionTask = .invalid
    UIApplication.shared.endBackgroundTask(task)
  }
}

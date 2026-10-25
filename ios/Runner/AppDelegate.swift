import Flutter
import UIKit
import AVFoundation
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var audioTransitionChannel: FlutterMethodChannel?
  private var audioTransitionTask: UIBackgroundTaskIdentifier = .invalid
  private var audioCompletionObserver: NSObjectProtocol?
  private var audioTransitionOrigin: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Acquire execution time on the native end notification, before forwarding
    // completion over Flutter's event channel. Dart may already be suspended
    // when it tries to request the same protection itself.
    audioCompletionObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] _ in
      self?.beginAudioTransition(origin: "native-completion")
    }
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
          let arguments = call.arguments as? [String: String]
          self.beginAudioTransition(origin: arguments?["origin"] ?? "dart-completion")
          result(nil)
        case "end":
          self.endAudioTransition()
          result(nil)
        case "status":
          result([
            "active": self.audioTransitionTask != .invalid,
            "origin": self.audioTransitionOrigin ?? "none",
            "title": MPNowPlayingInfoCenter.default().nowPlayingInfo?[
              MPMediaItemPropertyTitle] as? String ?? "",
            "nextEnabled": MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled,
            "applicationState": UIApplication.shared.applicationState.rawValue
          ])
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      audioTransitionChannel = channel
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func beginAudioTransition(origin: String) {
    guard audioTransitionTask == .invalid else { return }
    audioTransitionOrigin = origin
    audioTransitionTask = UIApplication.shared.beginBackgroundTask(
      withName: "Prepare next audio track"
    ) { [weak self] in
      NSLog("TactoAudio background transition expired")
      self?.endAudioTransition()
    }
    NSLog("TactoAudio transition begin source=%@ active=%d", origin,
      audioTransitionTask != .invalid)
  }

  private func endAudioTransition() {
    guard audioTransitionTask != .invalid else { return }
    let task = audioTransitionTask
    audioTransitionTask = .invalid
    audioTransitionOrigin = nil
    UIApplication.shared.endBackgroundTask(task)
    NSLog("TactoAudio transition end")
  }

  deinit {
    if let observer = audioCompletionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}

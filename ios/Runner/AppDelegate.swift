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
  private var audioDiagnosticsChannel: FlutterMethodChannel?
  private var audioLifecycleObservers: [NSObjectProtocol] = []
  private let audioDiagnosticsKey = "tacto.playbackDiagnostics.v1"
  private var audioEvents: [[String: Any]] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    audioEvents = Array((UserDefaults.standard.array(forKey: audioDiagnosticsKey)
      as? [[String: Any]] ?? []).suffix(200))
    recordAudioEvent("app-start")
    for (name, stage) in [
      (UIApplication.willResignActiveNotification, "will-resign-active"),
      (UIApplication.didEnterBackgroundNotification, "did-enter-background"),
      (UIApplication.willEnterForegroundNotification, "will-enter-foreground"),
      (UIApplication.didBecomeActiveNotification, "did-become-active")
    ] {
      audioLifecycleObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        self?.recordAudioEvent(stage)
      })
    }
    // Acquire execution time on the native end notification, before forwarding
    // completion over Flutter's event channel. Dart may already be suspended
    // when it tries to request the same protection itself.
    audioCompletionObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] _ in
      self?.beginAudioTransition(origin: "native-completion")
      self?.recordAudioEvent("native-complete")
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
      let diagnostics = FlutterMethodChannel(
        name: "tacto/playback_diagnostics", binaryMessenger: controller.binaryMessenger)
      diagnostics.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(nil)
          return
        }
        switch call.method {
        case "record":
          if let arguments = call.arguments as? [String: Any],
             let stage = arguments["stage"] as? String {
            var details: [String: Any] = [:]
            if let time = arguments["timeMs"] as? NSNumber { details["timeMs"] = time }
            if let id = arguments["trackId"] as? String {
              details["trackId"] = String(id.prefix(100))
            }
            if let type = arguments["errorType"] as? String {
              details["errorType"] = String(type.prefix(100))
            }
            self.recordAudioEvent(String(stage.prefix(80)), source: "dart", details: details)
          }
          result(nil)
        case "read":
          result([
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
              as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
              as? String ?? "unknown",
            "iOSVersion": UIDevice.current.systemVersion,
            "snapshot": self.audioSnapshot(),
            "events": self.audioEvents
          ])
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      audioDiagnosticsChannel = diagnostics
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func beginAudioTransition(origin: String) {
    guard audioTransitionTask == .invalid else { return }
    audioTransitionOrigin = origin
    audioTransitionTask = UIApplication.shared.beginBackgroundTask(
      withName: "Prepare next audio track"
    ) { [weak self] in
      self?.recordAudioEvent("transition-expired")
      NSLog("TactoAudio background transition expired")
      self?.endAudioTransition()
    }
    recordAudioEvent("transition-begin", details: ["origin": origin])
    NSLog("TactoAudio transition begin source=%@ active=%d", origin,
      audioTransitionTask != .invalid)
  }

  private func endAudioTransition() {
    guard audioTransitionTask != .invalid else { return }
    let task = audioTransitionTask
    audioTransitionTask = .invalid
    audioTransitionOrigin = nil
    recordAudioEvent("transition-end")
    UIApplication.shared.endBackgroundTask(task)
    NSLog("TactoAudio transition end")
  }

  private func audioSnapshot() -> [String: Any] {
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
    return [
      "applicationState": UIApplication.shared.applicationState.rawValue,
      "transitionActive": audioTransitionTask != .invalid,
      "hasNowPlayingItem": info?.isEmpty == false,
      "playbackRate": info?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber ?? 0,
      "nextEnabled": MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled,
      "audioCategory": AVAudioSession.sharedInstance().category.rawValue
    ]
  }

  private func recordAudioEvent(
    _ stage: String, source: String = "native", details: [String: Any] = [:]
  ) {
    var event = audioSnapshot()
    let receivedAt = Int64(Date().timeIntervalSince1970 * 1000)
    event["timeMs"] = receivedAt
    event["receivedAtMs"] = receivedAt
    event["source"] = source
    event["stage"] = stage
    for (key, value) in details { event[key] = value }
    audioEvents.append(event)
    if audioEvents.count > 200 { audioEvents.removeFirst(audioEvents.count - 200) }
    UserDefaults.standard.set(audioEvents, forKey: audioDiagnosticsKey)
  }

  deinit {
    for observer in audioLifecycleObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = audioCompletionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}

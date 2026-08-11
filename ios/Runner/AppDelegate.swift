import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Talks to `RemoteCommands` on the Dart side.
  private var remote: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // better_player_plus turns the skip buttons off — `nextTrackCommand` and
    // `previousTrackCommand` are set to `isEnabled = false` in its own
    // `setupRemoteCommands`, with no target attached and no way to configure
    // it. That is why the lock screen showed them greyed out.
    //
    // The commands are a process-wide singleton, so we can claim them back
    // here. The plugin disables them again every time a data source is set
    // up, which is why Dart re-arms them after each video starts rather than
    // wiring this once at launch.
    let messenger = engineBridge.applicationBinaryMessenger
    let channel = FlutterMethodChannel(
      name: "ai.bit/remote_commands",
      binaryMessenger: messenger
    )
    remote = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "enableTrackCommands":
        self?.enableTrackCommands(hasPrevious: true, hasNext: true)
        result(nil)
      case "setTrackAvailability":
        let args = call.arguments as? [String: Any]
        self?.enableTrackCommands(
          hasPrevious: args?["hasPrevious"] as? Bool ?? false,
          hasNext: args?["hasNext"] as? Bool ?? false
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var targetsAttached = false

  private func enableTrackCommands(hasPrevious: Bool, hasNext: Bool) {
    let centre = MPRemoteCommandCenter.shared()
    centre.nextTrackCommand.isEnabled = hasNext
    centre.previousTrackCommand.isEnabled = hasPrevious

    // Targets are added once. `addTarget` appends rather than replaces, so
    // re-arming on every video would stack up handlers and fire one tap
    // several times.
    guard !targetsAttached else { return }
    targetsAttached = true

    centre.nextTrackCommand.addTarget { [weak self] _ in
      self?.remote?.invokeMethod("next", arguments: nil)
      return .success
    }
    centre.previousTrackCommand.addTarget { [weak self] _ in
      self?.remote?.invokeMethod("previous", arguments: nil)
      return .success
    }
  }
}

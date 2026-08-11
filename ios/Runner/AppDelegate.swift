import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Talks to `RemoteCommands` on the Dart side.
  private var remote: FlutterMethodChannel?
  private var targetsAttached = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let started = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // Set up after super, which is what installs the Flutter view controller
    // as the window's root and therefore the only point where its messenger
    // is available.
    if let controller = window?.rootViewController as? FlutterViewController {
      setupRemoteChannel(messenger: controller.binaryMessenger)
    }
    return started
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  /// Claims the lock-screen skip buttons back from the player plugin.
  ///
  /// better_player_plus turns them off — `nextTrackCommand` and
  /// `previousTrackCommand` are set to `isEnabled = false` in its own
  /// `setupRemoteCommands`, with no target attached and no way to configure
  /// it. That is why the buttons showed greyed out on the lock screen.
  ///
  /// The command centre is a process-wide singleton, so we can take them back
  /// here. The plugin disables them again every time a data source is set up,
  /// which is why Dart re-arms them after each video rather than relying on
  /// this running once at launch.
  private func setupRemoteChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "ai.bit/remote_commands",
      binaryMessenger: messenger
    )
    remote = channel
    channel.setMethodCallHandler {
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
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

  private func enableTrackCommands(hasPrevious: Bool, hasNext: Bool) {
    let centre = MPRemoteCommandCenter.shared()
    centre.nextTrackCommand.isEnabled = hasNext
    centre.previousTrackCommand.isEnabled = hasPrevious

    // Targets are attached once. `addTarget` appends rather than replaces, so
    // re-arming on every video would stack handlers up and turn one tap into
    // several skips.
    guard !targetsAttached else { return }
    targetsAttached = true

    _ = centre.nextTrackCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.remote?.invokeMethod("next", arguments: nil)
      return .success
    }
    _ = centre.previousTrackCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.remote?.invokeMethod("previous", arguments: nil)
      return .success
    }
  }
}

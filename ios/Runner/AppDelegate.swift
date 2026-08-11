import AVKit
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // The Cast button is the system output-route picker, which only Apple's
    // own view can present.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RoutePicker") {
      registrar.register(
        RoutePickerViewFactory(),
        withId: "ai.bit/route_picker"
      )
    }

    // Registered here, off a plugin registrar, rather than from the window's
    // root view controller.
    //
    // This app has a SceneDelegate, so the scene owns the window and creates
    // it after `didFinishLaunchingWithOptions` has already returned. Reading
    // `window?.rootViewController` there found nil, the channel was never
    // registered, and every call from Dart hit a missing plugin — which is why
    // the lock screen still showed seek arrows instead of the skip buttons.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AIBitRemoteCommands") {
      setupRemoteChannel(messenger: registrar.messenger())
    }
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

/// Hosts the system output-route picker so Flutter can show a real Cast button.
///
/// This is `AVRoutePickerView`, the control the stock apps use: it lists Apple
/// TVs, AirPlay speakers and anything else the device can reach, and lights up
/// on its own while a route is active. Drawing our own button would not work —
/// only Apple's view may present the picker, and only it knows the current
/// route.
///
/// It lives in this file rather than its own because the Xcode project lists
/// its sources explicitly, and a new file would have to be registered in four
/// places in the pbxproj to be compiled at all.
///
/// Chromecast is deliberately absent: it needs the Google Cast SDK as a pod
/// and a receiver app id, which is a decision to take rather than a dependency
/// to add quietly.
class RoutePickerViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return RoutePickerPlatformView(frame: frame)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class RoutePickerPlatformView: NSObject, FlutterPlatformView {
  private let picker: AVRoutePickerView

  init(frame: CGRect) {
    picker = AVRoutePickerView(frame: frame)
    picker.backgroundColor = .clear
    picker.tintColor = .white
    picker.activeTintColor = .systemRed
    super.init()
  }

  func view() -> UIView {
    return picker
  }
}

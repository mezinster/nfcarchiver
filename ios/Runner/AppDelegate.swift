import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let photoEncoder = PhotoEncoder()
  private let shareInbox = ShareInbox()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhotoEncoder") {
      photoEncoder.register(with: registrar.messenger())
    }
    // No onShareAvailable push on iOS: the share extension's URL open lands
    // in FlutterSceneDelegate, and Dart already checks the inbox on launch
    // and on every resume, which that open triggers.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShareInbox") {
      shareInbox.register(with: registrar.messenger())
    }
  }
}

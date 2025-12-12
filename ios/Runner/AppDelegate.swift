import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  static func registerPlugins(with registry: FlutterPluginRegistry) {
    GeneratedPluginRegistrant.register(with: registry)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    AppDelegate.registerPlugins(with: self)

    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      AppDelegate.registerPlugins(with: registry)
    }

    // Periodic background refresh (frequency in seconds; scheduling is best-effort).
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.openai.codexremote.iOSBackgroundAppRefresh",
      frequency: NSNumber(value: 20 * 60)
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Windowing-API mode only (`--windowing`, see WindowingBootstrap.swift).
  private var windowing: WindowingBootstrap?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard WindowingMode.isEnabled else { return }
    // The nib loaded its window (kept invisible) before this delegate could
    // object; Dart creates every window in this mode.
    mainFlutterWindow?.close()
    windowing = WindowingBootstrap()
    windowing?.start()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Windowing mode: closing the nib window above happens before any Dart
    // window exists and must not quit the app. Once Dart has shown a window,
    // the usual rule applies again (Dart exits with its last window as well).
    return !WindowingMode.isEnabled || WindowingBootstrap.hasShownWindow
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

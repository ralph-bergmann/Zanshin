import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// The view-less engine; Dart creates every window (WindowingBootstrap.swift).
  private var windowing: WindowingBootstrap?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    windowing = WindowingBootstrap()
    windowing?.start()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // AppKit runs this check deferred, so a transient gap between two Dart
    // windows - the splash going away after the main window opened - would
    // quit the app. Dart's window registry owns the rule instead: it exits the
    // process when it unregisters its last window.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

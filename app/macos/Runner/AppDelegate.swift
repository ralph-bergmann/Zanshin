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
    // process when a window unregisters and none that keeps the app alive is
    // left (Story 11.12).
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // A Dock click with no visible window: Dart brings back the minimised
    // project window or shows Projects (Story 11.12 item 7). AppKit itself has
    // nothing to reopen - every window is Dart's.
    if !flag {
      windowing?.reopen()
    }
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

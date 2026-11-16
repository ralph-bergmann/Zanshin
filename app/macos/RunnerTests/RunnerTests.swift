import Cocoa
import FlutterMacOS
import XCTest

@testable import zanshin

class RunnerTests: XCTestCase {

  /// A menu bar shaped like the engine's: View with the toggles and Enter Full Screen, Window with the system items.
  private func menuBar() -> NSMenu {
    let bar = NSMenu()
    let view = NSMenu(title: "View")
    view.autoenablesItems = false
    view.addItem(withTitle: "Detailed Cards", action: nil, keyEquivalent: "")
    view.addItem(withTitle: "Group Stacks", action: nil, keyEquivalent: "")
    view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
    let window = NSMenu(title: "Window")
    window.autoenablesItems = false
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    for menu in [view, window] {
      bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
    }
    return bar
  }

  func testApplySetsCheckmarksEnabledStateAndFindsTheWindowMenu() throws {
    let bar = menuBar()
    let payload = try XCTUnwrap(
      MenuStateChannel.Payload([
        "checked": [
          ["menu": "View", "item": "Detailed Cards", "checked": true],
          ["menu": "View", "item": "Group Stacks", "checked": false],
          ["menu": "View", "item": "Missing", "checked": true],
        ],
        "enabled": ["performMiniaturize:": false, "performZoom:": false, "toggleFullScreen:": true],
        "titles": ["toggleFullScreen:": "Exit Full Screen", "missingSelector:": "Missing"],
      ]))
    let view = try XCTUnwrap(bar.item(withTitle: "View")?.submenu)
    let window = try XCTUnwrap(bar.item(withTitle: "Window")?.submenu)
    let fullScreen = try XCTUnwrap(view.items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
    // NSMenuItem starts enabled: disabled first, so `true` below proves the write.
    fullScreen.isEnabled = false

    let windows = MenuStateChannel.apply(payload, to: bar)

    XCTAssertEqual(view.item(withTitle: "Detailed Cards")?.state, .on)
    XCTAssertEqual(view.item(withTitle: "Group Stacks")?.state, .off)
    XCTAssertEqual(fullScreen.title, "Exit Full Screen")
    XCTAssertEqual(fullScreen.isEnabled, true)
    XCTAssertEqual(window.item(withTitle: "Minimize")?.isEnabled, false)
    XCTAssertEqual(window.item(withTitle: "Zoom")?.isEnabled, false)
    XCTAssertFalse(
      bar.items.compactMap(\.submenu).flatMap(\.items).contains { $0.title == "Missing" },
      "a title for a selector no item has is skipped")
    XCTAssertTrue(windows === window)
  }

  func testAMalformedPayloadIsRejected() {
    XCTAssertNil(MenuStateChannel.Payload(nil))
    XCTAssertNil(MenuStateChannel.Payload(["checked": [], "enabled": ["performZoom:": "yes"], "titles": [:]]))
    XCTAssertNil(
      MenuStateChannel.Payload([
        "checked": [["menu": "View", "item": "Group Stacks"]], "enabled": [:], "titles": [:],
      ]))
    XCTAssertNil(MenuStateChannel.Payload(["checked": [], "enabled": [:]]), "titles is required")
    XCTAssertNil(
      MenuStateChannel.Payload(["checked": [], "enabled": [:], "titles": ["toggleFullScreen:": true]]),
      "a title must be a string")
    XCTAssertNotNil(MenuStateChannel.Payload(["checked": [], "enabled": [:], "titles": [:]]))
  }

  // MARK: - Traffic-light position (Story 11.26)

  /// A titled, resizable, full-size-content window, like the engine's.
  private func plainWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  /// Lays the titlebar out and lets the chrome's next-turn pass run.
  private func settle(_ window: NSWindow) {
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    window.contentView?.superview?.layoutSubtreeIfNeeded()
  }

  private func buttons(_ window: NSWindow) -> [NSButton] {
    [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
  }

  /// Each button's centre y, measured from the window's top edge.
  private func midsFromTop(_ window: NSWindow) -> [CGFloat] {
    buttons(window).map { window.frame.height - $0.convert($0.bounds, to: nil).midY }
  }

  private func assertCentred(_ window: NSWindow, at midY: CGFloat, _ message: String, line: UInt = #line) {
    let mids = midsFromTop(window)
    XCTAssertEqual(mids.count, 3, message, line: line)
    for mid in mids {
      XCTAssertEqual(mid, midY, accuracy: 0.5, message, line: line)
    }
  }

  /// The titlebar container is twice the line high and pinned to the top edge, which keeps AppKit's hover area for
  /// the × − + symbols on the moved buttons.
  private func assertContainerFollows(_ window: NSWindow, line midY: CGFloat, _ message: String, line: UInt = #line) {
    guard let container = buttons(window).first?.superview?.superview else {
      return XCTFail("no titlebar container: \(message)", line: line)
    }
    XCTAssertEqual(container.frame.height, midY * 2, accuracy: 0.5, message, line: line)
    XCTAssertEqual(container.frame.maxY, window.frame.height, accuracy: 0.5, message, line: line)
  }

  func testTheProjectWindowCentresItsButtonsOnTheTopBar() {
    let window = plainWindow()
    let chrome = MainWindowChrome(window: window, kind: .main, buttonMidY: 34)
    settle(window)
    assertCentred(window, at: 34, "on open")

    window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 760), display: false)
    settle(window)
    assertCentred(window, at: 34, "after a resize")
    assertContainerFollows(window, line: 34, "after a resize")

    window.appearance = NSAppearance(named: .darkAqua)
    settle(window)
    assertCentred(window, at: 34, "after switching to darkAqua")
    window.appearance = NSAppearance(named: .aqua)
    settle(window)
    assertCentred(window, at: 34, "after switching to aqua")

    // AppKit puts a button back where it lays it out: 8 pt higher, as the system position (centre 26) would be.
    guard let close = buttons(window).first else { return XCTFail("no close button") }
    let up: CGFloat = (close.superview?.isFlipped ?? false) ? -8 : 8
    close.setFrameOrigin(NSPoint(x: close.frame.minX, y: close.frame.minY + up))
    // AppKit drops a move made inside the button's own frame notification, so the chrome must not make one there.
    XCTAssertEqual(midsFromTop(window).first ?? 0, 26, accuracy: 0.5, "no move inside the frame notification")
    settle(window)
    assertCentred(window, at: 34, "after a button was set back")

    // The overlay's layout pass alone puts it back, without a run-loop turn.
    close.setFrameOrigin(NSPoint(x: close.frame.minX, y: close.frame.minY + up))
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    assertCentred(window, at: 34, "after a layout pass")

    // The run-loop observer alone puts it back, with the overlay's layout path switched off.
    guard let overlay = close.superview?.subviews.compactMap({ $0 as? TrafficLightOverlayView }).first else {
      return XCTFail("no traffic-light overlay")
    }
    overlay.onLayout = nil
    close.setFrameOrigin(NSPoint(x: close.frame.minX, y: close.frame.minY + up))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assertCentred(window, at: 34, "after a run-loop turn")

    // On hover AppKit resets the container to its own height together with the buttons; one placement restores both.
    guard let container = close.superview?.superview else { return XCTFail("no titlebar container") }
    container.frame = NSRect(
      x: container.frame.minX, y: window.frame.height - 66, width: container.frame.width, height: 66)
    close.setFrameOrigin(NSPoint(x: close.frame.minX, y: close.frame.minY + up))
    settle(window)
    assertCentred(window, at: 34, "after the container was reset")
    assertContainerFollows(window, line: 34, "after the container was reset")

    withExtendedLifetime(chrome) { window.close() }
  }

  func testTheButtonsFollowTheLineDartSends() {
    let window = plainWindow()
    let chrome = MainWindowChrome(window: window, kind: .main, buttonMidY: 34)
    settle(window)
    assertCentred(window, at: 34, "at 100 %")
    assertContainerFollows(window, line: 34, "at 100 %")

    // 150 %: the highest line the titlebar holds.
    chrome.buttonMidY = 51
    settle(window)
    assertCentred(window, at: 51, "at 150 %")
    assertContainerFollows(window, line: 51, "at 150 %")
    for button in buttons(window) {
      guard let host = button.superview else { return XCTFail("a button without a superview") }
      XCTAssertTrue(host.bounds.contains(button.frame), "inside the titlebar at 150 %: \(button.frame) in \(host.bounds)")
    }

    chrome.buttonMidY = 30.6
    settle(window)
    assertCentred(window, at: 30.6, "at 90 %")
    assertContainerFollows(window, line: 30.6, "at 90 %")

    withExtendedLifetime(chrome) { window.close() }
  }

  /// macOS keeps a visible toolbar on screen in full screen, a bar over the content; the chrome hides the empty
  /// toolbar while the window is in full screen and shows it again after.
  func testFullScreenHidesTheToolbar() throws {
    let window = plainWindow()
    let chrome = MainWindowChrome(window: window, kind: .main, buttonMidY: 34)
    settle(window)
    let toolbar = try XCTUnwrap(window.toolbar, "the chrome attaches a toolbar")
    XCTAssertTrue(toolbar.isVisible, "visible in a window")

    NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
    XCTAssertFalse(toolbar.isVisible, "hidden from the start of the full-screen transition")

    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    settle(window)
    XCTAssertTrue(toolbar.isVisible, "visible again after leaving full screen")
    assertCentred(window, at: 34, "the buttons back on the line after leaving full screen")

    withExtendedLifetime(chrome) { window.close() }
  }

  func testADialogWindowKeepsTheSystemPosition() {
    let reference = plainWindow()
    reference.titlebarAppearsTransparent = true
    reference.titleVisibility = .hidden
    reference.toolbar = NSToolbar(identifier: "Reference")
    settle(reference)

    let window = plainWindow()
    let chrome = MainWindowChrome(window: window, kind: .secondary, buttonMidY: nil)
    settle(window)

    let expected = midsFromTop(reference)
    let actual = midsFromTop(window)
    XCTAssertEqual(actual.count, 3)
    for (mid, native) in zip(actual, expected) {
      XCTAssertEqual(mid, native, accuracy: 0.5)
    }
    XCTAssertNotEqual(actual.first ?? 0, 34, accuracy: 0.5)

    withExtendedLifetime(chrome) { window.close() }
    reference.close()
  }

  // MARK: - The line over `zanshin/window_frames` (Story 11.27)

  /// Calls `method` on `zanshin/window_frames` through `messenger`; the decoded reply: nil, or the `FlutterError`.
  private func call(_ messenger: FakeMessenger, _ method: String, _ arguments: [String: Any]) -> Any? {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    var reply: Any?
    var replied = false
    messenger.handlers["zanshin/window_frames"]?(
      codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))
    ) { data in
      replied = true
      reply = data.flatMap { codec.decodeEnvelope($0) }
    }
    XCTAssertTrue(replied, "\(method) answered")
    return reply
  }

  private func handle(of window: NSWindow) -> Int {
    Int(bitPattern: Unmanaged.passUnretained(window).toOpaque())
  }

  func testTheStoreTakesTheLineWithRestoreAndPlaceButtons() {
    let key = "xctest-story-11-27"
    defer { UserDefaults(suiteName: "\(Bundle.main.bundleIdentifier!).window_frames")?.removeObject(forKey: key) }
    let messenger = FakeMessenger()
    let store = WindowFrameStore(messenger: messenger)
    let window = plainWindow()
    let restore: [String: Any] = [
      "window": handle(of: window), "key": key, "chrome": "main", "frame": "full", "level": "normal",
    ]

    // The main chrome needs a numeric line.
    XCTAssertEqual((call(messenger, "restore", restore) as? FlutterError)?.code, "bad-args")
    let mistyped = restore.merging(["buttonMidY": "34"]) { $1 }
    XCTAssertEqual((call(messenger, "restore", mistyped) as? FlutterError)?.code, "bad-args")

    XCTAssertNil(call(messenger, "restore", restore.merging(["buttonMidY": 34.0]) { $1 }))
    settle(window)
    assertCentred(window, at: 34, "restored on the line Dart sent")

    XCTAssertNil(call(messenger, "placeButtons", ["window": handle(of: window), "buttonMidY": 51.0]))
    settle(window)
    assertCentred(window, at: 51, "moved by placeButtons")

    XCTAssertEqual(
      (call(messenger, "placeButtons", ["window": handle(of: window)]) as? FlutterError)?.code, "bad-args")
    // A window the store does not hold (one closed meanwhile) is skipped, never dereferenced.
    let other = plainWindow()
    XCTAssertNil(call(messenger, "placeButtons", ["window": handle(of: other), "buttonMidY": 30.6]))
    settle(window)
    assertCentred(window, at: 51, "an unknown handle moves nothing")

    withExtendedLifetime(store) { window.close() }
    other.close()
  }
}

/// Stands in for the engine's messenger: keeps each channel's handler so a test can call it.
private final class FakeMessenger: NSObject, FlutterBinaryMessenger {
  var handlers: [String: FlutterBinaryMessageHandler] = [:]

  func send(onChannel channel: String, message: Data?) {}

  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {}

  func setMessageHandlerOnChannel(
    _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?
  ) -> FlutterBinaryMessengerConnection {
    handlers[channel] = handler
    return 1
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

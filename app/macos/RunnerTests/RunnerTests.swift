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
        "enabled": ["performMiniaturize:": false, "performZoom:": true, "toggleFullScreen:": false],
      ]))
    let windows = MenuStateChannel.apply(payload, to: bar)

    let view = try XCTUnwrap(bar.item(withTitle: "View")?.submenu)
    let window = try XCTUnwrap(bar.item(withTitle: "Window")?.submenu)
    XCTAssertEqual(view.item(withTitle: "Detailed Cards")?.state, .on)
    XCTAssertEqual(view.item(withTitle: "Group Stacks")?.state, .off)
    XCTAssertEqual(view.item(withTitle: "Enter Full Screen")?.isEnabled, false)
    XCTAssertEqual(window.item(withTitle: "Minimize")?.isEnabled, false)
    XCTAssertEqual(window.item(withTitle: "Zoom")?.isEnabled, true)
    XCTAssertTrue(windows === window)
  }

  func testAMalformedPayloadIsRejected() {
    XCTAssertNil(MenuStateChannel.Payload(nil))
    XCTAssertNil(MenuStateChannel.Payload(["checked": [], "enabled": ["performZoom:": "yes"]]))
    XCTAssertNil(MenuStateChannel.Payload(["checked": [["menu": "View", "item": "Group Stacks"]], "enabled": [:]]))
    XCTAssertNotNil(MenuStateChannel.Payload(["checked": [], "enabled": [:]]))
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

  func testTheProjectWindowCentresItsButtonsOnTheTopBar() {
    let window = plainWindow()
    let chrome = MainWindowChrome(window: window, kind: .main)
    settle(window)
    assertCentred(window, at: MainWindowChrome.buttonMidY, "on open")
    XCTAssertEqual(MainWindowChrome.buttonMidY, 34)

    window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 760), display: false)
    settle(window)
    assertCentred(window, at: 34, "after a resize")

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
    settle(window)
    assertCentred(window, at: 34, "after a button was set back")

    withExtendedLifetime(chrome) { window.close() }
  }

  func testADialogWindowKeepsTheSystemPosition() {
    let reference = plainWindow()
    reference.titlebarAppearsTransparent = true
    reference.titleVisibility = .hidden
    reference.toolbar = NSToolbar(identifier: "Reference")
    settle(reference)

    let window = plainWindow()
    let chrome = MainWindowChrome(window: window, kind: .secondary)
    settle(window)

    let expected = midsFromTop(reference)
    let actual = midsFromTop(window)
    XCTAssertEqual(actual.count, 3)
    for (mid, native) in zip(actual, expected) {
      XCTAssertEqual(mid, native, accuracy: 0.5)
    }
    XCTAssertNotEqual(actual.first ?? 0, MainWindowChrome.buttonMidY, accuracy: 0.5)

    withExtendedLifetime(chrome) { window.close() }
    reference.close()
  }
}

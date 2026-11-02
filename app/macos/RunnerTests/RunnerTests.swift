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
}

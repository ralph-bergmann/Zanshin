// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Remembers the frame of every Dart-created window that asks for it, keyed by
/// a stable name (`main` for the one project window, whichever project it
/// shows — decision 16.42 j), and puts a window back where it was when the
/// same key comes around again. It is also where a window asks
/// for the app's custom chrome, because that has to be in place before the
/// frame is applied.
///
/// Native half of the `zanshin/window_frames` channel. Persists the way the
/// pre-windowing runner did: in UserDefaults, with the display the window was
/// on, so a frame saved on a display that is no longer connected is ignored
/// instead of restored off screen.
final class WindowFrameStore {
    /// One window's frame on disk; the pre-windowing `WindowState`, per key.
    private struct Frame: Codable {
        let position: CGPoint
        let size: CGSize
        let displayId: CGDirectDisplayID
        let displayOffset: CGPoint
        let displaySize: CGSize
    }

    private let channel: FlutterMethodChannel
    private let defaults = UserDefaults(suiteName: "\(Bundle.main.bundleIdentifier!).window_frames")!
    /// Notification observers per window, removed when the window closes.
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    /// The custom chrome per window, kept alive for as long as the window is.
    private var chrome: [ObjectIdentifier: MainWindowChrome] = [:]

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "zanshin/window_frames", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "restore" else {
            result(FlutterMethodNotImplemented)
            return
        }
        // `chrome` is parsed as strictly as the rest: defaulting a missing or
        // mistyped flag to `false` would silently hand back a stock titled
        // window - no custom chrome, and `isRestorable` left on, which lets
        // AppKit's state restoration override the frame restored just below.
        guard let args = call.arguments as? [String: Any],
            let handle = args["window"] as? Int,
            let key = args["key"] as? String,
            let wantsChrome = args["chrome"] as? Bool,
            let pointer = UnsafeRawPointer(bitPattern: handle)
        else {
            result(
                FlutterError(
                    code: "bad-args", message: "expected a window handle, a key and a chrome flag", details: nil))
            return
        }
        let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
        restore(window, key: key, chrome: wantsChrome)
        result(nil)
    }

    /// Applies the app's window chrome if `chrome` is set, then the frame saved
    /// under `key` if its display is still there — otherwise places the window
    /// for a first launch (see `placeForFirstLaunch`) — and keeps saving this
    /// window's frame under that key from now on.
    ///
    /// Chrome first, always: `.fullSizeContentView` redefines what a frame
    /// means, so a saved frame applied under the old style mask would lose the
    /// titlebar height on every launch.
    private func restore(_ window: NSWindow, key: String, chrome wantsChrome: Bool) {
        if wantsChrome {
            chrome[ObjectIdentifier(window)] = MainWindowChrome(window: window)
        }

        if let frame = load(key) {
            window.setFrame(NSRect(origin: frame.position, size: frame.size), display: true)
        } else {
            placeForFirstLaunch(window)
        }

        let center = NotificationCenter.default
        let id = ObjectIdentifier(window)
        var tokens: [NSObjectProtocol] = []
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            tokens.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    guard let window = window else { return }
                    self?.save(window, key: key)
                })
        }
        tokens.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                self?.forget(id)
            })
        observers[id] = tokens
    }

    /// Places a window that has no remembered frame: its requested size,
    /// clamped to the screen's usable area, centred in that area.
    ///
    /// Not `window.center()` - that neither clamps the size nor keeps the
    /// window clear of the menu bar, so on a display smaller than the
    /// requested size it lands partly off screen. The pre-windowing runner's
    /// `defaultFrame()` clamped and centred, and the frame saved on the first
    /// move would otherwise persist the off-screen placement.
    private func placeForFirstLaunch(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }

        // `visibleFrame` excludes the menu bar and the Dock, so the window is
        // centered in - and fits inside - the actually usable area.
        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(window.frame.width, visible.width),
            height: min(window.frame.height, visible.height)
        )
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func forget(_ id: ObjectIdentifier) {
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        chrome.removeValue(forKey: id)
    }

    private func save(_ window: NSWindow, key: String) {
        // Not on any screen yet (hidden until the first frame), or in full
        // screen (the last normal frame is the one to come back to).
        guard let screen = window.screen, !window.styleMask.contains(.fullScreen) else { return }
        let frame = Frame(
            position: window.frame.origin,
            size: window.frame.size,
            displayId: Self.displayId(of: screen),
            displayOffset: screen.frame.origin,
            displaySize: screen.frame.size
        )
        if let data = try? JSONEncoder().encode(frame) {
            defaults.set(data, forKey: key)
        }
    }

    /// The saved frame, if its display is still connected: an exact display
    /// match first, then the same display id at the same x offset (display
    /// moved up or down). The pre-windowing runner's two strategies.
    private func load(_ key: String) -> Frame? {
        guard let data = defaults.data(forKey: key),
            let frame = try? JSONDecoder().decode(Frame.self, from: data)
        else {
            return nil
        }
        let screens = NSScreen.screens
        if screens.contains(where: { $0.frame.origin == frame.displayOffset && $0.frame.size == frame.displaySize }) {
            return frame
        }
        if screens.contains(where: {
            Self.displayId(of: $0) == frame.displayId && $0.frame.origin.x == frame.displayOffset.x
        }) {
            return frame
        }
        return nil
    }

    private static func displayId(of screen: NSScreen) -> CGDirectDisplayID {
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }
}

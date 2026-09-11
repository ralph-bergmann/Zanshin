// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Remembers the frame of every Dart-created window that asks for it, keyed by
/// a stable name (`start`, `project:<path>`, ...), and puts a window back where
/// it was when the same key comes around again.
///
/// Native half of the `zanshin/window_frames` channel. Persists the way the
/// pre-windowing runner did (`MainFlutterWindow.swift`): in UserDefaults, with
/// the display the window was on, so a frame saved on a display that is no
/// longer connected is ignored instead of restored off screen.
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
        guard let args = call.arguments as? [String: Any],
            let handle = args["window"] as? Int,
            let key = args["key"] as? String,
            let pointer = UnsafeRawPointer(bitPattern: handle)
        else {
            result(FlutterError(code: "bad-args", message: "expected a window handle and a key", details: nil))
            return
        }
        let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
        restore(window, key: key)
        result(nil)
    }

    /// Applies the frame saved under `key` if its display is still there —
    /// otherwise centres the window, as the pre-windowing runner did on a
    /// first launch — and keeps saving this window's frame under that key
    /// from now on.
    private func restore(_ window: NSWindow, key: String) {
        if let frame = load(key) {
            window.setFrame(NSRect(origin: frame.position, size: frame.size), display: true)
        } else {
            window.center()
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

    private func forget(_ id: ObjectIdentifier) {
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
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

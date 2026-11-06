// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// The chrome a window asks for in `restore` (Story 11.12 item 2): the project
/// window's, or a dialog window's.
enum WindowChromeKind: String {
    case main
    case secondary
}

/// What the store remembers of a window's frame (Story 11.12 item 3): size and
/// position, or only the position of a window sized to its content.
enum WindowFrameMode: String {
    case full
    case position
}

/// The level a window takes (Story 11.12 item 6): normal, or floating while
/// Zanshin is active (jj log Configurations).
enum WindowLevelMode: String {
    case normal
    case floating
}

/// Remembers the frame of every Dart-created window that asks for it, keyed by
/// a stable name (`main` for the one project window, whichever project it
/// shows — decision 16.42 j; `projects`, `settings`, `revset-configs` for the
/// dialog windows), and puts a window back where it was when the same key comes
/// around again. It is also where a window asks for its chrome and its level,
/// because the chrome has to be in place before the frame is applied.
///
/// Native half of the `zanshin/window_frames` channel. Persists the way the
/// pre-windowing runner did: in UserDefaults, with the display the window was
/// on, so a frame saved on a display that is no longer connected is ignored
/// instead of restored off screen. It also forwards the Dock's reopen to Dart
/// (`reopen`).
///
/// `restore {window, key, chrome: main|secondary, frame: full|position,
/// level: normal|floating}` runs, in this order: the chrome (`MainWindowChrome`
/// of that kind) → `isRestorable = false` → the frame → the observers.
/// - **Frame `full`** restores the saved size and origin.
/// - **Frame `position`** saves the frame the same way but restores only the
///   origin, by the saved top edge (`origin.y + height`), and keeps that top
///   edge on every later resize (re-anchored on `didResize`, the top updated on
///   `didMove`): `setContentSize`, which the engine calls for a window sized to
///   its content, keeps the bottom-left origin instead (Claude's proposal; I1).
///   Once the user resized (a live resize) or zoomed the window, it keeps the
///   frame they gave it (Story 11.19, the resizable Settings window).
/// - **First placement** without a saved frame: the project window as for a
///   first launch (`placeForFirstLaunch`); a dialog centred over the visible
///   project window, else the screen's visible frame, clamped into it — a sized
///   dialog at once, a content-sized one again on each resize before it shows
///   (its frame means nothing before its first frame), and once more when it
///   first becomes key as the fallback (Claude's proposal).
/// - **Level `floating`**: `.floating` while `NSApp.isActive`, `.normal` once it
///   resigns, as the splash does (decisions 16.19, 16.42 b).
/// In debug builds each restore and each level change logs
/// `zanshin.window <key>: styleMask … collection … restorable … level …`, the
/// readout of what CGWindowList cannot see.
final class WindowFrameStore {
    /// One window's frame on disk; the pre-windowing `WindowState`, per key.
    private struct Frame: Codable {
        let position: CGPoint
        let size: CGSize
        let displayId: CGDirectDisplayID
        let displayOffset: CGPoint
        let displaySize: CGSize
    }

    /// One open window's placement state.
    private final class Placement {
        let key: String
        let mode: WindowFrameMode

        /// The top edge a position-only window keeps, once known.
        var top: CGFloat?

        /// A dialog without a saved frame is centred until it first becomes key.
        var centring = false

        /// The user resized or zoomed the window (Story 11.19): a position-only
        /// window then keeps the frame they gave it instead of its top edge.
        var userSized = false

        init(key: String, mode: WindowFrameMode) {
            self.key = key
            self.mode = mode
        }
    }

    private let channel: FlutterMethodChannel
    private let defaults = UserDefaults(suiteName: "\(Bundle.main.bundleIdentifier!).window_frames")!
    /// Notification observers per window, removed when the window closes.
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    /// The chrome per window, kept alive for as long as the window is.
    private var chrome: [ObjectIdentifier: MainWindowChrome] = [:]
    private var placements: [ObjectIdentifier: Placement] = [:]
    /// The project window a dialog is first centred over, while it is open.
    private weak var projectWindow: NSWindow?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "zanshin/window_frames", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    /// The Dock was clicked while no window is visible: Dart brings the
    /// project window back, or shows Projects.
    func reopen() {
        channel.invokeMethod("reopen", arguments: nil)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "restore" else {
            result(FlutterMethodNotImplemented)
            return
        }
        // Every argument is parsed strictly: defaulting a missing or mistyped
        // one would silently hand back a stock titled window - no custom chrome,
        // and `isRestorable` left on, which lets AppKit's state restoration
        // override the frame restored just below.
        guard let args = call.arguments as? [String: Any],
            let handle = args["window"] as? Int,
            let key = args["key"] as? String,
            let kind = (args["chrome"] as? String).flatMap(WindowChromeKind.init(rawValue:)),
            let mode = (args["frame"] as? String).flatMap(WindowFrameMode.init(rawValue:)),
            let level = (args["level"] as? String).flatMap(WindowLevelMode.init(rawValue:)),
            let pointer = UnsafeRawPointer(bitPattern: handle)
        else {
            result(
                FlutterError(
                    code: "bad-args",
                    message: "expected a window handle, a key, a chrome (main|secondary), a frame (full|position) "
                        + "and a level (normal|floating)",
                    details: nil))
            return
        }
        let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
        restore(window, key: key, kind: kind, mode: mode, level: level)
        result(nil)
    }

    /// Applies the chrome of `kind`, takes the geometry away from AppKit's state
    /// restoration, applies the frame saved under `key` in `mode` (or the first
    /// placement), sets the `level`, and keeps saving this window's frame under
    /// that key from now on.
    ///
    /// Chrome first, always: `.fullSizeContentView` redefines what a frame
    /// means, so a saved frame applied under the old style mask would lose the
    /// titlebar height on every launch.
    private func restore(
        _ window: NSWindow, key: String, kind: WindowChromeKind, mode: WindowFrameMode, level: WindowLevelMode
    ) {
        let id = ObjectIdentifier(window)
        chrome[id] = MainWindowChrome(window: window, kind: kind)

        // The store is the single owner of every window's geometry. AppKit's
        // own state restoration would restore its stale frame asynchronously
        // ~300ms after launch, silently overriding both the saved frame and the
        // first placement.
        window.isRestorable = false

        let placement = Placement(key: key, mode: mode)
        placements[id] = placement
        if let saved = load(key) {
            switch mode {
            case .full:
                // At least the window's content minimum, which Dart scales with the zoom (Story 11.20): a frame saved
                // at a smaller zoom grows, its top edge kept.
                let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
                let size = NSSize(
                    width: max(saved.size.width, minimum.width), height: max(saved.size.height, minimum.height))
                let top = saved.position.y + saved.size.height
                window.setFrame(NSRect(origin: NSPoint(x: saved.position.x, y: top - size.height), size: size), display: true)
            case .position:
                // The content decides the height; the saved top edge stays.
                let top = saved.position.y + saved.size.height
                placement.top = top
                window.setFrameOrigin(NSPoint(x: saved.position.x, y: top - window.frame.height))
            }
        } else if kind == .main {
            placeForFirstLaunch(window)
        } else {
            placement.centring = true
            centre(window, placement)
        }
        if kind == .main {
            projectWindow = window
        }

        var tokens = observe(window, placement)
        if level == .floating {
            tokens += floatWhileActive(window, key: key)
        }
        observers[id] = tokens
        #if DEBUG
            Self.log(window, key: key)
        #endif
    }

    /// Saves the frame on every move and resize, keeps a position-only
    /// window's top edge, finishes a dialog's first placement and forgets the
    /// window when it closes.
    private func observe(_ window: NSWindow, _ placement: Placement) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let id = ObjectIdentifier(window)
        return [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                guard let self = self, let window = window else { return }
                if placement.mode == .position {
                    placement.top = window.frame.maxY
                }
                // A shown window that moved (the user dragged it before it ever became key) stays where it is.
                if window.isVisible {
                    placement.centring = false
                }
                self.save(window, key: placement.key)
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                guard let self = self, let window = window else { return }
                // A live resize starts with willStartLiveResize; a zoom ends zoomed.
                if window.inLiveResize || window.isZoomed {
                    placement.userSized = true
                }
                if placement.centring && !window.isVisible {
                    self.centre(window, placement)
                } else if !placement.userSized, let top = placement.top, abs(window.frame.maxY - top) > 0.5 {
                    window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
                }
                self.save(window, key: placement.key)
            },
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) {
                _ in
                placement.userSized = true
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                guard let self = self, let window = window, placement.centring else { return }
                placement.centring = false
                self.centre(window, placement)
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                self?.forget(id)
            },
        ]
    }

    /// Floats `window` above other windows while Zanshin is active and drops
    /// it to the normal level otherwise: the floating level is global, so it
    /// must never hover over other apps' windows.
    private func floatWhileActive(_ window: NSWindow, key: String) -> [NSObjectProtocol] {
        let update = { [weak window] in
            guard let window = window else { return }
            let wanted: NSWindow.Level = NSApp.isActive ? .floating : .normal
            guard window.level != wanted else { return }
            window.level = wanted
            #if DEBUG
                Self.log(window, key: key)
            #endif
        }
        update()
        let center = NotificationCenter.default
        return [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in update() },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { _ in update() },
        ]
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

    /// Centres a dialog over the visible project window, else in its screen's
    /// visible frame, and keeps it inside that visible frame — its title bar
    /// first when it is taller (Claude's proposal). The size stays the
    /// dialog's own.
    private func centre(_ window: NSWindow, _ placement: Placement) {
        let over = projectWindow.flatMap { $0.isVisible ? $0 : nil }
        guard let screen = over?.screen ?? window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let anchor = over?.frame ?? visible
        let size = window.frame.size
        let x = max(visible.minX, min(anchor.midX - size.width / 2, visible.maxX - size.width))
        let y = min(visible.maxY - size.height, max(anchor.midY - size.height / 2, visible.minY))
        window.setFrameOrigin(NSPoint(x: x, y: y))
        if placement.mode == .position {
            placement.top = window.frame.maxY
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        chrome.removeValue(forKey: id)
        placements.removeValue(forKey: id)
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

    #if DEBUG
        /// The window properties the CGWindowList probe cannot read.
        private static func log(_ window: NSWindow, key: String) {
            let masks: [(NSWindow.StyleMask, String)] = [
                (.titled, "titled"), (.closable, "closable"), (.miniaturizable, "miniaturizable"),
                (.resizable, "resizable"), (.fullSizeContentView, "fullSizeContentView"), (.fullScreen, "fullScreen"),
            ]
            let behaviors: [(NSWindow.CollectionBehavior, String)] = [
                (.managed, "managed"), (.transient, "transient"), (.moveToActiveSpace, "moveToActiveSpace"),
                (.fullScreenPrimary, "fullScreenPrimary"), (.fullScreenAuxiliary, "fullScreenAuxiliary"),
                (.fullScreenNone, "fullScreenNone"),
            ]
            let style = masks.filter { window.styleMask.contains($0.0) }.map { $0.1 }.joined(separator: "|")
            let collection = behaviors.filter { window.collectionBehavior.contains($0.0) }.map { $0.1 }
                .joined(separator: "|")
            NSLog(
                "zanshin.window %@: styleMask %@ collection %@ restorable %@ level %ld", key, style,
                collection.isEmpty ? "none" : collection, window.isRestorable ? "true" : "false",
                window.level.rawValue)
        }
    #endif
}

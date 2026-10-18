// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Native half of the bidirectional "zanshin_shell" channel.
///
/// Pushes system theme changes (dark/light, the accent, the text-selection
/// colours, the accessibility display options and the scroll bar style) to
/// Dart and executes window commands for every app window (Story 11.12 item 4):
/// the appearance override applies to all of them, also to each one that
/// becomes key later, and the drag and the titlebar double-click action act on
/// the window of the event that triggered them. It runs the folder picker
/// (`DirectoryPanel`) on the window of a given view, and reveals paths in
/// Finder. It also owns the `FolderDropHost` behind the
/// "zanshin_shell/folder_drop" channel and the `WindowChromeHost` behind
/// "zanshin_shell/window_chrome".
public class ZanshinShellPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    /// The engine's messenger, which names the Flutter views of this engine.
    private let messenger: FlutterBinaryMessenger
    private weak var view: NSView?
    /// The folder drop channel's host; lives as long as the plugin.
    private let folderDrops: FolderDropHost
    /// The window chrome channel's host; lives as long as the plugin.
    private let windowChrome: WindowChromeHost
    private var appearanceObservation: NSKeyValueObservation?
    /// The last `setWindowAppearance` choice; nil until Dart sent one.
    private var windowAppearance: NSAppearance??

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "zanshin_shell", binaryMessenger: registrar.messenger)
        let instance = ZanshinShellPlugin(
            channel: channel, messenger: registrar.messenger, view: registrar.view,
            folderDrops: FolderDropHost(messenger: registrar.messenger),
            windowChrome: WindowChromeHost(messenger: registrar.messenger))
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(
        channel: FlutterMethodChannel, messenger: FlutterBinaryMessenger, view: NSView?, folderDrops: FolderDropHost,
        windowChrome: WindowChromeHost
    ) {
        self.channel = channel
        self.messenger = messenger
        self.view = view
        self.folderDrops = folderDrops
        self.windowChrome = windowChrome
        super.init()

        // Covers dark/light switches AND accent changes: macOS republishes the
        // effective appearance when the accent color changes appearance-relevant
        // state; the distributed notification below covers pure accent swaps.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            self?.emitThemeChanged()
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAccentChanged),
            name: NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil
        )
        // Flutter's macOS embedder reports none of these, so the theme map
        // carries them and is re-sent whenever one changes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemChanged),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
        // `AppleScrollerPagingBehavior` ("Click in the scroll bar to") posts
        // no change notification, and System Settings or `defaults` can only
        // change it while another app is active; re-sending the theme when
        // Zanshin becomes active keeps it fresh for the next track press.
        // Dart ignores a report that changes nothing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // A window created after the last `setWindowAppearance` (a dialog
        // window) takes the choice when it becomes key, which the engine makes
        // it on its first frame.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAccentChanged(_ notification: Notification) {
        // The distributed notification can arrive before AppKit has refreshed
        // NSColor.controlAccentColor; resolve on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.emitThemeChanged()
        }
    }

    /// Accessibility display options, system colours or the scroller style
    /// changed, or Zanshin became active; AppKit has the new values once the
    /// notification is posted.
    @objc private func handleSystemChanged(_ notification: Notification) {
        emitThemeChanged()
    }

    @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
        guard let choice = windowAppearance, let window = notification.object as? NSWindow, Self.isAppWindow(window)
        else { return }
        if window.appearance != choice {
            window.appearance = choice
        }
    }

    private func emitThemeChanged() {
        channel.invokeMethod("onThemeChanged", arguments: currentTheme())
    }

    /// The window hosting the Flutter view - resolved lazily because the view
    /// is not attached to a window yet when the plugin registers.
    ///
    /// With a view-less engine - the runner's shape since every window is
    /// created from Dart - `registrar.view` is nil for good, and `mainWindow`
    /// is nil until some window has become key. So fall back to the app's own
    /// window list. `.titled` is the discriminator: the splash is borderless,
    /// has no titlebar to drag, zoom or re-appearance, and must never answer
    /// for the app.
    private var window: NSWindow? {
        if let attached = view?.window {
            return attached
        }
        if let main = NSApp.mainWindow, Self.isAppWindow(main) {
            return main
        }
        if let key = NSApp.keyWindow, Self.isAppWindow(key) {
            return key
        }
        return NSApp.windows.first(where: Self.isAppWindow)
    }

    /// - Returns: `true` for a Flutter window that carries the app's chrome
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        return window.contentViewController is FlutterViewController
            && window.styleMask.contains(.titled)
    }

    private func currentTheme() -> [String: Any] {
        let isDark =
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let aqua = NSAppearance(named: .aqua)
        let darkAqua = NSAppearance(named: .darkAqua)
        let workspace = NSWorkspace.shared

        // controlAccentColor is resolved in aqua, the appearance the "This Mac"
        // hue mapping and the Multicolor check are defined in. Fallback: the
        // aqua blue that macOS defaults to.
        var theme: [String: Any] = [
            "brightness": isDark ? "dark" : "light",
            "accentColor": Self.argb(NSColor.controlAccentColor, in: aqua) ?? 0xFF007AFF,
            "reduceMotion": workspace.accessibilityDisplayShouldReduceMotion,
            "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast,
            "scrollerStyle": NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay",
            // No change notification exists for this preference; the value
            // is re-read on every emit.
            "jumpToClickedSpot": UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior"),
        ]
        // Absent means Multicolor or an iMac's "This Mac" colour; omitted, so
        // Dart reads null.
        if let accent = UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int {
            theme["appleAccentColor"] = accent
        }
        let selection: [(String, NSColor, NSAppearance?)] = [
            ("selectedTextBackgroundDark", .selectedTextBackgroundColor, darkAqua),
            ("selectedTextBackgroundLight", .selectedTextBackgroundColor, aqua),
            ("unemphasizedSelectedTextBackgroundDark", .unemphasizedSelectedTextBackgroundColor, darkAqua),
            ("unemphasizedSelectedTextBackgroundLight", .unemphasizedSelectedTextBackgroundColor, aqua),
        ]
        for (key, color, appearance) in selection {
            if let argb = Self.argb(color, in: appearance) {
                theme[key] = argb
            }
        }
        return theme
    }

    /// - Returns: `color` resolved under `appearance` as an sRGB ARGB int, or
    ///   nil when either is unavailable
    private static func argb(_ color: NSColor, in appearance: NSAppearance?) -> Int? {
        guard let appearance = appearance else { return nil }
        var argb: Int?
        appearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                argb =
                    (Int(round(c.alphaComponent * 255)) << 24)
                    | (Int(round(c.redComponent * 255)) << 16)
                    | (Int(round(c.greenComponent * 255)) << 8)
                    | Int(round(c.blueComponent * 255))
            }
        }
        return argb
    }

    public func handle(
        _ call: FlutterMethodCall, result: @escaping FlutterResult
    ) {
        switch call.method {
        case "getTheme":
            result(currentTheme())
        case "setWindowAppearance":
            setWindowAppearance(call.arguments as? String)
            result(nil)
        case "startWindowDrag":
            // Reuses the mouse event of the Flutter gesture that triggered the
            // call, on the window it happened in; without an active event this
            // is a deliberate no-op.
            if let event = NSApp.currentEvent, let window = event.window ?? self.window {
                window.performDrag(with: event)
            }
            result(nil)
        case "performTitlebarDoubleClickAction":
            performTitlebarDoubleClickAction()
            result(nil)
        case "chooseDirectory":
            chooseDirectory(call.arguments as? [String: Any], result: result)
        case "revealInFinder":
            guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
                result(FlutterError(code: "bad-args", message: "revealInFinder needs a path", details: nil))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Runs the folder picker as a sheet on the window of the view named by
    /// `viewId`, or as a modal panel when no attached view has that id, and
    /// answers the chosen path or nil.
    private func chooseDirectory(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
        guard let viewId = arguments?["viewId"] as? Int else {
            result(FlutterError(code: "bad-args", message: "chooseDirectory needs a viewId", details: nil))
            return
        }
        let window = flutterViewController(FlutterViewIdentifier(viewId), messenger: messenger)?.view.window
        DirectoryPanel.choose(
            on: window, initialDirectory: arguments?["initialDirectory"] as? String,
            prompt: arguments?["prompt"] as? String
        ) { path in
            result(path)
        }
    }

    /// Per-window override on purpose: overriding NSApp.appearance would also
    /// flip the platformBrightness Flutter reports, hiding the real system
    /// value that the theme channel is supposed to deliver. The choice is kept
    /// and applied to every app window, so a theme switch from any window
    /// restyles all of them (the splash, borderless, is no app window).
    private func setWindowAppearance(_ name: String?) {
        let choice: NSAppearance?
        switch name {
        case "light":
            choice = NSAppearance(named: .aqua)
        case "dark":
            choice = NSAppearance(named: .darkAqua)
        default:
            choice = nil
        }
        windowAppearance = .some(choice)
        for window in NSApp.windows where Self.isAppWindow(window) {
            window.appearance = choice
        }
    }

    /// Mirrors the native titlebar double-click behavior, which the user
    /// configures in System Settings ("double-click a window's title bar to"),
    /// on the window of the double-click.
    private func performTitlebarDoubleClickAction() {
        guard let window = NSApp.currentEvent?.window ?? self.window else { return }
        let action = UserDefaults.standard.string(
            forKey: "AppleActionOnDoubleClick")
        // A dialog window that cannot miniaturize or zoom does nothing, as a
        // native title bar does (performing it anyway would beep).
        switch action {
        case "Minimize":
            if window.isMiniaturizable {
                window.performMiniaturize(nil)
            }
        case "None":
            break
        default:
            // "Maximize", "Fill" (unsupported pre-Sequoia semantics) and the
            // unset default all map to zoom.
            if window.isZoomable {
                window.performZoom(nil)
            }
        }
    }
}

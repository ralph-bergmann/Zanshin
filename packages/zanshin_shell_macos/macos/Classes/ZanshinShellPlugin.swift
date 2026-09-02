// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Native half of the bidirectional "zanshin_shell" channel.
///
/// Pushes system theme changes (dark/light + accent color) to Dart and
/// executes window commands (drag, appearance override, titlebar
/// double-click action) on the window that hosts the Flutter view.
public class ZanshinShellPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private weak var view: NSView?
    private var appearanceObservation: NSKeyValueObservation?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "zanshin_shell", binaryMessenger: registrar.messenger)
        let instance = ZanshinShellPlugin(channel: channel, view: registrar.view)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(channel: FlutterMethodChannel, view: NSView?) {
        self.channel = channel
        self.view = view
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
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleAccentChanged(_ notification: Notification) {
        // The distributed notification can arrive before AppKit has refreshed
        // NSColor.controlAccentColor; resolve on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.emitThemeChanged()
        }
    }

    private func emitThemeChanged() {
        channel.invokeMethod("onThemeChanged", arguments: currentTheme())
    }

    /// The window hosting the Flutter view - resolved lazily because the view
    /// is not attached to a window yet when the plugin registers.
    private var window: NSWindow? {
        return view?.window ?? NSApp.mainWindow
    }

    private func currentTheme() -> [String: Any] {
        let appearance = NSApp.effectiveAppearance
        let isDark =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // controlAccentColor is appearance-dependent; resolve it under the
        // current effective appearance so the ARGB value matches what the
        // user sees. Fallback: the accent blue that macOS defaults to.
        var argb = isDark ? 0xFF0A84FF : 0xFF007AFF
        appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                argb =
                    (Int(round(c.alphaComponent * 255)) << 24)
                    | (Int(round(c.redComponent * 255)) << 16)
                    | (Int(round(c.greenComponent * 255)) << 8)
                    | Int(round(c.blueComponent * 255))
            }
        }

        return ["brightness": isDark ? "dark" : "light", "accentColor": argb]
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
            // call; without an active event this is a deliberate no-op.
            if let window = self.window, let event = NSApp.currentEvent {
                window.performDrag(with: event)
            }
            result(nil)
        case "performTitlebarDoubleClickAction":
            performTitlebarDoubleClickAction()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Per-window override on purpose: overriding NSApp.appearance would also
    /// flip the platformBrightness Flutter reports, hiding the real system
    /// value that the theme channel is supposed to deliver.
    private func setWindowAppearance(_ name: String?) {
        guard let window = self.window else { return }
        switch name {
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        default:
            window.appearance = nil
        }
    }

    /// Mirrors the native titlebar double-click behavior, which the user
    /// configures in System Settings ("double-click a window's title bar to").
    private func performTitlebarDoubleClickAction() {
        guard let window = self.window else { return }
        let action = UserDefaults.standard.string(
            forKey: "AppleActionOnDoubleClick")
        switch action {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            // "Maximize", "Fill" (unsupported pre-Sequoia semantics) and the
            // unset default all map to zoom.
            window.performZoom(nil)
        }
    }
}

// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Runs the engine without a view and hosts the window channels.
///
/// Every window is created from Dart: the engine allows multi-view only while
/// it has no view yet, so the runner attaches none. There is no nib window and
/// no `MainFlutterWindow` any more; Dart's own registry ends the process once
/// no window that keeps the app alive is left (Story 11.12).
final class WindowingBootstrap {
    private let engine = FlutterEngine(name: "zanshin", project: nil)
    private var splashWindowHost: SplashWindowHost?
    private var windowFrameStore: WindowFrameStore?
    private var menuStateChannel: MenuStateChannel?
    private var fontsChannel: FontsChannel?

    /// Hot-restart workaround for an engine bug: `closeAllWindows` disposes
    /// each window's view controller and then closes the window without
    /// detaching the window delegate (`destroyWindow` does detach it).
    /// Closing the key window then reports "resign key" to a delegate that
    /// asks the disposed controller for its view id and throws. Detaching the
    /// delegate as soon as a Flutter window closes keeps the debug build alive
    /// across hot restarts; `destroyWindow` calls the delegate's close hook
    /// explicitly, so nothing is lost on a regular close.
    private let closingWindows = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { note in
        if let window = note.object as? NSWindow, window.contentViewController is FlutterViewController {
            window.delegate = nil
        }
    }

    func start() {
        WindowingBootstrap.activate()
        RegisterGeneratedPlugins(registry: engine)
        splashWindowHost = SplashWindowHost(messenger: engine.binaryMessenger)
        windowFrameStore = WindowFrameStore(messenger: engine.binaryMessenger)
        menuStateChannel = MenuStateChannel(messenger: engine.binaryMessenger)
        fontsChannel = FontsChannel(messenger: engine.binaryMessenger)
        engine.run(withEntrypoint: nil)
    }

    /// The Dock was clicked while no window is visible: Dart decides what comes
    /// back (the minimised project window, else Projects).
    func reopen() {
        windowFrameStore?.reopen()
    }

    /// Brings the app to the front even when it was not launched through
    /// LaunchServices: `flutter run --release` and a plain exec start it
    /// inactive, behind the terminal (in debug mode the tool runs `open` on
    /// the bundle after attaching, release never does). Under cooperative
    /// activation (macOS 14+) a bare `activate()` only succeeds after the
    /// frontmost app yielded, which a terminal never does; the soft-deprecated
    /// `ignoringOtherApps` variant is the one AppKit still honours here.
    /// macOS 26 is reported to drop activation requests at random (Apple
    /// FB21087054), so it is issued twice.
    static func activate() {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// Native half of the `zanshin/menu_state` channel (Story 11.17): what the
/// engine's menu bar cannot express, applied to the `NSApp.mainMenu` it has
/// just built.
///
/// The engine gives its items no stable id (`tag` is a per-build serial), so
/// a toggle is found by its top menu's and its own title (the Dart labels), a
/// system item by its selector. Its submenus have `autoenablesItems = NO`, so
/// an `isEnabled` or `title` set here stays until the next build replaces the
/// menu; AppKit never validates, so it never retitles Enter Full Screen
/// itself. Every title comes from Dart (its strings).
final class MenuStateChannel {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "zanshin/menu_state", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "apply" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let payload = MenuStateChannel.Payload(call.arguments) else {
            result(
                FlutterError(
                    code: "bad-args",
                    message:
                        "expected checked: [{menu, item, checked}], enabled: {selector: bool} and titles: {selector: string}",
                    details: nil))
            return
        }
        if let mainMenu = NSApp.mainMenu, let windows = MenuStateChannel.apply(payload, to: mainMenu),
            NSApp.windowsMenu !== windows
        {
            NSApp.windowsMenu = windows
        }
        result(nil)
    }

    /// `apply`'s arguments, parsed strictly before anything changes: a
    /// malformed payload changes nothing.
    struct Payload {
        let checked: [(menu: String, item: String, on: Bool)]
        let enabled: [String: Bool]
        let titles: [String: String]

        init?(_ arguments: Any?) {
            guard let args = arguments as? [String: Any],
                let checkedArgs = args["checked"] as? [[String: Any]],
                let enabled = args["enabled"] as? [String: Bool],
                let titles = args["titles"] as? [String: String]
            else { return nil }
            var checked: [(menu: String, item: String, on: Bool)] = []
            for entry in checkedArgs {
                guard let menu = entry["menu"] as? String, let item = entry["item"] as? String,
                    let on = entry["checked"] as? Bool
                else { return nil }
                checked.append((menu, item, on))
            }
            self.checked = checked
            self.enabled = enabled
            self.titles = titles
        }
    }

    /// Sets the toggles' `state` and the selector items' `isEnabled` and
    /// `title` in `mainMenu` (an item not found is skipped) and returns the
    /// submenu holding `arrangeInFront:`, the menu `NSApp.windowsMenu` should
    /// be.
    static func apply(_ payload: Payload, to mainMenu: NSMenu) -> NSMenu? {
        for toggle in payload.checked {
            mainMenu.item(withTitle: toggle.menu)?.submenu?.item(withTitle: toggle.item)?.state =
                toggle.on ? .on : .off
        }
        let submenus = mainMenu.items.compactMap(\.submenu)
        func items(for selector: String) -> [NSMenuItem] {
            let action = NSSelectorFromString(selector)
            return submenus.flatMap { $0.items.filter { $0.action == action } }
        }
        for (selector, isEnabled) in payload.enabled {
            for item in items(for: selector) {
                item.isEnabled = isEnabled
            }
        }
        for (selector, title) in payload.titles {
            for item in items(for: selector) {
                item.title = title
            }
        }
        let arrange = #selector(NSApplication.arrangeInFront(_:))
        return submenus.first(where: { $0.items.contains { $0.action == arrange } })
    }
}

/// Native half of the `zanshin/fonts` channel: the installed fixed-pitch font
/// families for the code font setting. Flutter uses an installed font by name
/// but cannot list them.
///
/// Reading every family takes up to a second and a half cold, so the answer is
/// built on a background queue with CoreText (AppKit's `NSFontManager` is not
/// documented thread-safe) and sent back on the main queue. The queue is
/// serial, so the answers keep the order of the calls and an older list never
/// lands after a newer one.
final class FontsChannel {
    private let channel: FlutterMethodChannel
    private let queue = DispatchQueue(label: "zanshin.fonts", qos: .userInitiated)

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "zanshin/fonts", binaryMessenger: messenger)
        channel.setMethodCallHandler { [queue] call, result in
            guard call.method == "monospacedFamilies" else {
                result(FlutterMethodNotImplemented)
                return
            }
            queue.async {
                let families = FontsChannel.monospacedFamilies(of: FontsChannel.installedFamilies())
                DispatchQueue.main.async { result(families) }
            }
        }
    }

    /// The installed families, without the hidden system ones (names starting with ".").
    static func installedFamilies() -> [String] {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The families whose default, regular face is fixed pitch, sorted case-insensitively. A family CoreText
    /// resolves to another family counts as missing.
    static func monospacedFamilies(of families: [String]) -> [String] {
        families.filter { family in
            let attributes = [kCTFontFamilyNameAttribute: family] as CFDictionary
            let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes), 12, nil)
            return CTFontCopyFamilyName(font) as String == family
                && CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// Native half of the `zanshin/splash_window` channel: strips the chrome off a
/// Flutter-created dialog window and fades it out.
///
/// The window is addressed by the NSWindow pointer the macOS window controller
/// exposes to Dart; it is only valid while that window is alive.
final class SplashWindowHost {
    private let channel: FlutterMethodChannel
    private weak var splashWindow: NSWindow?
    /// The floating level is global, so the splash only floats while this app
    /// is active and drops to the normal level otherwise: it stays visible
    /// (unlike `hidesOnDeactivate`, which races the activation at start) but
    /// never hovers over other apps' windows.
    private var activationObservers: [NSObjectProtocol] = []

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "zanshin/splash_window", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                self?.splashWindow?.level = .floating
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                self?.splashWindow?.level = .normal
            },
        ]
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let handle = args["window"] as? Int,
            let window = SplashWindowHost.window(fromHandle: handle)
        else {
            result(FlutterError(code: "bad-args", message: "expected a window handle", details: nil))
            return
        }
        switch call.method {
        case "configure":
            guard let width = args["width"] as? Double, let height = args["height"] as? Double else {
                result(FlutterError(code: "bad-args", message: "expected width and height", details: nil))
                return
            }
            configure(window, contentSize: NSSize(width: width, height: height))
            result(nil)
        case "fadeOut":
            let millis = args["durationMs"] as? Int ?? 250
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = Double(millis) / 1000
                    window.animator().alphaValue = 0
                },
                completionHandler: { result(nil) })
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func window(fromHandle handle: Int) -> NSWindow? {
        guard let pointer = UnsafeRawPointer(bitPattern: handle) else { return nil }
        return Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
    }

    /// Borderless, fixed, centred and floating above the app's own windows;
    /// the Flutter content draws its own rounded card on the transparent
    /// background.
    private func configure(_ window: NSWindow, contentSize: NSSize) {
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovable = false
        window.level = NSApp.isActive ? .floating : .normal
        window.isExcludedFromWindowsMenu = true
        // Like every window (Story 11.12): AppKit's state restoration must not
        // put a stale frame back over this one.
        window.isRestorable = false
        splashWindow = window
        (window.contentViewController as? FlutterViewController)?.backgroundColor = .clear
        window.setContentSize(contentSize)
        window.center()

        // A borderless window cannot become key and activate the app itself.
        WindowingBootstrap.activate()
    }
}

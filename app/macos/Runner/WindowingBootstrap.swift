// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Runs the engine without a view and hosts the window channels.
///
/// Every window is created from Dart: the engine allows multi-view only while
/// it has no view yet, so the runner attaches none. There is no nib window and
/// no `MainFlutterWindow` any more; Dart's own registry ends the process with
/// its last window.
final class WindowingBootstrap {
    private let engine = FlutterEngine(name: "zanshin", project: nil)
    private var splashWindowHost: SplashWindowHost?
    private var windowFrameStore: WindowFrameStore?

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
        engine.run(withEntrypoint: nil)
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
        splashWindow = window
        (window.contentViewController as? FlutterViewController)?.backgroundColor = .clear
        window.setContentSize(contentSize)
        window.center()

        // A borderless window cannot become key and activate the app itself.
        WindowingBootstrap.activate()
    }
}

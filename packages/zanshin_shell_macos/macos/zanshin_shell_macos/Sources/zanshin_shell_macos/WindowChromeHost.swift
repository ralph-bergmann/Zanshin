// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Native half of the `zanshin_shell/window_chrome` channel: for each Flutter view Dart watches, measures whether its
/// window is in full screen and where the window's standard buttons sit, and pushes every change.
///
/// `watch {viewId}` answers the current report and measures once more on the next run-loop turn, because the toolbar
/// attaches lazily and rebuilds the titlebar; `unwatch {viewId}` stops. A report is
/// `{fullScreen, trafficLights?: {x, y, width, height}}`, the block in the Flutter view's points with the origin top
/// left and absent in full screen or while no button is visible. The buttons are only read, never moved.
///
/// The triggers are Claude's proposal (Story 11.4): the window's resize, key, full-screen and close notifications
/// and the frame changes of the current buttons, which AppKit replaces when it rebuilds the titlebar. Each one
/// re-measures and sends `changed {viewId, …}` only when the report differs from the last one sent. AppKit posts no
/// notification when entering full screen fails (only the window's delegate, the engine's, hears
/// `windowDidFailToEnterFullScreen(_:)`), so a full-screen entry that has not arrived after
/// `enterFullScreenTimeout` is taken as failed.
final class WindowChromeHost {
    private let channel: FlutterMethodChannel
    private let messenger: FlutterBinaryMessenger
    private var watches: [FlutterViewIdentifier: WindowChromeWatch] = [:]

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        channel = FlutterMethodChannel(name: "zanshin_shell/window_chrome", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any], let viewId = args["viewId"] as? Int else {
            result(FlutterError(code: "bad-args", message: "expected a viewId", details: nil))
            return
        }
        let id = FlutterViewIdentifier(viewId)
        switch call.method {
        case "watch":
            guard let controller = flutterViewController(id, messenger: messenger),
                let answer = watch(controller, id: id).answer()
            else {
                result(FlutterError(code: "unknown-view", message: "no Flutter view with id \(viewId)", details: nil))
                return
            }
            result(answer)
        case "unwatch":
            watches.removeValue(forKey: id)?.stop()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// The watch of `controller`'s view: the existing one while it still follows the same controller and window,
    /// else a new one.
    private func watch(_ controller: FlutterViewController, id: FlutterViewIdentifier) -> WindowChromeWatch {
        if let existing = watches[id], existing.follows(controller) {
            return existing
        }
        watches.removeValue(forKey: id)?.stop()
        let watch = WindowChromeWatch(
            controller: controller,
            send: { [weak self] report in
                self?.channel.invokeMethod("changed", arguments: report.arguments(viewId: id))
            },
            closed: { [weak self] in
                self?.watches.removeValue(forKey: id)?.stop()
            }
        )
        watches[id] = watch
        return watch
    }
}

/// One measurement of a watched view's window.
private struct WindowChromeReport: Equatable {
    let fullScreen: Bool

    /// The union of the visible standard buttons in the Flutter view's points, origin top left.
    let trafficLights: CGRect?

    /// The report as the channel carries it; without a block the key is absent.
    var arguments: [String: Any] {
        var map: [String: Any] = ["fullScreen": fullScreen]
        if let block = trafficLights {
            map["trafficLights"] = [
                "x": Double(block.minX),
                "y": Double(block.minY),
                "width": Double(block.width),
                "height": Double(block.height),
            ]
        }
        return map
    }

    /// The `changed` call's arguments for the view `viewId`.
    func arguments(viewId: FlutterViewIdentifier) -> [String: Any] {
        var map = arguments
        map["viewId"] = Int(viewId)
        return map
    }
}

/// How long after `willEnterFullScreen` a window that is still not in full screen counts as having failed to enter
/// it; the system's transition takes well under a second (Claude's proposal).
private let enterFullScreenTimeout: DispatchTimeInterval = .seconds(2)

/// The observers of one watched view's window and the last report sent for it.
private final class WindowChromeWatch {
    private weak var controller: FlutterViewController?
    private weak var window: NSWindow?
    private let send: (WindowChromeReport) -> Void
    private var windowObservers: [NSObjectProtocol] = []
    private var buttonObservers: [NSObjectProtocol] = []

    /// The buttons `buttonObservers` follow, compared by identity: AppKit replaces them when it rebuilds the titlebar.
    private var observedButtons: [NSButton] = []

    /// Set from `willEnterFullScreen` to the transition's end (or its failure), while `styleMask` may not say full
    /// screen yet.
    private var entering = false

    /// The pending check that ends the current full-screen entry as failed; cancelled when the entry ends, replaced
    /// by the next entry.
    private var failedEntryCheck: DispatchWorkItem?
    private var lastSent: WindowChromeReport?

    init(
        controller: FlutterViewController, send: @escaping (WindowChromeReport) -> Void,
        closed: @escaping () -> Void
    ) {
        self.controller = controller
        window = controller.view.window
        self.send = send
        observeWindow(closed: closed)
    }

    deinit {
        stop()
    }

    /// - Returns: `true` while this watch measures `candidate`'s view in the window it shows now
    func follows(_ candidate: FlutterViewController) -> Bool {
        return controller === candidate && window != nil && window === candidate.view.window
    }

    /// The current report as `watch` answers it, nil without a window; measures once more on the next run-loop turn.
    func answer() -> [String: Any]? {
        guard let report = measure() else { return nil }
        lastSent = report
        DispatchQueue.main.async { [weak self] in
            self?.update()
        }
        return report.arguments
    }

    /// Removes every observer and cancels a pending full-screen check.
    func stop() {
        failedEntryCheck?.cancel()
        failedEntryCheck = nil
        (windowObservers + buttonObservers).forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        buttonObservers = []
        observedButtons = []
    }

    private func observeWindow(closed: @escaping () -> Void) {
        guard let window = self.window else { return }
        func on(_ name: NSNotification.Name, _ action: @escaping (WindowChromeWatch) -> Void) -> NSObjectProtocol {
            return NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) {
                [weak self] _ in
                if let self = self {
                    action(self)
                }
            }
        }
        windowObservers = [
            on(NSWindow.didResizeNotification) { $0.update() },
            on(NSWindow.didBecomeKeyNotification) { $0.update() },
            on(NSWindow.willEnterFullScreenNotification) { $0.beginEntry() },
            on(NSWindow.didEnterFullScreenNotification) { $0.endEntry() },
            on(NSWindow.didExitFullScreenNotification) { $0.endEntry() },
            on(NSWindow.willCloseNotification) { _ in closed() },
        ]
    }

    /// Starts a full-screen entry: sets `entering`, re-measures and schedules this entry's failure check, replacing
    /// an earlier entry's.
    private func beginEntry() {
        entering = true
        update()
        failedEntryCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            self?.endFailedEntry()
        }
        failedEntryCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + enterFullScreenTimeout, execute: check)
    }

    /// Ends the transition (`didEnterFullScreen`, `didExitFullScreen`): cancels the failure check, clears `entering`
    /// and re-measures.
    private func endEntry() {
        failedEntryCheck?.cancel()
        failedEntryCheck = nil
        entering = false
        update()
    }

    /// Clears `entering` when the window never reached full screen, and re-measures.
    private func endFailedEntry() {
        failedEntryCheck = nil
        guard entering, let window = self.window, !window.styleMask.contains(.fullScreen) else { return }
        entering = false
        update()
    }

    /// Follows the frames of `buttons` instead of the ones observed so far.
    private func observe(_ buttons: [NSButton]) {
        buttonObservers.forEach { NotificationCenter.default.removeObserver($0) }
        observedButtons = buttons
        buttonObservers = buttons.map { button in
            button.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: nil
            ) { [weak self] _ in
                self?.update()
            }
        }
    }

    /// Re-measures and sends the report when it differs from the last one sent.
    private func update() {
        guard let report = measure(), report != lastSent else { return }
        lastSent = report
        send(report)
    }

    /// The window's report now, nil once the view or the window is gone.
    private func measure() -> WindowChromeReport? {
        guard let window = self.window, let view = controller?.view else { return nil }
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        if !buttons.elementsEqual(observedButtons, by: ===) {
            observe(buttons)
        }
        if entering || window.styleMask.contains(.fullScreen) {
            return WindowChromeReport(fullScreen: true, trafficLights: nil)
        }
        // Hidden buttons and those AppKit moved into another window (the full-screen reveal bar) are not the block.
        let frames = buttons
            .filter { !$0.isHidden && $0.window === window }
            .map { view.convert($0.bounds, from: $0) }
        guard let first = frames.first else {
            return WindowChromeReport(fullScreen: false, trafficLights: nil)
        }
        var block = frames.dropFirst().reduce(first) { $0.union($1) }
        if !view.isFlipped {
            block.origin.y = view.bounds.height - block.maxY
        }
        return WindowChromeReport(fullScreen: false, trafficLights: block)
    }
}

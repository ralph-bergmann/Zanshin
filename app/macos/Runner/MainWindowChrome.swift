// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// The app's custom window chrome, applied to a window the Flutter engine
/// created on Dart's behalf.
///
/// Before the windowing API this was `MainFlutterWindow`, an `NSWindow`
/// subclass loaded from the nib. Now Dart creates every window and the runner
/// only gets a handle to it, so the same treatment is applied from the outside:
/// `WindowFrameStore` builds one of these for the window that asks for chrome,
/// *before* it restores the saved frame.
///
/// The ordering is load-bearing. With `.fullSizeContentView` the frame equals
/// the content size; applying a saved frame while the titlebar still occupies
/// its own strip would shave the titlebar height off the window on every launch.
///
/// The window is opaque on a colour set, so the system rounds and clips it with
/// its own corner radius and a frame the Flutter view has not drawn yet shows
/// the theme's base; the colour set's appearance variants follow
/// `setWindowAppearance` (paper = aqua, night = darkAqua). The Flutter view
/// stays clear and paints everything, so no view lies below it (Story 11.4,
/// Claude's proposal).
///
/// Two kinds (Story 11.12 item 2):
/// - `main`, the project window: miniaturizable and resizable, the 880 × 560
///   minimum, on `CanvasBase` (`--canvas-base`).
/// - `secondary`, a dialog window (Settings, Projects, Configurations): the
///   engine's style mask (Titled | Closable, Resizable where it asked for it, never
///   Miniaturizable) plus `.fullSizeContentView`, no forced minimum, on
///   `WindowFillBase` (`--fl-bg-solid`, the window fill's base). No vibrancy: the
///   window is opaque and Flutter paints the fill.
/// Both get the transparent titlebar, the hidden title, the empty toolbar that
/// puts the traffic lights where the project window has them, the drag
/// interceptor and the `--tl-ring` rings, greyed buttons included.
final class MainWindowChrome {
    private weak var window: NSWindow?
    private let kind: WindowChromeKind

    /// Click-through overlay that paints the neutral resting state of the window
    /// control buttons (close, minimize, zoom). Kept as a strong reference so the
    /// overlay can be re-attached whenever AppKit rebuilds the titlebar.
    private var trafficLightOverlay: TrafficLightOverlayView?

    init(window: NSWindow, kind: WindowChromeKind) {
        self.window = window
        self.kind = kind

        setupWindowAppearance()
        setupWindowButtons()
    }

    /// Removes the notification observers when the chrome is deallocated
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Add a toolbar to move the window control buttons (close, minimize, zoom) a little bit down.
    /// Without this, the buttons would appear too close to the top border. The toolbar contains
    /// a custom invisible item that prevents window dragging in the titlebar area, as this
    /// functionality is handled by Flutter instead. This is necessary because Flutter UI elements
    /// in the toolbar area need to receive mouse events without interference from the native
    /// window dragging behavior.
    private func setupWindowAppearance() {
        guard let window = self.window else { return }

        switch kind {
        case .main:
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.backgroundColor = NSColor(named: "CanvasBase") ?? .windowBackgroundColor
            // The project window's minimum (decision 16.37), as `defaultWindowConstraints` in Dart.
            window.minSize = NSSize(width: 880, height: 560)
        case .secondary:
            // The engine's dialog mask stays (no minimise; zoom only where resizable); the dialog passes its own
            // minimum through its constraints.
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(named: "WindowFillBase") ?? .windowBackgroundColor
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.hasShadow = true

        // See-through, so the window's base shows until the first Flutter frame.
        (window.contentViewController as? FlutterViewController)?.backgroundColor = .clear

        // Add toolbar with custom invisible item to prevent window dragging
        let toolbar = NSToolbar(identifier: "Toolbar")
        let accessoryController = TitlebarAccessoryController()
        accessoryController.layoutAttribute = .top
        window.addTitlebarAccessoryViewController(accessoryController)

        window.toolbar = toolbar
    }

    /// Installs the neutral overlay on top of the window control buttons
    /// (close, minimize, zoom) and registers the window notifications that keep
    /// the overlay attached and correctly positioned.
    private func setupWindowButtons() {
        guard let window = self.window else { return }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowWillEnterFullScreen),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )

        installTrafficLightOverlay()

        // The toolbar and the titlebar accessory view controller are attached
        // lazily, which can rebuild the titlebar view hierarchy after this method
        // has returned. `installTrafficLightOverlay()` is idempotent, so simply run
        // it once more after the current run loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.installTrafficLightOverlay()
        }
    }

    /// Creates - or re-attaches - the overlay that paints the resting state of the
    /// window control buttons.
    ///
    /// AppKit owns the titlebar view hierarchy and is free to rebuild it (when the
    /// toolbar attaches, when the style mask changes or when the window leaves
    /// fullscreen), which can move the standard window buttons into a fresh
    /// superview or replace them outright. This method is therefore idempotent: it
    /// reuses the existing overlay as long as it is still attached to the current
    /// buttons and only rebuilds it otherwise, so it can safely be called from
    /// several notifications without piling up overlays or tracking areas.
    private func installTrafficLightOverlay() {
        guard let window = self.window else { return }

        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton),
        ].compactMap { $0 }

        guard !buttons.isEmpty, let host = buttons[0].superview else { return }

        if let overlay = trafficLightOverlay {
            if overlay.superview === host, overlay.tracks(buttons) {
                // Only re-stack when AppKit put something on top of the overlay -
                // re-adding an existing subview would needlessly tear down and
                // rebuild its tracking area.
                if host.subviews.last !== overlay {
                    host.addSubview(overlay, positioned: .above, relativeTo: nil)
                }
                overlay.syncGeometry()
                // A titlebar rebuild resets the buttons to full opacity, so push the
                // resting state back onto them instead of assuming it survived.
                overlay.reassertState()
                return
            }
            // Hand the old buttons back before dropping the overlay that owns their
            // transparency, so they cannot be orphaned invisible.
            overlay.restoreButtons()
            overlay.removeFromSuperview()
            trafficLightOverlay = nil
        }

        let overlay = TrafficLightOverlayView(buttons: buttons)
        // Stack the overlay above every existing titlebar subview so that it covers
        // the buttons. It never becomes the hit-test result, so the buttons keep
        // receiving all mouse events.
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.syncGeometry()
        overlay.setSuppressed(window.styleMask.contains(.fullScreen))
        overlay.reassertState()
        trafficLightOverlay = overlay
    }

    /// Re-attaches the overlay when the window becomes key, because a preceding
    /// titlebar rebuild may have orphaned it
    @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
        installTrafficLightOverlay()
    }

    /// Hides the overlay before the fullscreen transition starts so it cannot
    /// interfere with the fullscreen titlebar
    @objc private func handleWindowWillEnterFullScreen(_ notification: Notification) {
        trafficLightOverlay?.setSuppressed(true)
    }

    /// Re-attaches and shows the overlay after leaving fullscreen, where AppKit has
    /// rebuilt the titlebar
    @objc private func handleWindowDidExitFullScreen(_ notification: Notification) {
        installTrafficLightOverlay()
        trafficLightOverlay?.setSuppressed(false)
    }

    // Window resize event handler
    @objc private func handleWindowDidResize(_ notification: Notification) {
        trafficLightOverlay?.syncGeometry()
    }
}

/// Click-through overlay that paints the resting state of the three standard window
/// buttons (close, minimize, zoom): a 1 pt ring in the theme's `--tl-ring` with a
/// fully transparent interior, so whatever the window paints underneath shows
/// through it - a deliberate deviation from the system (decision 16.5).
///
/// The view is a *sibling* of the buttons, stacked above them inside the titlebar.
/// It never returns itself from `hitTest(_:)`, so the real buttons keep every bit of
/// their native behaviour - glyph rollover, clicks and the zoom button's fullscreen
/// and tiling menu.
///
/// Because the ring interior is transparent, the native colored circles must not be
/// visible underneath it at rest. They are therefore faded out via `alphaValue`.
/// `alphaValue` rather than `isHidden` on purpose: a hidden view drops out of hit
/// testing and out of the accessibility tree, a fully transparent one stays
/// clickable and keeps its accessibility label.
///
/// Hovering anywhere over the cluster cross fades the whole group at once (group
/// semantics, like macOS itself): the rings fade out while the native buttons fade
/// in. A single tracking area spanning the whole cluster provides that.
///
/// An earlier revision painted an opaque, theme colored disc behind each ring to
/// hide the native color. That could never line up: the Flutter UI paints its own
/// theme derived titlebar background, so a disc matching the *system* light/dark
/// palette clashed with it. A transparent interior sidesteps the problem entirely.
///
/// The ring colour is the `TrafficLightRing` colour set (night and paper). A
/// `CGColor` does not follow appearance changes, so the overlay resolves the named
/// colour in its effective appearance - which follows the app theme through
/// `setWindowAppearance` - on attach and on every appearance change.
final class TrafficLightOverlayView: NSView {
    /// Stroke width of a single ring in points.
    ///
    /// The ring *diameter* is deliberately not a constant: the native traffic light
    /// size varies by macOS version, so it is derived from the button geometry in
    /// `syncGeometry()`.
    private static let ringLineWidth: CGFloat = 1.0

    /// Duration of the cross fade between the rings and the native buttons on hover
    private static let hoverAnimationDuration: CFTimeInterval = 0.1

    /// The standard window buttons this overlay is painted on top of
    private let buttons: [NSButton]

    /// Stroke only rings, one per button. A single layer is enough: all rings share
    /// their color and are shown and hidden as a group.
    private let ringLayer = CAShapeLayer()

    /// The tracking area covering the whole button cluster.
    /// Recreated by `updateTrackingAreas()`, never accumulated.
    private var clusterTrackingArea: NSTrackingArea?

    /// Observer tokens that keep the overlay aligned with the buttons
    private var frameObservers: [NSObjectProtocol] = []

    /// `true` while the pointer is inside the button cluster
    private var isHovered = false

    /// `true` while the rings must stay hidden regardless of hover (fullscreen)
    private var isSuppressed = false

    /// `true` while the native buttons are the visible representation of the
    /// cluster, i.e. on hover and while suppressed
    private var revealsNativeButtons: Bool {
        return isHovered || isSuppressed
    }

    /// Creates an overlay for the given standard window buttons
    /// - Parameter buttons: The standard window buttons to cover. They must all
    ///   share the same superview, which is the case for the traffic light cluster.
    init(buttons: [NSButton]) {
        self.buttons = buttons
        super.init(frame: .zero)

        // Do not let AppKit resize the overlay behind our back: `syncGeometry()` is
        // the single place that positions it.
        autoresizingMask = []

        // Ring only: the interior stays transparent so the window's own background
        // shows through. The stroke colour is set on attach (`syncRingColor()`).
        ringLayer.lineWidth = Self.ringLineWidth
        ringLayer.fillColor = nil

        // Layer hosting view: the layer belongs to us, so managing its sublayers is
        // legal - unlike doing the same to the system buttons.
        let hostLayer = CALayer()
        hostLayer.addSublayer(ringLayer)
        self.layer = hostLayer
        self.wantsLayer = true

        // The ring's outer edge sits exactly on the overlay bounds, so keep its
        // antialiased rim from being clipped. `false` is the default, set it
        // explicitly.
        hostLayer.masksToBounds = false
        ringLayer.masksToBounds = false

        observeButtonFrames()

        // Establish the resting state immediately: rings visible, native buttons
        // transparent.
        applyState(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        frameObservers.forEach { NotificationCenter.default.removeObserver($0) }

        // Safety net: this overlay owns the buttons' transparency, so it must never
        // go away while leaving them invisible.
        restoreButtons()
    }

    // MARK: - Event transparency

    /// Never becomes the hit-test result so that all mouse events reach the real
    /// window buttons underneath
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override var acceptsFirstResponder: Bool {
        return false
    }

    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    // MARK: - Geometry

    /// Aligns the overlay with the current button frames.
    ///
    /// The overlay spans the union of the button frames, which is exactly the region
    /// the hover tracking area has to cover, and draws one centered ring per visible
    /// button.
    func syncGeometry() {
        guard let host = superview else { return }

        let visibleButtons = buttons.filter { !$0.isHidden }
        guard let first = visibleButtons.first else {
            ringLayer.path = nil
            return
        }

        let clusterFrame = visibleButtons.dropFirst().reduce(first.frame) {
            $0.union($1.frame)
        }
        if frame != clusterFrame {
            frame = clusterFrame
        }

        // Layer geometry must not animate while it follows the buttons
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        ringLayer.frame = bounds

        let ringPath = CGMutablePath()
        for button in visibleButtons {
            // `convert(_:from:)` keeps this correct no matter whether the titlebar
            // view uses flipped coordinates
            let buttonRect = convert(button.frame, from: host)

            // Size the ring from the button instead of hardcoding a diameter: the
            // native traffic lights are drawn larger on newer macOS versions than the
            // 12 pt this used to assume. The stroke is centered on the path, so
            // subtracting the line width puts the ring's *outer* edge exactly on the
            // button's shorter side - which is what makes the ring and the native
            // circle line up during the hover cross fade.
            let nativeDiameter = min(buttonRect.width, buttonRect.height)
            let ringDiameter = nativeDiameter - Self.ringLineWidth
            guard ringDiameter > 0 else { continue }

            ringPath.addEllipse(
                in: Self.circle(ofDiameter: ringDiameter, centeredIn: buttonRect))
        }
        ringLayer.path = ringPath

        CATransaction.commit()
    }

    /// - Parameters:
    ///   - diameter: The diameter of the circle in points
    ///   - rect: The rect to center the circle in
    /// - Returns: The bounding rect of a circle of `diameter` centered in `rect`
    private static func circle(ofDiameter diameter: CGFloat, centeredIn rect: CGRect)
        -> CGRect
    {
        return CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    /// - Parameter candidates: The standard window buttons to compare against
    /// - Returns: `true` when this overlay was built for exactly these button
    ///   instances, i.e. when AppKit has not replaced them in the meantime
    func tracks(_ candidates: [NSButton]) -> Bool {
        guard candidates.count == buttons.count else { return false }
        return zip(buttons, candidates).allSatisfy { $0 === $1 }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        if superview != nil {
            syncGeometry()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            // Do not rely on AppKit invoking this on its own before the first
            // hover; `updateTrackingAreas()` replaces the area instead of adding
            // another one, so calling it explicitly is safe.
            updateTrackingAreas()

            // AppKit does not reliably call `viewDidChangeBackingProperties()` on
            // the initial attach, so sync the scale here as well.
            syncContentsScale()

            syncRingColor()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()

        syncRingColor()
    }

    /// Resolves the `TrafficLightRing` colour set in the overlay's effective
    /// appearance and strokes the rings with it, without an implicit animation.
    private func syncRingColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ringLayer.strokeColor = NSColor(named: "TrafficLightRing")?.cgColor
            CATransaction.commit()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        syncContentsScale()
    }

    /// Matches the ring layer's `contentsScale` to the screen the window is on.
    ///
    /// A layer hosting view does not get its sublayers' `contentsScale` updated for
    /// free; without this the rings would be rasterized at 1x on Retina.
    private func syncContentsScale() {
        guard let scale = window?.backingScaleFactor else { return }

        layer?.contentsScale = scale
        ringLayer.contentsScale = scale
    }

    /// Keeps the overlay glued to the buttons if AppKit moves or resizes them, for
    /// example when the titlebar height changes
    private func observeButtonFrames() {
        frameObservers = buttons.map { button in
            // Defaults to `true` for `NSView`, set explicitly to be safe
            button.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: button,
                queue: nil
            ) { [weak self] _ in
                self?.syncGeometry()
            }
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = clusterTrackingArea {
            removeTrackingArea(existing)
            clusterTrackingArea = nil
        }

        // `.inVisibleRect` makes AppKit keep the tracked region in sync with the
        // view, `.activeAlways` makes hovering work while the window is not key.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        clusterTrackingArea = area

        // A fresh tracking area does not report a pointer that is already inside it,
        // so resolve the current hover state explicitly and push it onto the rings
        // *and* the buttons. This prevents rings from staying hidden - or buttons
        // from staying transparent - after the overlay was re-attached mid hover.
        reassertState()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false, animated: true)
    }

    /// Hides or shows the rings independently of the hover state.
    ///
    /// While suppressed the native buttons are handed back at full opacity: in
    /// fullscreen AppKit owns them inside the reveal bar.
    /// - Parameter suppressed: `true` while the window is in fullscreen
    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }

        isSuppressed = suppressed
        applyState(animated: false)
    }

    /// - Parameters:
    ///   - hovered: `true` when the pointer is inside the button cluster
    ///   - animated: Whether the change should be cross faded
    private func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != isHovered else { return }

        isHovered = hovered
        applyState(animated: animated)
    }

    // MARK: - Resting state

    /// Re-resolves the hover state from the current pointer position and re-applies
    /// it to the rings and the buttons, bypassing the change guards.
    ///
    /// Whenever AppKit rebuilds the titlebar it hands out *fresh* buttons at
    /// `alphaValue == 1`, so every install and re-attach path has to push the
    /// current state onto them again - otherwise the colored circles would pop back
    /// in and stay.
    func reassertState() {
        resolveHoverFromPointer()
        applyState(animated: false)
    }

    /// Restores the buttons to their native, fully visible state.
    ///
    /// Called before this overlay is discarded, so a replaced overlay cannot leave
    /// the buttons it used to own invisible.
    func restoreButtons() {
        buttons.forEach { $0.alphaValue = 1 }
    }

    /// Derives `isHovered` from where the pointer currently is, because a freshly
    /// created tracking area never reports a pointer that is already inside it
    private func resolveHoverFromPointer() {
        guard let window = self.window, window.isVisible else { return }

        let pointInView = convert(
            window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = bounds.contains(pointInView)
    }

    /// Applies the current hover and suppression state to both representations.
    ///
    /// The rings and the native buttons are exact opposites of each other, so this
    /// is a cross fade: whatever fades out, the other fades in over the same
    /// duration, which keeps the two circles visually locked together.
    /// - Parameter animated: Whether the change should be cross faded
    private func applyState(animated: Bool) {
        let showsNative = revealsNativeButtons
        let ringOpacity: Float = showsNative ? 0.0 : 1.0
        let buttonAlpha: CGFloat = showsNative ? 1.0 : 0.0

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(Self.hoverAnimationDuration)
        }
        ringLayer.opacity = ringOpacity
        CATransaction.commit()

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.hoverAnimationDuration
                buttons.forEach { $0.animator().alphaValue = buttonAlpha }
            }
        } else {
            buttons.forEach { $0.alphaValue = buttonAlpha }
        }
    }
}

/// Custom titlebar accessory controller that creates a full-width interactive area
/// in the window's titlebar. This prevents window dragging in specific regions while
/// maintaining a clean, invisible appearance. We need this because Flutter UI elements
/// are placed in the toolbar area and the native window dragging would interfere with
/// their interaction. Window dragging is instead handled by the Flutter application itself.
class TitlebarAccessoryController: NSTitlebarAccessoryViewController {
    override func loadView() {
        self.view = DragInterceptorView(frame: .zero)
    }
}

class DragInterceptorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        return false
    }

    override var mouseDownCanMoveWindow: Bool {
        return false
    }
}

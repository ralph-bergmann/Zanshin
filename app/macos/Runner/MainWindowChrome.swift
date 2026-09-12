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
final class MainWindowChrome {
    private weak var window: NSWindow?

    /// Click-through overlay that paints the neutral resting state of the window
    /// control buttons (close, minimize, zoom). Kept as a strong reference so the
    /// overlay can be re-attached whenever AppKit rebuilds the titlebar.
    private var trafficLightOverlay: TrafficLightOverlayView?

    /// The translucent background behind the Flutter view. Kept so a titlebar
    /// rebuild can re-stack the same view instead of piling up new ones.
    private var vibrancyView: NSVisualEffectView?

    init(window: NSWindow) {
        self.window = window

        setupWindowAppearance()
        installVibrancyView()
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

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.minSize = NSSize(width: 900, height: 600)

        // The WindowFrameStore below is the single owner of the window
        // geometry. AppKit's own state restoration would restore its stale frame
        // asynchronously ~300ms after launch, silently overriding both the saved
        // frame and the first-launch default.
        window.isRestorable = false

        // Add toolbar with custom invisible item to prevent window dragging
        let toolbar = NSToolbar(identifier: "Toolbar")
        let accessoryController = TitlebarAccessoryController()
        accessoryController.layoutAttribute = .top
        window.addTitlebarAccessoryViewController(accessoryController)

        window.toolbar = toolbar
    }

    /// Creates - or re-stacks - the translucent background the app paints on.
    ///
    /// Before the windowing API this view was the window's own content view: a
    /// `WrapperViewController` owned the `NSVisualEffectView` and carried the
    /// Flutter view as its subview. The engine owns the `contentViewController`
    /// of a window it created itself, so the effect view becomes a *sibling*
    /// instead - inserted into the frame view directly below the content view.
    /// The Flutter view therefore still draws on top and unclipped, and shows
    /// the blur wherever it paints transparent, which is what the clear window
    /// background above is for.
    ///
    /// It has to be an `EventTransparentEffectView`, not a plain
    /// `NSVisualEffectView`: a view stacked below the content view is where
    /// AppKit forwards the content view's unhandled mouse events to, ahead of
    /// the content view controller - see that class for the full story.
    private func installVibrancyView() {
        guard let window = self.window,
            let contentView = window.contentView,
            let host = contentView.superview
        else { return }

        let effectView = vibrancyView ?? EventTransparentEffectView()
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 20.0
        if effectView.superview !== host {
            host.addSubview(effectView, positioned: .below, relativeTo: contentView)
        }
        effectView.frame = host.bounds
        vibrancyView = effectView

        // The Flutter view has to be see-through for any of this to show.
        (window.contentViewController as? FlutterViewController)?.backgroundColor = .clear
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
        installVibrancyView()
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
        installVibrancyView()
        installTrafficLightOverlay()
        trafficLightOverlay?.setSuppressed(false)
    }

    // Window resize event handler
    @objc private func handleWindowDidResize(_ notification: Notification) {
        trafficLightOverlay?.syncGeometry()
    }
}

/// Click-through overlay that paints the resting state of the three standard window
/// buttons (close, minimize, zoom): a plain gray ring with a fully transparent
/// interior, so whatever the window paints underneath shows through it.
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
/// palette clashed with it. A transparent interior sidesteps the problem entirely,
/// which is also why this class carries no theme handling at all any more - a gray
/// stroke reads correctly on any background.
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
        // shows through. Gray works on top of any of them.
        ringLayer.lineWidth = Self.ringLineWidth
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.gray.cgColor

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

/// The vibrancy background behind the Flutter view, invisible to hit-testing.
///
/// AppKit's default mouse-event forwarding - `NSResponder`'s `mouseDown(with:)`
/// and its siblings - does not hand an event the content view left unhandled
/// straight to the content view's next responder. It first hit-tests for a
/// view stacked *beneath* the content view and, when it finds one, forwards
/// the event to that view instead. Flutter's content view (the engine's
/// `FlutterViewWrapper`) leaves every mouse event unhandled on purpose: its
/// `FlutterViewController`, the next responder, is what turns them into
/// pointer events. A plain `NSVisualEffectView` below the content view was
/// therefore where every click ended up; it passed the event up its own chain
/// (theme frame, window) and the Flutter side never saw a single pointer
/// event - no button, no checkbox, nothing reacted.
///
/// Returning `nil` from `hitTest(_:)` takes this view out of that lookup, so
/// the forwarding falls back to the next responder and the click reaches the
/// `FlutterViewController` again. Hit-testing is all the blur needs to opt
/// out of: it never handles events itself.
///
/// Verified with an in-process `sendEvent` probe (macOS 26, 2026-09-12): with
/// the plain view the responder hops were wrapper -> effect view -> theme
/// frame -> window; with this view they are wrapper -> view controller ->
/// engine -> Dart.
final class EventTransparentEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

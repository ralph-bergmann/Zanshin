import Cocoa
import FlutterMacOS

let bundleId = Bundle.main.bundleIdentifier!
let defaults = UserDefaults(suiteName: "\(bundleId).app_position")!

/// Represents the complete state of a window and its display configuration
/// Used for persisting and restoring window positions across app launches
struct WindowState: Codable {
    /// The app window's position in screen coordinates
    let position: CGPoint

    /// The app window's dimensions
    let size: CGSize

    /// Unique identifier of the display where the window was located
    /// This ID persists across system restarts for the same physical display
    let displayId: CGDirectDisplayID

    /// The display's position in the global coordinate space
    /// Example: (-2560, 0) means the display is positioned to the left of the main display
    let displayOffset: CGPoint

    /// The physical dimensions of the display
    /// Used to detect display changes even when coordinates remain the same
    let displaySize: CGSize
}

class MainFlutterWindow: NSWindow {
    /// Click-through overlay that paints the neutral resting state of the window
    /// control buttons (close, minimize, zoom). Kept as a strong reference so the
    /// overlay can be re-attached whenever AppKit rebuilds the titlebar.
    private var trafficLightOverlay: TrafficLightOverlayView?

    override func awakeFromNib() {
        super.awakeFromNib()

        setupFlutterViewController()
        // Appearance first: the frame must be applied under the final style mask.
        // With `.fullSizeContentView` the frame equals the content size; applying a
        // saved frame while the titlebar still occupies its own strip would shave
        // the titlebar height off the window on every launch.
        setupWindowAppearance()
        saveAndRestoreWindowFrame()
        setupWindowButtons()
    }

    /// Removes the notification observers when the window is deallocated
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Sets up the main Flutter view controller and initializes Flutter plugins.
    /// The FlutterViewController is wrapped in a custom view controller to provide a translucent background.
    private func setupFlutterViewController() {
        // Create the main Flutter view controller that hosts the Flutter content
        let flutterViewController = FlutterViewController()

        // Create a wrapper view controller that provides a translucent background
        let wrapperViewController = WrapperViewController(
            flutterViewController: flutterViewController)
        self.contentViewController = wrapperViewController

        // Initialize Flutter plugins
        RegisterGeneratedPlugins(registry: flutterViewController)
    }

    /// Saves and restores the window frame based on the saved window state
    private func saveAndRestoreWindowFrame() {
        // Attempt to restore previous window position and size
        let windowState = loadWindowState()
        let frameToUse =
            windowState.map { NSRect(origin: $0.position, size: $0.size) }
            ?? defaultFrame()

        self.setFrame(frameToUse, display: true)

        // Set up window position tracking
        // These observers will save window state whenever it moves or resizes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: self
        )
    }

    /// Add a toolbar to move the window control buttons (close, minimize, zoom) a little bit down.
    /// Without this, the buttons would appear too close to the top border. The toolbar contains
    /// a custom invisible item that prevents window dragging in the titlebar area, as this
    /// functionality is handled by Flutter instead. This is necessary because Flutter UI elements
    /// in the toolbar area need to receive mouse events without interference from the native
    /// window dragging behavior.
    private func setupWindowAppearance() {
        self.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.minSize = NSSize(width: 900, height: 600)

        // The WindowState mechanism below is the single owner of the window
        // geometry. AppKit's own state restoration would restore its stale frame
        // asynchronously ~300ms after launch, silently overriding both the saved
        // WindowState and the first-launch default frame.
        self.isRestorable = false

        // Add toolbar with custom invisible item to prevent window dragging
        let toolbar = NSToolbar(identifier: "Toolbar")
        let accessoryController = TitlebarAccessoryController()
        accessoryController.layoutAttribute = .top
        self.addTitlebarAccessoryViewController(accessoryController)

        self.toolbar = toolbar
    }

    /// Installs the neutral overlay on top of the window control buttons
    /// (close, minimize, zoom) and registers the window notifications that keep
    /// the overlay attached and correctly positioned.
    private func setupWindowButtons() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowWillEnterFullScreen),
            name: NSWindow.willEnterFullScreenNotification,
            object: self
        )
        center.addObserver(
            self,
            selector: #selector(handleWindowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: self
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
        let buttons = [
            self.standardWindowButton(.closeButton),
            self.standardWindowButton(.miniaturizeButton),
            self.standardWindowButton(.zoomButton),
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
        overlay.setSuppressed(self.styleMask.contains(.fullScreen))
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

    /// Saves the current window position, size, and display configuration
    /// Called automatically when window moves or resizes
    ///
    /// Always reads from `self`. `NSApplication.shared.mainWindow` may point at a
    /// different window - or at no window at all - by the time this is called, which
    /// used to persist a foreign frame or silently skip the save.
    private func saveWindowState() {
        guard let screen = self.screen else {
            return
        }

        let state = WindowState(
            position: self.frame.origin,
            size: self.frame.size,
            displayId: screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID,
            displayOffset: screen.frame.origin,
            displaySize: screen.frame.size
        )

        if let encoded = try? JSONEncoder().encode(state) {
            defaults.set(encoded, forKey: "WindowState")
        }
    }

    /// Attempts to restore the window state from previous session
    /// Uses multiple fallback strategies to handle different display configurations
    private func loadWindowState() -> WindowState? {
        guard let data = defaults.data(forKey: "WindowState"),
            let state = try? JSONDecoder().decode(WindowState.self, from: data)
        else {
            return nil
        }

        // Strategy 1: Look for exact display match (position and size)
        if NSScreen.screens.contains(where: { screen in
            screen.frame.origin == state.displayOffset
                && screen.frame.size == state.displaySize
        }) {
            return state
        }

        // Strategy 2: Match display ID and X coordinate
        // Useful when display is moved up or down but not left or right
        if NSScreen.screens.contains(where: { screen in
            let screenId =
                screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")]
                as! CGDirectDisplayID
            return screenId == state.displayId
                && screen.frame.origin.x == state.displayOffset.x
        }) {
            return state
        }

        // Strategy 3: No matching display found, use default window frame
        return nil
    }

    /// Window size used when no usable window state has been saved yet
    private static let defaultWindowSize = NSSize(width: 1280, height: 800)

    /// The fallback frame for the first launch (or when no saved display matches):
    /// the default size, centered on the primary screen - the one carrying the
    /// menu bar at the global origin, which `NSScreen.screens` lists first.
    ///
    /// `self.frame` cannot serve as this fallback: attaching the content view
    /// controller has already collapsed the window to the wrapper view's zero
    /// frame by the time this runs, so restoring it would show a sliver of a
    /// window - and persist that sliver on the next move or resize.
    private func defaultFrame() -> NSRect {
        guard let screen = NSScreen.screens.first else {
            return NSRect(origin: self.frame.origin, size: Self.defaultWindowSize)
        }

        // `visibleFrame` excludes the menu bar and the Dock, so the window is
        // centered in - and fits inside - the actually usable area.
        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(Self.defaultWindowSize.width, visible.width),
            height: min(Self.defaultWindowSize.height, visible.height)
        )
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size)
    }

    // Window movement event handler
    @objc func windowDidMove(_ notification: Notification) {
        saveWindowState()
    }

    // Window resize event handler
    @objc func windowDidResize(_ notification: Notification) {
        saveWindowState()
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

/// Wrapper view controller that provides a translucent background effect
/// and hosts the Flutter view controller
class WrapperViewController: NSViewController {
    private var _flutterViewController: FlutterViewController? = nil
    public var flutterViewController: FlutterViewController {
        return _flutterViewController!
    }

    public init(flutterViewController: FlutterViewController? = nil) {
        self._flutterViewController =
            flutterViewController ?? FlutterViewController()

        super.init(nibName: nil, bundle: nil)
    }

    required public init?(coder: NSCoder) {
        fatalError()
    }

    override public func loadView() {
        let newVisualEffectView = NSVisualEffectView()
        newVisualEffectView.autoresizingMask = [.width, .height]
        newVisualEffectView.blendingMode = .behindWindow
        newVisualEffectView.state = .active
        newVisualEffectView.wantsLayer = true
//        newVisualEffectView.layer?.borderWidth = 2.0
//        newVisualEffectView.layer?.borderColor = NSColor(red: 24 / 255, green: 23 / 255, blue: 36 / 255, alpha: 1.0).cgColor
        newVisualEffectView.layer?.cornerRadius = 20.0
        self.view = newVisualEffectView
    }

    /// Sets up the Flutter view controller within the wrapper
    override public func viewDidLoad() {
        super.viewDidLoad()

        self.addChild(flutterViewController)

        flutterViewController.view.frame = self.view.bounds
        flutterViewController.view.autoresizingMask = [.width, .height]
        flutterViewController.backgroundColor = .clear

        self.view.addSubview(flutterViewController.view)
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
        // self.wantsLayer = true
        // self.layer?.backgroundColor = NSColor.blue.cgColor
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

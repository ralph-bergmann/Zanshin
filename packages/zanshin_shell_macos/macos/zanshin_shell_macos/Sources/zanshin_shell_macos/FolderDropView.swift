// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// An invisible layer over a Flutter view that receives folder drags from
/// other apps and reports them to Dart over the `zanshin_shell/folder_drop`
/// channel; Dart decides with its own hit test whether a drop would land.
///
/// Mouse events never stop here: `hitTest(_:)` returns `nil`, so clicks,
/// scrolling and cursor updates keep reaching the Flutter view. AppKit finds
/// drag destinations with a separate hit test (`_hitTest:dragTypes:`) that
/// does not consult that override, which is what makes an invisible drop
/// layer possible.
///
/// Dart answers asynchronously, AppKit asks synchronously: the view keeps
/// Dart's last answer and returns the matching operation. At most one position
/// is on its way to Dart at a time; a newer one replaces the pending one.
final class FolderDropView: NSView {
    /// One drag carrying folders over this view.
    private final class Session {
        let generation: Int
        let paths: [String]
        /// Dart's last answer: a drop at the last reported position would be accepted.
        var accepted = false
        /// A position was sent to Dart and is not answered yet.
        var inFlight = false
        /// The latest position that arrived while another one was in flight.
        var pending: NSPoint?

        init(generation: Int, paths: [String]) {
            self.generation = generation
            self.paths = paths
        }
    }

    private let viewId: FlutterViewIdentifier
    private let channel: FlutterMethodChannel
    private var session: Session?
    /// Counts drags, so a late answer from an earlier drag is recognised.
    private var generation = 0

    init(viewId: FlutterViewIdentifier, channel: FlutterMethodChannel) {
        self.viewId = viewId
        self.channel = channel
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Event transparency

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override var acceptsFirstResponder: Bool {
        return false
    }

    /// A transparent view would otherwise count as window-drag area in the
    /// full-size titlebar strip - the reason `DragInterceptorView` in the
    /// runner says the same.
    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    /// Top-left origin like the Flutter view it covers, so its points are
    /// Flutter's logical pixels.
    override var isFlipped: Bool {
        return true
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let paths = FolderPasteboard.folderPaths(on: sender.draggingPasteboard)
        guard !paths.isEmpty else {
            session = nil
            return []
        }
        generation += 1
        session = Session(generation: generation, paths: paths)
        send("dragEntered", at: location(of: sender), paths: paths)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let session = session else { return [] }
        if session.inFlight {
            session.pending = location(of: sender)
        } else {
            send("dragUpdated", at: location(of: sender))
        }
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endSession()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let session = session else { return false }
        self.session = nil
        channel.invokeMethod("dropped", arguments: arguments(at: location(of: sender), paths: session.paths))
        return true
    }

    /// A refused or cancelled drop does not always come with
    /// `draggingExited`; ending the session here keeps Dart from holding on
    /// to a hover state.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        endSession()
    }

    // MARK: - Session

    private func endSession() {
        guard session != nil else { return }
        session = nil
        channel.invokeMethod("dragExited", arguments: ["viewId": viewId])
    }

    /// Sends a position to Dart and stores the answer for the drag it belongs
    /// to, then sends the position that arrived meanwhile, if any.
    private func send(_ method: String, at point: NSPoint, paths: [String]? = nil) {
        guard let current = session else { return }
        current.inFlight = true
        channel.invokeMethod(method, arguments: arguments(at: point, paths: paths)) { [weak self] reply in
            guard let self = self, let session = self.session, session.generation == current.generation else {
                return
            }
            // No Dart handler (FlutterMethodNotImplemented) or an error reply is a rejection.
            session.accepted = reply as? Bool ?? false
            session.inFlight = false
            if let pending = session.pending {
                session.pending = nil
                self.send("dragUpdated", at: pending)
            }
        }
    }

    private func arguments(at point: NSPoint, paths: [String]?) -> [String: Any] {
        var arguments: [String: Any] = ["viewId": viewId, "x": Double(point.x), "y": Double(point.y)]
        if let paths = paths {
            arguments["paths"] = paths
        }
        return arguments
    }

    private func location(of sender: NSDraggingInfo) -> NSPoint {
        return convert(sender.draggingLocation, from: nil)
    }

    /// The operation for Dart's last answer, within what the drag source
    /// allows: copy, else link, else generic.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard session?.accepted == true else { return [] }
        let allowed = sender.draggingSourceOperationMask
        for candidate: NSDragOperation in [.copy, .link, .generic] where allowed.contains(candidate) {
            return candidate
        }
        return []
    }
}

// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Native half of the `zanshin_shell/folder_drop` channel: puts a
/// `FolderDropView` on each Flutter view Dart enables folder drops for.
///
/// Dart names a view by its `FlutterViewController.viewIdentifier`. Every
/// Flutter view of the app is the content view controller of a window the
/// engine created for Dart, so the host looks it up among the app's windows
/// instead of tracking windows itself. The drop view goes on top of the
/// controller's view - the engine's `FlutterViewWrapper`, which reports only
/// the Flutter view to accessibility, so the extra subview changes nothing
/// there.
final class FolderDropHost {
    /// A drop view the host does not keep alive: it lives as long as its window.
    private struct WeakDropView {
        weak var view: FolderDropView?
    }

    private let channel: FlutterMethodChannel
    private let messenger: FlutterBinaryMessenger
    private var dropViews: [FlutterViewIdentifier: WeakDropView] = [:]

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        channel = FlutterMethodChannel(name: "zanshin_shell/folder_drop", binaryMessenger: messenger)
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
        case "attach":
            guard let controller = flutterViewController(id, messenger: messenger) else {
                result(FlutterError(code: "unknown-view", message: "no Flutter view with id \(viewId)", details: nil))
                return
            }
            attach(to: controller, id: id)
            result(nil)
        case "detach":
            dropViews.removeValue(forKey: id)?.view?.removeFromSuperview()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Puts a drop view on top of the controller's view; idempotent.
    private func attach(to controller: FlutterViewController, id: FlutterViewIdentifier) {
        if let existing = dropViews[id]?.view, existing.superview === controller.view {
            return
        }
        dropViews = dropViews.filter { $0.value.view != nil }
        let dropView = FolderDropView(viewId: id, channel: channel)
        dropView.frame = controller.view.bounds
        dropView.autoresizingMask = [.width, .height]
        controller.view.addSubview(dropView)
        dropViews[id] = WeakDropView(view: dropView)
    }
}

// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// The attached view controller with the given id of the engine behind `messenger`.
///
/// Dart names a view by its `FlutterViewController.viewIdentifier`. Every Flutter view of the app is the content
/// view controller of a window the engine created for Dart, so the per-view hosts look it up among the app's windows
/// instead of tracking windows themselves.
func flutterViewController(_ id: FlutterViewIdentifier, messenger: FlutterBinaryMessenger) -> FlutterViewController? {
    let ownMessenger = messenger as AnyObject
    return NSApp.windows.lazy
        .compactMap { $0.contentViewController as? FlutterViewController }
        .first { controller in
            // Reading `viewIdentifier` of a detached controller asserts.
            controller.attached() && controller.viewIdentifier == id
                && (controller.engine.binaryMessenger as AnyObject) === ownMessenger
        }
}

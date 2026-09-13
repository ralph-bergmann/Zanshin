// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'folder_drop_dispatcher.dart';

/// A folder drag over a [FolderDropTarget].
@immutable
class FolderDragDetails {
  const FolderDragDetails({required this.paths, required this.localPosition, required this.globalPosition});

  /// The absolute paths of the dragged folders; never empty.
  final List<String> paths;

  /// The pointer position in the target's coordinate space.
  final Offset localPosition;

  /// The pointer position in the view's logical pixels.
  final Offset globalPosition;
}

/// Accepts folders dragged in from other apps, such as Finder (macOS).
///
/// The target is the innermost [FolderDropTarget] under the pointer, found
/// with the framework's own hit test: clipping, transforms and widgets painted
/// on top all count. A target covers its whole box but never keeps pointer
/// events from reaching anything else. When the innermost target rejects a
/// drop, outer targets are not asked.
///
/// Every visit of a target — from its first [onDragUpdate] until the drag
/// leaves it — ends with exactly one [onDragExit] or [onDrop]. Keep hover
/// styling in these callbacks rather than in a `MouseRegion`.
class FolderDropTarget extends StatefulWidget {
  const FolderDropTarget({required this.onDrop, required this.child, this.onDragUpdate, this.onDragExit, super.key});

  /// Called on enter and on every update while the drag is over this target.
  ///
  /// Returns whether a drop at [FolderDragDetails.localPosition] would be
  /// accepted, which drives the platform's drop feedback. When null, the
  /// target accepts everywhere.
  final bool Function(FolderDragDetails details)? onDragUpdate;

  /// Called when the drag leaves this target without dropping on it: it moved
  /// to another target, left the window, or was cancelled.
  final VoidCallback? onDragExit;

  /// Called when folders are dropped on this target at a position
  /// [onDragUpdate] accepted.
  final ValueChanged<FolderDragDetails> onDrop;

  /// The widget below this widget in the tree.
  final Widget child;

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  /// The view this target is registered in.
  int? _viewId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final int viewId = View.of(context).viewId;
    if (viewId == _viewId) {
      return;
    }
    if (_viewId case final int previous) {
      FolderDropDispatcher.instance.release(previous);
    }
    FolderDropDispatcher.instance.retain(viewId);
    _viewId = viewId;
  }

  @override
  void dispose() {
    if (_viewId case final int viewId) {
      FolderDropDispatcher.instance.release(viewId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FolderDropRegion(target: widget, child: widget.child);
}

class _FolderDropRegion extends SingleChildRenderObjectWidget {
  const _FolderDropRegion({required this.target, required super.child});

  final FolderDropTarget target;

  @override
  RenderFolderDropTarget createRenderObject(BuildContext context) => RenderFolderDropTarget(target);

  @override
  void updateRenderObject(BuildContext context, RenderFolderDropTarget renderObject) => renderObject.widget = target;
}

/// The render object of a [FolderDropTarget]; the dispatcher looks for it in
/// the hit test path.
///
/// Hit-tests translucently: it is in the path wherever its box is, without
/// keeping hit testing from reaching what lies behind it.
class RenderFolderDropTarget extends RenderProxyBoxWithHitTestBehavior {
  RenderFolderDropTarget(this.widget) : super(behavior: HitTestBehavior.translucent);

  /// The widget whose callbacks answer for this render object.
  FolderDropTarget widget;

  @override
  void dispose() {
    FolderDropDispatcher.instance.forget(this);
    super.dispose();
  }
}

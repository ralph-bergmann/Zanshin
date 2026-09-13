// SPDX-License-Identifier: MIT

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show immutable;

/// One step of a folder drag over a Flutter view, as the platform reports it.
///
/// A drag over a view is a [FolderDragEntered], any number of
/// [FolderDragUpdated]s, and then a [FolderDragExited] or a [FolderDropped].
/// The platform only reports drags that carry at least one folder.
@immutable
sealed class FolderDragEvent {
  const FolderDragEvent({required this.viewId});

  /// The Flutter view the drag is over (`FlutterView.viewId`).
  final int viewId;
}

/// A drag carrying folders entered the view.
final class FolderDragEntered extends FolderDragEvent {
  const FolderDragEntered({required super.viewId, required this.position, required this.paths});

  /// The pointer position in the view's logical pixels.
  final Offset position;

  /// The absolute paths of the dragged folders; never empty.
  final List<String> paths;
}

/// The drag moved over the view.
final class FolderDragUpdated extends FolderDragEvent {
  const FolderDragUpdated({required super.viewId, required this.position});

  /// The pointer position in the view's logical pixels.
  final Offset position;
}

/// The drag left the view, or ended without dropping on it.
final class FolderDragExited extends FolderDragEvent {
  const FolderDragExited({required super.viewId});
}

/// The folders were dropped on the view.
final class FolderDropped extends FolderDragEvent {
  const FolderDropped({required super.viewId, required this.position, required this.paths});

  /// The drop position in the view's logical pixels.
  final Offset position;

  /// The absolute paths of the dropped folders; never empty.
  final List<String> paths;
}

/// Answers a [FolderDragEvent]: whether a drop at the event's position would
/// be accepted. The answer drives the platform's drag feedback; it is ignored
/// for [FolderDragExited].
typedef FolderDragHandler = bool Function(FolderDragEvent event);

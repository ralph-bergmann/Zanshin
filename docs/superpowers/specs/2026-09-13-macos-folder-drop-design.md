# macOS folder drops — design

**Status:** POC implemented and verified 2026-09-14; plugin code production-ready.
**POC entrypoint:** `app/lib/main3.dart` (`flutter run -d macos -t lib/main3.dart` from `app/`).
**Reusable code:** the `zanshin_shell` plugin family, written to production standard so the
project overview can adopt it unchanged.

## Goal

Let the user drag project folders from Finder into the project overview and drop them at a
precise spot of a `TreeSliver`: before a row, into a group, or after a row. Only folders
matter; files are ignored. It has to work in every window of the view-less windowing runner
(see `2026-09-11-windowing-splash-poc-design.md`).

## Background and findings

- **The blog post** ("Solving Drag and Drop in Flutter macOS", greenrobot, 2025-11-23)
  contributes one idea: a native drop view whose `hitTest(_:)` returns `nil` stays invisible
  to clicks and scrolling but still receives drags. It shows no complete code, and its
  `flutter_macos_drag` plugin was never published. Its implementation puts an `AppKitView`
  (a platform view at `Opacity(0.01)`) into every drop zone.
- **AppKit backs the idea.** The drag destination lookup is a hit test of its own: the
  Objective-C runtime on macOS 26 lists `-[NSView _hitTest:dragTypes:]` and
  `-[NSView _treeHasDragTypes]` next to the public `hitTest:`.
- **Existing packages do not fit.** `desktop_drop` installs its overlay on `registrar.view`,
  which is `nil` for our view-less engine (see `ZanshinShellPlugin.window`), so it silently
  installs nothing; its events carry no view id, and its overlay does not override `hitTest`.
  `super_drag_and_drop` brings its own Rust/cargokit toolchain, and the blog reports gesture
  conflicts with it.
- **Engine facts** (installed SDK, master 3.48.0-1.0.pre):
  - `FlutterViewController.view` is the engine's `FlutterViewWrapper`. It already hosts
    foreign subviews (the text input plugin, which keeps a 0×0 frame) and reports only the
    `FlutterView` as its accessibility child, so one more subview leaves the accessibility
    tree alone.
  - `FlutterView.isFlipped` is `YES`; its points are Flutter's logical pixels.
  - `FlutterViewController.viewIdentifier` and `.engine` are public. The registrar's
    `messenger` is the engine's `binaryMessenger` object, so `vc.engine.binaryMessenger ===
    registrar.messenger` identifies the plugin's own engine.
- **Framework facts:** `WidgetsBinding.hitTestInView` is public. `TreeSliver.didUpdateWidget`
  re-unpacks the tree on every rebuild, so editing `TreeSliverNode.children` in place plus
  `setState` is enough. `TreeSliverNode`'s constructor ignores `expanded: true` without
  children, and `toggleNode` does nothing for a childless node, so a group that just received
  its first child has to be expanded explicitly.
- **Foundation facts** (checked with fixtures): `URL(resolvingAliasFileAt:)` resolves Finder
  aliases *and* symlinks (a symlink reports `isAliasFile == true`) and throws for a broken
  one; a directory named `Some.app` reports `isDirectory && isPackage`.
- **No sandbox** (both entitlement files): dropped paths are usable directly, no
  security-scoped bookmarks needed.

## Decisions

| Topic | Decision |
|---|---|
| Approach | One native drop overlay per Flutter view; Flutter's own hit test picks the target. No platform views, no package fork. |
| Location | Federated `zanshin_shell` plugin: Swift in `zanshin_shell_macos`, transport API in `zanshin_shell_platform_interface`, widget in `zanshin_shell`. |
| Tree semantics | Row targets with a placement: before, inside (groups only), after. |
| Accepted items | Directories only. Finder aliases and symlinks are resolved and the resolved path is delivered. Packages (`.app`, `.xcodeproj`, …) are rejected, since Finder treats them as files. A mixed drag delivers only its folders; a drag without folders is ignored. |
| Enabling | Per view, only while at least one `FolderDropTarget` is mounted in it. |
| Target resolution | The innermost `FolderDropTarget` under the cursor; no bubbling to outer targets. |
| Session end | Every visit of a target — from its first `onDragUpdate` until the drag leaves it — ends with exactly one `onDragExit` or `onDrop`. |
| Tree logic | Extracted into `app/lib/src/features/projects/tree_drop.dart` with unit tests; `main3.dart` holds only boot, windows and UI. |

## Architecture

```
Finder drag
  ▼
FolderDropView   Swift; one per Flutter view, topmost subview of FlutterViewWrapper, hitTest → nil
  │  reads the folders from the drag pasteboard
  │  channel zanshin_shell/folder_drop: viewId, position (logical px), paths
  ▼
ZanshinShellMacOS   Dart; transport only
  ▼
FolderDropDispatcher   zanshin_shell, internal
  │  WidgetsBinding.hitTestInView(result, position, viewId) → innermost RenderFolderDropTarget
  ▼
FolderDropTarget callbacks: onDragUpdate → bool, onDragExit, onDrop
  │  the bool is the channel reply → cached natively → drag operation badge
```

## Native side (`zanshin_shell_macos`)

New Swift source(s) next to `ZanshinShellPlugin.swift`. The plugin instance creates and owns
the host in `register(with:)`.

### `FolderDropHost`

- Owns the method channel `zanshin_shell/folder_drop`.
- `attach {viewId}` finds, among `NSApp.windows`, the window whose `contentViewController` is a
  `FlutterViewController` with that `viewIdentifier` and this plugin's engine, then adds a
  `FolderDropView` as the topmost subview of the controller's `view`, sized to its bounds
  with `autoresizingMask = [.width, .height]`. Idempotent. No such view →
  `FlutterError(code: "unknown-view")`.
- `detach {viewId}` removes that view; an unknown view is a successful no-op.
- Malformed arguments → `FlutterError(code: "bad-args")`, as in `SplashWindowHost`.
- Holds the drop views weakly: a closed window takes its drop view with it.

### `FolderDropView`

- `hitTest(_:)` returns `nil`: clicks, scrolling and cursor updates keep reaching the
  `FlutterView`, including the first click into an inactive window.
- `mouseDownCanMoveWindow` returns `false`: a transparent view would otherwise count as
  window-drag area in the full-size titlebar strip (the reason `DragInterceptorView` sets it).
- `isFlipped` returns `true`, and the frame equals the `FlutterView`'s, so
  `convert(sender.draggingLocation, from: nil)` yields Flutter logical pixels.
- `registerForDraggedTypes([.fileURL])`.
- **Reading the folders** (once, on enter): `readObjects(forClasses: [NSURL.self], options:
  [.urlReadingFileURLsOnly: true])`, then per URL `URL(resolvingAliasFileAt:)` (an item that
  fails to resolve is skipped), then keep it if `isDirectory && !isPackage`, and deliver its
  `path`. No folder left → the view ignores the whole session and answers `[]`.
- **Session state:** a generation number, the paths, the last answer (`accepted`, initially
  `false`), one request in flight, and the latest pending position.
  - `draggingEntered` sends `dragEntered`; `draggingUpdated` sends `dragUpdated`. While a
    request is in flight, a newer position replaces the pending one (latest wins); each reply
    sends the pending position, if there is one.
  - A reply updates `accepted`. A reply that is not a `Bool` — no Dart handler
    (`FlutterMethodNotImplemented`) or a `FlutterError` — counts as `false`. Replies from an
    older generation are dropped.
  - Both methods return the operation for the cached answer: `.copy` if the source's operation
    mask allows it, else `.link`, else `.generic`; `[]` when not accepted or when none of those
    is allowed.
  - `draggingExited` sends `dragExited` and ends the session.
  - `prepareForDragOperation` returns `true` only when the cached answer is accepted and the
    operation is not empty.
  - `performDragOperation` sends `dropped`, ends the session and returns `true`.
  - `draggingEnded`: if a session is still open (a refused or cancelled drop), it sends
    `dragExited` and ends the session, so no hover state is left behind in Dart.

### Channel protocol

| Direction | Method | Arguments | Reply |
|---|---|---|---|
| Dart → native | `attach` | `viewId` | `null`, or error `unknown-view` / `bad-args` |
| Dart → native | `detach` | `viewId` | `null`, or error `bad-args` |
| native → Dart | `dragEntered` | `viewId`, `x`, `y`, `paths` | `bool`: a drop here would be accepted |
| native → Dart | `dragUpdated` | `viewId`, `x`, `y` | `bool`: a drop here would be accepted |
| native → Dart | `dragExited` | `viewId` | ignored |
| native → Dart | `dropped` | `viewId`, `x`, `y`, `paths` | `bool`: accepted (informational only) |

`x` and `y` are logical pixels with the origin at the top left of the Flutter view. `paths` is
a list of absolute paths and never empty.

## Dart side

### `zanshin_shell_platform_interface`

New `lib/src/folder_drag_event.dart`, exported from the package:

```dart
@immutable
sealed class FolderDragEvent {
  const FolderDragEvent({required this.viewId});
  final int viewId;
}

final class FolderDragEntered extends FolderDragEvent { /* Offset position; List<String> paths */ }
final class FolderDragUpdated extends FolderDragEvent { /* Offset position */ }
final class FolderDragExited extends FolderDragEvent {}
final class FolderDropped extends FolderDragEvent { /* Offset position; List<String> paths */ }

/// Whether a drop at the event's position would be accepted; ignored for [FolderDragExited].
typedef FolderDragHandler = bool Function(FolderDragEvent event);
```

`ZanshinShellPlatform` gains three members with the usual `throw UnimplementedError()`
defaults. Every existing fake `extends` the class, so they all keep compiling.

```dart
void setFolderDragHandler(FolderDragHandler? handler);
Future<void> enableFolderDrops(int viewId);
Future<void> disableFolderDrops(int viewId);
```

### `zanshin_shell_macos`

- A second channel, `zanshin_shell/folder_drop`.
- `setFolderDragHandler` installs the channel's method-call handler, or removes it for `null`.
  Never in `registerWith`, which runs before `main` without a binding — the same rule the
  theme handler follows.
- The handler decodes the four events, calls the `FolderDragHandler` and returns its `bool`.
  Malformed arguments throw, which becomes an error reply and a rejection on the native side.
- `enableFolderDrops` / `disableFolderDrops` invoke `attach` / `detach`.

### `zanshin_shell`: `FolderDropTarget`

Exported: `FolderDropTarget`, `FolderDragDetails`. Internal: `RenderFolderDropTarget`,
`FolderDropDispatcher`.

```dart
@immutable
class FolderDragDetails {
  final List<String> paths;     // the dragged folders; never empty
  final Offset localPosition;   // in the target's coordinate space
  final Offset globalPosition;  // in the view's logical pixels
}

class FolderDropTarget extends StatefulWidget {
  const FolderDropTarget({
    required this.onDrop,
    required this.child,
    this.onDragUpdate,
    this.onDragExit,
    super.key,
  });

  /// Called on enter and on every update over this target. Returns whether a drop at
  /// `details.localPosition` would be accepted, which drives the cursor badge.
  /// When null, the target accepts everywhere.
  final bool Function(FolderDragDetails details)? onDragUpdate;

  /// The drag left this target without dropping on it: it moved to another target,
  /// left the window, or was cancelled.
  final VoidCallback? onDragExit;

  /// Folders were dropped on this target at a position `onDragUpdate` accepted.
  final ValueChanged<FolderDragDetails> onDrop;

  final Widget child;
}
```

Contract:

- The target is the innermost `RenderFolderDropTarget` in the path of
  `WidgetsBinding.instance.hitTestInView(result, position, viewId)`, so clipping, transforms
  and widgets painted on top all count. The local position comes from the hit-test entry's
  transform. The render object hit-tests like `HitTestBehavior.translucent`: it covers its
  whole box but never keeps pointer hit testing from reaching anything else.
- No bubbling: when the innermost target rejects, outer targets are not asked.
- Moving to another target calls `onDragExit` on the old one, then `onDragUpdate` on the new
  one.
- On a drop, `onDragUpdate` is asked once more at the exact drop position: `true` → `onDrop`,
  `false` → `onDragExit` and a rejected reply.
- Every visit of a target — from its first `onDragUpdate` until the drag leaves it — ends with
  exactly one `onDragExit` or `onDrop`. A drag that returns to a target starts a new visit.
- An exception thrown by a callback is reported through `FlutterError.reportError` and counts
  as a rejection.
- Hover state is the target's own business: Flutter is expected to receive no pointer events
  during a Finder drag (to be confirmed in the POC), so `MouseRegion` cannot provide it.

### `FolderDropDispatcher` (internal)

- A target's state reads `View.of(context).viewId` and retains that view with the dispatcher;
  it releases it when disposed or moved to another view.
- The first retain overall binds `ZanshinShellPlatform.instance` and installs the handler.
  The first retain per view calls `enableFolderDrops`; the last release per view calls
  `disableFolderDrops` and drops that view's session; the last release overall removes the
  handler and unbinds. That keeps it correct across hot restarts and across tests that swap
  the fake platform.
- Enable/disable failures are reported through `FlutterError.reportError` (library
  `zanshin_shell`), never thrown into the widget tree.
- Session per view: the dragged paths (from `dragEntered`) and the current target. Updates for
  a view without a session, and positions without a hit, answer `false` and call nothing.
  `dropped` carries its own paths and is evaluated even without a session.
- A `RenderFolderDropTarget` that is disposed mid-session is forgotten silently — no callbacks
  into a disposed widget.

## Demo: `app/lib/main3.dart`

### Boot and windows

- Shaped like `main2.dart`: `AppWindows` + `WindowManager`, no boot sequence, no DI. Every
  window wears the app chrome and has a `WindowDragArea` header.
- A **New window** button opens another demo window (key `folder-drop-<n>`) with its own tree.
  That checks the routing by view id and that windows opened later get their drop view too.

### Tree

- A `CustomScrollView` holding a `TreeSliver<_Entry>` (row extent 32) and a
  `SliverFillRemaining` below it.
- An `_Entry` is either a group (seeded with "Work", "Private" and an empty "Archive") or a
  project (name = folder name, path shown dimmed). Clicking a group toggles it.
- `indentation: TreeSliverIndentationType.none`; rows indent themselves with padding, so every
  row box spans the full width. With `TreeSliver`'s own indentation, the gutter left of a
  nested row would fall through to the end-of-list target.
- The demo edits the nodes in place and calls `setState`.

### Drop zones

| Pointer over | Zone | Result |
|---|---|---|
| Group row, top quarter | before | Sibling before the group. |
| Group row, middle half | inside | Last child; the group expands afterwards (a previously empty one too). |
| Group row, bottom quarter | after | Sibling after the group — **unless** the group is expanded and has children: then its first child, because the gap below the row visually belongs to the group. |
| Project row, top half | before | Sibling before. |
| Project row, bottom half | after | Sibling after. |
| Empty area below the tree | — | End of the top level (an outer `FolderDropTarget` around the scroll view). |
| Header, status bar | — | No target, so no badge. |

Multiple folders are inserted in drop order. Paths already in the tree are skipped and
reported.

### Indicators and status

- **before / after:** a 2 px accent line on the row edge, indented to the insertion depth,
  with a dot at its start.
- **inside:** the row gets an accent tint.
- **end of list:** the empty area gets a tint and an "add to the end" hint.
- **Status bar:** the live drag state ("2 folders · before 'Zanshin'") and the result of the
  last drop ("added 2 to 'Work' · 1 already listed").

### `app/lib/src/features/projects/tree_drop.dart`

Pure logic, generic over the node content, no widgets:

```dart
enum TreeDropPlacement { before, inside, after }

/// The zone of a row: quarters for rows that can hold children, halves otherwise.
TreeDropPlacement treeDropPlacement({
  required double dy,
  required double rowExtent,
  required bool canHaveChildren,
});

/// Where dropped nodes go.
@immutable
class TreeInsertionPoint<T> {
  final TreeSliverNode<T>? parent; // null = top level
  final int index;
  final int depth; // depth of the inserted nodes; also the indicator's indent
}

TreeInsertionPoint<T> treeInsertionPoint<T>(
  List<TreeSliverNode<T>> roots,
  TreeSliverNode<T> target,
  TreeDropPlacement placement,
);

TreeInsertionPoint<T> treeAppendPoint<T>(List<TreeSliverNode<T>> roots);

void insertTreeNodes<T>(
  List<TreeSliverNode<T>> roots,
  TreeInsertionPoint<T> point,
  List<TreeSliverNode<T>> nodes,
);
```

Zone boundaries: with quarters, `dy < rowExtent / 4` is before, `dy >= rowExtent * 3 / 4` is
after, anything between is inside; with halves, `dy < rowExtent / 2` is before, the rest is
after. With `p` the target's parent, `i` its index among its siblings and `d` its depth:
`before` yields `(p, i, d)`; `after` yields `(p, i + 1, d)`, except for an expanded target with
children, which yields `(target, 0, d + 1)`; `inside` yields
`(target, target.children.length, d + 1)`. `treeAppendPoint` yields `(null, roots.length, 0)`.

It finds the target's parent and depth by walking `roots` itself instead of reading
`TreeSliverNode.parent` / `depth`, which only a mounted `TreeSliver` fills in — so it is
testable without widgets.

## Error handling

| Situation | Behavior |
|---|---|
| `attach` for an unknown view / malformed arguments | `FlutterError` `unknown-view` / `bad-args`; Dart reports it via `FlutterError.reportError`. |
| `detach` for an unknown view | Successful no-op. |
| Drag without any folder | Never reaches Dart; no badge. |
| Reply is not a `Bool` (no handler, error) | Rejected. |
| Reply after the session ended | Dropped (generation check). |
| Refused or cancelled drop | `draggingExited` — or, when AppKit sends none, `draggingEnded` — sends `dragExited`; the target gets `onDragExit`. |
| Window closed | The drop view dies with the window; the host holds it weakly. |
| Hot restart | The engine closes all windows; new windows have new view ids and their targets attach again. Until then, native rejects. |
| Event for a view without targets, or no hit | `false`, no callbacks. |
| Target unmounted mid-drag | Forgotten silently. |
| Callback throws | Reported via `FlutterError.reportError`; counts as a rejection. |

## Testing

All of these run in `cargo make test` (`flutter test` + `dart analyze` + `dart format` per
package).

- **`zanshin_shell_platform_interface`:** the three new default members throw
  `UnimplementedError`.
- **`zanshin_shell_macos`** (channel tests in the style of the existing ones):
  `enableFolderDrops` / `disableFolderDrops` send `attach` / `detach` with the view id; all
  four native events decode into the right `FolderDragEvent` and the handler's `bool` comes
  back in the reply; malformed arguments produce an error reply; `setFolderDragHandler(null)`
  removes the handler.
- **`zanshin_shell`** (widget tests with a recording fake platform):
  - retain/release counting per view (enable once, disable once, handler installed and removed);
  - local and global positions, including under a `Transform`;
  - the innermost target wins, with no bubbling to an outer target;
  - a target change calls exit, then update;
  - exactly one exit or drop; a drop re-asks `onDragUpdate`, and a rejection there yields exit
    instead of drop;
  - a target scrolled out of the viewport is not hit;
  - a target unmounted mid-drag gets no further callbacks;
  - events for another view id do nothing;
  - a failing `enableFolderDrops` is reported.
- **`app/test/features/projects/tree_drop_test.dart`:** zone boundaries for groups (25/50/25)
  and projects (50/50); insertion points for before/inside/after at the top level and nested;
  the expanded-group exception; appending at the end; the insertion depth.
- **Swift:** no automated tests — the gate has no Swift test runner, and the existing plugin
  has none either. The folder filter is checked once against real fixtures (folder, file,
  alias, symlink, broken symlink, `.app`) with a throwaway script; everything else by the
  runtime checks below.
- **Coverage ratchet:** unaffected; there are no Rust changes.

## Runtime verification

1. `cargo make test` passes (run unpiped).
2. `flutter run -d macos -t lib/main3.dart` from `app/`.
3. A real Finder drag: via computer use if access to Finder and the app is granted
   (mouse down, several moves, mouse up; screenshots as evidence). Ralph does the final pass
   either way.
4. Checklist:
   - Clicks, scrolling, group toggling and window dragging work unchanged, including the
     first click into an inactive window.
   - One folder; several folders; files only → no badge; mixed → only the folders.
   - Alias and symlink → resolved paths; `.app` → no badge.
   - Every zone including the expanded-group exception, an empty group, the empty area, and
     header/status bar (no badge).
   - A second window; moving between windows mid-drag; cancelling with Esc.
   - Whether `MouseRegion` reacts during the drag (the assumption from the contract).
   - Drops still work after a hot restart.

## Assumptions the POC has to prove

1. `_hitTest:dragTypes:` finds a view whose `hitTest(_:)` returns `nil` (the blog and the
   selector list say so; only a real drag proves it).
2. The drag lookup reaches the drop view inside the top titlebar strip, although titlebar and
   accessory views are stacked above the content view there. This only matters if a target
   ever sits in that strip; the demo has none.
3. `draggingEnded(_:)` reaches the destination after a refused or cancelled drop.
4. Flutter receives no pointer hover events during a Finder drag.
5. The drop view's frame equals the `FlutterView`'s: both autoresize from the wrapper, and no
   app window is sized to its content.

## POC results

Verified 2026-09-14 by Ralph with real Finder drags against `lib/main3.dart`, using the
checklist from Task 8 of `docs/superpowers/plans/2026-09-13-macos-folder-drop.md`.

| # | Assumption | Result | Evidence |
|---|---|---|---|
| 1 | `_hitTest:dragTypes:` finds a view whose `hitTest(_:)` returns `nil` | confirmed | Rows 2–8: drops land on the rows and zones under the cursor, while clicks, scrolling and window dragging keep working (row 1). |
| 2 | The drag lookup reaches the drop view in the top titlebar strip | not tested | No target sits in the strip; row 9 only shows that the header, which has no target, gives no badge. |
| 3 | `draggingEnded(_:)` reaches the destination after a refused or cancelled drop | confirmed in effect | Rows 9 and 15: no hover state is left behind after a refused drop or Esc. Which AppKit callback delivered the exit was not traced. |
| 4 | Flutter receives no pointer hover events during a Finder drag | refuted | Row 16: the **New window** button did react to hover during a drag, but only sometimes, and its hover state cleared late after the pointer left. Hover events arrive, but unreliably, so drop feedback must come from the `FolderDropTarget` callbacks, never from `MouseRegion`. |
| 5 | The drop view's frame equals the `FlutterView`'s | confirmed | Rows 2–8: the placement follows the row zones under the cursor. |

Rows 1–15 behaved as expected, including a second window (row 14). Row 17 (hot restart) was
not run.

Open question from testing: `main3.dart` skips folders that are already in the tree. That is
demo behavior (the plugin and `tree_drop.dart` deliver every dropped folder), and it was
confusing while testing; whether the project overview keeps it is still open.

## Out of scope

- Spring-loaded expansion while hovering a group, auto-scrolling near the edges, choosing the
  depth by horizontal position.
- Moving or reordering existing tree nodes.
- Files, file promises (`NSFilePromiseReceiver`), dragging items out of the app.
- Asynchronous acceptance, e.g. checking for a jj/Git repository before accepting; that check
  belongs after the drop.
- Persisting the tree and wiring the drop into the real project overview (`HomeDialog`).
- Platforms other than macOS.

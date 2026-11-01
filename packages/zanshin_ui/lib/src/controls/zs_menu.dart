// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import '../materials/zs_menu_material.dart';
import '../materials/zs_surface.dart';
import '../materials/zs_surface_transition.dart';
import 'zs_control.dart';
import 'zs_control_text.dart';
import 'zs_text_rung.dart';
import 'zs_tooltip.dart';

/// One entry of a command menu (DS components/menus/Menu.d.ts).
sealed class ZsMenuEntry {
  const ZsMenuEntry();
}

/// An action row: 28 high, the leading 16 px column (an icon, or the check of a check item), the label, and the right
/// column (the jj [cmd] in mono, a plain-text [shortcut], › for a submenu).
final class ZsMenuItem extends ZsMenuEntry {
  /// A row labelled [label].
  const ZsMenuItem({
    required this.label,
    this.text,
    this.icon,
    this.cmd,
    this.shortcut,
    this.danger = false,
    this.enabled = true,
    this.checked,
    this.radio = false,
    this.mono = false,
    this.strong = false,
    this.dot,
    this.dotLabel,
    this.submenu,
    this.onSelected,
    this.identifier,
    this.tooltip,
  });

  /// The action's name.
  final String label;

  /// What typeahead matches, when it differs from [label].
  final String? text;

  /// A `ZI` glyph in the leading column.
  final String? icon;

  /// The jj command, right column, mono.
  final String? cmd;

  /// A shortcut, right column, plain text ("⌘C").
  final String? shortcut;

  /// Whether the row is destructive: red at rest, a red tint when highlighted.
  final bool danger;

  /// Whether the row can be activated; a disabled row shows at .4 and is skipped.
  final bool enabled;

  /// Makes the row a check item: the check replaces the icon column; null for an action row.
  final bool? checked;

  /// With [checked]: one of many.
  final bool radio;

  /// Whether the label is set in JetBrains Mono (bookmarks, remotes).
  final bool mono;

  /// Whether the label is semibold: the open project in the Project menu (DS components/menus/menus.css:60).
  final bool strong;

  /// A 6 px status dot 8 px after the label (DS components/menus/menus.css:58, :61), or null for none. On the
  /// highlight's solid accent it carries a 1 px `--accent-ink` ring outside it, which the DS's ink list leaves out
  /// (decision 16.42 h).
  final Color? dot;

  /// What the [dot] means; VoiceOver reads it after the label, before the command ("MyApp, uncommitted changes,
  /// feature/new-ui").
  final String? dotLabel;

  /// Nested entries; the row shows › and opens them beside the menu.
  final List<ZsMenuEntry>? submenu;

  /// Runs after the activation blink, once focus is back on the opener.
  final VoidCallback? onSelected;

  /// The row's `Semantics(identifier:)`.
  final String? identifier;

  /// A tooltip the row shows on hover, also while disabled (a disabled row's reason); VoiceOver reads it as the row's
  /// hint.
  final String? tooltip;

  /// Whether the row takes the highlight and activation.
  bool get actionable => enabled;

  String get _match => (text ?? label).toLowerCase();
}

/// A 1 px `--border` hairline, margin 4 6 (DS components/menus/menus.css:33).
final class ZsMenuSeparator extends ZsMenuEntry {
  /// A separator.
  const ZsMenuSeparator();
}

/// A section heading in caps, aligned with the labels (DS components/menus/menus.css:13-14); not actionable.
final class ZsMenuHeader extends ZsMenuEntry {
  /// A heading reading [label].
  const ZsMenuHeader(this.label);

  /// The heading.
  final String label;
}

/// A note in the menu (Epic 10's "Immutable" row): `--fs-id` in `--text-dim`, wrapping, an optional [leading] widget
/// in the rows' 16 px column; not actionable, so keys, typeahead and the highlight pass it by.
final class ZsMenuNote extends ZsMenuEntry {
  /// A note reading [label].
  const ZsMenuNote(this.label, {this.leading});

  /// The text.
  final String label;

  /// A widget in the leading column (a swatch, a glyph).
  final Widget? leading;
}

/// Opens and closes a [ZsMenuAnchor]'s menu.
class ZsMenuController {
  _ZsMenuAnchorState? _anchor;

  /// Whether the menu shows (also while it leaves).
  bool get isOpen => _anchor?._menu.isOpen ?? false;

  /// Opens the menu at [position] in the anchor's coordinates (a context menu at the pointer), or below the anchor.
  /// Focus moves into the menu; the node that had it is the opener.
  void open({Offset? position}) => _anchor?._open(position);

  /// Closes the menu with its exit and returns focus to the opener.
  void close() => _anchor?._close(refocus: true);
}

/// A command menu over its anchor (DS components/menus/Menu.{d.ts,jsx,prompt.md}; menus.css:1-36), on
/// `RawMenuAnchor`, the menu material and the menu's entrance and exit (`ZsSurfaceTransition`, `--dur-menu` in,
/// `--dur-exit` out).
///
/// **Panel.** 250–320 wide, or exactly [width] (the Project menu's 300, DS components/menus/menus.css:57), padding 5,
/// rows 1 apart; a command longer than [cmdMaxWidth] ends in an ellipsis (the Project menu's 130, menus.css:62); an
/// optional head names the [subject] (padding 4 8 7, a 1 px
/// `--border` below); rows 28 high on a 16 | label | auto grid with gap 10, padding 0 8, radius `--radius-md`,
/// `--fs-control`. The highlight is solid `--accent` with `--accent-ink` — icon, command, shortcut, check and chevron
/// turn ink — and moves between rows without a fade; danger rows are `--rem` with a `--danger-hover` tint as their
/// highlight; a check is `--accent-text`. The right column's faint text reads as dim on the menu's sheen (decision
/// 16.41). One highlight for mouse and keyboard; while the keyboard drives, hover does not move it.
///
/// **Keys.** ↑ ↓ move and wrap, Home End, typing jumps to the next row starting with the letters (letters within
/// `--dur-typeahead` extend the match, on `ZsMenuItem.text` else the label), ↩ / Space activate, → opens a submenu
/// with its first row highlighted, ← and Esc close only a submenu, and Esc on the top level closes the menu and
/// returns focus to its opener (r4out a11y KVS-7).
///
/// **Submenus** open after `--delay-submenu` on hover (→, ↩ and a click at once). While the pointer travels toward
/// an open submenu — inside the triangle from where it was to the submenu's near corners — other rows take no
/// highlight; reaching the submenu cancels a pending switch; leaving row and triangle closes it after
/// `--delay-submenu-out`. A submenu opens right of its row, flips left without room and stays 8 px inside the
/// window.
///
/// **Activation** (story 11.11 I3): the row blinks — highlight off `--dur-blink`, on `--dur-blink`, input ignored —
/// then focus goes back to the opener, then `ZsMenuItem.onSelected` runs, then the menu fades out. Focus changes apply
/// in a microtask, before the frame that builds whatever the command shows, so a `ZsSheet` it opens records the
/// opener as the node to return to. An opener that is gone by then gets no focus request.
///
/// **Placement** (Claude's proposal, Story 11.11; 11.3 places menus against islands): at the position [ZsMenuController.open]
/// was given, else 4 below the anchor's left edge, flipped above without room, clamped 8 px inside the window.
///
/// VoiceOver: the menu is a container named by [semanticLabel], else by [subject]; each row a button named by its
/// label, its dot's meaning and its command (the Project menu's bookmark; checked for a check item, in a mutually
/// exclusive group for a radio item), the highlighted one selected and focused.
class ZsMenuAnchor extends StatefulWidget implements ZsControl {
  /// A menu of [entries] over the widget [builder] builds.
  const ZsMenuAnchor({
    required this.entries,
    required this.builder,
    this.controller,
    this.subject,
    this.semanticLabel,
    this.headLeading,
    this.blink = true,
    this.width,
    this.cmdMaxWidth,
    this.onOpen,
    this.onClose,
    this.identifier,
    super.key,
  });

  /// The rows.
  final List<ZsMenuEntry> entries;

  /// The menu's fixed width (border box), or null for 250–320 by its content (DS components/menus/menus.css:6).
  final double? width;

  /// The widest a row's command may be before it ends in an ellipsis, or null for no limit.
  final double? cmdMaxWidth;

  /// Builds the anchor (typically a button that calls `controller.open`).
  final Widget Function(BuildContext context, ZsMenuController controller) builder;

  /// The controller; the anchor keeps its own when null.
  final ZsMenuController? controller;

  /// What the menu acts on, shown in its head and read as its name unless [semanticLabel] gives one.
  final String? subject;

  /// The menu's VoiceOver name, read instead of [subject]; it draws nothing.
  final String? semanticLabel;

  /// A widget before the subject in the head (Epic 10's change id and @ badge).
  final Widget? headLeading;

  /// Whether activation blinks the row first.
  final bool blink;

  /// Called when the menu opens.
  final VoidCallback? onOpen;

  /// Called when the menu is gone.
  final VoidCallback? onClose;

  /// The open menu's `Semantics(identifier:)`.
  @override
  final String? identifier;

  @override
  State<ZsMenuAnchor> createState() => _ZsMenuAnchorState();
}

class _ZsMenuAnchorState extends State<ZsMenuAnchor> {
  final _menu = MenuController();
  ZsMenuController? _ownController;
  FocusNode? _opener;
  var _closing = false;
  var _refocus = false;
  VoidCallback? _hide;

  ZsMenuController get _controller => widget.controller ?? (_ownController ??= ZsMenuController());

  @override
  void initState() {
    super.initState();
    _controller._anchor = this;
  }

  @override
  void didUpdateWidget(ZsMenuAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?._anchor = null;
      _controller._anchor = this;
    }
  }

  @override
  void dispose() {
    if (_controller._anchor == this) {
      _controller._anchor = null;
    }
    super.dispose();
  }

  void _open(Offset? position) {
    // Opened again while open (a second click on the anchor, a second right-click): focus is in the menu, and the
    // opener stays the one it came from.
    if (!_menu.isOpen) {
      _opener = FocusManager.instance.primaryFocus;
    }
    _menu.open(position: position);
  }

  void _close({required bool refocus}) {
    if (!_menu.isOpen) {
      return;
    }
    _refocus = refocus;
    _menu.close();
  }

  void _refocusOpener() {
    final FocusNode? opener = _opener;
    if (opener != null && opener != FocusManager.instance.rootScope && (opener.context?.mounted ?? false)) {
      opener.requestFocus();
    }
  }

  void _activated(ZsMenuItem item) {
    _refocusOpener();
    item.onSelected?.call();
    _close(refocus: false);
  }

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: _menu,
    consumeOutsideTaps: true,
    onOpenRequested: (position, show) {
      _hide = null;
      setState(() => _closing = false);
      show();
    },
    onCloseRequested: (hide) {
      if (_closing) {
        return;
      }
      _hide = hide;
      setState(() => _closing = true);
    },
    onOpen: widget.onOpen,
    onClose: () {
      if (_refocus) {
        _refocusOpener();
      }
      _refocus = false;
      widget.onClose?.call();
    },
    overlayBuilder: (context, info) => Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _MenuLayout(anchor: info.anchorRect, position: info.position),
        child: TapRegion(
          groupId: info.tapRegionGroupId,
          // A root anchor closes only its submenus on an outside tap; the menu closes itself.
          onTapOutside: (_) => _close(refocus: false),
          child: Semantics(
            identifier: widget.identifier,
            child: ZsMenuPanel(
              entries: widget.entries,
              subject: widget.subject,
              semanticLabel: widget.semanticLabel,
              headLeading: widget.headLeading,
              blink: widget.blink,
              minWidth: widget.width ?? ZsMenuPanel.defaultMinWidth,
              maxWidth: widget.width ?? ZsMenuPanel.defaultMaxWidth,
              cmdMaxWidth: widget.cmdMaxWidth,
              closing: _closing,
              onClosed: () {
                final VoidCallback? hide = _hide;
                _hide = null;
                hide?.call();
              },
              onActivated: _activated,
              onDismiss: () => _close(refocus: true),
            ),
          ),
        ),
      ),
    ),
    builder: (context, controller, child) => widget.builder(context, _controller),
  );
}

/// Places a top-level menu at its position, else 4 below the anchor; flips above without room; clamps 8 inside.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout({required this.anchor, required this.position});

  final Rect anchor;
  final Offset? position;

  static const double _margin = 8;
  static const double _gap = 4;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
    Size(math.max(0, constraints.maxWidth - 2 * _margin), math.max(0, constraints.maxHeight - 2 * _margin)),
  );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final Offset? at = position;
    double x;
    double y;
    if (at != null) {
      x = anchor.left + at.dx;
      y = anchor.top + at.dy;
    } else {
      x = anchor.left;
      y = anchor.bottom + _gap;
      if (y + childSize.height > size.height - _margin && anchor.top - _gap - childSize.height >= _margin) {
        y = anchor.top - _gap - childSize.height;
      }
    }
    x = math.max(_margin, math.min(x, size.width - _margin - childSize.width));
    y = math.max(_margin, math.min(y, size.height - _margin - childSize.height));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) => oldDelegate.anchor != anchor || oldDelegate.position != position;
}

/// Places a submenu right of its row (its first row level with it), flipped left without room, kept 8 inside.
class _SubmenuLayout extends SingleChildLayoutDelegate {
  _SubmenuLayout({required this.row});

  final Rect row;

  /// `left:calc(100% - 2px);top:-6px` (DS components/menus/menus.css:34).
  static const double _overlap = 2;
  static const double _lift = 6;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
    Size(math.max(0, constraints.maxWidth - 2 * _margin), math.max(0, constraints.maxHeight - 2 * _margin)),
  );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = row.right - _overlap;
    if (x + childSize.width > size.width - _margin) {
      x = row.left + _overlap - childSize.width;
    }
    x = math.max(_margin, math.min(x, size.width - _margin - childSize.width));
    double y = row.top - _lift;
    if (y + childSize.height > size.height - _margin) {
      y -= math.min(y - _margin, y + childSize.height - (size.height - _margin));
    }
    return Offset(x, math.max(_margin, y));
  }

  @override
  bool shouldRelayout(_SubmenuLayout oldDelegate) => oldDelegate.row != row;
}

/// The menu panel itself: the material, the rows, the keys, the highlight, submenus and the blink. Shared by
/// [ZsMenuAnchor], the select's list and the text field's context menu; not exported.
class ZsMenuPanel extends StatefulWidget {
  /// A panel of [entries].
  const ZsMenuPanel({
    required this.entries,
    required this.onActivated,
    required this.onDismiss,
    this.subject,
    this.semanticLabel,
    this.headLeading,
    this.blink = true,
    this.closing = false,
    this.onClosed,
    this.takeFocus = true,
    this.highlight,
    this.submenu = false,
    this.minWidth = defaultMinWidth,
    this.maxWidth = defaultMaxWidth,
    this.cmdMaxWidth,
    this.scrollController,
    this.rowKeys,
    this.origin,
    this.onPointerEnter,
    super.key,
  });

  /// The rows.
  final List<ZsMenuEntry> entries;

  /// Runs once an item's blink is over.
  final ValueChanged<ZsMenuItem> onActivated;

  /// Esc (and ← in a submenu): the owner closes the panel.
  final VoidCallback onDismiss;

  /// The head's subject, read as the panel's name unless [semanticLabel] gives one.
  final String? subject;

  /// The panel's VoiceOver name, read instead of [subject]; it draws nothing.
  final String? semanticLabel;

  /// A widget before the subject in the head.
  final Widget? headLeading;

  /// Whether activation blinks the row.
  final bool blink;

  /// Whether the panel leaves.
  final bool closing;

  /// Runs once the exit completes.
  final VoidCallback? onClosed;

  /// Whether focus moves into the panel (a command menu); false keeps it where it is (the text menu).
  final bool takeFocus;

  /// The entry highlighted at first (a select's chosen row, a keyboard-opened submenu's first row).
  final int? highlight;

  /// Whether this panel is a submenu: ← closes it.
  final bool submenu;

  /// `min-width:250px` (DS components/menus/menus.css:6).
  static const double defaultMinWidth = 250;

  /// `max-width:320px` (DS components/menus/menus.css:6).
  static const double defaultMaxWidth = 320;

  /// `min-width` (DS components/menus/menus.css:6; the select's list is wider).
  final double minWidth;

  /// `max-width` (DS components/menus/menus.css:6; the select's list allows 360).
  final double maxWidth;

  /// The widest a row's command may be before it ends in an ellipsis, or null for no limit.
  final double? cmdMaxWidth;

  /// Scrolls a panel taller than the window (the select brings its chosen row to the trigger).
  final ScrollController? scrollController;

  /// One key per entry, so an owner can measure a row (the select's geometry).
  final List<GlobalKey>? rowKeys;

  /// The transform origin of the entrance; top left by default.
  final Alignment? origin;

  /// The pointer entered the panel (a parent menu cancels a pending submenu switch).
  final VoidCallback? onPointerEnter;

  /// The first actionable entry after (or, for [direction] −1, before) [from], wrapping; [from] when none.
  static int step(List<ZsMenuEntry> entries, int from, int direction) {
    final int count = entries.length;
    for (var k = 1; k <= count; k++) {
      final int j = ((from + direction * k) % count + count) % count;
      if (entries[j] case ZsMenuItem(actionable: true)) {
        return j;
      }
    }
    return from;
  }

  @override
  State<ZsMenuPanel> createState() => ZsMenuPanelState();
}

/// The panel's state; an owner activates a row through [activateEntry] (the select's press – drag – release).
class ZsMenuPanelState extends State<ZsMenuPanel> {
  final _focus = FocusNode(debugLabel: 'ZsMenuPanel');
  late int _hi = widget.highlight ?? -1;
  var _keyboard = false;
  var _blinkAt = -1;
  var _busy = false;

  /// The open submenu's entry, or −1.
  var _sub = -1;

  /// Whether the open submenu took focus (opened by key) and highlights its first row.
  var _subByKey = false;
  final _subControllers = <int, MenuController>{};

  /// The open submenu's panel, to measure the safe triangle; a new key per opening, so a submenu reopened by key
  /// takes focus and its first row.
  final _subKeys = <int, GlobalKey>{};
  Timer? _subTimer;
  Offset? _lastPointer;

  var _typed = '';
  Timer? _typeTimer;
  final _blinkTimers = <Timer>[];

  /// `padding:5px` (DS components/menus/menus.css:6).
  static const double _padding = 5;

  @override
  void initState() {
    super.initState();
    if (widget.highlight != null) {
      _keyboard = true;
    }
    if (widget.takeFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.closing) {
          _focus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _subTimer?.cancel();
    _typeTimer?.cancel();
    for (final Timer timer in _blinkTimers) {
      timer.cancel();
    }
    _focus.dispose();
    super.dispose();
  }

  MenuController _subController(int index) => _subControllers.putIfAbsent(index, MenuController.new);

  void _openSub(int index, {required bool byKey}) {
    _subTimer?.cancel();
    if (_sub == index && (_subByKey || !byKey)) {
      return;
    }
    _closeSub();
    setState(() {
      _sub = index;
      _subByKey = byKey;
      _subKeys[index] = GlobalKey(debugLabel: 'ZsMenuPanel submenu $index');
    });
    _subController(index).open();
  }

  void _closeSub() {
    final int open = _sub;
    if (open < 0) {
      return;
    }
    _subControllers[open]?.close();
    if (mounted) {
      setState(() => _sub = -1);
    }
  }

  /// Activates the entry at [index] as a click does: the blink, then `ZsMenuPanel.onActivated`.
  void activateEntry(int index) {
    if (_busy || index < 0 || index >= widget.entries.length) {
      return;
    }
    final ZsMenuEntry entry = widget.entries[index];
    if (entry is! ZsMenuItem || !entry.actionable) {
      return;
    }
    if (entry.submenu != null) {
      _openSub(index, byKey: _keyboard);
      return;
    }
    if (!widget.blink) {
      widget.onActivated(entry);
      return;
    }
    final Duration blink = ZsMotion.of(context).durBlink;
    setState(() {
      _busy = true;
      _hi = index;
      _blinkAt = index;
    });
    _blinkTimers.add(
      Timer(blink, () {
        if (!mounted) {
          return;
        }
        setState(() => _blinkAt = -1);
        _blinkTimers.add(
          Timer(blink, () {
            if (!mounted) {
              return;
            }
            _busy = false;
            widget.onActivated(entry);
          }),
        );
      }),
    );
  }

  /// Whether [point] lies in the triangle from the pointer's last spot to the open submenu's near corners (DS
  /// components/menus/Menu.jsx:11, :48-53).
  bool _aiming(Offset point) {
    final box = _subKeys[_sub]?.currentContext?.findRenderObject() as RenderBox?;
    final Offset? last = _lastPointer;
    if (box == null || !box.hasSize || last == null) {
      return false;
    }
    final Rect rect = box.localToGlobal(Offset.zero) & box.size;
    final double nearX = rect.left >= last.dx ? rect.left : rect.right;
    return _inTriangle(point, last, Offset(nearX, rect.top), Offset(nearX, rect.bottom));
  }

  static bool _inTriangle(Offset p, Offset a, Offset b, Offset c) {
    double side(Offset u, Offset v, Offset w) => (u.dx - w.dx) * (v.dy - w.dy) - (v.dx - w.dx) * (u.dy - w.dy);
    final double d1 = side(p, a, b);
    final double d2 = side(p, b, c);
    final double d3 = side(p, c, a);
    final bool negative = d1 < 0 || d2 < 0 || d3 < 0;
    final bool positive = d1 > 0 || d2 > 0 || d3 > 0;
    return !(negative && positive);
  }

  void _enter(int index, Offset position) {
    if (_busy) {
      return;
    }
    final ZsMenuEntry entry = widget.entries[index];
    if (entry is! ZsMenuItem || !entry.actionable) {
      return;
    }
    _subTimer?.cancel();
    final ZsMotion motion = ZsMotion.of(context);
    if (_sub >= 0 && _sub != index && _aiming(position)) {
      _subTimer = Timer(motion.delaySubmenuOut, () {
        if (!mounted) {
          return;
        }
        setState(() => _hi = index);
        if (entry.submenu != null) {
          _openSub(index, byKey: false);
        } else {
          _closeSub();
        }
      });
      return;
    }
    setState(() {
      _keyboard = false;
      _hi = index;
    });
    if (entry.submenu != null) {
      if (_sub != index) {
        _subTimer = Timer(motion.delaySubmenu, () {
          if (mounted) {
            _openSub(index, byKey: false);
          }
        });
      }
    } else if (_sub >= 0) {
      _subTimer = Timer(motion.delaySubmenuOut, _closeSub);
    }
  }

  void _hover(Offset position) {
    if (_keyboard) {
      setState(() => _keyboard = false);
    }
    if (_sub < 0 || !_aiming(position)) {
      _lastPointer = position;
    }
  }

  void _leave() {
    if (!_keyboard && _sub < 0 && !_busy) {
      setState(() => _hi = -1);
    }
  }

  void _type(String character) {
    _typeTimer?.cancel();
    _typed += character.toLowerCase();
    _typeTimer = Timer(ZsMotion.of(context).durTypeahead, () => _typed = '');
    final List<ZsMenuEntry> entries = widget.entries;
    final int from = math.max(0, _typed.length > 1 ? _hi : _hi + 1);
    for (var n = 0; n < entries.length; n++) {
      final int j = (from + n) % entries.length;
      if (entries[j] case final ZsMenuItem item when item.actionable && item._match.startsWith(_typed)) {
        setState(() {
          _keyboard = true;
          _hi = j;
        });
        return;
      }
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    if (_busy) {
      return KeyEventResult.handled;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final List<ZsMenuEntry> entries = widget.entries;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      final down = key == LogicalKeyboardKey.arrowDown;
      _closeSub();
      setState(() {
        _keyboard = true;
        _hi = ZsMenuPanel.step(entries, _hi < 0 && !down ? 0 : _hi, down ? 1 : -1);
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) {
      setState(() {
        _keyboard = true;
        _hi = key == LogicalKeyboardKey.home
            ? ZsMenuPanel.step(entries, -1, 1)
            : ZsMenuPanel.step(entries, entries.length, -1);
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        _keyboard = true;
        activateEntry(_hi);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final ZsMenuEntry? highlighted = _hi >= 0 && _hi < entries.length ? entries[_hi] : null;
      if (highlighted case ZsMenuItem(submenu: final List<ZsMenuEntry> _?, actionable: true)) {
        _keyboard = true;
        _openSub(_hi, byKey: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (widget.submenu) {
        widget.onDismiss();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      return KeyEventResult.handled;
    }
    final String? character = event.character;
    if (character != null && character.length == 1 && character.trim().isNotEmpty) {
      _type(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final children = <Widget>[];
    final String? subject = widget.subject;
    final Widget? leading = widget.headLeading;
    if (subject != null || leading != null) {
      children.add(_Head(subject: subject, leading: leading));
    }
    for (var i = 0; i < widget.entries.length; i++) {
      final Key? key = widget.rowKeys != null && i < widget.rowKeys!.length ? widget.rowKeys![i] : null;
      children.add(switch (widget.entries[i]) {
        ZsMenuSeparator() => _Separator(key: key),
        ZsMenuHeader(:final String label) => _Header(key: key, label: label, first: i == 0 && children.isEmpty),
        ZsMenuNote(:final String label, :final Widget? leading) => _Note(key: key, label: label, leading: leading),
        final ZsMenuItem item => _row(context, i, item, key),
      });
    }
    // The widths hold for the border box (`box-sizing:border-box`, DS components/base.css:2): the material's border
    // and padding come off the content's.
    const double edges = 2 * (_padding + ZsSurface.borderWidth);
    final Widget body = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: math.max(0, widget.minWidth - edges),
        maxWidth: math.max(0, widget.maxWidth - edges),
      ),
      child: IntrinsicWidth(
        child: SingleChildScrollView(
          controller: widget.scrollController,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 1, children: children),
        ),
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: widget.semanticLabel ?? subject,
      child: ZsSurfaceTransition(
        motion: ZsSurfaceMotion.menu,
        closing: widget.closing,
        onClosed: widget.onClosed,
        origin: widget.origin,
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _handleKey,
          skipTraversal: true,
          includeSemantics: false,
          child: MouseRegion(
            onEnter: (_) => widget.onPointerEnter?.call(),
            onHover: (event) => _hover(event.position),
            onExit: (_) => _leave(),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: colors.text),
              child: ZsMenuMaterial(padding: const EdgeInsets.all(_padding), child: body),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int index, ZsMenuItem item, Key? key) {
    final List<ZsMenuEntry>? submenu = item.submenu;
    final Widget row = _Row(
      key: key,
      item: item,
      cmdMaxWidth: widget.cmdMaxWidth,
      highlighted: index == _hi && _blinkAt != index && item.actionable,
      blinking: index == _blinkAt,
      submenuOpen: index == _sub,
      onEnter: (position) => _enter(index, position),
      onTap: () {
        _keyboard = false;
        activateEntry(index);
      },
    );
    if (submenu == null) {
      return row;
    }
    return RawMenuAnchor(
      controller: _subController(index),
      overlayBuilder: (context, info) => Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: _SubmenuLayout(row: info.anchorRect),
          child: TapRegion(
            groupId: info.tapRegionGroupId,
            child: ZsMenuPanel(
              key: _subKeys[index],
              entries: submenu,
              blink: widget.blink,
              cmdMaxWidth: widget.cmdMaxWidth,
              submenu: true,
              takeFocus: _subByKey,
              highlight: _subByKey ? ZsMenuPanel.step(submenu, -1, 1) : null,
              onActivated: widget.onActivated,
              onPointerEnter: () => _subTimer?.cancel(),
              onDismiss: () {
                _closeSub();
                _focus.requestFocus();
              },
            ),
          ),
        ),
      ),
      child: row,
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.subject, required this.leading});

  final String? subject;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? text = subject;
    final Widget? lead = leading;
    // `padding:4px 8px 7px;margin-bottom:3px;border-bottom:1px solid var(--border)` (DS components/menus/menus.css:11).
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(
            spacing: 8,
            children: <Widget>[
              ?lead,
              if (text != null)
                Expanded(
                  child: Text(
                    text,
                    style: zsSans(ZsType.fsMd, height: ZsType.lhSnug).copyWith(color: colors.textDim),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.label, required this.first, super.key});

  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      // `padding:7px 8px 3px 34px` (the first one 3 on top; DS components/menus/menus.css:13-14).
      padding: EdgeInsets.fromLTRB(34, first ? 3 : 7, 8, 3),
      child: Text(ZsType.caps(label), style: ZsType.capsLabel.copyWith(color: ZsColors.of(context).textDim)),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.label, required this.leading, super.key});

  final String label;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Padding(
    // The rows' padding and 16 | label grid (DS components/menus/menus.css:15), 6 above and below the wrapped text.
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Row(
      spacing: 10,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: 16, child: Center(child: leading)),
        Expanded(
          child: Text(
            label,
            style: zsSans(ZsType.fsId, height: ZsType.lhSnug).copyWith(color: ZsColors.of(context).textDim),
          ),
        ),
      ],
    ),
  );
}

class _Separator extends StatelessWidget {
  const _Separator({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    // `height:1px;margin:4px 6px` (DS components/menus/menus.css:33).
    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
    child: SizedBox(height: 1, child: ColoredBox(color: ZsColors.of(context).border)),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.cmdMaxWidth,
    required this.highlighted,
    required this.blinking,
    required this.submenuOpen,
    required this.onEnter,
    required this.onTap,
    super.key,
  });

  final ZsMenuItem item;
  final double? cmdMaxWidth;
  final bool highlighted;
  final bool blinking;
  final bool submenuOpen;
  final ValueChanged<Offset> onEnter;
  final VoidCallback onTap;

  /// `height:28px` (DS components/menus/menus.css:15).
  static const double _height = 28;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final rung = ZsTextRung.of(colors, hovered: true);
    final bool danger = item.danger;
    final Color fill = highlighted ? (danger ? colors.dangerHover : colors.accent) : const Color(0x00000000);
    final Color text = danger ? colors.rem : (highlighted ? colors.accentInk : colors.text);
    final Color icon = danger ? colors.rem : (highlighted ? colors.accentInk : colors.textMuted);
    final Color side = danger && highlighted
        ? colors.rem
        : (highlighted ? colors.accentInk : (blinking ? colors.textMuted : rung.faint));
    final Color check = highlighted && !danger ? colors.accentInk : (blinking ? colors.textMuted : colors.accentText);
    final Color chevron = highlighted && !danger ? colors.accentInk : (blinking ? colors.textMuted : colors.textDim);
    final bool? checked = item.checked;
    final String? glyph = item.icon;
    final Widget lead = checked != null
        ? (checked ? ZanshinIcon(ZI.check, size: ZsIconSize.sm, color: check) : const SizedBox.shrink())
        : (glyph != null ? ZanshinIcon(glyph, size: ZsIconSize.md, color: icon) : const SizedBox.shrink());
    final String? cmd = item.cmd;
    final String? shortcut = item.shortcut;
    TextStyle labelStyle = item.mono
        ? zsMono(ZsType.fsMd, height: ZsType.lhSnug).copyWith(color: text)
        : zsSans(ZsType.fsControl, height: ZsType.lhSnug).copyWith(color: text);
    if (item.strong) {
      labelStyle = zsWeighted(labelStyle, ZsType.fwSemibold);
    }
    final Widget labelText = Text(item.label, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
    final Color? dot = item.dot;
    final double? cmdMax = cmdMaxWidth;
    Widget? cmdText = cmd == null
        ? null
        : Text(
            cmd,
            style: zsMono(ZsType.fsSm).copyWith(color: side),
            maxLines: 1,
            softWrap: false,
            overflow: cmdMax == null ? TextOverflow.clip : TextOverflow.ellipsis,
          );
    if (cmdText != null && cmdMax != null) {
      cmdText = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: cmdMax),
        child: cmdText,
      );
    }
    Widget row = DecoratedBox(
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(metrics.radiusMd)),
      child: SizedBox(
        height: _height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            spacing: 10,
            children: <Widget>[
              SizedBox(width: 16, child: Center(child: lead)),
              Expanded(
                child: dot == null
                    ? labelText
                    // `.zs-pm-l{display:flex;align-items:center;gap:8px;min-width:0}` (DS menus.css:58).
                    : Row(
                        spacing: 8,
                        children: <Widget>[
                          Flexible(child: labelText),
                          _MenuDot(color: dot, ring: highlighted && !danger ? colors.accentInk : null),
                        ],
                      ),
              ),
              if (cmdText != null || shortcut != null || item.submenu != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: <Widget>[
                    ?cmdText,
                    if (shortcut != null)
                      Text(
                        shortcut,
                        style: zsSans(ZsType.fsMd).copyWith(color: side, letterSpacing: .02 * ZsType.fsMd),
                        softWrap: false,
                      ),
                    if (item.submenu != null)
                      Transform.translate(
                        // `margin-right:-3px` (DS components/menus/menus.css:22).
                        offset: const Offset(3, 0),
                        child: ZanshinIcon(ZI.chevronRight, size: ZsIconSize.sm, color: chevron),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
    if (!item.enabled) {
      row = Opacity(opacity: metrics.disabledOpacity, child: row);
    }
    final Widget semantics = Semantics(
      container: true,
      identifier: item.identifier,
      button: true,
      enabled: item.enabled,
      label: <String>[item.label, ?item.dotLabel, ?item.cmd].join(', '),
      hint: item.tooltip,
      checked: checked,
      inMutuallyExclusiveGroup: checked != null && item.radio ? true : null,
      selected: highlighted,
      focused: highlighted,
      expanded: item.submenu != null ? submenuOpen : null,
      onTap: item.enabled ? onTap : null,
      child: ExcludeSemantics(
        child: MouseRegion(
          onEnter: (event) => onEnter(event.position),
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: item.enabled ? onTap : null, child: row),
        ),
      ),
    );
    final String? tooltip = item.tooltip;
    return tooltip == null
        ? semantics
        : ZsTooltip(message: tooltip, placement: ZsTooltipPlacement.right, child: semantics);
  }
}

/// A row's 6 px status dot (`.zs-pm-dot{width:6px;height:6px;border-radius:50%}`, DS components/menus/menus.css:61),
/// with a 1 px [ring] outside it while the row is highlighted (decision 16.42 h).
class _MenuDot extends LeafRenderObjectWidget {
  const _MenuDot({required this.color, required this.ring});

  final Color color;
  final Color? ring;

  @override
  _RenderMenuDot createRenderObject(BuildContext context) => _RenderMenuDot(color: color, ring: ring);

  @override
  void updateRenderObject(BuildContext context, _RenderMenuDot renderObject) {
    renderObject
      ..color = color
      ..ring = ring;
  }
}

class _RenderMenuDot extends RenderBox {
  _RenderMenuDot({required this._color, required this._ring});

  static const double _side = 6;
  static const double _ringWidth = 1;

  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value != _color) {
      _color = value;
      markNeedsPaint();
    }
  }

  Color? get ring => _ring;
  Color? _ring;
  set ring(Color? value) {
    if (value != _ring) {
      _ring = value;
      markNeedsPaint();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(const Size.square(_side));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _side;

  @override
  double computeMaxIntrinsicWidth(double height) => _side;

  @override
  double computeMinIntrinsicHeight(double width) => _side;

  @override
  double computeMaxIntrinsicHeight(double width) => _side;

  @override
  void paint(PaintingContext context, Offset offset) {
    final Offset centre = offset + size.center(Offset.zero);
    final Color? ringColor = _ring;
    if (ringColor != null) {
      context.canvas.drawCircle(
        centre,
        _side / 2 + _ringWidth / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _ringWidth
          ..color = ringColor,
      );
    }
    context.canvas.drawCircle(centre, _side / 2, Paint()..color = _color);
  }
}

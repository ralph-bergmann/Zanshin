// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show ZanshinWarning;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';

/// One toast a source shows through [ShellToasts.show] (Story 10.23): its [tone] and how to [build] its [ZsToast] —
/// rebuilt at each build and whenever [listenable] notifies, so ids and the Undo button follow their model without
/// showing it again. `dismiss` hides this entry.
@immutable
class ShellToastEntry {
  /// An entry of [tone].
  const ShellToastEntry({required this.tone, required this.build, this.listenable});

  /// Success and warn hide after the hold; error stays.
  final ZsToastTone tone;

  /// The toast.
  final ZsToast Function(BuildContext context, VoidCallback dismiss) build;

  /// What the toast follows.
  final Listenable? listenable;
}

/// The project window's one toast queue (Story 10.23): one toast at a time, no history. [show] replaces the current
/// one, [dismiss] hides it, and the view reports the end of its exit through [exited]; [occupied] is true from a show
/// until that exit ends, which is while the shell's bottom slot belongs to the toast.
class ShellToasts extends ChangeNotifier {
  ShellToastEntry? _current;
  var _exiting = false;
  var _disposed = false;

  /// The toast showing; null while none is, or while the last one leaves.
  ShellToastEntry? get current => _current;

  /// Whether a toast shows or is leaving.
  bool get occupied => _current != null || _exiting;

  /// Shows [entry] in place of the current toast.
  void show(ShellToastEntry entry) {
    _current = entry;
    _exiting = false;
    _notify();
  }

  /// Hides the current toast, or only [entry] when given and still current.
  void dismiss([ShellToastEntry? entry]) {
    if (_current == null || (entry != null && !identical(entry, _current))) {
      return;
    }
    _current = null;
    _exiting = true;
    _notify();
  }

  /// The view's exit ended.
  void exited() {
    if (_current != null || !_exiting) {
      return;
    }
    _exiting = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The shell's toast host (Story 10.23; DS components/overlays/Toast.prompt.md:10-15; overlays.css:4-5, :12-14), the
/// bottom slot's content while [ShellToasts.occupied]:
/// - **in**, a 10 px rise × `--motion` and a fade on `--dur-slide` / `--ease-glide`; **out**, 8 px down × `--motion`
///   and a fade on `--dur-exit-lg` / `--ease-exit`, then [ShellToasts.exited]; a **replaced** toast fades in place on
///   `--dur-exit` under the new one. Glass fades only through [ZsFade].
/// - **hold:** success and warn hide after `--dur-toast-hold`, paused while the pointer is over the toast or focus is
///   inside it (Claude's proposal for the focus); an error stays until × or its action.
/// - **keys:** its buttons are no Tab stops until focus is inside the toast (the shell's F6 puts it there); then Tab
///   moves between them.
class ShellToastView extends StatefulWidget {
  /// The host of [toasts].
  const ShellToastView({required this.toasts, super.key});

  /// The queue.
  final ShellToasts toasts;

  /// The rise in, before × `--motion` (DS components/overlays/overlays.css:5).
  static const double rise = 10;

  /// The drop out, before × `--motion` (DS components/overlays/Toast.prompt.md:12).
  static const double drop = 8;

  @override
  State<ShellToastView> createState() => _ShellToastViewState();
}

class _ShellToastViewState extends State<ShellToastView> with TickerProviderStateMixin {
  late final _motion = AnimationController(vsync: this)..addStatusListener(_motionStatus);
  late final _replace = AnimationController(vsync: this)..addStatusListener(_replaceStatus);
  late final _hold = AnimationController(vsync: this)..addStatusListener(_holdStatus);
  final _region = FocusNode(debugLabel: 'Toast', canRequestFocus: false, skipTraversal: true);

  ShellToastEntry? _shown;
  ShellToastEntry? _replaced;
  var _closing = false;
  var _hovered = false;
  var _started = false;

  @override
  void initState() {
    super.initState();
    widget.toasts.addListener(_sync);
    _region.addListener(_focusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _motion
      ..duration = motion.durSlide
      ..reverseDuration = motion.durExitLg;
    _replace.duration = motion.durExit;
    _hold.duration = motion.durToastHold;
    if (!_started) {
      _started = true;
      _sync();
    }
  }

  @override
  void didUpdateWidget(ShellToastView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toasts != widget.toasts) {
      oldWidget.toasts.removeListener(_sync);
      widget.toasts.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.toasts.removeListener(_sync);
    _motion.dispose();
    _replace.dispose();
    _hold.dispose();
    _region.dispose();
    super.dispose();
  }

  void _sync() {
    final ShellToastEntry? next = widget.toasts.current;
    final ShellToastEntry? shown = _shown;
    if (next == null) {
      if (shown == null) {
        // Nothing to play out (a view mounted during an exit); not now, as this can run while the tree builds.
        WidgetsBinding.instance.addPostFrameCallback((_) => widget.toasts.exited());
      } else if (!_closing) {
        setState(() => _closing = true);
        _hold.stop();
        _motion.reverse();
      }
      return;
    }
    if (identical(next, shown)) {
      if (_closing) {
        // The same entry shown again during its exit comes back from where it is.
        setState(() => _closing = false);
        _motion.forward();
        _runHold();
      }
      return;
    }
    setState(() {
      // A toast already leaving is dropped; only one still showing fades in place.
      if (shown != null && !_closing) {
        _replaced = shown;
        _replace.forward(from: 0);
      }
      _shown = next;
      _closing = false;
      // The old keyed region unmounts without an exit; the new one hears its own enter.
      _hovered = false;
    });
    _motion.forward(from: 0);
    _hold.value = 0;
    _runHold();
  }

  bool get _paused => _hovered || _region.hasFocus;

  void _runHold() {
    if (_shown?.tone == ZsToastTone.error || _closing || _paused) {
      _hold.stop();
    } else {
      _hold.forward();
    }
  }

  void _holdStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.toasts.dismiss(_shown);
    }
  }

  void _motionStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _closing) {
      setState(() {
        _shown = null;
        _closing = false;
      });
      widget.toasts.exited();
    }
  }

  void _replaceStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      setState(() => _replaced = null);
    }
  }

  void _focusChanged() {
    setState(() {});
    _runHold();
  }

  void _hover(bool hovered) {
    _hovered = hovered;
    _runHold();
  }

  Widget _toast(ShellToastEntry entry, {required bool inTab}) {
    Widget build(BuildContext context) =>
        entry.build(context, () => widget.toasts.dismiss(entry)).withActionFocusSkip(!inTab);
    final Listenable? listenable = entry.listenable;
    return listenable == null
        ? Builder(builder: build)
        : ListenableBuilder(listenable: listenable, builder: (context, _) => build(context));
  }

  @override
  Widget build(BuildContext context) {
    final ShellToastEntry? shown = _shown;
    final ShellToastEntry? replaced = _replaced;
    final ZsMotion motion = ZsMotion.of(context);
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        if (replaced != null)
          IgnorePointer(
            key: ObjectKey(replaced),
            child: ExcludeFocus(
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: _replace,
                  builder: (context, child) =>
                      ZsFade(opacity: (1 - motion.easeExit.transform(_replace.value)).clamp(0, 1), child: child!),
                  child: _toast(replaced, inTab: false),
                ),
              ),
            ),
          ),
        if (shown != null)
          MouseRegion(
            key: ObjectKey(shown),
            onEnter: (_) => _hover(true),
            onExit: (_) => _hover(false),
            child: Focus(
              focusNode: _region,
              includeSemantics: false,
              child: IgnorePointer(
                ignoring: _closing,
                child: ExcludeFocus(
                  excluding: _closing,
                  child: AnimatedBuilder(
                    animation: _motion,
                    builder: (context, child) {
                      final double v = _motion.value;
                      // Both run v toward its end: in 0 → 1 rising from below, out 1 → 0 dropping below.
                      final double eased = _closing
                          ? motion.easeExit.flipped.transform(v)
                          : motion.easeGlide.transform(v);
                      final double distance = _closing ? ShellToastView.drop : ShellToastView.rise;
                      return Transform.translate(
                        offset: Offset(0, distance * motion.motion * (1 - eased)),
                        child: ZsFade(opacity: eased.clamp(0, 1), child: child!),
                      );
                    },
                    child: _toast(shown, inTab: _region.hasFocus),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// [message] — a localized text whose placeholders were filled with [toastSlot]s — with each slot replaced by its
/// span in [parts].
InlineSpan toastSpan(String message, List<InlineSpan> parts) {
  final children = <InlineSpan>[];
  final text = StringBuffer();
  for (final int unit in message.runes) {
    final int slot = unit - _slotBase;
    if (slot >= 0 && slot < parts.length) {
      if (text.isNotEmpty) {
        children.add(TextSpan(text: text.toString()));
        text.clear();
      }
      children.add(parts[slot]);
    } else {
      text.writeCharCode(unit);
    }
  }
  if (text.isNotEmpty) {
    children.add(TextSpan(text: text.toString()));
  }
  return TextSpan(children: children);
}

// Private-use code points, never in a message.
const _slotBase = 0xE000;

/// The placeholder [toastSpan] replaces with its [i]th part.
String toastSlot(int i) => String.fromCharCode(_slotBase + i);

/// [text] in mono, 600 `--fs-md` (DS components/overlays/overlays.css:16): a bookmark name, a jj command.
InlineSpan toastMono(ZsColors colors, String text) => TextSpan(
  text: text,
  style: ZsType.id.copyWith(
    fontSize: ZsType.fsMd,
    fontWeight: FontWeight.w600,
    fontVariations: const <FontVariation>[FontVariation.weight(600)],
    color: colors.text,
  ),
);

/// [items] as a localized list: "a", "a and b", "a, b and c".
InlineSpan toastList(AppLocalizations strings, List<InlineSpan> items) {
  if (items.isEmpty) {
    return const TextSpan();
  }
  InlineSpan head = items.first;
  for (var i = 1; i < items.length; i++) {
    final String joined = i == items.length - 1
        ? strings.toastListAnd(toastSlot(0), toastSlot(1))
        : strings.toastListComma(toastSlot(0), toastSlot(1));
    head = toastSpan(joined, <InlineSpan>[head, items[i]]);
  }
  return head;
}

/// [text] followed by one " · " clause per warning, its message verbatim in `--warn` (Story 10.23 item 6); only the
/// messages, joined " · ", without [text].
InlineSpan toastWithWarnings(ZsColors colors, InlineSpan? text, List<ZanshinWarning> warnings) {
  final String messages = warnings.map((w) => w.message).join(' · '); // l10n-ignore: separator
  if (text == null) {
    return TextSpan(text: messages);
  }
  if (warnings.isEmpty) {
    return text;
  }
  return TextSpan(
    children: <InlineSpan>[
      text,
      TextSpan(
        text: ' · $messages',
        style: TextStyle(color: colors.warn),
      ), // l10n-ignore: separator
    ],
  );
}

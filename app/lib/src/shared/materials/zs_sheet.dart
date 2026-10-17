// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_values.dart';
import 'zs_surface.dart';
import 'zs_surface_transition.dart';

/// The modal sheet on its scrim, for the two short modal tasks, ConfirmDialog and Push (decision 16.17; DS
/// components/surfaces/surfaces.css:26-30; Dialog.prompt.md:1, :7-8). It fills its parent, which places it over the
/// window's content at `--z-dialog`; its content is ConfirmDialog's (11.11) or Push's (11.8).
///
/// **Scrim:** `--scrim` blurred by `--scrim-blur` (σ 12, saturate 1.2) in a backdrop group of its own: it overlaps
/// every island, and backdrop filters that overlap must not share a group (Claude's proposal; it is also the group a
/// window of its own gets while its sheet shows). It fades in over `--dur-pop` on `--ease-state` and out over
/// `--dur-exit-lg` on `--ease-exit` without an opacity layer above the filter (Claude's proposal): the colour layer
/// and the sheet fade by the fade value a, and the blur through the filter's alpha f = a·(1 − Lα) / (1 − a·Lα), Lα
/// the `--scrim` colour's alpha — exactly CSS opacity a over the whole scrim (f is 0 at a = 0 and 1 at a = 1). A
/// click on it does nothing and reaches nothing beneath; it hides the semantics beneath it until the exit starts.
/// Under reduce transparency and increased contrast it has no blur and the darker scrim colour of the tokens.
///
/// **Sheet:** [ZsSurface] with `--fl-sheen` over `--fl-bg-solid`, a 1 px `--fl-border`, `--shadow-dialog` and
/// `--radius-dialog`, clipped, centred, [width] × [height] (its content's size where null) but at most the parent
/// less 48 per axis; it enters and leaves as [ZsSurfaceMotion.sheet].
///
/// **Keys and focus** (DS components/surfaces/Dialog.jsx:7-24; readme.md:145): Esc runs [onCancel], except while
/// [busy] or [closing]. After the first frame focus moves to [initialFocus], else to the sheet's first control, else
/// to the sheet itself; Tab and Shift+Tab stay inside, also from the sheet itself. When [closing] turns true the
/// sheet takes no pointer and no focus, and focus returns to the node that had it before the sheet opened (Claude's
/// proposal: at the start of the exit rather than at unmount, so no key reaches a leaving sheet), or at dispose if
/// it never closed; an opener that is gone by then gets nothing. VoiceOver reads the sheet as a route named
/// [semanticLabel] until the exit starts; from then on it reads what lies beneath again.
class ZsSheet extends StatefulWidget {
  /// Shows [child] on a sheet over a scrim.
  const ZsSheet({
    required this.semanticLabel,
    required this.onCancel,
    required this.child,
    this.busy = false,
    this.closing = false,
    this.onClosed,
    this.initialFocus,
    this.width,
    this.height,
    super.key,
  });

  /// The sheet's distance from the edges of its parent, both sides together: `max-width:calc(100% - 48px)` and
  /// `max-height:calc(100% - 48px)` (DS components/surfaces/surfaces.css:30).
  static const _margin = 48.0;

  /// The name VoiceOver reads for the sheet (the dialog's title).
  final String semanticLabel;

  /// Runs on Esc, the sheet's cancel; the content's Cancel button calls it too.
  final VoidCallback onCancel;

  /// Whether the task runs (pushing): Esc does nothing.
  final bool busy;

  /// Whether the sheet is leaving; the parent keeps it mounted until [onClosed].
  final bool closing;

  /// Runs once when the exit completes.
  final VoidCallback? onClosed;

  /// The node that takes focus when the sheet opens; null for the first control.
  final FocusNode? initialFocus;

  /// The sheet's width; null for its content's.
  final double? width;

  /// The sheet's height; null for its content's.
  final double? height;

  /// The sheet's content.
  final Widget child;

  @override
  State<ZsSheet> createState() => _ZsSheetState();
}

class _ZsSheetState extends State<ZsSheet> with SingleTickerProviderStateMixin {
  static const _keys = <ShortcutActivator, Intent>{SingleActivator(LogicalKeyboardKey.escape): DismissIntent()};

  late final _fade = AnimationController(vsync: this)..addListener(_onTick);
  late final CurvedAnimation _fadeIn;

  /// Runs the controller back from 1 on the exit curve, flipped so the value is the remaining opacity.
  late final CurvedAnimation _fadeOut;

  late final _actions = <Type, Action<Intent>>{
    DismissIntent: CallbackAction<DismissIntent>(onInvoke: _cancel),
  };

  final _scrimGroup = BackdropKey();

  /// Moves the faded layer, and the content's state with it, when the scrim's filter comes or goes.
  final GlobalKey _layer = GlobalKey();

  final _scope = FocusScopeNode(debugLabel: 'ZsSheet');

  FocusNode? _opener;
  var _focusReturned = false;

  /// Whether the running exit has reported [ZsSheet.onClosed].
  var _reported = false;
  var _started = false;

  @override
  void initState() {
    super.initState();
    _opener = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback(_focusInitial);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      final ZsMotion motion = ZsMotion.of(context);
      _fadeIn = CurvedAnimation(parent: _fade, curve: motion.easeState);
      _fadeOut = CurvedAnimation(parent: _fade, curve: motion.easeExit.flipped);
      _run();
    }
  }

  @override
  void didUpdateWidget(ZsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      _run();
      // After this frame, so the focus this frame's ExcludeFocus gives up does not override the return.
      WidgetsBinding.instance.addPostFrameCallback(widget.closing ? (_) => _returnFocus() : _focusInitial);
    }
  }

  void _run() {
    final ZsMotion motion = ZsMotion.of(context);
    if (widget.closing) {
      _reported = false;
      _fade
        ..reverseDuration = motion.durExitLg
        ..reverse(from: 1);
    } else {
      _focusReturned = false;
      _fade
        ..duration = motion.durPop
        ..forward(from: 0);
    }
  }

  // On the frame the exit reaches its end, rather than on the next one, where the controller reports dismissed.
  void _onTick() {
    if (widget.closing && !_reported && _fade.value == 0) {
      _reported = true;
      widget.onClosed?.call();
    }
  }

  Object? _cancel(DismissIntent intent) {
    if (!widget.busy && !widget.closing) {
      widget.onCancel();
    }
    return null;
  }

  void _focusInitial([Duration? _]) {
    if (!mounted || widget.closing) {
      return;
    }
    final FocusNode? initial = widget.initialFocus;
    if (initial != null && initial.context != null && initial.canRequestFocus) {
      initial.requestFocus();
      return;
    }
    final FocusTraversalPolicy policy = FocusTraversalGroup.maybeOfNode(_scope) ?? ReadingOrderTraversalPolicy();
    (policy.findFirstFocus(_scope, ignoreCurrentFocus: true) ?? _scope).requestFocus();
  }

  void _returnFocus() {
    if (_focusReturned) {
      return;
    }
    _focusReturned = true;
    final FocusNode? opener = _opener;
    if (opener == null || opener == FocusManager.instance.rootScope || !(opener.context?.mounted ?? false)) {
      return;
    }
    opener.requestFocus();
  }

  @override
  void dispose() {
    _returnFocus();
    _fadeIn.dispose();
    _fadeOut.dispose();
    _fade.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final ZsElevation elevation = ZsElevation.of(context);
    final bool closing = widget.closing;
    final CurvedAnimation fade = closing ? _fadeOut : _fadeIn;
    Widget layer = FadeTransition(
      key: _layer,
      opacity: fade,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          BlockSemantics(
            blocking: !closing,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: ColoredBox(color: colors.scrim),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(ZsSheet._margin / 2),
              child: SizedBox(width: widget.width, height: widget.height, child: _sheet(colors, elevation, closing)),
            ),
          ),
        ],
      ),
    );
    final ZsGlassFilter? blur = elevation.scrimBlur;
    if (blur != null) {
      final faded = layer;
      final double scrimAlpha = colors.scrim.a;
      layer = AnimatedBuilder(
        animation: fade,
        builder: (context, child) => BackdropFilter.grouped(
          filter: blur.toImageFilter(alpha: fade.value * (1 - scrimAlpha) / (1 - fade.value * scrimAlpha)),
          child: child,
        ),
        child: faded,
      );
    }
    // The filter changes every frame of the fade; the boundary keeps that repaint off the window around the sheet.
    return RepaintBoundary(
      child: SizedBox.expand(
        child: ClipRect(
          child: BackdropGroup(
            backdropKey: _scrimGroup,
            child: IgnorePointer(ignoring: closing, child: layer),
          ),
        ),
      ),
    );
  }

  Widget _sheet(ZsColors colors, ZsElevation elevation, bool closing) => ExcludeSemantics(
    excluding: closing,
    child: Semantics(
      container: true,
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: widget.semanticLabel,
      child: ZsSurfaceTransition(
        motion: ZsSurfaceMotion.sheet,
        closing: closing,
        child: ZsSurface(
          fill: colors.flBgSolid,
          sheen: colors.flSheen,
          border: colors.flBorder,
          shadow: elevation.shadowDialog,
          radius: ZsMetrics.of(context).radiusDialog,
          clip: true,
          child: ExcludeFocus(
            excluding: closing,
            child: Shortcuts(
              shortcuts: _keys,
              child: Actions(
                actions: _actions,
                child: FocusScope(node: _scope, child: widget.child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

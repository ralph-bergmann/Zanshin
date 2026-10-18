// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../shell/calm_controller.dart';
import '../shell/shell_scope.dart';
import 'project_status_style.dart';

/// The project capsule in the top bar's PLACE slot, with the Project menu (epics.md Story 11.5 items 3-5; DS
/// ui_kits/desktop/kit.css:35-41, chrome.jsx:70-77; components/menus/ProjectMenu.{jsx,prompt.md}).
///
/// **Capsule.** A 44 px glass island (radius `--radius-island` 14, padding 0 12 0 8, gaps 10) holding the 28 px Nami
/// chip, [project]'s name in 13/600 cut with an ellipsis at 220 px, the 7 px status dot in its `--proj-*` colour (none
/// without a status; the floating export's app-float.jsx:160) and the chevron in `--text-dim`. Hover fills it with
/// `--fl-hover`; while the menu is open it shows `--fl-on` (hover `--fl-on-hover`, pressed `--fl-press`), as the icon
/// buttons do. Its tooltip is the path, the dot's the status label. A click, ↩, Space or ↓ opens the menu; a second
/// click closes it. VoiceOver reads a button named after the project, the status as its value, and whether the menu
/// is expanded.
///
/// **Menu.** 11.11's menu, 300 wide, [menuGap] below the capsule's left edge: RECENT with [recent] as radio rows
/// (the open project checked and semibold, its status dot after the name, the bookmark or "—" in the mono column cut
/// at 130 px) · All Projects… ⇧⌘O · Project Settings… · Settings… ⌘, (ProjectMenu.jsx:9-23). A row whose callback is
/// null is disabled (until 11.6 and 11.7 pass theirs). While open it holds the shell's calm scrolling (ledger I1).
/// VoiceOver names the open menu "Project" (ProjectMenu.jsx:30); it has no head.
///
/// Identifiers: `project-capsule`, `project-menu`, `project-menu-recent-<i>`, `project-menu-all`,
/// `project-menu-project-settings`, `project-menu-settings`.
class ProjectCapsule extends StatefulWidget {
  /// The capsule of the open [project].
  const ProjectCapsule({
    required this.project,
    required this.recent,
    required this.onOpen,
    this.onAllProjects,
    this.onProjectSettings,
    this.onSettings,
    this.menuController,
    super.key,
  });

  /// The open project.
  final ProjectEntry project;

  /// The Project menu's Recent rows, the open project first.
  final List<ProjectEntry> recent;

  /// Opens the project at the given path (a Recent row).
  final ValueChanged<String> onOpen;

  /// All Projects… (11.6); null disables the row.
  final VoidCallback? onAllProjects;

  /// Project Settings… (11.7, the Project tab); null disables the row.
  final VoidCallback? onProjectSettings;

  /// Settings… (11.7, the tab shown last); null disables the row.
  final VoidCallback? onSettings;

  /// Opens and closes the menu; the capsule keeps its own when null.
  final ZsMenuController? menuController;

  /// The menu's gap below the capsule (`top:calc(100% + 10px)`, DS ui_kits/desktop/kit.css:41).
  static const double menuGap = 10;

  /// Where the menu opens, from the capsule's top left: [menuGap] below the capsule's `--chrome-h`, at its left edge
  /// (`top:calc(100% + 10px);left:0`, DS ui_kits/desktop/kit.css:41).
  static Offset menuPositionOf(BuildContext context) => Offset(0, ZsMetrics.of(context).chromeH + menuGap);

  /// The menu's width (`.zs-pm{width:300px}`, DS components/menus/menus.css:57).
  static const double menuWidth = 300;

  /// The bookmark column's limit (`.zs-pm .zs-menu-cmd{max-width:130px}`, DS components/menus/menus.css:62).
  static const double bookmarkMaxWidth = 130;

  /// The name's limit (`.zk-proj-name{max-width:220px}`, DS ui_kits/desktop/kit.css:39).
  static const double nameMaxWidth = 220;

  /// The bookmark column without a bookmark (design question (b)).
  static const noBookmark = '—';

  @override
  State<ProjectCapsule> createState() => _ProjectCapsuleState();
}

class _ProjectCapsuleState extends State<ProjectCapsule> {
  var _open = false;
  CalmHold? _hold;

  @override
  void dispose() {
    _hold?.release();
    super.dispose();
  }

  void _opened() {
    _hold?.release();
    _hold = ShellScope.maybeOf(context)?.openSurface();
    setState(() => _open = true);
  }

  void _closed() {
    _hold?.release();
    _hold = null;
    if (mounted) {
      setState(() => _open = false);
    }
  }

  void _toggle(ZsMenuController menu) {
    if (menu.isOpen) {
      menu.close();
    } else {
      menu.open(position: ProjectCapsule.menuPositionOf(context));
    }
  }

  List<ZsMenuEntry> _entries(ZsColors colors) {
    final String open = widget.project.path;
    return <ZsMenuEntry>[
      const ZsMenuHeader('Recent'),
      for (final (int i, ProjectEntry project) in widget.recent.indexed)
        ZsMenuItem(
          label: project.name,
          checked: project.path == open,
          radio: true,
          strong: project.path == open,
          dot: project.status?.colorIn(colors),
          dotLabel: project.status?.label,
          cmd: project.bookmark ?? ProjectCapsule.noBookmark,
          onSelected: () => widget.onOpen(project.path),
          identifier: 'project-menu-recent-$i',
        ),
      const ZsMenuSeparator(),
      ZsMenuItem(
        label: 'All Projects…',
        shortcut: '⇧⌘O',
        enabled: widget.onAllProjects != null,
        onSelected: widget.onAllProjects,
        identifier: 'project-menu-all',
      ),
      const ZsMenuSeparator(),
      ZsMenuItem(
        label: 'Project Settings…',
        enabled: widget.onProjectSettings != null,
        onSelected: widget.onProjectSettings,
        identifier: 'project-menu-project-settings',
      ),
      ZsMenuItem(
        label: 'Settings…',
        shortcut: '⌘,',
        enabled: widget.onSettings != null,
        onSelected: widget.onSettings,
        identifier: 'project-menu-settings',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final ProjectEntry project = widget.project;
    final ProjectStatus? status = project.status;
    return ZsMenuAnchor(
      entries: _entries(colors),
      controller: widget.menuController,
      width: ProjectCapsule.menuWidth,
      cmdMaxWidth: ProjectCapsule.bookmarkMaxWidth,
      // `<Menu aria-label="Project" …>` (DS components/menus/ProjectMenu.jsx:30): a name, no head.
      semanticLabel: 'Project',
      onOpen: _opened,
      onClose: _closed,
      identifier: 'project-menu',
      // The path tooltip sits inside the anchor, so the open menu — an element child of the anchor, focused while
      // open — is not inside it: focus within the menu never shows the path over the menu's Recent header.
      builder: (context, menu) => ZsTooltip(
        message: project.path,
        child: ZsControlCore(
          identifier: 'project-capsule',
          onActivate: () => _toggle(menu),
          selected: _open,
          shortcuts: const <ShortcutActivator, Intent>{SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent()},
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _toggle(menu);
                return null;
              },
            ),
          },
          semantics: SemanticsProperties(button: true, label: project.name, value: status?.label, expanded: _open),
          ring: ZsRingPlacement.outside,
          ringRadius: ZsMetrics.of(context).radiusIsland,
          builder: (context, state) => _CapsuleFace(project: project, state: state),
        ),
      ),
    );
  }
}

/// The capsule as it paints in [state].
class _CapsuleFace extends StatelessWidget {
  const _CapsuleFace({required this.project, required this.state});

  final ProjectEntry project;
  final ZsControlStatus state;

  /// `.zk-dot{width:7px;height:7px}` (DS ui_kits/desktop/kit.css:40).
  static const double _dot = 7;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final ProjectStatus? status = project.status;
    // As the icon buttons (ZsIconButton): `.zk-proj:hover` --fl-hover, `.is-on` --fl-on (DS ui_kits/desktop/kit.css:36-37).
    final Color fill = state.selected
        ? (state.pressed ? colors.flPress : (state.hovered ? colors.flOnHover : colors.flOn))
        : (state.pressed ? colors.flOn : (state.hovered ? colors.flHover : const Color(0x00000000)));
    // `.zk-proj-name{font-size:13px;font-weight:600;letter-spacing:var(--tracking-label)}` (DS ui_kits/desktop/kit.css:39).
    final TextStyle name = ZsType.cardSubject.copyWith(
      fontWeight: ZsType.fwSemibold,
      fontVariations: const <FontVariation>[FontVariation.weight(600)],
      fontSize: ZsType.fsBase,
      letterSpacing: ZsType.trackingLabel * ZsType.fsBase,
      color: colors.text,
    );
    return SizedBox(
      height: metrics.chromeH,
      child: ZsGlass(
        radius: metrics.radiusIsland,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: fill),
          duration: state.pressed ? motion.durInstant : motion.durHover,
          curve: motion.easeState,
          builder: (context, color, child) => DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(metrics.radiusIsland - ZsSurface.borderWidth),
            ),
            child: child,
          ),
          child: Padding(
            // `padding:0 12px 0 8px` (DS ui_kits/desktop/kit.css:35).
            padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: <Widget>[
                const ZsNamiMark(chip: true),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: ProjectCapsule.nameMaxWidth),
                  child: Text(project.name, style: name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis),
                ),
                if (status != null)
                  ZsTooltip(
                    message: status.label,
                    child: SizedBox.square(
                      dimension: _dot,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: status.colorIn(colors), shape: BoxShape.circle),
                      ),
                    ),
                  ),
                ZanshinIcon(ZI.chevronDown, size: ZsIconSize.md, color: colors.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

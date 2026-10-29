// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/projects/project_capsule.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart';
import 'package:zanshin/src/features/projects/projects_window.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../demo_projects_fakes.dart';

/// The "Projects" folder (Story 11.5): the project capsule in its states, and with the Project menu open — the menu
/// opens after the first frame, as Marionette cannot click it open in a review. Story 11.6 adds the Projects window's
/// content over the demo registry (`demo_projects_fakes.dart`) at 900 × 640 (680 × 440 for Narrow), scaled down when
/// the panel is smaller; each state is set up once the demo project is open, as Marionette cannot hover, drag a Finder
/// folder or type into the window in a review.
final projectsFolder = WidgetbookFolder(
  name: 'Projects',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Project capsule',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'States', builder: (context) => const _CapsuleStates()),
        WidgetbookUseCase(name: 'Menu open', builder: (context) => const _CapsuleMenuOpen()),
      ],
    ),
    WidgetbookComponent(
      name: 'Projects window',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'Tree', builder: (context) => const _Sized(DemoProjectsWindow())),
        WidgetbookUseCase(
          name: 'Search',
          builder: (context) => _Sized(DemoProjectsWindow(setup: (state, _) => state.search('backend'))),
        ),
        WidgetbookUseCase(
          name: 'No results',
          builder: (context) => _Sized(DemoProjectsWindow(setup: (state, _) => state.search('zzz'))),
        ),
        WidgetbookUseCase(name: 'Empty', builder: (context) => const _Sized(DemoProjectsWindow(empty: true))),
        WidgetbookUseCase(
          name: 'Narrow',
          builder: (context) => const _Sized(DemoProjectsWindow(), size: Size(680, 440)),
        ),
        WidgetbookUseCase(
          name: 'Convert offer',
          builder: (context) =>
              _Sized(DemoProjectsWindow(setup: (state, home) => state.addDirectory(demoGitRepository(home)))),
        ),
        WidgetbookUseCase(
          name: 'Clone form',
          builder: (context) {
            final bool busy = context.knobs.boolean(label: 'busy');
            return _Sized(
              DemoProjectsWindow(
                key: ValueKey<bool>(busy),
                busyClone: busy,
                setup: (state, _) {
                  state.openCloneForm(url: 'https://github.com/jj-vcs/jj.git');
                  if (busy) {
                    unawaited(state.submitClone());
                  }
                },
              ),
            );
          },
        ),
        WidgetbookUseCase(
          name: 'Drop hint',
          builder: (context) => _Sized(DemoProjectsWindow(setup: (state, _) => state.previewDrop())),
        ),
        WidgetbookUseCase(
          name: 'No identity',
          builder: (context) => _Sized(
            DemoProjectsWindow(
              identity: JjIdentity(name: '', email: ''),
            ),
          ),
        ),
        // Story 11.15: Work's row as its name field, and a row in hand over a group.
        WidgetbookUseCase(
          name: 'Rename group',
          builder: (context) => _Sized(DemoProjectsWindow(setup: (state, _) => state.renameGroup('g1'))),
        ),
        WidgetbookUseCase(
          name: 'Moving',
          builder: (context) => _Sized(DemoProjectsWindow(setup: (state, _) => _holdDrag(state))),
        ),
      ],
    ),
  ],
);

/// Presses a mouse on the row "workers…" and moves it to the middle of PERSONAL two frames later, never releasing
/// it, so the ghost and the drop look stay on screen (Marionette cannot drag). Nothing happens when a row is missing.
void _holdDrag(ProjectsWindowState state) {
  void nextFrame(VoidCallback then) => WidgetsBinding.instance.addPostFrameCallback((_) => then());
  nextFrame(
    () => nextFrame(() {
      if (!state.mounted) {
        return;
      }
      final Offset? from = _textCentre(state.context, (text) => text.startsWith('workers'));
      final Offset? to = _textCentre(state.context, (text) => text == 'PERSONAL');
      if (from == null || to == null) {
        return;
      }
      final int viewId = View.of(state.context).viewId;
      const pointer = 0x11500;
      const device = 0x11500;
      final GestureBinding gestures = GestureBinding.instance
        ..handlePointerEvent(
          PointerAddedEvent(viewId: viewId, device: device, kind: PointerDeviceKind.mouse, position: from),
        )
        ..handlePointerEvent(
          PointerDownEvent(
            viewId: viewId,
            pointer: pointer,
            device: device,
            kind: PointerDeviceKind.mouse,
            position: from,
          ),
        );
      Offset last = from;
      for (final at in <Offset>[from + const Offset(0, 6), to, to + const Offset(1, 0)]) {
        // The drag moves its ghost by each event's delta, which a synthesised event must carry itself.
        gestures.handlePointerEvent(
          PointerMoveEvent(
            viewId: viewId,
            pointer: pointer,
            device: device,
            kind: PointerDeviceKind.mouse,
            position: at,
            delta: at - last,
          ),
        );
        last = at;
      }
      // Once the use case is gone, the held pointer is cancelled, so its ghost does not outlive it.
      void release() => nextFrame(() {
        if (state.mounted) {
          release();
          return;
        }
        gestures
          ..handlePointerEvent(
            PointerCancelEvent(viewId: viewId, pointer: pointer, device: device, kind: PointerDeviceKind.mouse),
          )
          ..handlePointerEvent(PointerRemovedEvent(viewId: viewId, device: device, kind: PointerDeviceKind.mouse));
      });
      release();
    }),
  );
}

/// The global centre of the first [Text] under [root] whose text [matches], or null.
Offset? _textCentre(BuildContext root, bool Function(String text) matches) {
  Offset? found;
  void visit(Element element) {
    if (found != null) {
      return;
    }
    final Widget widget = element.widget;
    final RenderObject? box = element.renderObject;
    if (widget is Text && matches(widget.data ?? '') && box is RenderBox && box.hasSize) {
      found = box.localToGlobal(box.size.center(Offset.zero));
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildElements(visit);
  return found;
}

/// [child] at [size] (the Projects window's default 900 × 640), centred and scaled down to fit the panel.
class _Sized extends StatelessWidget {
  const _Sized(this.child, {this.size = const Size(900, 640)});

  final Widget child;
  final Size size;

  @override
  Widget build(BuildContext context) => Center(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox.fromSize(size: size, child: child),
    ),
  );
}

/// The demo registry: the open project and four others across the statuses, one without a bookmark (names from the
/// floating export's design/data.js:305-338; Claude's proposal for the demo).
final demoProjects = <ProjectEntry>[
  ProjectEntry(
    path: '/Users/me/code/work/mobile/myapp',
    name: 'MyApp',
    status: ProjectStatus.dirty,
    bookmark: 'feature/new-ui',
    lastOpened: DateTime.utc(2026, 10, 18, 9),
  ),
  ProjectEntry(
    path: '/Users/me/code/work/backend/api-server',
    name: 'api-server',
    status: ProjectStatus.clean,
    bookmark: 'develop',
    lastOpened: DateTime.utc(2026, 10, 18, 8),
  ),
  ProjectEntry(
    path: '/Users/me/code/work/backend/workers',
    name: 'workers',
    status: ProjectStatus.conflict,
    bookmark: 'fix/queue-retries-after-a-dropped-connection',
    lastOpened: DateTime.utc(2026, 10, 17),
  ),
  ProjectEntry(
    path: '/Users/me/code/work/mobile/design-kit',
    name: 'design-kit',
    status: ProjectStatus.stale,
    lastOpened: DateTime.utc(2026, 10, 13),
  ),
  ProjectEntry(
    path: '/Users/me/code/work/infra',
    name: 'infra',
    bookmark: 'main',
    lastOpened: DateTime.utc(2026, 10, 11),
  ),
];

/// The demo's capsule over [demoProjects]; its rows open nothing.
ProjectCapsule demoCapsule({ProjectEntry? project, ZsMenuController? menuController}) => ProjectCapsule(
  project: project ?? demoProjects.first,
  recent: demoProjects,
  onOpen: (_) {},
  menuController: menuController,
);

/// The capsule in each state: clean, dirty, ahead, behind, diverged, conflict, stale, no status and a name past
/// 220 px.
class _CapsuleStates extends StatelessWidget {
  const _CapsuleStates();

  @override
  Widget build(BuildContext context) {
    final ProjectEntry open = demoProjects.first;
    final states = <ProjectEntry>[
      open.copyWith(status: ProjectStatus.clean),
      open,
      open.copyWith(status: ProjectStatus.ahead),
      open.copyWith(status: ProjectStatus.behind),
      open.copyWith(status: ProjectStatus.diverged),
      open.copyWith(status: ProjectStatus.conflict),
      open.copyWith(status: ProjectStatus.stale),
      open.copyWith(status: null),
      open.copyWith(name: 'a-project-whose-name-is-far-too-long-for-the-capsule'),
    ];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: <Widget>[for (final ProjectEntry project in states) demoCapsule(project: project)],
      ),
    );
  }
}

/// The capsule at the bar's PLACE position with the Project menu open.
class _CapsuleMenuOpen extends StatefulWidget {
  const _CapsuleMenuOpen();

  @override
  State<_CapsuleMenuOpen> createState() => _CapsuleMenuOpenState();
}

class _CapsuleMenuOpenState extends State<_CapsuleMenuOpen> {
  final _menu = ZsMenuController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _menu.open(position: ProjectCapsule.menuPositionOf(context));
      }
    });
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: EdgeInsets.fromLTRB(ZsMetrics.of(context).chromeFirstX, ZsMetrics.of(context).chromeBarY, 0, 0),
      child: demoCapsule(menuController: _menu),
    ),
  );
}

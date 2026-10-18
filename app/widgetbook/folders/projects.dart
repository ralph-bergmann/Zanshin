// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/projects/project_capsule.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The "Projects" folder (Story 11.5): the project capsule in its states, and with the Project menu open — the menu
/// opens after the first frame, as Marionette cannot click it open in a review.
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
  ],
);

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

/// The capsule in each state: clean, dirty, conflict, stale, no status and a name past 220 px.
class _CapsuleStates extends StatelessWidget {
  const _CapsuleStates();

  @override
  Widget build(BuildContext context) {
    final ProjectEntry open = demoProjects.first;
    final states = <ProjectEntry>[
      open.copyWith(status: ProjectStatus.clean),
      open,
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

// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The "Controls" folder: per control family a "State matrix" (rows the variants, columns the states its `.d.ts`
/// lists, interaction states forced through a `WidgetStatesController`; DS components/controls/state-matrix.card.html)
/// and an "Interactive" use case (the live control, with knobs where they help).
final controlsFolder = WidgetbookFolder(
  name: 'Controls',
  children: <WidgetbookNode>[
    _family('Button', _buttonMatrix, _buttonInteractive),
    _family('IconButton', _iconButtonMatrix, _iconButtonInteractive),
    _family('Badge', _badgeMatrix, _badgeInteractive),
    _family('Switch', _switchMatrix, _switchInteractive),
    _family('Checkbox', _checkboxMatrix, _checkboxInteractive),
    _family('Radio', _radioMatrix, _radioInteractive),
    _family('Segmented', _segmentedMatrix, _segmentedInteractive),
    _family('Slider', _sliderMatrix, _sliderInteractive),
    _family('TextField', _textFieldMatrix, _textFieldInteractive),
    _family('SearchField', _searchFieldMatrix, _searchFieldInteractive),
    _family('Select', _selectMatrix, _selectInteractive),
    _family('Menu', _menuMatrix, _menuInteractive),
    _family('Field list', _fieldListMatrix, _fieldListInteractive),
    _family('Tooltip', _tooltipMatrix, _tooltipInteractive),
    _family('Popover', _popoverMatrix, _popoverInteractive),
    _family('ConfirmDialog', _confirmMatrix, _confirmInteractive),
    _family('ScrollArea', _scrollAreaMatrix, _scrollAreaInteractive),
    _family('Chip', _chipMatrix, _chipInteractive),
    _family('Link', _linkMatrix, _linkInteractive),
    _family('Disclosure', _disclosureMatrix, _disclosureInteractive),
    _family('Spinner', _spinnerMatrix, _spinnerInteractive),
    _family('ProgressBar', _progressMatrix, _progressInteractive),
    _family('Skeleton', _skeletonMatrix, _skeletonInteractive),
    _family('Presence', _presenceMatrix, _presenceInteractive),
    _family('Kbd', _kbdMatrix, _kbdInteractive),
  ],
);

WidgetbookComponent _family(String name, WidgetBuilder matrix, WidgetBuilder interactive) => WidgetbookComponent(
  name: name,
  useCases: <WidgetbookUseCase>[
    WidgetbookUseCase(name: 'State matrix', builder: matrix),
    WidgetbookUseCase(name: 'Interactive', builder: interactive),
  ],
);

// ---- the state matrix ----

/// A column of the DS state matrix (DS components/controls/state-matrix.card.html: `COLS`, `HEAD`).
enum MatrixState {
  rest('Rest'),
  hover('Hover'),
  press('Pressed'),
  focus('Focus'),
  on('On / sel.'),
  mixed('Mixed'),
  disabled('Disabled'),
  error('Error'),
  busy('Busy'),
  readOnly('Read-only');

  const MatrixState(this.label);

  /// The column heading.
  final String label;

  /// The interaction states a cell's controller is forced to (a forced `focused` counts as focus-visible).
  Set<WidgetState> get forced => switch (this) {
    MatrixState.hover => <WidgetState>{WidgetState.hovered},
    MatrixState.press => <WidgetState>{WidgetState.pressed},
    MatrixState.focus => <WidgetState>{WidgetState.focused},
    _ => <WidgetState>{},
  };
}

/// One cell of the matrix: its [state], the [states] controller forced to it, and [own] for further notifiers the
/// cell disposes with itself.
abstract interface class MatrixCell {
  /// The column.
  MatrixState get state;

  /// The controller forced to [state]'s interaction states.
  WidgetStatesController get states;

  /// Keeps [notifier] until the cell goes away.
  T own<T extends ChangeNotifier>(T notifier);
}

/// One row of the matrix: a variant named [name] ([spec] under it) shown in the [states] it has.
class MatrixRow {
  /// A row.
  const MatrixRow(this.name, this.spec, this.states, this.build);

  /// The control family.
  final String name;

  /// The variant.
  final String spec;

  /// The columns this row fills; the others read "—".
  final List<MatrixState> states;

  /// The control in a cell.
  final Widget Function(MatrixCell cell) build;
}

/// The DS state matrix: a 150 px name column, then one column of [columnWidth] per state any row has.
class StateMatrix extends StatelessWidget {
  /// The matrix of [rows].
  const StateMatrix(this.rows, {this.columnWidth = 180, super.key});

  /// The variants.
  final List<MatrixRow> rows;

  /// Every state column's width.
  final double columnWidth;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final columns = <MatrixState>[
      for (final MatrixState state in MatrixState.values)
        if (rows.any((row) => row.states.contains(state))) state,
    ];
    final TextStyle head = ZsType.capsLabel.copyWith(color: colors.textDim);
    Widget pad(Widget child) => Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8), child: child);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          columnWidths: const <int, TableColumnWidth>{0: FixedColumnWidth(150)},
          defaultColumnWidth: FixedColumnWidth(columnWidth),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            top: BorderSide(color: colors.borderStrong),
            horizontalInside: BorderSide(color: colors.border),
            bottom: BorderSide(color: colors.border),
          ),
          children: <TableRow>[
            TableRow(
              children: <Widget>[
                pad(Text(ZsType.caps('Control'), style: head)),
                for (final MatrixState state in columns) pad(Text(ZsType.caps(state.label), style: head)),
              ],
            ),
            for (final MatrixRow row in rows)
              TableRow(
                children: <Widget>[
                  pad(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: <Widget>[
                        Text(
                          row.name,
                          style: ZsType.control.copyWith(color: colors.text, fontWeight: FontWeight.w500),
                        ),
                        Text(row.spec, style: ZsType.meta.copyWith(color: colors.textFaint)),
                      ],
                    ),
                  ),
                  for (final MatrixState state in columns)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Center(
                        child: row.states.contains(state)
                            ? Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                // A control wider than its column (a long label, a large text scale) shrinks to fit.
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: _MatrixCell(state: state, build: row.build),
                                ),
                              )
                            : Text('—', style: ZsType.meta.copyWith(color: colors.textFaint)),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MatrixCell extends StatefulWidget {
  const _MatrixCell({required this.state, required this.build});

  final MatrixState state;
  final Widget Function(MatrixCell cell) build;

  @override
  State<_MatrixCell> createState() => _MatrixCellState();
}

class _MatrixCellState extends State<_MatrixCell> implements MatrixCell {
  final _owned = <ChangeNotifier>[];

  @override
  late final WidgetStatesController states = own(WidgetStatesController(widget.state.forced));

  @override
  MatrixState get state => widget.state;

  @override
  T own<T extends ChangeNotifier>(T notifier) {
    _owned.add(notifier);
    return notifier;
  }

  @override
  void dispose() {
    for (final ChangeNotifier notifier in _owned) {
      notifier.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.build(this);
}

/// A live control centred on the canvas.
Widget _live(Widget child) => Center(
  child: Padding(padding: const EdgeInsets.all(24), child: child),
);

/// A control with state of its own: [build] gets the value and a setter.
class _Stateful<T> extends StatefulWidget {
  const _Stateful({required this.initial, required this.build});

  final T initial;
  final Widget Function(T value, ValueChanged<T> set) build;

  @override
  State<_Stateful<T>> createState() => _StatefulState<T>();
}

class _StatefulState<T> extends State<_Stateful<T>> {
  late T _value = widget.initial;

  @override
  Widget build(BuildContext context) => widget.build(_value, (value) => setState(() => _value = value));
}

const _interaction = <MatrixState>[MatrixState.rest, MatrixState.hover, MatrixState.press, MatrixState.focus];

VoidCallback? _enabled(MatrixCell cell) => cell.state == MatrixState.disabled ? null : () {};

// ---- Button ----

Widget _buttonMatrix(BuildContext context) {
  MatrixRow row(String spec, String label, ZsButtonVariant variant, {bool busy = false}) => MatrixRow(
    'Button',
    spec,
    <MatrixState>[..._interaction, MatrixState.disabled, if (busy) MatrixState.busy],
    (cell) => ZsButton(
      label: label,
      variant: variant,
      busy: cell.state == MatrixState.busy,
      onPressed: _enabled(cell),
      statesController: cell.states,
    ),
  );
  return StateMatrix(<MatrixRow>[
    row('default', 'Describe…', ZsButtonVariant.quiet, busy: true),
    row('primary · gold', 'Commit', ZsButtonVariant.primary, busy: true),
    row('ghost', 'Cancel', ZsButtonVariant.ghost),
    row('danger · quiet', 'Abandon', ZsButtonVariant.danger),
    row('destructive · filled', 'Clear history', ZsButtonVariant.destructive, busy: true),
    for (final ZsButtonSize size in ZsButtonSize.values)
      MatrixRow(
        'Button',
        '${size.name} · icon',
        const <MatrixState>[MatrixState.rest],
        (cell) => ZsButton(label: 'New change', icon: ZI.plus, size: size, onPressed: () {}),
      ),
  ]);
}

Widget _buttonInteractive(BuildContext context) {
  final String label = context.knobs.string(label: 'label', initialValue: 'Commit');
  final ZsButtonVariant variant = context.knobs.object.dropdown(
    label: 'variant',
    options: ZsButtonVariant.values,
    initialOption: ZsButtonVariant.primary,
    labelBuilder: (value) => value.name,
  );
  final ZsButtonSize size = context.knobs.object.dropdown(
    label: 'size',
    options: ZsButtonSize.values,
    labelBuilder: (value) => value.name,
  );
  final bool icon = context.knobs.boolean(label: 'icon');
  final bool busy = context.knobs.boolean(label: 'busy');
  final String? reason = context.knobs.stringOrNull(label: 'disabled reason', initialValue: 'Nothing to commit');
  return _live(
    ZsButton(
      label: label,
      variant: variant,
      size: size,
      icon: icon ? ZI.plus : null,
      busy: busy,
      disabledReason: reason,
      onPressed: () {},
      identifier: 'button',
    ),
  );
}

// ---- IconButton ----

Widget _iconButtonMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  for (final ZsIconButtonSize size in ZsIconButtonSize.values)
    MatrixRow(
      'IconButton',
      size.name,
      const <MatrixState>[..._interaction, MatrixState.on, MatrixState.disabled],
      (cell) => ZsIconButton(
        icon: ZI.bookmark,
        label: 'Bookmarks',
        size: size,
        active: cell.state == MatrixState.on,
        onPressed: _enabled(cell),
        statesController: cell.states,
      ),
    ),
  MatrixRow(
    'IconButton',
    'md · badge',
    const <MatrixState>[..._interaction, MatrixState.on, MatrixState.disabled],
    (cell) => ZsIconButton(
      icon: ZI.conflict,
      label: 'Conflicts',
      badge: 3,
      active: cell.state == MatrixState.on,
      onPressed: _enabled(cell),
      statesController: cell.states,
    ),
  ),
]);

Widget _iconButtonInteractive(BuildContext context) {
  final ZsIconButtonSize size = context.knobs.object.dropdown(
    label: 'size',
    options: ZsIconButtonSize.values,
    initialOption: ZsIconButtonSize.md,
    labelBuilder: (value) => value.name,
  );
  final int badge = context.knobs.int.slider(label: 'badge', max: 120);
  return _live(
    _Stateful<bool>(
      initial: false,
      build: (active, set) => ZsIconButton(
        icon: ZI.bookmark,
        label: 'Bookmarks',
        size: size,
        active: active,
        badge: badge == 0 ? null : badge,
        onPressed: () => set(!active),
        identifier: 'icon-button',
      ),
    ),
  );
}

// ---- Badge ----

Widget _badgeMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  for (final ZsBadgeTone tone in ZsBadgeTone.values) ...<MatrixRow>[
    MatrixRow('Badge', '${tone.name} · 3', const <MatrixState>[
      MatrixState.rest,
    ], (cell) => ZsBadge(count: 3, tone: tone)),
    MatrixRow(
      'Badge',
      '${tone.name} · over 99',
      const <MatrixState>[MatrixState.rest],
      (cell) => ZsBadge(count: 120, tone: tone),
    ),
  ],
]);

Widget _badgeInteractive(BuildContext context) {
  final int count = context.knobs.int.slider(label: 'count', initialValue: 3, max: 150);
  final ZsBadgeTone tone = context.knobs.object.dropdown(
    label: 'tone',
    options: ZsBadgeTone.values,
    labelBuilder: (value) => value.name,
  );
  return _live(ZsBadge(count: count, tone: tone, identifier: 'badge'));
}

// ---- Switch ----

Widget _switchMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'Switch',
    '30 × 18',
    const <MatrixState>[..._interaction, MatrixState.on, MatrixState.disabled],
    (cell) => ZsSwitch(
      value: cell.state == MatrixState.on,
      onChanged: cell.state == MatrixState.disabled ? null : (_) {},
      label: 'Show elided',
      statesController: cell.states,
    ),
  ),
]);

Widget _switchInteractive(BuildContext context) => _live(
  _Stateful<bool>(
    initial: true,
    build: (value, set) => ZsSwitch(value: value, onChanged: set, label: 'Show elided', identifier: 'switch'),
  ),
);

// ---- Checkbox ----

Widget _checkboxMatrix(BuildContext context) {
  bool? value(MatrixCell cell) => switch (cell.state) {
    MatrixState.on => true,
    MatrixState.mixed => null,
    _ => false,
  };
  return StateMatrix(<MatrixRow>[
    MatrixRow(
      'Checkbox',
      '15 · accent',
      const <MatrixState>[..._interaction, MatrixState.on, MatrixState.mixed, MatrixState.disabled],
      (cell) => ZsCheckbox(
        value: value(cell),
        tristate: true,
        onChanged: cell.state == MatrixState.disabled ? null : (_) {},
        label: 'Select',
        statesController: cell.states,
      ),
    ),
    MatrixRow(
      'Checkbox',
      '13 · Viewed',
      const <MatrixState>[MatrixState.rest, MatrixState.hover, MatrixState.on],
      (cell) => ZsCheckbox(
        value: value(cell),
        size: ZsCheckboxSize.sm,
        tone: ZsCheckboxTone.add,
        onChanged: (_) {},
        label: 'Viewed',
        statesController: cell.states,
      ),
    ),
  ]);
}

Widget _checkboxInteractive(BuildContext context) {
  final bool tristate = context.knobs.boolean(label: 'tristate');
  return _live(
    _Stateful<bool?>(
      initial: false,
      build: (value, set) => ZsCheckbox(
        value: value,
        tristate: tristate,
        onChanged: (next) => set(tristate && value == true ? null : next),
        label: 'Viewed',
        identifier: 'checkbox',
      ),
    ),
  );
}

// ---- Radio ----

Widget _radioMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'Radio',
    '15',
    const <MatrixState>[..._interaction, MatrixState.on, MatrixState.disabled],
    (cell) => RadioGroup<String>(
      groupValue: cell.state == MatrixState.on ? 'origin' : null,
      onChanged: (_) {},
      child: ZsRadio<String>(
        value: 'origin',
        enabled: cell.state != MatrixState.disabled,
        statesController: cell.states,
      ),
    ),
  ),
]);

Widget _radioInteractive(BuildContext context) => _live(
  _Stateful<String>(
    initial: 'merge',
    build: (value, set) => ZsRadioGroup<String>(
      label: 'Strategy',
      value: value,
      onChanged: set,
      identifier: 'radio',
      options: const <ZsRadioOption<String>>[
        ZsRadioOption<String>(value: 'merge', label: 'Merge', hint: 'A merge commit with both parents'),
        ZsRadioOption<String>(value: 'rebase', label: 'Rebase'),
        ZsRadioOption<String>(value: 'squash', label: 'Squash', disabledReason: 'Only one change to land'),
      ],
    ),
  ),
);

// ---- Segmented ----

const _density = <ZsSegment<String>>[
  ZsSegment<String>(value: 'free', label: 'Free'),
  ZsSegment<String>(value: 'compact', label: 'Compact'),
];

Widget _segmentedMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'Segmented',
    'state on “Compact”',
    const <MatrixState>[..._interaction, MatrixState.on, MatrixState.disabled],
    (cell) => ZsSegmented<String>(
      segments: cell.state == MatrixState.disabled
          ? const <ZsSegment<String>>[
              ZsSegment<String>(value: 'free', label: 'Free'),
              ZsSegment<String>(value: 'compact', label: 'Compact', disabledReason: 'Needs a wider window'),
            ]
          : _density,
      value: cell.state == MatrixState.on ? 'compact' : 'free',
      onChanged: (_) {},
      statesControllers: <WidgetStatesController>[cell.own(WidgetStatesController()), cell.states],
    ),
  ),
  for (final ZsSegmentedVariant variant in ZsSegmentedVariant.values)
    for (final ZsSegmentedSize size in ZsSegmentedSize.values)
      MatrixRow(
        'Segmented',
        '${variant.name} · ${size.name}',
        const <MatrixState>[MatrixState.rest],
        (cell) => ZsSegmented<String>(
          segments: _density,
          value: 'compact',
          onChanged: (_) {},
          variant: variant,
          size: size,
        ),
      ),
]);

Widget _segmentedInteractive(BuildContext context) {
  final ZsSegmentedVariant variant = context.knobs.object.dropdown(
    label: 'variant',
    options: ZsSegmentedVariant.values,
    labelBuilder: (value) => value.name,
  );
  return _live(
    _Stateful<String>(
      initial: 'graph',
      build: (value, set) => ZsSegmented<String>(
        label: 'View',
        variant: variant,
        value: value,
        onChanged: set,
        identifier: 'segmented',
        segments: const <ZsSegment<String>>[
          ZsSegment<String>(value: 'graph', label: 'Graph'),
          ZsSegment<String>(value: 'list', label: 'List'),
          ZsSegment<String>(value: 'ops', label: 'Operations'),
        ],
      ),
    ),
  );
}

// ---- Slider ----

Widget _sliderMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'Slider',
    'thumb',
    const <MatrixState>[..._interaction, MatrixState.disabled],
    (cell) => ZsSlider(
      value: 40,
      onChanged: (_) {},
      unit: 'px',
      label: 'Card width',
      disabledReason: cell.state == MatrixState.disabled ? 'Fixed in compact mode' : null,
      statesController: cell.states,
    ),
  ),
  MatrixRow(
    'Slider',
    'ticks',
    const <MatrixState>[MatrixState.rest],
    (cell) => ZsSlider(value: 50, onChanged: (_) {}, step: 25, ticks: true, label: 'Spacing'),
  ),
]);

Widget _sliderInteractive(BuildContext context) {
  final bool ticks = context.knobs.boolean(label: 'ticks');
  return _live(
    _Stateful<double>(
      initial: 240,
      build: (value, set) => ZsSlider(
        value: value,
        onChanged: set,
        min: 180,
        max: 320,
        step: ticks ? 20 : 1,
        ticks: ticks,
        unit: 'px',
        label: 'Card width',
        identifier: 'slider',
      ),
    ),
  );
}

// ---- TextField ----

Widget _textFieldMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'TextField',
    'sm 30',
    const <MatrixState>[
      MatrixState.rest,
      MatrixState.hover,
      MatrixState.focus,
      MatrixState.disabled,
      MatrixState.error,
      MatrixState.readOnly,
    ],
    (cell) => SizedBox(
      width: 160,
      child: ZsTextField(
        placeholder: 'Summary',
        controller: cell.state == MatrixState.readOnly ? cell.own(ZsTextEditingController(text: 'feat: swipe')) : null,
        enabled: cell.state != MatrixState.disabled,
        error: cell.state == MatrixState.error ? 'Required' : null,
        readOnly: cell.state == MatrixState.readOnly,
        statesController: cell.states,
      ),
    ),
  ),
  for (final ZsTextFieldSize size in ZsTextFieldSize.values)
    MatrixRow(
      'TextField',
      size.name,
      const <MatrixState>[MatrixState.rest],
      (cell) => SizedBox(
        width: 160,
        child: ZsTextField(size: size, placeholder: 'Bookmark name'),
      ),
    ),
  MatrixRow(
    'TextField',
    'multiline · mono',
    const <MatrixState>[MatrixState.rest],
    (cell) => const SizedBox(
      width: 160,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: <Widget>[
          ZsTextField(multiline: true, placeholder: 'Details'),
          ZsTextField(mono: true, placeholder: 'trunk()..@'),
        ],
      ),
    ),
  ),
]);

Widget _textFieldInteractive(BuildContext context) {
  final String? error = context.knobs.stringOrNull(label: 'error', initialValue: 'Unknown function “trunks”');
  final bool readOnly = context.knobs.boolean(label: 'read-only');
  final bool multiline = context.knobs.boolean(label: 'multiline');
  final bool mono = context.knobs.boolean(label: 'mono', initialValue: true);
  return _live(
    SizedBox(
      width: 320,
      child: ZsTextField(
        label: 'Revset',
        placeholder: 'trunk()..@',
        error: error,
        readOnly: readOnly,
        multiline: multiline,
        mono: mono,
        identifier: 'text-field',
      ),
    ),
  );
}

// ---- SearchField ----

Widget _searchFieldMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'SearchField',
    '30 · key cap',
    const <MatrixState>[MatrixState.rest, MatrixState.hover, MatrixState.focus],
    (cell) => SizedBox(
      width: 160,
      child: ZsSearchField(shortcutLabel: '/', statesController: cell.states),
    ),
  ),
]);

Widget _searchFieldInteractive(BuildContext context) => _live(
  const SizedBox(
    width: 280,
    child: ZsSearchField(placeholder: 'Search projects', shortcutLabel: '/', identifier: 'search-field'),
  ),
);

// ---- Select ----

const _remotes = <ZsSelectEntry<String>>[
  ZsSelectHeader<String>('Remotes'),
  ZsSelectOption<String>(value: 'origin', label: 'origin'),
  ZsSelectOption<String>(value: 'upstream', label: 'upstream'),
  ZsSelectOption<String>(value: 'fork', label: 'fork', enabled: false),
  ZsSelectSeparator<String>(),
  ZsSelectOption<String>(value: 'all', label: 'All remotes'),
];

Widget _selectMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'Select',
    'pop-up button',
    const <MatrixState>[..._interaction, MatrixState.disabled],
    (cell) => ZsSelect<String>(
      options: _remotes,
      value: 'origin',
      onChanged: (_) {},
      label: 'Fetch from',
      disabledReason: cell.state == MatrixState.disabled ? 'No remote configured' : null,
      statesController: cell.states,
    ),
  ),
]);

Widget _selectInteractive(BuildContext context) {
  final ZsSelectPlacement placement = context.knobs.object.dropdown(
    label: 'placement',
    options: ZsSelectPlacement.values,
    labelBuilder: (value) => value.name,
  );
  return _live(
    _Stateful<String>(
      initial: 'origin',
      build: (value, set) => ZsSelect<String>(
        options: _remotes,
        value: value,
        onChanged: set,
        label: 'Fetch from',
        placement: placement,
        identifier: 'select',
      ),
    ),
  );
}

// ---- Menu ----

List<ZsMenuEntry> _menuEntries() => const <ZsMenuEntry>[
  ZsMenuHeader('Change'),
  ZsMenuItem(label: 'New change on top', icon: ZI.newOnTop, cmd: 'jj new', shortcut: '⌘N'),
  ZsMenuItem(label: 'Edit', icon: ZI.change, cmd: 'jj edit'),
  ZsMenuItem(label: 'Describe…', icon: ZI.describe, shortcut: '⌘D'),
  ZsMenuItem(label: 'Squash into parent', icon: ZI.squash, enabled: false),
  ZsMenuSeparator(),
  ZsMenuHeader('Show'),
  ZsMenuItem(label: 'Elided changes', checked: true),
  ZsMenuItem(label: 'Free', radio: true, checked: true),
  ZsMenuItem(label: 'Compact', radio: true, checked: false),
  ZsMenuItem(
    label: 'Copy',
    submenu: <ZsMenuEntry>[
      ZsMenuItem(label: 'Change id', mono: true, text: 'change id'),
      ZsMenuItem(label: 'Commit id', mono: true, text: 'commit id'),
    ],
  ),
  ZsMenuSeparator(),
  ZsMenuItem(label: 'Abandon', icon: ZI.abandon, danger: true, cmd: 'jj abandon'),
];

/// Every kind of row in one menu, opened when the use case shows.
Widget _menuMatrix(BuildContext context) => const _MenuStage(child: _OpenMenu());

/// The open menu's anchor, up and left so the panel and its submenu fit.
class _MenuStage extends StatelessWidget {
  const _MenuStage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: const Alignment(-.6, -.8),
    child: child,
  );
}

class _OpenMenu extends StatefulWidget {
  const _OpenMenu();

  @override
  State<_OpenMenu> createState() => _OpenMenuState();
}

class _OpenMenuState extends State<_OpenMenu> {
  final _menu = ZsMenuController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _menu.open();
      }
    });
  }

  @override
  Widget build(BuildContext context) => ZsMenuAnchor(
    controller: _menu,
    entries: _menuEntries(),
    subject: 'feat(onboarding): swipe gestures',
    identifier: 'menu',
    builder: (context, controller) => ZsButton(label: 'Actions', onPressed: controller.open),
  );
}

Widget _menuInteractive(BuildContext context) {
  final bool blink = context.knobs.boolean(label: 'blink', initialValue: true);
  return _live(
    ZsMenuAnchor(
      entries: _menuEntries(),
      subject: 'feat(onboarding): swipe gestures',
      blink: blink,
      identifier: 'menu',
      builder: (context, controller) => ZsButton(label: 'Actions', icon: ZI.more, onPressed: controller.open),
    ),
  );
}

// ---- Field list ----

Widget _fieldListMatrix(BuildContext context) {
  MatrixRow row(String spec, {bool shown = false, bool danger = false}) => MatrixRow(
    'Field list row',
    spec,
    const <MatrixState>[MatrixState.rest, MatrixState.on],
    (cell) => SizedBox(
      width: 170,
      child: ZsFieldListRow(
        active: cell.state == MatrixState.on,
        shown: shown,
        danger: danger,
        icon: danger ? ZI.abandon : ZI.bookmark,
        onPressed: () {},
        child: Text(danger ? 'Delete' : 'main'),
      ),
    ),
  );
  return StateMatrix(<MatrixRow>[row('plain'), row('shown · check', shown: true), row('danger', danger: true)]);
}

Widget _fieldListInteractive(BuildContext context) => _live(const SizedBox(width: 280, child: _FieldListDemo()));

class _FieldListDemo extends StatefulWidget {
  const _FieldListDemo();

  @override
  State<_FieldListDemo> createState() => _FieldListDemoState();
}

class _FieldListDemoState extends State<_FieldListDemo> {
  static const _bookmarks = <String>['main', 'feat/onboarding', 'fix/crash', 'release/2.4'];
  final _list = ZsFieldListController();
  var _picked = 'main';

  @override
  void initState() {
    super.initState();
    _list.attach(count: _bookmarks.length, enabled: (_) => true, onActivate: _pick);
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  void _pick(int index) => setState(() => _picked = _bookmarks[index]);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: <Widget>[
      ZsSearchField(placeholder: 'Move to bookmark', fieldList: _list, identifier: 'field-list-search'),
      ListenableBuilder(
        listenable: _list,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < _bookmarks.length; i++)
              ZsFieldListRow(
                active: _list.active == i,
                shown: _bookmarks[i] == _picked,
                icon: ZI.bookmark,
                onPressed: () => _pick(i),
                semanticLabel: _bookmarks[i],
                child: Text(_bookmarks[i]),
              ),
          ],
        ),
      ),
    ],
  );
}

// ---- Tooltip ----

// The tooltips wrap a text button: an icon button brings its own tooltip, which would take the hover (the innermost
// `RawTooltip` wins) and show only the button's name.

Widget _tooltipMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  for (final ZsTooltipPlacement placement in ZsTooltipPlacement.values)
    MatrixRow(
      'Tooltip',
      '${placement.name} · hover the button',
      const <MatrixState>[MatrixState.rest],
      (cell) => ZsTooltip(
        message: 'Fetch',
        cmd: 'jj git fetch',
        shortcut: '⇧⌘F',
        placement: placement,
        child: ZsButton(icon: ZI.fetch, label: 'Fetch', onPressed: () {}),
      ),
    ),
]);

Widget _tooltipInteractive(BuildContext context) {
  final String message = context.knobs.string(label: 'message', initialValue: 'Push');
  final String? cmd = context.knobs.stringOrNull(label: 'command', initialValue: 'jj git push');
  final String? shortcut = context.knobs.stringOrNull(label: 'shortcut', initialValue: '⇧⌘P');
  final ZsTooltipPlacement placement = context.knobs.object.dropdown(
    label: 'placement',
    options: ZsTooltipPlacement.values,
    labelBuilder: (value) => value.name,
  );
  return _live(
    ZsTooltip(
      message: message,
      cmd: cmd,
      shortcut: shortcut,
      placement: placement,
      identifier: 'tooltip',
      child: ZsButton(icon: ZI.push, label: message, onPressed: () {}),
    ),
  );
}

// ---- Popover ----

Widget _popoverMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'Option link',
    'the way out',
    _interaction,
    (cell) => SizedBox(
      width: 170,
      child: ZsOptionLink(label: 'More', action: 'Settings…', onPressed: () {}, statesController: cell.states),
    ),
  ),
]);

Widget _popoverInteractive(BuildContext context) => _live(
  ZsPopover(
    label: 'View',
    identifier: 'popover',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 2,
      children: <Widget>[
        const ZsPopoverHeader('View'),
        ZsOptionRow(
          label: 'Show elided changes',
          child: _Stateful<bool>(
            initial: true,
            build: (value, set) => ZsSwitch(value: value, onChanged: set, label: 'Show elided changes'),
          ),
        ),
        ZsOptionRow(
          label: 'Density',
          child: _Stateful<String>(
            initial: 'free',
            build: (value, set) => ZsSegmented<String>(
              segments: _density,
              value: value,
              onChanged: set,
              label: 'Density',
              size: ZsSegmentedSize.sm,
            ),
          ),
        ),
        ZsOptionRow(
          label: 'Card width',
          child: _Stateful<double>(
            initial: 240,
            build: (value, set) => ZsSlider(value: value, onChanged: set, min: 180, max: 320, label: 'Card width'),
          ),
        ),
        const ZsPopoverSeparator(),
        ZsOptionLink(label: 'More view options', action: 'Settings…', shortcut: '⌘,', onPressed: () {}),
      ],
    ),
  ),
);

// ---- ConfirmDialog ----

Widget _dialog(ZsConfirmTone tone, {bool busy = false, String? identifier}) => ZsConfirmDialog(
  title: switch (tone) {
    ZsConfirmTone.destructive => 'Clear the operation history?',
    ZsConfirmTone.warn => 'Push with conflicts?',
    ZsConfirmTone.standard => 'Check out this change?',
  },
  body: const Text('Undo can no longer reach the operations before now.'),
  cmd: 'jj op abandon ..@-',
  confirmLabel: switch (tone) {
    ZsConfirmTone.destructive => 'Clear history',
    ZsConfirmTone.warn => 'Push anyway',
    ZsConfirmTone.standard => 'Check out',
  },
  tone: tone,
  busy: busy,
  onConfirm: () {},
  onCancel: () {},
  identifier: identifier,
);

Widget _confirmMatrix(BuildContext context) => StateMatrix(columnWidth: 520, <MatrixRow>[
  for (final ZsConfirmTone tone in ZsConfirmTone.values)
    MatrixRow(
      'ConfirmDialog',
      tone.name,
      const <MatrixState>[MatrixState.rest, MatrixState.busy],
      (cell) => SizedBox(
        width: 500,
        height: 330,
        child: Stack(children: <Widget>[_dialog(tone, busy: cell.state == MatrixState.busy)]),
      ),
    ),
]);

Widget _confirmInteractive(BuildContext context) {
  final ZsConfirmTone tone = context.knobs.object.dropdown(
    label: 'tone',
    options: ZsConfirmTone.values,
    labelBuilder: (value) => value.name,
  );
  final bool busy = context.knobs.boolean(label: 'busy');
  return SizedBox.expand(
    child: Stack(
      children: <Widget>[_dialog(tone, busy: busy, identifier: 'confirm')],
    ),
  );
}

// ---- ScrollArea ----

Widget _scrollList(ScrollController controller) => ListView.builder(
  controller: controller,
  itemCount: 40,
  itemBuilder: (context, i) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    child: Text('src/feature_$i.dart'),
  ),
);

Widget _scrollAreaMatrix(BuildContext context) {
  MatrixRow row(String spec, {bool? always}) => MatrixRow(
    'ScrollArea',
    spec,
    const <MatrixState>[MatrixState.rest],
    (cell) {
      final ScrollController controller = cell.own(ScrollController());
      return SizedBox(
        width: 170,
        height: 140,
        child: ZsScrollArea(controller: controller, alwaysShowScrollBars: always, child: _scrollList(controller)),
      );
    },
  );
  return StateMatrix(<MatrixRow>[row('overlay · hidden at rest'), row('always shown', always: true)]);
}

Widget _scrollAreaInteractive(BuildContext context) {
  final bool? jump = context.knobs.booleanOrNull(label: 'jump to the spot (null: the shell)');
  return _live(SizedBox(width: 280, height: 320, child: _ScrollDemo(jumpToClickedSpot: jump)));
}

class _ScrollDemo extends StatefulWidget {
  const _ScrollDemo({required this.jumpToClickedSpot});

  final bool? jumpToClickedSpot;

  @override
  State<_ScrollDemo> createState() => _ScrollDemoState();
}

class _ScrollDemoState extends State<_ScrollDemo> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ZsScrollArea(
    controller: _controller,
    label: 'Files',
    jumpToClickedSpot: widget.jumpToClickedSpot,
    identifier: 'scroll-area',
    child: _scrollList(_controller),
  );
}

// ---- Chip ----

Widget _chipMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  for (final (String spec, String label, ZsChipKind kind) in const <(String, String, ZsChipKind)>[
    ('toggle “Aa”', 'Aa', ZsChipKind.toggle),
    ('not “~”', '~', ZsChipKind.not),
  ])
    MatrixRow(
      'Chip',
      spec,
      const <MatrixState>[..._interaction, MatrixState.on, MatrixState.disabled],
      (cell) => ZsChip(
        label: label,
        kind: kind,
        on: cell.state == MatrixState.on,
        onChanged: cell.state == MatrixState.disabled ? null : (_) {},
        statesController: cell.states,
      ),
    ),
  MatrixRow(
    'Chip',
    'filter',
    _interaction,
    (cell) => ZsChip(
      label: 'author: ralph',
      kind: ZsChipKind.filter,
      mono: true,
      onRemove: () {},
      statesController: cell.states,
    ),
  ),
  MatrixRow(
    'Chip',
    'add',
    _interaction,
    (cell) => ZsChip(label: 'Add rule', kind: ZsChipKind.add, onPressed: () {}, statesController: cell.states),
  ),
  MatrixRow(
    'Chip',
    'sm · icon',
    const <MatrixState>[MatrixState.rest, MatrixState.on],
    (cell) => ZsChip(
      label: 'conflicts',
      icon: ZI.conflict,
      size: ZsChipSize.sm,
      on: cell.state == MatrixState.on,
      onChanged: (_) {},
    ),
  ),
]);

Widget _chipInteractive(BuildContext context) => _live(
  _Stateful<(bool, bool, bool)>(
    initial: (false, false, true),
    build: (value, set) {
      final (bool matchCase, bool not, bool filter) = value;
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: <Widget>[
          ZsChip(label: 'Aa', on: matchCase, onChanged: (on) => set((on, not, filter)), identifier: 'chip-case'),
          ZsChip(label: '~', kind: ZsChipKind.not, on: not, onChanged: (on) => set((matchCase, on, filter))),
          if (filter)
            ZsChip(
              label: 'author: ralph',
              kind: ZsChipKind.filter,
              mono: true,
              onRemove: () => set((matchCase, not, false)),
            ),
          ZsChip(label: 'Add rule', kind: ZsChipKind.add, onPressed: () => set((matchCase, not, true))),
        ],
      );
    },
  ),
);

// ---- Link ----

Widget _linkMatrix(BuildContext context) {
  MatrixRow row(String spec, {bool quiet = false, bool external = false}) => MatrixRow(
    'Link',
    spec,
    const <MatrixState>[..._interaction, MatrixState.disabled],
    (cell) => ZsLink(
      label: external ? 'jj docs' : 'Open log',
      quiet: quiet,
      external: external,
      onPressed: _enabled(cell),
      statesController: cell.states,
    ),
  );
  return StateMatrix(<MatrixRow>[row('inline'), row('quiet', quiet: true), row('external', external: true)]);
}

Widget _linkInteractive(BuildContext context) {
  final bool quiet = context.knobs.boolean(label: 'quiet');
  final bool external = context.knobs.boolean(label: 'external');
  return _live(
    Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text('Fetched 3 changes. '),
        ZsLink(label: 'Show them', quiet: quiet, external: external, onPressed: () {}, identifier: 'link'),
      ],
    ),
  );
}

// ---- Disclosure ----

Widget _disclosureMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  MatrixRow(
    'Disclosure',
    'header 30',
    const <MatrixState>[..._interaction, MatrixState.on],
    (cell) => SizedBox(
      width: 170,
      child: ZsDisclosure(
        label: 'Conflicts',
        meta: '3',
        open: cell.state == MatrixState.on,
        statesController: cell.states,
        child: const Padding(padding: EdgeInsets.fromLTRB(28, 4, 8, 6), child: Text('src/app.dart')),
      ),
    ),
  ),
]);

Widget _disclosureInteractive(BuildContext context) => _live(
  SizedBox(
    width: 280,
    child: ZsDisclosure(
      label: 'Changed files',
      meta: '12',
      initiallyOpen: true,
      identifier: 'disclosure',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var i = 0; i < 6; i++)
            Padding(padding: const EdgeInsets.fromLTRB(28, 4, 8, 4), child: Text('lib/src/file_$i.dart')),
        ],
      ),
    ),
  ),
);

// ---- Spinner ----

Widget _spinnerMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  for (final ZsIconSize size in ZsIconSize.values)
    MatrixRow('Spinner', size.name, const <MatrixState>[MatrixState.rest], (cell) => ZsSpinner(size: size)),
  MatrixRow(
    'Spinner',
    'labelled',
    const <MatrixState>[MatrixState.rest],
    (cell) => const ZsSpinner(label: 'Fetching'),
  ),
]);

Widget _spinnerInteractive(BuildContext context) {
  final ZsIconSize size = context.knobs.object.dropdown(
    label: 'size',
    options: ZsIconSize.values,
    initialOption: ZsIconSize.md,
    labelBuilder: (value) => value.name,
  );
  return _live(ZsSpinner(size: size, label: 'Fetching', identifier: 'spinner'));
}

// ---- ProgressBar ----

Widget _progressMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  for (final double value in const <double>[0, .4, 1])
    MatrixRow(
      'ProgressBar',
      '${(value * 100).round()} %',
      const <MatrixState>[MatrixState.rest],
      (cell) => ZsProgressBar(value: value, width: 160),
    ),
  MatrixRow(
    'ProgressBar',
    'indeterminate',
    const <MatrixState>[MatrixState.rest],
    (cell) => const ZsProgressBar(width: 160),
  ),
]);

Widget _progressInteractive(BuildContext context) {
  final bool indeterminate = context.knobs.boolean(label: 'indeterminate');
  final double value = context.knobs.double.slider(label: 'value', initialValue: .4, max: 1);
  return _live(
    ZsProgressBar(value: indeterminate ? null : value, label: 'Fetching', width: 240, identifier: 'progress'),
  );
}

// ---- Skeleton ----

Widget _skeletonMatrix(BuildContext context) => StateMatrix(columnWidth: 280, <MatrixRow>[
  MatrixRow(
    'Skeleton',
    'bar',
    const <MatrixState>[MatrixState.rest],
    (cell) => const ZsSkeleton(width: 160),
  ),
  MatrixRow(
    'Skeleton',
    'card 240 × 62',
    const <MatrixState>[MatrixState.rest],
    (cell) => const ZsSkeleton(kind: ZsSkeletonKind.card),
  ),
  MatrixRow(
    'Skeleton',
    'row 30',
    const <MatrixState>[MatrixState.rest],
    (cell) => const SizedBox(width: 240, child: ZsSkeleton(kind: ZsSkeletonKind.row, width: 120)),
  ),
]);

Widget _skeletonInteractive(BuildContext context) {
  final ZsSkeletonKind kind = context.knobs.object.dropdown(
    label: 'kind',
    options: ZsSkeletonKind.values,
    labelBuilder: (value) => value.name,
  );
  return _live(
    SizedBox(
      width: 280,
      child: ZsSkeleton(kind: kind, width: 160, identifier: 'skeleton'),
    ),
  );
}

// ---- Presence ----

Widget _presenceCard(BuildContext context, bool closing) => ZsSurfaceTransition(
  motion: ZsSurfaceMotion.popover,
  closing: closing,
  child: const ZsMenuMaterial(
    padding: EdgeInsets.all(12),
    child: Text('Mounted while open and through its exit'),
  ),
);

Widget _presenceMatrix(BuildContext context) => StateMatrix(columnWidth: 300, <MatrixRow>[
  for (final bool open in const <bool>[true, false])
    MatrixRow(
      'Presence',
      open ? 'open' : 'closed',
      const <MatrixState>[MatrixState.rest],
      (cell) => SizedBox(
        height: 60,
        child: ZsPresence(open: open, exit: ZsMotion.of(context).durExit, builder: _presenceCard),
      ),
    ),
]);

Widget _presenceInteractive(BuildContext context) {
  final bool open = context.knobs.boolean(label: 'open', initialValue: true);
  return _live(ZsPresence(open: open, exit: ZsMotion.of(context).durExit, builder: _presenceCard));
}

// ---- Kbd ----

Widget _kbdMatrix(BuildContext context) => StateMatrix(<MatrixRow>[
  for (final String key in const <String>['/', '⌘K', '⇧⌘P', 'Esc'])
    MatrixRow('Kbd', key, const <MatrixState>[MatrixState.rest], (cell) => ZsKbd(key)),
]);

Widget _kbdInteractive(BuildContext context) {
  final String label = context.knobs.string(label: 'key', initialValue: '⌘K');
  return _live(ZsKbd(label, identifier: 'kbd'));
}

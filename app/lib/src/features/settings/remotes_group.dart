// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show Remote;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_layout.dart' show jjRefSymbol;
import '../graph/graph_ports.dart' show shellQuote;
import '../shell/shell_toast.dart' show toastSlot, toastSpan;
import 'settings_view_model.dart';
import 'settings_widgets.dart';

/// Which form a row is.
enum _Mode { add, rename, url }

/// Settings › Project › Remotes (Story 11.18; DS components/settings/RemotesGroup.{jsx,prompt.md}, settings.css:56-90):
/// a row per remote — the name, the fetch URL (mono, one line, ellipsis, the URL as tooltip), the push URL when it
/// differs — with ••• (Rename… · Set URL… · Remove…), then Add remote…, then [children] (Fetch from, Push to, Check
/// for remote changes).
///
/// - **Forms:** Add, Rename and Set URL edit in the row: the fields on a 72 px label column, the exact command, jj's
///   refusal, Cancel and the verb (off until something would change). ↩ runs it, Esc cancels and returns focus to the
///   row's •••.
/// - **Remove** asks first: the window's sheet ([SettingsViewModel.askRemove]); its refusal shows under the row.
/// - A credential never shows: every URL goes through [scrubRemoteUrl].
///
/// Identifiers: `settings-remote-<name>`, `settings-remote-more-<name>`, `settings-remote-add`, `settings-remote-form`,
/// `settings-remote-run`, `settings-remote-cancel`, `settings-remote-command`.
class SettingsRemotesGroup extends StatefulWidget {
  /// The remotes of [vm] above [children].
  const SettingsRemotesGroup({required this.vm, required this.children, super.key});

  /// The view model.
  final SettingsViewModel vm;

  /// The group's other rows.
  final List<Widget> children;

  @override
  State<SettingsRemotesGroup> createState() => _SettingsRemotesGroupState();
}

class _SettingsRemotesGroupState extends State<SettingsRemotesGroup> {
  /// The open form and the remote it edits (null for Add).
  ({_Mode mode, String? of})? _form;
  String? _menuOpen;
  final _more = <String, FocusNode>{};
  final _add = FocusNode(debugLabel: 'add remote');

  SettingsViewModel get vm => widget.vm;

  @override
  void dispose() {
    for (final FocusNode node in _more.values) {
      node.dispose();
    }
    _add.dispose();
    super.dispose();
  }

  FocusNode _moreOf(String name) => _more.putIfAbsent(name, () => FocusNode(debugLabel: 'remote $name more'));

  void _open(_Mode mode, [String? of]) {
    vm.clearRemoteNotes();
    setState(() => _form = (mode: mode, of: of));
  }

  void _close({bool refocus = false}) {
    final String? of = _form?.of;
    setState(() => _form = null);
    if (refocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => (of == null ? _add : _moreOf(of)).requestFocus());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final List<Remote> remotes = vm.remoteList;
    final ({_Mode mode, String? of})? form = _form;
    return SettingsGroup(
      title: s.settingsRemotes,
      children: <Widget>[
        if (remotes.isEmpty && form == null)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(s.settingsRemotesEmpty, style: ZsType.secondary.copyWith(color: colors.textDim)),
              ),
            ),
          ),
        for (final Remote remote in remotes)
          if (form != null && form.mode != _Mode.add && form.of == remote.name)
            _FormRow(
              key: ValueKey<Object>((form.mode, remote.name)),
              vm: vm,
              mode: form.mode,
              remote: remote,
              onDone: _close,
              onCancel: () => _close(refocus: true),
            )
          else
            _row(context, s, colors, remote),
        if (form != null && form.mode == _Mode.add)
          _FormRow(
            key: const ValueKey<String>('add'),
            vm: vm,
            mode: _Mode.add,
            onDone: _close,
            onCancel: () => _close(refocus: true),
          )
        else
          _addRow(s, colors),
        ...widget.children,
      ],
    );
  }

  Widget _row(BuildContext context, AppLocalizations s, ZsColors colors, Remote remote) {
    final String name = remote.name;
    final String? url = remote.url == null ? null : scrubRemoteUrl(remote.url!);
    final String? push = remote.pushUrl == null ? null : scrubRemoteUrl(remote.pushUrl!);
    final TextStyle mono = ZsType.id.copyWith(height: 1.45, color: colors.textDim);
    Widget urlLine(String text, {String? lead}) => ZsTooltip(
      message: text,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            if (lead != null) ...<InlineSpan>[
              TextSpan(
                text: lead,
                style: ZsType.meta.copyWith(fontSize: ZsType.fsXs, color: colors.textFaint),
              ),
              const WidgetSpan(child: SizedBox(width: 6)),
            ],
            TextSpan(text: text),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: mono,
      ),
    );
    final RemoteOutcome? note = vm.remoteNotes[name];
    ZsMenuItem item(String label, String cmd, String id, VoidCallback run) =>
        ZsMenuItem(label: label, cmd: cmd, identifier: id, onSelected: run);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 3,
                children: <Widget>[
                  Semantics(
                    container: true,
                    identifier: 'settings-remote-$name',
                    label: s.settingsRemoteRow(name, url ?? s.settingsRemoteNoFetchUrl),
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 3,
                        children: <Widget>[
                          Text(name, style: ZsType.body.copyWith(height: 1.35, color: colors.text)),
                          if (url != null)
                            urlLine(url)
                          else
                            Text(
                              s.settingsRemoteNoFetchUrl,
                              style: ZsType.meta.copyWith(fontSize: ZsType.fsId, color: colors.textFaint),
                            ),
                          if (push != null) urlLine(push, lead: s.settingsRemotePushLabel),
                        ],
                      ),
                    ),
                  ),
                  if (note case final RemoteRefusal refusal) _Refusal(refusal: refusal),
                  if (note case final RemoteWarning warning) _Warning(warning: warning),
                ],
              ),
            ),
            Transform.translate(
              offset: const Offset(6, -2),
              child: ZsMenuAnchor(
                semanticLabel: s.settingsRemoteMore(name),
                onOpen: () => setState(() => _menuOpen = name),
                onClose: () => setState(() => _menuOpen = null),
                entries: <ZsMenuEntry>[
                  item(
                    s.settingsRemoteRenameItem,
                    'jj git remote rename', // l10n-ignore: jj command
                    'settings-remote-rename-$name',
                    () => _open(_Mode.rename, name),
                  ),
                  item(
                    s.settingsRemoteSetUrlItem,
                    'jj git remote set-url', // l10n-ignore: jj command
                    'settings-remote-set-url-$name',
                    () => _open(_Mode.url, name),
                  ),
                  const ZsMenuSeparator(),
                  item(
                    s.settingsRemoteRemoveItem,
                    'jj git remote remove', // l10n-ignore: jj command
                    'settings-remote-remove-$name',
                    () => vm.askRemove(name),
                  ),
                ],
                builder: (context, controller) => ZsIconButton(
                  icon: ZI.more,
                  label: s.settingsRemoteMore(name),
                  size: ZsIconButtonSize.sm,
                  active: _menuOpen == name,
                  focusNode: _moreOf(name),
                  identifier: 'settings-remote-more-$name',
                  onPressed: controller.open,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addRow(AppLocalizations s, ZsColors colors) => ZsTooltip(
    message: 'jj git remote add', // l10n-ignore: jj command
    child: ZsControlCore(
      identifier: 'settings-remote-add',
      focusNode: _add,
      onActivate: () => _open(_Mode.add),
      ring: ZsRingPlacement.inside,
      semantics: SemanticsProperties(button: true, label: s.settingsRemoteAdd),
      builder: (context, status) {
        final Color ink = status.hovered || status.pressed ? colors.text : colors.textMuted;
        return ColoredBox(
          color: status.pressed
              ? colors.flPress
              : status.hovered
              ? colors.flOn
              : const Color(0x00000000),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                spacing: 7,
                children: <Widget>[
                  ZanshinIcon(ZI.plus, size: ZsIconSize.sm, color: ink),
                  Text(
                    s.settingsRemoteAdd,
                    style: ZsType.control.copyWith(
                      fontWeight: FontWeight.w400,
                      fontVariations: const <FontVariation>[FontVariation.weight(400)],
                      color: ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// A row as a form (`--fl-on`): the head, the fields, the command well, jj's refusal, Cancel and the verb.
class _FormRow extends StatefulWidget {
  const _FormRow({
    required this.vm,
    required this.mode,
    required this.onDone,
    required this.onCancel,
    this.remote,
    super.key,
  });

  final SettingsViewModel vm;
  final _Mode mode;
  final Remote? remote;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  @override
  State<_FormRow> createState() => _FormRowState();
}

class _FormRowState extends State<_FormRow> {
  late final ZsTextEditingController _name;
  late final ZsTextEditingController _url;
  late final ZsTextEditingController _push;
  final _first = FocusNode(debugLabel: 'remote form');
  RemoteRefusal? _refusal;
  var _running = false;

  Remote? get _remote => widget.remote;

  @override
  void initState() {
    super.initState();
    final Remote? remote = _remote;
    // A URL holding a credential starts empty: its scrubbed form is the placeholder.
    String keep(String? url) => widget.mode == _Mode.url && url != null && !remoteUrlHasCredential(url) ? url : '';
    _name = ZsTextEditingController(text: widget.mode == _Mode.rename ? remote?.name ?? '' : '');
    _url = ZsTextEditingController(text: keep(remote?.url));
    _push = ZsTextEditingController(text: keep(remote?.pushUrl));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _first.requestFocus();
      if (widget.mode == _Mode.rename) {
        _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _push.dispose();
    _first.dispose();
    super.dispose();
  }

  /// A Set URL side: the trimmed text when it is non-empty and differs from [was], else null (it stays).
  static String? _side(String text, String? was) {
    final String t = text.trim();
    return t.isNotEmpty && t != was ? t : null;
  }

  RemoteOp get _op {
    final Remote? remote = _remote;
    return switch (widget.mode) {
      _Mode.add => RemoteAdd(
        _name.text.trim(),
        url: _url.text.trim(),
        pushUrl: _push.text.trim().isEmpty ? null : _push.text.trim(),
      ),
      _Mode.rename => RemoteRename(remote!.name, _name.text.trim()),
      _Mode.url => RemoteSetUrl(
        remote!.name,
        url: _side(_url.text, remote.url),
        pushUrl: _side(_push.text, remote.pushUrl ?? remote.url),
      ),
    };
  }

  bool get _ready => switch (_op) {
    RemoteAdd(:final String name, :final String url) => name.isNotEmpty && url.isNotEmpty,
    RemoteRename(:final String name, :final String newName) => newName.isNotEmpty && newName != name,
    RemoteSetUrl(:final String? url, :final String? pushUrl) => url != null || pushUrl != null,
    RemoteRemove() => true,
  };

  Future<void> _run() async {
    if (!_ready || _running) {
      return;
    }
    setState(() => _running = true);
    RemoteOutcome? outcome;
    try {
      outcome = await widget.vm.runRemote(_op);
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
    if (!mounted) {
      return;
    }
    if (outcome case final RemoteRefusal refusal) {
      setState(() => _refusal = refusal);
    } else {
      widget.onDone();
    }
  }

  void _edited(String _) => setState(() => _refusal = null);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final Remote? remote = _remote;
    String? scrubbed(String? url) => remoteUrlHasCredential(url) ? scrubRemoteUrl(url!) : null;
    final String head = switch (widget.mode) {
      _Mode.add => s.settingsRemoteAddTitle,
      _ => remote!.name,
    };
    final String? what = switch (widget.mode) {
      _Mode.add => null,
      _Mode.rename => s.settingsRemoteRenameTitle,
      _Mode.url => s.settingsRemoteSetUrlTitle,
    };
    final marks = _refusal != null;
    final fields = <Widget>[
      ...switch (widget.mode) {
        _Mode.add => <Widget>[
          _field(
            s.settingsRemoteName,
            _name,
            first: true,
            placeholder: 'upstream', // l10n-ignore: example remote name
            error: marks,
          ),
          _field(
            s.settingsRemoteUrl,
            _url,
            mono: true,
            placeholder: 'https://github.com/owner/repo.git', // l10n-ignore: example URL
          ),
          _field(
            s.settingsRemotePushUrl,
            _push,
            mono: true,
            placeholder: s.settingsRemoteSameAsUrl,
            hint: s.settingsRemoteAddPushHint,
          ),
        ],
        _Mode.rename => <Widget>[
          _field(
            s.settingsRemoteNewName,
            _name,
            first: true,
            error: marks,
            hint: s.settingsRemoteRenameHint(
              'main@${jjRefSymbol(remote!.name)}', // l10n-ignore: example bookmark
              'main@${_name.text.trim().isEmpty ? '…' : jjRefSymbol(_name.text.trim())}', // l10n-ignore: example bookmark
            ),
          ),
        ],
        _Mode.url => <Widget>[
          _field(
            s.settingsRemoteUrl,
            _url,
            first: true,
            mono: true,
            placeholder: scrubbed(remote!.url),
            hint: remoteUrlHasCredential(remote.url) ? s.settingsRemoteCredentialHint : null,
          ),
          _field(
            s.settingsRemotePushUrl,
            _push,
            mono: true,
            placeholder: remote.pushUrl == null ? s.settingsRemoteSameAsUrl : scrubbed(remote.pushUrl),
            hint: remote.pushUrl == null ? null : s.settingsRemotePushKeepHint,
          ),
        ],
      },
    ];
    final RemoteRefusal? refusal = _refusal;
    return Semantics(
      identifier: 'settings-remote-form',
      container: true,
      explicitChildNodes: true,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: ColoredBox(
          color: colors.flOn,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: <Widget>[
                Text.rich(
                  TextSpan(
                    text: head,
                    children: <InlineSpan>[
                      if (what != null)
                        TextSpan(
                          text: '  $what',
                          style: ZsType.meta.copyWith(fontSize: ZsType.fsId, color: colors.textDim),
                        ),
                    ],
                  ),
                  style: ZsType.body.copyWith(height: 1.35, color: colors.text),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: <Widget>[
                    ...fields,
                    Padding(
                      padding: const EdgeInsets.only(left: 82),
                      child: Semantics(
                        identifier: 'settings-remote-command',
                        container: true,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.codeBg,
                            border: Border.all(color: colors.flBorder),
                            borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusMd),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            child: Text(_op.command, style: ZsType.id.copyWith(height: 1.55, color: colors.textMuted)),
                          ),
                        ),
                      ),
                    ),
                    if (refusal != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 82),
                        child: _Refusal(refusal: refusal),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        spacing: 8,
                        children: <Widget>[
                          ZsButton(
                            label: s.settingsRemoteCancel,
                            size: ZsButtonSize.md,
                            identifier: 'settings-remote-cancel',
                            onPressed: widget.onCancel,
                          ),
                          ZsButton(
                            label: switch (widget.mode) {
                              _Mode.add => s.settingsRemoteAddVerb,
                              _Mode.rename => s.settingsRemoteRenameVerb,
                              _Mode.url => s.settingsRemoteSetUrlVerb,
                            },
                            variant: ZsButtonVariant.primary,
                            size: ZsButtonSize.md,
                            busy: _running,
                            identifier: 'settings-remote-run',
                            onPressed: _ready ? () => unawaited(_run()) : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    ZsTextEditingController controller, {
    bool first = false,
    bool mono = false,
    bool error = false,
    String? placeholder,
    String? hint,
  }) {
    final ZsColors colors = ZsColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: <Widget>[
        SizedBox(
          width: 72,
          height: 30,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: ZsType.secondary.copyWith(color: colors.textMuted),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: <Widget>[
              ZsTextField(
                controller: controller,
                focusNode: first ? _first : null,
                mono: mono,
                label: label,
                placeholder: placeholder,
                error: error ? '' : null,
                onChanged: _edited,
                onSubmitted: (_) => unawaited(_run()),
              ),
              if (hint != null) Text(hint, style: ZsType.meta.copyWith(height: 1.4, color: colors.textDim)),
            ],
          ),
        ),
      ],
    );
  }
}

/// jj's refusal in `--warn` with the conflict mark, then the help sentence; an alert (DS `.zs-rem-err`).
class _Refusal extends StatelessWidget {
  const _Refusal({required this.refusal});

  final RemoteRefusal refusal;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final TextStyle help = ZsType.meta.copyWith(fontSize: ZsType.fsId, height: 1.45, color: colors.textMuted);
    final InlineSpan? helpText = switch (refusal.help) {
      null => null,
      RemoteHelp.reservedName => TextSpan(text: s.settingsRemoteReservedHelp),
      RemoteHelp.nonstandardConfig => toastSpan(s.settingsRemoteNonstandardHelp(toastSlot(0)), <InlineSpan>[
        TextSpan(
          text: 'git remote remove ${shellQuote(refusal.name ?? '')}', // l10n-ignore: git's command
          style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.text),
        ),
      ]),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 3,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: ZanshinIcon(ZI.conflict, size: ZsIconSize.sm, color: colors.warn),
                ),
                Expanded(
                  child: Text(refusal.message, style: ZsType.secondary.copyWith(height: 1.45, color: colors.warn)),
                ),
              ],
            ),
            if (helpText != null)
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: Text.rich(helpText, style: help),
              ),
          ],
        ),
      ),
    );
  }
}

/// Add's duplicate-URL warning under the new row: jj's message in `--warn`, then jj's hint (DS `.zs-rem-warn`).
class _Warning extends StatelessWidget {
  const _Warning({required this.warning});

  final RemoteWarning warning;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: ZanshinIcon(ZI.conflict, size: ZsIconSize.sm, color: colors.warn),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: warning.message,
                  children: <InlineSpan>[
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: warning.hint,
                      style: TextStyle(color: colors.textDim),
                    ),
                  ],
                ),
                style: ZsType.meta.copyWith(fontSize: ZsType.fsId, height: 1.45, color: colors.warn),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

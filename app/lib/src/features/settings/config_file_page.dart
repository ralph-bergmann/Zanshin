// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Material, MaterialType, TextField;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'settings_view_model.dart';
import 'settings_widgets.dart' show SettingsPage;

/// jj's refusal of a config file's text (`jj.config_parse_error`, Story 11.19): its [message] verbatim and, when jj
/// knows the spot, the draft's UTF-16 [range] with its 1-based [line] and [column] (characters before it on its line
/// plus one).
@immutable
final class ConfigParseFailure {
  /// A refusal reading [message], at [range] when known.
  const ConfigParseFailure({required this.message, this.range, this.line, this.column});

  /// The failure [error] means for [draft], or null when [error] is no parse error. The bridge's context is
  /// `"<start>..<end>\n<message>"` (a UTF-8 byte span) or just the message (docs/rust-error-codes.md); jj's message
  /// itself is never read.
  static ConfigParseFailure? of(ZanshinFfiException error, String draft) {
    if (error.code != 'jj.config_parse_error') {
      return null;
    }
    final String context = error.context ?? error.code;
    final RegExpMatch? span = _span.firstMatch(context);
    if (span == null) {
      return ConfigParseFailure(message: context);
    }
    final int start = _utf16At(draft, int.parse(span[1]!));
    final int end = math.max(start, _utf16At(draft, int.parse(span[2]!)));
    final String before = draft.substring(0, start);
    final int lineStart = before.lastIndexOf('\n') + 1;
    return ConfigParseFailure(
      message: context.substring(span.end),
      range: TextRange(start: start, end: end),
      line: '\n'.allMatches(before).length + 1,
      column: before.substring(lineStart).runes.length + 1,
    );
  }

  static final _span = RegExp(r'^(\d+)\.\.(\d+)\n');

  /// The UTF-16 offset of the UTF-8 byte offset [byte] in [text], clamped to its end.
  static int _utf16At(String text, int byte) {
    var bytes = 0;
    var offset = 0;
    for (final int rune in text.runes) {
      if (bytes >= byte) {
        break;
      }
      bytes += rune < 0x80
          ? 1
          : rune < 0x800
          ? 2
          : rune < 0x10000
          ? 3
          : 4;
      offset += rune > 0xFFFF ? 2 : 1;
    }
    return offset;
  }

  /// jj's message, verbatim (it may span lines).
  final String message;

  /// The spot in the draft, or null when jj names none.
  final TextRange? range;

  /// The spot's line, or null.
  final int? line;

  /// The spot's column, or null.
  final int? column;
}

/// The editor's text: [mark] — jj's parse span — wavy-underlined in `--rem` over `--rem-bg` (DS settings.css:111).
class _ConfigEditingController extends ZsTextEditingController {
  TextRange? mark;

  @override
  TextSpan buildTextSpan({required BuildContext context, required bool withComposing, TextStyle? style}) {
    final TextRange? mark = this.mark;
    final bool composing = withComposing && value.isComposingRangeValid && !value.composing.isCollapsed;
    if (composing || mark == null || !mark.isValid || mark.isCollapsed || mark.end > text.length) {
      return super.buildTextSpan(context: context, withComposing: withComposing, style: style);
    }
    final ZsColors colors = ZsColors.of(context);
    return TextSpan(
      style: style,
      children: <InlineSpan>[
        TextSpan(text: mark.textBefore(text)),
        TextSpan(
          text: mark.textInside(text),
          style: TextStyle(
            backgroundColor: colors.remBg,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: colors.rem,
          ),
        ),
        TextSpan(text: mark.textAfter(text)),
      ],
    );
  }
}

/// The Config file page (Story 11.19; DS components/settings/ConfigFilePage.{jsx,prompt.md}, settings.css:92-120):
/// the GUI half of `jj config edit --<scope>` inside a Settings tab — General's user file, Project's repo file.
///
/// - **The well** (`--code-bg`, `--radius-well`, 1 px `--fl-border`; `--accent-ring` while the editor has focus,
///   `--rem` with an error): a 30 px bar naming the file and its state (*Edited* with a gold dot · *✓ Saved* for 1.6 s
///   after a save), the changed-on-disk notice, then a 44 px gutter of line numbers beside the editor — the file's
///   exact text in mono 12/19.5, no wrapping, scrolling both ways. Tab moves focus; no tab characters.
/// - **Save** (gold, ⌘S) writes the draft through jj, which checks it first; a refusal writes nothing and shows
///   jj's message under the well — with its spot marked (gutter number in `--rem`, the span wavy-underlined), its
///   line and column, a sentence and **Show** when jj names the spot. It stays until the next Save or Revert.
///   **Revert** goes back to the saved text. Both are off while nothing changed. A landed save re-reads Settings
///   ([SettingsViewModel.configFileSaved]).
/// - **Changed on disk** (a watch on the file): without edits the page shows the new text; with edits a notice offers
///   **Reload**, which replaces the draft. Save still writes the draft.
/// - [onEditing] reports whether the draft differs from the saved text, so the window asks before it is left.
///
/// Identifiers: `settings-config-editor`, `-error`, `-stale`, `-save`, `-revert`, `-reload`, `-show`.
class SettingsConfigFilePage extends StatefulWidget {
  /// The page editing [scope]'s file through [vm]'s environment.
  const SettingsConfigFilePage({
    required this.vm,
    required this.scope,
    required this.back,
    required this.onBack,
    required this.onEditing,
    super.key,
  });

  /// The Settings view model: the environment, the project, the re-read after a save.
  final SettingsViewModel vm;

  /// The file's scope: user (General) or repo (Project).
  final ConfigScope scope;

  /// The tab's name, where back leads.
  final String back;

  /// Back to the tab (⌘[ too); the window asks first while there are edits.
  final VoidCallback onBack;

  /// Whether the draft has edits, on every change of it.
  final ValueChanged<bool> onEditing;

  @override
  State<SettingsConfigFilePage> createState() => _SettingsConfigFilePageState();
}

class _SettingsConfigFilePageState extends State<SettingsConfigFilePage> {
  final _text = _ConfigEditingController();
  final _focus = FocusNode(debugLabel: 'config file editor');
  final _undo = UndoHistoryController();
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  var _loading = true;
  String? _loadError;
  String? _path;
  var _saved = '';
  var _editing = false;
  var _saving = false;

  /// jj's parse refusal of the last Save, or null.
  ConfigParseFailure? _parse;

  /// Another failure of the last Save, or null.
  String? _failure;

  /// The draft the last refused Save sent; the spot is marked only while the text still is that draft.
  String? _errorDraft;

  /// jj's spot in the text, while the text is still the refused draft, else null.
  TextRange? get _markedRange => _text.text == _errorDraft ? _parse?.range : null;

  var _justSaved = false;
  Timer? _justSavedTimer;

  /// The file's text on disk while it differs from the saved text under edits (the notice shows), else null.
  String? _disk;
  StreamSubscription<void>? _watch;

  /// The gutter's width (DS settings.css:105).
  static const double _gutter = 44;

  /// One line of the editor (DS settings.css:104: `--fs-md`/19.5px).
  static const _lineHeight = 19.5;

  bool get _dirty => !_loading && _loadError == null && _text.text != _saved;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
    _focus.addListener(_refocused);
    unawaited(_load());
  }

  @override
  void dispose() {
    // A page dropped with edits (a project switch re-keys it) leaves no edits behind.
    if (_editing) {
      widget.onEditing(false);
    }
    unawaited(_watch?.cancel());
    _justSavedTimer?.cancel();
    _text.dispose();
    _focus.dispose();
    _undo.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _refocused() => setState(() {});

  void _changed() {
    final bool dirty = _dirty;
    if (dirty != _editing) {
      _editing = dirty;
      widget.onEditing(dirty);
    }
    setState(() {});
  }

  Future<ConfigFileText> _read() => widget.vm.environment.configFileRead(widget.scope, workspaceRoot: widget.vm.root);

  Future<void> _load() async {
    try {
      final ConfigFileText file = await _read();
      if (!mounted) {
        return;
      }
      _path = file.path;
      _saved = file.text;
      _loading = false;
      _text.text = file.text;
      // An empty file leaves the text as it was: no notification rebuilds the page.
      _changed();
      _watch = widget.vm.environment
          .fileChanges(file.path)
          .listen((_) => unawaited(_diskChanged()), onError: (Object _) {});
    } on ZanshinFfiException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = settingsErrorText(error);
        });
      }
    }
  }

  /// The file changed on disk: read again; new text replaces a clean draft, or raises the notice over edits.
  Future<void> _diskChanged() async {
    // Zanshin's own save reports here too; its text is the saved one once the save returns.
    if (_saving) {
      return;
    }
    final ConfigFileText file;
    try {
      file = await _read();
    } on ZanshinFfiException {
      return;
    }
    if (!mounted || file.text == _saved) {
      return;
    }
    if (_dirty && file.text != _text.text) {
      setState(() => _disk = file.text);
      return;
    }
    _saved = file.text;
    _disk = null;
    if (_text.text == file.text) {
      _changed();
    } else {
      _text.text = file.text;
    }
  }

  void _clearError() {
    _parse = null;
    _failure = null;
    _errorDraft = null;
  }

  /// Reload: the file on disk replaces the draft.
  void _reload() {
    _saved = _disk ?? _saved;
    _disk = null;
    _clearError();
    _text.text = _saved;
    _changed();
  }

  /// Revert: back to the saved text.
  void _revert() {
    _clearError();
    _text.text = _saved;
    _changed();
  }

  Future<void> _save() async {
    final String? path = _path;
    if (!_dirty || _saving || path == null) {
      return;
    }
    final String draft = _text.text;
    _saving = true;
    try {
      await widget.vm.environment.configFileWrite(path, draft, workspaceRoot: widget.vm.root);
    } on ZanshinFfiException catch (error) {
      if (!mounted) {
        return;
      }
      final ConfigParseFailure? parse = ConfigParseFailure.of(error, draft);
      setState(() {
        _parse = parse;
        _errorDraft = draft;
        _failure = parse == null ? settingsErrorText(error) : null;
        _justSaved = false;
      });
      _show();
      return;
    } finally {
      _saving = false;
    }
    if (!mounted) {
      return;
    }
    _saved = draft;
    _disk = null;
    _clearError();
    _justSaved = true;
    _justSavedTimer?.cancel();
    _justSavedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() => _justSaved = false);
      }
    });
    _changed();
    await widget.vm.configFileSaved();
  }

  /// Show: the caret goes to the marked spot.
  void _show() {
    final TextRange? range = _markedRange;
    if (range == null) {
      return;
    }
    _focus.requestFocus();
    _text.selection = TextSelection.collapsed(offset: math.min(range.start, _text.text.length));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final String? project = widget.vm.projectName;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => unawaited(_save()),
      },
      child: SettingsPage(
        back: widget.back,
        onBack: widget.onBack,
        title: s.settingsConfigTitle,
        intro: widget.scope == ConfigScope.user
            ? s.settingsConfigIntroUser
            : s.settingsConfigIntroProject(project ?? widget.back),
        spacing: 14,
        children: <Widget>[
          Expanded(child: _well(context, s)),
          if (_parse != null || _failure != null) _error(context, s),
          _footer(context, s),
        ],
      ),
    );
  }

  TextStyle _editorStyle(ZsColors colors) =>
      ZsType.command.copyWith(fontSize: ZsType.fsMd, height: _lineHeight / ZsType.fsMd, color: colors.text);

  static const _strut = StrutStyle(
    fontFamily: ZsType.monoFamily,
    fontSize: ZsType.fsMd,
    height: _lineHeight / ZsType.fsMd,
    leadingDistribution: TextLeadingDistribution.even,
    forceStrutHeight: true,
  );

  Widget _well(BuildContext context, AppLocalizations s) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final String? loadError = _loadError;
    if (loadError != null) {
      return Align(
        alignment: AlignmentDirectional.topStart,
        child: Text(
          loadError,
          style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: colors.rem),
        ),
      );
    }
    final bool error = _parse != null || _failure != null;
    final radius = BorderRadius.circular(metrics.radiusWell);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: radius,
        border: Border.all(
          color: error
              ? colors.rem
              : _focus.hasFocus
              ? colors.accentRing
              : colors.flBorder,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _bar(colors, s),
            if (_disk != null) _notice(colors, s),
            if (!_loading) Expanded(child: _editor(colors, s)),
          ],
        ),
      ),
    );
  }

  Widget _bar(ZsColors colors, AppLocalizations s) {
    final TextStyle state = ZsType.body.copyWith(fontSize: ZsType.fsSm, color: colors.textDim);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.flBorder)),
      ),
      child: SizedBox(
        height: 30,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            spacing: 12,
            children: <Widget>[
              Expanded(
                child: Text(
                  _path ?? '',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textDim),
                ),
              ),
              if (_dirty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(color: colors.gold, shape: BoxShape.circle),
                      child: const SizedBox.square(dimension: 6),
                    ),
                    Text(s.settingsConfigEdited, style: state),
                  ],
                )
              else if (_justSaved)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: <Widget>[
                    ZanshinIcon(ZI.check, size: ZsIconSize.xs, color: colors.textDim),
                    Text(s.settingsConfigSaved, style: state),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notice(ZsColors colors, AppLocalizations s) => Semantics(
    identifier: 'settings-config-stale',
    container: true,
    liveRegion: true,
    child: ColoredBox(
      color: colors.warnBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Row(
          spacing: 8,
          children: <Widget>[
            ZanshinIcon(ZI.conflict, size: ZsIconSize.sm, color: colors.warn),
            Expanded(
              child: Text(
                s.settingsConfigStale,
                style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: colors.text),
              ),
            ),
            ZsButton(label: s.settingsConfigReload, onPressed: _reload, identifier: 'settings-config-reload'),
          ],
        ),
      ),
    ),
  );

  Widget _editor(ZsColors colors, AppLocalizations s) {
    final TextStyle style = _editorStyle(colors);
    final String text = _text.text;
    final int lines = '\n'.allMatches(text).length + 1;
    final TextRange? marked = _markedRange;
    final int? errorLine = marked == null ? null : _parse?.line;
    // Read by buildTextSpan in this frame's EditableText build, which follows this one.
    _text.mark = marked;
    final TextStyle gutter = style.copyWith(color: colors.textFaint);
    return LayoutBuilder(
      builder: (context, box) {
        // No wrapping: the editor is as wide as its longest line (the padding and the caret beside it).
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
          strutStyle: _strut,
        )..layout();
        final double textWidth = painter.width;
        painter.dispose();
        final double width = math.max(box.maxWidth - _gutter, textWidth + 24 + 4);
        return Stack(
          children: <Widget>[
            ZsScrollArea(
              controller: _vertical,
              horizontalController: _horizontal,
              child: SingleChildScrollView(
                controller: _vertical,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: _gutter,
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 8, 10, 8),
                          child: Text.rich(
                            TextSpan(
                              children: <InlineSpan>[
                                for (var line = 1; line <= lines; line++)
                                  TextSpan(
                                    text: line == lines ? '$line' : '$line\n',
                                    style: line == errorLine
                                        ? TextStyle(
                                            color: colors.rem,
                                            fontWeight: FontWeight.w600,
                                            fontVariations: const <FontVariation>[FontVariation.weight(600)],
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                            textAlign: TextAlign.right,
                            style: gutter,
                            strutStyle: _strut,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _horizontal,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: width,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: box.maxHeight),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Semantics(
                                identifier: 'settings-config-editor',
                                label: s.settingsConfigEditorLabel(_path ?? ''),
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: TextField(
                                    controller: _text,
                                    focusNode: _focus,
                                    decoration: null,
                                    style: style,
                                    strutStyle: _strut,
                                    maxLines: null,
                                    keyboardType: TextInputType.multiline,
                                    textInputAction: TextInputAction.newline,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    smartDashesType: SmartDashesType.disabled,
                                    smartQuotesType: SmartQuotesType.disabled,
                                    cursorColor: colors.text,
                                    undoController: _undo,
                                    // The DS text menu (TextField.prompt.md:11) at the pointer.
                                    contextMenuBuilder: (context, state) => zsTextContextMenu(context, state, _undo),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: _gutter,
              top: 0,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: colors.flBorder),
            ),
          ],
        );
      },
    );
  }

  Widget _error(BuildContext context, AppLocalizations s) {
    final ZsColors colors = ZsColors.of(context);
    final ConfigParseFailure? parse = _parse;
    final int? line = parse?.line;
    final int? column = parse?.column;
    final bool spot = parse?.range != null && line != null && column != null;
    final TextStyle body = ZsType.body.copyWith(fontSize: ZsType.fsMd, height: 1.45, color: colors.text);
    return Semantics(
      identifier: 'settings-config-error',
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.remBg,
          borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusMd),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 9,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: ZanshinIcon(ZI.conflict, size: ZsIconSize.sm, color: colors.rem),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: <Widget>[
                    Text(
                      spot ? s.settingsConfigNotSavedAt(line, column) : s.settingsConfigNotSaved,
                      style: body.copyWith(
                        fontWeight: FontWeight.w600,
                        fontVariations: const <FontVariation>[FontVariation.weight(600)],
                      ),
                    ),
                    Text(
                      parse?.message ?? _failure ?? '', // l10n-ignore: jj's text
                      style: ZsType.id.copyWith(height: 1.55, color: colors.text),
                    ),
                    if (spot) Text(s.settingsConfigHelp, style: body.copyWith(color: colors.textMuted)),
                  ],
                ),
              ),
              if (spot && _markedRange != null)
                ZsButton(label: s.settingsConfigShow, onPressed: _show, identifier: 'settings-config-show'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, AppLocalizations s) {
    final ZsColors colors = ZsColors.of(context);
    final bool dirty = _dirty;
    return Row(
      spacing: 8,
      children: <Widget>[
        Expanded(
          child: Text(
            s.settingsConfigKey,
            style: ZsType.body.copyWith(fontSize: ZsType.fsSm, color: colors.textFaint),
          ),
        ),
        ZsButton(
          label: s.settingsConfigRevert,
          size: ZsButtonSize.md,
          onPressed: dirty ? _revert : null,
          identifier: 'settings-config-revert',
        ),
        ZsButton(
          label: s.settingsConfigSave,
          size: ZsButtonSize.md,
          variant: ZsButtonVariant.primary,
          onPressed: dirty ? () => unawaited(_save()) : null,
          identifier: 'settings-config-save',
        ),
      ],
    );
  }
}

// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart' show trunkKey;
import 'package:zanshin/src/features/settings/settings_view_model.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/sync/sync_model.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_remote_sync.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/settings_rig.dart';

const _credential = Remote(name: 'mirror', url: 'https://ralph:tok@git.example.com/t.git', pushUrl: null);

/// The rig on Settings › Project with a project window sync over [sync] (no remotes until a test names some).
Future<SettingsRig> _pump(
  WidgetTester tester, {
  FakeRemoteSync? sync,
  void Function(SettingsRig rig)? configure,
}) async {
  final rig = SettingsRig(tester);
  configure?.call(rig);
  if (sync != null) {
    final toasts = ShellToasts();
    final model = SyncModel(
      sync: sync,
      graph: rig.model,
      toasts: toasts,
      pollSetting: () => RemotePollSetting.off,
    );
    rig.sync = model;
    addTearDown(toasts.dispose);
  }
  await rig.pump(target: SettingsTarget.project);
  if (rig.sync case final SyncModel model) {
    addTearDown(model.dispose);
  }
  return rig;
}

extension on SettingsRig {
  /// Picks [item] (`rename`, `set-url`, `remove`) from [remote]'s ••• menu.
  Future<void> menu(String remote, String item) async {
    await tap('settings-remote-more-$remote');
    await tester.pumpAndSettle();
    await tester.tap(id('settings-remote-$item-$remote'));
    // The picked row blinks (a timer) before the menu closes and reports it.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  /// Taps the Remove sheet's [button] and lets the sheet leave and the verb land.
  Future<void> answer(String button) async {
    await tester.tap(find.text(button).last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  Future<void> type(String label, String text) async {
    await tester.enterText(
      // The field beside its label on the form's 72 px column.
      find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
        matching: find.byType(EditableText),
      ),
      text,
    );
    await settle();
  }

  String get command =>
      tester.widget<Text>(find.descendant(of: id('settings-remote-command'), matching: find.byType(Text))).data!;

  Future<void> run() async {
    await tap('settings-remote-run');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await settle();
  }
}

/// Every text on screen, rich text included.
List<String> _texts(WidgetTester tester) => <String>[
  for (final RichText text in tester.widgetList<RichText>(find.byType(RichText))) text.text.toPlainText(),
  for (final EditableText field in tester.widgetList<EditableText>(find.byType(EditableText))) field.controller.text,
];

void main() {
  setUpIconRegistry();

  test('scrubRemoteUrl hides everything between scheme:// and @, case-insensitively', () {
    expect(scrubRemoteUrl('https://ralph:tok@git.example.com/t.git'), 'https://•••@git.example.com/t.git');
    expect(scrubRemoteUrl('HTTPS://tok@h/x'), 'HTTPS://•••@h/x');
    expect(scrubRemoteUrl('https://u:p@ss@host/x.git'), 'https://•••@host/x.git', reason: 'an unencoded @');
    expect(scrubRemoteUrl('git@github.com:ralph/x.git'), 'git@github.com:ralph/x.git');
    expect(scrubRemoteUrl('https://github.com/a@b/x'), 'https://github.com/a@b/x', reason: 'an @ after the host');
  });

  test('remoteRefusal renders jj-lib\'s text from the code, the name as_symbol', () {
    expect(
      remoteRefusal(const ZanshinFfiException('jj.remote_exists', 'origin'), 'origin').message,
      "Git remote named 'origin' already exists",
    );
    expect(
      remoteRefusal(const ZanshinFfiException('jj.remote_not_found', 'a b'), 'a b').message,
      "No git remote named '\"a b\"'",
    );
    final RemoteRefusal reserved = remoteRefusal(
      const ZanshinFfiException('jj.invalid_input', "Git remote named 'git' is reserved for local Git repository"),
      'git',
    );
    expect(reserved.message, "Git remote named 'git' is reserved for local Git repository");
    expect(reserved.help, RemoteHelp.reservedName);
    expect(remoteRefusal(const ZanshinFfiException('jj.invalid_input', 'Invalid Git remote name'), 'a~').help, isNull);
    expect(remoteRefusal(const ZanshinFfiException('jj.other'), 'x').message, 'jj.other');
  });

  testWidgets('the list: name, scrubbed URL, push URL; Add remote… after; a credential shows nowhere', (tester) async {
    final SettingsRig rig = await _pump(
      tester,
      configure: (rig) => rig.reads.remoteList = <Remote>[
        const Remote(name: 'origin', url: 'git@github.com:ralph/myapp.git', pushUrl: null),
        const Remote(name: 'upstream', url: 'https://github.com/acme/x.git', pushUrl: 'git@github.com:ralph/x.git'),
        _credential,
      ],
    );

    expect(find.text('git@github.com:ralph/myapp.git', findRichText: true), findsOneWidget);
    expect(find.textContaining('git@github.com:ralph/x.git', findRichText: true), findsOneWidget);
    expect(find.text('https://•••@git.example.com/t.git', findRichText: true), findsOneWidget);
    expect(find.bySemanticsLabel('mirror, https://•••@git.example.com/t.git'), findsOneWidget);
    expect(rig.id('settings-remote-add'), findsOneWidget);
    expect(_texts(tester).where((text) => text.contains('tok')), isEmpty);
    expect(
      tester.widgetList<ZsTooltip>(find.byType(ZsTooltip)).where((tip) => tip.message.contains('tok')),
      isEmpty,
    );
    // The group's other rows follow.
    expect(
      tester.getRect(rig.id('settings-remote-add')).bottom,
      lessThanOrEqualTo(tester.getRect(rig.id('settings-git-fetch')).top),
    );
  });

  testWidgets('no remotes: the empty row, then Add remote…', (tester) async {
    await _pump(tester, configure: (rig) => rig.reads.remoteList = <Remote>[]);
    expect(find.text('No remotes yet. Fetch and push need one.'), findsOneWidget);
  });

  testWidgets('Add issues the verb with its command; the row appears; the sync reads the remotes again', (
    tester,
  ) async {
    final sync = FakeRemoteSync()..names = <String>[];
    final SettingsRig rig = await _pump(tester, sync: sync);
    expect(rig.sync!.hasRemote, isFalse);

    await rig.tap('settings-remote-add');
    expect(rig.command, "jj git remote add '<name>' '<url>'");
    expect(tester.widget<ZsButton>(find.byType(ZsButton).last).onPressed, isNull, reason: 'off until name and URL');
    await rig.type('Name', 'fork');
    await rig.type('URL', 'https://github.com/ralph/x.git');
    await rig.type('Push URL', 'git@github.com:ralph/x.git');
    expect(rig.command, 'jj git remote add fork https://github.com/ralph/x.git --push-url git@github.com:ralph/x.git');

    sync.names = <String>['fork'];
    await rig.run();
    expect(rig.reads.verbs, <String>['add fork https://github.com/ralph/x.git git@github.com:ralph/x.git']);
    expect(rig.id('settings-remote-form'), findsNothing);
    expect(rig.id('settings-remote-fork'), findsOneWidget);
    expect(rig.sync!.hasRemote, isTrue, reason: 'the project window sync re-read the remotes');
  });

  testWidgets("a taken name: the form stays, jj's text under the command; the next edit clears it", (tester) async {
    final SettingsRig rig = await _pump(tester);
    rig.reads.verbError = const ZanshinFfiException('jj.remote_exists', 'origin');

    await rig.tap('settings-remote-add');
    await rig.type('Name', 'origin');
    await rig.type('URL', 'https://github.com/jj-vcs/jj.git');
    await rig.run();

    expect(rig.id('settings-remote-form'), findsOneWidget);
    expect(find.text("Git remote named 'origin' already exists"), findsOneWidget);
    await rig.type('Name', 'origin2');
    expect(find.text("Git remote named 'origin' already exists"), findsNothing);
  });

  testWidgets('the reserved name: jj-lib\'s reason and the help sentence', (tester) async {
    final SettingsRig rig = await _pump(tester);
    rig.reads.verbError = const ZanshinFfiException(
      'jj.invalid_input',
      "Git remote named 'git' is reserved for local Git repository",
    );
    await rig.tap('settings-remote-add');
    await rig.type('Name', 'git');
    await rig.type('URL', 'https://x/y.git');
    await rig.run();

    expect(find.text("Git remote named 'git' is reserved for local Git repository"), findsOneWidget);
    expect(
      find.text('jj uses the name git for the repository on disk. Pick another name.', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets("Add's duplicate URL warning shows under the new row with jj's hint until the next verb", (tester) async {
    final SettingsRig rig = await _pump(tester);
    rig.reads.addWarnings = const <ZanshinWarning>[
      ZanshinWarning(code: ZanshinWarningCode.remoteUrlDuplicate, message: 'Remote origin already uses the same URL.'),
    ];
    await rig.tap('settings-remote-add');
    await rig.type('Name', 'dup');
    await rig.type('URL', 'git@github.com:ralph/myapp.git');
    await rig.run();

    expect(
      find.text(
        'Remote origin already uses the same URL. If this was a mistake, run `jj git remote remove dup`.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    await rig.menu('dup', 'rename');
    expect(find.textContaining('already uses the same URL', findRichText: true), findsNothing);
  });

  testWidgets('Rename selects the name; off until it differs; runs and renames the row; not found is verbatim', (
    tester,
  ) async {
    final SettingsRig rig = await _pump(tester);
    await rig.menu('upstream', 'rename');
    final EditableText field = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(field.controller.text, 'upstream');
    expect(field.controller.selection, const TextSelection(baseOffset: 0, extentOffset: 8));
    expect(tester.widget<ZsButton>(find.byType(ZsButton).last).onPressed, isNull);
    expect(rig.command, 'jj git remote rename upstream upstream');

    await rig.type('New name', 'fork');
    expect(rig.command, 'jj git remote rename upstream fork');
    expect(find.text('Its remote bookmarks follow: main@upstream becomes main@fork.'), findsOneWidget);
    await rig.run();
    expect(rig.reads.verbs, <String>['rename upstream fork']);
    expect(rig.id('settings-remote-fork'), findsOneWidget);

    rig.reads.verbError = const ZanshinFfiException('jj.remote_not_found', 'fork');
    await rig.menu('fork', 'rename');
    await rig.type('New name', 'x');
    await rig.run();
    expect(find.text("No git remote named 'fork'"), findsOneWidget);
  });

  testWidgets('Set URL sends only the changed side; a credential URL starts empty under its scrubbed placeholder', (
    tester,
  ) async {
    final SettingsRig rig = await _pump(
      tester,
      configure: (rig) => rig.reads.remoteList = <Remote>[...rig.reads.remoteList, _credential],
    );
    await rig.menu('upstream', 'set-url');
    expect(tester.widget<ZsButton>(find.byType(ZsButton).last).onPressed, isNull, reason: 'nothing changes');
    await rig.type('Push URL', 'git@github.com:ralph/x.git');
    expect(rig.command, 'jj git remote set-url upstream --push git@github.com:ralph/x.git');
    await rig.run();
    expect(rig.reads.verbs, <String>['set-url upstream null git@github.com:ralph/x.git']);

    await rig.menu('mirror', 'set-url');
    final ZsTextField url = tester.widget<ZsTextField>(find.byType(ZsTextField).first);
    expect(url.controller!.text, isEmpty);
    expect(url.placeholder, 'https://•••@git.example.com/t.git');
    expect(find.text('Holds a credential, so it stays hidden. Type a new URL to replace it.'), findsOneWidget);
    await rig.type('URL', 'https://ralph:new@git.example.com/t.git');
    expect(rig.command, "jj git remote set-url mirror 'https://•••@git.example.com/t.git'");
    expect(_texts(tester).where((text) => text.contains('tok')), isEmpty);
  });

  testWidgets('Esc cancels the form and returns focus to the row\'s •••', (tester) async {
    final SettingsRig rig = await _pump(tester);
    await rig.menu('origin', 'rename');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await rig.settle();
    expect(rig.id('settings-remote-form'), findsNothing);
    expect(rig.reads.verbs, isEmpty);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote origin more');
  });

  testWidgets('Remove asks on the window first; Cancel changes nothing; confirm removes the row', (tester) async {
    final SettingsRig rig = await _pump(tester);
    await rig.menu('upstream', 'remove');
    expect(find.text('Remove upstream?'), findsOneWidget);
    expect(find.text('jj git remote remove upstream'), findsOneWidget);

    await rig.answer('Cancel');
    expect(find.text('Remove upstream?'), findsNothing);
    expect(rig.reads.verbs, isEmpty);

    await rig.menu('upstream', 'remove');
    await rig.answer('Remove remote');
    expect(rig.reads.verbs, <String>['remove upstream']);
    expect(rig.id('settings-remote-upstream'), findsNothing);
  });

  testWidgets('a refused remove shows jj\'s text and the help under the row', (tester) async {
    final SettingsRig rig = await _pump(tester);
    rig.reads.verbError = const ZanshinFfiException('jj.remote_nonstandard_config', 'upstream');
    await rig.menu('upstream', 'remove');
    await rig.answer('Remove remote');

    expect(find.text("Git remote named 'upstream' has nonstandard configuration"), findsOneWidget);
    expect(find.textContaining('git remote remove upstream removes it.', findRichText: true), findsOneWidget);
    expect(rig.id('settings-remote-upstream'), findsOneWidget);
  });

  testWidgets('↩ runs the form; ↩ while the verb is off issues nothing', (tester) async {
    final SettingsRig rig = await _pump(tester);
    await rig.tap('settings-remote-add');
    await rig.type('Name', 'fork');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await rig.settle();
    expect(rig.reads.verbs, isEmpty, reason: 'no URL yet');

    await rig.type('URL', 'https://x/y.git');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await rig.settle();
    expect(rig.reads.verbs, <String>['add fork https://x/y.git null']);
  });

  testWidgets('a rename re-reads the trunk alias and recounts the immutable commits', (tester) async {
    final SettingsRig rig = await _pump(tester);
    expect(find.text('14'), findsOneWidget);
    rig.env.configEntries[trunkKey] = <ConfigEntry>[
      const ConfigEntry(
        name: trunkKey,
        value: '"main@fork"',
        source: ConfigValueSource.repo,
        path: null,
        overridden: false,
      ),
    ];
    rig.reads.count = const RevsetCount(n: 20, capped: false, error: null);

    await rig.menu('upstream', 'rename');
    await rig.type('New name', 'fork');
    await rig.run();

    expect(find.descendant(of: rig.id('settings-trunk'), matching: find.text('main@fork')), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
  });

  testWidgets('a project switch while a verb runs drops its results', (tester) async {
    final sync = FakeRemoteSync()..names = <String>[];
    final SettingsRig rig = await _pump(tester, sync: sync);
    rig.reads.verbGate = Completer<void>();
    await rig.tap('settings-remote-add');
    await rig.type('Name', 'fork');
    await rig.type('URL', 'https://x/y.git');
    await rig.tap('settings-remote-run');

    await tester.runAsync(rig.session.closeProject);
    await rig.settle();
    sync.names = <String>['fork'];
    rig.reads.verbGate!.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await rig.settle();

    final SettingsViewModel vm = rig.content.viewModel;
    expect(rig.reads.verbs, hasLength(1));
    expect(vm.remoteList, isEmpty, reason: "the old project's remotes stay out");
    expect(vm.remoteNotes, isEmpty);
    expect(rig.sync!.hasRemote, isFalse, reason: 'no sync reload for the old project');
  });

  testWidgets('a Fetch from naming a remote no longer there reads "— not a remote"', (tester) async {
    final SettingsRig rig = await _pump(
      tester,
      configure: (rig) => rig.env.configEntries['git.fetch'] = <ConfigEntry>[
        const ConfigEntry(
          name: 'git.fetch',
          value: '"gone"',
          source: ConfigValueSource.repo,
          path: null,
          overridden: false,
        ),
      ],
    );
    expect(
      find.descendant(of: rig.id('settings-git-fetch'), matching: find.text('gone — not a remote')),
      findsOneWidget,
    );
  });
}

---
title: 'Story 11.18 — Remote management in Settings: add, rename, remove, set URL'
type: 'feature'
created: '2026-11-06'
status: 'done'
baseline_revision: '40d85773ba670d908d7fca503bbd982fff58839e'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The Marionette witness (the running Settings window or its Widgetbook use case compared with the DS card "Settings — Remotes and config file") was not run.
    evidence: |-
      Running the catalogue or the app needs a long-lived `flutter run`, which this unattended, no-background run could not hold; the Remotes group is covered by widget tests only, and the SettingsGroup ClipRRect (every Settings group) is unchecked visually.
    location: >-
      app/lib/src/features/settings/remotes_group.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** 9.5's `jj git remote add / rename / remove / set-url` (done, on `RepoHandle`) have no UI; Settings › Project's Remotes group only picks the fetch and push remotes (deferred-work I1).

**Approach:** Build the DS `RemotesGroup` (sync #20) into Settings › Project: the remote list (name, scrubbed fetch URL, push URL when it differs), a ••• menu per row (Rename… · Set URL… · Remove…), "Add remote…" as the last row, in-row forms with the exact shell-quoted command, jj's refusal verbatim, Remove through a destructive `ZsConfirmDialog` sheet on the Settings window. After any verb the Settings selects, the sync model (Fetch/Push enable, poll) and an open Push sheet re-read the remotes.

## Boundaries & Constraints

**Always:**
- Build to the DS: `design_system/components/settings/RemotesGroup.{jsx,prompt.md,d.ts}`, `settings.css:57-90` (`.zs-rem-*`), card `remotes-config.card.html`. DS wins over the prototype `design/remotes.jsx`. Control heights / tokens from `zanshin_ui`; visible controls are Zs controls only.
- A credential never shows: rows, tooltips, form fields, placeholders and commands hide everything between `scheme://` and `@` as `•••` (DS `zsRemScrub`: `^([a-z][a-z0-9+.-]*://)[^/@]+@` case-insensitive → `$1•••@`). Set URL on a remote whose URL holds one starts that field empty with the scrubbed form as placeholder; a Set URL push field starts empty when the push URL holds one.
- Commands are the CLI's, each word POSIX shell-quoted (reuse `jjCommand` in `graph_ports.dart`), URLs scrubbed: `jj git remote add <name> <url> [--push-url <push>]`, `jj git remote rename <old> <new>`, `jj git remote set-url <name> [<url>] [--push <push>]`, `jj git remote remove <name>`; a missing name/url shows `<name>`/`<url>`/`<new name>` placeholders as in the DS.
- Set URL sends only the sides that change (trimmed, non-empty, different from the current value); both unchanged → the verb button is off. Rename's button is off until the new name is non-empty and differs; Add's until name and URL are non-empty.
- jj's text verbatim, keyed by the bridge's error code (never parsed from text), name formatted with `jjRevsetSymbol` (jj-lib's `as_symbol`): `jj.remote_exists` → `Git remote named '<n>' already exists`; `jj.remote_not_found` → `No git remote named '<n>'`; `jj.remote_nonstandard_config` → `Git remote named '<n>' has nonstandard configuration` + help sentence (l10n) naming `git remote remove <n>`; `jj.invalid_input` → its `context` verbatim (jj-lib's reason), plus the reserved-name help sentence when the name the user typed is `git`; anything else → `context ?? code`. jj strings carry `// l10n-ignore: jj's text`.
- Add's `jj.remote_url_duplicate` warning shows under the new row: the warning message verbatim + jj's hint `If this was a mistake, run \`jj git remote remove <n>\`.` (CLI `add.rs:111-115` @ v0.47.0), until the next verb.
- No undo toast for any remote verb. After every verb that succeeded: Settings re-reads remotes + defaults + trunk choices; `graph.value?.sync?.reloadRemotes()`. The graph already reloads on op-head events (no extra call).
- A Fetch from / Push to value naming a remote that no longer exists stays in its select, labelled `<name> — not a remote` (l10n).
- All new UI strings in `app/lib/l10n/app_en.arb`, then `flutter gen-l10n`.

**Never:**
- No Rust, FFI, schema or `zanshin_core` change (all verbs and the `Remote` read exist). No ConfigFilePage, no resizable Settings window (Story 11.19). No remote-bookmark management, no forge integration.
- Never `Display` a credential, never log a URL.
- No undo toast; no own "is it the same URL" check (jj's warning does it).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Add | name `upstream`, URL `https://github.com/acme/x.git` | `gitRemoteAdd(name, url, pushUrl: null)`; form closes; row appears | — |
| Add taken name | name `origin` exists | form stays, name field marked, `Git remote named 'origin' already exists` under the command | refusal, alert semantics |
| Add reserved | name `git` | jj's `invalid_input` context verbatim + reserved help sentence | refusal |
| Add duplicate URL | URL equals origin's | row added; warning `Remote origin already uses the same URL.` + hint under the new row | warning |
| Rename | `upstream` → `fork` | `gitRemoteRename('upstream','fork')`; row renamed | taken/reserved → refusal in form |
| Set URL push only | URL untouched, push typed | `gitRemoteSetUrl(name, url: null, pushUrl: typed)`; command `jj git remote set-url name --push <push>` | — |
| Credential URL | `https://ralph:tok@git.example.com/t.git` | shown/command/tooltip `https://•••@git.example.com/t.git`; Set URL field empty, scrubbed placeholder | — |
| Remove | ••• › Remove… › confirm | sheet "Remove upstream?" with command; confirm → `gitRemoteRemove`; row gone | nonstandard config → refusal + help under the row |
| Removed default | `git.fetch = "upstream"`, upstream removed | Fetch from select shows `upstream — not a remote` | — |
| No remotes | empty list | `No remotes yet. Fetch and push need one.` row, then Add remote… | — |

</intent-contract>

## Code Map

- `app/lib/src/features/settings/project_tab.dart:106-127` -- the Remotes group today (Fetch from, Push to, Check for remote changes); becomes `SettingsRemotesGroup(vm, children: <those three rows>)`. `_remoteRow:206-241` builds the select options (`shown` added when not a remote → label it "— not a remote").
- `app/lib/src/features/settings/settings_view_model.dart:47-68` -- port `SettingsRepoReads` (fake in tests/widgetbook); `RepoSettingsReads:71-122` over `ProjectRepo.handle`. `remotes` (names, :179), `_readRemotes:351-372`, `settingsErrorText:125`, `graph` (`GraphMenuBinding`, has `.sync`).
- `app/lib/src/features/settings/settings_window.dart:121-201` -- window content; the Remove sheet goes in a `Stack` over the `ZsWindowScaffold`, as `revset_configs_window.dart:473-485` does (`ZsConfirmDialog` in `Positioned.fill`, `closing` + `onClosed` pattern at :302-318).
- `app/lib/src/features/settings/settings_widgets.dart` -- `SettingsGroup` (rows divided by `--fl-border`), `SettingsRow` (min 46, padding 14/8; `stack`).
- `packages/zanshin_core/lib/src/worker/handle.dart:350-360, 2021-2121` -- `remotes()` → `WarnedList<Remote>` (`Remote{name, url?, pushUrl?}`, pushUrl only when it differs, URLs unredacted via gix `to_bstring`); `gitRemoteAdd/Remove/Rename/SetUrl` → `MutationResult` (`.warnings: List<ZanshinWarning>{code,message}`); errors `ZanshinFfiException{code, context}` (context = the offending name for `remote_exists/not_found/nonstandard_config`, jj-lib's reason for `invalid_input`).
- `packages/zanshin_core/lib/src/ffi/warning.dart:94` -- `ZanshinWarningCode.remoteUrlDuplicate = 'jj.remote_url_duplicate'`.
- `~/.cargo/registry/src/*/jj-lib-0.47.0/src/git.rs:172-182, 2521-2539` -- jj-lib's message templates (read-only reference).
- `app/lib/src/features/graph/graph_ports.dart:697-713` -- `jjCommand(args)` (shell-quoting); `app/lib/src/features/graph/graph_layout.dart:59-61` -- `jjRevsetSymbol` (as_symbol).
- `app/lib/src/features/sync/sync_model.dart:131-139` -- `_loadRemotes`/`reloadRemotes`; `_changes` (poll badge, keyed by remote); `_push` (open `PushSheetModel`). `push_sheet_model.dart:186-212` -- `_busy`, `load()` (reads remote names, defaults, config, replans).
- `packages/zanshin_ui` -- `ZsConfirmDialog` (destructive, `cmd`, `identifier`), `ZsMenuAnchor`/`ZsMenuItem`/`ZsMenuSeparator` (see `immutable_page.dart:141` for an anchored menu in Settings), `ZsIconButton`, `ZsButton`, `ZsTextField`, `ZsTooltip`, `ZanshinIcon(ZI.conflict|ZI.plus|ZI.more)`.
- `app/test/features/settings/settings_window_test.dart:35-` -- fake `_Reads`; `app/test/features/settings/repo_settings_reads_test.dart` -- real-worker pattern (`ZanshinWorker.start`, `initRepo(path, backend:)`, `WorkerProjectRepos(...).open`).
- `app/widgetbook/folders/windows.dart:529-` -- `_DemoSettingsReads` (the Settings window use-case); add the DS card's remotes (incl. a credential URL and a push URL).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/settings/settings_view_model.dart` -- port: replace `remoteNames()` with `remotes()` → `List<Remote>`; add `remoteAdd({name,url,pushUrl})`, `remoteRename(old,new)`, `remoteSetUrl({name,url,pushUrl})`, `remoteRemove(name)`, each returning the call's `List<ZanshinWarning>` (implement in `RepoSettingsReads` over the handle; update doc to "reads and remote verbs"). VM: `remoteList` (`List<Remote>`), `remotes` stays the names; a `RemoteOp` (sealed: add/rename/setUrl/remove) with `command` (scrubbed, quoted) and a `runRemote(op)` returning `RemoteOutcome?` (refusal `{message, help?}` or warning `{message, hint}`); success re-reads remotes and calls `graph.value?.sync?.reloadRemotes()`. Remove ask state (`removing`, `closing`) + per-remote notes (refusal/warning) live in the VM so the window-level sheet and the row share them; notes clear on the next verb. Pure helpers `scrubRemoteUrl`, `remoteRefusal(ZanshinFfiException, typedName)` -- one source for the rules.
- `app/lib/src/features/settings/remotes_group.dart` (new) -- `SettingsRemotesGroup`: rows per DS (name `--fs-base`; URL mono `--fs-id` `--text-dim`, one line, ellipsis, scrubbed tooltip; `push` + URL line when it differs; *No fetch URL* italic-less `--text-faint` sans), ••• `ZsIconButton` per row with a `ZsMenuAnchor` (Rename… · Set URL… · separator · Remove…, command in the right column), Add remote… row (`ZI.plus`, tooltip `jj git remote add`), empty row, in-row form (`--fl-on`, 72 px label column, fields, command well, refusal, Cancel + gold primary; ↩ runs when enabled, Esc cancels and refocuses the row's •••; first field focused, Rename selects the name), field hints from the DS, notes under rows. Semantics identifiers `settings-remote-<name>`, `settings-remote-more-<name>`, `settings-remote-add`, `settings-remote-form`, `settings-remote-run`, `settings-remote-cancel`, `settings-remote-command`; rows read "<name>, <scrubbed url>"; refusal is a live region.
- `app/lib/src/features/settings/project_tab.dart` -- use `SettingsRemotesGroup` with the three existing rows as children; label a select option that is not a remote `<name> — not a remote`.
- `app/lib/src/features/settings/settings_window.dart` -- the destructive `ZsConfirmDialog` sheet over the window while the VM asks (title `Remove <n>?`, body per DS with `main@<n>` and `jj undo` in mono, `cmd`, `Remove remote`, identifier `settings-remote-remove`); confirm runs the remove, refusal lands under the row.
- `app/lib/src/features/sync/sync_model.dart` + `push_sheet_model.dart` -- `reloadRemotes()` also drops poll `_changes` entries for remotes no longer fetched, and re-runs an open, idle Push sheet's `load()` (new public `PushSheetModel.reloadRemotes()` that is a no-op while busy).
- `app/lib/l10n/app_en.arb` -- the strings (menu items, labels, placeholders, hints, empty row, sheet title/body/button, help sentences, "— not a remote"); run `flutter gen-l10n` in `app/`.
- `app/test/features/settings/remotes_group_test.dart` (new) -- fake-port widget tests: each verb issues the right port call and shows its command; refusals verbatim per code (exists, not found, nonstandard + help, invalid_input + reserved help); duplicate-URL warning + hint; credential never in any text/tooltip/field; set-url sends only changed sides; Remove goes through the sheet, Cancel changes nothing; removed default select label; after a verb `sync.reloadRemotes` is called. Update `settings_window_test.dart`'s fake.
- `app/test/features/settings/repo_settings_reads_test.dart` -- real-worker test: Git-backend temp repo, `RepoSettingsReads` adds, renames, sets the URL of and removes a remote, `remotes()` reflecting each.
- `app/test/features/sync/*` -- `reloadRemotes` drops stale poll changes and reloads an idle open Push sheet.
- `app/widgetbook/folders/windows.dart` -- demo reads implement the new port (DS card's three remotes; verbs mutate an in-memory list; `upstream` remove refuses nonstandard).

**Acceptance Criteria:**
- Given Settings › Project with remotes origin, upstream (push URL differs) and mirror (credential URL), when it shows, then the Remotes group lists them per DS with mirror's credential as `•••`, then Add remote…, Fetch from, Push to, Check for remote changes.
- Given any remote form or the Remove sheet, when shown, then it shows the exact shell-quoted jj command with credentials hidden, and ↩/Esc run/cancel.
- Given a verb jj refuses, when run, then jj's message shows verbatim (plus the DS help sentence where defined) and nothing else changes.
- Given a verb succeeded, when it lands, then the Settings selects, the toolbar Fetch/Push enablement and the poll use the new remote list without a View › Reload.
- Given the running widgetbook Settings use-case, when checked with Marionette, then it matches the DS card "Settings — Remotes and config file" (left column) within the "design is inspiration" tolerance.

## Spec Change Log

## Review Triage Log

### 2026-11-06 — Review pass
- verdicts: 32 findings — high 0, medium 3, low 21, false 8, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) rename/remove's trunk re-read + immutable recount untested — added a test: trunk `main@fork` and count 20 show after renaming upstream to fork.
  - `[low]` `[patch]` (verification-gap) ↩ running a form untested — added a test: ↩ with only a name issues nothing, with a URL issues `add`.
  - `[low]` `[patch]` (verification-gap) Push sheet's closing guard in `reloadRemotes` untested — added a push_sheet_model test after `cancel()`.
  - `[low]` `[reject]` (blind) `ssh://git@host` is scrubbed as a credential — the DS's own `zsRemScrub` does the same; a colon rule would leak `https://<token>@` URLs. Erring on hiding is the DS's choice.
  - `[false]` `[reject]` (blind) placeholders are shell-quoted — DS `zsSh` quotes `<name>` the same way (`<` is outside its safe set).
  - `[false]` `[reject]` (blind) set-url command has no placeholder — DS `zsRemCommand` shows the same bare form; the verb button is off then.
  - `[low]` `[reject]` (blind) spec names `jjRevsetSymbol`, code uses `jjRefSymbol` — fix would be a spec edit; `jjRefSymbol` is the exact port of jj-core 0.47's `RefSymbol` Display (`as_symbol`).
  - `[false]` `[reject]` (blind) group ClipRRect clips focus rings — rows pad 14 px; the ••• shift of 6 px leaves 8 px, nothing reaches the group edge.
  - `[low]` `[patch]` (blind) a non-FFI throw leaves the form spinning — `_FormRow._run` resets `_running` in a `finally`.
  - `[false]` `[reject]` (blind) `runRemote` null without reads closes the form — the Project tab (and so the group) exists only with an open repo, which sets `_reads`.
  - `[low]` `[reject]` (blind) focus not restored after a successful verb — DS specifies refocus only for Esc; adds focus plumbing for a rare path.
  - `[false]` `[reject]` (blind) notes clear when a form opens — DS `open()` clears them (`setNotes({})`), as built.
  - `[low]` `[reject]` (blind) a second verb can start while a remove runs — needs a click inside the remove's few ms; fix adds a busy state across the group.
  - `[low]` `[reject]` (blind) a failed fetch-remotes read clears poll findings — only on a closed handle / native repo, where the badge has no meaning; guard adds a branch.
  - `[low]` `[patch]` (blind) ↩ / Esc not tested — same as the ↩ verification gap; covered by the new ↩ test (Esc already tested; the sheet's Esc is ZsConfirmDialog's own, tested in zanshin_ui).
  - `[low]` `[reject]` (blind) more untested paths (nonstandard help after rename, url-null Set URL, reload after each verb) — same code paths as tested ones.
  - `[low]` `[reject]` (blind) VoiceOver row label omits the push URL — the DS prompt defines the label as "name, url".
  - `[low]` `[patch]` (blind) widgetbook demo token uses GitHub's `ghp_` prefix — now `ralph:secret@`.
  - `[false]` `[reject]` (blind) `remotes` getter allocates per call — no identity-based change detection reads it; cost negligible.
  - `[low]` `[reject]` (blind) epic-11-context says 11.18 is backlog — the compiled context is a planning snapshot, regenerated when the planning docs change.
  - `[low]` `[reject]` (edge) a poll in flight across a reload can restore a removed remote's findings — the next poll corrects it; a generation guard for a rare race.
  - `[low]` `[reject]` (edge) a busy Push sheet skips the reload — the spec's chosen behavior; the sheet re-reads when reopened.
  - `[medium]` `[patch]` (edge) a project switch during a verb wrote the old project's remotes into the new one — `runRemote` captures the generation and drops the result when it changed; test added.
  - `[low]` `[patch]` (edge) non-FFI error leaves the form stuck — same fix as the blind finding (`finally`).
  - `[false]` `[reject]` (edge) null from `runRemote` without reads — see the blind finding's refutation.
  - `[low]` `[reject]` (edge) failed read clears poll findings — same as the blind finding.
  - `[medium]` `[patch]` (edge) unencoded `@` in a password leaked part of it — scrub regex now runs to the last `@` before the path; test case added.
  - `[low]` `[reject]` (edge) a form for a remote that disappears stays in state — only this group changes remotes and it closes the form first.
  - `[low]` `[reject]` (edge) jjRevsetSymbol vs jjRefSymbol — spec wording; code is the exact port.
  - `[medium]` `[defer]` (intent) the Marionette witness vs the DS card was not run — needs a live `flutter run`, impossible in this unattended run; deferred (frontmatter + deferred-work.md).
  - `[low]` `[reject]` (intent) refusal text is reconstructed, not compared with jj — templates copied from jj-lib 0.47 (`git.rs:172-182, 2521-2539`), keyed by code as the epic rule allows; the pin-bump checklist re-checks copied refusals.
  - `[false]` `[reject]` (intent) raw URLs live in view-model memory — the intent forbids showing a credential, and every display path scrubs.

## Design Notes

Error-to-text is code-keyed, not text-parsed (epic rule "jj's own text stays verbatim … keyed by a kind the bridge sends"): the bridge sends the offending name in `context`, and the UI renders jj-lib's own template with `jjRevsetSymbol(name)` — exactly jj-lib's `as_symbol()` Display. `invalid_input` already carries jj-lib's reason verbatim.

Remove's ask + notes live in the VM because the sheet covers the whole Settings window (outside the group's subtree) while its refusal shows under a row inside it. The in-row form state stays local to the group widget.

## Verification

**Commands:**
- `flutter gen-l10n` (in `app/`) -- expected: regenerated, committed.
- `flutter test test/features/settings test/features/sync` (in `app/`) -- expected: all pass.
- `dart analyze` (in `app/`, incl. widgetbook) -- expected: no issues.
- `dart format --set-exit-if-changed lib test widgetbook` (in `app/`) -- expected: exit 0.

**Manual checks:**
- Marionette over the running widgetbook Settings use-case vs DS card `remotes-config.card.html` (rows, form, refusal, sheet).

## Auto Run Result

Status: done

**Summary.** Settings › Project's Remotes group now carries the DS `RemotesGroup` (sync #20): the remote list (name, scrubbed fetch URL, push URL when it differs, *No fetch URL*), a ••• menu per row (Rename… · Set URL… · Remove…), Add remote… last, in-row forms with the exact shell-quoted `jj git remote …` command (credentials as `•••`), ↩ runs / Esc cancels, jj's refusal verbatim (code-keyed jj-lib templates, `invalid_input` passed through) with the DS help sentences, Add's duplicate-URL warning + jj's hint, and Remove through a destructive `ZsConfirmDialog` sheet over the Settings window. A landed verb re-reads Settings' remotes/defaults/trunk choices (rename/remove also `trunk()` and the immutable count), reloads the project window's `SyncModel` (Fetch/Push enablement, poll findings pruned) and an idle open Push sheet. A Fetch from / Push to value naming a gone remote reads "<name> — not a remote". No Rust/FFI/zanshin_core change.

**Files changed** (under `app/`):
- `lib/src/features/settings/settings_view_model.dart` — port `remotes()` + four remote verbs; `RemoteOp` (commands), `RemoteOutcome`/`remoteRefusal`, `scrubRemoteUrl`; VM remote state, `runRemote` (generation-guarded), Remove ask state.
- `lib/src/features/settings/remotes_group.dart` (new) — `SettingsRemotesGroup` per DS.
- `lib/src/features/settings/project_tab.dart` — uses the group; "— not a remote" label.
- `lib/src/features/settings/settings_window.dart` — the Remove sheet over the window.
- `lib/src/features/settings/settings_widgets.dart` — `SettingsGroup` clips to its radius (form fill keeps the corners).
- `lib/src/features/sync/sync_model.dart`, `push_sheet_model.dart` — `reloadRemotes` prunes poll findings and reloads an idle open Push sheet.
- `lib/src/features/graph/graph_ports.dart` — public `shellQuote`.
- `lib/l10n/app_en.arb` + regenerated `app_localizations*.dart`.
- `widgetbook/folders/windows.dart` — demo reads with the DS card's three remotes, jj-like refusals.
- Tests: `test/features/settings/remotes_group_test.dart` (new, 17), `repo_settings_reads_test.dart` (real-worker add/rename/set-url/remove), `settings_window_test.dart` (shared rig), `test/helpers/settings_rig.dart` + `fake_settings_reads.dart` (new), `sync_model_test.dart`, `push_sheet_model_test.dart`.
- Also: `epic-11-context.md` recompiled (epics.md was newer), `sprint-status.yaml` 11-18 → done, `deferred-work.md` (one Medium item).

**Review findings.** 32 findings — 9 patched (2 medium: project switch during a verb, `@` in a password partly shown; 7 low: three test gaps, the stuck spinner ×2, ↩ test, demo `ghp_` token), 1 deferred (Marionette witness, medium), 14 rejected low and 8 false with reasons in the Review Triage Log. Deviations kept: `jjRefSymbol` (exact port of jj-core 0.47 `RefSymbol` Display) instead of the spec's `jjRevsetSymbol`; rename/remove also re-read `trunk()` and recount immutable commits (jj rewrites a `trunk()` naming the remote).

**Follow-up review recommendation:** false — patched: high 0, medium 2, low 7; both medium patches carry their own tests and the targeted suites re-ran green after them; no named unverified risk in the patched code.

**Deferred-work item I1** ("Remote management has no surface"): fixed — the Remotes group in Settings › Project offers add, rename, set URL and remove (commit hash below).

**Verification** (gate rule of this run: no full gate):
- `flutter gen-l10n` (app/) — ran.
- `dart analyze .` (app/, widgetbook included) — No issues found.
- `dart format --set-exit-if-changed lib test widgetbook` (app/) — 0 changed.
- `cargo make test-app test/features/settings test/features/sync test/l10n` — 125 passed, after the review patches (a plain `flutter test` fails `remote_sync_test`'s pushConfig test only because XDG_CONFIG_HOME is unpinned; untouched file).
- Not run: Marionette vs the DS card (deferred), the full gate (the loop runs it).

**Residual risks.** The layout is verified by widget tests only (no visual DS comparison yet); the `SettingsGroup` clip touches every Settings group; jj-lib's refusal templates are copied text that a pin bump must re-check.

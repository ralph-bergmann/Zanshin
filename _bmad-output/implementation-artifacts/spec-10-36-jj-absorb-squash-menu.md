---
title: 'Story 10.36 — jj absorb: a Squash menu in the inspector, a row in the card menu and the Change menu'
type: 'feature'
created: '2026-11-14'
status: 'done'
baseline_revision: 'eb8efe9551e6bab8953b57d9742e4c54113520f0'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      A foreign operation that lands between the runner's head read and a verb that wrote nothing makes the runner count the verb as written.
    evidence: |-
      GraphViewModel._execute reads headOpId() before the verb and sets wrote = result.newOpId != head; a no-op verb returns the pre-call head, which is the foreign operation's id. The toast then reads as a success (for absorb: "Absorbed X into 0 changes") and offers an Undo pinned to the foreign operation. Pre-existing for every verb that can write nothing (squash, rebase, restore, bookmark move, edit); absorb only adds a new wording of it. Rare: needs a concurrent jj in the same repo within one call.
    location: >-
      app/lib/src/features/graph/graph_view_model.dart:786-797
    severity: low
---

<intent-contract>

## Intent

**Problem:** `jj absorb` (move each hunk of a change into the nearest mutable ancestor that last changed those lines) is offered nowhere in the app. The backend verb exists, but `ChangeActions` has no absorb preview, and the DS / `zanshin_ui` have no button that opens a menu (deferred-work I1).

**Approach:** Add an `absorb` row to `ChangeActions` (Rust → schema → FFI → `zanshin_core`), a `GraphAbsorb` action through the graph's runner, a new `ZsMenuButton` (DS `MenuButton`) that turns the inspector's Squash button into a menu with "Squash into parent" and "Absorb into ancestors", and an "Absorb into ancestors" row in the card menu and the Change menu.

## Boundaries & Constraints

**Always:**
- The preview is `jj absorb --from X` with jj's defaults: `--into` is the `mutable()` alias, parsed and resolved exactly as `Repo::absorb` does (`crate::revset::parse_revset(repo, "mutable()", …)`, then `resolve_expression` with the row's id-prefix context), all paths; planned by `plan_absorb`, never by own rules. Status: Refused (the verb's own `MutateError`), `NoOp` when `target_commits` is empty (the CLI prints "Nothing changed."), else Available. It runs through `Rows::row` with `cli_command::ABSORB`.
- `absorb` is APPENDED as the last field of the `ChangeActions` table (FlatBuffers append-only), the Rust struct, the FFI wire object (8 outcomes) and the Dart model; `docs/ffi-abi.md`'s `ChangeActions` row says eight outcomes; run `cargo make codegen` and commit its output.
- `GraphAbsorb(id)`: command `jj absorb --from <id>`, `pendingKeys {id}`, anchor = the first shown parent of `id` (as Abandon). It runs through `GraphViewModel.run` like every verb (pending, anchored reload, refusal toast, undo). `GraphActions` gains `Future<AbsorbResult> absorb(String from)`; `RepoGraphActions.absorb` calls `handle.absorb(from: from)` (no `into`, no paths). The view model's `_execute` uses it for a `GraphAbsorb` and treats `absorbed.mutation` (with `absorbed.warnings`) as the result; `RepoGraphActions.run(GraphAbsorb)` throws `ArgumentError` like `GraphLoggedOperation`.
- After an absorb that wrote: flash = `rewrittenChangeIds`; the toast reads "Absorbed ‹source id› into N change(s)" (ICU plural, N = `rewrittenChangeIds.length`) with Undo; a run that wrote nothing toasts jj's "Nothing changed.". When jj abandoned the source (`rewrittenChangeIds` non-empty and `sourceChangeId == null`) and it was selected, the selection becomes null — as after Abandon.
- Inspector: the Squash button becomes a `ZsMenuButton` labelled "Squash" with a chevron (tooltip "Squash or absorb into earlier changes", identifier `inspector-squash-menu`, disabled with the blocked reason while the graph is busy/stale). Rows: "Squash into parent" (`cmd` `jj squash -r <short>`, runs `model.squash(key)`, disabled with the squash preview's refusal; identifier `inspector-squash`) and "Absorb into ancestors" (`cmd` `jj absorb --from <short>`, runs `graph.run(GraphAbsorb(key))`; disabled with the refusal's text, or for `NoOp` with "Nothing to absorb: no hunk belongs to an earlier change."; identifier `inspector-absorb`). Each row's tooltip is its disabled reason, else its full command.
- Card menu: "Absorb into ancestors" row (glyph `ZI.squashInto`, identifier `card-menu-absorb`) right after "Squash into parent" on a mutable, non-root change, enabled exactly like its siblings (disabled only by `blocked`). Change menu: "Absorb into Ancestors" / "Absorb ‹target› into Ancestors" right after Squash, enabled like Squash (`change(GraphAbsorb.new)`). Undo/Redo names it "Absorb ‹target›".
- `ZsMenuButton` (`packages/zanshin_ui`): a `ZsButton` look (variant, size, disabled reason) plus a trailing `chevron-down` at 12 px, opacity .75, 5 px after the label and 8 px before the right edge (mock-up `.isd-menubtn`), opening a `ZsMenuAnchor` with the given entries 4 px below its left edge; Space / ↩ / click open it; exported from `zanshin_ui.dart`. DS: `components/actions/MenuButton.{jsx,d.ts,prompt.md}`, its CSS in `actions.css`, a state card, the `_ds_bundle.js` block + header name, a readme change-log line, the kit inspector's Squash button as a MenuButton, a dated follow-up line under DESIGN-SYSTEM-SYNC #25; republish the DS and sync canvas `6sAzL5mDcVpWXevbTcempu` through the `design-artifacts` skill (A, B, E).
- New user text in `app/lib/l10n/app_en.arb` (run `flutter gen-l10n`, commit the output); jj's words stay literals with `// l10n-ignore`.

**Never:** absorb by drag and drop (the drop menu keeps ignoring the backend's drop-action absorb row, which stays); `--into`, paths, `--interactive`; a preview in the card menu or the Change menu; a new glyph; removing the drop-action absorb row; hand edits of generated files.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Two ancestors | X changes lines last changed in A and in B | preview Available; run moves each hunk to its ancestor; toast "… into 2 changes"; A and B flash | parity oracle equal to `jj absorb --from X` |
| Nothing absorbable | X only adds new files | preview `NoOp`; inspector row disabled with the nothing-to-absorb reason | card/Change menu run writes no operation, toast "Nothing changed." |
| Undescribed, whole | @ (no description) changes only A's and B's lines | jj abandons @; selection null when it was selected | parity oracle equal |
| Unknown id | id resolves to nothing | row Refused with `ChangeNotFound` | row disabled with jj's text |
| Busy graph | another action runs | menu button disabled with the blocked reason; card row disabled | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/drop_actions.rs` -- `ChangeActions` (:170), `change_actions` (:661), `Rows::row` (:331), the drop absorb row as the pattern (:433-444); `plan_absorb` / `rev` live in `mutate.rs` (:1983), `parse_revset` in `revset.rs:374`, `resolve_expression` in `revset.rs:973`; `Repo::absorb` (`repo.rs:3558`) is the verb to mirror; `Repo::change_actions` doc (`repo.rs:3733`) names the rows.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- `card()` (:924, 7 rows → 8), the card tests (:941-1023), `absorbable()` (:767), `change_actions_rows_agree_with_their_verbs` (:1185: add the absorb verb `repo.absorb(Some(x), None, &[])` and an absorbable pick).
- `crates/zanshin-jj/tests/it/api_stability.rs:1673`, `when_commands.rs:677` -- list every card field; add `absorb`.
- `schemas/envelope.fbs:2306-2317` -- `ChangeActions` table: append `absorb: ActionOutcome;`, update the doc comment.
- `crates/zanshin-ffi/src/envelope.rs:1237-1325` -- `ChangeActionsObj` (`[_; 8]`), `ok_change_actions`; its unit test (:2190); `crates/zanshin-ffi/tests/it/drop_actions_ffi.rs:466-490` `card_rows` + the round-trip tests.
- `docs/ffi-abi.md:2042` -- the `ChangeActions` row.
- `packages/zanshin_core/lib/src/ffi/drop_actions.dart:279-366` -- `ChangeActions` model + decoder; tests `test/ffi/drop_actions_test.dart:195-255`, `test/worker/drop_actions_test.dart:~183`; `lib/zanshin_core.dart:41` exports (add `AbsorbResult`, `SkippedPath` if needed by fakes).
- `crates/zanshin-parity/tests/oracle/scenarios.rs:1269-1279` (existing `absorb`), `main.rs:97` scenario list -- add `absorb_from_two_ancestors` (setup on BASE: `new -m D`, write a.txt / b.txt changes, `new -m E`; `--from D`) and `absorb_from_undescribed_at` (setup `new`; files change a.txt and b.txt; `--from` @).
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphAction` subclasses (:168-695; add `GraphAbsorb` after `GraphSquash`), `GraphActions` (:829), `RepoGraphActions.run` (:845).
- `app/lib/src/features/graph/graph_view_model.dart` -- `_execute` (:771), `_plan` (:833), `_succeeded` (:868, flash list :909).
- `app/lib/src/features/graph/graph_toasts.dart:245-338` -- `_text` switch: add `GraphAbsorb`.
- `app/lib/src/app/menu/app_menu.dart` -- `actionName` (:173-225), Change menu group (:512-541).
- `app/lib/src/features/graph/graph_card_menu.dart:215-227` -- the Squash row; add the absorb row after it; doc comment (:99).
- `app/lib/src/features/graph/graph_inspector.dart` -- `_previews` (:888), `squash(key)` (:748), the actions row (:2080-2174: `button()`, Squash button :2141-2148).
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` (`ZsMenuAnchor`, `ZsMenuItem.cmd/tooltip`), `zs_button.dart:118-280` (`ZsButton`, `_paint`); new `zs_menu_button.dart`; `lib/zanshin_ui.dart` exports; tests `test/controls/zs_menu_test.dart` style.
- `app/widgetbook/folders/controls.dart:~960` (menu use case), `app/widgetbook/folders/graph.dart:1044`, `app/integration_test/glass_profile.dart:279` -- fakes of `ChangeActions` / `GraphActions`.
- Fakes of `GraphActions` (add `absorb`): `app/test/app/menu/app_menu_test.dart`, `app/test/helpers/fake_bookmark_list.dart:147`, `app/widgetbook/folders/{graph,bookmarks}.dart`, `app/test/features/graph/{graph_inspector,graph_drag,graph_controls,graph_view,graph_view_model}_test.dart`.
- Tests to adapt: `app/test/features/graph/graph_inspector_test.dart:690-739, 2576-2635` (Squash is now a menu row), `app/test/widgetbook/catalogue_smoke_test.dart:273`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/actions/` (Button.* as the pattern, `actions.css`, `actions.card.html`), `components/menus/Menu.d.ts` (cmd + note already exist), `_ds_bundle.js`, `readme.md`, `ui_kits/desktop/inspector.jsx`; mock-up `design/inspector-study.jsx:528-534, 592`, `inspector-study.css:71, 200-208`; `design/DESIGN-SYSTEM-SYNC.md` #25.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/drop_actions.rs` -- `absorb` field + row; doc of `ChangeActions` / `Repo::change_actions` -- the preview.
- `crates/zanshin-jj/tests/it/{drop_actions,api_stability,when_commands}.rs` -- eight rows; an absorbable card is Available, the others' expectations; agreement with the verb.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/envelope.rs` + its tests, `docs/ffi-abi.md`, `cargo make codegen` -- the wire.
- `packages/zanshin_core` -- model, decoder, export `AbsorbResult`; tests.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- the two scenarios.
- `packages/zanshin_ui` -- `ZsMenuButton` + export + widget test (opens the menu below itself, disabled with reason, keyboard open).
- DS via `design-artifacts` -- MenuButton component, card, bundle, readme, kit inspector, sync line, republish + canvas sync.
- `app/lib/src/features/graph/{graph_ports,graph_view_model,graph_toasts,graph_card_menu,graph_inspector}.dart`, `app/lib/src/app/menu/app_menu.dart`, `app/lib/l10n/app_en.arb` + gen-l10n -- the app.
- App fakes + tests -- `absorb` on every fake; inspector menu tests (rows, reasons, tooltips, runs); card menu row; Change menu entry; view model (flash, selection after abandon, no-op); toast text; catalogue use case for the menu button.

**Acceptance Criteria:**
- Given each I/O row, when the matching Rust, parity or widget test runs, then the expected behavior holds.
- Given a change, when `change_actions` and `jj absorb --from` run on the same fixture, then the row's status agrees with the verb (Available ⇒ new op, NoOp ⇒ none, Refused ⇒ same error).
- Given the inspector on a mutable change, when the Squash menu button is pressed, then a menu opens under it with the two rows, each with its command as `cmd` and tooltip, and choosing "Squash into parent" behaves as today's Squash button.
- Given a mutable card, when its menu opens, then "Absorb into ancestors" follows "Squash into parent", and the Change menu lists the absorb entry after Squash, both enabled.

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 37 findings — high 0, medium 0, low 24, false 13, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the toast count is `outcome.flash.length`, not `rewrittenChangeIds.length` — for a `GraphAbsorb` the flash holds exactly `rewrittenChangeIds` (`_succeeded`); carrying a second copy on `GraphOutcome` adds surface for no present harm.
  - `[false]` `[reject]` (blind) the toast says less than the CLI (no destination ids, no rebased count) — the story asks for "how many changes took hunks"; the flash shows which.
  - `[false]` `[reject]` (blind) `_absorbMutation` drops the nested warnings — the decoder never puts warnings on the nested mutation (`mutate.dart` `_decodeAbsorbResultEnvelope`); the call's warnings are `AbsorbResult.warnings`.
  - `[low]` `[patch]` (blind) `absorbed!` force-unwrapped in `_succeeded` — replaced by a null-safe check.
  - `[low]` `[reject]` (blind) the preview repeats `Repo::absorb`'s `mutable()` parse/resolve instead of sharing a helper — the agreement test (`change_actions_rows_agree_with_their_verbs`, absorb verb) guards drift; a helper is a refactor of the verb.
  - `[low]` `[reject]` (blind) no parity scenario for the NoOp path or an immutable source — the agreement test runs the verb after every row status, including NoOp; the verb's no-op path is Story 9.3's.
  - `[low]` `[reject]` (blind) `ZsMenuButton` has no tooltip parameter, so busy shows the reason twice — the same nesting as every inspector verb button (`button()`: `ZsTooltip` + `disabledReason`); pre-existing pattern.
  - `[low]` `[reject]` (blind) no `aria-haspopup` / expanded semantics — `ZsSelect` and the card menu anchor have none either; a semantics extension for every menu opener is wider than this story.
  - `[low]` `[patch]` (blind) `ZsMenuButton` defaults to 320 while the DS `MenuButton` defaults to 360; the inspector hard-codes 360 with a wrong comment — default 360, the inspector argument and comment removed.
  - `[low]` `[patch]` (blind) the chevron gap is 6 at `lg` (gap − 2) while the DS sets 5 for every size — fixed 5.
  - `[low]` `[reject]` (blind) no test for focus return or the first row highlighted on keyboard open — `ZsMenuAnchor`'s own behaviour, tested in `zs_menu_test.dart`; the button only forwards `controller.open`.
  - `[low]` `[reject]` (blind) the catalogue shows no open state — a click opens it, so Marionette can tap it; not a hover-only surface.
  - `[low]` `[reject]` (blind) the DS jsx never flips the menu and does not clear its close timer — the jsx is an illustration; the prompt describes the Flutter control, which flips.
  - `[false]` `[reject]` (blind) the shipped `part` file differs from the Code Map's plan — the fix would be a spec edit.
  - `[low]` `[reject]` (blind) `pendingKeys` covers only the source — the destinations are unknown before the verb runs; cosmetic.
  - `[low]` `[reject]` (blind) the plain Squash run is not tested through the menu row — the row calls the same `model.squash(key)` the old button called, tested directly.
  - `[false]` `[reject]` (blind) absorb ignores the file checkboxes — paths are a non-goal of the intent (epics.md Story 10.36 Non-goals).
  - `[low]` `[reject]` (blind) both rows are enabled while the previews load — Squash had the same window before; a run then gets jj's answer.
  - `[low]` `[reject]` (blind) the `api_stability` assert on `card.absorb` proves nothing — the test's purpose is the struct literal compiling; the assert mirrors the squash one beside it.
  - `[low]` `[reject]` (edge) the menu button stays enabled when `graph.hasActions` is false — only without an actions port (catalogue, tests); the real app always has one, and the rows are disabled.
  - `[low]` `[defer]` (edge) a foreign op between the head read and a no-op absorb toasts "Absorbed X into 0 changes" with Undo — pre-existing runner race for every no-op verb; deferred (frontmatter `deferred`, deferred-work.md).
  - `[false]` `[reject]` (edge) an empty `entries` list opens an empty menu — no caller passes one.
  - `[low]` `[patch]` (verification-gap) the absorb warnings path is not pinned: the toast fake carried warnings on the nested mutation too — the fake now puts them only on `AbsorbResult.warnings`.
  - `[low]` `[reject]` (verification-gap, other) same as the edge `hasActions` finding above.
  - `[false]` `[reject]` (intent) card and Change menu rows carry no preview — epics.md item 3 puts "disabled with its preview's reason" on the inspector rows only; both menus show the same state (enabled like Squash), and a run on nothing writes no operation, as the CLI.
  - `[false]` `[reject]` (intent) the abandoned source's `sourceChangeId == null` is untested against the real backend — `content_ops.rs` `absorb_abandons_a_discardable_source_and_reports_no_source_change_id` tests it.
  - `[low]` `[reject]` (intent) the inspector closing is tested only in the view model — the inspector is open exactly while something is selected (Story 10.8); `select(null)` closing it is tested there.
  - `[false]` `[reject]` (intent) Abandon's own selection rule is outside the diff — `_succeeded` sets `_selected = null` for `GraphAbandon` (`graph_view_model.dart`, unchanged).
  - `[low]` `[reject]` (intent) the toast count from flash — same as the blind finding above.
  - `[low]` `[reject]` (intent) the preview's Available is tested with one ancestor, not two — the two-ancestor run is the parity scenario; Available needs only one target.
  - `[low]` `[reject]` (intent) no app-level two-ancestor absorb — the backend and parity tests carry it; the app maps any count the same way.
  - `[false]` `[reject]` (intent) the DS republish and canvas sync are not shown — done: DS artifact version 1794671112-ec0a, canvas 6sAzL5mDcVpWXevbTcempu synced.
  - `[low]` `[reject]` (intent) prompt.md behaviours (flip, 8 px inset, focus return, popup semantics) untested on the Flutter side — `ZsMenuAnchor`'s placement and focus are tested in `zs_menu_test.dart`; semantics as above.
  - `[false]` `[reject]` (intent) #26's group heads and checks are missing — `ZsMenuAnchor` already has `ZsMenuHeader` and check items; 10.33 composes them.
  - `[false]` `[reject]` (intent) no `## Auto Run Result` with I1 — written at finalization.
  - `[false]` `[reject]` (intent) R2 reading tests absent — the chosen reading is tested (`graph_card_menu_test` "carries no preview", `app_menu_test`).
  - `[false]` `[reject]` (intent) the I1 outcome is only in prose — recorded under Auto Run Result.

## Design Notes

DS synced through #26. The menu style (#25) is already `ZsMenuAnchor` (`cmd` = the mono hint, `ZsMenuNote`); only the button is new, so `ZsMenuButton` composes `ZsButton` + `ZsMenuAnchor` rather than a new menu. The absorb row's glyph reuses `squash-into` (Claude's proposal; no new glyph). The card and Change menus carry no preview, like their Squash siblings: running absorb on nothing absorbable writes no operation and toasts jj's "Nothing changed." — the CLI's behavior. The absorb result reaches the view model through `GraphActions.absorb`, because `MutationResult` cannot carry the destinations.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it drop_actions:: api_stability:: when_commands::` -- pass.
- `cargo test -p zanshin-ffi` (lib + `--test it drop_actions_ffi::`) -- pass.
- `cargo test -p zanshin-parity --test oracle` -- pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean.
- `flutter test` in `packages/zanshin_core` (drop_actions tests), `packages/zanshin_ui`, `app` (`test/features/graph test/app/menu test/widgetbook test/l10n`) -- pass.
- `dart analyze` + `dart format --set-exit-if-changed lib test` in each touched package -- clean.

**Manual checks:**
- Marionette vs the DS cards: left to the console session (as in 10.34, 10.35).

## Auto Run Result

Status: done

**Summary.** `jj absorb --from X` is offered in three places:
- **Backend.** `ChangeActions` gains `absorb`, planned by `plan_absorb` into the `mutable()` alias, as `Repo::absorb` resolves it. It is `NoOp` when nothing is absorbable and otherwise jj's refusal or Available. The field is appended to the schema, the FFI (eight outcomes), `docs/ffi-abi.md` and `zanshin_core`, which also exports `AbsorbResult`.
- **Runner.** `GraphAbsorb` runs through `GraphActions.absorb`. The anchor is the first parent, and the changes the hunks went into flash. The toast reads "Absorbed ‹id› into N change(s)" with Undo, or jj's "Nothing changed.". When jj abandons the selected source, the selection clears.
- **Inspector.** Squash is a `ZsMenuButton` ("Squash" + chevron) with "Squash into parent" and "Absorb into ancestors". Each row has its command as the hint; its tooltip is the reason it is off, else the command.
- **Card menu and Change menu.** An absorb row follows Squash. Like their Squash rows, they carry no preview.
- **Design system.** The new `MenuButton` component is published (DS artifact version 1794671112-ec0a; canvas 6sAzL5mDcVpWXevbTcempu synced).

**Deferred-work items.**
- **I1** (no button that opens a menu) — fixed in 8ccf895c4b6178d08d7085e43a5208a7078d09ae: DS `components/actions/MenuButton.*` and `zanshin_ui` `ZsMenuButton`, used by the inspector's Squash menu.

**Files changed (8ccf895c).**
- `crates/zanshin-jj/src/drop_actions.rs`, `repo.rs` — the absorb row and its docs; `tests/it/{drop_actions,api_stability,when_commands}.rs` — eight rows, absorbable / immutable cards, agreement with the verb.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/envelope.rs` (+ generated), `tests/it/drop_actions_ffi.rs`, `docs/ffi-abi.md` — the wire.
- `packages/zanshin_core` — model, decoder (+ generated), exports, tests.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` — `absorb_from_two_ancestors`, `absorb_from_undescribed_at`; `test-fixtures/commands/card-menu.txt` — the card's absorb command.
- `packages/zanshin_ui` — `ZsMenuButton` (`zs_menu_button.dart`, a `part` of `zs_button.dart`), export, test.
- `app/lib/src/features/graph/{graph_ports,graph_view_model,graph_toasts,graph_card_menu,graph_inspector}.dart`, `app/lib/src/app/menu/app_menu.dart`, `app/lib/l10n/*` — the app; fakes, tests and catalogue (`app/test/…`, `app/widgetbook/…`, `app/integration_test/glass_profile.dart`).
- DS: `design_system/components/actions/MenuButton.*`, `actions.css`, `menubutton.card.html`, `_ds_bundle.js`, `_ds_manifest.json`, `readme.md`, `ui_kits/desktop/inspector.jsx`; `design/DESIGN-SYSTEM-SYNC.md` follow-up under #25.

**Review.** The pass logged 37 findings:
- **Patched: 4** (low 4): the toast fake pins the absorb warnings path, no force-unwrap, `ZsMenuButton` defaults to the DS's 360, and the chevron gap is a fixed 5.
- **Deferred: 1** (low): the runner's head race for no-op verbs, mirrored into deferred-work.md.
- **Rejected: 32** — 13 false and 19 low; each reason is in the Review Triage Log.
- **Follow-up review:** not recommended (no high or medium patched).

**Verification performed (targeted; the full gate is left to the story loop).**
- `cargo test -p zanshin-jj --test it -- drop_actions:: api_stability:: when_commands::` — 96 passed.
- `cargo test -p zanshin-ffi --lib` — 240 passed; `--test it -- drop_actions_ffi::` — 6 passed.
- `cargo test -p zanshin-parity --test oracle` — 522 passed (incl. the two new scenarios).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — run by the implementation; output committed.
- `packages/zanshin_core`: `flutter test` on the two drop_actions files — 17 passed; `dart analyze` / `dart format --set-exit-if-changed lib test` — clean.
- `packages/zanshin_ui`: `flutter test` — 464 passed; analyze / format clean (after the review patches).
- `app`: `flutter test test/features/graph test/app/menu test/widgetbook test/l10n` — 1395 passed; `dart analyze` / `dart format --set-exit-if-changed lib test widgetbook integration_test` — clean (after the review patches).
- Not run: `cargo make test` / coverage (this run's gate rule); Marionette vs the DS cards (console session).

**Residual risks.**
- The card and Change menu rows carry no preview: on a change with nothing absorbable they stay enabled, and a run writes no operation and toasts "Nothing changed." (the CLI's behaviour; the inspector row is disabled with the reason).
- The DS JSX `MenuButton` always opens below; only the Flutter control flips above without room.
- New Rust lines are tested, but coverage was not measured in this run.

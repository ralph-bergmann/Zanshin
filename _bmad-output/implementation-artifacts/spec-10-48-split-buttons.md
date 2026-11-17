---
title: 'Story 10.48 — Split buttons: the composer offers Split ▾ Commit, Squash runs on a click, the preview shows where a bookmark lands'
type: 'feature'
created: '2026-11-17'
status: 'done'
baseline_revision: '4868e0673051f8d4ef84cf2c3000b190b292cbc3'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The composer names its verb after the change, not the pick: on `@` it always reads "Commit", so a part picked on `@` looks like it cannot be split. The Squash button (10.36) looks like a button but only opens a menu. Nothing shows that `jj split` moves the change's bookmarks to the rest (`split.legacy-bookmark-behavior`, default true) while `jj commit` leaves them on the selected part (deferred-work I1).

**Approach:** Build `design/Inspector Extras Study.html` §1–3: a new split button (DS `SplitButton`, `zanshin_ui` `ZsSplitButton`: the label runs, the divided chevron opens the alternatives); the composer's verb follows the pick (`@` + a part = Split ▾ Commit); the preview puts the change's local bookmark chips on the part where the click's verb leaves them and the menu rows say it in a quiet line; Squash becomes a split button whose label squashes into the parent. DS synced through #30, plus a new #31.

## Boundaries & Constraints

**Always:**
- **Verb table** (`InspectorViewModel`): `@` + a part (any partial pick, or some files whole) → label **Split** (`jj split -r <short> …`), chevron offers Commit (`jj commit …`); `@` + everything whole → plain **Commit** (`jj commit -m …`, no paths, as today); other change + a part → plain **Split**; other change + everything → no button, the 10.35/10.40 hint (`splitsEverything`, unchanged); nothing picked → the button disabled, as today (on `@` it reads Commit). Both arms (paths and hunks, 10.25 / 10.26) for both verbs. A Split on `@` runs `GraphSplit` with @'s key (short id in the shown command).
- The model exposes the label's verb, the optional alternative, and the action / command / cut command per verb; `runComposer` takes the verb (default the label's). The member names are the implementer's choice; keep `splitsEverything` and the existing draft/pick/error behaviour.
- **Hover:** while a composer menu row is highlighted (pointer or keys), the command line, the summary placeholder (`inspectorComposerSummaryAt` for Commit, `…Split` for Split) and the bookmark chips follow that row's verb; un-highlighting or closing the menu returns them to the label's verb. The composer's `Semantics` label and the run tooltip name the label's verb.
- **Bookmarks:** the selection's local bookmarks are `layout.refsOf(node)` with `remote == null` (names, jj's order). `GraphDetails` gains a read of `split.legacy-bookmark-behavior` through a new `ProjectsEnvironment.configGet(name, {workspaceRoot})` (`jj config get`, the effective config incl. jj's built-in default; `true`/`false` → bool, anything else or a refused read → null, logged). The inspector reads it at start and again in `configChanged()` (as `_readContext`). Where they land: `jj commit` → the selected part; `jj split` → the rest while true, the selected part while false; unknown (null) → no chips for a split and no menu lines. Chips: `ZI.bookmark` 10 px in `--accent` + the name, mono 11, `--fl-on` pill, 18 high, after the row label (study `.xs-bm`), tooltip "<name> lands here".
- **Menu lines:** only on the Split ▾ Commit menu and only when the two verbs put the bookmarks on different parts: "feature moves to the new working copy" / "feature stays on this change, with the selected part" (2 names joined with "and", 3+ as "N bookmarks"; ICU plural for moves/move, stays/stay). `ZsMenuItem` gains `note` (+ optional `noteIcon`): a second line under the label, 11 px, `--text-dim`, glyph `--text-faint` 10 px; on the highlighted row both take the row's ink. The row grows to fit (min 28). `ZsMenuItem` also gains `onHighlight(bool)`, called when the panel's highlight enters or leaves that row and with false when the panel closes.
- **`ZsSplitButton`** (`packages/zanshin_ui`, a `part` of `zs_button.dart`, exported): variants `quiet` and `primary` (assert others), sizes 30 (padding 0 12 / chevron 0 7, radius `--radius-btn`, `--type-control`) and 26 (0 10 / 0 6, radius 8, 12 px); one shape with the variant's rest fill and ring; a 1 px divider inset 7 top and bottom (`--fl-border`; primary gold 45%); each part its own `ZsControlCore` (own Tab stop, hover, pressed, focus ring inside, disabled) painting its half's hover/press step (quiet `--fl-on` / `--fl-press`; primary gold 16% / 28%); the chevron `ZI.chevronDown` 12 (primary in gold). Params: `label`, `onPressed` (null disables the label), `entries`, `disabledReason` (the label's), `menuDisabledReason` (the chevron's), `tooltip` + `cmd` (the label's tooltip), `identifier` (label; chevron `<identifier>-more`), `maxWidth` (menu, 360). The chevron opens a `ZsMenuAnchor` like `ZsMenuButton` (Space/↩/click), placed by the anchor's own rules. VoiceOver: label part a button named [label]; chevron a button "More <label> actions" (`zs_en.arb` `splitButtonMore`, `flutter gen-l10n` in `packages/zanshin_ui`).
- **Squash** (`_Actions`): a secondary `ZsSplitButton` "Squash" (identifier `inspector-squash-button`): the label runs `model.squash(key)` (the squash form when both descriptions are set — today's row behaviour) with tooltip/cmd `jj squash -r <short>`; disabled with jj's refusal text when the squash preview is refused, the chevron still enabled; the chevron opens today's two rows (identifiers `inspector-squash`, `inspector-absorb`, reasons and tooltips unchanged) and is disabled only when both rows are off. `blocked` (busy / stale) disables both parts with its reason. `inspectorSquashMenuTooltip` goes (orphaned).
- Composer button identifier stays `inspector-composer-run` (the label part; chevron `inspector-composer-run-more`).
- Strings in `app/lib/l10n/app_en.arb` + `flutter gen-l10n` (output committed); jj's words and commands stay literals marked `// l10n-ignore`.
- **DS** via `design-artifacts` C + E (no publish): `components/actions/SplitButton.{jsx,d.ts,prompt.md}` (from the study's `SplitButton`; the prompt states the rule "buttons that look the same work the same; a split button runs its label, its chevron opens the alternatives; a menu button only opens a menu; the label always names the command that runs"), its CSS in `actions.css` (`.zs-splitbtn…`, from `.xs-split…`), `splitbutton.card.html` (the gallery: primary/secondary states, label disabled, size 26, compared with Button and MenuButton); the Menu row's `note` (`Menu.jsx`, `.d.ts`, `.prompt.md`, `menus.css`, from `.xs-msub`); the `_ds_bundle.js` blocks + header `components` name, `_ds_manifest.json` if it lists components; `ui_kits/desktop/inspector.jsx`'s Squash MenuButton → SplitButton; `readme.md` "Synced through #31" + dated line; a new entry `### #31 · 2026-11-17 · Split button …` at the end of `design/DESIGN-SYSTEM-SYNC.md`. Never touch the study files.

**Never:** remembering the last choice; `jj split --parallel`; changing jj's bookmark behaviour or writing the user's config; other menu buttons (`ZsMenuButton` stays, the diff options keep it); Rust, FFI or schema changes; publishing the DS or the Marionette check (console session); the full gate (`cargo make test` / `test-full` / `coverage`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| @ part | @ `qkynoyuu`, `a`,`b` of 5 whole, summary "x" | label Split; click runs `GraphSplit(@key, paths [a,b])`, shown `jj split -r qkynoyuu -m x root:a root:b` | refusal → composer error, as today |
| @ part, menu Commit | same, choose Commit | runs `GraphCommit(@key, paths [a,b])`, `jj commit -m x root:a root:b` | — |
| @ hunks | @, one file partial | Split ▾ Commit, both `-i` with the hunk choice | — |
| @ everything | all 5 whole | plain Commit, no chevron, `jj commit -m x` | — |
| other part | `wxkktntx`, 2 picked | plain Split | — |
| other everything | all picked | no button, the hint | — |
| bookmark, legacy | `feature` on @, part, legacy true | chip on "New working copy"; rows: Split "feature moves to the new working copy", Commit "feature stays on this change, with the selected part"; hover Commit → chip on Selected, command/placeholder Commit | — |
| bookmark, legacy off | same, legacy false | chip on Selected; rows without lines | — |
| legacy unreadable | config read refused | Split: no chips, no lines; Commit hover: chip on Selected | logged |
| 3 bookmarks | `a`,`b`,`c` on @ | lines "3 bookmarks move …" / "3 bookmarks stay …" | — |
| Squash | mutable change, squash Available | label click runs `model.squash(key)`; chevron rows as today | — |
| Squash on merge | squash Refused | label disabled with jj's text; chevron opens, Absorb runs | both off → chevron disabled |
| busy | another action runs | both parts of each split button disabled with the blocked reason | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_inspector.dart` -- `InspectorViewModel`: ctor `:70-91` (`_readContext` at start), `_readContext` `:233-246` (pattern for the legacy read + serial), `configChanged` `:455-459`, `composing` `:845`, `composerAction`/`composerCommand`/`composerCommandCut` `:853-864`, `splitsEverything` `:868`, `_composer` `:873-914` (verb parameter; split id = short id when `short`, also on @), `runComposer` `:928-954`, `_mutableNode` (layout + node for `refsOf`). `_Actions` `:2462-2604` (Squash `ZsMenuButton` `:2554-2577`, `button()` `:2480`, `row()` `:2515`). `_Composer`/`_ComposerState` `:3723-4068`: result preview rows `:3907-3948` (chips after the label), run label `:3951`, `runButton` `:3957`, `Semantics` `:3972`, placeholder `:4011`, command row + tooltip `:4029-4053`.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphDetails` `:1160-1203` (add the legacy read), `RepoGraphDetails` `:1206-1247` (`_environment`, `root`); `GraphCommit` `:442`, `GraphSplit` `:474` (unchanged).
- `app/lib/src/features/projects/projects_environment.dart` -- `ProjectsEnvironment` `:20-60` (add `configGet`), real impl `identity` `:191-195` (uses `_worker.configGet` → `ConfigGetResult.value`).
- Fakes: `app/test/helpers/fake_projects_environment.dart:11`, `app/widgetbook/demo_projects_fakes.dart:187` (`ProjectsEnvironment`); `GraphDetails` in `app/test/features/graph/graph_inspector_test.dart:95`, `graph_card_menu_test.dart:232`, `app/widgetbook/folders/graph.dart:1084`, `app/integration_test/glass_profile.dart:245`.
- `app/lib/src/features/graph/graph_layout.dart:61-100` -- `GraphRef` (`name`, `remote`); `refsOf` `:281`.
- `packages/zanshin_ui/lib/src/controls/zs_button.dart` -- `_Look`, `_LookPainter` `:57-107`, `ZsButton._look` `:199`, `_paint` `:259` (pattern), `part 'zs_menu_button.dart'` `:24` (add `part 'zs_split_button.dart'`); `zs_menu_button.dart` (pattern: `ZsMenuAnchor` + builder).
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `ZsMenuItem` `:29-114` (add `note`, `noteIcon`, `onHighlight`), `ZsMenuPanelState` `_hi` changes `:574, 733, 742-745, 770, 783-786, 804-816` (notify highlight changes, false on dispose), `_Row` `:1060-1203` (second line; height `:1131`). `ZsControlCore` in `zs_control_core.dart:76-160` (`ring: ZsRingPlacement.inside`). Colours: `ZsColors.gold`, `flOn`, `flPress`, `flBorder`.
- `packages/zanshin_ui/lib/l10n/zs_en.arb` + `l10n.yaml` (gen-l10n); `lib/zanshin_ui.dart` exports; tests `test/controls/zs_menu_button_test.dart` (pattern), `test/controls/zs_menu_test.dart`.
- `app/l10n.yaml`, `app/lib/l10n/app_en.arb:625-660` -- `inspectorSquash*`, `inspectorCommit`, `inspectorSplit`, `inspectorComposerSummaryAt/Split`.
- Tests: `app/test/features/graph/graph_inspector_test.dart` -- helpers `_button` `:477`, `_squashMenu` `:484`, `_squashRow`, `_chooseFromSquashMenu` `:495`; Squash tests `:836-980`; composer tests `:2260-2790` (Commit on @ `:2269-2282`, Split `:2409`, hint `:2464`, tooltip `:2504`).
- Catalogue: `app/widgetbook/folders/controls.dart:27` (`_family('MenuButton', …)`, matrix `:1097`, interactive `:1133`) — add a SplitButton family; `app/test/widgetbook/catalogue_smoke_test.dart`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/actions/` (`MenuButton.*`, `menubutton.card.html`, `actions.css` as patterns), `components/menus/Menu.{jsx,d.ts,prompt.md}`, `menus.css`, `_ds_bundle.js`, `_ds_manifest.json`, `ui_kits/desktop/inspector.jsx`, `readme.md:22` + dated list; `design/DESIGN-SYSTEM-SYNC.md` (append #31). Reference only: `design/extras-study.jsx:44-255`, `design/extras-study.css:15-73`.
- jj reference: `../jj` `v0.47.0:cli/src/commands/split.rs:503-518` (legacy → rest), `cli/src/config/misc.toml:67-68` (default true); backend already follows it (`crates/zanshin-jj/src/squash_split.rs:805`, parity `split_legacy_bookmarks_off`).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `ZsMenuItem.note`/`noteIcon`/`onHighlight`, the row's second line, highlight notifications -- tests: note renders and takes ink when highlighted; `onHighlight` true on hover/arrow, false on leave and on close.
- `packages/zanshin_ui/lib/src/controls/zs_split_button.dart` (+ `zs_button.dart` part, export, `zs_en.arb` + gen-l10n) -- `ZsSplitButton` -- tests: click on the label runs, chevron opens the menu below, Tab reaches both parts, Space/↩ on the chevron opens, label disabled with reason while the chevron works, chevron semantics "More Split actions".
- `app/lib/src/features/projects/projects_environment.dart` + both fakes -- `configGet`.
- `app/lib/src/features/graph/graph_ports.dart` + every `GraphDetails` fake -- the legacy read.
- `app/lib/src/features/graph/graph_inspector.dart` -- verb model, legacy read, bookmarks, composer split button + chips + hover + lines, Squash split button.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n` -- new strings, removed `inspectorSquashMenuTooltip`, updated descriptions.
- `app/test/features/graph/graph_inspector_test.dart` -- adapt the Squash and composer tests; add the matrix rows (verbs, commands per verb, hover follows, chips and lines for legacy true/false/null, 3 bookmarks, Squash label click / merge refusal / both off, busy).
- `app/widgetbook/folders/controls.dart` -- SplitButton family (matrix + interactive); smoke test passes.
- DS -- SplitButton component, card, CSS, Menu note, bundle blocks, manifest, kit inspector, readme, DESIGN-SYSTEM-SYNC #31.

**Acceptance Criteria:**
- Given @ with two of five files picked, when the composer shows, then its button reads Split with a chevron, a click runs `jj split -r <short> -m … root:a root:b`, and choosing Commit from the chevron runs `jj commit -m … root:a root:b`.
- Given a bookmark `feature` on @ and `split.legacy-bookmark-behavior` true, when a part is picked, then the chip sits on "New working copy", the menu rows carry the two quiet lines, and highlighting Commit moves the chip to Selected and the command line to `jj commit …` until the highlight leaves.
- Given a merge change, when the inspector shows, then Squash's label is disabled with jj's refusal and its chevron still opens a menu whose Absorb row runs.
- Given keyboard focus on the composer, when Tab moves, then it reaches the label and then the chevron, and Space on the chevron opens the menu.
- Given the DS files, when `_ds_bundle.js` is read, then it has a `components/actions/SplitButton.jsx` block and the header lists `SplitButton`.

## Spec Change Log

## Review Triage Log

### 2026-11-17 — Review pass
- verdicts: 27 findings — high 0, medium 2, low 21, false 4, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) `RepoGraphDetails.splitLegacyBookmarks` parse and `configGet` call never tested — added a `graph_ports_test` case for true / false / non-boolean / missing / refused.
  - `[low]` `[patch]` (verification-gap) the menu row's VoiceOver label with the note is not pinned — added an exact `bySemanticsLabel` expectation to the note test.
  - `[low]` `[reject]` (edge) on @ with nothing picked the chips sit on Selected — the approved study does the same (`lands(verb)` with the disabled Commit verb); the preview names where Commit would put them.
  - `[low]` `[reject]` (edge) entries rebuilt while the menu is open could make `_announced` name another row — the composer rebuilds its two rows in a fixed order, so the index names the same verb; no caller changes the list's shape while open.
  - `[low]` `[reject]` (edge) a `split.legacy-bookmark-behavior` change made outside Zanshin is not seen until the next Zanshin config write — the same mechanism as `diff.color-words.context` (`configWrites`); rare, and a re-read per selection adds calls for a flag users almost never change. Named under residual risks.
  - `[false]` `[reject]` (edge) a non-`ZanshinFfiException` from the legacy read escapes — `RepoGraphDetails` only surfaces the worker's `ZanshinFfiException`; `_readContext` has the same contract.
  - `[low]` `[patch]` (blind) `epic-10-context.md` says "#30 is current" while #31 is added — changed to #31.
  - `[medium]` `[patch]` (blind) `splitLegacyBookmarks` untested — same root cause as the first row; same fix.
  - `[low]` `[patch]` (blind) `FakeProjectsEnvironment.configValues` / `configGetFailure` unused — now used by the new `graph_ports_test` case.
  - `[low]` `[reject]` (blind) the chevron's semantics carry no popup / expanded hint — `ZsMenuButton`, `ZsSelect` and the card menu anchor have none either (10.36 triage); a semantics extension for every menu opener is wider than this story.
  - `[low]` `[reject]` (blind) `zs_split_button_test` lacks focus return, tooltip/cmd, `menuDisabledReason`, painting and assert cases — focus return is `ZsMenuAnchor`'s (tested in `zs_menu_test`); tooltip/cmd and the chevron-off state are covered through the inspector tests (composer tooltip, "both rows off"); colours are not unit-tested anywhere in `zanshin_ui`.
  - `[low]` `[patch]` (blind) the Tab test never asserts where focus is — asserts focus on the label after the first Tab and on the chevron after the second.
  - `[low]` `[patch]` (blind) chips on a non-@ plain Split and on @'s plain Commit untested — added both cases.
  - `[low]` `[patch]` (blind) DS `SplitButton.jsx` disabled parts never show their `title` — each part sits in a span that carries the title (bundle block updated).
  - `[low]` `[patch]` (blind) DS kit's Squash disabled text is invented — now jj's "Cannot squash merge commits without a specified destination".
  - `[low]` `[patch]` (blind) the card's MenuButton comparison carries the Squash rows — now diff-options rows.
  - `[low]` `[reject]` (blind) one variant has three names (default / secondary / quiet) — `ZsButtonVariant.quiet` documents itself as the DS's "default"; "secondary" is the study's caption only.
  - `[low]` `[reject]` (blind) DS `Menu.jsx` `onHighlight` timing differs from Flutter (deps on `[hi]`, false after the exit) — the jsx is an illustration; the prompt describes the Flutter control (10.36 triage, same rule).
  - `[low]` `[reject]` (blind) DS `SplitButton.jsx` close timer never cleared — the jsx is an illustration, the MenuButton jsx has the same timer (10.36 triage).
  - `[low]` `[patch]` (blind) `inspectorComposerBookmarkCount` is not an ICU plural — now `{count, plural, other{…}}`.
  - `[low]` `[reject]` (blind) the ARB key `inspectorSquashMenu` still says "Menu" — a rename churns the generated l10n and tests for no user-visible gain; its description says what it is.
  - `[low]` `[reject]` (blind) the note's 26 px indent is a magic number — it mirrors the 16 + 10 of the line above it in the same widget; cosmetic.
  - `[false]` `[reject]` (intent) no real-repo test that @ ends on the rest and bookmarks land where the app said — the backend verb is already covered by `zanshin-jj` `tests/it/squash_split.rs:619-655` and the parity scenario `split_legacy_bookmarks_off`; this story dispatches the same `GraphSplit` / `GraphCommit` and now tests the config read.
  - `[low]` `[reject]` (intent) `jj commit` may advance bookmarks on @'s parents (`advance-bookmarks`), which the preview does not show — the story limits the preview to the change's own local bookmarks; advance-bookmarks is off unless configured. Named under residual risks.
  - `[low]` `[reject]` (intent) the DS kit composer is not converted to Split ▾ Commit — the story puts the composer in `graph_inspector.dart`; the kit is an illustration and #31 names the composer as app-side.
  - `[false]` `[reject]` (intent) no `## Auto Run Result`, no commit, verification only planned — written at finalization, as the workflow orders.
  - `[false]` `[reject]` (intent) informational interpretive choices (highlight vs hover, Squash label wording, tooltips) — consistent with the spec; no defect claimed.

## Design Notes

The verb follows the pick because jj's FAQ calls `jj split -i` and `jj commit -i` practically identical; they differ in where the change's bookmarks end up, which the preview now shows instead of hiding. The split button is drawn as one shape with two `ZsControlCore` parts so each part keeps its own focus and states (the DS rule) while the variant's fill and ring stay whole. Only `quiet` and `primary` are built: the study draws no other variant and nothing uses one. Highlight, not raw hover, drives the preview, so keyboard users get the same feedback (the menu has one highlight for mouse and keys). After a Split on @ the selection stays on the selected part, as for any Split (only Commit moves it to the new @); the view model is unchanged.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` -- expected: pass.
- `flutter test test/features/graph test/features/projects test/widgetbook test/l10n` in `app` -- expected: pass.
- `dart analyze` + `dart format --set-exit-if-changed lib test` (app also `widgetbook integration_test`) in each touched package -- expected: clean.

**Manual checks (if no CLI):**
- Marionette vs the DS card and the study: left to the console session.

**Checks run (targeted; the full gate is the story loop's):**
- `flutter test` in `packages/zanshin_ui` — 488 passed (before and after the review patches).
- `cargo make test-app test/features/graph test/features/projects test/widgetbook test/l10n` in `app` (the gate's pinned env) — 1932 passed before the review patches, 1935 after.
- `dart analyze` in `packages/zanshin_ui` and `app` — no issues (before and after the patches).
- `dart format --set-exit-if-changed lib test` (`app` also `widgetbook integration_test`) — 0 changed (after the patches).
- `node --check` on `_ds_bundle.js` — passes (run by the implementer).
- Not run: Rust checks (no Rust, FFI or schema change), `cargo make test` / `test-full` / `coverage` (this run's gate rule), Marionette (console session).

## Auto Run Result

Status: done

**Summary.** Story 10.48 builds the approved Inspector Extras Study §1–3:
- **Split button.** New DS `SplitButton` (components/actions: jsx, d.ts, prompt with the rule, CSS, card) and `zanshin_ui` `ZsSplitButton`: quiet or primary, 30 or 26 high, one shape with a divider; the label and the chevron are separate controls (own Tab stop, hover, pressed, focus ring, disabled reason); the chevron opens a `ZsMenuAnchor` and reads "More <label> actions".
- **Menu rows.** `ZsMenuItem` gains `note` / `noteIcon` (a quiet second line that takes the row's ink when highlighted, read by VoiceOver) and `onHighlight` (pointer or keys; false on leave and close). DS Menu follows.
- **Composer.** The verb follows the pick: @ + a part = Split ▾ Commit, @ + everything = plain Commit, another change + a part = plain Split, another change + everything = the hint, nothing = disabled. Split on @ runs `GraphSplit` with @'s key. The highlighted menu row moves the command line, the summary placeholder and the chips.
- **Bookmarks.** `ProjectsEnvironment.configGet` (`jj config get`) and `GraphDetails.splitLegacyBookmarks` read `split.legacy-bookmark-behavior` (at start and after each Zanshin config write). Chips show the change's local bookmarks on the part the verb leaves them on (commit → selected; split → rest while true, selected while false, none while unknown); the Split ▾ Commit rows say "… moves to the new working copy" / "… stays on this change, with the selected part" only when the two differ.
- **Squash.** A secondary split button: the label runs Squash into parent (with its form), disabled with jj's refusal on a merge while the chevron keeps Squash / Absorb; the chevron is off only when both rows are off.
- **DS.** DESIGN-SYSTEM-SYNC #31, readme "Synced through #31", bundle blocks and manifest, kit inspector's Squash as a SplitButton. Not published (console session).

**Deferred-work items.**
- **I1** (the composer reads Commit on @ though a part can be split; Squash only opens a menu) — fixed in 7c82a1e968b992fbef689590ebdb2287be1a1bcb: the composer offers Split ▾ Commit on @ with a part picked, Squash runs on a click, and the preview and menu rows show where a bookmark lands.

**Files changed (7c82a1e9).**
- `packages/zanshin_ui/lib/src/controls/zs_split_button.dart` (new), `zs_button.dart` (part), `zs_menu.dart` (note, highlight), `lib/zanshin_ui.dart` (exports), `lib/l10n/zs_*` (`splitButtonMore`); tests `zs_split_button_test.dart` (new), `zs_menu_test.dart`.
- `app/lib/src/features/graph/graph_inspector.dart` — verb model, legacy read, chips, menu lines, composer and Squash split buttons.
- `app/lib/src/features/graph/graph_ports.dart` — `GraphDetails.splitLegacyBookmarks`; `app/lib/src/features/projects/projects_environment.dart` — `configGet`.
- `app/lib/l10n/*` — new strings, removed `inspectorSquashMenuTooltip`.
- Fakes and tests: `app/test/helpers/fake_projects_environment.dart`, `app/test/features/graph/{graph_inspector,graph_ports,graph_card_menu}_test.dart`, `app/test/widgetbook/{catalogue_smoke,ds_manifest_parity}_test.dart`, `app/widgetbook/{demo_projects_fakes,folders/controls,folders/graph}.dart`, `app/integration_test/glass_profile.dart`.
- DS: `design_system/components/actions/SplitButton.*`, `splitbutton.card.html`, `actions.css`, `components/menus/Menu.*`, `menus.css`, `_ds_bundle.js`, `_ds_manifest.json`, `readme.md`, `ui_kits/desktop/inspector.jsx`; `design/DESIGN-SYSTEM-SYNC.md` #31.
- Planning (docs commit): this spec, `epic-10-context.md` (recompiled for 10.48–10.50, #31), `sprint-status.yaml`.

**Review.** One pass, 27 findings (high 0, medium 2, low 21, false 4):
- **Patched: 9 entries** (medium 1 — the untested `RepoGraphDetails.splitLegacyBookmarks` read, reported by two layers; low 8 — VoiceOver note label test, Tab focus assertions, chip tests for plain Split / plain Commit, ICU plural for the bookmark count, epic context #31, DS SplitButton disabled titles, DS kit refusal text, DS card's MenuButton rows).
- **Deferred: 0.**
- **Rejected: 14** (10 low, 4 false) — each reason in the Review Triage Log.
- **Follow-up review:** not recommended (no high patched, one medium entry).

**Residual risks.**
- A `split.legacy-bookmark-behavior` change made outside Zanshin (jj CLI, editor) shows only after the next Zanshin config write or a new window — the same as `diff.color-words.context`.
- With `advance-bookmarks` configured, `jj commit` may also move bookmarks on @'s parents; the preview shows only the change's own bookmarks, as the story scopes it.
- The focus ring of each part uses the shape's radius on all corners (CSS squares the divider side); marked `shortcut:` in `zs_split_button.dart`.
- The DS kit disables Squash for any `canSquash == false` with jj's merge refusal text.
- Not checked in the running app or against the DS card (console session's Marionette check); the DS is not published.

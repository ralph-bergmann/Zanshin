---
title: 'Story 10.35 — Inspector fixes: the title form forgets an untouched edit, parent ids like the change id, a jump to the parent, Split only for part of a change'
type: 'bugfix'
created: '2026-11-14'
status: 'done'
baseline_revision: '70ba4f9bf1b0d737066864db3bf636ee60e4e7e5'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Five inspector faults (epics.md Story 10.35): (1) a describe form opened by a click stays a text field for the whole session, even untouched; (2) parent ids in the meta line lack jj's bold prefix; (3) there is no way to jump to a parent; (4) Split with everything picked on a change other than @ runs and leaves an empty change; (5) the composer's command line cuts its end, so the paths never show with a long message.

**Approach:** All in `app/lib/src/features/graph/graph_inspector.dart`: close a non-dirty form when the selection leaves its change; bold the parent prefix; add a small jump button per parent that goes to it; disable Split on "everything picked, not @" with the approved wording; cut the command inside its `-m` message(s), never its paths. The jump glyph `parent` enters the DS and the app icon set, through the `design-artifacts` skill.

## Boundaries & Constraints

**Always:**
- Item 1 rule (DECIDED, Ralph): when the selection leaves change K (another change, or `graph.select(null)`), K's form stays open only while `dirty(K)`; the check runs in `_graphChanged` before `_key` / `_entry` change. Drafts are kept as today.
- Item 2: parent prefix bold in `--text` (`colors.text`), no subscript; prefix = `changeIdPrefixLengthOf(parent)` when the parent's key is its change id, else `commitIdPrefixLengthOf(parent)`; a parent outside the layout keeps prefix 0. The click still copies the full id.
- Item 3: after each parent id a 20 px icon button (DS #25: `.isd-jump` — radius 6, `--text-faint`, hover `--fl-hover` / `--text`, accent focus ring, disabled at `--disabled-opacity`), built on `ZsControlCore`. Tooltip / name "Select parent <short id>". A click calls `graph.goTo(parentKey)` (selects, reveals, pulses; opens a collapsed stack that folds the parent). Disabled when `layout.indexOfKey` is null, reason "Parent <short id> is not in the shown graph".
- Item 4: on a change other than @ with `allPicked`, Split is disabled with the reason "Every change is picked. To describe this change, click its title."; the hint under the row reads "Every change is picked — Split needs something left behind. To describe this change, click its title." and replaces jj's "…will become empty" note. `runComposer` runs nothing in that state. @ (`jj commit`) is unchanged.
- Item 5: the command line shows the full command when it fits; else each `-m` paragraph is cut to its first k characters plus "…" (largest k that fits, longest paragraphs give way first); `jj split -r <id>`, the quotes and the paths stay. Only when k = 0 still overflows does the line end-ellipsize. The run button's tooltip keeps the full command.
- New user text in `app/lib/l10n/app_en.arb`; run `flutter gen-l10n` and commit the output.

**Never:** other open-state memory; a Describe button in the composer; changes to `jj commit` on @; a new `ZsIconButton` size; hand edits under `design/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected |
|----------|--------------|----------|
| Untouched form, close | form opened, nothing typed, `select(null)`, select K again | title label |
| Untouched form, commit | form opened on @, composer Commit runs, select other, select K | title label |
| Typed, reverted | type "x", delete it, select other, back | title label |
| Typed draft | type "draft", select other, back | form open with "draft" |
| Merge | two parents in layout | two prefixes bold, two enabled jump buttons |
| Parent absent | `show` names a parent the layout lacks | plain id, jump disabled with the reason |
| Folded parent | parent inside a collapsed stack | jump enabled; goTo opens the stack |
| Split all | non-@, Select all | Split disabled + reason, hint shown, run does nothing |
| Split one less | non-@, one file unpicked | Split enabled |
| Commit all | @, all picked | Commit enabled |
| Long message | 200-char summary, two paths | both paths and `'…'` visible |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_inspector.dart`
  - `:102` `_open`; `:314-371` `isOpen`/`openForm`/`closeForm`/`updateDraft`/`dirty`/`_unchanged`; `:762` `_graphChanged` (item 1 lands before `_key = key`, `:784`).
  - `:437` `allPicked` (a partial pick is never full, so it is exactly "every file and hunk"); `:621-674` `composing`, `composerAction`, `composerCommand`, `_composer(short:)` — add a cut-message variant (paragraphs truncated with characters) so the cut command is built by the same `GraphSplit/GraphCommit.command`; `:688` `runComposer`.
  - `:1177-1210` `_CopyId` (`prefix`, `bold`); `:1418-1442` header's change id (the look to copy); `:1779-1877` `_Meta` with `_parents()` (add node/prefix; WidgetSpan row id + jump); `:1070` `_Meta` call (pass the graph or a jump callback).
  - `:2529-2807` `_Composer`: `_ready` `:2560`, run button / tooltip `:2706-2785`, command `Text` `:2763-2771` (key `inspector-composer-command` stays on one `Text` whose `data` is the shown string), jj hint `:2788-2793`.
- `app/lib/src/features/graph/graph_view_model.dart:510` `goTo(key)` — select + reveal + pulse, opens a folded key's stack.
- `app/lib/src/features/graph/graph_ports.dart:408-475` `GraphCommit` / `GraphSplit` `.command` (`_message`, `_shellQuote`); reuse, no change needed.
- `packages/zanshin_ui/lib/src/controls/zs_control_core.dart` — `ZsControlCore` (disabled reason tooltip, focus ring, semantics); `zs_button.dart:316-458` `ZsIconButton` as the look reference.
- `packages/zanshin_ui/lib/src/icons/zanshin_icon.dart:149` `ZI` + `ZI.all`; `packages/zanshin_ui/assets/icons/svg/` (arrow-up.svg = file style).
- `packages/zanshin_ui/test/design/ds_parity_test.dart:261-277` — DS glyphs = app files = `ZI.all`, count 59 → 60.
- DS: `_bmad-output/implementation-artifacts/design_system/assets/icons/glyphs.json`, `assets/icons/ui/`, `ui_kits/desktop/inspector.jsx:181` (parents), `kit.css`, `readme.md` change log; mock-up `design/inspector-study.jsx:25` (glyph path), `:464-490` (composer), `:564-575` (parents); `design/inspector-study.css:51-56, 209-212`.
- `app/lib/l10n/app_en.arb:599` neighbourhood (`inspectorParents`, `inspectorSplit`).
- `app/test/features/graph/graph_inspector_test.dart` — `:922` draft survives (must stay green), `:784` merge, `:643` parent outside layout, `:1579+` composer group (`shown()` reads the command `Text`), `:1792` split-all test (rewrite).

## Tasks & Acceptance

**Execution:**
- `graph_inspector.dart` (view model) -- item 1 in `_graphChanged`; `splitsEverything` getter; `runComposer` guard; cut-command helper (`composerCommandCut(int keep)` or equivalent).
- `graph_inspector.dart` (widgets) -- `_Meta` parent prefix + `_ParentJump`; `_Composer` disabled reason, new hint, measured command line (LayoutBuilder + TextPainter, binary search on k).
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n` -- four strings: jump tooltip, jump absent reason, split-all reason, split-all hint.
- `packages/zanshin_ui` -- `parent.svg` (mock-up glyph in the arrow-up file style), `ZI.parent`, `ZI.all`; parity count 60.
- DS via `design-artifacts` skill -- glyph in `assets/icons/ui/` + `glyphs.json`; kit `inspector.jsx` parent prefix + jump, `kit.css` jump rule; readme change-log entry; republish.
- `app/test/features/graph/graph_inspector_test.dart` -- witnesses below; rewrite the split-all test.

**Acceptance Criteria:**
- Given each I/O row, when the inspector test runs, then the expected outcome holds.
- Given a parent in the layout, when its jump is tapped, then `graph.selected` is that parent and the layout holds it placed (`goTo` ran).
- Given the DS and the app, when `ds_parity_test` runs, then the 60 glyphs match byte for byte and `ZI.all` holds `parent`.

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 30 findings — high 0, medium 0, low 19, false 11, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) the commit-id branch of a parent's bold prefix is untested — fixed: test "a parent keyed by its commit id takes the commit id's prefix" (swapping the branches bolds 2 characters and fails it).
  - `[false]` `[reject]` (blind) sprint-status still says backlog — set to done at finalization, in this run's commit.
  - `[false]` `[reject]` (blind) unrelated 10.38 planning edits in the diff — they are commit 92512202 by another session after the baseline; the working tree holds none of them.
  - `[low]` `[patch]` (blind) DESIGN-SYSTEM-SYNC #25 not followed up — fixed: a dated "the app follows #25 for its part" line under #25 (no old entry edited).
  - `[false]` `[reject]` (blind) the diff leaves out `_ds_bundle.js` and `epic-10-context.md` — left out of the review file on purpose (hand-copied DS bundle block, `node --check` clean; regenerated context); both are committed.
  - `[low]` `[patch]` (blind) `_ParentJump` doc cites `.isd-jump` — fixed: cites `ui_kits/desktop/kit.css` `.zk-ins-jump`.
  - `[low]` `[reject]` (blind) the cut line quotes `-m 'x…'` where the full command has `-m xxx` — the "…" makes the word need quotes; the shown line is still a valid command and the tooltip has the exact one; matching quotes needs a second quoting path.
  - `[false]` `[reject]` (blind) "change" used for picks and for the jj change — the wording is the mock-up's, approved by Ralph (DESIGN-SYSTEM-SYNC #25).
  - `[false]` `[reject]` (blind) no test for "@ Commit enabled" — "commit all: one commit with both paragraphs and no paths" starts with every file picked on @ and runs Commit.
  - `[low]` `[reject]` (blind) the cut is tested only for one long summary — the cut is one loop over the paragraphs; a second paragraph takes the same path.
  - `[low]` `[reject]` (blind) paths are cut when even k = 0 overflows — by design: paths give way last (spec Always, mock-up `.p{flex:0 1 auto}`); a fixed width cannot always show every path.
  - `[low]` `[reject]` (blind) `_fitted` lays text out on every build — about log2(message) + 2 layouts, only in the composer; no measured cost.
  - `[low]` `[reject]` (blind) the folded-stack test does not check the reveal — the reveal after the stack opens is `goTo`'s own behaviour, tested in Story 10.17.
  - `[low]` `[patch]` (blind) the reflowed view-model doc comment runs past the width — fixed: rewrapped.
  - `[low]` `[reject]` (edge) a divergent/hidden parent keyed by its commit id is not found by `show`'s change id, so its jump is disabled — rare (divergent parent); the copy id already behaved so; a fix needs a new lookup.
  - `[low]` `[reject]` (edge) leaving a change while `_entry` is null may close a form — the form only shows with a read entry (`_editing`), and the draft stays.
  - `[low]` `[reject]` (edge) `MediaQuery.boldText` is not measured — macOS reports no bold-text setting.
  - `[low]` `[reject]` (edge) the kit's jump does not open a collapsed stack — the kit is a click-through illustration.
  - `[low]` `[reject]` (edge) claim: paths are still cut at k = 0 — same as the blind finding above, by design.
  - `[low]` `[reject]` (intent) repro 2's test does not move @ — the rule only looks at the left key's draft, which the test drives the same way.
  - `[false]` `[reject]` (intent) the jump also pulses — the spec chose `goTo`, the go-to path that selects and reveals; the pulse is that path's look.
  - `[low]` `[reject]` (intent) kit and mock-up name the absent parent differently — kit illustration only; the app uses the short id like every other id.
  - `[false]` `[reject]` (intent) a hint replaces jj's note instead of nothing — the approved mock-up, named in the story, shows that hint.
  - `[false]` `[reject]` (intent) "every hunk picked" not tested through hunks — a partial pick is never full (Story 10.26 invariant), so it is `allPicked`.
  - `[low]` `[reject]` (intent) at 460 px the paths still give way — by design (paths last); Story 10.38 lifts the inspector's maximum width.
  - `[low]` `[reject]` (intent) quoting differs between line and tooltip — same as the blind finding above.
  - `[low]` `[reject]` (intent) no Marionette check — left to the console session by this run's rules.
  - `[false]` `[reject]` (intent) 10.38 edits out of scope — another session's commit, not this change.
  - `[false]` `[reject]` (intent) sprint-status still backlog — set at finalization.
  - `[false]` `[reject]` (intent) bundle and generated l10n missing from the diff — excluded from the review file on purpose; committed with the change.

## Design Notes

DS synced through #26. The jump glyph is the mock-up's "arrow onto a dot" (`M8 2.5v7M5 6.8L8 9.8l3-3`, circle 8/13 r1.6). `goTo` over a bare `select`: it already reveals, pulses and unfolds a stack — that settles the story's "parent inside a collapsed stack" check. The mock-up cuts the message at its end inside the quotes; the spec follows it.

## Verification

**Commands:**
- `flutter test test/features/graph/graph_inspector_test.dart` in `app` -- pass.
- `flutter test` in `packages/zanshin_ui` -- pass (parity 60).
- `dart analyze` and `dart format --set-exit-if-changed lib test` in `app` and `packages/zanshin_ui` -- clean.

**Manual checks:**
- Marionette vs DS cards: left to the console session (as in 10.34).

## Auto Run Result

Status: done

**Summary.** The five inspector fixes are in `graph_inspector.dart`:
1. A describe form closes when the selection leaves its change, unless its draft differs (`_graphChanged`, before the key changes).
2. Parent ids show jj's prefix bold in `--text`: the change id's prefix, or the commit id's for a commit-keyed parent.
3. A 20 px jump after each parent (`_ParentJump` on `ZsControlCore`, glyph `parent`) runs `graph.goTo`; it is disabled with "Parent <id> is not in the shown graph" outside the layout. A parent folded in a stack opens the stack.
4. Split on a change other than @ with everything picked is disabled with the approved reason and hint; `runComposer` runs nothing then; @ is unchanged.
5. The command line is cut inside its `-m` paragraphs (measured, largest k that fits); the change id and the paths stay, the tooltip keeps the full command.

**Files changed.**
- `app/lib/src/features/graph/graph_inspector.dart` -- the five fixes.
- `app/lib/l10n/app_en.arb` + generated `app_localizations*.dart` -- four strings.
- `app/test/features/graph/graph_inspector_test.dart` -- witnesses; the split-all test rewritten; `pump(width:)` for long full commands.
- `packages/zanshin_ui/assets/icons/svg/parent.svg`, `lib/src/icons/zanshin_icon.dart` (`ZI.parent`), `test/design/ds_parity_test.dart` (60 glyphs).
- DS (`design_system/`): `assets/icons/ui/parent.svg`, `glyphs.json`, `components/brand/Icon.*`, `brand.card.html`, `_ds_bundle.js`, `ui_kits/desktop/inspector.jsx` / `app.jsx` / `kit.css`, `readme.md` change log. Republished: DS artifact version 1794668223-f549; canvas 6sAzL5mDcVpWXevbTcempu synced.
- `design/DESIGN-SYSTEM-SYNC.md` -- the follow-up line under #25.
- `epic-10-context.md` regenerated; `sprint-status.yaml` 10-35 → done.

**Review.** 30 findings: 4 patches (commit-id prefix test, sync-log line, doc reference, doc wrap), 0 deferred, 26 rejected (reasons in the Review Triage Log). Patched by verdict: high 0, medium 0, low 4. The patches were small enough that the orchestrator applied them itself. Follow-up review: not recommended.

**Verification performed (targeted; the full gate is left to the story loop).**
- `flutter test test/features/graph/graph_inspector_test.dart` in `app` -- 99 passed (after the review patches).
- `flutter test test/l10n test/widgetbook test/architecture` in `app` -- 418 passed; the implementation run also ran `test/features/graph test/widgetbook` -- 1346 passed.
- `flutter test` in `packages/zanshin_ui` -- 460 passed (parity 60 glyphs).
- `dart analyze` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed, in `app` and `packages/zanshin_ui`.
- Not run: `cargo make test` (this run's gate rule); no Rust changed. Marionette check vs the DS cards (console session).

**Residual risks.**
- At the default 460 px inspector, a command with long paths still gives way at its end after the message is cut to "…" (by design; Story 10.38 widens the inspector).
- The published DS artifact has `"plus":"<g` without the space the repo now has in `Icon.jsx` / `_ds_bundle.js` (cosmetic; the next republish carries it).
- A divergent or hidden parent keyed by its commit id is not found by `show`'s change id, so its jump is disabled (rare).

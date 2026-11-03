---
title: 'Story 10.26 — Hunk selection: partial selections through a GUI tree'
type: 'feature'
created: '2026-11-03'
status: 'done'
baseline_revision: '0ae11fa47e4a2846cbe63fcf9b103cc75892f3ef'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The hunk checkboxes, the mixed states and the selected-hunk look were not checked in the running catalogue against the DS DiffHunk card.
    evidence: |-
      Unattended run with targeted checks only: widget tests pin the colours and checkbox states; no Marionette/Playwright look.
    location: >-
      app/lib/src/features/graph/inspector_diff.dart; app/lib/src/features/graph/graph_inspector.dart
    severity: low
    resolved: >-
      2026-11-03 — fixed (console session, commit 6cf017db): checked in the catalogue (Graph › Inspector diff › Hunk selection); matches decision (f).
---

<intent-contract>

## Intent

**Problem:** The inspector's composer (10.25) selects whole files only: no hunk checkboxes, no mixed state, no way to commit or split part of a file, though the backend's `selectTree` (9.50) and the tree arms of `commit` / `split` exist. Also (deferred I1) a renamed file chosen whole passes only its target path, leaving the source's removal behind.

**Approach:** Extend the inspector model's file picks with per-file partial picks (9.50 section keys + the mode row), draw tristate checkboxes on files, select-all, hunk headers and the mode row, and let `GraphCommit` / `GraphSplit` carry a hunk choice that `RepoGraphActions` turns into one `selectTree` call plus the verb's tree arm. A renamed file picked whole also selects its source path.

## Boundaries & Constraints

**Always:**
- Model state (in `InspectorViewModel`, per selection key, reset on a key change as 10.25's picks): `_picked` (paths picked whole, as today) plus `_partial: path → (keys: Set<HunkKey>, mode: bool)` — never both for one path; a partial entry is never empty (no keys, no mode → dropped) and never full (keys ⊇ the file's sections and (mode or no mode row) → moved to `_picked`).
- A file's *shape* is its summary `FileDiff` (`summaryOf(path)`): `sections` and `modeChange`. Only a file with sections or a mode change takes hunk / mode checkboxes; others (added/removed/binary/renamed/copied, or no summary) stay whole-only.
- File state: `_picked` → all, `_partial` → mixed, else none. Select-all state: every listed file all → all; none → none; else mixed. File toggle: all → none, else → all. Select-all toggle: all → clear every pick, else every listed file → all. Hunk state over `hunk.sections` (empty: no checkbox): all of them picked (or the file is all) → all, some → mixed, none → none; toggle: all → remove them, else add them. Mode row: picked when the file is all or its partial has `mode`; toggling flips it. Every pick edit clears the composer's refusal.
- @ starts with every file picked whole (10.25). A reload re-maps: `_picked` keeps still-listed paths (10.25); a partial keeps keys still in the file's new sections and `mode` only while the file still has a mode change, then is normalized (empty → dropped, full → whole); a file now whole-only drops its partial.
- Running: no partial → 10.25's path arm unchanged, except a picked renamed file adds its `fromPath` (I1). Any partial → `GraphCommit(key, message, hunks: HunkChoice(left: entry.parentTreeIds, files: …))` / `GraphSplit(id, message, hunks: …)` with no paths, where files = every whole pick as `FileSelection.whole` (+ `FileSelection.whole(fromPath)` for a renamed one) and every partial as `FileSelection.hunks(path, keys in section order)` or `FileSelection.modeAndHunks` when its mode is picked.
- `GraphCommit` / `GraphSplit` with `hunks` show `-i` in `command` right after the verb (`jj commit -i -m …`, `jj split -r <id> -i -m …`) and no paths; `RepoGraphActions` calls `handle.selectTree(revision: null for commit / id for split, left, files, verb: SelectTreeVerb.commit|split)` exactly once, then `commit(message, tree: TreeSelection.of(tree, left: left))` / `split(revision: id, message, tree: …)`. No call carries an interactive flag. A refusal of either call (e.g. `jj.stale_selection`) is the action's refusal: the composer's warn line shows it, draft and picks stay (10.25), and they are re-mapped on the next reload.
- Composer counts (10.25's preview): Selected = files with a pick; Rest = files not picked whole. A file's ± in Selected = its summary ± when whole, else Σ over picked keys of `newCount` / `oldCount`; in Rest the file's ± minus that. The split-all hint shows only when every file is whole (`allPicked`).
- Look (DS DiffHunk.prompt.md:8-11, content.css:58-59): a hunk with a pick (all or mixed) has its header on `accentSoftHi`, header text `text`, the dim/faint parts (symbol) `textMuted`, and a 2 px `accentLine` left edge on every line; unselected headers stay `hunkBg`. Checkboxes are `ZsCheckbox` (sm, `tristate: true` where mixed is possible: file rows, select-all, hunks); the hunk checkbox is the hunk's Tab stop, Space toggles it. The mode-change note gets a checkbox in front when the file is pickable.
- Esc (inspector `_onKey`), after the squash-form / composer-field / describe-form rules: on a non-@ change with any pick it clears the picks (`clearPicks`) and keeps the panel; the next Esc closes it.
- Strings in `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`): the hunk checkbox label, the mode-row label. Controls only from `zanshin_ui`.

**Never:** line-level selection inside a hunk, `diffedit` (9.17), drags (10.27), any Rust/FFI/schema change, a selection keyed by view-local ids, an interactive flag in a call, `-i` shown for an all-whole selection.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| @ opens | @ with a.txt (3 sections) | file all, every hunk checked | — |
| Uncheck hunk 2 on @ | | file mixed, select-all mixed; preview `jj commit -i -m …`; run → `selectTree(left: parentTreeIds, files: [hunks(a.txt,[k1,k3])], verb: commit)` then `commit(tree:)` | — |
| Recheck hunk 2 | | file all again; preview has no `-i`, paths arm | — |
| Mode only | b.sh +x and content | uncheck content hunk, keep mode → `modeAndHunks(b.sh, [])` | — |
| Non-@ change | none picked; check one hunk | composer Split, `jj split -r <short> -i -m …`; run splits with the tree | — |
| Renamed file whole | `old.txt → new.txt` picked, paths arm | `paths: [new.txt, old.txt]`, command shows both | — |
| Renamed file whole, tree arm | rename + a partial file | `whole(new.txt)`, `whole(old.txt)` in files | — |
| Reload rewrote @ | partial {k1}; @ edited elsewhere in file | k1 survives → still picked; a dropped key goes | — |
| Stale refusal | `selectTree` refuses `jj.stale_selection` | warn line shows jj's text; draft and picks stay | no toast (10.25) |
| Esc on non-@ with picks | | picks cleared, panel stays; second Esc closes | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_inspector.dart` -- `InspectorViewModel` picks :101-104, :376-420 (`selectable`, `isPicked`, `allPicked`, `togglePick`, `pickAll`, `clearPicks`), `composing` :446, `_composer` :462-477 (path arm; add I1 source path and the hunk arm), `_graphChanged` :553-588 (reset per key), `_fetch` :601-652 (initial picks / re-map at :619-628). Widgets: `_onKey` :734-766 (Esc), `_Changes` header select-all :1946-1953, rows :2030-2047, diff view call :2052-2069; `InspectorFileRow` checkbox :2141-2148 (`picked: bool?` → tristate); `_Composer` selected/rest lists and `count` :2338-2363, split-all hint :2535.
- `app/lib/src/features/graph/inspector_diff.dart` -- `InspectorDiffView` (mode note :141, :146; hunks :147-153) and `InspectorDiffHunk` header :399-423 and lines :451-484 / `_sideBySide` :493-545: add optional pick callbacks (hunk state/toggle, mode state/toggle), the checkbox, the selected look. 10.29's operation view uses both without picks — stays unchanged when the callbacks are null.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphCommit` :405-427, `GraphSplit` :431-452 (add `hunks`), `RepoGraphActions.run` :822-870 (commit / split mapping) and `_split` :884-896.
- `packages/zanshin_core/lib/src/worker/handle.dart:1620` `selectTree`, `:1580` `commit(tree:)`, `:1160` `split(tree:)`; `packages/zanshin_core/lib/src/ffi/select_tree.dart` `HunkKey`, `FileSelection.{whole,hunks,modeAndHunks}`, `SelectTreeVerb`, `TreeSelection.of` — all exported already (`zanshin_core.dart:110`). `ShowEntry.parentTreeIds` (`commit_views.dart:242`) is the `left`. `FileDiff.sections` / `Hunk.sections` / `modeChange` (`ffi/diff.dart:94-144`); the summary keeps sections (`crates/zanshin-jj/src/hunks.rs:28`).
- `ZsCheckbox` (`packages/zanshin_ui/lib/src/controls/zs_checkbox.dart:72`, `tristate`, null = mixed); tokens `accentSoftHi`, `accentLine`, `hunkBg`, `textMuted` on `ZsColors`.
- Tests: `app/test/features/graph/graph_inspector_test.dart` (fake `_Details` :70-262 with `fileDiff` / `hunk` helpers at :264-301 that hardcode `sections: const []` — add `sections` / `modeChange` params and keep them in the summary; `_Actions` :303; composer group :1418, the split-all case :1603 now expects the renamed file's source path), `app/test/features/graph/graph_ports_test.dart` (commands group :562; real-repo group :207, `setUpRepo` :209, commit case :300).
- Deferred I1 source: `_bmad-output/implementation-artifacts/deferred-work.md`, section "Surfaced in Story 5.6 (bmad-build-auto, 2026-10-31)".

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_ports.dart` -- add `HunkChoice` (`left`, `files`) and an optional `hunks` on `GraphCommit` / `GraphSplit` (`-i`, no paths in `command`); `RepoGraphActions`: `selectTree` then the tree arm -- the 9.50 contract.
- `app/lib/src/features/graph/graph_inspector.dart` -- partial picks, states, toggles, re-map, hunk arm and I1 source path in `_composer`, composer counts, Esc rule; tristate checkboxes in rows and select-all; pass pick callbacks to the diff view.
- `app/lib/src/features/graph/inspector_diff.dart` -- hunk and mode checkboxes, selected look.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- the new labels.
- `app/test/features/graph/graph_inspector_test.dart` -- every I/O matrix row; three-state math of file and select-all; the selected look (accentSoftHi + accentLine vs hunkBg); no checkboxes on an immutable change or a whole-only file.
- `app/test/features/graph/graph_ports_test.dart` -- commands with `-i`; real cdylib: committing hunks 1 and 3 of a three-hunk file leaves hunk 2 in the new @; a hunk split through the runner; I1: committing a picked rename whole leaves no `old.txt` removal in the new @.

**Acceptance Criteria:**
- Given @ with a three-hunk file, when hunk 2 is unchecked and Commit runs, then exactly one `selectTree` and one `commit(tree:)` run, and the new @ holds only hunk 2's change (real cdylib).
- Given an all-whole selection, when the composer runs, then no `selectTree` runs and the paths go as in 10.25, without `-i`.
- Given a partial selection, when the composer previews it, then its command shows `-i` and the call carries no interactive flag.
- Given a renamed file picked whole, when commit runs, then both the target and the source path are selected.

## Spec Change Log

## Review Triage Log

### 2026-11-03 — Review pass
- verdicts: 28 findings — high 0, medium 3, low 19, false 6, maybe-false 0
- findings:
  - (verification-gap) `[low]` `[patch]` no test pins that the dimmed previous file's diff takes no hunk/mode checkboxes — test added with a held focus read.
  - (verification-gap) `[medium]` `[patch]` the tree arm's `FileSelection.whole(fromPath)` for a rename never ran against a real repo — real Git-backend case added (rename whole + a partial hunk through `selectTree` → `commit(tree:)`).
  - (intent) `[low]` `[reject]` intent readings: R-S1 implemented in Dart, I1 settled in the UI on both arms — descriptive, no divergence to act on beyond the rows below.
  - (intent) `[medium]` `[patch]` I1's tree arm checked only as a Dart shape — dup of the verification-gap row; same test.
  - (intent) `[low]` `[reject]` I1 widened to the paths arm — deliberate (Design Notes): `jj commit root:new root:old` is the CLI command for "this rename"; behaving like the CLI is required.
  - (intent) `[false]` `[reject]` a listed file at the rename's `fromPath` is not de-duplicated — jj reports a rename only when the source is gone on the right side (a kept source is a copy), so the source is never listed too.
  - (intent) `[low]` `[reject]` mode-only / conflict-section witnesses not at real-cdylib level — the tree equality with the builtin editor is the backend's, witnessed in 9.50's follow-on (b08ea22); the UI path is generic over `sections` and `modeAndHunks` is pinned in the widget test.
  - (intent) `[low]` `[reject]` re-map tested on a non-@ change — the same `_remapPartials` code runs for @; the @-specific part (`_picked.retainAll`) is 10.25's, tested there.
  - (intent) `[low]` `[reject]` stale refusal tested in two halves — the fake refusal through the composer and the real `jj.stale_selection` through the runner together cover the path; joining them adds no branch.
  - (intent) `[low]` `[reject]` the look asserted under the default accent only — the colours are role tokens (`accentSoftHi`, `accentLine`) that every family defines; a per-family loop tests ZsColors, not this change.
  - (edge) `[low]` `[patch]` a toggle on a stale focused diff after a same-key reload adds keys not in the current sections (shown checked, dropped from the command) — `toggleHunk` adds only keys in the summary's sections.
  - (edge) `[false]` `[reject]` a rename's `fromPath` re-listed as its own file — as the intent row above: a rename implies the source is absent.
  - (blind) `[low]` `[patch]` a renamed (or copied) file with a mode change becomes hunkable and can go as `hunks(newPath, [])` without its source — `hunkable` excludes renamed and copied files.
  - (blind) `[low]` `[reject]` `GraphSplit` no longer requires paths / paths dropped beside hunks — every caller builds one arm; an assert guards a state no caller reaches.
  - (blind) `[medium]` `[patch]` tree-arm rename not run through `selectTree` — dup of the verification-gap row.
  - (blind) `[low]` `[patch]` every hunk checkbox labelled "Select hunk" — the label now carries the hunk's range (`hunkHeader`).
  - (blind) `[false]` `[reject]` re-map may run before the summary is fresh — `_fetch` awaits show, previews and the summary before it sets them together and re-maps.
  - (blind) `[false]` `[reject]` a sectionless hunk in a pickable file is drawn inconsistently — sections are empty only at `-w`/`-b`, which the inspector never reads; a sectionless hunk in a whole file is selected, so its look is right.
  - (blind) `[low]` `[patch]` a binary file with a mode change shows no mode checkbox — the mode row now shows above the binary note.
  - (blind) `[low]` `[reject]` the `-i` preview is not reproducible in a terminal — the epic's item 3: the preview shows `-i` as the design does.
  - (blind) `[low]` `[reject]` hunk checkboxes vanish while the next file loads — the guard is intended (picks must not land on another path); the dimmed diff is transient.
  - (blind) `[low]` `[reject]` the Space test finds its focus node loosely — test robustness only; it passes and pins the behaviour.
  - (blind) `[low]` `[reject]` I1 test casts without `reason:` — a failing cast still fails the test.
  - (blind) `[false]` `[reject]` duplicate paths when a rename's source is also listed — as the intent row above.
  - (blind) `[low]` `[reject]` no test for Esc on @ with partial picks / a real split mixing whole, partial and mode — Esc on @ falls through to 10.25's tested close; the mix is the same `selectTree` call the commit case runs.
  - (blind) `[false]` `[reject]` spec and generated l10n not in the diff — excluded from the review diff on purpose; `dart analyze` checks the generated getters.
  - (blind) `[low]` `[reject]` no-paths `GraphSplit` previews `jj split -r id -m …` — no caller builds it (the composer always passes paths or hunks).
  - (blind) `[low]` `[reject]` flicker — dup of the vanishing-checkbox row.

## Design Notes

- The hunk arm rides on the existing actions (`GraphCommit` / `GraphSplit` with `hunks`), so `_plan`/`_succeeded`, toasts, menu names and undo stay as 10.25 built them; `RepoGraphActions` makes the two backend calls. `selectTree`'s own warnings are not merged into the outcome (the verb snapshots and warns again).
- A file picked whole stays whole across reloads even when its sections change (@ is rewritten on every snapshot, 9.26): only partial picks are re-mapped by key. This keeps "@ starts with everything" stable while the user edits.
- I1: the paths arm adds a renamed file's `fromPath` — `jj commit root:new.txt root:old.txt` is exactly what the CLI runs for "this rename"; the tree arm lists both whole, as the builtin editor shows them as two files. A copy's source is untouched by the copy, so nothing is added for it.
- ± of a partial file from its keys: a section's `oldCount` / `newCount` are its removed / added lines.

## Verification

**Commands:**
- `cd app && flutter gen-l10n` then `flutter test test/features/graph test/features/shell test/l10n test/widgetbook` (Makefile.toml test env for the real-worker tests) -- expected: green.
- `cd app && dart analyze --fatal-infos . && dart format --set-exit-if-changed .` -- expected: no issues, 0 changed.
- Not run (gate rule): `cargo make test` / `test-full` / `coverage`; no Rust/FFI/schema/jj-verb change, so no cargo checks, codegen or parity oracle.

**Manual checks (if no CLI):**
- Marionette check of the hunk checkboxes in the catalogue against DS DiffHunk — unattended; deferred if skipped.

**Verification notes (2026-11-03, this run):**
- `app`: `flutter gen-l10n` ran. `cargo make test-app "test/features/graph;test/features/shell;test/l10n;test/widgetbook"` (the Makefile.toml test-flutter env): before the review patches 1430 passed; after them one run had 1 failure in `app_menu_test.dart` ("applies the native state after each build…", a file this story does not touch), which passed alone (22/22); two further full runs: 1434 passed, 0 failed. `dart analyze --fatal-infos .` no issues; `dart format --set-exit-if-changed .` 0 changed.
- Real cdylib (in those runs): commit -i of hunks 1 and 3 of three leaves hunk 2 in the new @; split -i through the runner; a wrong `left` refused as `jj.stale_selection`; I1 on a Git backend through the paths arm and through the tree arm (rename whole + one hunk of another file).
- Not run: cargo checks, `cargo make codegen`, parity oracle (no Rust/FFI/schema/jj-verb change); full gate and coverage (gate rule); Marionette check (unattended; deferred).

## Auto Run Result

Status: done. Commit 5937e4f4d4e1444d0823e981bb4e8e2aee6121aa (code); spec, ledger and sprint-status in the following commit.

**Summary.** The inspector selects hunks: a mutable change's diff has a tristate checkbox per hunk with sections (labelled with its range; a Tab stop, Space toggles) and one on the mode-change note (binary files too); file rows and select-all are tristate. Picks are whole files plus partial picks keyed by 9.50 section keys and mode, normalized (empty → none, full → whole), re-mapped by key on every reload; a toggle on a diff from before a reload adds only current keys; the dimmed previous diff takes no picks. A picked hunk's header is `accentSoftHi` (range in `text`) with a 2 px `accentLine` edge along its lines. An all-whole selection runs 10.25's paths arm; any partial pick makes `GraphCommit` / `GraphSplit` carry a `HunkChoice` (left = `parentTreeIds`), shown with `-i`, which `RepoGraphActions` runs as one `selectTree` plus the verb's tree arm. Composer counts follow the picked sections. Esc on a non-@ change clears the picks before closing.

**Files.**
- `app/lib/src/features/graph/graph_ports.dart` — `HunkChoice`, `hunks` on commit/split, `-i`, `selectTree` → tree arm.
- `app/lib/src/features/graph/graph_inspector.dart` — partial picks, states, toggles, re-map, composer hunk arm and rename source (I1), counts, Esc, tristate rows.
- `app/lib/src/features/graph/inspector_diff.dart` — hunk and mode checkboxes, selected look.
- `app/lib/l10n/app_en.arb` (+ generated) — `inspectorHunkCheck`, `inspectorModeCheck`.
- Tests: `app/test/features/graph/graph_inspector_test.dart`, `app/test/features/graph/graph_ports_test.dart`.

**Review.** 28 findings (high 0, medium 3, low 19, false 6). Patched: the real-repo tree-arm rename test (medium, with its two dups), stale-key toggle, renamed/copied files whole-only even with a mode change, binary mode row, per-hunk labels, the dimmed-diff test (low). Deferred (1): the catalogue/Marionette check. Rejected: every other row, with its reason in the triage log.

**Follow-up review recommendation:** false — the only medium entry patched is one root cause (a missing real-repo test), now passing; no unverified risk remains beyond the deferred visual check. Patched by verdict: medium 1 entry (3 rows), low 5.

**Items.**
- **I1** — fixed (5937e4f4): renamed and copied files are whole-only (no hunk or mode boxes); a renamed file picked whole also selects its source path — `root:<new> root:<old>` in the paths arm (the CLI command for that rename), `FileSelection.whole` for both in the tree arm; witnessed on a real Git-backend repo through both arms. A copy's source is untouched, so nothing is added for it.

**Residual risks.** No visual check in the running catalogue. The ± of a partial pick comes from its section keys (exact at the inspector's default whitespace mode). One unrelated flaky test (`app_menu_test.dart`) failed once and passed on rerun. The hunk header's range turns `text` on a selected hunk, the symbol stays `textMuted`.

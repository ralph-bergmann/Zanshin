---
title: 'Story-loop 11.13 … 10.25 leftovers: diff range -r, multiple-revisions hint, composer refusal, split toast id, viewed marks follow the store'
type: 'bugfix'
created: '2026-11-02'
status: 'done'
baseline_revision: '22bdd264da6a7d23b82f9c6b5b95af3f84b7e0a4'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The Widgetbook catalogue no longer analyzes: its fake GraphDetails.diff still builds
      Diff(commitId: ...), which became commitIds.
    evidence: |-
      dart analyze in app/ reports 2 errors at app/widgetbook/folders/graph.dart:889 and :895
      (missing_required_argument commitIds, undefined_named_parameter commitId). The run's
      dispatch forbade touching app/widgetbook/ (a parallel Marionette session), so the
      one-line fix was not applied; the end-of-loop gate's dart analyze app fails until it is.
    location: >-
      app/widgetbook/folders/graph.dart:895
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Five low leftovers of the story loop 11.13 … 10.25, each verified against the current code: (1) `hunks::diff` resolves `-r` through `push::single_commit`, so a set of several commits is refused, where `jj diff -r` (`cmd_diff`, `cli/src/commands/diff.rs:142-191` @ v0.46.0) diffs a connected set as one (merged parents of its roots against its merged heads) and refuses gaps; (2) `push::single_commit` refuses a multi-commit set with `hints: vec![]`, where the CLI's `format_multiple_revisions_error` (`cli/src/revset_util.rs:277-331`) adds one hint listing up to five `templates.commit_summary` lines; (3) `InspectorViewModel.runComposer` drops a refusal that lands after the selection moved (`graph_inspector.dart:465-468`), and `graphOutcomeEntry` suppresses every commit/split refusal (`graph_toasts.dart:136-139`), so it shows nowhere; (4) `GraphSplit.shown` puts the inspector's short id into `GraphSplit.command`, so a split's Undo/Redo toast ("Undid `jj split -r <short>`") prints the short id where every other verb's run action carries the full id; (5) `InspectorViewModel` reads `ProjectViewedStore.load()` once, so another writer's `viewedFiles` change is not followed, while `general.diffLayout` is (`_settingsChanged`).

**Approach:** (1) For a present `-r` text, port `cmd_diff`'s range form verbatim: gaps (`roots(T)::heads(T) ~ T`) refuse with the CLI's message and hint, the parents of the roots (in order, deduplicated) merge into the left tree, the heads merge into the right tree, copy records per parent × head; `RevisionDiff.commit_id` becomes `commit_ids` (the heads; `[to]` for `--from`/`--to`) through the schema, FFI and Dart `Diff`. `None` keeps the `@` path. (2) `single_commit` takes the call's `Templates` and adds the CLI's hint. (3) `graphOutcomeEntry` toasts a commit/split refusal when the selection is no longer the action's change (the composer shows it only for its own selection). (4) Drop `GraphSplit.shown`; the composer's preview string is a separate short-id action's command, as the inspector's other buttons do. (5) `_settingsChanged` reloads the viewed set and notifies when it differs.

## Boundaries & Constraints

**Always:** CLI observable behavior for items 1–2 (messages verbatim: "Cannot diff revsets with gaps in." with hint "Revision <12-hex> would need to be in the set."; "The revset `<text>` resolved to these revisions:" then one "  <summary>" line per commit, at most five, "  ..." when more); `-r` text keeps its parse diagnostics and `revsets.short-prefixes` resolution; an empty `-r` set diffs empty trees as the CLI (no refusal); the multiple-revisions hint comes FIRST, before a caller's own hint (bookmark advance's `ADVANCE_TO_HINT` stays appended after it, as `with_advance_hint` does now); witnesses for every matrix row; gate rule of this run: targeted checks only, no `cargo make test` / `test-full` / `coverage`.

**Never:** a `Vec` of `-r` arguments on `DiffRevisions` (one revset text expresses the CLI's union of several `-r`); changes under `app/widgetbook/`, `design/`, `design_system/`, `epics.md`, `sprint-status.yaml`; touching any finished story spec except the two `resolved:` lines in `spec-10-24-closing-diff-any-revision.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Range | `-r 'B::C'` on A–B–C linear | from = B's parent tree, to = C's tree; `commit_ids` = [C] | — |
| Two heads | `-r 'B \| C'` with B, C siblings on A | from = A, to = merge(B, C) (heads in revset order); `commit_ids` both | — |
| Gap | `-r 'A \| C'` on A–B–C | refused | `InvalidInput`, "Cannot diff revsets with gaps in.", hint "Revision <B 12-hex> would need to be in the set." |
| Empty | `-r 'none()'` | empty diff, `commit_ids` = [] | — |
| Single | `-r C`, `-r` absent | as before; `commit_ids` = [C] / [@] | — |
| Several, single-rev | `--from 'all()'`, `git push -r`, `bookmark advance` default with several | resolution error + hint listing ≤5 summaries, `  ...` past five | `RevsetResolutionError` |
| Late refusal | split refused after selection moved to another change | warn toast with jj's message | — |
| Same-selection refusal | split refused, selection unchanged | composer error line only, no toast | — |
| Split undo | Undo toast of a split | names `jj split -r <full id> …` | — |
| Viewed elsewhere | another writer sets `viewedFiles` of this repo | `isViewed` follows, listeners notified | unchanged set → no notify |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:146-182` -- `DiffRevisions` / `RevisionDiff` docs + `commit_id` field → `commit_ids: Vec<CommitId>`.
- `crates/zanshin-jj/src/hunks.rs:244-320` -- `diff`: `Revision(Some(text))` → range form; `Revision(None)` keeps `resolve_or_wc`; `resolve` closure gets `&Templates` for `single_commit`.
- `crates/zanshin-jj/src/push.rs:747-761` -- `collect_ids` (make `pub(crate)` for hunks' roots/heads/gaps evaluation; ids in index order = CLI order).
- `crates/zanshin-jj/src/push.rs:990-1025` -- `resolve_single` / `single_commit`: take `&Templates` (its `prefixes()` replaces the param); multi → hint via `Templates::commit_summary` (`template.rs:440`).
- `crates/zanshin-jj/src/bookmark_ops.rs:680-701` -- `advance_target`: build `Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace)` for `single_commit` (field-wise borrows keep `ctx.warnings` free, as `resolve.rs:378`).
- `crates/zanshin-jj/src/push.rs:710-727` -- `Planner` has `config`, `immutable`, `template_startup`, `repo` → `Templates::new(...)` in `resolve_single`.
- `crates/zanshin-jj/src/repo.rs:4430-4462` -- `Repo::diff` docs ("multi-revision -r is not ported" → range form) and the `hunks::diff` call (pass templates instead of prefixes).
- `crates/zanshin-jj/tests/it/diff.rs:460-480` -- existing "several" refusal test to update; add range/gap/empty witnesses.
- `crates/zanshin-jj/tests/it/bookmark_move.rs:565` -- advance refusal asserts `hints == &[HINT]`: becomes [summary hint, HINT].
- `schemas/envelope.fbs:3181-3186` -- `table Diff`: `commit_id: string` → `commit_ids: [string]`; `cargo make codegen` regenerates Rust + Dart.
- `crates/zanshin-ffi/src/diff.rs:140-160, 330-350, 446` -- encoder + its unit tests; `crates/zanshin-ffi/tests/it/diff_ffi.rs:121, 363` -- assertions.
- `packages/zanshin_core/lib/src/ffi/diff.dart:165-190, 200-210, 265` -- `Diff.commitId` → `commitIds` (List<String>), docs of `zanshinDiff`; tests `packages/zanshin_core/test/ffi/diff_test.dart:79,149`, `test/worker/diff_test.dart:71-105`. App does not read `Diff.commitId`.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- pattern for verbatim CLI hint comparison (`cli_hint`, `fresh_repo`, `BASE`); new module for diff range/gap + multiple-revisions hint, declared in `tests/oracle/main.rs:19`-ish `mod` list.
- `app/lib/src/features/graph/graph_toasts.dart:133-149` -- `graphOutcomeEntry` refusal branch: suppress commit/split only while `model.selected` equals the action's `id`.
- `app/lib/src/features/graph/graph_ports.dart:367-394` -- `GraphSplit`: remove `shown`.
- `app/lib/src/features/graph/graph_inspector.dart:429-446, 2049` -- `composerAction` runs with the full key; new `composerCommand` (short-id action's `command`) feeds the preview at :2049.
- `app/lib/src/features/graph/graph_inspector.dart:71-72, 214-220` -- `_viewed` reload in `_settingsChanged` (`setEquals`).
- Tests: `app/test/features/graph/graph_ports_test.dart:539-546` (`shown:`), `graph_inspector_test.dart:1229-1236` (split run vs shown command), `graph_toasts_test.dart:300-320`, viewed tests near `graph_inspector_test.dart:1480-1510`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/push.rs` -- `single_commit(base, expression, revision, templates)`; multi → `hints: vec![<one hint>]` rendered from the first five commits (`collect_ids` order) + `  ...`; `collect_ids` `pub(crate)`; `resolve_single` builds `Templates`; inline unit test only if a line is not reached by integration tests.
- `crates/zanshin-jj/src/bookmark_ops.rs` -- pass `Templates` to `single_commit`.
- `crates/zanshin-jj/src/hunks.rs` -- range form for `Revision(Some(_))`, `commit_ids`; docs.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::diff` passes templates; docs updated.
- `crates/zanshin-jj/tests/it/diff.rs`, `bookmark_move.rs`, push test with a several-commit `-r` -- witnesses for the matrix (range, siblings, gap message+hint, empty, hint lines with ≤5 / `...`).
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs`, `crates/zanshin-ffi/tests/it/diff_ffi.rs` -- `commit_ids`; run `cargo make codegen`, commit outputs.
- `packages/zanshin_core/lib/src/ffi/diff.dart` + its tests -- `commitIds`; a worker test diffs a range (`revision: 'a::@'` or similar) and gets several head ids or one.
- `crates/zanshin-parity/tests/oracle/<new>.rs` + `main.rs` -- CLI parity: `jj diff -r` gap refusal message+hint vs Zanshin; `jj diff --from 'all()'` (or `-r` in push) multi-revision hint block vs Zanshin's hint verbatim; a range diff's `--summary` paths vs Zanshin's file paths/kinds.
- `app/lib/src/features/graph/graph_toasts.dart`, `graph_ports.dart`, `graph_inspector.dart` -- items 3–5; tests in the matching `app/test/features/graph/*_test.dart`.
- `_bmad-output/implementation-artifacts/deferred-work.md`, `spec-10-24-closing-diff-any-revision.md` -- strike items 1–2 / add `resolved:` lines (with the code commit hash).

**Acceptance Criteria:**
- Given the matrix rows, when each runs through `Repo::diff` / `git_push` / `bookmark_advance` / the app models, then the outcome matches the row, and the parity tests show Zanshin's messages and hints equal the pinned CLI's.
- Given the composer runs a split on change X and the selection moves to Y before jj refuses, when the refusal arrives, then a warn toast shows jj's message and Y's composer shows no error.
- Given a split done from the composer, when its Undo toast shows, then its command names the full change id, and the composer's preview still shows the short id.
- Given an open inspector of repo R, when another writer changes R's `viewedFiles` in the settings store, then the inspector's Viewed state follows it.

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 15 findings — high 0, medium 0, low 11, false 3, maybe-false 1
- findings:
  - `[low]` `[reject]` blind: `single_commit` collects the whole set before refusing where the CLI stops at six — pre-existing `collect_ids` behavior; only a refusal on a huge set pays it; a bounded collector is added complexity for a rare path.
  - `[false]` `[reject]` blind: the `(Revision(_), _)` arm could ignore `-r` text — `texts` forces `parse_config` to `Some` for any `Revision(Some)`, so that arm sees only `Revision(None)`.
  - `[low]` `[patch]` blind: "one text joined with `|`" can change meaning by precedence — doc now says each argument parenthesized, `(a) | (b)`.
  - `[low]` `[reject]` blind: no "moved on" toast test for `GraphCommit` — the same switch arm as the tested `GraphSplit`; a duplicate test adds nothing.
  - `[low]` `[reject]` blind: a refusal shown in the composer is gone after navigating away — it was shown where the user acted (10.25's design); keeping it per key is the larger option the item did not ask for.
  - `[low]` `[reject]` blind: past 2000 marks a save's echo notifies twice — a redundant rebuild, no wrong state.
  - `[maybe-false]` `[reject]` blind: no test for `-r @` with no working-copy commit on the range path — it now evaluates `@` as `parse_union_revsets` does in the CLI, so the refusal is the CLI's; would be low if anything.
  - `[low]` `[reject]` blind: oracle helpers are looser than they look (lines before `Error:`, R/C mapped to M, no empty/sibling witnesses) — BASE has no renames; Rust tests cover empty/siblings; tightening is polish.
  - `[low]` `[reject]` blind: `commit_id` → `commit_ids` changes the field type in place — the cdylib and the Dart decoder are generated and built together (`cargo make codegen`); no persisted or cross-version buffers exist.
  - `[low]` `[patch]` blind: the "whole" case does not pin `commit_ids` — added `assert_eq!(whole.commit_ids, [b.1])`.
  - `[low]` `[reject]` edge: gap ids are all collected before refusing — same as the first row.
  - `[false]` `[reject]` edge: `&gap.hex()[..12]` panics on short ids — Zanshin repos are Git-backed (20-byte ids, 40 hex).
  - `[low]` `[reject]` edge: `--from all()` loads the whole set for a five-line hint — same as the first row.
  - `[low]` `[reject]` edge: removing the open repo from the registry, then any settings change, drops its Viewed marks — only while the project is removed under an open inspector; a store flag is added surface for a rare path.
  - `[false]` `[reject]` edge: away-and-back selection can lose the refusal — the toast and the inspector both decide at the same moment by the same key (`graph.selected` == the inspector's `_key`), so exactly one of them shows it.
  - verification-gap: no gaps reported. intent-alignment: descriptive only (no findings to route); its process notes (hash placeholders, Auto Run Result, recorded checks) are settled in Finalize.

## Design Notes

- Item 1 range form, from `cmd_diff`: `gaps = roots(T).range(heads(T)).minus(T)`, first id → refuse; `heads`, `roots` evaluated as commits; `parents` = roots' parents flattened, IndexSet (dedup, order kept); `from = merge_commit_trees(parents)`, `to = merge_commit_trees(heads)`; copy records for each parent × head. All expressions resolve through the call's prefixes (`collect_ids`).
- Item 2 hint is ONE string with embedded newlines (the CLI's formatted hint; Zanshin's multi-line hints already ride as one string, cf. the stale-working-copy hint), no trailing newline.
- Item 3: the smaller fix of the two the item offers — the operation toast already reports every other verb's refusal (10.23), so a late composer refusal joins it; no per-draft error state.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it diff::` / `bookmark_move::` / `push::`, `cargo test -p zanshin-jj --lib push` -- pass
- `cargo test -p zanshin-ffi` (diff unit + `--test it diff_ffi::`) -- pass
- `cargo test -p zanshin-parity --test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `cargo make codegen` -- outputs committed
- `flutter test` / `dart analyze` / `dart format --set-exit-if-changed` in `packages/zanshin_core` and `app` (graph tests) -- pass / clean

## Auto Run Result

Status: done. Code commit `cbdf25762b460b3cfa647e508c04d7697c2b4269`; the two review patches and these docs are in the commit that adds this spec.

**Items:**
1. **Fixed** (cbdf2576) — `Repo::diff`'s `-r` diffs a set as `cmd_diff` does: the roots' merged parents (in order, deduplicated) against the merged heads, copy records per parent × head, gaps refused ("Cannot diff revsets with gaps in." / "Revision <12-hex> would need to be in the set."), an empty set empty. `RevisionDiff.commit_ids` → schema `Diff.commit_ids: [string]` → FFI → Dart `Diff.commitIds`. Parity oracle `crates/zanshin-parity/tests/oracle/diff_revisions.rs`: gap refusal verbatim, a range's `--summary` paths.
2. **Fixed** (cbdf2576) — `single_commit` takes the call's `Templates` and adds the CLI's hint (heading, ≤5 `templates.commit_summary` lines, `  ...` past five) for git push, bookmark advance (before its own hint) and diff; oracle compares it verbatim for 4 and 7 commits.
3. **Fixed** (cbdf2576) — `graphOutcomeEntry` toasts a commit/split refusal (warn tone, jj's message) once its change is no longer selected; while it is, the composer shows it as before. The smaller option, matching 10.23's toasts.
4. **Fixed** (cbdf2576) — short id was not the rule (every other verb's action, and so its Undo/Redo toast, carries the full id): `GraphSplit.shown` removed, the run uses the full id, the composer's preview a separate short-id action (`composerCommand`), as the inspector's other buttons do.
5. **Fixed** (cbdf2576) — `_settingsChanged` reloads the Viewed set from the store and notifies only when it differs, as `general.diffLayout` is followed.

**Files changed:** `crates/zanshin-jj/src/{hunks,push,bookmark_ops,repo}.rs` (range form, hint, templates plumbing, docs); `crates/zanshin-jj/tests/it/{diff,push,bookmark_move,api_stability}.rs` (witnesses); `schemas/envelope.fbs` + generated `crates/zanshin-ffi/src/envelope_generated.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/{envelope_zanshin.ffi_generated,bindings}.dart`; `crates/zanshin-ffi/src/diff.rs`, `tests/it/diff_ffi.rs`; `packages/zanshin_core/lib/src/ffi/diff.dart`, `lib/src/worker/handle.dart` + tests; `crates/zanshin-parity/tests/oracle/{diff_revisions,main}.rs`; `app/lib/src/features/graph/{graph_toasts,graph_ports,graph_inspector}.dart` + tests; `docs/ffi-abi.md`; ledger: `deferred-work.md`, `spec-10-24-closing-diff-any-revision.md`.

**Review:** 15 findings — 2 patched (low: the `(a) | (b)` doc for several CLI `-r`; the `commit_ids == [B]` assertion), 13 rejected with reasons in the triage log, 0 deferred from review. One new deferral from verification: the Widgetbook catalogue's fake `Diff(commitId:)` (`app/widgetbook/folders/graph.dart:895`) no longer compiles — the dispatch forbade touching `app/widgetbook/`; one-line fix recorded in `deferred:` and mirrored to `deferred-work.md`. Follow-up review: not recommended (no high or medium patched; patched counts: low 2).

**Verification run (all targeted, no full gate per the run's gate rule):**
- `cargo test -p zanshin-jj` — 434 unit + 1509 integration passed (1 ignored); after the patches `--test it diff::` 38 passed.
- `cargo test -p zanshin-ffi` — 238 unit + 404 integration passed.
- `cargo test -p zanshin-parity --test oracle` — 506 passed.
- `cargo check --workspace --all-targets` — ok; `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — run by the implementer; outputs committed.
- `packages/zanshin_core`: `dart analyze --fatal-infos` clean, `dart format --set-exit-if-changed` clean, `dart test test/ffi/diff_test.dart test/worker/diff_test.dart` 16 passed.
- `app`: `flutter test test/features/graph` 804 passed; `dart format` clean; `dart analyze` — 2 errors, both in `app/widgetbook/folders/graph.dart` (the deferral above), none elsewhere.

**Residual risks:** the end-of-loop gate's `dart analyze app` fails until the Widgetbook line is fixed. No Marionette check of the late-refusal toast or the split's Undo toast in the running app. Redo of a split is not exercised by a test (same `of.command` path as Undo).

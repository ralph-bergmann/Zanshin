---
title: 'Story 10.24 closing run — diff takes any revision, the inspector diffs a node by its commit id'
type: 'bugfix'
created: '2026-11-01'
status: 'done'
baseline_revision: '0857bf2c60804847584f2be155314241d6087772'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: []
deferred:
  - summary: >-
      Repo::diff's -r takes one revision only; the CLI's multi-revision -r (a connected set diffed
      as one, gaps refused) is not ported.
    evidence: |-
      cmd_diff (cli/src/commands/diff.rs @ v0.46.0) reads -r through parse_union_revsets, diffs
      merge(parents of roots) against merge(heads) and refuses gaps; hunks::diff refuses a set of
      several commits ("resolved to more than one revision"). Porting it changes RevisionDiff's
      single commit_id across the FFI.
    location: >-
      crates/zanshin-jj/src/hunks.rs (diff, DiffRevisions::Revision)
    severity: low
  - summary: >-
      A revision that resolves to several commits is refused without the CLI's "resolved to these
      revisions" hint.
    evidence: |-
      crate::push::single_commit returns hints: vec![] for more than one commit; the CLI's
      format_multiple_revisions_error (cli/src/revset_util.rs @ v0.46.0) lists up to five commit
      summaries. Pre-existing in the helper shared by git push, bookmark advance and now diff.
    location: >-
      crates/zanshin-jj/src/push.rs (single_commit)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 10.24's run deferred one item, verified against the current code: (1) `hunks::diff` (`crates/zanshin-jj/src/hunks.rs:251`) resolves `-r` / `--from` / `--to` through `op_support::resolve_or_wc`, a `ChangeId` lookup of VISIBLE commits only, so a commit id fails `jj.change_not_found`; the inspector therefore reads no diff for a node keyed by its commit id (hidden or divergent, `graph_inspector.dart` `_fetch`), and `RepoGraphDetails.diff` passes a change id. `jj diff -r` / `--from` / `--to` take any revision (`resolve_single_rev`, `cli/src/commands/diff.rs` @ v0.46.0). Decided (Ralph, 2026-10-23): behave like the CLI.

**Approach:** `DiffRevisions` carries revision TEXT (`Option<String>`, `None` = `@`); a present side is parsed as a revset and resolved to exactly one commit with the CLI's `resolve_single_rev` refusals (the existing `crate::push::single_commit` after `crate::revset::parse_diagnosed`, as `bookmark advance` does), through the call's `revsets.short-prefixes`. The wire already carries strings: only docs change there. The app's `GraphDetails.diff` takes the node's commit id (as `show` does) and the inspector reads every node's diff by it; Viewed keys stay per change id.

## Boundaries & Constraints

**Always:** `None` keeps today's `@` path (`resolve_or_wc`, incl. its no-working-copy refusal); a commit-id hex prefix reaches a hidden commit as in the CLI; a set of zero or several commits is `jj.revset_resolution_error` ("didn't resolve to any revisions" / "resolved to more than one revision"), a bad expression `jj.revset_parse_error`; witnesses for every matrix row; gate rule of this run: targeted checks only, no `cargo make test` / `test-full` / `coverage`.

**Never:** multi-revision `-r` (the CLI's `-r 'B::D'` range with its gaps refusal) — not this item; a schema field change; a change to Story 10.24's spec, `epics.md`, `sprint-status.yaml`, `design/`, `design_system/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Change id | `-r <change id>` | as before | — |
| Commit id of a hidden commit | `-r <commit hex>` of a rewritten predecessor | that commit's diff, `commit_id` = it | — |
| Revset | `-r '@-'`, `--from '@--' --to '@-'` | the one commit each denotes | — |
| Unknown symbol | `-r yyyyyyyy` | refused | `RevsetResolutionError` |
| Several commits | `-r 'all()'` | refused | `RevsetResolutionError` "more than one" |
| Parse error | `-r 'bogus('` | refused | `RevsetParseError` |
| Inspector, hidden/divergent node | node key = commit id | summary + focused diff read by commit id, diff block shows | refused read as before |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:145-157` -- `DiffRevisions`: `ChangeId` → `String` revision text, docs. `:238-288` `diff`: `resolve` closure → `None`: `resolve_or_wc(.., None)`; `Some(text)`: `revset::revset_config(config, sink)` + `revset::parse_diagnosed(workspace, .., (text, revset::IN_REVSET_EXPRESSION), sink).map_err(mutate::rev)` + `push::single_commit(&readonly, &expr, text, prefixes)` (reuse, `bookmark_ops.rs:679-701` is the model). Module doc `:24-29`.
- `crates/zanshin-jj/src/repo.rs:4422-4462` -- `Repo::diff` doc: revisions are revset texts, errors list (no `ChangeNotFound` for a present side; `RevsetParseError`).
- `crates/zanshin-ffi/src/diff.rs:25-63, 83-111` -- reader maps strings straight through (no `ChangeId`); doc errors; inline tests `change()` helper.
- `schemas/envelope.fbs:361-371` -- `DiffRequest` doc: revisions/revsets, not change ids; then `cargo make codegen` (commit what it regenerates).
- `packages/zanshin_core/lib/src/worker/handle.dart:1634-1650`, `lib/src/ffi/diff.dart:199-205` -- doc only (revisions, error codes).
- `app/lib/src/features/graph/graph_ports.dart:769-790` -- `GraphDetails.diff(String commitId, …)`, doc; `RepoGraphDetails` passes it as `revision`.
- `app/lib/src/features/graph/graph_inspector.dart:71, 207-243, 351-380` -- keep `_changeId` (Viewed keys), add `_commitId` for both reads; `_fetch` always reads the summary by `layout.commitIdOf(node)`; drop the change-id-only comment/guard; class doc if it mentions it.
- Tests: `crates/zanshin-jj/tests/it/diff.rs` (helpers `revision`, `from_to`, `ChangeId(..)` → text; `an_unknown_revision_is_not_found` → resolution error; new: hidden commit id, revset texts, several commits, parse error); `crates/zanshin-ffi/tests/it/diff_ffi.rs` (`id` helper); `app/test/features/graph/graph_inspector_test.dart` (fake `diff(commitId)` keys by `commitId.substring(1)` as `show`; the "keyed by its commit id … reads no diff" test flips to reading it); `graph_card_menu_test.dart` fake signature; `graph_ports_test.dart` passes a commit id.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-jj/src/hunks.rs`, `repo.rs` -- revision text resolution + docs -- item 1.
- [x] `crates/zanshin-ffi/src/diff.rs`, `schemas/envelope.fbs` (+ codegen output) -- pass-through, docs -- item 1.
- [x] `packages/zanshin_core/lib/src/worker/handle.dart`, `lib/src/ffi/diff.dart` -- docs -- item 1.
- [x] `app/lib/src/features/graph/graph_ports.dart`, `graph_inspector.dart` -- commit id reads -- item 1.
- [x] tests for every matrix row (see Code Map).

**Acceptance Criteria:**
- Given the one item, when this run ends, then `## Auto Run Result` lists it by number with fixed (commit) / rejected (reason) / deferred.
- Given a hidden or divergent node in the running inspector's model, when it is selected, then its ± and focused diff come from its own commit (witnessed by the inspector test with the fake keyed by commit id).

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 28 findings — high 0, medium 0, low 23, false 5, maybe-false 0
- findings:
  - `low` `patch` [blind] No test diffs a divergent change. — Added a `diff` call to `change_id_prefix.rs`'s divergent test with the CLI's reason and three hints; it passes unchanged.
  - `low` `reject` [blind] Hidden commit ids are not tested past the jj layer. — The FFI passes the text through unchanged (reader tests) and `graph_ports_test.dart` drives the real handle with a commit id; the hidden resolution is jj-lib's, pinned in `diff.rs`.
  - `false` `reject` [blind] The fake's `substring(1)` hides a wrong id. — A change id stripped of its first character is no key in `fileDiffs`, so the flipped test would find no ± (the verification layer confirmed it pinned).
  - `low` `reject` [blind] The flipped inspector test does not check the focused read's id. — A focused read by change id would answer no file and show no lines; extra assertions add no branch coverage.
  - `low` `patch` [blind] `docs/ffi-abi.md` still lists `jj.change_not_found` for `zanshin_diff`. — Row codes updated, the `revision` bullet says revisions are revset texts.
  - `low` `patch` [blind] Revset parse diagnostics on the warnings are undocumented. — Docs in `repo.rs`, FFI, schema, `handle.dart` say so.
  - `false` `reject` [blind] Generated files missing from the reviewed diff. — Excluded on purpose; their diff is the regenerated doc comment (8 lines), and a rerun of `cargo make codegen` changes nothing.
  - `false` `reject` [blind] Header reflow looks hand-edited. — It is cbindgen's output from `cargo make codegen`; a rerun is stable.
  - `low` `patch` [blind] Touched doc lines are ragged / over width. — Rewrapped (Rust 100, Dart 80).
  - `low` `reject` [blind] `diff` imports `push::single_commit`. — `bookmark_ops` reuses it the same way; moving it is a refactor outside the item.
  - `low` `patch` [blind] The unknown-revision assertion accepts any reason. — Now asserts "Revision `yyyyyyyy` doesn't exist"; the test is renamed (no ambiguous case).
  - `low` `reject` [blind] Viewed keys stay per change id. — Story 10.24's decision (Viewed per change id + path + fingerprint); not item 1.
  - `low` `reject` [edge-case] The @ node reads its pre-snapshot commit. — `show` already reads by commit id (Story 10.8); the snapshot writes an operation, the watcher's reload re-fetches with the new commit id.
  - `low` `reject` [edge-case] A bookmark named exactly like a commit hex shadows it. — The CLI resolves `jj diff -r <hex>` the same way; needs a 40-hex bookmark name.
  - `low` `reject` [edge-case] `-r all()` materializes the set to refuse it. — Refusal path only; the GUI passes commit ids.
  - `low` `defer` [edge-case] Several commits are refused without the CLI's "resolved to these revisions" hint. — Pre-existing in `push::single_commit` (git push, bookmark advance); deferred.
  - `low` `patch` [edge-case] Docs claim `jj diff -r` parity though multi-revision `-r` is refused. — Docs say each side resolves to exactly one commit and the CLI's multi-revision `-r` is not ported.
  - `low` `patch` [verification-gap] Divergent / ambiguous diff refusal unpinned. — Same group as the first blind row; patched there.
  - `low` `reject` [verification-gap] Revset aliases on `diff` untested. — Same `revset_config` + `parse_diagnosed` wiring as `bookmark advance`, pinned by the revset suites.
  - `low` `defer` [verification-gap] No multiple-revisions hint. — Same group as the edge-case defer row.
  - `low` `patch` [verification-gap] The widgetbook demo's `diff` looks nodes up by change id. — `_DemoDetails.diff` takes the commit id and passes it to `show` directly.
  - `low` `defer` [intent-alignment] Multi-revision `-r` (CLI reading C) is not implemented. — New finding, deferred (changes `RevisionDiff`'s single `commit_id` across the FFI); see Design Notes.
  - `low` `defer` [intent-alignment] The CLI's hints for zero/several commits are not produced. — Same group as the edge-case defer row.
  - `low` `patch` [intent-alignment] No layer exercises a divergent node. — jj level patched (first blind row); the app level is the fake-keyed inspector test.
  - `low` `reject` [intent-alignment] FFI / zanshin_core never pass a commit id. — As the second blind row.
  - `low` `defer` [intent-alignment] `-r all()` refusal asserted where the CLI diffs the set. — Same group as the multi-revision defer row.
  - `false` `reject` [intent-alignment] The error contract changed for every caller. — Intended (CLI parity) and documented; the only in-repo caller is `RepoGraphDetails`, which maps neither code.
  - `false` `reject` [intent-alignment] Viewed keys share a namespace for divergent twins. — Duplicate of the blind Viewed row; the auditor did not weigh it.

## Design Notes

Single revision only: the item names `jj diff -r <any revision>` for one graph node; the CLI's multi-revision `-r` (a range diffed as one, gaps refused, `commit_id` then several heads) changes `RevisionDiff`'s shape across the FFI and is recorded as a new deferred finding. `@` stays on `resolve_or_wc` so its no-working-copy refusal and message stay as they are.

## Verification

**Commands (repo root):**
- `cargo test -p zanshin-jj --test it diff::` and `cargo test -p zanshin-ffi --test it diff_ffi::` and `cargo test -p zanshin-ffi --lib diff` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen` -- expected: generated docs updated, committed.
- `flutter test test/features/graph` + `dart analyze --fatal-infos .` + `dart format --set-exit-if-changed lib test widgetbook` in `app/`; `dart test test/worker/diff_test.dart` + `dart analyze` + `dart format --set-exit-if-changed .` in `packages/zanshin_core` -- expected: pass/clean.

## Verification Notes

2026-11-01 (gate rule of this run: no `cargo make test` / `test-full` / `coverage`; no jj verb's CLI behaviour diverged from the parity oracle's coverage — `diff` has no oracle case — so the oracle was not run):
- `cargo test -p zanshin-jj --test it -- diff:: change_id_prefix::` — 40 passed (incl. the new hidden-commit-id, revset-text, unknown/several/malformed and divergent-diff witnesses).
- `cargo test -p zanshin-ffi --test it diff_ffi::` — 6 passed; `cargo test -p zanshin-ffi --lib diff` — 9 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — regenerated the doc comments in `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart` (committed); a rerun changes nothing.
- `app/`: `flutter test test/features/graph` — 772 passed; `dart analyze --fatal-infos .` — no issues; `dart format --set-exit-if-changed lib test widgetbook` — 0 changed.
- `packages/zanshin_core`: `dart test test/worker/diff_test.dart` — 9 passed; `dart analyze` — no issues; `dart format --set-exit-if-changed .` — 0 changed.
- Matrix → tests: change id (existing `diff.rs` suite); hidden commit id (`a_hidden_commit_id_diffs_that_commit`); revset (`revset_texts_resolve_to_their_commit`); unknown / several / parse error (`an_unknown_several_or_malformed_revision_is_refused`, FFI `diff_ffi.rs`); inspector hidden/divergent node (`graph_inspector_test.dart`, the flipped commit-id test). Coverage not measured (gate rule).

## Auto Run Result

Status: done
Blocking condition: none

**Items:**
- **1 — fixed** (`ca8dee735bb33cb7eede07f4db8fd46c620f5e44`): real — `hunks::diff` resolved a present side as a visible change id only. `DiffRevisions` now carries revset text (`None` = `@` as before); a present side is parsed (`revset_config` once per call + `parse_diagnosed`) and resolved to exactly one commit with `push::single_commit` — change ids, commit ids incl. hidden ones, revsets, as `jj diff -r <revision>` / `--from` / `--to`. `GraphDetails.diff` takes a commit id; the inspector reads the summary and focused diff of every node by `commitIdOf(node)`, so hidden and divergent nodes show their own diff (Viewed keys stay per change id).

**Files:**
- `crates/zanshin-jj/src/hunks.rs`, `repo.rs`: revision text resolution, docs.
- `crates/zanshin-ffi/src/diff.rs`, `schemas/envelope.fbs` + regenerated `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`: pass-through, docs.
- `docs/ffi-abi.md`: `zanshin_diff` error codes, revision texts.
- `packages/zanshin_core/lib/src/worker/handle.dart`, `lib/src/ffi/diff.dart`: docs.
- `app/lib/src/features/graph/graph_ports.dart`, `graph_inspector.dart`, `app/widgetbook/folders/graph.dart`: commit-id reads.
- Tests: `crates/zanshin-jj/tests/it/diff.rs`, `change_id_prefix.rs`, `api_stability.rs`; `crates/zanshin-ffi/tests/it/diff_ffi.rs`; `app/test/features/graph/graph_inspector_test.dart`, `graph_card_menu_test.dart`, `graph_ports_test.dart`.

**Review findings** (one pass, 28: high 0, medium 0, low 23, false 5; § Review Triage Log):
- **Patched** (low): divergent-diff witness with the CLI's hints; exact unknown-revision reason; docs (single revision only, multi-revision `-r` not ported, parse diagnostics on warnings, rewrapped); `docs/ffi-abi.md`; the widgetbook demo's `diff` by commit id.
- **Deferred** (low, new, mirrored in deferred-work.md): the CLI's multi-revision `-r`; the missing "resolved to these revisions" hint in `push::single_commit`.
- **Rejected:** hidden ids untested past jj (pass-through, real-handle ports test); inspector test detail; `push` import; Viewed per change id (10.24's decision); stale @ commit id (show reads the same, reload follows); bookmark shadowing a commit hex (CLI identical); `all()` materialized on refusal; alias wiring test. False: the fake hiding ids, generated files/header (codegen, stable), error-contract change (intended), Viewed duplicate.

**Follow-up review recommended:** false — no high or medium entry patched (patched: low 7 entries).

**Residual risks:** coverage of the changed `hunks.rs` lines is not measured until the loop's gate; the hidden/divergent node in the running inspector is witnessed by a fake-keyed widget test plus the jj-level resolution, not checked in the app.

---
title: 'Story 10.44 closing run — New change here runs `jj new <name>`, rail counts tested'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: 'ca39b8c867e80a6d626960af882bc53eb15b8451'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings:
  - oversized
deferred: []
---

<intent-contract>

## Intent

**Problem:** Two items Story 10.44 deferred, both verified real in the current code. (1) "New change here" on a bookmark or tag row runs and shows `jj new <target change id>` (`BookmarkListModel.newHere`, `bookmark_list_model.dart:438-446`), because `Repo::new_change` (`crates/zanshin-jj/src/repo.rs:1596`) and `RepoHandle.newChange` take change ids only. So a divergent target is refused where `jj new <name>` works, and a conflicted ref uses its first side where the CLI refuses (jj-lib 0.47 `to_resolved_ref` → `ConflictedRef`). (2) No test sees the Tags (or Bookmarks) rail count update when its list loads: dropping `scope?.tags` from `HomePage`'s `Listenable.merge` (`home_page.dart:95`) fails no test, and the home rig cannot serve or order the two reads (`FakeProjectRepo.handle` throws; `RepoHandle` is a `final class`).

**Approach:** (1) Add a revset path to `jj new`: `Repo::new_change_on(revsets)` resolves each positional parent as a revset the way the CLI's `jj new <REVSETS>` does, carried through a new `revsets` field of the FFI `ChangeIdList`, `RepoHandle.newChange(…, revsets:)` and `GraphNew(revsets:, revsetTarget:)`; the row's New runs and shows `jj new <name>` / `jj new <name>@<remote>`. Existing change-id callers stay unchanged. (2) Make the list sources injectable (`RefListSourceOf`, the `GraphSourceOf` pattern) so the home test can gate the tag read and assert both rail counts.

## Boundaries & Constraints

**Always:**
- **Rust `Repo::new_change_on(&mut self, revsets: &[String])`** = `jj new <REVSETS>` (`cli/src/commands/new.rs` + `cli_util.rs:1934-1948,3770-3855` @ v0.47.0): an empty list refuses `InvalidInput` before the snapshot (via `with_checked_verb`, as `check_new_args`); in the verb, each revset is parsed "In revset expression" (`revset_config` + `parse_diagnosed` with the workspace, diagnostics into `ctx.warnings`) and evaluated in argument order against `tx.base_repo()` with the call's id-prefix context (`ctx.template_startup.id_prefix_context()`, as `workspace_add::resolve_some_revsets`); commit ids collected in order without duplicates; then `op_support::compute_commit_location(…, Some(&ids), None, None, "new commit")` (gives "No revisions found to use as parent" for an empty union). Everything after the plan is `mutate::new_change`'s existing body (merge tree, `new_description` + trailers, edit, advance-bookmarks for exactly one parent, finish "new empty commit") — share it, do not copy it (e.g. an extra `revsets: &[String]` parameter on the internal `mutate::new_change` that, when non-empty, replaces `plan_new`). `plan_new`, `drop_actions` and `Repo::new_change` keep their behavior and signatures.
- Errors map through the existing `rev`/`cfg`/`be`: parse → `RevsetParseError`; unknown name, conflicted ref, divergent change id → `RevsetResolutionError` with jj's hints; empty union → `InvalidInput`.
- **FFI:** append `revsets: [string]` to `table ChangeIdList` (read only by `zanshin_new_change`; abandon and parallelize ignore it). `read_new_change_args` reads it; `revsets` together with any of `change_ids` / `insert_after` / `insert_before` → `ffi.invalid_argument` (a caller bug; refused while reading the buffer). Non-empty `revsets` → `new_change_on`, else today's call. `cargo make codegen` (commit its output); `docs/ffi-abi.md` (ChangeIdList rows, `zanshin_new_change` row adds `jj.revset_parse_error`) and the extern fn's doc comment.
- **zanshin_core:** `RepoHandle.newChange(parents, {insertAfter, insertBefore, revsets = const []})` → `NewChangeCommand.revsets` → isolate → `zanshinNewChange(…, revsets:)` → `_withChangeIdListBytes(revsets:)`; NUL check on `revsets`; doc names the combination refusal and `jj.revset_parse_error`.
- **App:** `GraphNew` gains `revsets` (positional revsets, run and shown as written after `parents`) and `revsetTarget` (the change key they name now: pending key, reload anchor `_plan`, selection follow in `_succeeded`). `RepoGraphActions.run` passes `revsets`; the all-empty `_newOnAt` case also needs `revsets` empty. `BookmarkListModel.newCommand(row)` / `newHere(row)`: `GraphNew(revsets: [symbol], revsetTarget: target)` with `symbol` = `revsetSymbol(name)` for a local row, `remoteBookmarkSymbol(name, remote)` for a remote row (both kinds; tags resolve through the same symbol); offered only with a target, as today.
- **Rail counts:** `typedef RefListSourceOf = BookmarkListSource Function(ProjectRepo repo, RefKind kind)` beside `GraphSourceOf` in `project_scope.dart`, the app's binding (`RepoBookmarkListSource` / `RepoTagListSource` by kind) in `app_module.dart`, used by the `bookmarkList` / `tagList` providers; `TestModule.refListSources` overrides it; regenerate `main.inject.dart` and `test_component.inject.dart` with build_runner.
- Tests never touch Ralph's settings or jj config; jj only in temp dirs tests create.

**Never:**
- Changing `Repo::new_change`'s signature or its change-id resolution; revsets for `-A`/`-B`; a `-m` for `new`.
- Resolving the ref in Dart first and passing its change id (that is today's gap).
- The full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Local bookmark | `new_change_on(["main"])`, `main` on C | new empty change on C, `@` moves, op "new empty commit" | — |
| Remote bookmark | `["main@origin"]` | new change on the remote target | — |
| Divergent target | `main` on one of two commits of a divergent change | new change on that commit (no refusal) | — |
| Conflicted bookmark | `main` with two adds | refused, nothing written | `RevsetResolutionError`, jj's `ConflictedRef` text |
| Unknown name | `["nope"]` | refused | `RevsetResolutionError` "Revision `nope` doesn't exist" |
| Empty union / list | `["none()"]` / `[]` | refused | `InvalidInput` "No revisions found to use as parent" / before the snapshot |
| Duplicates, merge | `["main", "main"]` / `["a", "b"]` | one parent / a merge of two | — |
| FFI combination | `revsets` + `change_ids` | refused | `ffi.invalid_argument` |
| Row New | local `my topic` / remote `main@origin` | runs and shows `jj new 'my topic'` (quoted as `revsetSymbol`) / `jj new main@origin` | refusal → toast (existing) |
| Rail counts | bookmarks read 2 rows, tag read gated | Bookmarks count "2", Tags none; gate released → Tags "3", Bookmarks still "2" | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/repo.rs:1534-1606` -- `Repo::new_change` doc + body (`with_checked_verb(cli_command::NEW, …)`); add `new_change_on` beside it.
- `crates/zanshin-jj/src/mutate.rs:1141-1347` -- `check_new_args` `:1149`, `plan_new` `:1214`, `new_change` `:1274` (plan at `:1285`, advance `:1292-1300` keyed on empty insert lists). `rev` `:628`, `cfg`, `be`.
- `crates/zanshin-jj/src/workspace_add.rs:307-336` -- `resolve_some_revsets`: the parse/evaluate/dedup loop to mirror (its empty refusal text differs: "Empty revision set").
- `crates/zanshin-jj/src/arrange.rs:296-305` -- in-verb `revset_config` + `parse_diagnosed(workspace, …, IN_REVSET_EXPRESSION)` pattern.
- `crates/zanshin-jj/src/revset.rs:412` `revset_config`, `:474` `parse_diagnosed`, `:1022` `evaluate_revset`.
- `crates/zanshin-jj/src/op_support.rs:281` -- `compute_commit_location(repo, templates, destination, after, before, noun)`; empty parents → "No revisions found to use as parent".
- `crates/zanshin-jj/tests/it/mutate.rs:221-294` -- `new_change` tests (`tiny-3-commits`, `oracle_layout`); add `new_change_on` tests. `test_helpers`: `set_local_bookmark(root, name, &[targets])` (2 targets = conflicted), `set_remote_bookmark`, `add_divergent_twin`.
- `crates/zanshin-parity/tests/oracle/scenarios.rs:2449-2560` -- `new` scenarios (`simple(name, zanshin, cli args)`, `b-mark` in `BASE`); add `new_change_on` scenarios.
- `schemas/envelope.fbs:~241-256` -- `table ChangeIdList` (append `revsets`), its doc.
- `crates/zanshin-ffi/src/repo.rs:283-310` (`NewChangeArgs`, `read_new_change_args`), `:1242-1254` (`zanshin_new_change` + doc above it); tests `crates/zanshin-ffi/tests/it/repo_write_ffi.rs:94` (`new_change_request_bytes`), `:276-360`.
- `docs/ffi-abi.md:513-516,558,663` -- ChangeIdList / `zanshin_new_change` rows.
- `packages/zanshin_core/lib/src/ffi/mutate.dart:24-45,68-87` (`_withChangeIdListBytes`, `zanshinNewChange`), `lib/src/worker/commands.dart:448-478` (`NewChangeCommand`), `lib/src/worker/isolate.dart:1120-1152,4163-4182`, `lib/src/worker/handle.dart:540-586`; tests: grep `newChange(` under `packages/zanshin_core/test`.
- `app/lib/src/features/graph/graph_ports.dart:224-251` (`GraphNew`), `:708-712` (`remoteBookmarkSymbol`, `revsetSymbol`), `:958-961` (dispatch); `graph_view_model.dart:874-875` (`_plan`), `:920-923` (`_succeeded`).
- `app/lib/src/features/bookmarks/bookmark_list_model.dart:438-446` -- `newCommand`, `newHere`; `bookmark_list_view.dart:769,789` use them.
- `app/lib/src/features/home/project_scope.dart:39-46` (`GraphSourceOf`, `RemoteSyncOf`), `:205-215` (`bookmarkList`, `tagList` providers); `app/lib/src/app/app_module.dart:83-90`; `app/test/helpers/test_component.dart:41-80` (`TestModule`).
- `app/test/features/home/home_page_test.dart:74-93` (`pumpHome`), `:490-520` (rail test); `app/test/features/home/project_graph_host_test.dart:43-46` (ScriptedGraphSource via `graphSources`); `app/test/helpers/fake_bookmark_list.dart:21` (`FakeBookmarkListSource` with `gate`, `localRow`).
- Tests to update: `app/test/features/bookmarks/bookmark_list_model_test.dart:381-402` (`newCommand` expects `jj new k1`), `graph_ports` command tests for `GraphNew`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/{repo,mutate}.rs` -- `new_change_on` + the revset plan sharing `new_change`'s body -- item 1 backend.
- `crates/zanshin-jj/tests/it/mutate.rs` -- matrix rows 1-7 against `tiny-3-commits` with in-test bookmarks.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- `new_on_bookmark` (`jj new b-mark`) and `new_on_unknown_name` (`jj new nope`) against `new_change_on`; pass without a ledger entry.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/repo.rs`, `cargo make codegen` outputs, `docs/ffi-abi.md` -- the `revsets` field and its routing -- FFI tests: round trip on a bookmark name, the combination refusal.
- `packages/zanshin_core/lib/src/{ffi/mutate,worker/commands,worker/isolate,worker/handle}.dart` -- `revsets` plumbing -- a cdylib test: `newChange(const [], revsets: ['<bookmark>'])` lands on its target.
- `app/lib/src/features/graph/{graph_ports,graph_view_model}.dart`, `app/lib/src/features/bookmarks/bookmark_list_model.dart` -- `GraphNew.revsets`/`revsetTarget`, the row's New -- unit tests: commands (`jj new main`, `jj new main@origin`, quoted name), dispatch passes `revsets`, newHere runs `GraphNew(revsets:…, revsetTarget:…)`, the pending/anchor/selection use `revsetTarget`.
- `app/lib/src/features/home/project_scope.dart`, `app/lib/src/app/app_module.dart`, `app/test/helpers/test_component.dart`, build_runner outputs -- `RefListSourceOf` -- item 2 seam.
- `app/test/features/home/home_page_test.dart` -- the rail-count test (matrix last row); mutation-check it by dropping `scope?.tags`.

**Acceptance Criteria:**
- Given a bookmark row whose target change is divergent, when New change here is pressed, then a new change is created on the bookmark's commit and the button's tooltip shows `jj new <name>`.
- Given a conflicted bookmark, when New change here is pressed, then nothing is written and the refusal toast shows jj's conflicted-ref text.
- Given every existing change-id caller of `new_change` / `RepoHandle.newChange`, when its tests run, then they pass unchanged.
- Given `HomePage` with `scope?.tags` dropped from its merged listenable, when the home rail-count test runs, then it fails.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 23 findings — high 0, medium 1, low 15, false 7, maybe-false 0
- findings:
  - `[low]` `[patch]` (edge) A divergent target's row passes the change id as `revsetTarget`, but the layout keys a divergent node by commit id, so pending card, anchor and selection follow miss — `revsetTarget` is now `row.key ?? target` (the layout key), with a model test.
  - `[low]` `[reject]` (edge) A tag and a bookmark with the same name: `jj new main` on the bookmark row lands on the tag (jj-lib 0.47 `DEFAULT_RESOLVERS` = tag, then bookmark) — that is exactly what the shown command does in the CLI; same-named refs are rare, and an unambiguous form would no longer be the `jj new <name>` the intent asks for.
  - `[false]` `[reject]` (edge) `GraphNew` accepts `revsets` with `parents`/`-A`/`-B` — no caller builds that; the FFI refuses it loudly (`ffi.invalid_argument`), which is correct behavior for an unreachable shape.
  - `[low]` `[patch]` (edge) Claim: the divergent case gets no pending card/anchor/selection follow — same root as the first row; patched there.
  - `[medium]` `[patch]` (verification) `repoRefListSourceOf`'s kind→source mapping is run by no test; swapped arms would pass — unit test added (tag → `RepoTagListSource`, bookmark → `RepoBookmarkListSource` and not `RepoTagListSource`).
  - `[low]` `[patch]` (intent) The oracle compares only two `new_change_on` scenarios — added `new_on_empty_revset` (`jj new 'none()'`) and `new_on_duplicate_names` (`jj new b-mark b-mark`); divergent and conflicted refs stay on `tests/it/mutate.rs` (their CLI setup needs concurrent operations; the resolution is jj-lib's own resolver, so the texts are jj's).
  - `[false]` `[reject]` (intent) "The operation records the change id, not the name" is unaddressed — Zanshin's transactions record no CLI args; both commands write the op "new empty commit", so nothing differs.
  - `[low]` `[reject]` (intent) `-A`/`-B` stay change ids and a revsets + id-list mix is `ffi.invalid_argument`, not `jj.invalid_input` — no caller needs either; the intent asks for a ref-name shape (`<name>`, `<name>@<remote>`).
  - `[low]` `[patch]` (intent) The Bookmarks-count assertion did not fail with `scope?.bookmarks` dropped (mutation-checked) — the test now gates and releases the bookmark read first; both drops fail it.
  - `[false]` `[reject]` (intent) A production DI seam was added for a test — `RepoHandle` is a `final class` and `FakeProjectRepo.handle` cannot serve reads, so the rig needs a source seam; `RefListSourceOf` follows the existing `GraphSourceOf` / `RemoteSyncOf` pattern.
  - `[low]` `[reject]` (intent) A conflicted ref's pending card shows until jj refuses — every refused action shows its pending card until the refusal; the toast explains.
  - `[low]` `[reject]` (intent) No app-level real-repo test runs `name@remote` — the Rust test resolves `main@origin`; the app passes the text through unchanged and its command is unit-tested.
  - `[low]` `[reject]` (blind) Bookmark row lands on a same-named tag — same as the edge row above.
  - `[low]` `[reject]` (blind) New stays offered on a conflicted row and now always refuses — that is the CLI's `jj new <name>` (the intent: "the CLI refuses"); the refusal toast shows jj's conflicted-ref text and hints; hiding the button is a UI design change.
  - `[false]` `[reject]` (blind) `revsetTarget` can be stale when the ref moved — the list re-reads on every operation change (`_graphChanged` → `_load`) before its rows are used; between operations nothing moves the ref.
  - `[false]` `[reject]` (blind) `GraphNew` does not enforce its invariant — same as the edge row above.
  - `[low]` `[reject]` (blind) `revsetTarget` is single while `revsets` is a list; revsets without a target have no pending key — no caller passes several revsets; a null anchor is the existing "no anchor" path.
  - `[low]` `[patch]` (blind) The oracle covers only the two easiest cases — same root as the intent oracle row; patched there.
  - `[low]` `[patch]` (blind) Remote tag rows' New is untested — model test asserts `jj new v1@origin`; the helper rename is rejected (it touches existing callers for a name only).
  - `[low]` `[reject]` (blind) Refusals untested end to end through FFI/UI — the refusal codes go through the shared `map_mutate_err` and the graph's refusal toast, both tested elsewhere; the Rust tests pin the refusals themselves.
  - `[low]` `[patch]` (blind) Doc problems — the long `new_change` doc line is rewrapped and `GraphNew.revsets` says they show shell-quoted; the `@ v0.46.0` cite in `new_change`'s doc is pre-existing and left.
  - `[false]` `[reject]` (blind) `Vec::contains` dedupe is O(n²) and duplicates logic — `resolve_ordered` dedupes the same way; n is the number of revsets passed (one in practice); `wc_parent_hexes` duplication is test-only (moving it to `test_helpers` is a refactor).
  - `[false]` `[reject]` (blind) Two concerns in one diff, planning files missing — the intent names both items; the spec is the claims file, committed with the change.

## Design Notes

- **Why a separate `revsets` list, not revsets in `parents`:** a change id is a valid revset, but the change-id path has its own refusal taxonomy (`jj.change_not_found` for a malformed or absent id) that callers and tests rely on, and ~50 call sites pass `&[ChangeId]`. The revset path is additive; `-A`/`-B` keep change ids because no caller needs a revset there.
- **What the CLI does** (v0.47.0): `jj new main` evaluates `main` through jj-lib's symbol resolver — a conflicted local or remote ref refuses (`ConflictedRef`), a ref on one commit of a divergent change resolves to that commit, and several revsets union in order without duplicates. The op description stays "new empty commit"; Zanshin records no CLI args, so nothing else differs.
- **`revsetTarget`** keeps the row's New behaving as before in the graph (pending card, birth anchor, selection follow) without parsing the revset in Dart.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it mutate::` and the new unit tests -- pass.
- `cargo test -p zanshin-ffi --test it repo_write_ffi::` -- pass.
- `cargo test -p zanshin-parity --test oracle` -- pass (no new ledger entry).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- outputs committed.
- `flutter test` / `dart analyze` / `dart format --set-exit-if-changed .` in `packages/zanshin_core` (new-change tests) and `app/` (`test/features/bookmarks test/features/graph test/features/home test/app/menu test/architecture`) -- pass / clean.
- `dart run build_runner build --delete-conflicting-outputs` in `app/` -- outputs committed.

**Verification notes (2026-11-16, targeted checks per the story loop's gate rule):**
- `cargo test -p zanshin-jj --test it mutate::` — 28 pass (7 new `new_change_on` tests); the implementer also ran `--lib` — 455 pass.
- `cargo test -p zanshin-ffi --test it repo_write_ffi::` — 44 pass.
- `cargo test -p zanshin-parity --test oracle` — 556 pass (four new scenarios, count 499 → 503, no ledger entry).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` and `cargo fmt --all --check` — clean.
- `cargo make codegen` — run, outputs committed; a second run changed nothing.
- `cargo make test-app test/features/bookmarks test/features/graph test/features/home test/app/menu test/architecture` — 1236 pass.
- `dart test test/worker/mutate_test.dart test/ffi/bookmark_ops_test.dart` in `packages/zanshin_core` — 59 pass (real cdylib); the implementer ran the whole zanshin_core suite — 1213 pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_core` — clean.
- Mutation checks: dropping `scope?.bookmarks` or `scope?.tags` from `home_page.dart`'s merged listenable each fails the rail-count test; restored with Edit, `git diff` on the file empty.
- Not run (gate rule): `cargo make test` / `test-full` / `coverage`.

## Auto Run Result

Status: done

**Items.**
1. **Fixed** (9ca6885ad6f274aa151a642dcb8fc5e5a9a574ef). New `Repo::new_change_on(revsets)` = the CLI's `jj new <REVSETS>` (v0.47.0 `resolve_revsets_ordered` + `compute_commit_location`), carried through `ChangeIdList.revsets`, `RepoHandle.newChange(revsets:)` and `GraphNew(revsets:, revsetTarget:)`. A bookmark or tag row's New change here runs and shows `jj new <name>` / `jj new <name>@<remote>`: a divergent target resolves, a conflicted ref refuses with jj's text. Existing change-id callers are unchanged. Story 10.47 can pass any ref symbol.
2. **Fixed** (9ca6885ad6f274aa151a642dcb8fc5e5a9a574ef). An injectable `RefListSourceOf` (the `GraphSourceOf` pattern) lets the home test gate both list reads; it asserts each rail count follows its own list, and fails when either `scope?.bookmarks` or `scope?.tags` is dropped.

**Files changed.**
- `crates/zanshin-jj/src/{repo,mutate}.rs` — `new_change_on`, `plan_new_on` sharing `new_change`'s body.
- `crates/zanshin-jj/tests/it/mutate.rs` — local, remote, divergent, conflicted, unknown, parse error, empty, duplicates/merge.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` — `new_on_bookmark`, `new_on_unknown_name`, `new_on_empty_revset`, `new_on_duplicate_names`.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/repo.rs`, codegen outputs, `docs/ffi-abi.md` — `revsets` field, routing, combination refusal.
- `crates/zanshin-ffi/tests/it/repo_write_ffi.rs` — round trip on a name, combination refusal.
- `packages/zanshin_core/lib/src/{ffi/mutate,worker/commands,worker/isolate,worker/handle}.dart` + tests — `revsets` plumbing.
- `app/lib/src/features/graph/{graph_ports,graph_view_model}.dart` — `GraphNew.revsets` / `revsetTarget`.
- `app/lib/src/features/bookmarks/bookmark_list_model.dart` — the row's New by ref symbol, `revsetTarget` = the layout key.
- `app/lib/src/features/home/project_scope.dart`, `app/lib/src/app/app_module.dart`, `app/test/helpers/test_component.dart`, inject outputs — `RefListSourceOf`.
- Tests: `bookmark_list_{model,view}_test.dart`, `graph_ports_test.dart` (incl. a real-repo `jj new 'my topic'`), `graph_view_model_test.dart`, `home_page_test.dart`, new `project_scope_test.dart`.

**Review.** 23 findings. Patched: 1 medium (`repoRefListSourceOf` mapping test) and 7 low rows in 5 entries (divergent row's `revsetTarget` = layout key, Bookmarks-count sensitivity, two more oracle scenarios, remote tag row command test, doc wording). Deferred: none. Rejected: same-named tag shadows a bookmark (low, the CLI's own `jj new <name>`, rare), `GraphNew` invariant (false, unreachable, refused loudly), op records args (false, Zanshin records none), `-A`/`-B` revsets and the mix code (low, no caller), DI seam for a test (false, `RepoHandle` is final), pending card before a refusal (low, shared behavior), no app-level `name@remote` run (low, Rust covers it), New on a conflicted row refuses (low, the CLI's behavior; hiding is a design change), stale `revsetTarget` (false, the list re-reads per operation), single `revsetTarget` (low, no multi-revset caller), refusals end to end (low, shared mapping), O(n²) dedupe / helper duplication (false), two concerns in one diff (false, the intent names both).

**Follow-up review:** not recommended — patched 0 high, 1 medium, 7 low.

**Residual risks.** No Marionette check (only tooltip and command text changed; widget tests cover them). When the rail-count test fails, 12 later tests in `home_page_test.dart` fail after it (state left behind on failure only). Coverage and the full gate run at the end of the story loop.

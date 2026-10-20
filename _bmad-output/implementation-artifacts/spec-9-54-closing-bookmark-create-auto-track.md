---
title: 'Story 9.54 closing run — `bookmark create` auto-tracks on matching remotes'
type: 'bugfix'
created: '2026-10-20'
status: 'in-progress'
baseline_revision: 'b162d610c4c20bc6ce2ff0e689c0f9f633468cef'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 9.54's `deferred:` item), verified against the code at `b162d61`: the CLI's `jj bookmark create` (`cli/src/commands/bookmark/create.rs:88-111` @ v0.46.0) parses `remotes.<name>.auto-track-bookmarks` ∪ `auto-track-created-bookmarks` (`revset_util.rs:444-476` `parse_remote_auto_track_bookmarks_map_for_new_bookmarks`) and, for every created name a remote's matcher accepts and that remote has a remote view, calls `track_remote_bookmark` (warning "Auto-tracking bookmark that exists on the remote: <name>@<remote>" when that remote view already holds the name). Zanshin's `bookmark_ops::create` (`crates/zanshin-jj/src/bookmark_ops.rs:184-241`) only sets the local target; its module doc (`:23-26`) and `Repo::bookmark_create`'s doc (`crates/zanshin-jj/src/repo.rs` ~`:1968-1970`) call this a deliberate deferral to Story 9.11. That deferral needs no product decision: CLI parity is the rule, and jj-lib's `MutableRepo::track_remote_bookmark` is all it takes.

**Approach:** Port the CLI's loop into `create`'s transaction closure after the empty-target warning, with a config helper shared with the existing `auto-track-bookmarks` parse, and one new typed warning for the "exists on the remote" line. The outermost surface (`Repo::bookmark_create`, its FFI extern and `RepoHandle.bookmarkCreate`) needs no schema change: the tracked rows show in `list_bookmarks`, the warning rides the envelope's `warnings`.

## Boundaries & Constraints

**Always:**
- CLI order inside the transaction: both per-name guards → `jj.bookmark_target_empty` → parse the matchers (all remotes, even when no name matches — a broken value refuses the whole call) → per name in argument order: set the local target, then for each remote whose matcher accepts the name AND that has a remote view in the transaction's BASE repo (the view the guards read): warn if that base remote view's `bookmarks` already holds the name, then `track_remote_bookmark(name@remote)` (jj-lib's own merge of the remote target into the local one — keep its effect, conflicts included).
- Matcher map = per remote: the union of the parsed `auto-track-bookmarks` and `auto-track-created-bookmarks` (either alone suffices; neither → no entry). Remotes iterate in name order (the CLI's `HashMap` order is unspecified; name order makes the warnings deterministic). A parse failure refuses as `MutateError::Config` (→ `jj.config_error`) with the CLI's text "Invalid `remotes.<remote>.<field>`: <kind>" (`<remote>` via `as_symbol`), as `config::remote_auto_track_bookmarks` already does for `auto-track-bookmarks`; a `remotes.<name>` entry that is not a table of the known keys refuses as that helper does. Factor the per-field parse into ONE helper both functions use; the existing import-options behaviour stays byte-identical.
- New warning `WarningKind::BookmarkAutoTrackExisting` → code `jj.bookmark_auto_track_existing`, message exactly `Auto-tracking bookmark that exists on the remote: {symbol}` with `symbol` = `name.to_remote_symbol(remote)`'s Display. Wire it everywhere the last added kind (`CloneBranchesUnmatched`) is wired: `warning.rs`, `crates/zanshin-ffi/src/envelope.rs` (const, both maps, the exhaustive list), `tests/api_stability.rs` (both lists), `docs/rust-error-codes.md` warning table, Dart `packages/zanshin_core/lib/src/ffi/warning.dart` (constant + list) and `test/ffi/warning_test.dart`.
- Remote-name diagnostics: jj-lib 0.46 emits none for string patterns — dropped as `union_expression` documents.
- Docs: remove the "No auto-tracking on create" divergence from `bookmark_ops.rs`'s module doc and the matching paragraph from `Repo::bookmark_create`; add the auto-track behaviour, the new warning and `MutateError::Config` (# Errors) there and on `create`; update the FFI extern doc (`crates/zanshin-ffi/src/bookmark_ops.rs:146`) and `RepoHandle.bookmarkCreate`'s doc if they list warnings/behaviour, regenerating with `cargo make codegen` when an extern doc changes; `docs/ffi-abi.md` row of `zanshin_bookmark_create` already lists `jj.config_error` — add the warning only where that doc lists per-call warnings.

**Never:**
- No `bookmark set` / `track` / `untrack` / `forget` (Story 9.11 stays backlog); no change to fetch / import / clone auto-tracking; no FFI schema field; no UI widget, no MCP change.
- No change to the op description, to the existing guards or their order, or to Story 9.54's code beyond what this item needs; never regenerate fixtures; never lower `coverage-baseline.txt`; no edit of `epics.md`, `epic-9-context.md`, `sprint-status.yaml` or Story 9.54's spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Created-only config | remote `origin` (view, no rows); `remotes.origin.auto-track-created-bookmarks = "*"`; create `feature` | local `feature` at @; `feature@origin` row tracked, target absent; no warning | — |
| Plain auto-track config | same with `auto-track-bookmarks = "glob:feat*"`; create `feature`, `other` | only `feature@origin` tracked | — |
| No match / no view | matcher rejects the name, or `remotes.ghost.*` set but no `ghost` remote view | no remote row; no warning; same op description | — |
| Two remotes | `origin` and `upstream` both match | both rows tracked | — |
| Existing untracked remote | untracked `feature@origin` present (local `feature` absent); created-only config | `jj.bookmark_auto_track_existing` "Auto-tracking bookmark that exists on the remote: feature@origin"; row tracked; local target = jj-lib's merge result | — |
| Broken pattern | `remotes.origin.auto-track-created-bookmarks = "("` | refused, op head unchanged, nothing created | `MutateError::Config` "…Invalid `remotes.origin.auto-track-created-bookmarks`: …" |
| Guards first | name already a local bookmark + broken pattern | `BookmarkExists` (guards precede the parse) | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/bookmark_ops.rs` -- module doc divergence `:23-26` (remove), `create` `:156-241` (doc; closure `:208-239`: guards `:215-227`, empty warning `:228-230`, writes `:231-234` — the matcher parse goes after the warning, tracking into the write loop; base repo = `tx.base_repo()` or the `readonly` it was started from).
- `crates/zanshin-jj/src/config.rs` -- `git_import_options` `:1334-1349` (doc `:1320-1333`), `remote_auto_track_bookmarks` `:1354-1378` (factor the per-field parse; add the `_for_new_bookmarks` sibling returning a name-ordered map); inline test near `:3732` / `:3473-3480` for the style of config tests.
- `crates/zanshin-jj/src/mutate.rs` -- `cfg` `:434` (`ConfigError` → `MutateError::Config`), `finish_or_no_op_at` `:1274-1328` (the closure's sink is `ctx.warnings`, kept on a refusal).
- `crates/zanshin-jj/src/repo.rs` -- `Repo::bookmark_create` doc `~:1940-1990` (auto-track paragraph `~:1968-1970`; # Errors gains `Config`).
- `crates/zanshin-jj/src/warning.rs` -- `WarningKind` `:27-176` (add after `BookmarkNamesUnmatched` or at the end, with the CLI anchor in the doc).
- `crates/zanshin-ffi/src/envelope.rs` -- code consts ~`:268`/`:337`, `warning_code` map ~`:363`/`:394`, test map ~`:1206`/`:1237`, list ~`:1265`/`:1296`.
- `crates/zanshin-ffi/src/bookmark_ops.rs:146` -- extern doc; `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` -- an FFI witness that the warning code crosses.
- `packages/zanshin_core/lib/src/ffi/warning.dart` -- constants ~`:97`/`:205`, list ~`:267`; `test/ffi/warning_test.dart` ~`:394`/`:425`; `lib/src/worker/handle.dart:1348` `bookmarkCreate` doc.
- `jj-lib-0.46.0/src/repo.rs:1918` `MutableRepo::track_remote_bookmark` (async → `pollster::block_on`, `mutate::be`); `view.rs:376` `get_remote_view`; `git.rs` `add_remote` calls `ensure_remote` (a `git remote add` makes the remote view the CLI checks); `settings.rs:70-74` `RemoteSettings { auto_track_bookmarks, auto_track_created_bookmarks }`.
- `crates/zanshin-jj/tests/bookmark_ops.rs` -- fixtures/helpers `:26-140` (`set_remote_bookmark` makes a remote view with a row; a view without rows via `Repo::git_remote_add` on the git-backed fixture or the test_helpers equivalent; repo config via `zanshin_jj::config_set` under `pin_env`); `tests/api_stability.rs:1378`/`:1449` warning lists.
- Oracle: `crates/zanshin-parity/tests/oracle/git_scenarios.rs` -- `REMOTE` `:214-217`, `BOOKMARK_TEMPLATE` `:208`, `push_read_back` `:228-243` (lists `--all-remotes` rows with ` tracked`; check whether `jj bookmark list --all-remotes` shows an ABSENT tracked row — if not, the scenario needs an `extra` that reads remote rows through jj-lib, e.g. `scenarios.rs::load_workspace` `:89` + `view.all_remote_bookmarks()`), `push()` builder `:258-275`; `state.rs` compares only LOCAL bookmarks; `main.rs` `parity!` id list + scenario-count pin.
- App: `app/test/features/projects/worker_project_repos_test.dart` -- real-worker group `:275-`, `trackedMain` `:479-515` (repo-scope `worker.configSet` recipe, XDG guard), `gitAt` `:442-448`; the dot rule `app/lib/src/features/projects/project_repos.dart` `trackingStatusOf` `:121-146` (null-target term gated on push remotes, Story 9.54).
- `_bmad-output/implementation-artifacts/deferred-work.md:1657-1662` -- the item's bullet, marked resolved at finalisation.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- shared per-field parse; `remote_auto_track_bookmarks_for_new_bookmarks(config)` (name-ordered); inline tests: union of both fields, either alone, broken `auto-track-created-bookmarks` text -- the CLI's matcher map.
- `crates/zanshin-jj/src/warning.rs`, `crates/zanshin-ffi/src/envelope.rs`, `docs/rust-error-codes.md`, `packages/zanshin_core/lib/src/ffi/warning.dart` (+ its test), `tests/api_stability.rs` -- the new warning kind/code -- typed CLI warning.
- `crates/zanshin-jj/src/bookmark_ops.rs`, `repo.rs` -- the loop in CLI order; docs -- parity.
- `crates/zanshin-ffi/src/bookmark_ops.rs`, `packages/zanshin_core/lib/src/worker/handle.dart` docs (+ `cargo make codegen` if an extern doc changed) -- surface docs match.
- `crates/zanshin-jj/tests/bookmark_ops.rs` -- one test per I/O row (row/tracked state read via `list_bookmarks`; warnings via `take_warnings`; op head unchanged on the refusal) -- the item's witnesses.
- `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` -- created-only config + an existing untracked remote row: the envelope carries `jj.bookmark_auto_track_existing` -- the code crosses FFI.
- `crates/zanshin-parity/tests/oracle/{git_scenarios,main}.rs` -- scenarios `bookmark_create_auto_track_created` (REMOTE + `config set --repo remotes.origin.auto-track-created-bookmarks '"*"'`), `bookmark_create_auto_track_existing` (an untracked `feature@origin` present, e.g. git-pushed into the bare remote then `jj git fetch`, created-only config; both sides warn once), `bookmark_create_auto_track_broken` (pattern `(`; both refuse); each with a read-back that shows remote rows incl. tracked state; bump the count -- CLI comparison.
- `app/test/features/projects/worker_project_repos_test.dart` -- real-worker test (the one Story 9.54's review could not write): remotes `origin` and `upstream` added via `gitRemoteAdd`, repo-scope `remotes.<r>.auto-track-created-bookmarks = "*"` for the remote under test, `bookmarkCreate` on a clean `@`'s ancestry; `read()` is `ahead` when the tracked target-less row is on `origin` (the default push target) and clean when only `upstream` tracks it -- the dot's push-target rule end to end.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- at finalisation mark the `## Surfaced in Story 9.54` bullet resolved with the fix commit -- ledger hygiene.

**Acceptance Criteria:**
- Given every existing zanshin-jj, zanshin-ffi, zanshin_core, app and oracle test, when they run on the final tree, then each passes with no expected value changed.
- Given the new oracle scenarios, when the oracle runs, then each matches the pinned CLI (repo state, refusal, warning count, remote rows) with no new ledger row.
- Given `cargo make test` on the final tree (repo root, unpiped, synchronous), then it exits 0 and any raised `coverage-baseline.txt` is committed with the code.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

## Review Triage Log

## Design Notes

- **Base view, not the transaction's view:** the CLI checks `readonly_repo.view().get_remote_view(remote)` — the view before any write — both for "has a view" and for the warning. Because the guards already refused a tracked remote row, an existing row here is always untracked (or `@git`-style ignored), which is exactly when `track_remote_bookmark` merges a real remote target into the new local one.
- **Why the dot test now works:** with a remote view and `auto-track-created-bookmarks`, `bookmark create` leaves a tracked `name@origin` row whose target is absent — the "never pushed" state Story 9.54's `trackingStatusOf` reads as ahead only for push targets.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test bookmark_ops --test api_stability` and `cargo test -p zanshin-jj --lib -- config` -- expected: all pass.
- `cargo test -p zanshin-ffi --test bookmark_ops_ffi` -- expected: all pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: all pass, no new ledger row.
- `cargo make test` (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; the app's real-worker test runs inside it (it refuses outside the gate for the unpinned `XDG_CONFIG_HOME`).

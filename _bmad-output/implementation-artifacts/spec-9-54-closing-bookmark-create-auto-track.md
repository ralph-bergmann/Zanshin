---
title: 'Story 9.54 closing run — `bookmark create` auto-tracks on matching remotes'
type: 'bugfix'
created: '2026-10-20'
status: 'done'
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

### 2026-10-20 — Review pass
- verdicts: 18 findings — high 0, medium 0, low 14, false 4, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind 1) `packages/zanshin_core/lib/src/worker/isolate.dart` `ZanshinWorker.bookmarkCreate` still said "never auto-tracked (Story 9.11)" and lacked `jj.config_error` — doc reworded to match `handle.dart`, `jj.config_error` added.
  - `[low]` `[patch]` (blind 2) `docs/rust-error-codes.md` still listed "`bookmark create` auto-track" as not ported, and the `In remotes.<r>.*` diagnostics bullet did not name the new parse site — bullet removed; `parse_remote_auto_track_bookmarks_map_for_new_bookmarks` added to the re-check list.
  - `[low]` `[patch]` (blind 3) CLI citations off at v0.46.0 (warning `create.rs:104-108`, not `:101-106`; base repo `:92`; parse `:89-91`) — corrected in `warning.rs`, `bookmark_ops.rs`, the error-codes row and a test doc.
  - `[low]` `[reject]` (blind 4) `bookmark_ops.rs`'s module header mixes the v0.44.0 port pin with v0.46.0 citations — each new citation names its tag; re-pinning the header means re-verifying every older claim, beyond this item.
  - `[low]` `[reject]` (blind 5) the CLI's `revset_parse_error_hint` hints on a broken pattern are dropped — the same as the existing import-options parse of `auto-track-bookmarks` (pre-existing pattern, now one shared helper); carrying hints needs a new error field.
  - `[low]` `[reject]` (blind 6) with two broken remotes the reported one follows the stack's key order, not name order — the CLI's order is `HashMap`-unspecified there too; a second broken remote is a rare config typo and either report is CLI-consistent.
  - `[low]` `[patch]` (blind 7) the documented warning order (target-empty, then one auto-track warning per remote in name order) was untested — added `create_warns_target_empty_then_each_existing_remote_in_name_order` (`crates/zanshin-jj/tests/bookmark_ops.rs`), asserting the full ordered list. Same root as verification-gap 1.
  - `[low]` `[reject]` (blind 8) no FFI test sends a broken pattern or reads the tracked row through `zanshin_bookmarks` — both are witnessed at the `Repo` level and cross the one shared envelope/error mapping every verb uses (`MutateError::Config` → `jj.config_error`, `zanshin-ffi/src/repo.rs`); the FFI test proves the new code crosses.
  - `[low]` `[reject]` (blind 9) no real-cdylib `zanshin_core` round trip for the new warning code — the code crosses in the FFI test, the Dart registry test pins the constant, and the app real-worker tests drive `bookmarkCreate` through the worker.
  - `[low]` `[patch]` (blind 10) the oracle compared only `auto-track-created-bookmarks` — added `bookmark_create_auto_track_union` (both fields unioned on `origin`, `*` on `upstream`, a matching `ghost` without a view; `feature other third`); it matches the pinned CLI, pin 172.
  - `[false]` `[reject]` (blind 11) the ledger bullet keeps stale sub-bullets and no commit; sprint-status 9-54 still says the item was deferred — the ledger bullet is rewritten with the fix commit at finalisation (this spec's task); the sprint-status entry records Story 9.54's own run truthfully (it did defer the item), and no closing run (9.23, 9.48, 9.49, 9.51) edits sprint-status — the ledger is where the outcome lives.
  - `[false]` `[reject]` (edge 1) the deferred-work bullet cites no commit and keeps open follow-up text — mid-run state; finalisation writes the fix commit and closes the follow-up text.
  - `[false]` `[reject]` (edge 2) "no expected value changed" vs the edited registry counts (warning kinds 49→50, Dart codes 50→51, oracle scenarios 168→171) — those pins count registry entries the Tasks list adds; no behavioural expectation changed; the fix would edit this build's spec.
  - `[low]` `[patch]` (verification-gap 1) warning order across kinds unasserted — same as blind 7, patched there.
  - `[false]` `[reject]` (intent 1) no `## Auto Run Result` with a commit hash yet — mid-run state; finalisation writes it.
  - `[low]` `[reject]` (intent 2) the existing ledger bullet was annotated RESOLVED, which the intent did not ask for — the intent forbids re-mirroring, not resolving; every closing run marks its handed item resolved (ledger hygiene).
  - `[low]` `[reject]` (intent 3) not CLI-identical: name-ordered remotes, dropped hints, config read before the transaction — the order is a deliberate determinism choice for an unspecified CLI order; hints as blind 5; the refusal lands at the CLI's point (after the guards and the empty-target warning, nothing written), witnessed by `create_guards_refuse_before_a_broken_auto_track_pattern` and the oracle.
  - `[low]` `[reject]` (intent 4) the oracle compares warning counts and refusal, not the warning/error text, and `_existing` creates at the remote's own commit so the merge-conflict path is not CLI-compared — text comparison is outside the oracle's design (Story 9.47); the merge is jj-lib's `track_remote_bookmark`, the same function the CLI calls, and its conflicted result is asserted at the `Repo` level.

## Design Notes

- **Base view, not the transaction's view:** the CLI checks `readonly_repo.view().get_remote_view(remote)` — the view before any write — both for "has a view" and for the warning. Because the guards already refused a tracked remote row, an existing row here is always untracked (or `@git`-style ignored), which is exactly when `track_remote_bookmark` merges a real remote target into the new local one.
- **Why the dot test now works:** with a remote view and `auto-track-created-bookmarks`, `bookmark create` leaves a tracked `name@origin` row whose target is absent — the "never pushed" state Story 9.54's `trackingStatusOf` reads as ahead only for push targets.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test bookmark_ops --test api_stability` and `cargo test -p zanshin-jj --lib -- config` -- expected: all pass.
- `cargo test -p zanshin-ffi --test bookmark_ops_ffi` -- expected: all pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: all pass, no new ledger row.
- `cargo make test` (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; the app's real-worker test runs inside it (it refuses outside the gate for the unpinned `XDG_CONFIG_HOME`).

## Auto Run Result

Status: done (2026-10-20). Blocking condition: none.

**Items.**
- **Item 1 (`bookmark create` does not auto-track on remotes matched by `remotes.<name>.auto-track-bookmarks` / `auto-track-created-bookmarks`)** — fixed (182cf65; review patches 04f08ca). Verified real at `b162d61`: `bookmark_ops::create` only set the local target and its docs called the gap a deferral to Story 9.11; no product decision was needed (CLI parity, jj-lib's `track_remote_bookmark`). Now `create` runs the CLI's `create.rs:88-111` @ v0.46.0 in its order: guards → `jj.bookmark_target_empty` → parse every remote's union matcher (a broken value refuses `jj.config_error`, nothing written) → per name, set the target and track it on every matching remote that has a view in the pre-call view, warning `jj.bookmark_auto_track_existing` ("Auto-tracking bookmark that exists on the remote: name@remote") when that view already holds the name. The ledger's follow-up — a real-worker test of Story 9.54's push-target rule — landed too.

No new finding was deferred, so nothing new was mirrored into deferred-work.md; the item's own bullet there is marked RESOLVED with both commits.

**Summary.** `config::remote_auto_track_bookmarks_for_new_bookmarks` (union of both fields per remote, name-ordered) shares one per-field parser with the existing import-options matcher (behaviour unchanged); `bookmark_ops::create` tracks through jj-lib's `MutableRepo::track_remote_bookmark`; the new `WarningKind::BookmarkAutoTrackExisting` / `jj.bookmark_auto_track_existing` is wired through Rust, FFI, Dart and the registry docs. No FFI schema change.

**Files changed.**
- `crates/zanshin-jj/src/config.rs` — shared `parse_remote_string_expression` / `every_remote_settings`, `remote_auto_track_bookmarks_for_new_bookmarks`, two inline tests.
- `crates/zanshin-jj/src/bookmark_ops.rs` — the auto-track loop; module doc divergence removed; docs and `# Errors`.
- `crates/zanshin-jj/src/repo.rs` — `Repo::bookmark_create` doc.
- `crates/zanshin-jj/src/warning.rs`, `crates/zanshin-ffi/src/envelope.rs`, `packages/zanshin_core/lib/src/ffi/warning.dart` — the new warning kind/code.
- `crates/zanshin-ffi/src/bookmark_ops.rs`, `packages/zanshin_core/lib/src/worker/{handle,isolate}.dart`, regenerated `zanshin_ffi.h` / `bindings.dart` (doc comments only) — surface docs.
- `docs/rust-error-codes.md` — warning row; the "not ported" bullet removed; diagnostics re-check list extended.
- Tests: `crates/zanshin-jj/tests/bookmark_ops.rs` (8 auto-track tests; `XDG_CONFIG_HOME` pinned), `crates/zanshin-jj/tests/api_stability.rs` (registry 49 → 50), `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` (warning over the wire; `XDG_CONFIG_HOME` pinned), `packages/zanshin_core/test/ffi/warning_test.dart` (registry 50 → 51), `crates/zanshin-parity/tests/oracle/{git_scenarios,main,scenarios}.rs` (4 scenarios, 168 → 172), `app/test/features/projects/worker_project_repos_test.dart` (2 real-worker tests: ahead on `origin`, clean on `upstream`).
- `_bmad-output/implementation-artifacts/deferred-work.md` — the item's bullet resolved.

**Review.** 18 findings: high 0, medium 0, low 14, false 4, maybe-false 0 (triage log above).
- Patched (04f08ca, 5 entries, all low): stale `isolate.dart` doc (blind 1); stale "not ported" registry bullet + diagnostics re-check list (blind 2); v0.46.0 line citations (blind 3); ordered-warning witness (blind 7 / verification-gap 1); oracle `bookmark_create_auto_track_union` for the union, plain field, two remotes and a view-less remote (blind 10).
- Deferred: none.
- Rejected, reasons in the triage log: mixed pins in the module header (blind 4), dropped parse-error hints (blind 5, intent 3 — same as the pre-existing import parse), error order with two broken remotes (blind 6), FFI / `zanshin_core` copies of `Repo`-level witnesses (blind 8, 9), the unrequested ledger annotation (intent 2), oracle text / merge-path comparison (intent 4); false: ledger and sprint-status state mid-run (blind 11, edge 1), registry-count pins vs the AC wording (edge 2), missing Auto Run Result mid-run (intent 1).

**Follow-up review recommendation:** false — this first pass patched 0 high and 0 medium entries (patched counts: high 0, medium 0, low 5).

**Verification.**
- `cargo test -p zanshin-jj --test bookmark_ops --test api_stability`: 29 + 20 passed after the patches; `cargo test -p zanshin-jj --lib -- config`: 108 passed; `cargo test -p zanshin-ffi --test bookmark_ops_ffi`: 10 passed.
- `cargo test -p zanshin-parity --test oracle`: 180 passed before the patches, 181 after (172 scenarios), no ledger row.
- `cargo make test` (repo root, synchronous, unpiped to a log): exit 0 on 182cf65 (1012 s) and exit 0 after the review patches (916 s); the app's real-worker tests ran in `test-flutter`; coverage ratchet OK, `coverage-baseline.txt` unchanged (not lowered).
- Matrix audit: created-only — `create_auto_tracks_on_a_remote_with_a_view_under_the_created_only_config`; plain — `create_auto_tracks_only_the_names_the_plain_auto_track_matcher_accepts`; no match / no view — `create_tracks_nothing_when_the_matcher_rejects_or_the_remote_has_no_view`; two remotes — `create_auto_tracks_on_every_matching_remote`; existing — `create_auto_tracking_an_existing_remote_bookmark_warns_and_merges_its_target`; broken — `create_refuses_a_broken_auto_track_pattern_without_writing_an_operation`; guards first — `create_guards_refuse_before_a_broken_auto_track_pattern`; plus the oracle scenarios. All ran and passed.

**Residual risks.**
- A repo with `remotes.<r>.auto-track-created-bookmarks` (or `auto-track-bookmarks`) set and a remote view now gets tracked rows on create — as the CLI does; with Story 9.54's rule a never-pushed bookmark on a push-target remote now reads "ahead" in the project dot.
- A broken `auto-track-created-bookmarks` refuses `bookmark create` (it never refused before); the CLI's revset hint is not carried.

**Commits.** d12f677 (spec), 182cf65 (fix), 04f08ca (review patches), and the finalisation commit of this spec and deferred-work.md.

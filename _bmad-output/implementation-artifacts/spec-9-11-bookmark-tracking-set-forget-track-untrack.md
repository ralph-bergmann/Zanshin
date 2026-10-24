---
title: 'Story 9.11 — Bookmark tracking: `bookmark set`, `forget`, `track`, `untrack`'
type: 'feature'
created: '2026-10-24'
status: 'in-progress'
baseline_revision: 'd5f3b74ec43d687313507224721aeefadf02617c'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** zanshin-jj has no `jj bookmark set`, `forget`, `track` or `untrack`. A GUI therefore cannot create-or-move a bookmark by name, drop a bookmark together with its remote tracking, or start/stop tracking a remote bookmark — the remedies the registered codes `jj.bookmark_exists` / `jj.bookmark_tracked_remote_exists` already name, and the row action 9.29's untracked/tracked rows need.

**Approach:** Port `cmd_bookmark_set`, `cmd_bookmark_forget`, `cmd_bookmark_track` and `cmd_bookmark_untrack` (v0.46.0) over jj-lib, end to end (`.fbs` → zanshin-jj → `extern "C"` → committed codegen → `packages/zanshin_core`), on the 9.8/9.19 verb template (`bookmark_ops.rs`, `with_verb`/`with_checked_verb`, `finish_or_no_op_at`, `MutationResult`), with parity-oracle scenarios.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/bookmark/{set,forget,track,untrack,mod}.rs`, `cli/src/revset_util.rs:341-416`). It fixes the order of checks, refusal and warning texts (names via `as_symbol`, remote symbols via `RemoteRefSymbol`'s `Display`), the op descriptions and every repo effect. Each verb writes NO operation when its transaction has no change (`finish_or_no_op_at`; `new_op_id` = pre-call head).
- **set** (`set.rs:61-153`): `names` are DECODED names (as `create`'s); `revision: Option<ChangeId>` (`None` = `@`); `allow_backwards`.
  1. Clap, before the snapshot (`with_checked_verb`): empty `names` or an empty name → `jj.invalid_input`.
  2. Resolve the revision (as `create`).
  3. Per name in ARGUMENT order, fail-fast: a name is NEW when its local target is absent and it has no tracked remote (`has_tracked_remote_bookmarks`); without `allow_backwards`, `!is_fast_forward(old, target)` refuses "Refusing to move bookmark backwards or sideways: {name}" + hint "Use --allow-backwards to allow it." (`MutateError::invalid_hinted`).
  4. An `is_discardable` target warns `jj.bookmark_target_empty`.
  5. In the transaction: the auto-track matchers (`config::remote_auto_track_bookmarks_for_new_bookmarks`, refusal `jj.config_error` after the warning), then per name `RefTarget::normal(target)` and — NEW names only — `create`'s auto-track loop (warning `jj.bookmark_auto_track_existing`). Share that loop with `create`, do not copy it.
  6. Description `point bookmark {names} to commit {full hex}`, names in argument order.
- **forget** (`forget.rs:61-131`): `names` are PATTERNS passed through (bare = glob, as `delete`); `include_remotes`. Empty `names` → `jj.invalid_input` before the snapshot; a parse failure after it (`union_expression`'s refusal). Match `view.bookmarks()` (local OR remote rows) by name; warn unmatched exact names with no local and no remote row (`jj.bookmark_names_unmatched`, "No matching bookmarks for names: …"); nothing matched = no operation. Per matched name (view order): local → absent; per remote ref: with `include_remotes` set it `RemoteRef::absent()` (the `git` remote too); otherwise skip the default-ignored remote (`git` on a Git backend) and untrack. Description `forget bookmark {names}`, view order.
- **track / untrack** (`track.rs:76-148`, `untrack.rs:69-142`, `mod.rs:117-162`, `:204-243`): `names` are `BOOKMARK[@REMOTE]` TEXTS passed through and parsed like `parse_name_patterns_or_remote_symbols` (`revset::parse_program`; an `ExpressionKind::RemoteSymbol` is a symbol, anything else goes through `revset::expect_string_expression`); `remotes: Vec<String>` are remote-name PATTERNS (empty = `--remote` not given). Order:
  1. Clap: empty `names` → `jj.invalid_input`, before the snapshot.
  2. After the snapshot: parse failure → `jj.invalid_input` (reason `failed to parse name pattern or remote symbol: {kind}[: {source chain}]`, house rendering); patterns AND symbols → "Cannot specify both <bookmark> patterns and <bookmark>@<remote> symbols"; `remotes` with symbols → "--remote cannot be used with <bookmark>@<remote> symbols" (both `jj.invalid_input`).
  3. Symbols: `resolve_trackable_remote_bookmarks` (trackable when the remote ref is present, or the local is present and the remote view exists; sorted + deduped); unmatched warn "No matching remote bookmarks for names: …".
  4. Patterns: `ignored` = `git` on a Git backend only if its remote view exists; remote expression = `remotes` unioned (`union_expression`), else `~exact:git` when `ignored`, else all; matches = `trackable_remote_bookmarks_matching` (jj-lib `remote_bookmarks_matching` chained with every matching remote view's missing local names as `ABSENT_REMOTE_REF`); warn unmatched names (local-or-remote rule, `jj.bookmark_names_unmatched`) then unmatched exact remotes ("No matching remotes for names: …").
  5. track: a tracked ref warns "Remote bookmark already tracked: {symbol}", others are tracked (`track_remote_bookmark`); description `track remote bookmark {symbols}`. untrack: the ignored remote warns "Git-tracking bookmark cannot be untracked: {symbol}", an untracked one "Remote bookmark not tracked yet: {symbol}", others are untracked; description `untrack remote bookmark {symbols}`. Symbols joined `", "` in match order.
- Five NEW warning codes, messages verbatim: `jj.remote_bookmarks_unmatched`, `jj.bookmark_remotes_unmatched`, `jj.bookmark_already_tracked`, `jj.bookmark_not_tracked`, `jj.bookmark_git_tracking_untrack`. No new error code.

**Never:** no terminal chatter ("Created/Moved N bookmarks…", "No bookmarks to forget.", "Forgot N local/remote bookmarks.", "Started/Stopped tracking N remote bookmarks.", track's post-finish conflicted-bookmark listing — re-read via `list_bookmarks`); no parse-error hints (`revset_parse_error_hint`, house precedent of `delete`); no MCP; no UI code; never regenerate fixtures; no full gate (`cargo make test` / `test-full` / `coverage`) — this run's gate rule.

## I/O & Edge-Case Matrix

Shorthand: oracle `BASE` = root → A → B (`b-mark`) → C = `@`; remote states built in-test (`set_remote_bookmark`, or a local bare remote + push in git scenarios).

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| set new | `names=[new]`, `revision=B` | `new` → B; op `point bookmark new to commit <B>` | — |
| set forward / no-op | `b-mark` to C; `b-mark` to B | moves; second writes no operation | — |
| set backwards | `b-mark` to A | refused, head unchanged | `jj.invalid_input` + hint |
| set backwards allowed | same, `allow_backwards` | `b-mark` → A | — |
| set resurrect | local absent, tracked `x@origin` | local `x` set, no auto-track | — |
| set auto-track | `remotes.origin.auto-track-created-bookmarks="*"`, new name, origin has a view | tracked on origin | warns `jj.bookmark_auto_track_existing` when the name exists there |
| set empty target / clap | empty commit; `names=[]` or `[""]` | moves + warns; clap refusals before snapshot | `jj.bookmark_target_empty`; `jj.invalid_input` |
| forget | `b-mark`; pattern `glob:"b-*"` | local gone; tracked remotes untracked; op `forget bookmark b-mark` | — |
| forget include_remotes | tracked `x@origin` | local and remote rows gone | — |
| forget remote-only / nothing | untracked `y@origin` only; `nope` | `y` matched (untrack no-op → no op); `nope` no op | `jj.bookmark_names_unmatched` for `nope` |
| track symbol | untracked `y@origin` | tracked; op `track remote bookmark y@origin` | — |
| track pattern / absent | `names=[x]`, local `x`, origin view lacks `x` | `x@origin` tracked (not created yet) | — |
| track already / unmatched | tracked ref; `nope@origin`; `--remote nope` | no operation | `jj.bookmark_already_tracked` / `jj.remote_bookmarks_unmatched` / `jj.bookmark_remotes_unmatched` |
| untrack | tracked `x@origin`; untracked; `x@git` | untracked; others warn, no op | `jj.bookmark_not_tracked` / `jj.bookmark_git_tracking_untrack` |
| track/untrack bad args | patterns + symbols; `remotes` + symbol; bad pattern | refused after snapshot | `jj.invalid_input` |

</intent-contract>

## Code Map

CLI anchors @ `v0.46.0`; jj-lib vendored at `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0` (`revset_parser.rs:468` `parse_program`, `revset.rs:1351` `expect_string_expression`, `view.rs:92` `bookmarks`, `:195` `local_bookmarks_matching`, `:254` `remote_bookmarks_matching`, `:366` `remote_views_matching`; `jj-core-0.46.0/src/op_store.rs:61` `ABSENT_REMOTE_REF`). CLI tests to mirror: `cli/tests/test_bookmark_command.rs` `test_bookmark_forget_glob` `:1100`, `_fetched_bookmark` `:1371`, `_deleted_or_nonexistent` `:1517`, `_untracked_remote_only` `:1578`, `test_bookmark_track_untrack` `:1629`, `_patterns` `:1924`, `_bad_args` `:2085`, `test_bookmark_track_absent` `:2138`, `test_create_and_set_auto_track_*` `:3208-3358`; `set` cases inside `test_bookmark_move` `:247` and `test_bookmark_create` region.

**zanshin-jj**
- `src/bookmark_ops.rs` — template verbs: `create` `:224` (one head load, auto-track loop `:286-306` → extract a shared helper used by `create` and `set`), `delete` `:338` (pattern verb template), `validate_names` `:83` (clap arity; its message names `create` — parameterize the verb), `has_tracked_remote_bookmarks` `:102`, `ignored_remote_matcher` `:118` (add an `Option<&RemoteName>` sibling for the CLI's `default_ignored_remote_name`), `describe_pattern_parse_error` `:138` / `union_expression` `:153` (parameterize the message head for track's "name pattern or remote symbol"), `join_symbols` `:180`, `check_move_args` `:540` / `check_rename_args` `:709` (clap checks template), `is_fast_forward` `:897`. Module doc `:1-62` gains a Story 9.11 section. New verbs `set`, `forget`, `track`, `untrack` + `check_*_args` here.
- `src/bookmarks.rs:443` `warn_unmatched` — the local-or-remote unmatched-name warning (reuse for forget/track/untrack; make `pub(crate)` if needed).
- `src/config.rs:1564` `remote_auto_track_bookmarks_for_new_bookmarks`.
- `src/warning.rs` — `WarningKind` (bookmark variants `:78-104`); five new variants citing the CLI lines.
- `src/repo.rs` — facades next to `bookmark_create` `:2568` … `bookmark_rename` `:2704` (`with_verb` `:491`, `with_checked_verb` `:504`); doc blocks with `# Errors`. Update the stale "Story 9.11's" references in `bookmark_delete`'s doc `:2591`. `src/lib.rs` re-exports if a public type is added (none planned).

**Wire + FFI**
- `schemas/envelope.fbs` — `RequestKind` `:94-151` (append `BookmarkSet`, `BookmarkForget`, `BookmarkTrack`, `BookmarkUntrack` after `Movement`); new tables after `BookmarkRenameRequest` `:922`: `BookmarkSetRequest { kind, names: [string], revision: string, allow_backwards: bool }`, `BookmarkForgetRequest { kind, names: [string], include_remotes: bool }`, `BookmarkTrackRequest { kind, names, remotes: [string] }` (shared by track/untrack; `kind` tells them apart). Docs in the 9.19 style.
- `crates/zanshin-ffi/src/bookmark_ops.rs` — readers `:63-190` and externs `:236-470` as templates (`strings` `:96`); four externs `zanshin_bookmark_set` / `_forget` / `_track` / `_untrack`. `src/envelope.rs` — warning consts (`~:268` block), `warning_code()` arms (`:431` area), literal tables (`~:1622`, `~:1700`). `src/repo.rs` `map_mutate_err` (no change expected).
- Generated via `cargo make codegen` only: `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` — symbol index + request-buffer counts + bookmark section (94 → 98 exports); guard `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS` 94 → 98. `docs/rust-error-codes.md` — five warning rows (§ Warning Codes, beside the bookmark rows) + "Also emitted — Story 9.11" clauses on `jj.bookmark_target_empty`, `jj.bookmark_names_unmatched`, `jj.bookmark_auto_track_existing`; fix the "(both Story 9.11)" remedy note on `jj.bookmark_tracked_remote_exists` to say they now exist.

**Dart (`packages/zanshin_core`)**
- `lib/src/ffi/bookmark_ops.dart` (builders), `lib/src/ffi/warning.dart` (`ZanshinWarningCode` consts `~:120`, `values` `~:323`), `lib/src/worker/commands.dart` (`BookmarkMoveCommand` `:1411` … `BookmarkRenameCommand` `:1469` templates), `lib/src/worker/isolate.dart` (`bookmarkMove` `:2730` … `bookmarkRename` `:2789` + dispatch arms), `lib/src/worker/handle.dart` (`bookmarkMove` `:2059` … `bookmarkRename` `:2111`), barrel `lib/zanshin_core.dart`.

**Tests**
- `crates/zanshin-jj/tests/it/` — new module `bookmark_tracking.rs` (declare in `main.rs`); helpers from `bookmark_ops.rs`/`bookmark_move.rs` (`oracle_workspace`, `head_op`); `crates/test-helpers/src/lib.rs` `set_local_bookmark` `:603`, `set_remote_bookmark` `:629`; `api_stability.rs` (bookmark surface pin, `WarningKind` lists, header count).
- `crates/zanshin-ffi/tests/it/bookmark_ops_ffi.rs`; `packages/zanshin_core/test/{ffi,worker}/bookmark_ops_test.dart`, `test/ffi/warning_test.dart`, `test/worker/warnings_test.dart`.
- Oracle: `crates/zanshin-parity/tests/oracle/scenarios.rs` (`bookmark_move_scenarios` `:2989` template), `git_scenarios.rs` (`bookmark_auto_track_scenarios` `:859`, `bookmark_rename_tracked_scenarios` `:969` — remote setup idiom), `main.rs` `parity!` list.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/warning.rs` -- five `WarningKind` variants with rustdoc citing `mod.rs:136-143` (remote symbols), `mod.rs:229-243` (remotes), `track.rs:119-124`, `untrack.rs:113-125` -- the warnings ride the call's list.
- `crates/zanshin-jj/src/bookmark_ops.rs` -- `set`, `forget`, `track`, `untrack` (one `track_or_untrack` core is fine) + `check_set_args` / `check_names_given`; shared auto-track helper used by `create`; parameterized parse-error head; `default_ignored_remote`; module doc section (divergences: decoded set names, pass-through patterns/symbols, dropped chatter and hints); inline unit tests for the new pure helpers (name/symbol split, mixed-syntax refusals, message heads).
- `crates/zanshin-jj/src/repo.rs` -- `bookmark_set(&[String], Option<&ChangeId>, bool)`, `bookmark_forget(&[String], bool)`, `bookmark_track(&[String], &[String])`, `bookmark_untrack(&[String], &[String])` → `Result<MutationResult, MutateError>`, clap checks via `with_checked_verb`; house doc blocks.
- `schemas/envelope.fbs` + `cargo make codegen` -- the four kinds and three tables; commit generated files.
- `crates/zanshin-ffi/src/{bookmark_ops,envelope}.rs` -- readers (absent vector = empty, wrong kind refused), the four externs with full rustdoc, warning consts + `warning_code` arms + literal tables.
- `packages/zanshin_core` lib -- builders, commands, worker methods, dispatch arms, NUL guards, `RepoHandle.bookmarkSet(names, {revision, allowBackwards})`, `bookmarkForget(names, {includeRemotes})`, `bookmarkTrack(names, {remotes})`, `bookmarkUntrack(names, {remotes})`; five `ZanshinWarningCode`s; barrel.
- `crates/zanshin-jj/tests/it/bookmark_tracking.rs` -- every matrix row against jj-lib state (targets, `is_tracked`, remote rows), refusals keep the head, warnings in CLI order, no-ops return the pre-call head, clap refusals leave no precondition, set/create share auto-track; `api_stability.rs` pins.
- `crates/zanshin-ffi/tests/it/bookmark_ops_ffi.rs` -- readers (absent vs present, malformed, wrong kind), zero handle per extern, one success and one refusal envelope, a warning code across the envelope, each request field observably crossing (`revision`, `allow_backwards`, `include_remotes`, `remotes`).
- `packages/zanshin_core/test/{ffi,worker}/bookmark_ops_test.dart`, `test/ffi/warning_test.dart` -- wire shape + NUL guards; real-cdylib round trip per new extern (success + one refusal), each named argument changing the outcome.
- `crates/zanshin-parity/tests/oracle/{scenarios,git_scenarios,main}.rs` -- set (new, forward, no-op, backwards refused/allowed, empty target, auto-track created), forget (local, glob, include_remotes, untracked-remote-only, nothing), track (symbol, pattern, absent remote, already tracked, `--remote`), untrack (tracked, not tracked, `@git`), bad-arg refusals.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- per the Code Map.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- flip `9-11-bookmark-tracking-set-forget-track-untrack` to `done` with a sibling-style summary (bump `last_updated`); `## Surfaced in Story 9.11 (bmad-build-auto, 2026-10-24)` mirroring every `deferred:` entry.

**Acceptance Criteria:**
- Given the four verbs, when a Dart caller reaches them, then the whole chain exists and `ffi_abi_doc_sync` passes with 98 exports.
- Given every oracle scenario, when the oracle runs, then each matches the pinned CLI or diverges only through a ledgered entry with reason and reference.
- Given any refusal or no-op, when the op head is compared before and after, then it is unchanged and `new_op_id` equals the pre-call head.
- Given a name in the `jj.bookmark_tracked_remote_exists` state, when `bookmark_set` recreates it or `bookmark_untrack` disassociates it, then a following `bookmark_create` of that name behaves as the CLI does (refused after `set` with `jj.bookmark_exists`, succeeds after `untrack`).

## Spec Change Log

## Review Triage Log

## Design Notes

- **Two name currencies, as the CLI has them.** `set` takes decoded names (its clap parser is `parse_bookmark_name`, revset quoting is terminal syntax — 9.8's create rule). `forget`, `track`, `untrack` take the CLI's pattern texts unchanged (FR-JJ-17, 9.8's delete rule; the epic line says "pattern matching"); for track/untrack that includes the `name@remote` symbol syntax, so a GUI tracking one row sends the symbol text `name@origin` (revset-quoting a name or remote that needs it, e.g. `"a b"@origin` — jj-lib's `format_remote_symbol` renders it). The 9.19 exact-name rule is move/advance's alone.
- **CLI order across the snapshot.** Only clap's own checks (required names, set's empty name) refuse before the snapshot; forget/track/untrack parse their patterns inside the command body, after `workspace_helper`, so their parse and mixed-syntax refusals follow the snapshot.
- **No-op detection is the finish's.** The CLI's `tx.finish` writes nothing for an unchanged view (forget of an untracked-remote-only bookmark, track of only already-tracked refs, set to the current target); `finish_or_no_op_at` gives the same answer.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`; targeted checks only.

**Commands:**
- `cargo make codegen` -- expected: generated files committed; a second run leaves the tree unchanged.
- `cargo test -p zanshin-jj --lib`; `cargo test -p zanshin-jj --test it -- bookmark_tracking:: bookmark_ops:: bookmark_move:: bookmarks:: api_stability:: warnings::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib`; `cargo test -p zanshin-ffi --test it -- bookmark_ops_ffi:: ffi_abi_doc_sync::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p test-helpers --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed lib test`, `dart test` on the touched test files (real cdylib, test env as in 9.19) -- expected: pass/clean.

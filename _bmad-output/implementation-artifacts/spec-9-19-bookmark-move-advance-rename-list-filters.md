---
title: 'Story 9.19: `bookmark move` / `advance` / `rename` + `bookmark list` filters'
type: 'feature'
created: '2026-10-23'
status: 'done'
baseline_revision: '6862f48fde062a78bebbac4fb210f6e84c16a948'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [multiple-goals, oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** zanshin-jj has no `jj bookmark move`, `advance` or `rename`, and `list_bookmarks` returns only the fixed `--all-remotes` row set. The floating client's bookmark drop (10.10) and bookmark popover (10.15) need move/rename, and 9.31's `plan_bookmark_move` has no verb calling it yet. Deferred-work I1 (section "Surfaced in Story 9.31 (bmad-build-auto, 2026-10-21)", the fast-forward bullet's remainder) asks for a test of the move WRITE on a conflicted bookmark.

**Approach:** Port `cmd_bookmark_move`, `cmd_bookmark_advance`, `cmd_bookmark_rename` and the filter/sort half of `cmd_bookmark_list` (v0.46.0) over jj-lib, end to end (`.fbs` → zanshin-jj → `extern "C"` → `zanshin_core`). The move and advance verbs decide fast-forward per bookmark through `plan_bookmark_move`, so `drop_actions`' bookmark row and the verb agree by construction. `list_bookmarks` takes the CLI's list arguments as typed options and returns typed rows in the CLI's order, which replaces the CLI's template output.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/bookmark/{move,advance,rename,list,mod}.rs`, `cli/src/commit_ref_list.rs`). It fixes the order of checks, the refusal texts (CLI text verbatim, names via `RefName::as_symbol`), the op descriptions, and every repo effect.
  - The op descriptions are `point bookmark {names} to commit {full hex}`, with names joined by `", "` in view order, and `rename bookmark {old} to {new}`.
- **Move and advance address bookmarks by EXACT name.** This is the epic's 2026-10-14 design decision and is equivalent to the CLI's `exact:` pattern. The names become a union of `StringExpression::exact`. An exact name that matches no local bookmark warns `jj.bookmark_names_unmatched`. `--from` takes REVSET strings (as `GitPushArgs::revisions` does); they are parsed with diagnostics under "In revset expression" and unioned. `--to` is an optional change id; absent means `@` for move and `revsets.bookmark-advance-to` for advance (a revset resolved to exactly one commit, as `push.rs::resolve_single` does).
- Move checks run in this order:
  1. Refuse clap's "at least one of names/from" as `jj.invalid_input`.
  2. Resolve `to`.
  3. Evaluate `from`.
  4. Match local bookmarks: name matcher AND any present add in `from`.
  5. Record the unmatched warning.
  6. Drop the no-ops (`plan_bookmark_move` = `NoOp`).
  7. If nothing is left, this is the "No bookmarks to update." no-op: no operation, and `new_op_id` is the pre-call head.
  8. Without `allow_backwards`, the first `Backwards` in view order refuses "Refusing to move bookmark backwards or sideways: {name}" with hint "Use --allow-backwards to allow it." (`MutateError::invalid_hinted`).
  9. If the target `is_discardable`, warn `jj.bookmark_target_empty`.
  10. Write `RefTarget::normal(target)` for each matched bookmark. A conflicted bookmark therefore becomes normal (I1).
- Advance follows the same steps with these differences:
  - Without names, the candidates are all local bookmarks with a present add in `revsets.bookmark-advance-from`. That revset is parsed with the local `to` = the target's commit hex, and its diagnostics go under "In revsets.bookmark-advance-from". In this case there is no unmatched warning.
  - With names, it uses the exact names and ignores the from revset.
  - There is no `allow_backwards`. The refusal is "Refusing to advance bookmark backwards or sideways: {name}" with no hint.
  - When `to` is absent, every parse or resolution error of the default target carries the hint "`revsets.bookmark-advance-to` controls the default target. You can also specify a specific target with `--to`." To carry it, `MutateError::RevsetParseError` / `RevsetResolutionError` gain `hints: Vec<String>`, returned by `hints()`. Every existing construction site passes `vec![]`.
- Rename works on decoded names, like `create`. An empty name refuses `jj.invalid_input`.
  - The checks run in this order:
    1. "No such bookmark: {old}" as `jj.invalid_input`.
    2. Without `overwrite_existing`, a present `new` refuses `MutateError::BookmarkExists { name: new, hints: [] }`. This means `old == new` without overwrite refuses, as in the CLI.
    3. `old == new` returns the no-op.
  - Then rename writes as the CLI does: untrack the overwritten name's tracked remotes, move the target, absent the old name, and transfer tracking per remote.
  - The remote matcher excludes `git` on a Git backend. Share one helper with `has_tracked_remote_bookmarks`.
  - Rename's four `ui.warning_*` lines become NEW warning codes, each with its message verbatim. Their hints are dropped (house rule, `repo.rs:430`):
    - `jj.bookmark_rename_remote_exists`: "The renamed bookmark already exists on the remote '{remote}', tracking state was dropped."
    - `jj.bookmark_tracking_dropped`: "Tracking of remote bookmark {new}@{remote} was dropped."
    - `jj.bookmark_remotes_not_renamed`: "Tracked remote bookmarks for bookmark {old} were not renamed.", recorded after the finish.
    - `jj.bookmark_tracked_remotes_exist`: "Tracked remote bookmarks for bookmark {new} exist.", recorded after the finish.
- List options are named after the CLI arguments. An empty vec means the argument was not given, because clap's `Option<Vec>` is never `Some(empty)`.
  - The fields are `names` (string PATTERNS, passed through like `bookmark_delete`'s), `revisions` (revsets), `remotes` (patterns), `all_remotes`, `tracked`, `conflicted`, and `sort` (`BookmarkSortKey`; empty means `ui.bookmark-list-sort-keys`, parsed like `parse_sort_keys`, with an error going to `jj.config_error`).
  - `all_remotes` combined with `remotes`, `tracked` or `conflicted` refuses `jj.invalid_input`.
  - Port `RefFilterPredicates`, `collect_items` and `sort` exactly, including the CLI's row ORDER: each primary is followed by its tracked rows, then come the untracked remote items. Each row keeps 9.29's facts.
  - An exact name pattern that matches no local or remote bookmark warns `jj.bookmark_names_unmatched`.
  - `BookmarkError` gains `InvalidInput { reason }`, `RevsetParseError { reason }`, `RevsetResolutionError { reason }` and `Config(ConfigError)`. These map to `jj.invalid_input` / `jj.revset_parse_error` / `jj.revset_resolution_error` / `jj.config_error`.
- Every verb runs through `Repo::with_verb` (snapshot and warnings), returns `MutationResult` (move/advance/rename) and reuses registered error codes. The only new codes are the four warning codes above.
- `zanshin_bookmarks` becomes `(handle, data, len)` with a `BookmarkListRequest` (a breaking WIP edit in place). Its only app caller (`app/lib/src/features/projects/worker_project_repos.dart:109`) passes `allRemotes: true`, so the project-status behaviour is unchanged.

**Never:**
- No `-T` template rendering. Terminal chatter is not ported: "Moved/Advanced N bookmarks to …", "No bookmarks to update." as text, the success hints "Specify bookmark by name to update just one of the bookmarks.", and list's conflict/deleted hints, which can be derived from the rows. Record each in the module docs.
- No glob/pattern names for move or advance. No remote bookmarks moved (local only, `move.rs:107`). No change to `drop_actions`' rows or outcomes.
- No UI code beyond the one-line app call-site adaptation. No MCP. Never regenerate fixtures. Never lower the coverage baseline. No full gate (`cargo make test` / `test-full` / `coverage`) — this run's gate rule.

## I/O & Edge-Case Matrix

Fixture shorthand: `BASE` = root → A → B (`b-mark`) → C = `@` (oracle `BASE`); jj-level tests build their own graphs through `test_helpers::set_local_bookmark` / `set_remote_bookmark`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Move forward | `names=[b-mark]`, `to=C` | b-mark → C; op `point bookmark b-mark to commit <C hex>` | — |
| Move backwards | `names=[b-mark]`, `to=A` | refused, head unchanged | `jj.invalid_input` + hint |
| Move backwards allowed | same, `allow_backwards` | b-mark → A | — |
| Move `--from` | `from=["B"]` (revset text), `to=C`; two bookmarks on B, one elsewhere | both on B move, names in view order in the description | — |
| Move no-op / unknown name | `to=B`; or `names=[nope]` | no operation, `new_op_id` = pre-call head; unknown name also warns | `jj.bookmark_names_unmatched` |
| Move no source | `names=[]`, `from=[]` | refused before resolution | `jj.invalid_input` |
| Move empty target | `to` = an empty undescribed commit | moves, warns | `jj.bookmark_target_empty` |
| **I1** conflicted → descendant | `mark` conflicted (adds B, D), `to=C` (child of B) | `mark` becomes NORMAL at C (`RefTarget::normal`) | — |
| Advance default | no names, no `to`; b-mark on B, `@`=C | b-mark → C | — |
| Advance names / backwards | `names=[b-mark]`, `to=A` | refused "Refusing to advance bookmark backwards or sideways: b-mark" (no hint) | `jj.invalid_input` |
| Advance bad default `to` | `revsets.bookmark-advance-to = "none()"` | refused, error hints carry the config hint | `jj.revset_resolution_error` |
| Rename | `b-mark` → `renamed` | target kept, old absent; op `rename bookmark b-mark to renamed` | — |
| Rename refusals | old missing; new exists (no overwrite); `old == new` without overwrite | refused | `jj.invalid_input` / `jj.bookmark_exists` |
| Rename same name, overwrite | `old == new`, `overwrite_existing` | no operation | — |
| Rename tracked | `feature` tracked on `origin` (present) | `renamed@origin` tracked if absent there; warns `jj.bookmark_remotes_not_renamed` | — |
| List default | no options | CLI default rows: no synced tracked rows, no untracked rows | — |
| List filters | `tracked`; `conflicted`; `remotes=[origin]`; `names=["glob:f*"]`; `revisions=["B"]`; `sort=[AuthorDateDesc]` | the CLI's predicate result and order | `jj.invalid_input` for `all_remotes`+`tracked`; bad revset → `jj.revset_*`; bad sort config → `jj.config_error` |

</intent-contract>

## Code Map

CLI anchors @ `v0.46.0` (`git -C ../jj show v0.46.0:<path>`); jj-lib vendored at `~/.cargo/registry/src/*/jj-lib-0.46.0`; Zanshin at baseline `6862f48`.

**Prior art (read-only)**
- `cli/src/commands/bookmark/move.rs:84-179` — matching, retain no-ops, backwards refusal `:123-137`, empty-target `:139-141`, description `:164-176`.
- `cli/src/commands/bookmark/advance.rs:75-199` — `to` default + hint `:79-101`, from revset with `to` local `:119-145`, refusal `:157-169`.
- `cli/src/commands/bookmark/rename.rs:49-201` — the whole verb.
- `cli/src/commands/bookmark/list.rs:135-213` — name/revision/remote expressions, predicates, sort keys; `mod.rs:204-226` `warn_unmatched_local_or_remote_bookmarks`.
- `cli/src/commit_ref_list.rs` — `RefFilterPredicates`, `collect_items`, `SortKey` + `parse_sort_keys`, `sort`/`sort_inner`; its unit tests are worth porting for the sort.
- `cli/src/cli_util.rs:1889-1903` `parse_union_revsets`; `cli/src/config/{revsets,misc}.toml` (`bookmark-advance-to = "@"`, `bookmark-advance-from = "heads(::to & bookmarks())"`, `bookmark-list-sort-keys = ["name"]` — already on the stack via `CLI_DEFAULTS`, `crates/zanshin-jj/src/config.rs:266-271`).
- CLI tests to mirror: `cli/tests/test_bookmark_command.rs` `test_bookmark_move` `:247`, `_matching` `:387`, `_conflicting` `:530`, `test_bookmark_rename` `:596`, `_overwrite` `:700`, `test_bookmark_list_filtered` `:2513`, `_tracked` `:2858`, `_conflicted` `:3061`, `_sort_*` `:3096-3174`, `test_bookmark_advance_default` `:3428`.

**zanshin-jj**
- `src/bookmark_ops.rs` — `union_expression` `:127` (make it return a plain `String` reason, or wrap per caller), `has_tracked_remote_bookmarks` `:83` (extract the ignored-remote matcher), `join_symbols` `:148`, `create` `:196` (verb template: one head load, `finish_or_no_op_at`), `plan_bookmark_move` `:381` + `is_fast_forward` `:400` (doc names this story as the caller — update). The three new verbs go here.
- `src/bookmarks.rs` — `list_bookmarks` `:111`, `Lister::push_rows`/`remote_row` (keep the row facts, restructure into CLI items + predicates + sort), `BookmarkError` `:82`.
- `src/mutate.rs` — `MutateError` `:127-397` (`RevsetParseError`/`RevsetResolutionError` gain `hints`; `hints()` `:492`; its test `hints_follow_the_variant` `:2042`), `invalid_hinted` `~:481`, `rev` `:534`, `res` `:550`, `finish_or_no_op_at` `:1549`.
- `src/push.rs:986-998` `resolve_single` (refusal texts for a revset that resolves to 0 or more than 1 commits), `:742` `collect_ids`, `:1119-1145` config revset + locals.
- `src/revset.rs` — `revset_config` `:249`, `parse_revset_with` `~:296`, `parse_diagnosed_with` `:327`, `evaluate_revset` `~:518`, `IN_REVSET_EXPRESSION` `:285`.
- `src/config.rs` — typed readers next to `revsets_git_push` `:1709` (`revsets_bookmark_advance_to`, `revsets_bookmark_advance_from`, `ui_bookmark_list_sort_keys` → `ConfigError::Load` via `value_error` `:340`).
- `src/warning.rs` — `WarningKind` `:32` (bookmark variants `:78-85`; add four, rustdoc citing `rename.rs` lines).
- `src/op_support.rs` — `resolve_or_wc`; `src/drop_actions.rs:456-479` (calls `plan_bookmark_move`, must stay unchanged).
- `src/repo.rs` — `list_bookmarks` `:620-638`, `bookmark_create`/`delete` `:2222-2312` (facade + doc template); `src/lib.rs` re-exports.

**Wire + FFI**
- `schemas/envelope.fbs` — `RequestKind` `:94` (append `BookmarkList`, `BookmarkMove`, `BookmarkAdvance`, `BookmarkRename`); request tables after `BookmarkDeleteRequest` `:759`; `Bookmark`/`Bookmarks` docs `:1093-1123` (row order/default set change); new `enum BookmarkSortKey : ubyte { Unspecified, Name, NameDesc, AuthorName, AuthorNameDesc, AuthorEmail, AuthorEmailDesc, AuthorDate, AuthorDateDesc, CommitterName, CommitterNameDesc, CommitterEmail, CommitterEmailDesc, CommitterDate, CommitterDateDesc }` (reader refuses `Unspecified`). Field names `old_name`/`new_name` for rename (`new` is a Dart keyword).
- `crates/zanshin-ffi/src/bookmark_ops.rs` — readers `:63-100` + externs `:153-215` as templates; `src/bookmarks.rs` `zanshin_bookmarks` `:111-123`, `map_bookmarks_err` `:20-30` (new arms like `graph.rs:36` `map_topology_err`); `src/repo.rs:167` `map_mutate_err` (hints now also on revset variants); `src/envelope.rs` warning consts `~:268`, `warning_code()` `:369`, literal tables `~:1503`, `~:1573`.
- Generated via `cargo make codegen` only: `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` — symbol index `:538-606` (81 → 84 exports; `zanshin_bookmarks` row), request-buffer counts `:285-288`, Bookmarks section `:1529-1557`; guard `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` (`EXPECTED_EXPORTS` 81 → 84). `docs/rust-error-codes.md` — four warning rows (§ Warning Codes, bookmark rows `:137-139`) + "also emitted — Story 9.19" clauses.

**Dart (`packages/zanshin_core`)**
- `lib/src/ffi/bookmark_ops.dart` (builders `:41-67`), `lib/src/ffi/bookmarks.dart` (`zanshinBookmarks` `:22`, models + decoder `:31-170`; add `BookmarkSortKey`), `lib/src/ffi/warning.dart` (`ZanshinWarningCode` consts `~:97`, `values` `~:283`), `lib/src/worker/commands.dart` (`BookmarksCommand` `:150`, `BookmarkCreateCommand` `:1170` templates), `isolate.dart` (`bookmarks` `:935`, `bookmarkCreate` `:2378`, dispatch `:2937`, `:3704`), `handle.dart` (`bookmarks()` `:290`, `bookmarkCreate` `:1692`), barrel `lib/zanshin_core.dart`.
- App caller: `app/lib/src/features/projects/worker_project_repos.dart:109`.

**Tests**
- `crates/zanshin-jj/tests/it/bookmark_ops.rs` (helpers `oracle_workspace` `:35`, `head_op` `:103`, `remote_rows` `:644`), `tests/it/bookmarks.rs`, `tests/it/drop_actions.rs:858-905` (`commit_id`, `conflict_mark` — the conflicted-bookmark recipe), `tests/it/main.rs`, `tests/it/api_stability.rs` (`bookmark_ops_surface_resolves` `:905`, `list_bookmarks` pin `:1475`, `WarningKind` array/match `~:1590-1729`, header count `:12-22`). Every `repo.list_bookmarks()` test caller (`bookmarks`, `bookmark_ops`, `convert`, `snapshot_precondition`, `git_sync`, `mutate`, `git_fetch_parity`, `remotes_write`) changes to pass options.
- `crates/test-helpers/src/lib.rs` `set_local_bookmark` `:603` (several targets = conflicted), `set_remote_bookmark` `:629`.
- `crates/zanshin-ffi/tests/it/bookmark_ops_ffi.rs` (refusal-ladder tests `:482-639`), `bookmarks_ffi.rs`.
- `packages/zanshin_core/test/{ffi,worker}/bookmark_ops_test.dart`, `{ffi,worker}/bookmarks_test.dart`, `test/ffi/warning_test.dart`.
- Oracle: `crates/zanshin-parity/tests/oracle/scenarios.rs` (`BASE` `:33`, `simple` `~:86`, bookmark scenarios `:741-910`), `git_scenarios.rs` (`push` setup idiom `:370`, `bookmark_auto_track_scenarios` `:859`), `main.rs` `parity!` list `:54-79`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` + every construction/match site -- add `hints: Vec<String>` to `RevsetParseError` / `RevsetResolutionError`, return them from `hints()`, extend `hints_follow_the_variant` -- advance's default-target hint needs an error carrier.
- `crates/zanshin-jj/src/config.rs` -- three typed readers (two strings, one sort-key array → `Vec<BookmarkSortKey>` with the CLI's key spellings `name`, `name-`, `author-name`, …) + inline tests (default values, bad type, unknown key).
- `crates/zanshin-jj/src/warning.rs` -- four `WarningKind` variants citing `rename.rs` @ v0.46.0.
- `crates/zanshin-jj/src/bookmark_ops.rs` -- public `BookmarkMoveOptions { names, from: Vec<String>, to: Option<ChangeId>, allow_backwards }`; `pub(crate) fn r#move`, `advance(names, to)`, `rename(old, new, overwrite_existing)` per the Always rules; shared ignored-remote matcher; module doc (divergences: exact names, dropped success hints/chatter, dropped warning hints); update `plan_bookmark_move`'s doc; inline tests for pure helpers.
- `crates/zanshin-jj/src/bookmarks.rs` -- public `BookmarkListOptions` (Default = CLI defaults) and `BookmarkSortKey`; `list_bookmarks(workspace, ctx, &options)` porting predicates, `collect_items` order, the unmatched warning and `sort` (+ the CLI's sort unit tests ported inline); new `BookmarkError` variants; module doc.
- `crates/zanshin-jj/src/repo.rs` + `src/lib.rs` -- facades `bookmark_move(&BookmarkMoveOptions)`, `bookmark_advance(&[String], Option<&ChangeId>)`, `bookmark_rename(&str, &str, bool)` → `Result<MutationResult, MutateError>`; `list_bookmarks(&BookmarkListOptions)`; house doc blocks with `# Errors`; re-exports.
- `schemas/envelope.fbs` + `cargo make codegen` -- the four `RequestKind`s; `BookmarkListRequest { kind, names, revisions, remotes: [string], all_remotes, tracked, conflicted: bool, sort: [BookmarkSortKey] }`, `BookmarkMoveRequest { kind, names, from: [string], to: string, allow_backwards: bool }`, `BookmarkAdvanceRequest { kind, names: [string], to: string }`, `BookmarkRenameRequest { kind, old_name, new_name: string, overwrite_existing: bool }`; updated `Bookmark(s)` docs; commit generated files.
- `crates/zanshin-ffi/src/{bookmark_ops,bookmarks,envelope,repo}.rs` -- readers + `zanshin_bookmark_move` / `_advance` / `_rename`; `zanshin_bookmarks(handle, data, len)`; `map_bookmarks_err` arms; four warning consts + `warning_code` arms + literal tables; full rustdoc.
- `packages/zanshin_core` lib -- `BookmarkSortKey` enum, builders, `RepoHandle.bookmarks({names, revisions, remotes, allRemotes, tracked, conflicted, sort})` (defaults = the CLI's), `bookmarkMove(names, {from, to, allowBackwards})`, `bookmarkAdvance({names, to})`, `bookmarkRename(oldName, newName, {overwriteExisting})`; commands, worker methods, dispatch arms, NUL guards; four `ZanshinWarningCode`s; barrel.
- `app/lib/src/features/projects/worker_project_repos.dart` -- `handle.bookmarks(allRemotes: true)` (plus any fake implementing `RepoHandle.bookmarks` in `app/test`).
- `crates/zanshin-jj/tests/it/bookmark_move.rs` (new, declared in `main.rs`) -- every move/advance/rename matrix row against jj-lib state, incl. **I1** (conflicted `mark` adds B,D → `to` = child of B → `mark` is `RefTarget::normal`), `--from` with names AND from, refusals keep the head, warnings in order, rename tracking transfer + all four warnings, and agreement: for each `drop_actions` bookmark row (Available / NoOp / backwards) the verb writes / no-ops / refuses accordingly.
- `crates/zanshin-jj/tests/it/bookmarks.rs` -- filter matrix (default set, `tracked` incl. `@git` excluded, `conflicted`, `remotes`, name patterns OR revisions, unmatched warning, clap refusal, sort keys from argument and config, bad config → `Config`, CLI row order with tracked and untracked remotes); update other test files' calls.
- `crates/zanshin-jj/tests/it/api_stability.rs` -- new types and methods pinned, `WarningKind` lists, `list_bookmarks` pin, header count.
- `crates/zanshin-ffi/tests/it/bookmark_ops_ffi.rs` + `bookmarks_ffi.rs` -- readers (absent vs present, malformed, wrong kind, `Unspecified` sort key), zero handle for the three new externs, a refusal envelope with hints, success envelopes, list request with a filter.
- `packages/zanshin_core/test/{ffi,worker}/bookmark_ops_test.dart`, `{ffi,worker}/bookmarks_test.dart`, `test/ffi/warning_test.dart` -- synthetic wire shape + NUL guards; real-cdylib round trips for each new extern and the changed `zanshin_bookmarks` (one success each, one refusal, one list filter that changes the row set).
- `crates/zanshin-parity/tests/oracle/{scenarios,git_scenarios,main}.rs` -- scenarios: move forward, backwards refused, backwards allowed, `--from`, no-op, unknown name, empty target; advance default, advance named, advance backwards refused; rename, rename onto existing refused, rename overwrite, rename missing, rename same name (refused / overwrite no-op), rename of a tracked pushed bookmark (git setup).
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- per the Code Map.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- flip `9-19-bookmark-thick-move-advance-rename-list-filters` to `done` with a sibling-style summary (bump `last_updated`); mark the I1 remainder resolved with the commit; add `## Surfaced in Story 9.19 (bmad-build-auto, 2026-10-23)` mirroring every `deferred:` entry.

**Acceptance Criteria:**
- Given the three verbs and the filtered list exist, when a Dart caller reaches them, then the whole chain is present and `ffi_abi_doc_sync` passes with 84 exports.
- Given every oracle scenario above, when the oracle runs, then each matches the pinned CLI or diverges only through a ledgered entry with reason and reference.
- Given a `drop_actions` bookmark row on a head, when the move verb runs that move (with `allow_backwards` exactly when the row needed it), then it writes an operation exactly when the row said Available, and refuses with the backwards refusal when the row needed `allow_backwards` and the verb runs without it.
- Given I1's conflicted bookmark, when it is moved to a descendant of one side, then the stored target is normal at the new commit (zanshin-jj test), and deferred-work marks the remainder resolved.
- Given any refusal or no-op, when the op head is compared before and after, then it is unchanged and `new_op_id` equals the pre-call head.
- Given the project-status read in `app`, when it lists bookmarks, then it still receives the `--all-remotes` row set.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 23 findings — high 0, medium 3, low 17, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) the CLI row order (local, its tracked rows, then untracked items) has no witness; a fixture with an untracked remote sorting before a tracked one is missing — fixed: `bookmarks_are_sorted_by_name_then_kind` rewritten as the CLI-order witness (`foo`, `foo@origin` tracked, `foo@aaa` untracked).
  - `[low]` `[patch]` (blind) `bookmarks_are_sorted_by_name_then_kind` still asserts 9.29's replaced `(name, remote)` order — same fix as the row above.
  - `[low]` `[patch]` (blind) rename's empty-name refusal runs after the pre-verb snapshot (the CLI refuses in clap, before `workspace_helper`) — fixed: `check_rename_args` through `with_checked_verb`, with a dirty-working-copy test.
  - `[low]` `[reject]` (blind) `check_move_args`' text is not clap's "the following required arguments were not provided" — clap's rendering is terminal UX; house style names the flags (`squash_split.rs`, rebase's clap rows, rejected the same way in 9.16's review); the code `jj.invalid_input` is what the UI switches on.
  - `[low]` `[patch]` (blind) rename's exclusion of the `git` remote is untested — fixed: a tracked `feature@git` in a rename test, no tracking moved, no warning.
  - `[low]` `[patch]` (blind) advance paths untested (explicit bad `to` without hint, a custom `bookmark-advance-from` using `to`, names ignoring a broken from revset, the diagnostic label) — fixed: tests added (see Verification).
  - `[low]` `[patch]` (blind) the FFI round trip never checks that the refused rename left the head unchanged — fixed: head captured after the seed and compared.
  - `[low]` `[patch]` (blind) the oracle lacks list scenarios, a conflicted move, `--from` with names, a custom advance-from and a colocated `@git` rename — fixed in part: `--from` + names, custom advance-from and the conflicted (I1) move scenarios added; list scenarios rejected — the oracle compares repo state, a read's rows need hand audit (epic 9 context, "Reads … need hand audit"), and the jj-level filter matrix mirrors the CLI's list tests; the `@git` rename is covered by the jj-level test above.
  - `[low]` `[patch]` (blind) the drop_actions agreement test never uses a conflicted bookmark, and the I1 RESOLVED note overstates it — fixed: the loop also runs a conflicted `mark` (B, D); the note cites the write test as the I1 witness.
  - `[low]` `[reject]` (blind) rename's dropped warning hints lose remedies — the house rule (warnings carry code + message only, `repo.rs:430`, Story 9.32) applies to every ported warning; the affected remotes are in the list rows (9.29), which the UI re-reads after a mutation.
  - `[low]` `[patch]` (blind) the "absent vector is empty" reader exists twice in `zanshin-ffi` — fixed: one `pub(crate)` helper.
  - `[low]` `[patch]` (blind) the Dart API takes `bookmarkMove`'s names positionally but `bookmarkAdvance`'s by name, and the `names`/`remotes` NUL guards of `bookmarks()` are untested — fixed in part: the guard tests added; the API shape rejected — `bookmarkMove(names, …)` follows `bookmarkCreate`/`bookmarkDelete`, while advance's names are optional by the CLI's own shape.
  - `[low]` `[patch]` (blind) no test carries a new rename warning code across FFI or into Dart — fixed: FFI and worker round trips assert `jj.bookmark_remotes_not_renamed`.
  - `[low]` `[patch]` (edge) rename's empty-name refusal after the snapshot — same as the blind row.
  - `[low]` `[reject]` (edge) `with_advance_hint` hints only parse/resolution errors, while the CLI hints any `resolve_single_rev` error — the other variants are a jj-lib backend failure during evaluation (`MutateError::Backend`, which has no hints) or a config failure raised before the CLI's `resolve_single_rev`; nobody meets the backend case, and hinting it needs a new field on `Backend`.
  - `[medium]` `[patch]` (edge) the project-status read now depends on `ui.bookmark-list-sort-keys` (a malformed knob fails it with `jj.config_error`, the order follows the knob) — fixed: `worker_project_repos.dart` passes `sort: [BookmarkSortKey.name]` with `allRemotes: true`.
  - `[low]` `[patch]` (edge, claim) a rename refusal can write a snapshot operation — same as the blind empty-name row.
  - `[low]` `[patch]` (edge, claim) the status read's order follows the user's sort config — same as the medium row above.
  - `[medium]` `[patch]` (verification-gap) move `from`, advance `names`/`to` and rename `overwrite_existing` never observably cross the FFI/Dart wire — fixed: FFI and worker round trips whose outcomes differ by each field.
  - `[medium]` `[patch]` (verification-gap) list `revisions`/`remotes`/`conflicted` never cross the wire — fixed: one FFI and one worker request each whose rows differ from the default.
  - `[false]` `[reject]` (intent) I1 is tested at the Rust API only (no oracle/FFI) — the intent asks for a test of the move verb's WRITE, which `a_conflicted_bookmark_moved_to_a_descendant_of_one_side_becomes_normal` is; an oracle scenario was added anyway (blind oracle row).
  - `[false]` `[reject]` (intent) no commit hash / Auto Run Result yet — written at finalisation, when the commit exists.
  - `[false]` `[reject]` (intent) the list default changed and the app was adapted — that is the intent's reading A1 (the CLI's flags with the CLI's defaults); the app keeps its `--all-remotes` rows, so nothing regresses.

## Design Notes

- **Exact names for move/advance.** `names=["a*"]` moves only a bookmark literally named `a*` (the CLI's `jj bookmark move 'exact:"a*"'`). That answers the epic's 2026-10-14 rule. A name pattern would be a hidden glob default the GUI never wants.
- **One fast-forward rule.** The verb calls `plan_bookmark_move(repo, name, target)` per matched bookmark: `NoOp` is excluded (that is the CLI's retain), and `Backwards` refuses unless allowed. `drop_actions` calls the same fn, so a row and a run cannot disagree.
- **List order is the CLI's, not 9.29's.** The rows are flattened from `collect_items`' items (each primary, then its tracked remote rows), followed by the untracked remote items. So `foo`, `foo@origin` (tracked), `foo@aaa` (untracked) stays in that order. 9.29's name/local/remote sort would put `foo@aaa` second.
- **Hints dropped on success.** The data in each dropped hint is already in the result, so nothing is lost:
  - Rename's per-warning hints follow the house rule (warnings carry code + message).
  - Move/advance's "Specify bookmark by name…" only advises a CLI user typing `--from`. The GUI names what it moves, and `MutationResult` has no hints list.
  - List's two hints can be derived from the rows (a conflicted local row; a deleted local row with tracked remotes).

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`; targeted checks only.

**Commands:**
- `cargo make codegen` -- expected: regenerated files committed; a second run leaves the tree unchanged.
- `cargo test -p zanshin-jj --lib` and `cargo test -p zanshin-jj --test it -- bookmark_move:: bookmarks:: bookmark_ops:: drop_actions:: api_stability:: mutate:: convert:: snapshot_precondition:: git_sync:: git_fetch_parity:: remotes_write:: push::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it -- bookmark_ops_ffi:: bookmarks_ffi:: ffi_abi_doc_sync:: repo_write_ffi::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p test-helpers --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed lib test`, `dart test` on the touched test files -- expected: pass/clean.
- `app`: `dart analyze`, `dart format --set-exit-if-changed lib test`, `flutter test test/src/features/projects` (or the files that use `bookmarks`) -- expected: pass/clean.

**Outcomes (2026-10-23, final tree after the review patches; full gate not run per the run's gate rule):**
- `cargo make codegen` -- exit 0; a second run left the tree unchanged.
- `cargo fmt --all --check` -- clean. `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p test-helpers --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --lib` -- 337 passed. `cargo test -p zanshin-jj --test it -- bookmark_move:: bookmarks:: bookmark_ops:: drop_actions:: api_stability:: mutate:: convert:: snapshot_precondition:: git_sync:: git_fetch_parity:: remotes_write:: push:: clone_init:: arg_refusals::` -- 362 passed.
- `cargo test -p zanshin-ffi --lib` -- 205 passed. `cargo test -p zanshin-ffi --test it -- bookmark_ops_ffi:: bookmarks_ffi:: ffi_abi_doc_sync:: repo_write_ffi:: snapshot_ffi::` -- 92 passed.
- `cargo test -p zanshin-parity --test oracle` -- 300 passed (20 new Story 9.19 scenarios, no ledger entry).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed .` -- 0 changed; `dart test test/ffi/{bookmark_ops,bookmarks,warning}_test.dart test/worker/{bookmark_ops,bookmarks,warnings}_test.dart` (test-core env) -- 235 passed (real cdylib).
- `app`: `dart analyze` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed; `flutter test test/features/projects` with the gate's pinned env (JJ_*, GIT_CONFIG_GLOBAL, XDG_CONFIG_HOME) -- 194 passed. Without that env five real-worker tests fail on identity/config, as on the baseline; the gate pins it.
- Not run (gate rule): `cargo make test`, `test-full`, `coverage` -- the story loop runs the gate once at its end.

## Auto Run Result

Status: done

**Summary.** `jj bookmark move`, `advance` and `rename` and the filter/sort half of `jj bookmark list` are ported from the CLI at v0.46.0 end to end (`.fbs` → zanshin-jj → `zanshin_bookmark_move` / `_advance` / `_rename` and the request-taking `zanshin_bookmarks` → `RepoHandle.bookmarkMove` / `bookmarkAdvance` / `bookmarkRename` / `bookmarks({…})`, 84 exports). Move and advance address bookmarks by exact name, decide fast-forward through `plan_bookmark_move` (shared with `drop_actions`, agreement pinned for plain and conflicted bookmarks), refuse backwards moves with the CLI's text (move's hint "Use --allow-backwards to allow it."), write no operation for "No bookmarks to update.", warn an empty target, and write a normal target. Advance's default target comes from `revsets.bookmark-advance-to` and carries the CLI's hint on a parse/resolution failure (`MutateError::RevsetParseError`/`RevsetResolutionError` gained `hints`); its candidates come from `revsets.bookmark-advance-from` with `to` bound. Rename follows the CLI's refusals and tracking transfer, leaves `git` out, and emits four new warning codes (`jj.bookmark_rename_remote_exists`, `jj.bookmark_tracking_dropped`, `jj.bookmark_remotes_not_renamed`, `jj.bookmark_tracked_remotes_exist`). `list_bookmarks(&BookmarkListOptions)` takes names/revisions/remotes/all_remotes/tracked/conflicted/sort with the CLI's defaults and returns rows in the CLI's order; clap-level refusals (move without source, rename with an empty name, list's `--all-remotes` conflicts) run before the pre-verb snapshot. The app's project status passes `allRemotes: true, sort: [name]`, so it is unchanged.

**Items handed to this story.**
- **I1** (a conflicted bookmark moved to a descendant of one side becomes normal — the move verb's WRITE needs its own test) — **fixed** (a23ba38): `crates/zanshin-jj/tests/it/bookmark_move.rs::a_conflicted_bookmark_moved_to_a_descendant_of_one_side_becomes_normal` conflicts `mark` (adds B, D), runs `Repo::bookmark_move` onto C (a child of B) and pins `RefTarget::normal(C)`; an "all sides" regression refuses and fails it. Also witnessed against the pinned CLI by oracle scenario `bookmark_move_conflicted_to_descendant` (matches), and `the_verb_agrees_with_every_drop_actions_bookmark_row` runs the conflicted bookmark through row/verb agreement. Marked resolved in deferred-work.md with the commit.

**Files changed (a23ba38).**
- `crates/zanshin-jj/src/bookmark_ops.rs` — the three verbs, `BookmarkMoveOptions`, clap checks, shared ignored-remote matcher.
- `crates/zanshin-jj/src/bookmarks.rs` — `BookmarkListOptions`, `BookmarkSortKey`, predicates/`collect_items`/sort port, new `BookmarkError` variants.
- `crates/zanshin-jj/src/{repo,lib,mutate,config,revset,push,warning,drop_actions}.rs` — facades, re-exports, revset-error hints, config readers, `parse_union_diagnosed`, shared `single_commit`, four warning kinds, doc.
- `schemas/envelope.fbs` + generated files — four request kinds/tables, `BookmarkSortKey`.
- `crates/zanshin-ffi/src/{bookmark_ops,bookmarks,envelope,repo}.rs` — readers, three externs, the request-taking `zanshin_bookmarks`, error/warning codes.
- `packages/zanshin_core/lib/…` — builders, models, commands, worker methods, `RepoHandle` methods, warning codes.
- `app/lib/src/features/projects/worker_project_repos.dart` (+ its test) — explicit `allRemotes: true, sort: [name]`.
- Tests: `crates/zanshin-jj/tests/it/{bookmark_move (new),bookmarks,api_stability,…}.rs`, `crates/zanshin-ffi/tests/it/{bookmark_ops_ffi,bookmarks_ffi,…}.rs`, `packages/zanshin_core/test/{ffi,worker}/{bookmark_ops,bookmarks}_test.dart`, `test/ffi/warning_test.dart`, oracle `scenarios.rs`/`git_scenarios.rs`/`main.rs` (20 scenarios).
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`.
- Ledger (finalisation commit): this spec, `sprint-status.yaml` (9-19 done), `deferred-work.md` (I1 resolved).

**Review findings.** 23 findings (medium 3, low 17, false 3). Patched (in a23ba38): the project-status read depending on the user's sort knob (medium), move/advance/rename arguments and list `revisions`/`remotes`/`conflicted` across the FFI/Dart wire (medium ×2), rename's empty-name refusal before the snapshot, the CLI row-order witness replacing 9.29's order test, rename's `git` exclusion test, advance-path tests, the refused-rename head check over FFI, oracle scenarios (`--from` + names, custom advance-from, conflicted move), conflicted agreement, the duplicated FFI vector reader, `bookmarks()` NUL-guard tests, a rename warning code across FFI and Dart (low). Nothing deferred. Rejected: clap's own required-group text (terminal UX; house style names the flags, as 9.16), list scenarios in the oracle (it compares repo state; reads need hand audit), rename's dropped warning hints (house rule: warnings carry code + message), the Dart `bookmarkMove` positional names (follows `bookmarkCreate`/`Delete`), the advance hint on backend failures (unreachable in practice, needs a field on `Backend`), and three descriptive intent rows (I1 surface, commit hash written here, list default = the CLI's).

**Follow-up review recommendation: true.** Patched at entry verdict: high 0, medium 3, low 12. Unverified risk: the per-file coverage ratchet — `bookmark_ops.rs`, `bookmarks.rs`, `mutate.rs`, `config.rs` and the FFI modules sit at 100% in the baseline, and the new defensive arms (e.g. `sort_key`'s unknown-byte arm, `with_advance_hint`'s non-revset pass-through, `rev`'s backend arm in `bookmarks.rs`) are unmeasured until the story loop's final gate.

**Residual risks.** Coverage ratchet not run (gate rule). `bookmark list` filters and order are compared with the CLI only through jj-level tests mirroring the CLI's list tests (the oracle compares repo state, not read output). The app's real-worker project tests need the gate's pinned environment, as before.

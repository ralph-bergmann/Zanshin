---
title: 'Story 9.59 — Tag verbs (`tag set`/`delete`/`track`/`untrack`) and the tag list through the FFI'
type: 'feature'
created: '2026-11-15'
status: 'done'
baseline_revision: 'b9ea558d45e9e7e6acaaa52000d1621da4169f4a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      A bad name pattern refuses with Zanshin's own text and no hint, unlike the CLI.
    evidence: |-
      describe_pattern_parse_error says "failed to parse name pattern…" (lowercase, source appended) and drops the hint; the CLI says "Failed to parse name pattern: {kind}" with Caused by lines and revset_parse_error_hint (cli/src/revset_util.rs:336-339 @ v0.47.0). Pre-existing in the bookmark verbs; tag delete/track/untrack inherit it.
    location: >-
      crates/zanshin-jj/src/bookmark_ops.rs:177
    severity: medium
    resolved: >-
      2026-11-16 — fixed (spec-9-59-closing-name-pattern-error-text, commit d8b4c8b4): every caller of the shared helpers refuses with the CLI's text, Caused by lines and hint; oracle witnesses in hints.rs and scenario tag_delete_bad_pattern.
  - summary: >-
      The shared bookmark and list helpers still cite the CLI at v0.46.0.
    evidence: |-
      bookmark_ops.rs (:154, :176, :186, :200) and bookmarks.rs (:277, :348, :398) cite v0.46.0 line numbers; at v0.47.0 parse_union_name_patterns starts at revset_util.rs:323. Pre-existing; behavior was not found to differ.
    location: >-
      crates/zanshin-jj/src/bookmark_ops.rs, crates/zanshin-jj/src/bookmarks.rs
    severity: low
    resolved: >-
      2026-11-16 — fixed (spec-9-59-closing-name-pattern-error-text, commit d8b4c8b4): every CLI citation in bookmark_ops.rs and bookmarks.rs re-read and re-cited at v0.47.0.
---

<intent-contract>

## Intent

**Problem:** Zanshin reads tags but cannot change them: there is no tag verb in Rust, the FFI or Dart, and `Repo::list_tags` (local + tracked remote tags only) has no FFI wrapper. Stories 10.44–10.47 (bookmark and tag views, pickers, search actions) need both.

**Approach:** Port `jj tag set`, `delete`, `track`, `untrack` at v0.47.0 (`cli/src/commands/tag/{mod,set,delete,track,untrack}.rs`) as `Repo` verbs in the shape of the bookmark verbs (Stories 9.8/9.11), rework `Repo::list_tags` into the rows `jj tag list --all-remotes` prints minus `@git` rows, and carry all five through the FFI (append-only schema, externs, codegen, `docs/ffi-abi.md`) into `packages/zanshin_core` (`RepoHandle` methods + worker commands), with parity-oracle scenarios per verb and refusal.

## Boundaries & Constraints

**Always:**
- CLI observable behavior at v0.47.0: argument order, refusals and their order, warnings with the CLI's text, op descriptions byte-identical (`set tag {names} to commit {hex}`, `delete tag {names}`, `track remote tag {symbols}`, `untrack remote tag {symbols}`; names via `RefName::as_symbol()`, joined `", "`).
- `set`: DECODED names (as `bookmark set`; `parse_tag_name` = `parse_symbol`, so only an empty name or an empty list is refused, before the snapshot). `revision` absent = `-r` default `@`, present = a change id. Per name in argument order, fail-fast: a present local tag without `allow_move` refuses `jj.invalid_input` "Refusing to move tag: {name}" with hint "Use --allow-move to update existing tags." — no write. Then an empty, undescribed target warns "Target revision is empty.". Every name gets a NORMAL target. No auto-tracking (the CLI has none for tags).
- `delete`: pass-through string patterns (a bare one is a GLOB), unioned; empty list refused before the snapshot; exact names with no local tag warn "No matching tags for names: …"; matching nothing writes no operation. The local tag becomes absent; a tracked `name@remote` stays (the "deleted" state a push sends).
- `track`/`untrack`: `TAG[@REMOTE]` texts and `--remote` patterns, exactly as `bookmark track`/`untrack` (Story 9.11) but over tags: mixed patterns + symbols and `--remote` with symbols refuse `jj.invalid_input` with the CLI's `<tag>` wording; default remote filter excludes `git` on a Git-backed repo where `git` has a view; warnings "No matching remote tags for names: …", "No matching tags for names: …", "No matching remotes for names: …", "Remote tag already tracked: {symbol}", "Git-tracking tag cannot be untracked: {symbol}", "Remote tag not tracked yet: {symbol}". Untracking `name@git` therefore WARNS and writes nothing — that is the CLI's "refusal".
- A verb that changes nothing writes no operation and returns the pre-call head (`finish_or_no_op_at`).
- Each verb takes its own `cli_command` entry (`tag set`, `tag delete`, `tag track`, `tag untrack`) and its line in `repo.rs`'s `every_verb_resolves_for_its_cli_command`.
- New warning codes, one per CLI warning, each registered in `docs/rust-error-codes.md` § Warning Codes and mirrored in `packages/zanshin_core/lib/src/ffi/warning.dart`: `jj.tag_target_empty`, `jj.tag_names_unmatched`, `jj.remote_tags_unmatched`, `jj.tag_remotes_unmatched`, `jj.tag_already_tracked`, `jj.tag_git_tracking_untrack`, `jj.tag_not_tracked`. No new error code.
- Tag list = `cmd_tag_list` with `--all-remotes` and no other argument: rows via the bookmark list's `collect_items` over `view.tags()` (each local row, then its tracked remote rows, then the name's untracked remote rows, in name order), sorted by `ui.tag-list-sort-keys` (default `["name"]`), then every row whose remote is the default-ignored one (`git` on a Git-backed repo) dropped. Each row: name, target change id (`None` when absent), `conflicted`, `synced`, and on a remote row `remote_name` + `tracked`. No ahead/behind.
- Tests: `zanshin-jj` integration tests in `tests/it/` (one module, e.g. `tag_ops.rs`, declared in `main.rs`; `pin_test_env()` first), FFI tests in `crates/zanshin-ffi/tests/it/`, a real-cdylib `packages/zanshin_core` worker test per new extern fn (coverage attributes extern fns only through it), Dart wire-shape tests for the request builders and the `Tags` decoder.

**Never:** UI (10.44–10.47); pushing tags (exists, 9.20); a `tag forget` (jj 0.47 has none); list filters/`-T`/`--sort` arguments (the list is fixed to `--all-remotes`); MCP tools; touching fixtures; running the full gate (`cargo make test`/`test-full`/`coverage`) in this loop run.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| set new on @ | `tag_set(["v1"], None, false)` | `v1` → `@`; op `set tag v1 to commit <hex>` | — |
| set on -r | `tag_set(["v1"], Some(B), false)` | `v1` → B | — |
| set existing, no flag | `v1` exists, `tag_set(["v2","v1"], …, false)` | nothing written, `v2` not created | `jj.invalid_input` + hint |
| set existing, allow_move | same with `true` | `v1` moved | — |
| set same target | `v1` already at target | no operation, pre-call head returned | — |
| set empty target | target empty + undescribed | written | warning `jj.tag_target_empty` |
| set bad args | `[]` or `[""]` | nothing | `jj.invalid_input` before snapshot |
| delete glob | `["v1.*"]` with `v1.0`,`v1.1`,`v2` | `v1.0`,`v1.1` gone; op `delete tag v1.0, v1.1` | — |
| delete tracked | `v1` pushed + tracked on origin | local absent; `v1@origin` row stays, tracked | — |
| delete unmatched | `["nope"]` | no op | warning `jj.tag_names_unmatched` |
| track/untrack | `v1@origin` untracked / tracked | tracking flips; op `track/untrack remote tag v1@origin` | — |
| untrack @git | `["v1@git"]` | no op | warning `jj.tag_git_tracking_untrack` |
| mixed syntax | `["v1", "v2@origin"]` | nothing | `jj.invalid_input` "Cannot specify both <tag> patterns and <tag>@<remote> symbols" |
| list | local `v1` + `v1@origin` tracked + `v2@origin` untracked + `@git` rows | `v1` Local, `v1@origin` Remote tracked, `v2@origin` Remote untracked; no `@git` row | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/bookmark_ops.rs` -- the template. `set` (965), `delete` (397), `track_or_untrack` (1220) + helpers `parse_names_or_symbols` (1098), `refuse_mixed_syntax` (1117, its messages say `<bookmark>`: give it the noun), `union_expression` (191), `default_ignored_remote` (157), `describe_pattern_parse_error` (176), `join_symbols` (218), `check_names_given` (933, message says "bookmark {verb}"). Make the shared helpers `pub(crate)` and parametrize the noun rather than copy them; keep bookmark behavior and messages byte-identical.
- `crates/zanshin-jj/src/tag_ops.rs` (new) -- `set`, `delete`, `track_or_untrack` for tags + the tag-side `resolve_trackable` / `trackable_matching` / `warn_unmatched*` (jj-lib's tag accessors: `get_local_tag`, `get_remote_tag`, `local_tags_matching`, `remote_tags_matching`, `remote_views_matching`, `remote_view.tags`, `MutableRepo::{set_local_tag_target, track_remote_tag (async → pollster), untrack_remote_tag}`); argument checks for `with_checked_verb`.
- `crates/zanshin-jj/src/bookmarks.rs` -- `Predicates`/`Include`/`Item`/`Primary`/`collect_items` (277-394) and `sort` (398) to reuse for the tag list (make `pub(crate)`; `sort` returns `BookmarkError` — give it an error type both callers can map).
- `crates/zanshin-jj/src/config.rs:1852` -- `ui_bookmark_list_sort_keys`; add `ui_tag_list_sort_keys` sharing `parse_sort_keys`. CLI default `["name"]` comes from `CLI_DEFAULTS` (`config.rs:268`, jj-cli's `misc.toml:49`). Remote tags that `git push -t` records or `git fetch` imports are tracked (jj-lib `git.rs:1172`, `:1579`).
- `crates/zanshin-jj/src/view.rs` -- `Tag`/`TagKind`/`list_tags` reworked to the new row shape; `ViewError` gains `Config(ConfigError)` for the sort keys.
- `crates/zanshin-jj/src/repo.rs` -- `list_tags` (826) doc + body; new `tag_set`/`tag_delete`/`tag_track`/`tag_untrack` beside `bookmark_set` (3314)…`bookmark_untrack` (3410) via `with_checked_verb`; `every_verb_resolves_for_its_cli_command` (~5488).
- `crates/zanshin-jj/src/cli_command.rs` -- add `TAG_SET`, `TAG_DELETE`, `TAG_TRACK`, `TAG_UNTRACK` (the clap audit test checks them).
- `crates/zanshin-jj/src/warning.rs` + `src/lib.rs` -- new `WarningKind`s with codes; module + re-exports.
- `crates/zanshin-jj/tests/it/view.rs`, `git_fetch_parity.rs:209-217`, `clone_init.rs`, `api_stability.rs:566` -- callers of the old `Tag` shape to update (fetch parity filters tracked rows: `TagKind::Remote { remote_name, tracked: true }`).
- `schemas/envelope.fbs` -- append `TagSet`, `TagDelete`, `TagTrack`, `TagUntrack` to `RequestKind` (ends ~line 238); new `TagSetRequest {kind, names, revision, allow_move}`, `TagDeleteRequest {kind, names}`, `TagTrackRequest {kind, names, remotes}` (one table, kind tells track from untrack, as `BookmarkTrackRequest` 1236); `enum TagKind : byte { Local, Remote }`, `table Tag {name, target, kind, remote_name, conflicted, synced, tracked}`, `table Tags {tags}`; append `Tags` to `union Payload` (3339). Then `cargo make codegen` (Rust + Dart generated files, header, bindings).
- `crates/zanshin-ffi/src/bookmark_ops.rs` + `bookmarks.rs` -- templates for a new `crates/zanshin-ffi/src/tags.rs`: request readers, `zanshin_tag_set`/`_delete`/`_track`/`_untrack` (→ `map_mutate_err`, `ok_mutation_result`) and handle-only `zanshin_tags(handle)` (template: `remotes.rs:105` `zanshin_remotes`) with a `ViewError` mapper (Precondition → `map_precondition_err`, Config → `jj.config_error`, Backend → `jj.jj_lib_error`). Register the module in `lib.rs`.
- `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` -- `EXPECTED_EXPORTS` 116 → 121.
- `docs/ffi-abi.md` -- symbol rows (template rows ~648, ~701), a `Tags` payload section like § `Bookmarks` payload (1744), prose export counts.
- `docs/rust-error-codes.md` -- § Warning Codes (98) rows for the seven new codes; emitter lists of `jj.invalid_input` etc.
- `packages/zanshin_core/lib/src/ffi/bookmark_ops.dart`, `bookmarks.dart` -- templates for `ffi/tags.dart` (request builders + adapters with `rejectInteriorNul(s)`, `Tag`/`TagKind` model + `Tags` envelope decoder).
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- `BookmarkTrackCommand` (commands 1710), dispatch (isolate 5305), `RepoHandle.bookmarkTrack` (handle 2713): add tag commands + `RepoHandle.tags()`, `tagSet`, `tagDelete`, `tagTrack`, `tagUntrack`; export from `lib/zanshin_core.dart`.
- `packages/zanshin_core/test/ffi/bookmark_ops_test.dart`, `test/worker/bookmark_ops_test.dart`, `test/worker/bookmarks_test.dart` -- templates for the Dart tests.
- `crates/zanshin-parity/tests/oracle/git_scenarios.rs` -- `push()` (419), `PUSHED`/`ORIGIN` setups, `bookmark_tracking_scenarios` (1066), `push_read_back` (389): add `tag_scenarios()` with a `tag_read_back` (`jj tag list --all-remotes -T <bookmark template>` + the bare remote's refs) — state aspects do not cover tags; register the scenarios in `tests/oracle/main.rs` (see the bookmark list at ~309-332).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/bookmark_ops.rs` -- make the pattern/symbol helpers `pub(crate)` and noun-parametrized -- one parser for both ref families.
- `crates/zanshin-jj/src/tag_ops.rs`, `cli_command.rs`, `warning.rs`, `lib.rs`, `repo.rs` -- the four verbs, their CLI commands and warnings, `Repo` methods (`tag_set(names, revision, allow_move)`, `tag_delete(patterns)`, `tag_track(names, remotes)`, `tag_untrack(names, remotes)`), inline unit tests for private helpers.
- `crates/zanshin-jj/src/bookmarks.rs`, `config.rs`, `view.rs`, `repo.rs` -- reworked `list_tags` rows and `ViewError::Config`.
- `crates/zanshin-jj/tests/it/tag_ops.rs` (+ `main.rs`) and the updated `view.rs` / `git_fetch_parity.rs` / `clone_init.rs` / `api_stability.rs` -- every I/O-matrix row, the list shape, sort keys.
- `schemas/envelope.fbs` + `cargo make codegen` -- wire tables, generated files committed.
- `crates/zanshin-ffi/src/tags.rs`, `lib.rs`, `tests/it/tags_ffi.rs` (+ `main.rs`), `ffi_abi_doc_sync.rs` -- five externs and their tests (readers, kind tags, error mapping, payload round trip).
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- contract and registry.
- `packages/zanshin_core/lib/...` + `test/ffi/tags_test.dart`, `test/worker/tags_test.dart` -- bridge and its tests.
- `crates/zanshin-parity/tests/oracle/git_scenarios.rs`, `main.rs` -- tag scenarios for every witness and refusal.

**Acceptance Criteria:**
- Given a repo, when `RepoHandle.tagSet(['v1'])` runs from Dart, then `RepoHandle.tags()` lists a Local `v1` row at `@` and the op log head reads `set tag v1 to commit <hex>`.
- Given `v1` tracked on `origin` after `jj git push -t v1`, when `tag_delete(["v1"])` runs, then the list's Local `v1` row has no target (the CLI's `(deleted)` row) and a tracked `v1@origin` row still follows it.
- Given each oracle scenario (set on @ / -r, set refused / allowed move, set no-op, delete by glob, delete tracked, delete unmatched, track symbol, track pattern, already tracked, untrack, untrack `@git`, mixed syntax), when the oracle runs, then Zanshin and the stock CLI agree on state, read-back, refusal and warning count with no new ledger entry.
- Given the list read on a colocated repo with tags, when `RepoHandle.tags()` runs, then no row has remote `git`.

## Spec Change Log

## Review Triage Log

### 2026-11-15 — Review pass
- verdicts: 21 findings — high 0, medium 4, low 12, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `docs/ffi-abi.md` request-table counts disagree (70 / 69+7=76 vs 80 request-buffer symbols) — recounted from the schema and corrected.
  - `[low]` `[patch]` (blind) `Tag.remote_name` / `TagKind` schema comments say "empty for Local" while the encoder writes it absent — comments now say ABSENT; codegen rerun.
  - `[medium]` `[patch]` (blind) tracking a local-only tag onto a remote view that lacks it is untested at every layer — Rust test (pattern + symbol, tracked `target: None` row) and two oracle scenarios added.
  - `[low]` `[reject]` (blind) the oracle never compares `list_tags` rows with the CLI — reads are hand-audited by project rule (epic context § Oracle); the oracle compares state, and the rows are pinned by hand-written expectations in `tag_ops.rs`, `view.rs`, `tags_ffi.rs` and the worker test.
  - `[medium]` `[patch]` (blind) untrack by pattern and `--remote` with a symbol have no witness — Rust untrack-by-pattern test and oracle scenarios (`tag untrack v*`, `--remote` with symbol refusal) added.
  - `[low]` `[patch]` (blind) `tag set` on a deleted-but-tracked tag (set without `--allow-move`, unlike `bookmark set`) is not pinned — oracle scenario added.
  - `[low]` `[patch]` (blind) `tag set` with a bad revision is untested and `zanshin_tag_set` is missing from the `jj.change_not_found` / `jj.revset_resolution_error` emitter lists — Rust assertion and registry rows added.
  - `[low]` `[patch]` (blind) Dart `_mapTag` maps a missing `name` to `''` — now throws `ffi.unknown`, with a decoder test.
  - `[low]` `[reject]` (blind) `ViewError::Config` widens an enum shared with `list_heads` / `list_working_copies`, and `TagKind` lost `Ord` — WIP allows breaking changes (project-context posture); `workspace.rs::from_view` maps the never-returned arm; a separate error type adds surface for no named caller.
  - `[false]` `[reject]` (blind) the list hard-codes dropping `@git` rows — the intent itself asks for the list "without `@git` rows"; `view.rs` documents it.
  - `[low]` `[reject]` (blind) no wire-level test for a malformed `ui.tag-list-sort-keys` through `zanshin_tags` or for `jj.tag_target_empty` / `jj.remote_tags_unmatched` over the envelope — the mapping is unit-tested in `tags.rs`, warnings travel through the shared envelope code tested for every code; low value.
  - `[low]` `[reject]` (edge) a local tag deleted while its only tracked remote ref is `@git` lists a target-less Local row with no visible remote row — that is the CLI's `--all-remotes` output minus the `@git` row the intent removes, and the state is transient (the finish exports to Git and the `@git` ref follows); a guard would diverge from the CLI.
  - `[low]` `[patch]` (edge) Dart decoder turns a corrupt missing name into `''` — same root cause and fix as the blind-hunter row above.
  - `[medium]` `[patch]` (verification-gap) track of a local-only tag has no test — same entry as the blind-hunter row; covered by the added tests and scenarios.
  - `[low]` `[patch]` (verification-gap) a Local row's `synced` reading a tracked `@git` ref that points elsewhere is unpinned — `view.rs` test added (`synced == false`, no `@git` row).
  - `[false]` `[reject]` (intent) `untrack name@git` "refuses" as a warning, not an error — the intent says "as the CLI does"; the CLI at v0.47.0 warns "Git-tracking tag cannot be untracked" and exits 0 (`tag/untrack.rs`).
  - `[low]` `[reject]` (intent) the list witness is not oracle-compared — duplicate of the blind-hunter row; same reason.
  - `[medium]` `[patch]` (intent) refusal coverage in the oracle misses `--remote` with symbols and untrack paths — same entry as the blind-hunter untrack/`--remote` row; scenarios added.
  - `[false]` `[reject]` (intent) the public `list_tags` contract changed in place — the intent asks for the list "as `jj tag list --all-remotes` shows them"; its only callers were tests, updated in the same change.
  - `[false]` `[reject]` (intent) the "deleted" state is implicit (Local row with no target) — that is the bookmark list's shape since Story 9.29, which 10.14 already reads; the CLI shows the same row as `(deleted)`.
  - `[false]` `[reject]` (intent) deferred-work rule untouched — nothing was deferred, so nothing to mirror.

### 2026-11-16 — Review pass
Follow-up pass. The dispatch named one risk: `list_tags` rows were never compared with the CLI. The oracle now does it (new `crates/zanshin-parity/tests/oracle/tag_list.rs`).
- verdicts: 17 findings — high 0, medium 1, low 12, false 4, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `tag_set`'s docs leave out that tagging `@` makes it immutable, so a new `@` starts and the working-copy change id moves — one sentence added to `Repo::tag_set` and `RepoHandle.tagSet`.
  - `[low]` `[reject]` (blind) the tag list takes no filters or `--sort` — the intent excludes them ("Never: list filters/`-T`/`--sort` arguments").
  - `[low]` `[reject]` (blind) carried — a local tag deleted while only `@git` tracks it lists a target-less Local row with no remote row; same claim as the logged edge row, code unchanged. New: the oracle witness `a_tag_deleted_before_an_export_keeps_its_local_row_like_the_cli` shows the CLI prints the same row (plus the `@git` row the intent drops).
  - `[low]` `[patch]` (blind) `list_tags` rows are never compared with the CLI — not carried although the first pass rejected it: this follow-up dispatch named the risk and asked for oracle witnesses. Added `tag_list.rs` (5 tests, same repo through `Repo::list_tags` and `jj tag list --all-remotes -T`): every row kind incl. tracked/untracked on two remotes, unsynced, deleted and remote-only rows, `ui.tag-list-sort-keys = ["name-"]`, a conflicted tag, the deleted-before-export row, and a colocated repo where the CLI prints `@git` rows. All agree.
  - `[low]` `[reject]` (blind) carried — `ViewError::Config` on the shared enum; same claim as the logged row, code unchanged.
  - `[low]` `[defer]` (blind) the reused bookmark/list helpers cite v0.46.0 — pre-existing citations, behavior not found to differ; deferred and mirrored in deferred-work.md.
  - `[false]` `[reject]` (blind) `git_fetch_parity.rs` was quietly narrowed — the old `list_tags` returned only tracked remote rows, so filtering on `tracked: true` keeps exactly the prior comparison.
  - `[low]` `[patch]` (blind) the sprint-status `done` entry has no outcome note — added a `DONE 2026-11-15 (…)` note in the sibling style and bumped `last_updated`.
  - `[medium]` `[defer]` (blind) a bad name pattern refuses with "failed to parse name pattern…" and no hint, unlike the CLI's "Failed to parse name pattern: …" + `revset_parse_error_hint` — real (`bookmark_ops.rs:177` vs `revset_util.rs:336` @ v0.47.0) but pre-existing in the shared bookmark helper; deferred and mirrored.
  - `[low]` `[reject]` (blind) missing tests for an ambiguous `revision`, a conflicted local tag refused without `allow_move`, `zanshin_tags`' config error over the wire, `track --remote` glob — each runs shared code tested elsewhere (`resolve_change`, `is_present`, the envelope mapper, the bookmark remote matcher); unlikely to break alone.
  - `[low]` `[reject]` (blind) `tag_ops::track_or_untrack` parses after `reload_head`, the bookmark sibling before — same behavior; the cost is one head load on a refusal; reordering is churn.
  - `[low]` `[reject]` (edge) carried — the deleted-local-with-only-`@git` row; same as the logged edge row, now CLI-witnessed (see above).
  - `[low]` `[patch]` (intent) the list has no CLI witness — same entry as the blind row; `tag_list.rs` added.
  - `[low]` `[reject]` (intent) warning texts and the `--allow-move` hint are pinned by source-copied literals, not by the oracle (which counts warnings) — texts match the v0.47.0 source; widening the oracle's warning aspect is project-wide work.
  - `[false]` `[reject]` (intent) "set same target" without `allow_move` (reading R2b) — the CLI refuses any present tag without `--allow-move` (`tag/set.rs`), as the Always clause says; R2b contradicts the CLI.
  - `[false]` `[reject]` (intent) epic-context and sprint-status edits are outside scope — workflow bookkeeping the build requires.
  - `[false]` `[reject]` (intent) the absent-target Local row goes beyond the matrix's list row — the Always clause asks for `collect_items` rows with `None` targets; the oracle now shows the CLI prints the same row.

## Design Notes

- Why a separate `tag_ops.rs` instead of a `RefFamily` generic over `bookmark_ops`: the verbs differ (tags have no auto-track, no fast-forward rule, no tracked-remote guard on set, no forget/rename/move), and the view accessors differ per family; sharing only the parsing helpers keeps bookmark code paths untouched.
- `list_tags` changes meaning (it drops its "tracked only" rule). It had no FFI consumer; the Rust callers are tests and get updated.
- `@git` rows are dropped AFTER collecting, not via the remote matcher, so a local row's `synced` and a deleted local row still see the `git` ref exactly as the CLI's `--all-remotes` does.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it tag_ops::` and `--test it view::`, `git_fetch_parity::`, `clone_init::`, `api_stability::`, plus `cargo test -p zanshin-jj --lib` -- pass.
- `cargo test -p zanshin-ffi` -- pass (incl. `ffi_abi_doc_sync`).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- generated files committed, no further diff.
- `cargo test -p zanshin-parity --test oracle` -- pass, no new ledger entry.
- In `packages/zanshin_core`: `dart test`, `dart analyze`, `dart format --set-exit-if-changed .` -- clean (cdylib built first).

## Auto Run Result

Status: done

**Summary.** `zanshin-jj` gains `Repo::tag_set` / `tag_delete` / `tag_track` / `tag_untrack` (new `tag_ops.rs`, ports of `cli/src/commands/tag/*` @ v0.47.0, sharing `bookmark_ops`' noun-parametrized parsing helpers), seven `jj.tag_*` / `jj.remote_tags_unmatched` warning codes and four `cli_command` entries. `Repo::list_tags` now returns the rows of `jj tag list --all-remotes` (via the bookmark list's `collect_items`, sorted by `ui.tag-list-sort-keys`) with the `@git` rows dropped after collecting; `Tag` / `TagKind` carry `Option` targets, `conflicted`, `synced`, `tracked`; `ViewError` gains `Config`. The FFI adds `zanshin_tags` and `zanshin_tag_{set,delete,track,untrack}` (append-only schema: four `RequestKind`s, three request tables, `TagKind`, `Tag`, `Tags` payload), and `packages/zanshin_core` adds `RepoHandle.tags/tagSet/tagDelete/tagTrack/tagUntrack` with worker commands and a `Tag` model. The parity oracle has 22 tag scenarios with a `jj tag list --all-remotes` read-back.

**Files.**
- `crates/zanshin-jj/src/tag_ops.rs` (new) -- the four tag verbs.
- `crates/zanshin-jj/src/bookmark_ops.rs` -- shared helpers `pub(crate)`, noun parameter; bookmark text unchanged.
- `crates/zanshin-jj/src/bookmarks.rs`, `config.rs`, `view.rs`, `workspace.rs` -- reusable `collect_items`/`sort`, `ui_tag_list_sort_keys`, reworked `list_tags`, `ViewError::Config` mapping.
- `crates/zanshin-jj/src/repo.rs`, `cli_command.rs`, `warning.rs`, `lib.rs` -- `Repo` methods, CLI commands, warning kinds, module.
- `crates/zanshin-jj/tests/it/{tag_ops,view,git_fetch_parity,api_stability,main}.rs` -- new and updated tests.
- `schemas/envelope.fbs` + generated `envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart` -- wire contract.
- `crates/zanshin-ffi/src/{tags,envelope,lib}.rs`, `tests/it/{tags_ffi,ffi_abi_doc_sync,main}.rs` -- five externs, warning codes, tests, export count 121.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- symbol rows, `Tags` section, counts, warning codes, emitter lists.
- `packages/zanshin_core/lib/src/ffi/{tags,warning}.dart`, `lib/src/worker/{commands,isolate,handle}.dart`, `lib/zanshin_core.dart`, `test/ffi/{tags,warning}_test.dart`, `test/worker/tags_test.dart` -- bridge and tests.
- `crates/zanshin-parity/tests/oracle/{git_scenarios,scenarios,main}.rs` -- tag scenarios (count 498).

**Review.** One pass, 21 findings (medium 4, low 12, false 5). Patched: request-table counts in `ffi-abi.md`; schema comments for `remote_name` (ABSENT); tests + oracle scenarios for tracking a local-only tag; untrack by pattern and `--remote` with a symbol; `tag set` on a deleted-but-tracked tag; unknown revision on `tag_set` + registry emitters; Dart decoder refuses a missing tag name; `synced` reading a dropped `@git` ref. Rejected (reasons in the triage log): list rows not oracle-compared (reads are hand-audited by rule), `ViewError`/`TagKind` API widening (WIP breaking changes allowed), no wire test for the sort-key config error / two warning codes, the transient deleted-local-with-only-`@git` row, and five `false` findings. Nothing deferred. Patched by verdict: medium 2 entries, low 6 entries.

**Follow-up review recommended: true.** Two medium entries were patched on this first pass. Named unverified risk: the reworked `list_tags` rows (order, `synced`, `conflicted`, the deleted Local row, the `@git` drop) are checked only against hand-written expectations, never against the stock CLI's `jj tag list --all-remotes`.

**Verification (this run; gate rule: no `cargo make test`/`test-full`/`coverage`).**
- `cargo test -p zanshin-jj --test it -- tag_ops:: view:: git_fetch_parity:: clone_init:: api_stability:: bookmark arg_refusals::` -- 291 passed.
- `cargo test -p zanshin-jj --lib` -- 455 passed.
- `cargo test -p zanshin-ffi` -- 245 + 411 passed (incl. `ffi_abi_doc_sync`).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- rerun after the patches; no further diff.
- `cargo test -p zanshin-parity --test oracle` -- full suite 539 passed before the review patches; after them the 22 tag scenarios + `every_scenario_has_a_test` -- 23 passed. No ledger entry.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- clean; `dart format --set-exit-if-changed .` -- clean; `dart test test/ffi/tags_test.dart test/worker/tags_test.dart test/ffi/warning_test.dart` -- 187 passed (the implementer also ran the full suite, 1210 passed, before the review patches). One fix made here: the worker test's `git tag v1` now passes `-c tag.gpgSign=false`, since a user's `tag.gpgSign` made it an annotated tag needing a message.

**Residual risks.**
- Coverage not measured (gate rule); `tag_ops.rs` and `crates/zanshin-ffi/src/tags.rs` are new files that must reach the 80 % floor at the loop's final gate.
- Tagging `@` makes `@` immutable (`tags()` is in the builtin immutable heads), so the finish creates a new `@` with `jj.working_copy_immutable` — the CLI does the same; the oracle agrees.

### Follow-up review pass (2026-11-16)

Status: done

**Summary.** The named risk is closed: `Repo::list_tags` now has a CLI witness. The new oracle module `tag_list.rs` reads the same repo through `Repo::list_tags` and `jj tag list --all-remotes -T <row template>` (the CLI's `@git` rows left out, its target list cut to the first added change id, as `Tag::target` keeps it) and asserts equality. Against `cmd_tag_list` and `CommitRef::{local, remote, remote_only}` at v0.47.0 the rows agree on order, `tracked`, `synced`, `conflicted`, targets, the target-less deleted row and the descending sort key. No product code changed apart from two doc sentences.

**Files.**
- `crates/zanshin-parity/tests/oracle/tag_list.rs` (new), `main.rs` -- five read witnesses: every row kind (local only; tracked on `origin` + untracked on `remote2`; moved locally = unsynced; untracked; deleted = target-less local row; remote-only untracked), `ui.tag-list-sort-keys = ["name-"]`, a conflicted tag (concurrent `tag set` on two unrelated commits), a tag deleted before an export (local row kept, `@git` row dropped), and a colocated repo where the CLI prints `@git` rows.
- `crates/zanshin-jj/src/repo.rs`, `packages/zanshin_core/lib/src/worker/handle.dart` -- `tag_set` / `tagSet` docs say tagging `@` makes it immutable and moves the working copy.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- `DONE` note on `9-59-tag-verbs`, `last_updated` 2026-11-16.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- two deferred items mirrored.

**Review.** 17 findings (medium 1, low 12, false 4). Patched: list rows CLI-witnessed (low; not carried, the dispatch asked for it), `tag_set` immutable-`@` docs (low), sprint-status outcome note (low). Deferred: pattern-parse refusal text and hint differ from the CLI (medium, pre-existing in the shared bookmark helper); stale v0.46.0 citations in the shared helpers (low, pre-existing). Rejected (reasons in the triage log): list filters (intent excludes them), the deleted-local-with-only-`@git` row and `ViewError::Config` (carried), four extra error-path tests, the track/untrack parse order, oracle warning-text comparison, and four `false` findings. Patched by verdict: high 0, medium 0, low 3 entries.

**Follow-up review recommended: false.** A follow-up pass recommends another only when it patched a `high`; this one patched none.

**Verification (gate rule: no `cargo make test`/`test-full`/`coverage`).**
- `cargo test -p zanshin-parity --test oracle tag_list::` -- 5 passed.
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean (after `cargo fmt -p zanshin-parity`).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed lib/src/worker/handle.dart` -- unchanged.
- No verb, FFI or schema changed, so no codegen and no full oracle run.

**Residual risks.**
- The witnesses do not cover a sort key that loads commits (`committer-date`, `author-name`); `bookmarks::sort` is shared with the bookmark list and its CLI-copied sort tests.
- Coverage is still unmeasured until the loop's final gate.

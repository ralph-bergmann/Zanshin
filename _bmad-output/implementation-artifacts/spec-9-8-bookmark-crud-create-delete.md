---
title: 'Story 9.8: Bookmark CRUD (cheap start) — `bookmark create`, `bookmark delete`'
type: 'feature'
created: '2026-09-04'
status: 'done'
baseline_revision: 'a3f7ed37719280faf2f15421362fdac8bb09e3f4'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      BookmarkCreateRequest and BookmarkDeleteRequest verify interchangeably, and here the two
      names vectors have OPPOSITE semantics.
    evidence: |-
      No request table carries a FlatBuffers file_identifier (house-wide since Story 9.3), so a
      BookmarkCreateRequest buffer passes the Verifier as a BookmarkDeleteRequest and vice versa.
      Until now the colliding tables meant the same thing; here create's names are EXACT decoded
      names while delete's are GLOB-by-default patterns, so a mis-routed buffer silently
      glob-deletes what the caller meant as literal names. The FFI test
      a_zero_handle_is_refused_by_both_wrappers even feeds a create buffer to the delete wrapper.
    location: >-
      schemas/envelope.fbs (BookmarkCreateRequest / BookmarkDeleteRequest)
    severity: medium
  - summary: >-
      session_from_handle is now duplicated verbatim in four zanshin-ffi modules.
    evidence: |-
      git.rs, commit_views.rs, workspace.rs and the new bookmark_ops.rs each carry a byte-identical
      copy, including the unbounded-lifetime SAFETY comment that must stay in sync. This story's own
      rationale for moving finish_or_no_op into mutate.rs ("a second, desyncable spelling") applies
      unchanged.
    location: >-
      crates/zanshin-ffi/src/bookmark_ops.rs
    severity: low
  - summary: >-
      Six copies of the Dart request-buffer helpers across the ffi adapters.
    evidence: |-
      _withRequestBytes, _readToken and the interior-NUL guard are re-spelled in mutate.dart,
      git.dart, file.dart, commit_views.dart, workspace.dart and bookmark_ops.dart — the exact
      duplication the Rust half of this story refactored away, left standing on the Dart half.
    location: >-
      packages/zanshin_core/lib/src/ffi/bookmark_ops.dart
    severity: low
  - summary: >-
      The non-git arm of has_tracked_remote_bookmarks is executed but never asserted.
    evidence: |-
      On a git-backed repo the matcher excludes the reserved remote `git`; on a native backend it is
      StringMatcher::all(), so a tracked name@git DOES block create there. Every Rust test uses the
      git-backed tiny-3-commits fixture, and the Dart worker tests run on a native backend without
      asserting the distinguishing behaviour. The two arms differ semantically; only one is pinned.
    location: >-
      crates/zanshin-jj/src/bookmark_ops.rs (has_tracked_remote_bookmarks)
    severity: low
  - summary: >-
      MutationResult's other three fields are asserted nowhere for either bookmark verb.
    evidence: |-
      Across the new jj, FFI and Dart tests only new_op_id is checked. new_change_ids and
      abandoned_change_ids (both required to be empty for these verbs) and working_copy_change_id
      (produced by sync_working_copy) would ship a regression green.
    location: >-
      crates/zanshin-jj/tests/bookmark_ops.rs
    severity: low
  - summary: >-
      The same "absent revision" doc ambiguity fixed here survives on the Story 9.3/9.4/9.6
      surfaces.
    evidence: |-
      This story's `# Errors` bullet said a revision that is "malformed, absent, only-hidden, or
      divergent" refuses, in a paragraph where ABSENT means "apply the CLI's -r default". The
      wording was corrected on the three bookmark surfaces; file.rs's revision (and the sibling
      9.3/9.6 surfaces it was copied from) still carries it, and was left alone as out of scope.
    location: >-
      crates/zanshin-jj/src/file.rs
    severity: low
  - summary: >-
      docs/ffi-abi.md is now six stories stale.
    evidence: |-
      Stale since Story 4.9; 9.1 and 9.3-9.7 did not update it either. This story adds two more
      extern "C" entry points and two request tables that the ABI document is supposed to describe.
    location: >-
      docs/ffi-abi.md
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin can LIST bookmarks (Story 2.8 → `zanshin_bookmarks`) but cannot create or
delete one. Every bookmark write forces the user out to the `jj` CLI, and Epic 6's bookmark-CRUD
stub (Story 6.9) was deleted rather than implemented. Bookmarks are the primary way a jj user names
work, so a GUI that can only read them is read-only in the dimension users touch most.

**Approach:** Add the two cheapest bookmark mutations — the CLI's `jj bookmark create` and
`jj bookmark delete` — as typed verbs in a new `zanshin-jj` module `bookmark_ops.rs`, both built on
`MutableRepo::set_local_bookmark_target` (`RefTarget::normal` / `RefTarget::absent`), and surface
them through the chain Stories 9.3–9.7 established: `.fbs` request table → typed op → `extern "C"`
+ committed codegen → Dart adapter / `WorkerCommand` / `ZanshinWorker` / `RepoHandle` → tests. Both
verbs return the shipped `MutationResult`, so no new payload table and no new `union Payload`
discriminant is needed. The jj CLI at tag `v0.44.0` is the behavioral oracle for argument arity,
defaults, refusals and op-log effect.

## Boundaries & Constraints

**Always:**
- Both verbs are MUTATIONS composed entirely Rust-side (ADR-0003): one whole transaction per call,
  never primitives across FFI. Reuse `mutate::finish_or_no_op` (moved here from `git.rs`) so the
  no-op arm is the shipped one — when nothing changed, the transaction is dropped, NO operation is
  written, and `MutationResult::new_op_id` is the PRE-CALL op-log head.
- Op-log parity is byte-level (NFR-R-2): the transaction descriptions must be exactly the CLI's —
  `format!("create bookmark {names} pointing to commit {id}")` with `names` joined `", "` in
  ARGUMENT order and `id` the full commit hex (`cli/src/commands/bookmark/create.rs:123-131`), and
  `format!("delete bookmark {}")` with the MATCHED names joined `", "` in view order
  (`delete.rs:79-89`). Both render each name with jj-lib's `RefName::as_symbol()` (quoted revset
  form), which is the one place `as_symbol` is right — the payload/name direction still uses
  `as_str` (`zanshin-jj/src/git.rs:343-345`).
- CLI parity @ `v0.44.0` on arity, defaults and refusals:
  - `create` takes ≥1 EXACT name (`required = true`) plus `-r/--revision`, whose default is the
    literal `"@"` (a clap `default_value`, NOT a config key — do not invent a `revsets.*` lookup).
    Preconditions run per name in argument order, AFTER the revision resolves, and are FAIL-FAST:
    the first offending name returns and nothing is created.
  - `delete` takes ≥1 string PATTERN (`required = true`). A bare word is a GLOB, not an exact match
    (`jj_lib::revset::expect_string_expression` → `StringPattern::glob`, `revset.rs:1254-1261`);
    `exact:`/`glob:`/`regex:`/`substring:` prefixes and the `~`/`&`/`|` operators all work. Patterns
    are unioned. Matching nothing is SUCCESS with no operation — never a refusal.
- Parameter currency follows the rule 9.3/9.6 set: `create`'s revision is a single revision, so it
  is an owned `ChangeId` (`resolve_or_wc`, the CLI's `RevisionArg::AT` default), exactly like
  `FileListRequest.revision` — it inherits `resolve_single_rev`'s ambiguity REFUSAL but not its
  address space (no commit hex, no revset expression, no hidden commit). `delete`'s patterns are
  pass-through STRINGS, because the pattern kind is the parameter's meaning (FR-JJ-17).
- Names cross as DECODED values, not as CLI argument text. The CLI validates names with
  `revset_util::parse_bookmark_name` = `revset::parse_symbol`, i.e. revset QUOTING grammar (`'foo
  bar'`, `'foo@bar'`) — that is terminal input syntax the GUI replaces (ADR-0003). The only
  behavioral residue to keep is the refusal `parse_symbol` makes in every spelling: an EMPTY name is
  rejected. jj-lib itself validates nothing.
- `zanshin-jj` stays sync (`pollster::block_on`), stays `jj_lib`-type-free in every public signature
  (`lib.rs:17-28`), and keeps `#![deny(missing_docs)]` satisfied.
- Every new `extern "C"` fn needs at least one `packages/zanshin_core` test that calls it through
  the real cdylib, or the coverage gate's extern-fn guard fails (`Makefile.toml:537-564`).
- Interior-NUL rejection for every name/pattern string lives on the CALLING side
  (`ZanshinWorker` + `RepoHandle`), with the FFI adapter guard kept only as a direct-caller
  backstop — the fix Stories 9.6 and 9.7 both had to make in review, because inside the worker
  isolate an adapter `ArgumentError` comes back as `internal.dispatch_error`.

**Block If:**
- jj-lib 0.44.0 does not expose `MutableRepo::set_local_bookmark_target`, `RefTarget::normal`/
  `absent`, `View::local_bookmarks_matching`, or `revset::parse_string_expression` with the
  signatures in the Code Map (pin drift): HALT with `blocked`, blocking condition `jj-lib API drift`.
- The coverage ratchet can only be made green by lowering a baseline entry or adding an
  `exclude_prefix`: HALT with `blocked`, blocking condition `coverage ratchet regression`.

**Never:**
- No other bookmark verb. `set`, `forget`, `track`, `untrack` are Story 9.11; `move`, `advance`,
  `rename` and `bookmark list` filters are Story 9.19. In particular
  `track_remote_bookmark`/`untrack_remote_bookmark` must not be called from production code here.
- No auto-tracking on create. The CLI honours `remotes.<r>.auto-track-bookmarks` /
  `auto-track-created-bookmarks` (`create.rs:89-111`) by calling `track_remote_bookmark` — the verb
  Story 9.11 owns. Deliberately out of scope; record it as a deferred item, do not silently drop it.
- No terminal UX: no `ui.warning`/`ui.status` equivalents — the CLI's "Target revision is empty.",
  "Created N bookmarks pointing to …", "Deleted N bookmarks.", "No bookmarks to delete." and
  "No matching bookmarks for names: …" are all stdout/stderr chatter the GUI replaces. The
  machine-readable equivalent of the last two is already in the contract: an unchanged `new_op_id`
  means nothing happened.
- No new payload table and no new `union Payload` member — both verbs return the shipped
  `MutationResult` (the same reuse Story 9.5's four remote verbs made).
- No change to the shipped READ contract: `crates/zanshin-jj/src/bookmarks.rs`, its `Bookmark` /
  `BookmarkKind` / `BookmarkError` types, and `zanshin_bookmarks` stay exactly as they are.
- No fixture regeneration (forbidden, `test-helpers/src/lib.rs:135-138`). Remote-tracking state is
  constructed in-test with `test_helpers::set_remote_bookmark`.
- No shelling to `jj`, no MCP tool (`zanshin-mcp` is still a stub; Epic 7 owns the tool surface, and
  9.3–9.7 all skipped it).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| create, default revision | `bookmark_create(&["feature".into()], None)` on `tiny-3-commits` | `feature` present in the view at `@`; `new_op_id` ≠ pre-call head; op description `create bookmark feature pointing to commit <full hex>` | No error expected |
| create, explicit revision | `bookmark_create(&["v1".into()], Some(&change_id_of_root_child))` | Bookmark targets THAT commit, not `@` | No error expected |
| create, several names | `bookmark_create(&["a".into(), "b".into()], None)` | Both created in ONE operation; description names joined `", "` in ARGUMENT order (`a, b`), not sorted | No error expected |
| create, on the root commit | revision = the root commit's change id | Succeeds — the CLI allows it (`cli/tests/test_bookmark_command.rs:122-141`); only a later `git export` would object | No error expected |
| create, name already exists | `feature` already a local bookmark | Refusal; head op id unchanged | `jj.bookmark_exists`, context = the name |
| create, fail-fast on the 2nd name | `["fresh", "existing"]` | NOTHING is created — not even `fresh` (CLI returns on the first offender before opening the transaction); head op id unchanged | `jj.bookmark_exists`, context = `existing` |
| create, deleted-but-tracked name | local absent, `foo@origin` present and TRACKED (built with `set_remote_bookmark(.., tracked = true)`) | Refusal, distinct from the already-exists one because the remedy differs (untrack, or use `bookmark set` in 9.11) | `jj.bookmark_tracked_remote_exists`, context = the name |
| create, untracked remote of the same name | `foo@origin` present but NOT tracked | SUCCEEDS — the CLI's guard is `has_tracked_remote_bookmarks`, tracked only | No error expected |
| create, empty name | `bookmark_create(&[String::new()], None)` | Refusal — `revset::parse_symbol` rejects the empty string in every CLI spelling | `jj.invalid_input` |
| create, no names at all | `bookmark_create(&[], None)` | Refusal — the wire form of clap's `required = true`; no transaction | `jj.invalid_input` |
| create, unknown revision | revision = a change id no commit carries | Refusal | `jj.change_not_found`, context = the id |
| create, divergent revision | revision = a change id carried by two visible commits | Refusal, never a guess (the shipped `resolve_commit` contract) | `jj.change_not_found` |
| delete, exact name | one local bookmark named `feature` | Gone from the view; new op id; description `delete bookmark feature` | No error expected |
| delete, glob | bookmarks `foo-1`, `foo-2`, `bar`; pattern `glob:"foo-*"` | Both `foo-*` deleted, `bar` untouched; description lists the matched names in VIEW (lexicographic) order | No error expected |
| delete, bare word is a glob | a bookmark literally named `foo*` plus one named `foo1`; pattern `foo*` | BOTH match — a bare pattern is a glob, not an exact name; `exact:"foo*"` matches only the literal one | No error expected |
| delete, matches nothing | pattern `nosuch` on a repo without it | SUCCESS: `new_op_id` equals the PRE-CALL head, no operation written, view unchanged | No error expected |
| delete, malformed pattern | pattern `glob:"["` or an unknown kind prefix | Refusal | `jj.invalid_input`, context = jj-lib's parse reason |
| delete, no patterns at all | `bookmark_delete(&[])` | Refusal — clap's `required = true` | `jj.invalid_input` |
| delete, tracked remote survives | local `feature` + tracked `feature@origin`, delete `feature` | Local row gone; `list_bookmarks` STILL reports the `Remote { remote_name: "origin" }` row — the "deleted bookmark" state whose deletion propagates on the next push | No error expected |
| delete, conflicted bookmark | a divergent local bookmark (`set_local_bookmark(.., &[a, b])`) | Deleted — `RefTarget::absent()` removes it regardless of conflict state | No error expected |
| either verb, unknown handle | `handle = 0` or a closed handle | No call into `zanshin-jj` | `ffi.invalid_handle` |
| either wrapper, null request buffer | `data = null` | — | `ffi.null_pointer` |
| either wrapper, malformed request buffer | non-FlatBuffers bytes | Verifier rejects before use | `ffi.invalid_argument` |
| either verb, every refusal | any refusal row above | The head operation id is unchanged, at both the `zanshin-jj` and the FFI layer | — |

</intent-contract>

## Code Map

Zanshin anchors read against the working tree at baseline `a3f7ed3`; jj CLI anchors at tag `v0.44.0`
(`git -C ../jj show v0.44.0:<path>`); jj-lib anchors in the vendored `jj-lib-0.44.0`.

**Prior art (read-only, at the tag)**
- `v0.44.0:cli/src/commands/bookmark/create.rs:31-50` — args: `revision: RevisionArg` with
  `long, short, default_value = "@", visible_alias = "to"`; `names: Vec<RefNameBuf>` with
  `required = true, value_parser = revset_util::parse_bookmark_name`. `:57-60` resolve the revision
  FIRST. `:64-83` the two per-name preconditions, both `return Err` (fail-fast). `:84-86` the
  discardable-target warning (dropped here). `:88-112` the transaction: `set_local_bookmark_target
  (name, RefTarget::normal(target_commit.id().clone()))` at `:94-95`, auto-track at `:96-111`
  (out of scope). `:123-131` the description.
- `v0.44.0:cli/src/commands/bookmark/delete.rs:36-48` — `names: Vec<String>`, `required = true`, NO
  value parser; the doc comment names glob as the default syntax. `:57-67` parse → `to_matcher` →
  `local_bookmarks_matching` → **empty ⇒ status line + `return Ok(())`, no transaction**. `:69-73`
  the write loop with `RefTarget::absent()`. `:79-89` the description.
- `v0.44.0:cli/src/cli_util.rs:3385-3393` `has_tracked_remote_bookmarks(repo, bookmark) -> bool` —
  exact-name match over remote bookmarks EXCLUDING the default-ignored remote (`git`), true if any
  `remote_ref.is_tracked()`. This is why a colocated `foo@git` does not block `create foo`.
- `v0.44.0:cli/src/revset_util.rs:293-301` `parse_bookmark_name` = `revset::parse_symbol`;
  `:317-337` `parse_union_name_patterns` = per-arg `revset::parse_string_expression` +
  `StringExpression::union_all`, error text `Failed to parse name pattern: {kind}`.
- `v0.44.0:cli/src/commands/bookmark/mod.rs:185-203` `warn_unmatched_local_bookmarks` — warns only
  for `name_expr.exact_strings()`, so a non-matching GLOB warns nothing. Dropped here (ui chatter).
- `v0.44.0:cli/tests/test_bookmark_command.rs:46-84` (multi-name create + duplicate-collapsing
  delete), `:122-141` (create on `root()` succeeds), `:145-243` (name validation is clap-level,
  exit 2; quoted `'foo@bar'` succeeds), `:276-283` (already-exists), `:338-372` (deleted-but-tracked
  refusal, and that `bookmark untrack` clears it), `:1176-1298` (glob delete, "No bookmarks to
  delete." on a re-delete, malformed-pattern error), `:1303-1324` (`foo (deleted)` + `@git` row
  survives until `git export`).

**jj-lib 0.44.0 (vendored, exact signatures)**
- `repo.rs:1774-1779` `pub fn set_local_bookmark_target(&mut self, name: &RefName, target: RefTarget)`
  — adds a view head per `target.added_ids()`, then delegates to `View`. Takes the BORROWED
  `&RefName` (`RefNameBuf: Deref<Target = RefName>`). `repo.rs:1770` `get_local_bookmark(&RefName)
  -> RefTarget` (cloned).
- `view.rs:197-213` `View::set_local_bookmark_target` — the decision point for delete: an absent
  target removes the local entry and garbage-collects ONLY remote rows that are themselves absent.
  Any remote-tracking ref with a real target SURVIVES — that is the "deleted bookmark" state.
- `view.rs:165` `local_bookmarks()`, `:184` `local_bookmarks_matching(&StringMatcher)`, `:193`
  `get_local_bookmark(&RefName) -> &RefTarget` (there is no `has_local_bookmark`; the CLI uses
  `.is_present()`), `:223` `remote_bookmarks(&RemoteName)`, `:243` `remote_bookmarks_matching`.
  All backing maps are `BTreeMap`, so iteration is lexicographic by name.
- `op_store.rs:81` `RefTarget::normal(CommitId)`, `:63` `absent()`, `:114` `is_absent()`, `:119`
  `is_present()` (a CONFLICTED target is "present"), `:127` `added_ids()`. `:138` `RemoteRef
  { target, state }`, `:171` `is_tracked()`.
- `ref_name.rs:157` `RefName::new(&str) -> &RefName` (const, zero-copy ref-cast), `:160` `as_str`,
  `:165` `as_symbol() -> &RefSymbol` whose `Display` (`:334`) renders the QUOTED revset form — this
  is what the op-log descriptions need. `:311` `to_remote_symbol(&RemoteName)`. **No validation of
  any kind on construction.**
- `revset.rs:1446-1452` `pub fn parse_string_expression(&mut RevsetDiagnostics, &str) ->
  Result<StringExpression, RevsetParseError>`; `revset.rs:1254-1261` shows a bare identifier or
  quoted string becomes `StringPattern::glob(value)` — the DEFAULT KIND IS GLOB.
- `revset_parser.rs:662-676` `pub fn parse_symbol(&str) -> Result<String, RevsetParseError>` —
  "Parses the text as a revset symbol, rejects empty string" (`Expected non-empty string`).
- `str_util.rs:344` `StringExpression`, `:393` `union_all(Vec<Self>)`, `:432` `to_matcher()`,
  `:478` `StringMatcher`.
- `transaction.rs:135-173` `Transaction::write` asserts `!has_rewrites()` and
  `view.is_heads_normalized()`. Normalization is automatic: `mut_repo.consume()` (`:146`) calls the
  private `normalize_heads` (`repo.rs:991`), so the head `set_local_bookmark_target` adds needs no
  explicit rebase/normalize call. `repo.rs:978` `has_changes()` compares the view against the base
  view — a bookmark write is visible there, a matched-nothing delete is not.

**Extend — `crates/zanshin-jj`**
- `src/bookmark_ops.rs` (**NEW**) — module doc in the `view.rs:3-9` / `commit_views.rs` shape (CLI
  parity tag, the ported CLI files, the deliberate divergences from **Never**), then
  `pub(crate) fn create(workspace: &mut Workspace, names: &[String], revision: Option<&ChangeId>)`
  and `pub(crate) fn delete(workspace: &mut Workspace, patterns: &[String])`, both
  `-> Result<MutationResult, MutateError>`, plus module-private helpers for name validation and
  pattern parsing. **No new public types.**
- `src/mutate.rs:76-213` `MutateError` — append two variants after `RevsetResolutionError` `:204-208`
  and BEFORE `Backend` `:209-212` (the file's ordering convention). `:272` `be`, `:279` `cfg`,
  `:287` `rev`, `:298` `res` (make `pub(crate)` — same one-word widening `be`/`cfg`/`rev` already
  have), `:315` `build_matcher` (paths, NOT string patterns — do not reuse), `:321` `resolve_or_wc`,
  `:364` `capture_old_wc`, `:379` `sync_working_copy`, `:701` `no_op_result`.
- `src/git.rs:242-318` `struct Finished<T>` + `fn finish_or_no_op` — **MOVE both to `mutate.rs` as
  `pub(crate)`** and re-point `git.rs`'s four call sites. This is the shipped transaction skeleton
  (load at head → capture `@` → transaction → `has_changes()` no-op arm → commit → sync working
  copy) and both new verbs are exactly its shape. `git.rs:343-345` carries the `as_str`-not-
  `as_symbol` rule for payload names — the op-log description is the documented exception.
- `src/op_support.rs:513-529` `resolve_or_wc(&dyn Repo, &WorkspaceName, Option<&ChangeId>)`,
  `:482` `resolve_commit`, `:456` `ResolveError`. `immutable_user_expression`/`check_rewritable`
  are NOT needed: bookmark writes rewrite no commit and the CLI runs no rewritability guard.
- `src/bookmarks.rs:19-52` — the shipped read vocabulary (`BookmarkKind`, `Bookmark`,
  `BookmarkError`), untouched; `:70` `list_bookmarks` is the oracle the delete tests re-read through.
- `src/repo.rs:1070-1104` the Story 9.7 facades (the block to insert AFTER; `:1105` is blank and
  `:1106` starts the Story 9.3 `restore` doc block). `:792-800` `git_remote_add` is the closest
  mutation-facade doc template (summary naming the CLI verb, behavioural notes, `# Errors` one
  bullet per variant, `#[must_use]`). `:170` `list_bookmarks` for the read-facade shape.
- `src/lib.rs:30-48` module list (strictly alphabetical — `bookmark_ops` sorts BEFORE `bookmarks`
  at `:30`, since `_` < `s`), `:50-67` re-export block. No new re-export is needed (no new public
  types); `#![deny(missing_docs)]` at `:3`.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — append two request tables after `WorkspaceRootRequest` `:223-225`, before
  the `// ── Payload union ──` header `:227`; field order is the wire contract (`:36-39`), and the
  null-for-absence rule for an optional request string is spelled out at `:174-177` /
  `FileListRequest.revision` `:80-90` (the exact precedent for a `-r` default). Ledger comment
  `:229-245` — append a `//   Story 9-8  : …` line after `:245`. **`union Payload` `:850-877` is
  UNCHANGED**; `table MutationResult` `:536-541` is reused.
- `crates/zanshin-ffi/src/bookmark_ops.rs` (**NEW**) + `pub mod bookmark_ops;` in `lib.rs:32-50`
  BEFORE `bookmarks` `:32` (alphabetical; `cargo fmt` re-sorts and the C header must then be
  regenerated — see commit `f77ecbf`). Templates: `git.rs:62` `read_git_remote_add_request` (an
  owned-struct request reader), `git.rs:197-209` `session_from_handle`, `git.rs:296-338`
  `zanshin_git_remote_add` — the complete mutation wrapper: doc block with `# Errors` then
  `# Safety`, `debug!(fn_name = …, handle)`, `catch(|| …)`, `ok_mutation_result(&result)`,
  `vec_into_token(buf)`.
- `crates/zanshin-ffi/src/envelope.rs` — code constants `:18-118`; reuse `FFI_INVALID_HANDLE` `:18`,
  `FFI_NULL_POINTER` `:20`, `FFI_INVALID_ARGUMENT` `:24`, `JJ_INVALID_INPUT` `:45`,
  `JJ_CHANGE_NOT_FOUND` `:36`, `JJ_JJ_LIB_ERROR` `:32`; **add two new consts** here
  (single-emission-point rule), next to `JJ_REMOTE_EXISTS` `:64`, which is the naming precedent.
  Helpers: `reject_null_request` `:160`, `invalid_request` `:171`, `ok_mutation_result` `:274`,
  `err` `:407`, `catch` `:449`.
- `crates/zanshin-ffi/src/repo.rs:89-146` `map_mutate_err` — add the two arms in the same relative
  position as the enum variants. `:148-168` the request-reader banner + soundness note; `:310-311`
  `RepoSession` (`handle_from_raw` yields `&mut`, so a mutation needs no extra ceremony).
- `crates/zanshin-ffi/src/bookmarks.rs:19-26` `map_bookmarks_err` / `:84-99` `zanshin_bookmarks` —
  the read wrapper that stays untouched (the two crates split read vs. ops the same way
  `remotes.rs` and `git.rs` already do).
- Generated, regenerate only via `cargo make codegen`: `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `crates/zanshin-ffi/src/envelope_generated.rs`,
  `packages/zanshin_core/lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}`.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/bookmark_ops.dart` (**NEW**) — banners `// ── Request-buffer helpers ──` /
  `// ── FFI adapters ──`. Templates in `ffi/mutate.dart`: `_withRequestBytes` `:28-36`,
  `_rejectInteriorNul` `:49-53`, the buffer-passing adapter `zanshinAbandon` `:119-127`. **Decode
  through the shipped `decodeMutationResultEnvelopeInternal` (`ffi/mutate.dart:327`) — do not
  re-spell the MutationResult decoder or model.**
- `lib/src/worker/commands.dart` — sealed base `:11`; request-carrying templates `RestoreCommand`
  `:340` / `GitRemoteAddCommand` `:541`; append after `WorkspaceRootCommand` (ends ~`:753`), before
  `ShutdownCommand` `:755` (**must stay last**).
- `lib/src/worker/isolate.dart` — aliased import block (`repo_ffi_bookmarks` at `:11`); method
  templates `edit` `:707-712` / `restore` `:790`, append after `workspaceRoot`; switch-arm template
  `case EditCommand(...)` `:1495-1510` with the synthesized `ffi.invalid_handle` envelope, append
  after the `WorkspaceRootCommand` arm `:1893`, before `case ShutdownCommand():` `:1910`.
- `lib/src/worker/handle.dart` — the `_closed`-guard method template `edit` `:235-240`; the bookmark
  read method `bookmarks()` `:156-166`; append after the Story 9.7 methods.

**Tests / gates**
- `crates/test-helpers/src/lib.rs` — `extract_fixture` `:41`, `add_commit_off_root` `:95`,
  `add_divergent_twin` `:323`, **`set_local_bookmark(workspace_root, name, targets)` `:421-427`**
  (">1 target writes a CONFLICTED bookmark; an empty slice deletes it" — the only way to seed
  bookmark state), **`set_remote_bookmark(workspace_root, name, remote, target, tracked)`
  `:447-467`** (the only way to reach the tracked-remote refusal), private `ref_target` `:497-507`.
  Fixture regeneration is forbidden `:135-138`.
- `crates/zanshin-jj/tests/bookmarks.rs` — the read harness this story's tests re-read through:
  `pin_env` `:24`, `make_test_settings` `:28`, `oracle_workspace` `:48`, and
  `setup_with_remote_bookmarks` `:117-175` (builds local+tracked / absent-tracked / present-untracked
  remote state inline via jj-lib — the exact scenario matrix `create`'s second precondition needs).
- `crates/zanshin-jj/tests/mutate.rs` — the mutation harness: `pin_env` `:22`,
  `make_test_settings` `:26`, and the "capture the head op id before, compare after" idiom that the
  no-op rows depend on. `tests/git_sync.rs` / `tests/remotes_write.rs` are the `finish_or_no_op`
  siblings.
- **Fixture facts (do not re-derive):** `tiny-3-commits` has ZERO bookmarks
  (`tests/bookmarks.rs:68`, `tests/bookmarks_ffi.rs:105`); `medium-1k-commits` has exactly 29, all
  LOCAL, zero remote (`tests/bookmarks.rs:80-103`). Any remote-tracking state MUST be built in-test.
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` — `pin_env` `:50`, `parse_envelope` `:72`,
  `change_id_list_bytes` `:83`, `restore_request_bytes` `:94`, `change_id_for_commit` `:142`,
  `open_handle` `:150`, `close_handle` `:162`. `tests/bookmarks_ffi.rs` is the read sibling.
- `packages/zanshin_core/test/ffi/mutate_test.dart` — synthetic-buffer decode contract
  (`fbs.EnvelopeObjectBuilder` + `fbs.MutationResultObjectBuilder`, `:65`, `:146`) and the
  NUL-rejection group `:225`.
- `packages/zanshin_core/test/worker/mutate_test.dart` — the real-cdylib harness: group `:27`,
  `setUp` `:31` (temp dir + `ZanshinWorker.start()`), `worker.initRepo(...)` + `handle.status()` for
  a real change id `:44-48`, closed-handle guard group `:242`. Its header paragraph (real
  `Isolate.spawn` + real cdylib, and what credits each `zanshin_*` fn in the extern-fn guard) is the
  paragraph the new worker test file must carry.
- `crates/zanshin-jj/tests/api_stability.rs` — header type count `:12-18` (currently **60**; this
  story adds NO public type, so the count is unchanged — say so in the header rather than leaving it
  ambiguous), grouped alias regions `:80-121`, and the per-story `*_surface_resolves` convention
  ending at `workspace_surface_resolves` `:684-715` (append after `:715`). Never extend
  `api_surface_resolves` `:343`.
- `Makefile.toml` — `[tasks.test]` `:47-72` (coverage last), `[tasks.codegen]` `:289-295`,
  `[tasks.verify-codegen]` `:348-446` (manual; refuses on a dirty tree), `[tasks.coverage]`
  `:449-571` with the extern-fn guard `:537-564` (greps every `extern "C" fn` name out of
  `crates/zanshin-ffi/src` and fails on `FNDA:0,<name>`; a Rust-only integration test does NOT
  satisfy it).
- `coverage-baseline.txt` — knobs `:1-13` (`epsilon_pct = 0.10`, `new_file_floor_pct = 80.00`);
  `zanshin-ffi/src/*` `:14-34` (`bookmarks.rs` 100.00 at `:14`); `zanshin-jj/src/*` `:38-56`
  (`bookmarks.rs` 94.12 at `:38`, `git.rs` 98.87, `mutate.rs` 97.32, `repo.rs` 95.97). New entries
  sort alphabetically BEFORE `bookmarks.rs` in each block.
- `docs/rust-error-codes.md` — `## Code Table` `:33` (rows `:42-68`), `## Adding a New Code`
  `:72-77`, the `; also emitted — Story 9.x by …` reuse annotation, and `jj.remote_exists` `:64` /
  `jj.remote_not_found` `:61` as the precedent for minting a sibling code when the REMEDY differs.
  No bookmark code exists yet.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- append two `MutateError` variants after
  `RevsetResolutionError` and before `Backend`: `BookmarkExists { name: String }`
  (`#[error("bookmark already exists: {name}")]`) and `BookmarkTrackedRemoteExists { name: String }`
  (`#[error("tracked remote bookmarks exist for deleted bookmark: {name}")]`), each with a doc
  paragraph naming the CLI refusal it mirrors and WHY it is its own variant rather than
  `InvalidInput` (the remedies differ -- the `jj.remote_exists` precedent). Widen `res` to
  `pub(crate)` so the new module classifies revision-resolution failures identically.
- `crates/zanshin-jj/src/{git,mutate}.rs` -- MOVE `struct Finished<T>` and `fn finish_or_no_op`
  from `git.rs:242-318` into `mutate.rs` as `pub(crate)`, keeping their doc comments verbatim, and
  re-point `git.rs`'s call sites. Rationale in the doc: it is the shared transaction skeleton, not a
  git concern, and two more verbs now depend on its no-op arm.
- `crates/zanshin-jj/src/bookmark_ops.rs` (new) -- module doc (CLI parity tag `v0.44.0`, the three
  ported CLI files, and the deliberate divergences listed under **Never**, explicitly including
  auto-track and the dropped ui lines), then `create` and `delete`. `create`: refuse an empty
  `names` slice and any empty name as `InvalidInput`; resolve the revision once via
  `resolve_or_wc`; run BOTH per-name preconditions in argument order fail-fast against the
  transaction's own view (`get_local_bookmark(..).is_present()`, then a local port of
  `has_tracked_remote_bookmarks` that skips the default-ignored remote `git` and requires
  `is_tracked()`); then one `set_local_bookmark_target(name, RefTarget::normal(id))` per name.
  `delete`: refuse an empty `patterns` slice as `InvalidInput`; parse each pattern with
  `jj_lib::revset::parse_string_expression` (mapping a parse failure to `InvalidInput` with jj-lib's
  reason), `StringExpression::union_all`, `to_matcher`, collect `local_bookmarks_matching` and set
  each to `RefTarget::absent()` -- an empty match set writes nothing, so `finish_or_no_op`'s no-op
  arm returns the pre-call head. Both build the CLI's exact description string with
  `RefName::as_symbol()`.
- `crates/zanshin-jj/src/repo.rs` -- add the two `#[must_use]` facades after the Story 9.7 block
  (`:1104`): `bookmark_create(&mut self, names: &[String], revision: Option<&crate::ChangeId>)` and
  `bookmark_delete(&mut self, patterns: &[String])`, each a one-line delegation to
  `crate::bookmark_ops::…(self.workspace_mut(), …)` with the house doc block -- summary naming the
  CLI verb, the no-op / pre-call-head sentence, the `-r` default, the divergences, and `# Errors`
  with one bullet per reachable variant. State in `bookmark_create`'s doc that `names` are DECODED
  names (revset quoting is terminal syntax the GUI replaces) and in `bookmark_delete`'s that a bare
  pattern is a GLOB, so a name containing `*`/`?`/`[` needs `exact:"…"`.
- `crates/zanshin-jj/src/lib.rs` -- declare `pub(crate) mod bookmark_ops;` before `bookmarks` (the
  list is strictly alphabetical and `_` sorts before `s`). No re-export: the story adds no public
  type.
- `schemas/envelope.fbs` -- append `BookmarkCreateRequest { names: [string]; revision: string; }`
  and `BookmarkDeleteRequest { names: [string]; }` after `WorkspaceRootRequest`, each with the house
  doc block: `revision` ABSENT = the CLI's `-r` default `@` (the LAST-SNAPSHOTTED working copy,
  since Zanshin never snapshots -- D2), an explicitly present EMPTY string is a VALUE and refuses;
  `BookmarkCreateRequest.names` are EXACT decoded names while `BookmarkDeleteRequest.names` are
  GLOB-by-default string PATTERNS, and an empty vector is refused in both (clap's `required = true`).
  Add the `//   Story 9-8  : …` ledger line recording that BOTH verbs reuse the shipped
  `MutationResult`, so the union is unchanged.
- `crates/zanshin-ffi/src/envelope.rs` + `src/repo.rs` -- add `JJ_BOOKMARK_EXISTS` and
  `JJ_BOOKMARK_TRACKED_REMOTE_EXISTS` consts (single-emission-point rule) and the matching
  `map_mutate_err` arms, both carrying the offending name as `context`.
- `crates/zanshin-ffi/src/bookmark_ops.rs` (new) + `lib.rs` -- the two request readers returning
  owned structs (null/verifier guards via `reject_null_request`/`invalid_request`; an absent
  `revision` stays `None`, an absent `names` vector becomes an empty `Vec` so the jj layer raises
  the one canonical refusal) and the two `extern "C"` wrappers `zanshin_bookmark_create(handle,
  data, len)` and `zanshin_bookmark_delete(handle, data, len)` returning `ok_mutation_result`, each
  with the full doc block (`# Errors` one bullet per code, `# Safety` handle + buffer + free-once).
  Extend the `RepoSession` doc's wrapper enumeration.
- `cargo make codegen` -- regenerate and commit `zanshin_ffi.h`, `envelope_generated.rs`,
  `bindings.dart` and `envelope_zanshin.ffi_generated.dart` in the same change as the `.fbs` and
  `extern "C"` edits; `cargo make verify-codegen` must then report no drift on a clean tree.
- `packages/zanshin_core/lib/src/ffi/bookmark_ops.dart` (new) -- the two request builders and the
  two adapters, decoding through the shipped `decodeMutationResultEnvelopeInternal`; interior-NUL
  guard kept here only as the direct-caller backstop.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- add
  `BookmarkCreateCommand` and `BookmarkDeleteCommand` (before `ShutdownCommand`), the aliased
  import, the two `ZanshinWorker` methods, the two switch arms with the synthesized
  `ffi.invalid_handle` envelope, and the two `RepoHandle` methods behind the `_closed` guard. Put
  the interior-NUL rejection on the CALLING side in BOTH `ZanshinWorker` and `RepoHandle`, and
  document the `ArgumentError` on both -- inside the isolate an adapter throw returns as
  `internal.dispatch_error` (the fix Stories 9.6 and 9.7 each had to make in review).
- `crates/zanshin-jj/tests/bookmark_ops.rs` (new) -- cover every jj-level row of the I/O matrix
  against `list_bookmarks` plus a raw jj-lib view oracle: seed state with
  `test_helpers::{set_local_bookmark, set_remote_bookmark}`, assert the op-log description string
  verbatim for both verbs, assert the head op id is UNCHANGED on every refusal and on the
  matched-nothing delete, and pin the two traps -- a bare delete pattern is a glob (a bookmark named
  `foo*` and one named `foo1` both match `foo*`, only the literal matches `exact:"foo*"`), and a
  tracked `name@origin` survives the local delete while an UNTRACKED same-name remote does not block
  create.
- `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` (new) -- cover the envelope/verifier contract, both
  request readers (absent-revision and malformed-buffer variants), a zero-handle assertion for BOTH
  wrappers, at least one witness per NEW error code through the wrapper itself, and one
  no-operation-written test over a refusal.
- `packages/zanshin_core/test/ffi/bookmark_ops_test.dart` +
  `packages/zanshin_core/test/worker/bookmark_ops_test.dart` (new) -- request-buffer and NUL-guard
  tests over synthetic buffers, and real-cdylib worker tests that call BOTH `extern "C"` functions
  at least once (create a bookmark, delete it, and witness one refusal end to end), carrying the
  extern-fn-guard header paragraph.
- `crates/zanshin-jj/tests/api_stability.rs` -- add the Story 9.8 alias region and a
  `bookmark_ops_surface_resolves` test pinning both `Repo` method signatures as explicit `fn`
  pointer types and asserting the `Display` of both new `MutateError` variants; note in the header
  that the type count stays 60 because the story adds no public type.
- `docs/rust-error-codes.md` -- add the two new rows (domain `jj`, meaning, "Emitted — Story 9.8"
  plus the remedy-differs rationale) and append `; also emitted — Story 9.8 by …` clauses to the
  reused rows (`ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`,
  `jj.change_not_found`, `jj.jj_lib_error`).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- flip
  `9-8-bookmark-crud-create-delete` to `done` with a summary comment in the established style,
  carrying forward the standing ledger items (`docs/ffi-abi.md` stale since 4.9, the D2 no-snapshot
  note, the structurally-interchangeable request tables) plus this story's own deferrals.

**Acceptance Criteria:**
- Given the two verbs exist, when a caller reaches them from Dart, then the whole chain is present
  for each -- `.fbs` request table, typed `zanshin-jj` op, `extern "C"` wrapper, regenerated and
  committed codegen, Dart adapter, `WorkerCommand`, `ZanshinWorker` method and `RepoHandle` method
  -- `cargo make verify-codegen` reports no drift, and `union Payload` is byte-identical to the
  baseline because both verbs reuse the shipped `MutationResult`.
- Given a bookmark is created and then deleted through the FFI path, when `jj op log` is read
  through `Repo::op_log`, then the two operations carry EXACTLY the CLI's description strings
  (`create bookmark <symbol> pointing to commit <full hex>` and `delete bookmark <symbol>`), so a
  Zanshin mutation is indistinguishable from a CLI-initiated one (NFR-R-2).
- Given any refusal from either verb, and given a `delete` whose patterns match nothing, when the
  head operation id is compared before and after, then it is unchanged and the returned
  `new_op_id` equals that pre-call head -- at both the `zanshin-jj` and the FFI layer.
- Given a repo where `foo` is deleted locally but `foo@origin` is tracked, when `bookmark_create`
  is called for `foo`, then it refuses with a code DISTINCT from the already-exists one; and given
  the same name tracked only as an untracked remote, then create SUCCEEDS -- the CLI's own
  distinction, reproduced rather than collapsed.
- Given the two new `error.code` values, when the registry is inspected, then each has a row naming
  Story 9.8 and the remedy that distinguishes it from its sibling, and each is declared exactly once
  in `crates/zanshin-ffi/src/envelope.rs`.
- Given `cargo make test` runs on the final tree, then it exits 0 -- cargo test, clippy pedantic
  `-D warnings`, rustfmt, flutter/dart analyze + format, `cargo deny`, the coverage ratchet and the
  extern-fn guard -- with no baseline entry lowered and no `exclude_prefix` added, and the raised
  `coverage-baseline.txt` is committed with the code that earned it.
- Given the working tree at the end of the run, when `git status --porcelain` is inspected, then it
  is clean and every commit message ends with the required co-author trailer.

## Spec Change Log

## Review Triage Log

### 2026-09-04 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 12: (high 0, medium 4, low 8)
- defer: 7: (high 0, medium 1, low 6)
- reject: 14
- addressed_findings:
  - `[medium]` `[patch]` Both verbs loaded the head TWICE — each read it to build its op-log
    description (create for the target's commit hex, delete for the matched names), dropped it, and
    `finish_or_no_op` then loaded again and ran the guards and writes against that second view. The
    CLI has one load per invocation, and FR-MCP-9 has an external `jj` CLI or MCP process mutating
    the same repo, so a `delete` could commit a description naming bookmarks it never touched —
    the byte-level NFR-R-2 parity the story rests on. `finish_or_no_op` split into a thin loading
    wrapper plus `finish_or_no_op_at(workspace, readonly, …)`; both verbs now load once and pass
    that repo in; `git.rs`'s four call sites untouched. The comment claiming the guard loop runs
    before the transaction (it runs inside it) was replaced by what the code does.
  - `[medium]` `[patch]` `delete_treats_a_bare_pattern_as_a_glob_and_exact_as_a_literal` passed the
    QUOTED `"foo*"` while its name, its comment and the matrix row all say BARE, so the story's
    headline trap was unproven at verb level. Now passes the bare `foo*`.
  - `[medium]` `[patch]` `revision` never crossed the Dart worker seam in a passing test: every
    create either omitted it or carried an interior NUL that the calling-side guard rejects before a
    buffer exists, so deleting `revision:` from the dispatch arm, the command or the ObjectBuilder
    left the whole gate green while `bookmark create -r <commit>` would silently target `@`. Added
    `create_carries_revision_across_the_seam_and_refuses_a_bogus_one`, modelled on
    `file_test.dart`'s own `every_verb_carries_revision_and_refuses_a_bogus_one`.
  - `[medium]` `[patch]` A malformed delete pattern shipped only the wrapper prefix plus
    `e.kind()`, which is the same "Invalid string pattern" for every bad pattern, while
    `docs/rust-error-codes.md` already claimed jj-lib's own reason reaches `context` verbatim. The
    actionable text lives behind `#[source]`; the reason is now the kind plus the FLATTENED source
    chain — deliberately not a flatten of the whole error, whose `Display` is a pest caret diagram
    (terminal rendering the GUI replaces). Exact strings asserted at both levels, including the
    no-source syntax-error case and a negative assertion that the diagram never appears.
  - `[low]` `[patch]` The comment on `has_tracked_remote_bookmarks`' `tracked` binding explained it
    by a borrow that does not exist (`.any()` consumes the iterator and yields a `bool`); it now
    names the real reason, edition-2021 tail-expression temporaries outliving block locals.
  - `[low]` `[patch]` The `# Errors` bullet said `revision` refuses when "malformed, absent,
    only-hidden, or divergent" in a paragraph where ABSENT applies the CLI's `-r` default — the
    word cannot mean both. Reworded on the three Rust surfaces plus an explicit sentence that an
    absent revision is not an error; `zanshin_ffi.h` and `bindings.dart` regenerated.
  - `[low]` `[patch]` The documented "an explicitly present EMPTY `revision` is a VALUE, not an
    absence, and refuses" had no witness anywhere; added the `Some("")` case (the docs were right).
  - `[low]` `[patch]` `create_request_bytes` always set `names: Some(...)`, so the create reader's
    documented absent-vector → empty-`Vec` path was never exercised over the wire. The builder now
    takes `Option<&[&str]>` and the test drives both wrappers.
  - `[low]` `[patch]` "Head unchanged on every refusal at BOTH layers" was asserted at the FFI layer
    for one refusal only; added the before/after `head_op_id` assertions to the tracked-remote and
    absent-names tests.
  - `[low]` `[patch]` `Finished`'s field docs still described git-only callers after the move,
    contradicting the relocation rationale; they are verb-agnostic now, with `git_import` kept as
    the named example of a caller that must branch on `committed`.
  - `[low]` `[patch]` `RevsetDiagnostics` was collected and dropped with no justification, unlike
    every other dropped-CLI-output decision in the module; the rationale is at the drop site.
  - `[low]` `[patch]` The advertised `~`/`&`/`|` pattern operators were documented on six surfaces
    and exercised nowhere; `union_matcher_supports_the_advertised_pattern_operators` covers them.

## Design Notes

**Why a new `bookmark_ops` module on both sides rather than extending `bookmarks.rs`.** The shipped
`bookmarks.rs` is a pure READ module with its own minimal `BookmarkError` (a single `Backend`
variant); the mutations return `MutationResult`/`MutateError`. Mixing them would give one module two
error taxonomies. The repo already splits exactly this way for the git domain — `remotes.rs` is the
read, `git.rs` owns `git_remote_add`/`remove`/`rename`/`set_url` — and Stories 9.11 and 9.19 add six
more bookmark mutations that need a home. Naming the module identically in `zanshin-jj` and
`zanshin-ffi` keeps the two sides greppable together.

**Why both verbs return the bare `MutationResult`.** `absorb` earned its own `AbsorbResult` because
jj-lib reported facts (skipped paths, rebase count) that no re-read can recover. Nothing comparable
exists here: which bookmarks are gone is answered by re-reading `list_bookmarks`, which is what
ADR-0002 prescribes anyway (re-resolve per operation; the op-heads watcher is the refresh trigger).
The one fact a re-read cannot supply — "did anything happen at all" — is already in the contract as
the pre-call-head `new_op_id`, which is precisely what the CLI's "No bookmarks to delete." means.

**Why names are decoded values but patterns are pass-through strings.** The CLI validates a create
name with `revset::parse_symbol`, i.e. the user must type `'foo bar'` to name a bookmark `foo bar`.
That quoting is terminal argument syntax, and ADR-0003 says the GUI replaces the terminal UX, so the
API takes the decoded value and a GUI never learns revset quoting. The empty-name refusal is kept,
because it is the one refusal `parse_symbol` makes that no spelling can get around. Delete is the
opposite case: the `glob:`/`exact:`/`regex:` prefix IS the parameter's meaning, not its spelling, so
the pattern text passes through verbatim (FR-JJ-17) and jj-lib parses it. The consequence to
document loudly: a bare delete pattern is a GLOB, so deleting a bookmark whose name contains `*`,
`?` or `[` requires `exact:"…"`.

**Why the revision is a `ChangeId` and not a revset string.** Story 9.6 fixed the rule: a parameter
whose CLI form is a SET keeps its revset string (`show`, `evolog`, `absorb --into`); a parameter
that goes through `resolve_single_rev` becomes an owned change id (`interdiff --from/--to`,
`file list -r`). `bookmark create -r` is `resolve_single_rev`, so it inherits that currency —
including the trade already documented on `FileListRequest`: a commit hex, a revset expression and a
hidden commit are not addressable, and a divergent id is refused rather than guessed.

**Traps to respect.** `set_local_bookmark_target` calls `View::add_head` for every added id, which
clears the `head_normalized` bit; `Transaction::write` asserts it is set again, but normalization
happens automatically inside `MutableRepo::consume()` — so do NOT add a manual `rebase_descendants`
or normalize call (bookmark writes produce no rewrites, and `has_rewrites()` stays false). Deleting
a local bookmark removes only remote rows that are themselves ABSENT (`view.rs:197-213`), so a
tracked `name@remote` survives by design and `list_bookmarks` keeps reporting it — that is the
"deleted, propagates on next push" state, not a leak. `has_tracked_remote_bookmarks` skips the
default-ignored remote `git`, so a colocated `foo@git` must NOT block create. And the CLI's
per-name loop is fail-fast, not validate-all: a run whose second name already exists creates
nothing, which is worth a test of its own because the intuitive "create what you can" behavior would
also pass a naive suite.

## Verification

**Commands:**
- `cargo make test` -- expected: exit 0, run unpiped (cargo test + clippy pedantic `-D warnings` +
  rustfmt + flutter/dart analyze + format + `cargo deny` + coverage ratchet + extern-fn guard). This
  is the single gate.
- `cargo make codegen` then `cargo make verify-codegen` -- expected: the second reports no drift.
  Run `verify-codegen` only on a clean tree; it refuses otherwise.
- `git -C ../jj show v0.44.0:cli/src/commands/bookmark/create.rs` (and `delete.rs`, `mod.rs`) --
  expected: re-confirms the argument arity, the `-r` default, the two create refusals, the
  glob-by-default delete patterns and both description strings before relying on the anchors above.
- `git diff --stat schemas/envelope.fbs` -- expected: additions only, all after
  `WorkspaceRootRequest`; `union Payload` untouched.
- `git status --porcelain` -- expected: clean after each commit; the four generated files appear
  only in the codegen commit.

## Auto Run Result

**Outcome:** done. Every Tasks & Acceptance item is implemented; `cargo make test` exits 0 and
`cargo make verify-codegen` reports no drift on the clean tree.

**Note on the run:** this was a RESUMED run — an interrupted earlier attempt had left most of the
work uncommitted in the tree. It was reconciled against the checklist rather than discarded; the
three suspected loose ends (a half-done `finish_or_no_op` move, an unwired `zanshin-ffi`
`bookmark_ops` module, stale codegen) all turned out to be complete already, verified by
`cargo check --all-targets`, `cargo clippy -D warnings` and a re-run of `cargo make codegen` that
produced no further diff.

**One judgement call made unattended.** Moving `Finished<T>` / `finish_or_no_op` out of `git.rs`
carried its two never-taken error branches (the `?` on `no_op_result` and on `sync_working_copy`)
into `mutate.rs`, which dropped that file's per-file coverage 97.32% → 97.16% and tripped the
ratchet — even though `git.rs` rose by exactly the same lines and the workspace total went up.
The baseline was NOT lowered and no `exclude_prefix` was added (either would have been the spec's
`blocked` condition). Instead the gap was closed by adding the test `mutate.rs` had always been
missing: `abandon`'s PLURAL op-log description (`abandon commit <first> and <n-1> more`) had no
witness at all, because every existing abandon test passes a single change id. The new test in
`crates/zanshin-jj/tests/mutate.rs` passes two ids with the CHAIN HEAD first, so it also pins that
`<first>` is argument order rather than a sorted or reversed list. `mutate.rs` ends at 97.77%.

**Deferred (recorded in `sprint-status.yaml`, not silently dropped):** no auto-tracking on create
(needs `track_remote_bookmark`, Story 9.11); no other bookmark verb (9.11 / 9.19); no MCP tool
(Epic 7); no terminal UX equivalents; plus the three standing ledger items — `docs/ffi-abi.md`
stale since 4.9, the D2 no-snapshot note, and the structurally-interchangeable request tables.

**Summary of the implemented change.** `jj bookmark create` and `jj bookmark delete` now exist as
typed verbs and reach Dart through the full chain Stories 9.3–9.7 established. Both are composed
entirely Rust-side as one transaction per call, both reuse the shipped `MutationResult` (so
`union Payload` is byte-identical to the baseline), and both carry the CLI's op-log description
byte-for-byte. Two new error codes were minted because their remedies differ (`jj.bookmark_exists`
= move it with `bookmark set`; `jj.bookmark_tracked_remote_exists` = untrack or recreate). The
shared transaction skeleton (`Finished<T>` / `finish_or_no_op`) moved out of `git.rs` into
`mutate.rs`, and after review split into a loading wrapper plus `finish_or_no_op_at` so a caller
that already holds a head-resolved repo does not load a second time.

**Files changed** (commits `93a1504` + `2bb36ac`):
- `schemas/envelope.fbs` — two request tables appended; `union Payload` untouched.
- `crates/zanshin-jj/src/bookmark_ops.rs` (new) — the two typed verbs plus name validation,
  pattern-union and description-rendering helpers.
- `crates/zanshin-jj/src/mutate.rs` — two `MutateError` variants; `Finished`/`finish_or_no_op`
  received from `git.rs` and split into `finish_or_no_op_at`; `flatten_chain` received.
- `crates/zanshin-jj/src/git.rs` — the skeleton and `flatten_chain` moved out; four call sites
  re-pointed.
- `crates/zanshin-jj/src/repo.rs`, `src/lib.rs` — the two `#[must_use]` facades and the module.
- `crates/zanshin-ffi/src/bookmark_ops.rs` (new), `src/envelope.rs`, `src/repo.rs`, `src/lib.rs` —
  the two request readers, the two `extern "C"` wrappers, the two code constants and the
  `map_mutate_err` arms.
- `packages/zanshin_core/lib/src/ffi/bookmark_ops.dart` (new) and
  `lib/src/worker/{commands,isolate,handle}.dart` — adapter, commands, worker methods, handle
  methods.
- Generated and committed via `cargo make codegen`: `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/{bindings.dart,
  envelope_zanshin.ffi_generated.dart}`.
- Tests: `crates/zanshin-jj/tests/bookmark_ops.rs` (new, 20), `crates/zanshin-ffi/tests/
  bookmark_ops_ffi.rs` (new, 8), `packages/zanshin_core/test/{ffi,worker}/bookmark_ops_test.dart`
  (new), `crates/zanshin-jj/tests/{api_stability,mutate}.rs`.
- `docs/rust-error-codes.md`, `coverage-baseline.txt`, `_bmad-output/implementation-artifacts/
  sprint-status.yaml`.

**Review findings breakdown.** 12 patches applied (0 high, 4 medium, 8 low), 7 items deferred
(1 medium, 6 low), 14 findings rejected. No intent_gap and no bad_spec, so no loopback ran
(`review_loop_iteration` stays 0). The four medium patches were the double head load, the
bare-glob test that passed a quoted pattern, the `revision` argument that never crossed the Dart
worker seam in a passing test, and the malformed-pattern reason that dropped jj-lib's actual cause.

**Follow-up review recommendation: true.** Patched this pass: high 0, medium 4, low 8 → score
`3 × 4 + 1 × 8 = 20`, which is ≥ 5.

**Verification performed.**
- `cargo make test` — exit 0, captured unpiped (`EXIT=0`), on the final commit `2bb36ac`. Overall
  coverage 99.21% (8402/8469 lines over 46 files); `coverage-check: OK`; `extern-coverage: OK`, so
  both `zanshin_bookmark_create` and `zanshin_bookmark_delete` are exercised through the real
  cdylib. No baseline entry lowered and no `exclude_prefix` added.
- `cargo make verify-codegen` — exit 0, no drift, run on the clean tree after committing.
- Targeted suites re-run: 20 tests in `crates/zanshin-jj/tests/bookmark_ops.rs` and 8 in
  `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs`, all green.
- Matrix audit: all 24 I/O & Edge-Case Matrix rows map to a named test that ran and passed.
- `git status --porcelain` — clean apart from this spec file, which is committed at finalisation.

**Residual risks.**
- The two request tables still verify interchangeably, and this is the first story where the
  colliding `names` vectors mean OPPOSITE things (exact names vs glob patterns) — deferred, above.
- `create` is not auto-tracking, which is a deliberate divergence from the CLI at v0.44.0 until
  Story 9.11 lands `track_remote_bookmark`. A user who has `auto-track-created-bookmarks` set gets
  a bookmark that the CLI would have tracked.
- The native-backend arm of `has_tracked_remote_bookmarks` runs in the Dart tests but its
  distinguishing behaviour (a tracked `name@git` DOES block create there) is unasserted.
- Both verbs are reachable only as far as `RepoHandle`; no Flutter call site exists, which is the
  scope boundary, not an omission.

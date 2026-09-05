---
title: 'Epic 9 follow-up B: the three doc/test low-hanging fruits from Story 9.8'
type: 'chore'
created: '2026-09-05'
status: 'done'
baseline_revision: 'fd79e9de69e262a7ef49ef55147343e6e5651afb'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Three entries in `deferred-work.md` § "Deferred from: bmad-build-auto runs of
Stories 9.3–9.8" § "Low-hanging fruits" are still open, and all three are cheap. (1) The
"absent revision" doc ambiguity Story 9.8 fixed on its own three surfaces survives verbatim on
the 9.3/9.4/9.6 ones: a `# Errors` bullet says a revision that is "malformed, absent,
only-hidden, or divergent" REFUSES, in doc paragraphs where ABSENT means "the user omitted it,
so apply the CLI's default" — on `interdiff` the two readings sit in ADJACENT bullets. (2) For
both bookmark verbs only `MutationResult.new_op_id` is ever asserted; the other three fields
would ship a regression green in all three test layers. (3) `has_tracked_remote_bookmarks`'s
non-git arm is executed but never asserted — on a native backend the remote matcher is
`StringMatcher::all()`, so a tracked `name@git` DOES block `create` there, the opposite of the
git-backed behaviour one existing test pins.

**Approach:** A CLOSING run that resolves exactly those three ledger bullets and nothing else.
Item 1 is comment-only: copy 9.8's already-shipped corrected wording to the 14 stale doc sites
across `zanshin-jj` (module + `Repo` facade) and `zanshin-ffi`, then run `cargo make codegen`
because FFI doc text flows into `zanshin_ffi.h` and `bindings.dart`. Items 2 and 3 are
test-only: three `MutationResult` field assertions per bookmark verb in each of the three test
layers, and one native-backend Rust test that pins the refusal the non-git matcher arm causes.

## Boundaries & Constraints

**Always:**
- Item 1 is COMMENT-ONLY. No signature, no behaviour, no error code, no `.fbs` change. The only
  non-comment diff it may produce is the regenerated `zanshin_ffi.h` / `bindings.dart` doc text
  that `cargo make codegen` derives from the edited `///` comments.
- The replacement wording is COPIED from the 9.8 surfaces, not re-invented. The two shipped
  spellings are `crates/zanshin-jj/src/bookmark_ops.rs:170-172` (jj layer) and
  `crates/zanshin-ffi/src/bookmark_ops.rs:112-115` (FFI layer); each target keeps its own
  argument names (`revision` / `from`/`to` / `from`,`into`,`changes_in`) and its own trailing
  clauses (`; the offending id in \`context\``, `(the CLI's \`-r\` refuses an ambiguous revision
  too)`), and names the CLI flag that actually applies there.
- Items 2 and 3 are TEST-ONLY. No production file is touched by them.
- Both bookmark verbs always report `new_change_ids == []`, `abandoned_change_ids == []` and
  `working_copy_change_id == @`'s change id — that is `finish_or_no_op_at`'s single construction
  site (`mutate.rs:872-882`) and `no_op_result`'s, so the assertions hold on the written AND the
  no-op path.
- Coverage may rise but never drop. Item 1 removes and adds only comment lines (not counted);
  items 2 and 3 only add tests. Never lower a `coverage-baseline.txt` entry and never add an
  `exclude_prefix`.
- `cargo make test` is the single gate, run unpiped and synchronously (allow ~8-10 min), and
  must exit 0.
- Bookkeeping is part of the run: the three ledger bullets struck through in the file's existing
  convention, and a `resolved:` block scalar added to the three matching `deferred:` items in
  `spec-9-8-bookmark-crud-create-delete.md`.
- Commits use `--no-gpg-sign` and stay on `main`.

**Block If:**
- `cargo make codegen` produces a diff in a file OTHER than `zanshin_ffi.h` / `bindings.dart`
  (i.e. a `*_generated.rs` or `*.ffi_generated.dart` moves although no `.fbs` was edited): HALT
  with `blocked`, blocking condition `unexpected codegen drift`.
- The native-backend test does NOT refuse (create succeeds with a tracked `name@git` on a native
  repo), i.e. the ledger's stated semantics are wrong: HALT with `blocked`, blocking condition
  `non-git arm behaves like the git arm`.
- The gate can only be made green by lowering a `coverage-baseline.txt` entry or adding an
  `exclude_prefix`: HALT with `blocked`, blocking condition `coverage ratchet regression`.

**Never:**
- Do NOT touch the `describe`/`new_change`/`edit`/`abandon` doc bullets
  (`zanshin-jj/src/mutate.rs:437,501,562,617`, `zanshin-jj/src/repo.rs:539,568,581,609`,
  `zanshin-ffi/src/repo.rs:685,738,773,823`) or `MutateError::ChangeNotFound`'s own variant doc
  (`mutate.rs:77-80`). Those ids are REQUIRED — there is no "omitted, so apply a default"
  reading in those paragraphs, so there is no ambiguity to fix, and `MutateError`'s variant doc
  is shared with those Story 6.1 verbs.
- Do NOT touch the sibling bullets that already read "`revision` does not resolve"
  (`file.rs:379,467,590`, `zanshin-ffi/src/file.rs:354,393,438`, and the `Repo` facade's
  `file_show`/`file_annotate`/`file_search`). They are short but not ambiguous; rewriting them
  would be widening.
- Do NOT regenerate any test fixture. `tiny-3-commits` has zero bookmarks by design; every
  bookmark/remote-bookmark state is constructed in-test via `test_helpers::set_remote_bookmark`.
- Do NOT widen: no `docs/ffi-abi.md` pass (that is a separate, still-open ledger bullet), no
  `.fbs` edit, no new error code, no new helper on any production surface, no reformatting of
  adjacent code.
- Do NOT open a new ledger entry for anything of the same shape. This run exists to leave the
  ledger SMALLER — a few-line same-shape leftover is fixed here or rejected, never deferred.
- Do NOT write a literal NUL byte (`U+0000`) into any source or spec file.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| `bookmark create` with the default revision | `bookmark_create(["feature"], None)` on `tiny-3-commits` | `MutationResult` with `new_change_ids == []`, `abandoned_change_ids == []`, `working_copy_change_id ==` the pre-call `@`'s change id, `new_op_id` = the new head | No error expected |
| `bookmark delete` that matches something | a local `feature` exists, `bookmark_delete(["exact:feature"])` | same three fields as above; `new_op_id` advances | No error expected |
| `bookmark delete` that matches nothing (no-op path) | `bookmark_delete(["nosuch"])` | `new_op_id` is the PRE-CALL head AND the other three fields hold identically (`no_op_result` builds the same shape) | Success, never a refusal |
| Same, over FFI | `zanshin_bookmark_create` / `_delete` request buffers | `MutationResult` payload whose `new_change_ids()` / `abandoned_change_ids()` are PRESENT-but-empty vectors (the builder always writes `Some(...)`), `working_copy_change_id()` == `zanshin_status`'s `working_copy_change_id` | No error expected |
| Same, through the Dart worker | `handle.bookmarkCreate([...])` / `bookmarkDelete([...])` on a native repo | `MutationResult.newChangeIds` / `.abandonedChangeIds` empty, `.workingCopyChangeId` == `handle.status().workingCopyChangeId` | No error expected |
| Tracked `name@git` on a GIT backend | `tiny-3-commits`, `set_remote_bookmark(.., "colocated", "git", .., tracked)` | `create` SUCCEEDS — the matcher negates the reserved remote `git` (already pinned by `create_is_not_blocked_by_a_tracked_remote_on_the_reserved_git_remote`) | No error expected |
| Tracked `name@git` on a NATIVE backend | `Repo::init(tmp, None)`, `set_remote_bookmark(.., "colocated", "git", .., tracked)` | `create` REFUSES with `MutateError::BookmarkTrackedRemoteExists { name: "colocated" }` and writes NO operation — `StringMatcher::all()` does not exclude `git` | This IS the assertion |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `fd79e9d`. Line numbers shift as edits land —
re-grep rather than trusting a number after the first edit in a file.

**Item 1 — the two SOURCE spellings to copy (read-only, do not edit)**

- `crates/zanshin-jj/src/bookmark_ops.rs:170-172` — the jj-layer form:
  ``- [`MutateError::ChangeNotFound`] — `revision` is malformed, carried by no VISIBLE commit
  (unknown or only-hidden), or divergent. Not to be confused with an ABSENT `revision`, which is
  not an error at all: it applies the CLI's `-r` default `@`.``
- `crates/zanshin-ffi/src/bookmark_ops.rs:112-115` — the FFI-layer form:
  ``- `jj.change_not_found` — `revision` is malformed, carried by no VISIBLE commit (unknown or
  only-hidden), or divergent; the id in `context`. An ABSENT `revision` is not an error — it is
  what applies the CLI's `-r` default `@`. …``
- `crates/zanshin-jj/src/repo.rs:1133-1137` — the facade form Story 9.8 shipped for
  `bookmark_create`; the model for the four facade edits below.

**Item 1 — the 14 sites to rewrite** (every one is the literal substring
`malformed, absent, only-hidden, or divergent`, possibly line-wrapped; grep for `only-hidden`):

- `crates/zanshin-jj/src/file.rs:160-162` — `FileError::ChangeNotFound` variant doc ("The
  `revision` argument is malformed, absent, only-hidden, or DIVERGENT — …"). Serves all four
  file verbs, whose `revision: Option<&ChangeId>` defaults to `@` (`head_commit`, `:241-246`).
- `crates/zanshin-jj/src/file.rs:294-295` — `file_list`'s `# Errors`.
- `crates/zanshin-jj/src/mutate.rs:912-913` — `restore`'s `# Errors`; `from`/`into`/`changes_in`
  are all `Option` and their defaults are spelled out at `:888-894` of the same doc block.
- `crates/zanshin-jj/src/mutate.rs:1044-1045` — `absorb`'s `# Errors`; `from` is `Option`,
  default `@` (`:1024-1025`).
- `crates/zanshin-jj/src/commit_views.rs:110-112` — `CommitViewError::ChangeNotFound` variant
  doc; it names `interdiff`'s `from`/`to` explicitly.
- `crates/zanshin-jj/src/commit_views.rs:382-383` — `interdiff`'s `# Errors`. **The sharpest
  case:** the bullet right above it (`:380-381`) uses "absent" for OMITTED, this one for
  UNRESOLVABLE.
- `crates/zanshin-jj/src/repo.rs:281-282` — `Repo::file_list` (keeps its "(the CLI's `-r`
  refuses an ambiguous revision too)" clause).
- `crates/zanshin-jj/src/repo.rs:1029-1030` — `Repo::interdiff` (again directly under an
  omitted-means-absent bullet at `:1027-1028`).
- `crates/zanshin-jj/src/repo.rs:1213-1214` — `Repo::restore`.
- `crates/zanshin-jj/src/repo.rs:1286-1287` — `Repo::absorb`.
- `crates/zanshin-ffi/src/file.rs:306` — `zanshin_file_list`.
- `crates/zanshin-ffi/src/commit_views.rs:325-326` — `zanshin_interdiff`.
- `crates/zanshin-ffi/src/repo.rs:968-969` — `zanshin_restore`. Its own prose at `:950-953`
  already says "An ABSENT string is the wire form of 'the user did not supply it'", so the file
  currently contradicts itself 15 lines apart.
- `crates/zanshin-ffi/src/repo.rs:1030` — `zanshin_absorb`.

Generated outputs that must be regenerated and committed (never hand-edited):
`crates/zanshin-ffi/include/zanshin_ffi.h` (lines 536, 652, 1532 carry the four FFI bullets) and
`packages/zanshin_core/lib/src/ffi/bindings.dart` (lines 76, 480, 930). `cargo make codegen`
also re-runs `flatc`; with no `.fbs` edit those outputs must come back byte-identical.

**Item 2 — `MutationResult`'s other three fields, in three layers**

- `crates/zanshin-jj/src/mutate.rs:39-71` — the struct; `:872-882` is `finish_or_no_op_at`'s
  committed-path construction (`new_change_ids: Vec::new()`, `abandoned_change_ids: Vec::new()`,
  `working_copy_change_id` from `sync_working_copy`'s returned `@`), `:848-854` the no-op path
  via `no_op_result`. Both bookmark verbs go through this single site, so the expectation is
  structural, not incidental.
- `crates/zanshin-jj/tests/bookmark_ops.rs` — the jj layer. Targets:
  `create_with_the_default_revision_targets_at_and_writes_the_cli_description` (`:142-164`),
  `delete_removes_an_exactly_named_bookmark_with_the_cli_description` (`:388-405`), and
  `delete_matching_nothing_writes_no_operation_and_returns_the_pre_call_head` (`:457-468`, the
  no-op path). Existing scaffolding to reuse: `layout()` (`:79-95`) gives `wc_commit_hex`, and
  `change_id_of(root, hex)` (`:98-104`) turns it into the `ChangeId` to compare against. Add a
  small shared assertion helper rather than repeating three `assert!`s per test.
- `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs:216-246` —
  `create_then_delete_round_trips_through_mutation_result`; `created` is already bound at `:230`,
  the delete envelope is parsed at `:240-242` but its payload is never bound. Reuse
  `wc_commit_hex`'s first half (`:165-178`) — `zanshin_status`'s `working_copy_change_id` IS the
  expected value — by extracting a `wc_change_id(handle)` helper it can call. The vectors are
  always PRESENT: `envelope.rs:303-314` writes `Some(vec)` even when empty, so the assertion is
  `Some(&[])`-shaped, not `None`.
- `packages/zanshin_core/test/worker/bookmark_ops_test.dart:44-57` —
  `create_then_delete_round_trips_through_the_real_cdylib`, the real-cdylib layer. `MutationResult`
  (`lib/src/ffi/mutate.dart:145-168`) exposes `newChangeIds`, `abandonedChangeIds`,
  `workingCopyChangeId`. The oracle is `handle.status()` (`lib/src/worker/handle.dart:81-86`) →
  `WorkingCopyStatus.workingCopyChangeId` (`lib/src/ffi/status.dart:36`).
  **Not** `test/ffi/bookmark_ops_test.dart` — that file builds synthetic buffers and boots no
  repo, so it has no real `MutationResult` to assert.

**Item 3 — the native-backend refusal**

- `crates/zanshin-jj/src/bookmark_ops.rs:79-96` — `has_tracked_remote_bookmarks`. Git backend →
  `StringExpression::exact(REMOTE_NAME_FOR_LOCAL_GIT_REPO).negated()`; otherwise
  `StringMatcher::all()`. `create` calls it at `:216-220` and returns
  `MutateError::BookmarkTrackedRemoteExists`.
- `crates/zanshin-jj/tests/bookmark_ops.rs:242-256` —
  `create_is_not_blocked_by_a_tracked_remote_on_the_reserved_git_remote`, the git-backed twin the
  new test is the mirror of. Place the new test immediately after it.
- `crates/zanshin-jj/tests/bookmark_ops.rs:261-280` — the refusal shape to copy: `matches!(&err,
  MutateError::BookmarkTrackedRemoteExists { name } if name == …)` plus `assert_eq!(head_op(&repo).0,
  before)` ("refused" and "refused without writing an operation" are different claims).
- `Repo::init(tmp.path(), None)` is the native backend (`crates/zanshin-jj/src/repo.rs:1347-1364`,
  `Workspace::init_simple`). `tempfile` is already a dev-dep; `tests/change.rs:413` and
  `tests/status.rs:198` are the in-file precedent for `TempDir::new()` + `Repo::init(.., None)`.
  `tests/bookmark_ops.rs` does not import `TempDir` yet — add `use tempfile::TempDir;`.
- `crates/test-helpers/src/lib.rs:447-467` — `set_remote_bookmark(root, name, remote, target,
  tracked)`; backend-agnostic (`load()` at `:119-130` uses `default_backend_factories`), so it
  works unchanged on a native repo. The `target` argument is a commit HEX — take it from
  `layout(&root).wc_commit_hex`, which also works on a freshly inited native repo.

**Bookkeeping targets**

- `_bmad-output/implementation-artifacts/deferred-work.md:222, 224, 226` — the three bullets, in
  that order (doc ambiguity, `MutationResult` fields, non-git arm). Convention to follow is the
  same file's `:216`-`:220` shape: `~~**title**~~ **RESOLVED 2026-09-05 (<spec slug>, commit
  <short hash>)** [locations] — <original body, kept verbatim as the audit trail>
  **Resolution:** <what was done>`. Leave `:214` (`docs/ffi-abi.md`) and `:228` (`FileSearch`
  `skipped`) untouched and the section preamble intact — this run closes three of the section's
  bullets, not the section.
- `_bmad-output/implementation-artifacts/spec-9-8-bookmark-crud-create-delete.md:66-95` — the
  three `deferred:` items that still lack a `resolved:` field: the non-git arm (`:66-75`),
  `MutationResult`'s three fields (`:76-84`), and the absent-revision doc ambiguity (`:85-95`).
  Each gains a `resolved: >-` block scalar in the shape `:35-45` already uses. Keep the YAML
  valid; leave the `docs/ffi-abi.md` item (`:96-103`) and the schema-collision item (`:12-24`)
  alone.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/{file,mutate,commit_views,repo}.rs` -- rewrite the ten stale
  `# Errors` / variant-doc bullets listed in the Code Map so each says the revision is
  "malformed, carried by no VISIBLE commit (unknown or only-hidden), or divergent" and adds the
  explicit "an ABSENT `<arg>` is not an error — it applies the CLI's `<flag>` default" clause,
  keeping each site's own argument names and trailing clauses. -- the same paragraph currently
  uses "absent" for two opposite things, and on `interdiff` in adjacent bullets.
- `crates/zanshin-ffi/src/{file,commit_views,repo}.rs` -- the same rewrite on the four
  `extern "C"` wrapper bullets, in the FFI spelling (`jj.change_not_found`, `; the offending id
  in \`context\`` where the site already has it). -- this text IS the shipped C header and Dart
  doc comment; `zanshin_restore` currently contradicts its own prose 15 lines above.
- `crates/zanshin-ffi/include/zanshin_ffi.h` + `packages/zanshin_core/lib/src/ffi/bindings.dart`
  -- regenerate via `cargo make codegen` (never by hand) and commit alongside the source edit.
  Verify no other generated file moved. -- generated output is committed and must not drift.
- `crates/zanshin-jj/tests/bookmark_ops.rs` -- add the three `MutationResult` field assertions to
  the create happy path, the delete happy path AND the delete-matches-nothing no-op path, via one
  local helper that takes the result and the expected working-copy `ChangeId`. -- `new_op_id` is
  the only field any test reads today, so a regression in the other three ships green.
- `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` -- in
  `create_then_delete_round_trips_through_mutation_result`, bind the delete payload too and
  assert on BOTH payloads that `new_change_ids()` and `abandoned_change_ids()` are present and
  empty and that `working_copy_change_id()` equals the value `zanshin_status` reports; extract
  the change-id read out of `wc_commit_hex` into a reusable helper. -- the wire contract's three
  unasserted columns.
- `packages/zanshin_core/test/worker/bookmark_ops_test.dart` -- in
  `create_then_delete_round_trips_through_the_real_cdylib`, assert `newChangeIds` and
  `abandonedChangeIds` are empty and `workingCopyChangeId` equals `handle.status()`'s, for both
  the create and the delete result. -- the decoder maps four fields; one is witnessed.
- `crates/zanshin-jj/tests/bookmark_ops.rs` -- add ONE native-backend test next to
  `create_is_not_blocked_by_a_tracked_remote_on_the_reserved_git_remote`: `Repo::init(TempDir,
  None)`, seed a TRACKED `colocated@git` via `set_remote_bookmark`, assert `bookmark_create`
  refuses with `BookmarkTrackedRemoteExists` and the head operation is unchanged. Name it so the
  contrast with its git-backed twin is visible, and comment WHY the two differ. -- the matcher's
  `else` arm is executed by nothing that asserts, so deleting it would leave the gate green.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- strike through the three bullets in
  the file's existing convention with the RESOLVED stamp, the preserved original body and a
  trailing `**Resolution:**` sentence each. -- the ledger is the audit trail; a closed item that
  still reads as open is worse than no ledger.
- `_bmad-output/implementation-artifacts/spec-9-8-bookmark-crud-create-delete.md` -- add a
  `resolved: >-` block scalar to the three matching `deferred:` items, keeping the YAML valid.
  -- the originating spec's frontmatter is the per-story evidence trail.

**Acceptance Criteria:**
- Given the repo, when `crates/` is grepped for `malformed, absent, only-hidden, or divergent`
  and for `absent,\n///   only-hidden`, then the only remaining hits are the twelve
  `describe`/`new_change`/`edit`/`abandon` bullets (four in `zanshin-jj/src/mutate.rs`, four in
  `zanshin-jj/src/repo.rs`, four in `zanshin-ffi/src/repo.rs`) plus
  `zanshin-jj/src/change.rs:158` — and none in `file.rs`, `commit_views.rs`, or the
  `restore`/`absorb`/`interdiff`/`file_list` bullets of either `repo.rs`.
- Given the doc edit is committed, when `git diff --stat` for that commit is read, then the only
  non-`.rs` files in it are `crates/zanshin-ffi/include/zanshin_ffi.h` and
  `packages/zanshin_core/lib/src/ffi/bindings.dart`, and no `*_generated.rs`,
  `*.ffi_generated.dart` or `schemas/*.fbs` appears.
- Given the three test layers, when each is grepped for `abandoned_change_ids` /
  `abandonedChangeIds`, then each of `crates/zanshin-jj/tests/bookmark_ops.rs`,
  `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` and
  `packages/zanshin_core/test/worker/bookmark_ops_test.dart` has at least one hit inside a
  bookmark create AND a bookmark delete assertion.
- Given the new native-backend test is deliberately broken by replacing `StringMatcher::all()`
  with the git arm's negated matcher, when `cargo test -p zanshin-jj --test bookmark_ops` runs,
  then that test FAILS — i.e. it genuinely pins the arm rather than passing incidentally. (Revert
  the probe immediately; it is a check, not a change.)
- Given a clean tree, when `cargo make test` runs unpiped, then it exits 0 and no
  `coverage-baseline.txt` entry is lower than at baseline `fd79e9d`.
- Given the run is finished, when `deferred-work.md` is read, then exactly three further bullets
  of the Stories 9.3–9.8 "Low-hanging fruits" subsection are struck through with a resolution
  line naming this spec's slug and a commit, the `docs/ffi-abi.md` and `FileSearch` bullets are
  untouched, and no new section has been added for this run.

## Spec Change Log

## Review Triage Log

## Design Notes

**Why the `Repo` facade docs are in scope although the ledger names only the modules.** The
ledger bullet points at `file.rs` "and the sibling `restore`/`absorb`/`interdiff` docs it was
copied from". The identical sentence exists at three layers per verb — private module doc,
public `Repo` facade doc, `extern "C"` wrapper doc — and Story 9.8 corrected all three of its
own (`bookmark_ops.rs`, `repo.rs:1135`, `zanshin-ffi/src/bookmark_ops.rs`). The facade is the
rustdoc a consumer actually reads; fixing the private module doc and leaving the public one
ambiguous would mark the item resolved while the grievance stands. The intent's explicit mention
of the FFI layer ("including the matching `extern \"C\"` wrapper docs") is the same reasoning
applied to the third layer.

**Why `MutateError::ChangeNotFound`'s variant doc stays.** Unlike `FileError`'s and
`CommitViewError`'s, that variant is shared with `describe`/`new_change`/`edit`/`abandon`, whose
ids are REQUIRED. Its wording ("No change exists for a given id") already presupposes an id was
given, so it carries no default-vs-unresolvable ambiguity to fix, and rewriting it would put a
file-verb-specific clause on a variant four required-id verbs also raise.

**Why the no-op delete gets the field assertions too.** `finish_or_no_op_at` has two exits — the
committed one at `mutate.rs:872-882` and `no_op_result` at `:848-854` — and only the first is
covered by the happy-path tests. The three fields are supposed to be identical on both, which is
precisely the kind of claim that is true by construction today and silently false after a
refactor.

**Shape of the jj-layer helper** (one definition, three call sites; keeps each test's own
assertions readable):

```rust
/// Both bookmark verbs mint and abandon nothing, and never move `@` — asserted on every
/// path because `new_op_id` is the only field the rest of this suite reads.
fn assert_no_change_churn(result: &zanshin_jj::MutationResult, expected_wc: &ChangeId) {
    assert!(result.new_change_ids.is_empty(), "a bookmark verb mints no change");
    assert!(result.abandoned_change_ids.is_empty(), "a bookmark verb abandons no change");
    assert_eq!(&result.working_copy_change_id, expected_wc, "`@` does not move");
}
```

## Verification

**Commands:**
- `cargo make codegen` -- expected: exits 0; afterwards `git status --porcelain` shows only
  `crates/zanshin-ffi/include/zanshin_ffi.h` and
  `packages/zanshin_core/lib/src/ffi/bindings.dart` among generated files.
- `git status --porcelain -- 'crates/zanshin-ffi/src/*_generated.rs' 'packages/zanshin_core/lib/src/ffi/*.ffi_generated.dart' schemas/`
  -- expected: empty after codegen.
- `grep -rn "only-hidden" crates/zanshin-jj/src/ crates/zanshin-ffi/src/` -- expected: no hit in
  `file.rs` or `commit_views.rs` of either crate still reads "malformed, absent, only-hidden";
  the surviving `absent, only-hidden` hits are only the four `mutate.rs` and eight `repo.rs`
  required-id bullets plus `change.rs:158`.
- `cargo test -p zanshin-jj --test bookmark_ops` -- expected: all tests pass, including the new
  native-backend one; then temporarily flip `has_tracked_remote_bookmarks`'s `else` arm to the
  git matcher and confirm ONLY the new test fails, and revert.
- `cargo make test` -- expected: exit 0. Run unpiped and synchronously, allow ~8-10 minutes
  (cargo test + clippy pedantic `-D warnings` + rustfmt + `flutter test` + dart analyze/format +
  `cargo deny` + the coverage ratchet). The single gate.
- `git status --porcelain` -- expected: clean after each commit.

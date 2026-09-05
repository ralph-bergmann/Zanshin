---
title: 'Epic 9 follow-up B: the three doc/test low-hanging fruits from Story 9.8'
type: 'chore'
created: '2026-09-05'
status: 'done'
baseline_revision: 'fd79e9de69e262a7ef49ef55147343e6e5651afb'
review_loop_iteration: 0
followup_review_recommended: true
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
`crates/zanshin-ffi/include/zanshin_ffi.h` and
`packages/zanshin_core/lib/src/ffi/bindings.dart` — FOUR bullets move in each, one per wrapper
(`zanshin_interdiff`, `zanshin_file_list`, `zanshin_restore`, `zanshin_absorb`). Locate them by
verb, not by line: the single-line grep that first produced this list returned only three anchors
per file because `zanshin_restore`'s bullet is line-wrapped. `cargo make codegen`
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
- Given the repo, when `crates/` is grepped for the one-line form
  (`grep -rn "malformed, absent, only-hidden, or divergent" crates/`) and for the line-wrapped one
  (`grep -rn -A 1 "is malformed, absent,$" crates/zanshin-jj/src crates/zanshin-ffi/src`, since a
  plain `grep` is line-oriented and cannot match across the wrap), then the only remaining hits
  are the twelve
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

### 2026-09-05 — Doc scope extended beyond the 14 enumerated sites

**Trigger.** Item 3's new native-backend test (`create_is_blocked_by_a_tracked_git_remote_on_a_native_backend`)
falsified five doc statements that were not on the Code Map's 14-site list, because all five assert
UNCONDITIONALLY that a colocated `name@git` never blocks `create` / never produces
`jj.bookmark_tracked_remote_exists`: `Repo::bookmark_create`'s facade doc
(`crates/zanshin-jj/src/repo.rs`), `has_tracked_remote_bookmarks`' own doc
(`crates/zanshin-jj/src/bookmark_ops.rs`), `MutateError::BookmarkTrackedRemoteExists`
(`crates/zanshin-jj/src/mutate.rs`), `JJ_BOOKMARK_TRACKED_REMOTE_EXISTS`
(`crates/zanshin-ffi/src/envelope.rs`) and the canonical registry row in `docs/rust-error-codes.md`.

**Amendment.** All five qualified as GIT-backend-specific, in the same shape. No behaviour, no
signature, no error code, no `.fbs` — comment-only, like item 1.

**Authority and bound.** The intent's closing-run rule ("a few-line same-shape leftover is fixed
here or rejected, never deferred") plus the ban on new ledger entries. The extension is bounded to
statements THIS RUN'S OWN NEW TEST falsifies — nothing was rewritten merely for being terse,
inconsistent or stale, which is what kept `MutateError`'s enum-level header, `resolve_commit`'s
doc and the `file_show`/`file_annotate`/`file_search` siblings out.

**Known-bad state avoided.** Marking item 3 resolved while the registry `docs/rust-error-codes.md`
— which `project-context.md` makes authoritative for error codes — still told a reader the
refusal cannot happen, in the same commit range that added the test proving it can.

## Review Triage Log

### 2026-09-05 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 3: (high 0, medium 3, low 0)
- defer: 0
- reject: 21: (high 0, medium 0, low 21)
- addressed_findings:
  - `[medium]` `[patch]` The no-op exit's three `MutationResult` fields were witnessed at the jj
    layer only, while both ledger entries claimed all three layers — and the present-but-empty
    property the matrix's FFI row singles out is only representable at the FlatBuffers surface,
    exactly the surface left unwitnessed. Added the churn-helper call to the pre-existing no-op
    tests in `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` and
    `packages/zanshin_core/test/worker/bookmark_ops_test.dart` (one call each; both helpers were
    already file-scoped and in scope). The bookkeeping prose is now true as written.
  - `[medium]` `[patch]` `create_is_blocked_by_a_tracked_git_remote_on_a_native_backend`'s own
    doc comment inverted the fact it pins ("that `else` arm is executed by the git-backed tests"
    — they take the `if` arm; and deleting the arm would not compile, so it could not "leave the
    suite green"). Rewritten to say what is true: the `else` arm was reached only by the
    native-backend Dart worker tests, none of which assert the difference. A false comment is
    self-undermining in a run whose subject is comment accuracy.
  - `[medium]` `[patch]` `Repo::bookmark_create`'s rustdoc claimed unconditionally that a
    colocated `name@git` does NOT count. The run's own new test proves that false on a native
    backend. Qualified to "on a GIT-backed repo", naming the git-specific exclusion. A second
    review pass established that the same now-falsified claim survived at FOUR further sites —
    `has_tracked_remote_bookmarks`' own doc (whose opening and closing sentences are
    unconditional; only its middle clause was qualified), `MutateError::BookmarkTrackedRemoteExists`,
    `envelope.rs::JJ_BOOKMARK_TRACKED_REMOTE_EXISTS` and the canonical `docs/rust-error-codes.md`
    registry row. All four are now qualified in the same shape; see the Spec Change Log for the
    scope authority and its bound.

### 2026-09-05 — Review pass (second, parent-run, over the same diff)

- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 3, low 4)
- defer: 0
- reject: 19: (high 0, medium 0, low 19)
- addressed_findings:
  - `[medium]` `[patch]` Both NO-OP tests read the `@` oracle AFTER the mutation, so a regression
    that moved `@` would shift both sides of the comparison equally and still pass — and that is
    the one of the three fields not empty-by-construction. Both now bind the oracle before the
    delete (`crates/zanshin-ffi/tests/bookmark_ops_ffi.rs`,
    `packages/zanshin_core/test/worker/bookmark_ops_test.dart`).
  - `[medium]` `[patch]` FOUR further copies of the colocated-`name@git` claim the first pass
    corrected on the facade survived, all unconditional and all falsified by this run's own new
    test: `has_tracked_remote_bookmarks`' doc, `MutateError::BookmarkTrackedRemoteExists`,
    `envelope.rs::JJ_BOOKMARK_TRACKED_REMOTE_EXISTS` and the canonical `docs/rust-error-codes.md`
    row — the last the worst, since `project-context.md` makes that registry authoritative. All
    qualified as git-backend-specific; the first pass's own triage claim that "the private
    helper's doc was already correctly qualified" was false and is corrected above.
  - `[medium]` `[patch]` Bookkeeping written by this run was inaccurate about this run: item 3's
    `resolved:` block claimed "no production file was touched" (four were, all comment-only), the
    ledger's item-3 resolution omitted the doc corrections, and `## Spec Change Log` was empty
    although a real scope extension had happened. All three corrected; the change-log entry
    records the trigger, the amendment and the bound.
  - `[low]` `[patch]` Both `working_copy_change_id` assertions could pass vacuously on an empty
    oracle (the Dart decoder null-coalesces to `''`; `wc_change_id` guarded only `None`).
    Non-emptiness guards added inside `expectNoChangeChurn` and `wc_change_id`.
  - `[low]` `[patch]` Acceptance Criterion 1 told a re-verifier to grep `absent,\n///   only-hidden`,
    which line-oriented `grep` cannot match. Reworded to the runnable `grep -A 1` form, same
    expected outcome.
  - `[low]` `[patch]` The Code Map listed three anchors per generated file where FOUR bullets move
    — the single-line grep that produced the list missed `zanshin_restore`'s wrapped bullet.
    Replaced the line numbers with the four verb names.
  - `[low]` `[patch]` "Not to be confused with the ABSENT of the bullet above" is not English, and
    it sat on `interdiff` in both `crates/zanshin-jj/src/commit_views.rs` and
    `crates/zanshin-jj/src/repo.rs` — the sharpest site in the whole item. Reworded to the
    parallel FFI site's grammatical form.
  - `[low]` `[patch]` The ledger's item-2 resolution said the no-op exit "was not covered"; it was
    covered for `new_op_id` by the pre-existing tests — what was missing were the other three
    fields on that exit. Qualifier restored (the Design Notes already had it right).

Rejection note for the SECOND pass (19, all low; scope authority is the intent itself). Rejected as
already-witnessed or by-design: the claim that item 1's new doc text has no executable witness (the
absent-revision defaults are exercised by the pre-existing `file_reads.rs::file_list(None, &[])` and
`content_ops.rs`'s four `restore(None, …)` cases); the `--changes-in`-has-no-default objection (an
absent `changes_in` does default the destination to `@`, and the sentence explicitly defers to the
resolution paragraph above it); `change.rs:158` keeping the phrase (a REQUIRED id, the same
exclusion the first pass drew); `cargo make verify-codegen` not being a gate step (a deliberate WIP
deferral recorded in `project-context.md`). Rejected as beyond the intent's own naming: asserting
the churn helper on every remaining create/delete test (the intent says "for both `bookmark create`
and `bookmark delete`", and all three fields are empty by construction at a single site); an
FFI/Dart counterpart for item 3 (the intent says "one native-backend Rust test"); a
present-but-EMPTY-revision-string clause on the four rewritten FFI bullets (the intent quotes the
specific clause to copy); a `docs/ffi-abi.md` pass (a separate, still-open ledger bullet the intent
excludes); homing this run's residual risks in `deferred-work.md` (the intent forbids opening a new
entry). Rejected as noise: the new test seeding after `Repo::init` (forced — the repo must exist
before it can be seeded, and a moved load point would FAIL the test, not silently pass); its lack of
a positive control (the unchanged head operation is the state witness, and the independently re-run
mutation probe is the control); the two `assert_no_change_churn` helpers differing in assertion
style; the connectors differing between layers (each layer copies its own Story 9.8 source spelling,
which the spec mandates); the wrapped em dash reading as a list marker in the generated header
(cosmetic, and rewording would churn generated output for no semantic gain); and the four purely
descriptive intent-alignment observations, which the auditor's own mandate marks as non-prescriptive.

Rejection note (scope authority is the intent itself; applies to the FIRST pass): the largest rejected cluster is doc sites
the intent enumerates and excludes by name — `MutateError::ChangeNotFound`'s variant doc, the
twelve `describe`/`new_change`/`edit`/`abandon` bullets, and the "does not resolve" siblings on
`file_show`/`file_annotate`/`file_search`. A reviewer disputed the exclusion's *reasoning* for the
`MutateError` variant (`restore`/`absorb` do reach it through `Option` arguments), but the intent's
instruction there is unambiguous, so this is not an intent gap. Un-enumerated doc staleness of a
DIFFERENT shape (e.g. `MutateError`'s enum-level header listing four of its six producers) was
rejected under "Do NOT widen" rather than deferred, per the intent's ban on opening new ledger
entries. The line drawn for the three patches above: a statement this change's own new test
actively falsifies is caused by the change; pre-existing unrelated staleness is not.

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

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** A closing run that resolved exactly the three open "Low-hanging fruits" bullets from
the Stories 9.3-9.8 section of `deferred-work.md`, and nothing else. (1) The "absent revision" doc
ambiguity Story 9.8 fixed on its own surfaces was copied to the 14 stale sites — `file_list`,
`interdiff`, `restore`, `absorb` at all three layers each (module doc, `Repo` facade doc,
`extern "C"` wrapper doc) plus `FileError`'s and `CommitViewError`'s own `ChangeNotFound` variant
docs — with each site keeping its own argument names, trailing clauses and CLI flag. Comment-only;
`zanshin_ffi.h` and `bindings.dart` regenerated via `cargo make codegen`. (2) `MutationResult`'s
three previously-unasserted fields are now witnessed by one helper per test layer, on the create
happy path, the delete happy path AND delete's no-op path, at all three layers. (3) The non-git arm
of `has_tracked_remote_bookmarks` is pinned by a native-backend test that asserts the refusal its
git-backed twin does not get.

**Files changed**

- `crates/zanshin-jj/src/{file,commit_views,mutate,repo}.rs` — the ten stale jj-layer doc bullets
  rewritten.
- `crates/zanshin-ffi/src/{file,commit_views,repo}.rs` — the four `extern "C"` wrapper bullets, in
  the FFI spelling.
- `crates/zanshin-jj/src/{repo,bookmark_ops,mutate}.rs`, `crates/zanshin-ffi/src/envelope.rs`,
  `docs/rust-error-codes.md` — the five unconditional colocated-`name@git` claims this run's own
  new test falsified, qualified as git-backend-specific (review; see the Spec Change Log).
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` —
  regenerated doc text; no other generated output moved.
- `crates/zanshin-jj/tests/bookmark_ops.rs` — the `assert_no_change_churn` helper on three paths,
  plus `create_is_blocked_by_a_tracked_git_remote_on_a_native_backend`.
- `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` — `wc_change_id` extracted as the oracle; the
  wire-level churn helper on the round trip and the no-op test.
- `packages/zanshin_core/test/worker/bookmark_ops_test.dart` — `expectNoChangeChurn` on the round
  trip and the no-op test.
- `_bmad-output/implementation-artifacts/deferred-work.md`,
  `_bmad-output/implementation-artifacts/spec-9-8-bookmark-crud-create-delete.md` — bookkeeping.

**Review findings breakdown.** Two review passes over the same diff. First pass: 3 patches applied
(all medium), 0 deferred, 21 rejected. Second (parent-run) pass: 7 patches applied (3 medium,
4 low), 0 deferred, 19 rejected. Neither pass found an intent gap or triggered a spec repair
loopback, so `review_loop_iteration` stayed at 0. Both passes are itemised in the triage log; the
one scope extension either produced is recorded in the Spec Change Log. **0 items deferred across
both passes** — the closing mandate held, and this run's own section of `deferred-work.md` does not
exist because it opened none.

**Follow-up review recommendation:** `true`. Counting only THIS (second) pass's patched findings, as
the rule requires: high 0, medium 3, low 4. Score = 3 x 3 + 1 x 4 = 13, which is >= 5. (The first
pass computed 9 on its own three medium patches; the recommendation was `true` after either pass.)
Both passes were doc, comment, bookkeeping and test-assertion corrections — no `high` finding, and
no reviewer in either pass found the shipped behaviour wrong, which is unchanged by construction:
the whole change is comments plus tests.

**Verification performed**

- `cargo make codegen` — exit 0, run twice (after the doc edit and again after the review patches).
  Only `zanshin_ffi.h` and `bindings.dart` ever moved; `git status --porcelain` scoped to
  `*_generated.rs`, `*.ffi_generated.dart` and `schemas/` was empty both times. Block-If
  `unexpected codegen drift` did not trigger.
- Stale-phrase greps — the literal `malformed, absent, only-hidden, or divergent` and the
  line-wrapped `absent,` / `only-hidden` form now hit only the twelve required-id
  `describe`/`new_change`/`edit`/`abandon` bullets (four in `zanshin-jj/src/mutate.rs`, four in
  `zanshin-jj/src/repo.rs`, four in `zanshin-ffi/src/repo.rs`) plus `zanshin-jj/src/change.rs:158`.
  No hit remains in `file.rs` or `commit_views.rs` of either crate.
- `cargo test -p zanshin-jj --test bookmark_ops` — 21 passed. Mutation probe re-run independently of
  the implementation: replacing `StringMatcher::all()` with the git arm's negated matcher failed
  exactly one test, the new native-backend one; probe reverted and `git diff` confirmed empty. The
  ledger's stated semantics were confirmed, so Block-If `non-git arm behaves like the git arm` did
  not trigger.
- `cargo make test` — run unpiped and synchronously FOUR times in total, exit 0 every time:
  after the doc edit, after the first pass's patches, then twice more re-run independently by the
  parent run (once on the as-committed tree before the second review pass, once after the second
  pass's seven patches — `Build Done in 566.94 seconds`, zero `FAILED` lines, all Dart suites
  `All tests passed!` at 312 tests). `coverage-check: OK — coverage held at 99.20% (8315/8382 lines
  over 46 files)` and `extern-coverage: OK` on every run; `coverage-baseline.txt` is byte-unchanged
  from baseline `fd79e9d`, so the ratchet neither regressed nor auto-raised, no `exclude_prefix` was
  added, and Block-If `coverage ratchet regression` did not trigger.
- Independent re-verification by the parent run (not inherited from the implementation): the
  codegen drift check was re-run on the clean committed tree and produced NO diff at all, proving
  the committed `zanshin_ffi.h` / `bindings.dart` are exactly what `cargo make codegen` generates;
  the stale-phrase greps were re-executed; and the mutation probe was performed a second time from
  scratch — flipping `has_tracked_remote_bookmarks`' `else` arm to the git matcher failed exactly
  one test (`create_is_blocked_by_a_tracked_git_remote_on_a_native_backend`, `unwrap_err()` on an
  `Ok`), with the other 20 green, and `git status` was empty after reverting the probe.
- Matrix test audit — all seven rows have a covering test that ran and passed, confirmed by name in
  the gate's own output rather than inferred from the aggregate: rows 1/2/3/6/7 in
  `crates/zanshin-jj/tests/bookmark_ops.rs`, row 4 in `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs`
  (`create_then_delete_round_trips_through_mutation_result`,
  `delete_matching_nothing_succeeds_with_the_pre_call_head`), row 5 in
  `packages/zanshin_core/test/worker/bookmark_ops_test.dart`
  (`create_then_delete_round_trips_through_the_real_cdylib`,
  `delete_matching_nothing_succeeds_and_writes_no_operation`).
- `git status --porcelain` — clean after each commit.

**Residual risks**

- The Dart decoder null-coalesces `newChangeIds` / `abandonedChangeIds` to `const []` and
  `workingCopyChangeId` to `''`, so `expectNoChangeChurn` cannot tell a present-but-empty vector
  from an absent one. That distinction is pinned one layer down, in
  `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs`, where the vectors are read through `.expect(...)`.
  Nothing ships unguarded, but the Dart assertion is the weaker of the two by construction.
- Every `working_copy_change_id` oracle is now read PRE-CALL, at all three layers and on both the
  committed and the no-op path, so a regression that MOVED `@` cannot shift both sides of the
  comparison together. What remains uncovered is the narrower case where nothing moves `@` at all:
  no test advances `@` between opening the repo and the mutation, so a regression that returned a
  value cached at open time would still satisfy all three layers. Out of scope here — every matrix
  row fixes the expectation to the PRE-CALL `@`.
- `cargo make verify-codegen` remains a manual discipline tool rather than a gate step (a
  deliberate WIP deferral recorded in `project-context.md`), so a future rustdoc edit to one of the
  four `extern "C"` wrappers without `cargo make codegen` would leave the shipped header and Dart
  bindings carrying the old wording with the gate green — the same drift class this run's item 1
  was about.
- The frontmatter `warnings` are dispositioned as follows. `multiple-goals`: accepted deliberately —
  the three items are one closing transaction over a single subsection of one ledger section, and
  splitting them would have left that subsection half-open. `oversized`: accepted — the spec's size
  is the 14-site doc map plus a seven-row matrix, i.e. breadth of enumeration rather than depth, and
  both the gate and the acceptance greps bound it. `followup_review_recommended: true` opens no
  ledger debt: the intent forbids a new entry, `deferred` is empty, and the flag is driven purely by
  the VOLUME of falsified-documentation fixes across two passes, not by any defect in shipped
  behaviour — which this change does not touch at all.

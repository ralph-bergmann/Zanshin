---
title: 'Epic 9 follow-up A: dedupe the three copied FFI helpers'
type: 'refactor'
created: '2026-09-05'
status: 'done'
baseline_revision: '615db70c8d25f2c7363f276449072ee821671b3c'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      ~20 inline copies of the session_from_handle borrow remain in nine other zanshin-ffi
      modules.
    evidence: |-
      repo.rs (8 sites), file.rs (4), plus status.rs, change.rs, graph.rs, op_log.rs,
      bookmarks.rs, remotes.rs and log_defaults.rs each spell
      `unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(…)`
      INLINE inside their `catch(|| …)` closure, several with their own duplicated three-line
      SAFETY comment. Semantically identical to the extracted helper (same code,
      `context: None`), so nothing is mishandled — but "one spelling of the unbounded-lifetime
      contract" holds for 4 of ~19 modules. The intent scoped this run to the four NAMED
      copies, so the inline sites were left alone and the envelope.rs banner now says so.
    location: >-
      crates/zanshin-ffi/src/{repo,file,status,change,graph,op_log,bookmarks,remotes,log_defaults}.rs
    severity: low
    resolved: >-
      2026-09-05, spec-epic-9-followup-a2-finish-ffi-helper-dedupe, commit 53fc8f6. The count
      was exactly 19; every site now calls envelope::session_from_handle behind git.rs's
      one-line `// SAFETY: see \`session_from_handle\`.` pointer, with the three-line per-site
      duplicates and the orphaned handle_from_raw / RepoSession / FFI_INVALID_HANDLE imports
      deleted. zanshin_repo_close's `if let Some` + handle_drop close path is the one
      deliberate non-user; the envelope.rs banner was rewritten to say so.
  - summary: >-
      readToken's body is still inlined ~23 times in the Dart adapters that do NOT pass a
      request buffer.
    evidence: |-
      status.dart, bookmarks.dart, op_log.dart, remotes.dart, log_defaults.dart, change.dart,
      diagnostics.dart, events.dart, graph.dart and repo.dart (six sites), plus four blocks
      inside mutate.dart, each repeat FfiBuffer.fromToken / Uint8List.fromList(buf.bytes) /
      buf.dispose() verbatim. request_bytes.dart covers the six request-buffer files only, so a
      change to the token ownership discipline still has to be made in a dozen places.
    location: >-
      packages/zanshin_core/lib/src/ffi/
    severity: low
    resolved: >-
      2026-09-05, spec-epic-9-followup-a2-finish-ffi-helper-dedupe, commit 53fc8f6. All 23
      re-pointed at request_bytes.dart's readToken; FfiBuffer.fromToken now has exactly one
      caller. mutate.dart held 8 blocks, not four (the ~23 total was right).
      diagnostics.dart and events.dart decoded inside the try and now decode the
      Uint8List.fromList copy after disposal — same value, shorter native lifetime.
  - summary: >-
      ZanshinWorker._rejectInteriorNuls hand-rolls the guard this run just centralised.
    evidence: |-
      isolate.dart repeats `value.codeUnits.contains(0)` plus the literal
      `ArgumentError.value(value, name, 'must not contain an interior NUL (U+0000)')` instead of
      delegating to request_bytes.dart's rejectInteriorNul, so the message now has a second
      spelling one layer up. Deliberately left alone: it is the documented CALLING-SIDE guard,
      not one of the six adapter copies item 2 named. Six call sites also write their own `for`
      loop over the scalar form, so a list variant is the natural companion fix.
    location: >-
      packages/zanshin_core/lib/src/worker/isolate.dart
    severity: low
    resolved: >-
      2026-09-05, spec-epic-9-followup-a2-finish-ffi-helper-dedupe, commit 53fc8f6.
      _rejectInteriorNuls deleted; a new rejectInteriorNuls list helper next to the scalar
      form replaced all six hand-written `for` loops. The five remaining hand-rolled throws
      delegate too — two in isolate.dart (workspaceRoot's name, bookmarkCreate's revision)
      and three in graph.dart the a2 spec's own map had missed. `codeUnits.contains(0)` and
      the literal message each have one hit in lib/, both inside rejectInteriorNul.
  - summary: >-
      Ten worker command arms have no closed-handle test.
    evidence: |-
      23 of the 33 arms that synthesize the ffi.invalid_handle envelope have a closed-handle
      test; Describe, NewChange, Edit, Abandon, GitFetch, GitImport, GitRemoteAdd,
      GitRemoteRemove, GitRemoteRename and GitRemoteSetUrl have none, so their dispatch-arm
      wiring rests on textual uniformity alone. Collapsing the 33 copies into one helper reduces
      the risk but does not remove it — the per-arm lookup and reply are still per-arm code.
    location: >-
      packages/zanshin_core/test/worker/
    severity: medium
    resolved: >-
      2026-09-05, spec-epic-9-followup-a2-finish-ffi-helper-dedupe, commit 53fc8f6. Ten tests
      added on the file_test.dart model — the five mutation arms in mutate_test.dart, the
      five git arms in git_test.dart beside the existing gitExport one. All 33 arms now have
      a closed-handle witness.
---

<intent-contract>

## Intent

**Problem:** Three copy-paste clusters accumulated across Stories 9.3–9.8 and are recorded as
low-hanging fruits in `_bmad-output/implementation-artifacts/deferred-work.md` § "Deferred from:
bmad-build-auto runs of Stories 9.3–9.8": `session_from_handle` exists byte-for-byte in four
`zanshin-ffi` modules (each carrying an unbounded-lifetime `SAFETY` comment that must stay in
sync), the Dart request-buffer helpers are re-spelled in six `packages/zanshin_core` FFI adapters,
and `worker/isolate.dart` carries **33** verbatim copies of the synthesized `ffi.invalid_handle`
envelope (the ledger's "~a dozen" is stale). Every copy is a place a future edit can desync.

**Approach:** Three pure extractions with no observable behaviour change on any surface — the same
bytes on the wire, the same error codes, the same messages. (1) Move `session_from_handle` once
into `crates/zanshin-ffi/src/envelope.rs` as `pub(crate)`, next to `reject_null_request`, and call
it from the four modules. (2) Add `packages/zanshin_core/lib/src/ffi/request_bytes.dart` holding the
shared request-buffer helpers and re-point the six adapters at it. (3) Add one
`_invalidHandleEnvelope(handleId)` helper in `isolate.dart` and use it from every worker switch arm.
Existing tests are the witness; no new production behaviour, so no new test is required beyond
keeping the gate green.

## Boundaries & Constraints

**Always:**
- Behaviour-preserving only. Every extracted body is copied VERBATIM; the only permitted edits are
  the identifier's visibility/name and doc-comment wording that had to become noun-agnostic because
  it now serves several nouns.
- The FFI wire is untouched: no `.fbs` edit, no `extern "C"` signature change, therefore
  **no `cargo make codegen` run and no diff in any generated file** (`zanshin_ffi.h`,
  `bindings.dart`, `*_generated.rs`, `*.ffi_generated.dart`).
- The synthesized worker envelope keeps its exact shape and strings: `ok: false`,
  `code: 'ffi.invalid_handle'`, `context: 'unknown or closed handleId: $handleId'`. The per-arm
  `log.warning('Worker: <X>Command for unknown handleId $handleId')` stays INLINE — its text differs
  per arm and is not part of the duplication.
- Clean up only the orphans this change creates: imports in the four Rust modules and the six Dart
  adapters that the extraction leaves unused must go (`-D warnings` / `--fatal-warnings` catch them).
- Coverage may rise but never drop. All four Rust modules and `envelope.rs` are at 100.00 in
  `coverage-baseline.txt`; the moved lines are exercised by the existing FFI integration tests
  (zero-handle refusal + live-handle success), so 100.00 must hold on both sides of the move. A
  raised `coverage-baseline.txt` is committed with the code.
- `cargo make test` is the single gate and must exit 0, run unpiped.

**Block If:**
- The gate can only be made green by lowering a `coverage-baseline.txt` entry or adding an
  `exclude_prefix`: HALT with `blocked`, blocking condition `coverage ratchet regression`.
- An extraction turns out NOT to be behaviour-preserving (e.g. two "identical" copies differ in a
  way only a test reveals): HALT with `blocked`, blocking condition `not a pure refactor`.

**Never:**
- Do not convert the ~20 INLINE `handle_from_raw::<RepoSession>(…).ok_or_else(…)` expressions in
  `repo.rs`/`file.rs`/`status.rs`/`change.rs`/`graph.rs`/`op_log.rs`/`bookmarks.rs`/`remotes.rs`/
  `log_defaults.rs` to the new helper. They are not copies of the named helper and converting them
  is a separate, larger change (item 1 names four modules).
- Do not convert `mutate.dart`'s three pre-existing INLINE interior-NUL `throw`s
  (`zanshinDescribe`, `zanshinEdit`, `zanshinGitFetch`) to the shared guard — pre-existing adjacent
  code, not one of the six helper copies.
- No `docs/ffi-abi.md` pass (a separate ledger item), no `.fbs` change, no new error code, no
  behaviour change to any verb, no new public API on `zanshin-jj` or `zanshin_core`.
- Do not touch `_withChangeIdListBytes` (mutate-specific) or `_rejectPathNuls` (file-specific);
  they stay private to their modules and simply call the shared helpers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Zero handle at any of the 11 wrappers in the four Rust modules | `handle = 0` | `Envelope{ok:false, error.code="ffi.invalid_handle", context=null}` — byte-identical to before | Unchanged |
| Live handle at those wrappers | valid handle from `zanshin_repo_open` | success envelope, unchanged payload | Unchanged |
| Dart adapter given a string with an interior NUL | e.g. `bookmarkCreate(raw, ['a\u0000b'], null)` | `ArgumentError.value(value, name, 'must not contain an interior NUL (U+0000)')` — same message, same `name` | Unchanged |
| Dart adapter builds a request buffer | any request table | `malloc`-allocated copy passed to Rust, freed in `finally`; token read then disposed | Unchanged |
| Worker command for an unknown/closed `handleId` | `handles[handleId] == null` | `BufferResult` carrying the synthesized `ffi.invalid_handle` envelope with `context: 'unknown or closed handleId: <id>'` | Unchanged; `log.warning` still per-arm |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `615db70`.

**Item 1 — Rust `session_from_handle` (four copies → one)**
- `crates/zanshin-ffi/src/envelope.rs` — destination. `:165-170` the "Shared request-buffer guards"
  banner + its rationale paragraph; `:176` `reject_null_request`, `:187` `invalid_request`,
  `:201` `missing_field`, `:399` `finish_envelope`, `:449`/`:465` `catch`. `:18`
  `FFI_INVALID_HANDLE`, `:160` `struct FfiErrorObj`. `:9-12` the import block (currently NO
  `crate::handle` / `crate::repo` import — both must be added). `:2-7` the module doc claims "Every
  pub function returns a finished, owned `Vec<u8>`" — the new helper does not, so it goes under its
  OWN banner and the doc sentence is scoped to the builders.
- `crates/zanshin-ffi/src/git.rs:197-209` — the canonical copy (doc + `# Safety` + the SAFETY
  comment). Imports to prune: `:29` `use crate::handle::handle_from_raw;` (whole line),
  `:30` `RepoSession` out of `use crate::repo::{map_mutate_err, RepoSession};`, `FFI_INVALID_HANDLE`
  out of the `crate::envelope::{…}` list `:22-26`. `FfiErrorObj` STAYS (`:62`, `:81`). Six call
  sites: `:247, 281, 329, 382, 437, 495`.
- `crates/zanshin-ffi/src/commit_views.rs:203-215` copy; imports `:25` (`FFI_INVALID_HANDLE`),
  `:30` `handle_from_raw`, `:31` `use crate::repo::RepoSession;` (whole line). Call sites
  `:264, 303, 353`.
- `crates/zanshin-ffi/src/workspace.rs:125-137` copy; imports `:25`, `:30`, `:31` (same shapes).
  Call sites `:169, 219`.
- `crates/zanshin-ffi/src/bookmark_ops.rs:89-101` copy; imports `:23`, `:27`,
  `:28` `{map_mutate_err, RepoSession}`. Call sites `:151, 197`.
- `crates/zanshin-ffi/src/repo.rs:325` `pub(crate) struct RepoSession` — the borrowed type;
  `crates/zanshin-ffi/src/handle.rs:22` `pub unsafe fn handle_from_raw<'a, T>(ptr: *mut T) ->
  Option<&'a mut T>` — the primitive. Both already `pub(crate)`-reachable from `envelope.rs`.
- Inline `#[cfg(test)] mod tests` exist in `git.rs:506`, `workspace.rs:230`, `commit_views.rs:364`,
  `envelope.rs:497` — none references `session_from_handle`, so no test edit is needed.

**Item 2 — Dart request-buffer helpers (six copies → one file)**
- `packages/zanshin_core/lib/src/ffi/request_bytes.dart` (**NEW**) — SPDX first line, then the four
  helpers made package-visible: `withRequestBytes<T>`, `rejectInteriorNul`, `readToken`,
  `callWithRequest`. Needs `dart:ffi as ffi`, `dart:typed_data`, `package:ffi/ffi.dart` (malloc),
  `bindings.dart` (`ZanshinBuf`), `ffi_buffer.dart` (`FfiBuffer`).
- Definitions to delete and re-point (all under a `// ── Request-buffer helpers ──` banner):
  - `mutate.dart:28-36` `_withRequestBytes`, `:49-53` `_rejectInteriorNul`. `:40-41`
    `_withChangeIdListBytes` STAYS (calls the shared one). Uses at `:183-187, 196, 221-227`.
  - `git.dart:36-44`, `:51-55`, `:58-65` `_readToken`, `:68-71` `_callWithRequest`.
  - `file.dart:30-38`, `:45-49`, `:61-71` `_callWithRequest` (token-read inlined — replace with the
    shared `callWithRequest`). `:52-57` `_rejectPathNuls` STAYS.
  - `commit_views.dart:36-44`, `:51-55`, `:59-69` `_callWithRequest` (same inlined shape).
  - `workspace.dart:37-45`, `:52-56`, `:59-66`.
  - `bookmark_ops.dart:34-42`, `:52-56`, `:59-66`.
- Per-file doc wording differs only in the noun it names ("a jj change id, revset or path" /
  "a git remote name or URL"); the shared doc must be noun-agnostic.
- Import pruning after extraction: `package:ffi/ffi.dart` and `ffi_buffer.dart` become unused in the
  files whose only `malloc`/`FfiBuffer` use was the extracted helper (`git.dart` keeps
  `package:ffi/ffi.dart` for `Utf8` in its C-string adapters; `mutate.dart` keeps both). Let
  `dart analyze` decide — do not guess.
- `packages/zanshin_core/analysis_options.yaml` — `package:lints/recommended.yaml` plus
  `prefer_relative_imports`, `directives_ordering`, `require_trailing_commas`,
  `prefer_expression_function_bodies`, `comment_references`, `eol_at_end_of_file`;
  `formatter.page_width: 120`. No `public_member_api_docs`, so the now-public helpers need no
  mandated doc — keep the existing docs anyway.

**Item 3 — worker invalid-handle envelope (33 copies → one helper)**
- `packages/zanshin_core/lib/src/worker/isolate.dart` — 33 identical 7-line blocks; first at
  `:1392-1398` (`CloseRepoCommand`), last at `:2015-2021`. Every one is followed by
  `responseSP.send((commandId, BufferResult(errorBytes)));`. Each `code: 'ffi.invalid_handle',`
  line sits at the same indentation and each `context:` line is the identical
  `'unknown or closed handleId: $handleId'` (33/33 — verified by grep).
- Placement for the new top-level private helper: alongside the file's other worker-entry helpers
  after `_workerEntry` ends at `:2057` — i.e. immediately before `_replyRepoOp` `:2059-2083`
  (`_rawEventToRepoEvent` `:2087`, `_envelopeToException` `:2099` follow).
- The `internal.dispatch_error` envelope at `:2047-2053` is a DIFFERENT code/context and is not part
  of this extraction.

**Tests / gates (witnesses, no new tests planned)**
- Rust: `crates/zanshin-ffi/tests/` — the `*_ffi.rs` suites drive both arms of the moved helper
  (zero handle → `ffi.invalid_handle`; live handle → success), e.g. `repo_write_ffi.rs`,
  `bookmarks_ffi.rs`.
- Dart: `packages/zanshin_core/test/ffi/*_test.dart` (adapter-level, incl. the NUL-rejection groups
  in `mutate_test.dart:225` and the `bookmark_ops_test.dart` / `workspace_test.dart` zero-handle
  notes) and `packages/zanshin_core/test/worker/*_test.dart` — 14 `*_on_closed_handle_surfaces_
  ffi_invalid_handle` tests across `bookmarks/change/file(4)/graph/op_log/log_defaults/mutate(3)/
  status/remotes`, plus `git_test.dart:191` and
  `bookmark_ops_test.dart:136` — these are the item-3 witnesses.
- `coverage-baseline.txt` — `crates/zanshin-ffi/src/{envelope,git,commit_views,workspace,
  bookmark_ops}.rs` all `= 100.00`; `epsilon_pct = 0.10`. Coverage is Rust-only, so items 2 and 3
  cannot move it.
- `Makefile.toml` `[tasks.test]` → cargo test + clippy pedantic `-D warnings` + rustfmt +
  flutter/dart analyze + format + `cargo deny` + `[tasks.coverage]` incl. the extern-fn guard (no
  `extern "C"` fn is added or removed here, so the guard is unaffected).

**Bookkeeping targets**
- `_bmad-output/implementation-artifacts/deferred-work.md:216`, `:218`, `:220` — the three bullets to
  strike through. Convention in the same file: `:178` and `:182` show the `~~**title**~~ **RESOLVED
  <date> (…)**` form.
- `_bmad-output/implementation-artifacts/spec-9-8-bookmark-crud-create-delete.md:25-34` (item 1) and
  `:35-43` (item 2) — the `deferred:` entries that need a `resolved:` field. Item 3 has no spec
  `deferred:` entry (grep `spec-9-*.md` to confirm before claiming it does).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-ffi/src/envelope.rs` -- add `use crate::handle::handle_from_raw;` and
  `use crate::repo::RepoSession;`, then paste `session_from_handle` verbatim under a new
  `// ── Shared handle borrow ──` banner after `missing_field`, changed only to
  `pub(crate) unsafe fn`. Scope the module-doc sentence about "every pub function returns a
  finished, owned `Vec<u8>`" to the envelope builders so it stays true. -- one spelling of the
  unbounded-lifetime SAFETY contract instead of four.
- `crates/zanshin-ffi/src/{git,commit_views,workspace,bookmark_ops}.rs` -- delete the local
  `session_from_handle`, add `session_from_handle` to the existing `use crate::envelope::{…}` list,
  and drop the imports that go unused (`handle_from_raw` line; `RepoSession`; `FFI_INVALID_HANDLE`).
  Leave every `// SAFETY: see `session_from_handle`.` call-site comment and all 13 call sites
  untouched. -- the call sites are the behaviour; only the definition moves.
- `packages/zanshin_core/lib/src/ffi/request_bytes.dart` -- NEW file: `withRequestBytes`,
  `rejectInteriorNul`, `readToken`, `callWithRequest`, bodies verbatim from the existing copies
  (`git.dart` is the reference for `callWithRequest`, which composes the other two), with
  noun-agnostic doc comments and a file-header comment naming the six adapters it serves. -- one
  definition of the request-buffer ownership discipline (AR-P-5 inbound rule).
- `packages/zanshin_core/lib/src/ffi/{mutate,git,file,commit_views,workspace,bookmark_ops}.dart` --
  delete the local `_withRequestBytes` / `_rejectInteriorNul` / `_readToken` / `_callWithRequest`,
  import `request_bytes.dart`, rename the call sites to the unprefixed names, and remove imports
  that `dart analyze` then reports unused. Keep `_withChangeIdListBytes` and `_rejectPathNuls`
  local, now delegating to the shared helpers. -- six copies collapse to one; call sites keep their
  exact arguments so messages and `name` arguments are unchanged.
- `packages/zanshin_core/lib/src/worker/isolate.dart` -- add
  `Uint8List _invalidHandleEnvelope(int handleId)` before `_replyRepoOp`, returning the identical
  `fbs.EnvelopeObjectBuilder(ok: false, error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle',
  context: 'unknown or closed handleId: $handleId')).toBytes()`, and replace all 33 inline blocks
  with `final Uint8List errorBytes = _invalidHandleEnvelope(handleId);`. Leave each arm's
  `log.warning` and the `internal.dispatch_error` block alone. -- ~200 lines and 33 desync
  opportunities removed with no wire change.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- strike through the three resolved
  bullets in the file's existing convention (`~~**title**~~` + ` — RESOLVED 2026-09-05
  (<spec slug>, commit <short hash>): <one line>`). -- the ledger is the index; an unmarked
  resolved item is worse than no item.
- `_bmad-output/implementation-artifacts/spec-9-8-bookmark-crud-create-delete.md` -- add a
  `resolved: >-` block scalar to the two `deferred:` items this run closes (the
  `session_from_handle` one and the six-Dart-copies one), keeping the YAML valid. Grep the other
  `spec-9-*.md` files for a `deferred:` item describing the `isolate.dart` envelope duplication and
  annotate it too if one exists. -- the spec frontmatter is the per-story evidence trail.

**Acceptance Criteria:**
- Given the four `zanshin-ffi` modules, when the tree is grepped for `unsafe fn session_from_handle`,
  then exactly one definition remains and it is in `envelope.rs`, while all 13 call sites still read
  `unsafe { session_from_handle(handle) }?`.
- Given the six Dart FFI adapters, when the tree is grepped for `_withRequestBytes`, `_readToken`,
  `_rejectInteriorNul` and `_callWithRequest`, then no definition of any of them remains outside
  `request_bytes.dart`.
- Given `isolate.dart`, when the tree is grepped for `code: 'ffi.invalid_handle',`, then exactly one
  occurrence remains and it is inside `_invalidHandleEnvelope`.
- Given a clean tree, when `cargo make test` runs unpiped, then it exits 0 and no
  `coverage-baseline.txt` entry is lower than at baseline `615db70`.
- Given the change is staged, when `git status --porcelain` is read, then no generated file
  (`zanshin_ffi.h`, `bindings.dart`, `*_generated.rs`, `*.ffi_generated.dart`) and no `schemas/*.fbs`
  appears in the diff.
- Given the run is finished, when `deferred-work.md` is read, then the three low-hanging-fruit
  bullets are struck through with a resolution line naming this spec's slug and the commit, and the
  matching `spec-9-8` `deferred:` items carry a `resolved:` field.

## Spec Change Log

## Review Triage Log

### 2026-09-05 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 13: (high 0, medium 4, low 9)
- defer: 4: (high 0, medium 1, low 3)
- reject: 10
- addressed_findings:
  - `[medium]` `[patch]` The `# Safety` clause did not widen with the visibility. `pub(crate)`
    lets any module in the crate mint a `&mut RepoSession` of unbounded lifetime from a `u64`, so
    two calls on one handle produce two live aliasing `&mut` — UB. While the helper was
    module-private in four modules the hazard was contained; crate-wide it is not. Added the two
    missing obligations: at most ONE live borrow per handle, and the borrow must not outlive the
    `extern "C"` call (the Dart side may close and free the session as soon as it returns).
  - `[medium]` `[patch]` The exact `ArgumentError` message and its `name` argument are now
    produced in exactly one place, and NO test asserted either — every NUL test in the package
    matches `throwsArgumentError` by TYPE only. Rewording the message or dropping a `name` would
    have kept the whole gate green while breaking the intent's own "same messages" invariant. New
    `test/ffi/request_bytes_test.dart` pins the literal message, the `name` and the
    `invalidValue`, plus the null and NUL-free accept cases.
  - `[medium]` `[patch]` `_invalidHandleEnvelope` became the sole producer of
    `context: 'unknown or closed handleId: $handleId'` for all 33 worker arms, and a repo-wide
    grep found exactly one occurrence of that string — the definition. Every closed-handle worker
    test asserted `code` alone, though the suite pins `e.context` for ten other codes. Added the
    `context` assertion to `test/worker/bookmarks_test.dart`'s closed-handle test.
  - `[medium]` `[patch]` The ledger ended the run with one struck-through and one OPEN entry for
    the same debt: the 2.7 + 3.4b review at `deferred-work.md:117` proposed this exact helper
    under the name `_unknownHandleEnvelope`. Struck through, noting the shipped name differs and
    cross-referencing the 9.3–9.8 duplicate — the run's purpose was to shrink the ledger.
  - `[low]` `[patch]` `envelope.rs`'s module doc scoped its first sentence to "Every pub ENVELOPE
    BUILDER" but left "This module owns nothing beyond the build step" two lines below, which the
    move made false. Scoped it too, naming `session_from_handle` as the exception that pulls in
    `crate::handle` / `crate::repo`.
  - `[low]` `[patch]` The new banner said "Unlike the builders above" — wrong direction: the
    helper sits ahead of `ok_empty`, `ok_repo_handle`, `build_mutation_result`,
    `ok_mutation_result`, `ok_absorb_result`, `ok_diagnostics`, `finish_envelope`, `err` and
    `catch`. Reworded to "unlike the builders in this module"; the function did not move.
  - `[low]` `[patch]` The banner claimed the helper serves "every noun module whose wrappers take
    a handle as their first argument", which is false — nine other modules do too and still spell
    the borrow inline. Now says "the four modules that carried a NAMED copy", with the ~20 inline
    sites recorded so "the one spelling" is not read as already achieved.
  - `[low]` `[patch]` No test covered `session_from_handle` at its new home: `envelope.rs` has an
    inline test module, but the moved lines' coverage rested entirely on the cdylib/integration
    union. Added `session_from_handle_refuses_a_zero_handle` pinning code set + `context` absent.
    Uses `.err().expect(…)` — `expect_err` needs `RepoSession: Debug` and a `let … else` leaves
    an uncovered `panic!` line that dropped `envelope.rs` to 99.76% under the ratchet.
  - `[low]` `[patch]` `readToken` became the single funnel for every token read and said nothing
    about a null token — `FfiBuffer.fromToken` throws `ArgumentError` on `nullptr`, which inside
    the worker isolate surfaces as `internal.dispatch_error`, not as an FFI error envelope.
    Documented as a cdylib bug rather than a handleable refusal.
  - `[low]` `[patch]` `withRequestBytes`'s non-empty precondition used to sit beside each copy and
    was lost in the move. Documented, with the explicit note that it is deliberately NOT
    special-cased to `nullptr` — Rust would then answer `ffi.null_pointer`, a different observable
    outcome, which the reviewer had proposed as a guard.
  - `[low]` `[patch]` The DIRECT-CALLER-backstop rationale — why this guard is spelled at two
    layers at all — survived in only one of the six copies (`bookmark_ops.dart`). Carried onto
    `rejectInteriorNul` itself.
  - `[low]` `[patch]` `mutate.dart` imported the shared guard yet still hand-rolled it four times
    across its three C-string adapters (`describe` ×2, `edit`, `git_fetch`) — a same-file
    inconsistency this change introduced. They now call `rejectInteriorNul` with unchanged `name`
    arguments, so the thrown error is identical.
  - `[low]` `[patch]` `file.dart`'s leftover `// ── Request-buffer helpers ──` banner covered only
    the `_rejectPathNuls` argument guard; retitled. `mutate.dart`'s identical banner was left —
    what remains under it (`_withChangeIdListBytes`) genuinely is a request-buffer helper.

## Design Notes

**Why `envelope.rs` for a handle helper.** The intent prescribes the location, and it is the same
argument Story 9.8 made for moving `finish_or_no_op` into `mutate.rs`: the shared thing belongs
where the other shared thing lives, so there is no second, desyncable spelling. The trade is that
`envelope.rs` — until now a pure builder module — gains a dependency on `repo::RepoSession` and
`handle::handle_from_raw`. That is a module-level cycle Rust permits and the crate already has
elsewhere (`git.rs` ↔ `repo.rs`); it is recorded here so a later reader does not "fix" it by moving
the helper back out.

**Scope boundary, deliberately drawn.** Nine other `zanshin-ffi` modules spell the SAME borrow as an
inline expression inside their `catch(|| …)` closure rather than as a named helper (about 20 sites,
`repo.rs` alone has 8). Converting them is mechanical and behaviour-preserving, but it is a
different, much wider change than "four byte-identical copies of one named function", so it stays
out. Same reasoning for `mutate.dart`'s three inline NUL `throw`s.

**Why `callWithRequest` joins the shared file.** It is not a fourth kind of duplication: it is
literally `withRequestBytes(request, (p, l) => readToken(call(p, l)))`, defined three times
(`git.dart` in exactly that composed form, `file.dart` and `commit_views.dart` with the token-read
inlined). Extracting the two helpers and leaving their composition triplicated in the same banner
section would leave item 2 half-done.

**The refactor's own witness is the gate.** Nothing new is observable, so no new test is warranted —
adding one would be testing that a copy-paste was faithful, which the compiler plus the 14 existing
closed-handle worker tests, the adapter NUL-rejection groups and the Rust zero-handle FFI tests
already do. If the gate goes red, the extraction was not faithful; that is the signal.

## Verification

**Commands:**
- `cargo make test` -- expected: exit 0, run unpiped and synchronously (cargo test + clippy pedantic
  `-D warnings` + rustfmt + `flutter test` + dart analyze/format + `cargo deny` + coverage ratchet).
  The single gate.
- `grep -rn "unsafe fn session_from_handle" crates/zanshin-ffi/src/` -- expected: exactly one hit,
  in `envelope.rs`.
- `grep -rn "_withRequestBytes\|_readToken\|_rejectInteriorNul\|_callWithRequest" packages/zanshin_core/lib/`
  -- expected: no hits (the shared names carry no leading underscore).
- `grep -c "code: 'ffi.invalid_handle'," packages/zanshin_core/lib/src/worker/isolate.dart` --
  expected: `1`.
- `git status --porcelain` -- expected: clean after each commit; no generated file and no
  `schemas/*.fbs` in any diff.
- `git diff --stat` before committing -- expected: only the files named in Tasks & Acceptance.

## Auto Run Result

**Outcome:** done. All three extractions landed, the review pass patched 13 findings, and
`cargo make test` exits 0 (run unpiped twice: after the code, and again after the patches).

**Summary.** Three pure extractions, no observable behaviour change on any surface. (1) The four
byte-identical `session_from_handle` copies collapsed into one `pub(crate) unsafe fn` in
`envelope.rs`; all 13 call sites and their `// SAFETY:` comments untouched. (2) The Dart
request-buffer helpers collapsed into `ffi/request_bytes.dart` and the six adapters re-pointed at
it. (3) `isolate.dart`'s 33 verbatim `ffi.invalid_handle` envelopes collapsed into
`_invalidHandleEnvelope(handleId)`. Net −458 lines in the first commit.

**Files changed** (three commits: `a64d1c5` refactor, `33e02b2` bookkeeping, `7344da5` review
patches):
- `crates/zanshin-ffi/src/envelope.rs` -- gained the shared helper under a `Shared handle borrow`
  banner, a widened `# Safety` contract, and an inline zero-handle test.
- `crates/zanshin-ffi/src/{git,commit_views,workspace,bookmark_ops}.rs` -- local copy and the
  orphaned `handle_from_raw` / `RepoSession` / `FFI_INVALID_HANDLE` imports removed.
- `packages/zanshin_core/lib/src/ffi/request_bytes.dart` -- NEW: `withRequestBytes`,
  `rejectInteriorNul`, `readToken`, `callWithRequest`, with noun-agnostic docs and preconditions.
- `packages/zanshin_core/lib/src/ffi/{mutate,git,file,commit_views,workspace,bookmark_ops}.dart` --
  local helpers deleted, call sites re-pointed, orphaned imports pruned; `mutate.dart`'s four
  hand-rolled NUL throws now call the shared guard.
- `packages/zanshin_core/lib/src/worker/isolate.dart` -- 33 inline envelopes → one helper.
- `packages/zanshin_core/test/ffi/request_bytes_test.dart` -- NEW: pins the `ArgumentError`
  message, `name` and `invalidValue`.
- `packages/zanshin_core/test/worker/bookmarks_test.dart` -- pins the worker `context` string.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- three low-hanging fruits plus the
  duplicate 2.7/3.4b entry struck through; four new deferrals recorded.
- `_bmad-output/implementation-artifacts/spec-9-8-…md` (×2 items) and `spec-9-4-…md` (×1) --
  `resolved:` fields added to the originating `deferred:` entries.

**Review findings breakdown:** 13 patches applied (0 high, 4 medium, 9 low); 4 items deferred
(0 high, 1 medium, 3 low); 10 rejected. No intent gaps, no spec repairs, no loopbacks.

**Follow-up review recommendation:** `true`. Patched counts: high 0, medium 4, low 9 →
score `3 × 4 + 1 × 9 = 21`, at or above the threshold of 5.

**Verification performed.**
- `cargo make test` unpiped, exit 0, 460 s. Coverage held at 99.21% (8391/8458); no
  `coverage-baseline.txt` entry changed, so the file is not in the diff. The extern-fn guard
  passes (no `extern "C"` fn added or removed).
- Acceptance greps all hold: exactly one `unsafe fn session_from_handle` (in `envelope.rs`); 13
  call sites intact (git 6, commit_views 3, workspace 2, bookmark_ops 2); no `_withRequestBytes`
  / `_readToken` / `_rejectInteriorNul` / `_callWithRequest` definition outside the shared file;
  exactly one `code: 'ffi.invalid_handle',` in `isolate.dart`.
- No generated file (`zanshin_ffi.h`, `bindings.dart`, `*_generated.rs`, `*.ffi_generated.dart`)
  and no `schemas/*.fbs` appears in the diff — nothing required `cargo make codegen`.
- Matrix audit: every row has a covering test that ran and passed in the gate output — the
  zero-handle FFI suites (`a_zero_handle_is_refused_by_both_wrappers`,
  `git_import_and_export_with_a_zero_handle_return_ffi_invalid_handle`,
  `every_wrapper_zero_handle_returns_ffi_invalid_handle`, …), the adapter NUL-rejection groups,
  and the 14 `*_on_closed_handle_surfaces_ffi_invalid_handle` worker tests.

**Residual risks.**
- The two `resolved`/`patch` claims that this is behaviour-preserving rest on the extraction being
  textually faithful plus a green gate. Ten of the 33 worker arms have no closed-handle test
  (recorded as a deferral), so for those the substitution is witnessed by grep uniformity rather
  than by a test.
- This spec file was committed once (in `33e02b2`) containing a literal NUL byte in an I/O-matrix
  example, which made git classify that blob as binary. The working-tree version replaces it with
  a `U+0000` escape sequence, so the final blob is text; the historical blob stays binary and was
  NOT amended (no history rewrite). Same trap the review-patch pass hit in
  `test/ffi/request_bytes_test.dart` before switching that file to escapes — when writing ABOUT an
  interior NUL, never type one.
- Scope was held deliberately: the ~20 inline Rust borrows, the ~23 inlined Dart token reads and
  `ZanshinWorker._rejectInteriorNuls` are the same duplication one step wider, and are recorded in
  `deferred-work.md` rather than fixed here.

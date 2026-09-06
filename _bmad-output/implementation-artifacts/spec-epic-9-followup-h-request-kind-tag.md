---
title: 'Epic 9 follow-up H: a `RequestKind` type tag on every FFI request buffer, verified by every wrapper'
type: 'chore'
created: '2026-09-06'
status: 'done'
baseline_revision: '8816ad4121560357f69511cba389c74f5a0e889c'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** No request table carries a `file_identifier`, and several put one string in
slot 0, so a buffer built for one verb VERIFIES as another verb's table instead of being
refused. Story 9.8 made that dangerous rather than merely sloppy: `BookmarkCreateRequest.names`
are EXACT decoded names while `BookmarkDeleteRequest.names` are GLOB-by-default patterns, so a
create buffer fed to the delete wrapper silently glob-deletes what the caller meant literally —
and the FFI test `a_zero_handle_is_refused_by_both_wrappers` performs exactly that feed today.
The same hazard sits on `ChangeIdList`, whose two wrappers read it as `zanshin_new_change`'s
`parents` and as `zanshin_abandon`'s `change_ids`: a mis-routed buffer abandons the commits the
caller named as parents. This is the one open must-have on the central ledger at
`_bmad-output/implementation-artifacts/deferred-work.md:194`.

**Approach:** Ralph's decision (2026-09-06) is a **wrapper-side type tag**, not a FlatBuffers
`file_identifier`. Add `enum RequestKind : ubyte` to `schemas/envelope.fbs` with one variant per
`extern "C"` wrapper that reads a request root, and `kind: RequestKind;` as the FIRST field of
all 15 request tables. `Unspecified = 0` is FlatBuffers' default for an absent field, so an
untagged buffer reads as `Unspecified` and is refused — nothing is silently accepted. One
`pub(crate)` helper next to `reject_null_request` gives the check a single spelling; all 16
wrappers call it immediately after `root_with_opts` succeeds and BEFORE the handle lookup. All
16 Dart builders set the tag; regenerate once and commit. Closing run for that one ledger entry;
the only other work is bookkeeping.

## Boundaries & Constraints

**Always:**
- **One `RequestKind` variant per WRAPPER, not per table.** 14 tables have exactly one wrapper,
  so their variant name is the table name minus `Request`. `ChangeIdList` has TWO wrappers, so
  it gets TWO variants — `NewChange` and `Abandon` — because the tag is a per-buffer VALUE, not
  a per-table type. A single shared variant would leave the sharpest remaining collision
  (parents ↔ change ids, one of them destructive) unrefused, which is the ledger item's whole
  point. This is a deliberate strengthening of the intent's "one variant per table" wording; it
  adds no exception to the convention, it removes the last one.
- Declaration order: `Unspecified = 0, Restore, Absorb, NewChange, Abandon, FileList, FileShow,
  FileAnnotate, FileSearch, GitRemoteAdd, GitRemoteSetUrl, Show, Evolog, Interdiff,
  WorkspaceRoot, BookmarkCreate, BookmarkDelete` — 17 values, `ubyte`.
- **`kind` is the FIRST field of every request table**, edited in place (WIP rule: no `_v2`
  table, no `id:` attribute, no in-wire schema version). Slot shifts are safe ONLY because both
  committed codegen sides regenerate in the same commit — so the schema's own APPEND-only banner
  (`schemas/envelope.fbs:36-39`) and its restatement in `docs/ffi-abi.md:196-200` must be
  rewritten in the same change to state the tag convention and the regenerate-both-sides rule.
- **Refusal order is null → verify → kind → handle → fields.** The kind check runs inside each
  reader right after `root_with_opts`, before any other field is read; and each wrapper must call
  its reader BEFORE `session_from_handle`, which is the reverse of today's uniform order. A
  mis-routed buffer must be refused whether or not the caller also holds a live handle.
- Mismatch refusal: `ffi.invalid_argument` with a `context` naming both kinds. No new error code
  — `docs/rust-error-codes.md:45` already registers it; extend that row's prose instead.
- One `pub(crate)` helper in `crates/zanshin-ffi/src/envelope.rs`, next to `reject_null_request`,
  under the existing "Shared request-buffer guards" banner. Exactly one spelling of the check.
- Every Dart builder under `packages/zanshin_core/lib/src/ffi/` sets the tag, including the
  shared `_withChangeIdListBytes` helper, which takes the kind as a parameter.
- Every Rust test request-builder helper sets the tag (13 helper fns, 6 files).
- One `cargo make codegen` run; commit `crates/zanshin-ffi/src/envelope_generated.rs`,
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`,
  `crates/zanshin-ffi/include/zanshin_ffi.h` and
  `packages/zanshin_core/lib/src/ffi/bindings.dart` together with the sources.
- `#![deny(missing_docs)]` satisfied; no `jj_lib` type in any public signature; clippy pedantic
  clean; SPDX first line on any new `.rs`/`.dart` file.
- **Every touched file in `coverage-baseline.txt` sits at 100.00 %** (`envelope.rs`, `repo.rs`,
  `file.rs`, `git.rs`, `commit_views.rs`, `workspace.rs`, `bookmark_ops.rs`). Every new line must
  be executed by a test — that is why the mismatch witness is table-driven over ALL 16 wrappers,
  not only the ledger's named four.

**Block If:**
- `flatc` is absent or is not `25.12.19` (the `flatbuffers` crate pin) → HALT, blocking condition
  `flatc version mismatch`. Hand-editing a generated file is an AR-AP-7 violation.
- The codegen diff moves an `extern "C"` **signature** line in `zanshin_ffi.h` or `bindings.dart`
  (anything beyond doc-comment hunks) → HALT, blocking condition `unexpected codegen drift`.

**Never:**
- No `file_identifier` in the schema — that reading was considered and rejected by Ralph.
- No reordering, renaming or removal of any EXISTING request-table field; the only schema edits
  are the new enum, the 15 prepended `kind` fields, and the banner/doc comments that describe
  them. No payload/response table is touched. No `Payload` union member is added.
- No new `extern "C"` symbol, no signature change, no new dependency, no new error code.
- No Rust-side re-check of anything else (interior NUL stays a Dart-side guard).
- No allow-list, no `#[ignore]`, no lowering of `coverage-baseline.txt`, no new
  `exclude_prefix`.
- Do not touch `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` beyond what a green run requires —
  it must keep passing with `EXPECTED_EXPORTS = 47` and an empty exception set.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Correct tag | `zanshin_bookmark_delete` gets a buffer whose `kind == BookmarkDelete` | Verb runs exactly as before | No error expected |
| Wrong tag, live handle | `zanshin_bookmark_delete` gets a `BookmarkCreate`-tagged buffer | Refused before the handle lookup and before `names` is read | `ffi.invalid_argument`, context names expected + received kind |
| Wrong tag, zero handle | Same buffer, `handle == 0` | Refused as a KIND mismatch, not as an invalid handle | `ffi.invalid_argument` (order changed deliberately) |
| Untagged buffer | Buffer built without ever setting `kind` (byte-identical to a pre-change buffer) | Reads as `Unspecified`, refused | `ffi.invalid_argument`, context `got Unspecified` |
| Shared table, wrong wrapper | `zanshin_abandon` gets a `ChangeIdList` tagged `NewChange` | Refused — the two wrappers no longer share a tag | `ffi.invalid_argument` |
| Correct tag, zero handle | Correctly tagged buffer, `handle == 0` | Handle guard still fires (it is now the FOURTH rung) | `ffi.invalid_handle`, no context |
| Null / garbage buffer | `data == nullptr` / 8 bytes of `0xff`, live handle | Unchanged: rungs 1 and 2 still precede the kind check | `ffi.null_pointer` / `ffi.invalid_argument` |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `8816ad4`.

**Schema (the one source of truth)**
- `schemas/envelope.fbs:31-39` — the "Request-only tables" banner whose APPEND-only rule this
  change rewrites; `:41-266` the 15 request tables in declaration order: `ChangeIdList:43`,
  `RestoreRequest:58`, `AbsorbRequest:74`, `FileListRequest:89`, `FileShowRequest:97`,
  `FileAnnotateRequest:107`, `FileSearchRequest:123`, `GitRemoteAddRequest:141`,
  `GitRemoteSetUrlRequest:158`, `ShowRequest:184`, `EvologRequest:196`, `InterdiffRequest:216`,
  `WorkspaceRootRequest:231`, `BookmarkCreateRequest:249`, `BookmarkDeleteRequest:264`.
  `ChangeIdList` is a ROOT only — it is nested in no other table (verified: the name occurs once
  in the file). Existing enums for style: `:314, 341, 379, 415, 437, 468, 638, 739` (all `byte`;
  `RequestKind` is the first `ubyte`).
- `:268-291` the `Payload` union — response-only, NOT touched.

**Rust: the one shared guard**
- `crates/zanshin-ffi/src/envelope.rs:172-199` — the "Shared request-buffer guards" banner,
  `reject_null_request` (`:183-191`) and `invalid_request` (`:194-199`). The new
  `expect_request_kind` goes here, next to them. `FFI_INVALID_ARGUMENT` is already in scope.

**Rust: 16 readers + 16 wrappers (uniform two-line swap each)**
- `repo.rs` — readers `read_change_id_list:189` (SHARED by two wrappers → takes the expected
  kind as a parameter), `read_restore_request:229`, `read_absorb_request:252`; module banner
  `:162-182` explains why each reader owns its slice. Wrappers: `:775/776` (`new_change`),
  `:865/866` (`abandon`), `:1024/1025` (`restore`), `:1086/1087` (`absorb`).
- `file.rs` — wrappers `:353/354`, `:398/399`, `:438/439`, `:482/483`.
- `git.rs` — wrappers `:314/315`, `:480/481`.
- `commit_views.rs` — reader worked example `:82-98`, module SAFETY banner `:51-56`; wrappers
  `:265/266`, `:307/308`, `:366/367`.
- `workspace.rs` — wrapper `:203/204`.
- `bookmark_ops.rs` — readers `:60`, `:77`; wrappers `:136/137`, `:182/183`.
  In every one of the 16 the `session_from_handle(handle)?` line sits IMMEDIATELY BEFORE the
  `read_*_request(data, len)?` line; the fix is to swap them (the reader returns an OWNED
  struct, so there is no borrow interaction).

**Dart: 16 producers, all under `packages/zanshin_core/lib/src/ffi/`**
- `mutate.dart:24-25` `_withChangeIdListBytes` (shared by `zanshinNewChange:49` and
  `zanshinAbandon:66` → gains a `fbs.RequestKind` parameter), `:111` Restore, `:138` Absorb.
- `file.dart:41, 53, 68, 92`; `git.dart:62, 115`; `commit_views.dart:54, 81, 117`;
  `workspace.dart:50`; `bookmark_ops.dart:44, 58`.
- All 16 go through `request_bytes.dart:46-54 withRequestBytes` / `:110-113 callWithRequest`,
  which receive already-finished bytes — the tag must be set per builder, not there.
- Generated Dart enums are enhanced enums carrying `value` (`RepoKind` at
  `envelope_zanshin.ffi_generated.dart:131-170`); an ObjectBuilder field takes the enum INSTANCE
  (`RepoDetectObjectBuilder`, `:3321-3343`), and a reader defaults an absent field to value `0`.
  Lib code already names generated variants directly (`repo_detect.dart:81-84 fbs.RepoKind.Jj`).

**Rust test producers — 13 helper fns, 6 files (fixing the helpers covers all 17 sites)**
- `tests/repo_write_ffi.rs:83 change_id_list_bytes` (needs a kind parameter — it feeds both
  `new_change` and `abandon`), `:94 restore_request_bytes`, `:122 absorb_request_bytes`.
- `tests/file_ffi.rs:107 list_request_bytes` (branches into FileList/FileShow), `:134
  annotate_request_bytes`, `:151 annotate_request_without_path`, `:165
  search_request_without_pattern`, `:180 search_request_bytes`.
- `tests/git_ffi.rs:76 add_request_bytes`, `:94 set_url_request_bytes`.
- `tests/commit_views_ffi.rs:127 show_request_bytes_raw`, `:144 evolog_request_bytes`,
  `:161 interdiff_request_bytes`.
- `tests/workspace_ffi.rs:104 root_request_bytes`; `tests/bookmark_ops_ffi.rs:122
  create_request_bytes`, `:143 delete_request_bytes`.

**Tests whose outcome depends on the reorder (all pass a VALID buffer with a zero handle — they
stay green once their helper sets the tag)**
- `repo_write_ffi.rs:1353` (rows `:1364, 1372, 1385, 1390`, helper `assert_invalid_handle:1341`,
  which also asserts the invalid-handle envelope carries NO context);
  `file_ffi.rs:280 (:304), :440 (:465), :524 (:569), :682 (:726)`;
  `git_ffi.rs:385 (:409), :635 (:660)`; `commit_views_ffi.rs:575 (:595)`;
  `workspace_ffi.rs:349 (:378)`; `bookmark_ops_ffi.rs:438 (:446)`.
- **No test anywhere pairs an invalid handle with a null/garbage buffer**, so no asserted code
  changes from the reorder alone.
- `bookmark_ops_ffi.rs:436` — the doc comment "A zero handle is refused BEFORE the request buffer
  is even looked at" becomes false and must be rewritten; `:440` builds ONE create buffer and
  feeds it to both wrappers — that cross-feed is the ledger's own cited evidence and becomes the
  new mismatch witness.
- Dart: no ordering-sensitive test. Every Dart test passing rawHandle `0` is an interior-NUL
  guard that throws in Dart before the FFI call; the worker-level `..._on_closed_handle_...`
  tests are synthesized in the isolate. But EVERY Dart cdylib test breaks if a lib producer
  misses the tag — that is witness (3).

**Docs to correct (the "structurally interchangeable" claims)**
- `docs/ffi-abi.md:140-157` the three-rung refusal ladder → four rungs plus the handle rung;
  `:188-192` "the same posture as the interchangeable-verification caveat below" → reword;
  `:194-205` "declares **15** request tables" + the APPEND-only sentence → the tag convention,
  `kind` as field 0, `Unspecified`, and the two `ChangeIdList` kinds; `:207-216` the whole
  "Known caveat — request tables verify interchangeably" block → replaced by the resolution.
- `docs/rust-error-codes.md:45` — the `ffi.invalid_argument` row gains the kind-mismatch emitter.
- `schemas/envelope.fbs:36-39` banner (above).
- Per-wrapper rustdoc: the `ffi.invalid_argument` bullet in each of the 16 `# Errors` blocks.
  Keep the added text free of any dotted-lowercase backticked token —
  `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs:188-234` harvests codes from bullet-START lines
  and `:273` asserts each doc index row names EXACTLY the codes its rustdoc does.

**Gates / bookkeeping**
- `Makefile.toml:289-295 codegen` (runs `codegen-flatc-rust:297`, `codegen-flatc-dart:316`,
  cbindgen, ffigen — in that order); `:510, :519` the `_generated\.rs$` coverage exclusions;
  `:537-564` the extern-fn coverage guard (no new extern fn, so nothing to add).
- `coverage-baseline.txt:14, 17, 19, 22, 23, 31, 35` — the seven touched zanshin-ffi files, all
  at 100.00.
- `_bmad-output/implementation-artifacts/deferred-work.md:194` — the bullet to strike through.
- `spec-9-6-…:128-142`, `spec-9-7-…:66-78`, `spec-9-8-…:12-24` — the three `deferred:` items that
  gain a `resolved: >-` block scalar (convention: `spec-9-8-…:35-40`).

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- add `enum RequestKind : ubyte { … }` (17 values, order above) with a
  doc comment stating that the tag is per-WRAPPER, that `Unspecified` is the absent-field default
  and is always refused, and that `ChangeIdList` therefore carries two kinds; prepend
  `kind: RequestKind;` to all 15 request tables; rewrite the `:31-39` banner so the APPEND-only
  rule reads as "`kind` is always field 0; any other field order change is an in-place WIP edit
  that regenerates BOTH committed sides in the same commit".
- `cargo make codegen` -- regenerate all four committed outputs; inspect the `zanshin_ffi.h` /
  `bindings.dart` diff (expected: doc-comment hunks only, after the rustdoc edits below).
- `crates/zanshin-ffi/src/envelope.rs` -- add `pub(crate) fn expect_request_kind(actual, expected)
  -> Result<(), FfiErrorObj>` under the "Shared request-buffer guards" banner, returning
  `ffi.invalid_argument` with a context naming both kinds; document why the check must precede
  the handle borrow.
- `crates/zanshin-ffi/src/{repo,file,git,commit_views,workspace,bookmark_ops}.rs` -- call
  `expect_request_kind` in each of the 16 readers immediately after `root_with_opts` and before
  any field read (`read_change_id_list` takes the expected kind as a parameter); swap the
  `session_from_handle` / `read_*_request` lines in each of the 16 wrappers; extend each
  `ffi.invalid_argument` rustdoc bullet to name the tag.
- `packages/zanshin_core/lib/src/ffi/{mutate,file,git,commit_views,workspace,bookmark_ops}.dart`
  -- set `kind:` in all 16 builders; `_withChangeIdListBytes` gains a `fbs.RequestKind` parameter
  so `zanshinNewChange` and `zanshinAbandon` pass different tags.
- `crates/zanshin-ffi/tests/{repo_write,file,git,commit_views,workspace,bookmark_ops}_ffi.rs` --
  set the tag in all 13 request-builder helpers; add one table-driven wrong-kind test per file
  covering EVERY wrapper in that file (each fed a buffer built for a different verb), plus an
  `Unspecified` (tag never set) case, plus the `BookmarkCreate` ↔ `BookmarkDelete` cross-feed in
  BOTH directions and the `NewChange` ↔ `Abandon` cross-feed; rework
  `a_zero_handle_is_refused_by_both_wrappers` to build the correct kind per wrapper and correct
  its doc comment.
- `packages/zanshin_core/test/ffi/bookmark_ops_test.dart` -- set the tag in the five wire-shape
  builders (`:33, 42, 51, 62, 70`) and assert it round-trips.
- `docs/ffi-abi.md` -- four-rung refusal ladder (null → verify → kind → handle → fields), the tag
  convention in "The request tables", the `Unspecified` rule, the two `ChangeIdList` kinds; delete
  the "Known caveat" block and the `:191` back-reference to it.
- `docs/rust-error-codes.md` -- extend the `ffi.invalid_argument` row with the kind-mismatch
  emitter (all sixteen wrappers).
- `_bmad-output/implementation-artifacts/deferred-work.md` + `spec-9-6-…`, `spec-9-7-…`,
  `spec-9-8-…` -- bookkeeping in the established convention (strike-through + `RESOLVED
  2026-09-06 (spec-epic-9-followup-h-request-kind-tag, commit <short>)`; `resolved: >-` blocks
  with valid YAML).

**Acceptance Criteria:**
- Given a buffer built for verb A, when it is passed to verb B's wrapper with a LIVE handle, then
  the envelope is `ok == false` with code `ffi.invalid_argument` and a `context` naming the
  expected and the received kind — for every one of the 16 wrappers.
- Given a buffer whose `kind` was never set, when any of the 16 wrappers reads it, then it is
  refused as `Unspecified`; no untagged buffer is ever accepted as any verb.
- Given a wrong-kind buffer and `handle == 0`, when the wrapper runs, then the answer is the KIND
  refusal, proving the check precedes the handle lookup.
- Given a correctly tagged buffer and `handle == 0`, when the wrapper runs, then the answer is
  `ffi.invalid_handle` with no context, unchanged from baseline.
- Given the full existing suite, when `cargo make test` runs, then every pre-existing happy-path
  test at the Rust FFI and Dart layers passes unchanged apart from the tag — which is what proves
  the 16 Dart builders set it.
- Given `docs/ffi-abi.md`, when the request-buffer section is read, then it documents the tag,
  the four-rung order and the `Unspecified` rule, no text at any of the three layers still calls
  the tables interchangeable, and `ffi_abi_doc_sync.rs` still passes with `EXPECTED_EXPORTS = 47`.
- Given `cargo make test`, when it completes, then the coverage ratchet is green with no baseline
  entry lowered and the seven touched `zanshin-ffi` files still at 100.00.

## Spec Change Log

### 2026-09-06 — Implementation (commit `4e4e710`)

Three points where the built change is narrower or wider than the spec's prose, recorded so the
next reader is not misled by the spec alone:

- **The refusal ladder is `null → verify → kind → fields → handle`, not `… → kind → handle →
  fields`.** The spec states the latter under *Boundaries*, but its own Task — "swap the
  `session_from_handle` / `read_*_request` lines" — necessarily moves the WHOLE reader, whose
  required-field guard (`missing_field`) is inside it, ahead of the handle borrow. Splitting them
  would mean calling each reader twice or threading the handle into it. Every stated Acceptance
  Criterion still holds: a CORRECTLY tagged, COMPLETE buffer with `handle == 0` still answers
  `ffi.invalid_handle` with no context. `docs/ffi-abi.md` documents the five-rung order as built.
- **One existing test's asserted code did change**, contradicting the Code Map's "No test anywhere
  pairs an invalid handle with a null/garbage buffer, so no asserted code changes from the reorder
  alone". That survey covered null/garbage buffers but not INCOMPLETE ones:
  `git_ffi.rs::git_remote_add_rejects_a_null_buffer_garbage_and_a_missing_field` reused its
  `url`-less buffer for the `handle == 0` row, which now answers `jj.invalid_input`. The row was
  given a complete buffer so it still witnesses the handle guard, with a comment saying why.
- **The wrong-kind rows mostly use a MINIMAL tagged buffer**, not a fully-populated other-verb
  buffer. A populated buffer of an incompatible shape is refused one rung EARLIER, by the
  Verifier — e.g. a `FileAnnotateRequest` fed to `zanshin_file_show` fails on `paths`, never
  reaching the kind check — so it cannot witness this change. With every field but `kind` absent
  all fifteen request tables serialise IDENTICALLY, which is the interchangeability at issue, so a
  minimal tagged buffer IS a buffer built for that verb. The pairs that are field-compatible carry
  a full payload: `BookmarkCreate` ↔ `BookmarkDelete`, `NewChange` ↔ `Abandon`,
  `GitRemoteAdd` ↔ `GitRemoteSetUrl`, `FileList` ↔ `FileShow`, `Show` ↔ `Evolog`.

Codegen drift was inspected and accepted rather than treated as the `unexpected codegen drift`
HALT: the `zanshin_ffi.h` / `bindings.dart` diff is `#define` / `const int` vtable-offset
constants (`*_VT_*`, plus `ENUM_MIN/MAX_REQUEST_KIND`) and nothing else — no `extern "C"`
declaration line moved, and nothing in the repo consumes those constants (verified by grep).
Their shifting is the direct, intended consequence of prepending field 0, which the spec's own
Code Map anticipates. One casualty worth naming: cbindgen emits only ONE constant per associated
name, so `FileChange_VT_KIND` disappeared from the header when `ChangeIdList_VT_KIND` appeared —
a pre-existing cbindgen behaviour affecting unused informational constants only.

## Review Triage Log

### 2026-09-06 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 11: (high 0, medium 4, low 7)
- defer: 0
- reject: 9: (high 0, medium 1, low 8)
- addressed_findings:
  - `[medium]` `[patch]` **The committed `zanshin_ffi.h` and `bindings.dart` were STALE**: codegen
    had run BEFORE the 16 rustdoc `# Errors` edits, so the header carried zero of the new `kind`
    clauses (`grep -c "built for a different wrapper"` → 0 in both, 2 in `bookmark_ops.rs` alone).
    Re-ran `cargo make codegen`; both now carry all 16. Nothing in the gate catches this —
    `verify-codegen` is deliberately not chained into `cargo make test` (`Makefile.toml:349`).
  - `[medium]` `[patch]` **The ledger's own four-way collision was never cross-fed with real
    tables.** `Show`/`Evolog`/`Interdiff`/`WorkspaceRoot` all put one string after `kind`, so a
    POPULATED cross-feed is exactly the ledger's demonstration; only show ↔ evolog carried a
    payload. Added populated rows: `WorkspaceRootRequest` → show / evolog / interdiff,
    `InterdiffRequest` → show (`commit_views_ffi.rs`), and `ShowRequest` → workspace_root
    (`workspace_ffi.rs`, with its own builder).
  - `[medium]` `[patch]` **7 of 16 wrappers had no order-witnessing row** (wrong kind + `handle
    == 0`), so the reader-before-handle move could regress for `evolog`, `interdiff`, `file_show`,
    `file_annotate`, `file_search`, `git_remote_set_url` and `absorb` with the suite still green.
    Every wrapper now has one.
  - `[medium]` `[patch]` **The one behaviour whose code CHANGED was asserted nowhere.** A dead
    handle plus an INCOMPLETE buffer now answers `jj.invalid_input` (rung 4 before rung 5); the
    only test that covered that combination was rewritten to avoid it. Pinned in
    `git_ffi.rs::git_remote_add_rejects_a_null_buffer_garbage_and_a_missing_field`.
  - `[low]` `[patch]` `docs/ffi-abi.md` called the caveat "the last open must-have on the central
    ledger" — three must-haves in that subsection are still open (`deferred-work.md:190, 192,
    215`). Corrected to "one of the cross-cutting must-haves … (others there remain open)".
  - `[low]` `[patch]` `bookmark_ops_ffi.rs` ended the kind table with the bare comment "No
    operation was written by any of the six refusals", asserting nothing. It now seeds a real
    `feature` bookmark and asserts both the op-log head and the bookmark list are unchanged —
    the glob-delete hazard itself, asserted rather than asserted-about.
  - `[low]` `[patch]` The out-of-range tag byte was undocumented and untested. FlatBuffers
    range-checks no enum (`RequestKind::run_verifier` is `u8::run_verifier`), so `kind = 200`
    verifies and reaches the same rung. Added a row asserting `got <UNKNOWN 200>` plus one
    sentence each in `docs/ffi-abi.md` and `envelope.rs`.
  - `[low]` `[patch]` `RequestKind` had no append-only banner, unlike every other reordering-
    sensitive enum in the schema (`FileType`, `GitRefUpdateKind`, `Payload`), and the rewritten
    request-table banner had dropped the append-only rule for NEW fields. Both restored.
  - `[low]` `[patch]` The ladder table did not say that rung 4 is the READER's own required-field
    guard (four readers have one) while jj-layer refusals land after rung 5, nor that the
    per-symbol `# Errors` bullets are an inventory, not the evaluation order. Both stated.
  - `[low]` `[patch]` `docs/rust-error-codes.md` recorded the reordering only on the
    `ffi.invalid_argument` row; the `ffi.invalid_handle` row now says it runs last for the sixteen
    request-buffer wrappers (the follow-up-C precedent of recording on both rows).
  - `[low]` `[patch]` Three live docs still asserted the tables are "structurally interchangeable"
    in the present tense as a bare fact (`schemas/envelope.fbs:49`, `envelope.rs:203`,
    `docs/ffi-abi.md:221`). Reworded to "nothing in the FlatBuffers layer tells them apart", which
    is the tag's rationale rather than an open caveat.

Rejected (not silently — recorded because a later reader may re-derive them): a guard against
`expect_request_kind(_, Unspecified)` (unreachable internal misuse; the project bans error
handling for impossible scenarios, and the line would be uncovered under a 100.00 % file);
replacing the generated `Debug` with a hand-written label match (17 uncovered lines, same
reason); a "the 16 expected kinds are pairwise distinct" test (not cheaply expressible — the
kinds live inside private readers, and the cross-feed tables already catch every same-kind slip
that a cross-feed row covers); deduplicating `tagged_request_bytes` across the six suites (each
`tests/*.rs` is its own crate and `test-helpers` cannot depend on `zanshin-ffi` — the dev-dep
direction is the reverse, so the duplication is forced); adding "even when `handle` is 0" to the
16 `# Safety` blocks (the `data`/`len` obligation was already unconditional there); chaining
`verify-codegen` into `cargo make test` (pre-existing, deliberate — `Makefile.toml:349`); a
Dart→Rust end-to-end refusal test (the numbering agreement it would witness is already proved by
every Dart happy-path call through the real cdylib); editing the bodies of the completed 9.6 /
9.7 / 9.8 specs (historical records; the convention is the `resolved:` frontmatter block, which
they have); and a `file_identifier` (explicitly rejected by Ralph).

**Not treated as `unexpected codegen drift`, second occurrence.** Re-running codegen after the
rustdoc edits re-wrapped eight `extern "C"` declarations across three lines each
(`zanshin_bookmark_create`, `_bookmark_delete`, `_interdiff`, `_file_annotate`, `_file_search`,
`_git_remote_add`, `_git_remote_set_url`, `_workspace_root`). No parameter type, name or order
changed, and `bindings.dart`'s non-doc diff is empty. The wrapping is cbindgen's own deterministic
output for the current source — the same binary produced it — so committing it is what makes the
header match `cargo make codegen`; halting would have frozen a header that provably does not.

**Ledger accounting.** The cbindgen constant casualty (`FileChange_VT_KIND` displaced by
`ChangeIdList_VT_KIND`) was NOT filed as a new deferral: `deferred-work.md:49` already tracks
"`cbindgen.toml` `[export] exclude` list is hand-maintained per symbol — new schemas generating
fresh `VT_*`/`ENUM_*` consts will leak into `zanshin_ffi.h`". The newly observed part (cbindgen
emits one constant per BARE name, so a new table's `kind` displaces an older table's) was
appended to that existing bullet as evidence. The ledger therefore ends this run strictly
smaller: one must-have struck through, no bullet added.

## Design Notes

**Why the tag lives in the table and not in a `file_identifier`.** Ralph's call, 2026-09-06. A
`file_identifier` is a 4-byte prefix checked by `root_with_opts` only when the generated type
declares one; it would force `finish_size_prefixed`-style discipline on every producer and gives
no room for two kinds over one shared table. A `kind` field is ordinary schema, is set by the
same generated builder every producer already uses, and reads back through the same accessor.

**Why `Unspecified = 0` is load-bearing.** FlatBuffers writes no bytes for a field equal to its
default, so a buffer built by a producer that never sets `kind` is BYTE-IDENTICAL to a
pre-change buffer and decodes as `Unspecified`. That makes "legacy buffer" and "forgotten tag"
the same, always-refused state — and it makes the `Unspecified` witness trivial to build
(construct with `RequestKind::Unspecified`; flatc emits nothing).

**Context wording.** The message names the RequestKind VARIANT, not the table:
`request kind mismatch: expected BookmarkDelete, got BookmarkCreate`. Two kinds share the
`ChangeIdList` table, so a table-named message would read `expected ChangeIdList, got
ChangeIdList` for the one pair where the distinction matters most. For the other 14 the variant
name plus `Request` IS the table name, so nothing is lost. Use the generated `Debug` impl
(`{:?}`) rather than a hand-written 17-arm label match: a match would add 17 source lines to a
file the ratchet holds at 100.00 %, each needing its own test to stay covered.

```rust
pub(crate) fn expect_request_kind(actual: fbs::RequestKind, expected: fbs::RequestKind) -> Result<(), FfiErrorObj> {
    if actual == expected {
        return Ok(());
    }
    Err(FfiErrorObj {
        code: FFI_INVALID_ARGUMENT.to_owned(),
        context: Some(format!("request kind mismatch: expected {expected:?}, got {actual:?}")),
    })
}
```

**The reorder is the point, not a side effect.** Today all 16 wrappers borrow the handle first.
A mis-routed buffer must be refused on its own merits, so the request-buffer rungs move ahead of
the handle rung. The only observable change is for callers that get BOTH wrong at once, and no
existing test exercises that combination.

**Residual, deliberately not addressed:** the tag guards the WIRE, not the caller. A caller that
bypasses the generated adapters can still set the tag by hand; the tag turns a silent
mis-execution into a refusal, which is what the ledger asked for.

## Verification

**Toolchain (this shell):** `cargo`, `dart` and `flutter` are NOT on the default `PATH`. Prefix
every such command with:
`export SDK_PATH=$HOME/development/sdks RUSTUP_HOME=$SDK_PATH/rustup CARGO_HOME=$SDK_PATH/cargo FLUTTER_ROOT=$SDK_PATH/flutter PATH=$FLUTTER_ROOT/bin:$CARGO_HOME/bin:$PATH`
(one `bash -c` per invocation). `flatc 25.12.19` is already on the default `PATH`. Run
`cargo make test` UNPIPED and synchronously; it takes ~15 minutes. Disk is tight (~3.6 GiB free):
on `No space left on device` delete only `target/debug/incremental`, `target/llvm-cov-target` or
`target/release` and retry — nothing outside `target/`, never `git clean`, never touch the
pre-existing `git stash` entry.

**Commands:**
- `cargo make codegen` -- expected: exit 0; `git diff --stat` shows the four committed codegen
  outputs; `git diff crates/zanshin-ffi/include/zanshin_ffi.h packages/zanshin_core/lib/src/ffi/bindings.dart`
  shows doc-comment hunks only (no declaration line moves).
- `cargo make test` -- expected: exit 0. Rust workspace tests, clippy pedantic `-D warnings`,
  rustfmt, `flutter test`, `dart analyze`/`format`, `cargo deny`, and the coverage ratchet all
  green; `coverage-baseline.txt` unchanged or raised, never lowered.
- `grep -rn "interchangeab" docs/ schemas/ crates/ packages/` -- expected: no hit that presents
  interchangeability as an unmitigated present-tense caveat. Naming it as the RATIONALE for the
  tag, or as the historical hazard a test closes, is what the surviving hits are (one in
  `docs/ffi-abi.md`, the rest test doc comments).
- `python3 -c "import yaml,sys; [yaml.safe_load(open(p).read().split('---')[1]) for p in sys.argv[1:]]" <the three specs>`
  -- expected: exit 0 (frontmatter still parses after the `resolved:` blocks).

## Auto Run Result

Status: done
Blocking condition: none

### Summary

Every FlatBuffers request table now carries `kind: RequestKind` as field 0, and every one of the
sixteen request-buffer wrappers refuses a buffer whose tag is not its own — before the handle is
borrowed and before any other field is read. The tag is per-WRAPPER, not per-table: the two
wrappers that share `ChangeIdList` carry the distinct kinds `NewChange` and `Abandon`, which is
the one collision a per-table tag could not have closed (a buffer meant as `parents` would
otherwise abandon those commits). `Unspecified = 0` is FlatBuffers' absent-field default, so an
untagged buffer is byte-identical to a pre-tag one, decodes as `Unspecified`, and is always
refused. This closes the ledger's "Request tables verify interchangeably" must-have.

### Files changed

- `schemas/envelope.fbs` -- `enum RequestKind : ubyte` (17 values, append-only banner) plus
  `kind` as field 0 of all 15 request tables; the request-table banner now states the field-0 rule
  and the regenerate-both-sides rule.
- `crates/zanshin-ffi/src/envelope.rs` -- one `pub(crate) fn expect_request_kind`, next to
  `reject_null_request`; mismatch → `ffi.invalid_argument`, context
  `request kind mismatch: expected <K>, got <K>`.
- `crates/zanshin-ffi/src/{repo,file,git,commit_views,workspace,bookmark_ops}.rs` -- 15 readers
  check the tag right after `root_with_opts`; 16 wrappers call their reader before
  `session_from_handle`; 16 `# Errors` rustdoc bullets extended.
- `crates/zanshin-ffi/src/envelope_generated.rs`, `.../bindings.dart`,
  `.../envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h` --
  regenerated (twice: the first run predated the rustdoc edits and shipped a stale header).
- `packages/zanshin_core/lib/src/ffi/{mutate,file,git,commit_views,workspace,bookmark_ops}.dart`
  -- all 16 builders set the tag; `_withChangeIdListBytes` takes it as a parameter.
- `crates/zanshin-ffi/tests/{repo_write,file,git,commit_views,workspace,bookmark_ops}_ffi.rs` --
  13 builder helpers tag their buffers; six wrong-kind tables covering every wrapper, every
  wrapper with a `handle == 0` row, populated cross-feeds for the ledger's named four-way
  collision and both bookmark directions, an untagged row per wrapper, an out-of-range-byte row,
  and the seeded-bookmark survival assertion.
- `packages/zanshin_core/test/ffi/bookmark_ops_test.dart` -- the tag round-trips through the Dart
  builder and reader.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- the five-rung ladder, the tag convention, the
  `Unspecified` and out-of-range rules, the rung-4-vs-rung-5 clarification, both registry rows.
- `_bmad-output/implementation-artifacts/deferred-work.md` + `spec-9-6-…`, `spec-9-7-…`,
  `spec-9-8-…` -- the must-have struck through and marked resolved; three `resolved:` blocks.

### Review findings breakdown

- Patches applied: 11 (medium 4, low 7) — listed in the Review Triage Log above.
- Items deferred: 0. The one candidate (a public `#define` displaced by cbindgen's per-bare-name
  dedupe) was appended as evidence to the pre-existing ledger bullet at `deferred-work.md:49`
  rather than filed as a new entry, so the ledger ends this run strictly smaller.
- Items rejected: 9 — each named in the Review Triage Log with its reason, rather than dropped
  silently.

Follow-up review recommended: **true** (patched: high 0, medium 4, low 7 → 3×4 + 7 = 19 ≥ 5).

### Verification performed

- `cargo make codegen` -- exit 0, run again after the rustdoc edits. `bindings.dart`'s non-doc
  diff is empty; `zanshin_ffi.h` gained the 16 kind clauses and re-wrapped eight declarations
  across three lines each (no parameter type, name or order changed) — cbindgen's own
  deterministic output for the current source, accepted rather than halted on, with the reasoning
  in the Review Triage Log.
- `cargo clippy --workspace --all-targets -- -D warnings` -- exit 0 after refactoring the two
  over-long test fns into a shared `assert_kind_mismatches` driver and giving the bookmark table a
  `KindCase` alias (no `#[allow]` was added).
- `cargo make test` -- exit 0. Coverage held at **99.22 % (8516/8583 lines over 46 files)**;
  `coverage-baseline.txt` unchanged; `extern-coverage: OK` for every `extern "C"` fn.
- `grep -rn "interchangeab" …` -- one live doc hit, naming the CLOSED caveat; the rest are test
  doc comments describing the hazard the tag closes.
- The three touched spec frontmatters plus this one parse as YAML.

### Residual risks

- The tag guards the WIRE, not the caller: a caller bypassing the generated adapters can still set
  it by hand. What it removes is the silent mis-EXECUTION.
- The reordering is observable for callers that get two things wrong at once: a dead handle plus a
  null, unverifiable, mis-tagged or incomplete buffer now answers the buffer's refusal instead of
  `ffi.invalid_handle`. Documented in both registry rows and pinned by a test.
- Nothing in `cargo make test` proves the committed codegen matches the schema —
  `verify-codegen` is deliberately manual (`Makefile.toml:349`). This run shipped a stale header
  once because of that; the second codegen run fixed it, but the gap itself remains.
- 14 of the 15 tagged tables now export no `_VT_KIND` constant to the C header at all (cbindgen
  dedupes by bare name). Informational constants only, nothing consumes them; tracked at
  `deferred-work.md:49`.

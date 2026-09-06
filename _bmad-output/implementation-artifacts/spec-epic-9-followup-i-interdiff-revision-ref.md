---
title: 'Epic 9 follow-up I: `interdiff` takes a commit-id-or-change-id union (`RevisionRef`)'
type: 'feature'
created: '2026-09-06'
status: 'in-progress'
baseline_revision: '8e3a8f8eef8dfec76d39193db0eaccf2228486e8'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** `interdiff` resolves `from`/`to` through `op_support::resolve_commit`, which takes a
reverse-hex CHANGE-id prefix and `into_visible()`s it — so only the currently VISIBLE commit of a
change is addressable. The CLI's `--from`/`--to` go through `resolve_single_rev`, which accepts a
commit hex and therefore reaches a HIDDEN predecessor. `EvologEntry.predecessor_commit_ids` are
hidden COMMIT ids, so the spec's own stand-in for the unported `evolog --patch` ("compose `evolog`
+ `interdiff`") is inexpressible and Story 9.6's motivating question — what differs between two
versions of one change — is unanswerable through the shipped API. Ledger must-have at
`_bmad-output/implementation-artifacts/deferred-work.md:201`.

**Approach:** Ralph's decision (2026-09-06) is a **union currency for `interdiff` only**:
`schemas/envelope.fbs` gains `table ChangeIdRef { id: string; }`, `table CommitIdRef { id: string; }`
and `union RevisionRef { ChangeIdRef, CommitIdRef }`; `InterdiffRequest.from`/`.to` change from
`string` to `RevisionRef` in place. `zanshin-jj` gains a `jj_lib`-type-free
`pub enum RevisionRef { ChangeId(ChangeId), CommitId(CommitId) }`, `Repo::interdiff` takes
`Option<RevisionRef>` twice, and a new `op_support::resolve_commit_id_prefix` resolves the commit
arm through jj-lib's INDEX prefix lookup — which is visibility-blind, so a hidden predecessor
resolves. The union is lifted through the FFI reader, committed codegen, the Dart adapter,
`WorkerCommand`, `ZanshinWorker`, `RepoHandle` and `docs/ffi-abi.md`. Closing run for that one
ledger entry; the only other work is bookkeeping.

## Boundaries & Constraints

**Always:**
- **`interdiff` ONLY.** `show`, `evolog` and every other verb keep their currency untouched.
  `diff` (a later story) may adopt the union then. The change-id arm resolves EXACTLY as today
  (`op_support::resolve_commit`, `into_visible()`, divergence refused) — a passing test that
  refuses a divergent or hidden change id must keep failing the same way.
- **Three-stage taxonomy for the COMMIT arm**, mapped onto EXISTING `CommitViewError` variants and
  EXISTING registry codes: malformed (empty or non-hex) → `InvalidInput` → `jj.invalid_input`;
  ambiguous prefix → `RevsetResolutionError` → `jj.revset_resolution_error` (the registry's
  ambiguity code, Meaning column already says "ambiguous id"); no match → `ChangeNotFound` →
  `jj.change_not_found` (the existing not-found code, `id` echoed in `context`); an index/store
  failure → `Backend` → `jj.jj_lib_error`. **No new error code is minted.**
- `kind: RequestKind` stays field 0 of `InterdiffRequest` and `RequestKind` gains no variant —
  follow-up H's tagging is untouched. The two new tables are NESTED union members, not request
  roots: the schema still declares 15 request tables and `EXPECTED_EXPORTS` stays 47.
- Schema is edited in place (WIP rule): one `cargo make codegen`, all four committed outputs
  (`envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`,
  `bindings.dart`) committed with the sources. Run codegen AFTER the rustdoc edits so the header
  is not shipped stale (follow-up H's lesson).
- An ABSENT side keeps its meaning: the CLI's `@` default; BOTH absent stays `jj.invalid_input`.
- Every public signature stays `jj_lib`-type-free; `#![deny(missing_docs)]` satisfied; clippy
  pedantic clean without new `#[allow]`; SPDX first line on any new file.
- `crates/zanshin-ffi/src/commit_views.rs` is at **100.00 %** in `coverage-baseline.txt` — every
  new reader branch must be executed by a test. No branch may be defensive-and-unreachable (the
  FlatBuffers verifier already refuses an inconsistent union, see Design Notes).
- `zanshin_interdiff` keeps a `packages/zanshin_core` cdylib test (coverage attribution).
- Doc text at EVERY layer that says the change-id currency is "mandated", that a commit hex or
  hidden commit is "unaddressable", or that `evolog` and `interdiff` "do not compose" is corrected
  — including the generated mirror, which is fixed by regenerating from the `.fbs`.

**Block If:**
- `flatc` is absent or is not `25.12.19` → HALT, blocking condition `flatc version mismatch`.
- The codegen diff changes an `extern "C"` parameter's TYPE, NAME or ORDER in `zanshin_ffi.h` /
  `bindings.dart` → HALT, blocking condition `unexpected codegen drift`. (Doc-comment hunks,
  cbindgen re-wrapping of unchanged declarations, and `*_VT_*` / `ENUM_MIN/MAX_*` constant churn
  are EXPECTED here — the union adds vtable slots — and are inspected, not halted on.)
- jj-lib 0.44.0 does not expose commit-id-prefix resolution reachable from `&dyn Repo`
  (`Index::resolve_commit_id_prefix` + `Store::get_commit`) → HALT, blocking condition
  `commit-prefix resolution unavailable`.

**Never:**
- No `IdPrefixContext` / `revsets.short-prefixes` disambiguation set (see Design Notes) — so
  `zanshin_interdiff` still reads NO config and still never emits `jj.config_error` or
  `jj.revset_parse_error`.
- No tag/bookmark fallback and no change-id fallback for a `CommitIdRef`: the arm IS the commit-id
  currency (the CLI's `commit_id()` reading), not a revset symbol resolver.
- No fixture regeneration (`test-fixtures/` is frozen) — the rewritten-history repo is constructed
  in-test.
- No new `extern "C"` symbol, no new `RequestKind` variant, no `file_identifier`, no new
  dependency, no new error code.
- No lowering of `coverage-baseline.txt`, no new `exclude_prefix`, no `#[ignore]`.
- Do not touch `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` beyond what a green run requires.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| The motivating composition | `from = CommitIdRef(evolog head's predecessor_commit_ids[0])`, `to = ChangeIdRef(that change)`; the change was rewritten with different file content | The per-path diff between the two VERSIONS of the change | No error expected |
| Same string, change arm | `from = ChangeIdRef(<that commit hex>)` | Refused exactly as today (a commit hex is not valid reverse-hex) | `jj.change_not_found`, hex in `context` |
| Ambiguous commit prefix | `from = CommitIdRef("<prefix shared by ≥2 commits>")` | Refused, never guessed | `jj.revset_resolution_error`, jj-lib's "Commit ID prefix … is ambiguous" wording in `context` |
| Malformed commit ref | `from = CommitIdRef("")` or `CommitIdRef("nothex!")` | Refused as a structurally invalid argument | `jj.invalid_input`, the offending value in `context` |
| Unknown commit prefix | `from = CommitIdRef("deadbeef…")`, valid hex, no match | Refused as not found | `jj.change_not_found`, prefix in `context` |
| Both arms absent | `from`/`to` both absent from the buffer | Unchanged refusal (the CLI's `ArgGroup`) | `jj.invalid_input` |
| One arm absent | Only `to` present | The absent side is `@` (last-snapshotted), unchanged | No error expected |
| Union value without discriminant | `from` value table present, `from_type` never set (reads as `NONE`) | Refused by the FlatBuffers verifier before any field is read | `ffi.invalid_argument`, verifier's inconsistent-union message |
| Out-of-range discriminant | `from_type` byte = 200, value present | Verifies (FlatBuffers range-checks no union tag), then refused by the reader | `ffi.invalid_argument`, context names the unknown tag |
| Ref with absent inner id | `from_type = ChangeIdRef`, table present, `id` absent | Refused by the reader's required-field guard (ladder rung 4) | `jj.invalid_input`, field name in `context` |
| Wrong-verb buffer | A `ShowRequest`-tagged buffer fed to `zanshin_interdiff` | Still refused (kind tag, or one rung earlier by the verifier now that the layouts differ) | `ffi.invalid_argument` |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `8e3a8f8`.

**Schema**
- `schemas/envelope.fbs:31-43` request-table banner (field order IS the wire contract; `kind`
  always field 0; regenerate BOTH sides in one commit) — extend, do not weaken.
  `:45-82` `RequestKind` + its append-only banner — **not touched**.
  `:244-255` `EvologRequest` (declaration order: new tables + union go AFTER it, BEFORE
  `InterdiffRequest`; FlatBuffers requires member tables before the union and the union before its
  user). `:257-270` `InterdiffRequest` doc — `:259-265` is the "do NOT compose" paragraph to
  rewrite. `:271-276` the table (`kind`, `from: string`, `to: string`, `paths`).
  `:906-909` `EvologEntry.predecessor_commit_ids` doc — "cannot be fed to `zanshin_interdiff`".
  `:983-1010` `Payload` union — house style for a union decl; RESPONSE-only, not touched.
  `ChangeIdList:84-90` — precedent for a shared helper table declared before its users.

**`zanshin-jj`**
- `crates/zanshin-jj/src/op_support.rs:445-451` §5 banner (shared resolution rules);
  `:453-463` `ResolveError`; `:465-500` `resolve_commit` (change-id, `into_visible()`) — the new
  commit-arm resolver goes next to it; `:502-529` `resolve_or_wc`; `:555-564` `build_matcher`.
- `crates/zanshin-jj/src/commit_views.rs:33-40` module currency paragraph;
  `:101-126` `EvologEntry` (+ `:105` "which the crate's single-revision resolver refuses");
  `:128-178` `CommitViewError` (`ChangeNotFound:135-144`, `InvalidInput:145-151`,
  `RevsetResolutionError:158-164`); `:199-208` `res` (ResolveError → taxonomy);
  `:395-430` `interdiff` rustdoc (`:402-409` the address-space paragraph, `:422-430` `# Errors`);
  `:431-471` the fn (`:434-435` the two `Option<&ChangeId>` params, `:449-450` the two
  `resolve_or_wc` calls); `:473-530` inline tests (`res_preserves_…:511`).
- `crates/zanshin-jj/src/repo.rs:1093-1104` `Repo::interdiff` (`#[allow(clippy::needless_pass_by_value)]`
  + the owned-`ChangeId` WHY comment at `:1094-1096`); `:1024-1026` and `:1060-1062` the two
  `evolog` doc paragraphs claiming non-composition.
- `crates/zanshin-jj/src/lib.rs:54` `pub use commit_views::{…}` — re-export `RevisionRef` here.

**`zanshin-ffi`**
- `crates/zanshin-ffi/src/commit_views.rs:33-49` `map_commit_view_err` (already covers all six
  variants — no change needed); `:51-56` reader banner (SAFETY argument, cited by
  `docs/ffi-abi.md:143`); `:74-80` `InterdiffRequestOwned`; `:124-142` `read_interdiff_request`;
  `:326-369` `zanshin_interdiff` rustdoc (`:333-335` the non-composition sentence, `:353-364`
  `# Errors`); `:370-384` the wrapper; `:386-615` inline tests.
- `crates/zanshin-ffi/src/envelope.rs:183` `reject_null_request`, `:194` `invalid_request`,
  `:213-221` `expect_request_kind`, plus `missing_field` (the rung-4 helper —
  `git.rs:70-71` is the call-site precedent), `:267` `session_from_handle`.
- `crates/zanshin-ffi/src/lib.rs:27` `pub use envelope_generated::zanshin::ffi as fbs`.
- Generated Rust union accessors to use: `req.from_type() -> fbs::RevisionRef`,
  `req.from() -> Option<Table>`, `req.from_as_change_id_ref() -> Option<fbs::ChangeIdRef>`
  (pattern: `envelope_generated.rs:11820-11880` for `Payload`).

**Dart (`packages/zanshin_core/lib/src/`)**
- `ffi/commit_views.dart:99-126` `zanshinInterdiff` (NUL guards `:116-118`, builder `:119-124`);
  `:146-167` `InterdiffView`; `:170-196` `EvologEntry` (`:186-189` "cannot be passed to
  [zanshinInterdiff]"); `:255-271` the interdiff decoder (unchanged).
- `ffi/bookmarks.dart:24-48` `sealed class BookmarkKind` + two `final class` subtypes — the house
  style to copy for `RevisionRef`.
- `ffi/request_bytes.dart:69-73` `rejectInteriorNul`, `:110-113` `callWithRequest`.
- `worker/commands.dart:11` `sealed class WorkerCommand`; `:697-718` `InterdiffCommand`
  (`from`/`to` are `String?` at `:709-714`). All command fields are primitives today —
  `RevisionRef` is the first object crossing the port; `Isolate.spawn` isolates share a code
  group, so a plain final-field class is sendable.
- `worker/isolate.dart:1138-1177` `ZanshinWorker.interdiff` (`:1144-1145` the unaddressable
  claim); `:1779-1793` the `InterdiffCommand` dispatch arm.
- `worker/handle.dart:5` import list; `:660-694` `evolog` (`:676-678` the claim); `:696-735`
  `RepoHandle.interdiff` (`:704-706` the claim).
- `packages/zanshin_core/lib/zanshin_core.dart` exports neither `InterdiffView` nor `RepoHandle`
  — the new type needs NO barrel entry.

**Tests**
- `crates/zanshin-jj/tests/commit_views.rs:136-167` `interdiff_pair`; `:691-698` `evolution_chain`
  (describe-twice — DESCRIPTION-only, so its versions share a tree); `:868`, `:894`, `:914`,
  `:933`, `:950`, `:979` (the address-space test), `:1035`, `:1090`, `:1115` interdiff tests.
- `crates/zanshin-ffi/tests/commit_views_ffi.rs:161-180` `interdiff_request_bytes`;
  `:198-207` `open_evolution_scenario`; `:211` `open_interdiff_scenario`; `:455`, `:499`,
  `:529` interdiff round-trips; `:578` handle/buffer guard table; `:634` no-op-written;
  `:690-792` the kind-mismatch table (`:695-702` documents the FOUR-WAY "one string after `kind`"
  collision — that claim changes for `InterdiffRequest`; rows `:720-727`, `:744-759`, `:762-769`,
  `:780-787` touch interdiff); `:794-814` `assert_kind_mismatches`; `:843` `tagged_request_bytes`.
- `crates/zanshin-ffi/tests/workspace_ffi.rs` — one row feeds an `InterdiffRequest` to
  `zanshin_workspace_root`; re-verify it after the layout change.
- `crates/zanshin-jj/tests/api_stability.rs:110`, `:341-344`, `:658-663` (the doc naming the
  parameter-currency split as a deliberate tripwire), `:667-720` `commit_views_surface_resolves`
  (`:713-719` pins `Repo::interdiff`'s exact fn-pointer type — MUST be updated).
- `packages/zanshin_core/test/ffi/commit_views_test.dart:292-315` the three NUL tests (signature
  change); `:219-290` the decode-contract group (unchanged).
- `packages/zanshin_core/test/worker/commit_views_test.dart:154`, `:178`, `:202`, `:215` —
  the real-cdylib rows carrying `from:`/`to:`.
- `crates/test-helpers/src/lib.rs:196-222` `add_commit_with_files`, `:294-315` `describe_commit`
  (the template for a content-rewriting helper), `:323` `add_divergent_twin`. Coverage-excluded
  (`coverage-baseline.txt:11`).

**Docs / gates / bookkeeping**
- `docs/ffi-abi.md:140-163` refusal ladder (`:157-159` claims interdiff's rung-4 guard is "the
  from+to pair" — that guard is a jj-layer refusal AFTER rung 5; the real rung-4 guard is the new
  `from.id`/`to.id` one); `:213-225` "declares **15** request tables"; `:297-298` table header;
  `:312` the `zanshin_interdiff` row (error-code column).
- `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` — harvests codes from `# Errors` bullet-START
  lines and asserts each doc row names EXACTLY those codes: the rustdoc and the `:312` row must
  gain `jj.revset_resolution_error` TOGETHER.
- `docs/rust-error-codes.md:47` (`jj.change_not_found`), `:54` (`jj.revset_parse_error` — "its two
  sides are single change ids"), `:55` (`jj.revset_resolution_error`), `:58` (`jj.invalid_input`),
  `:56` (`jj.config_error` — "reads no config", still true).
- `coverage-baseline.txt:17` zanshin-ffi/commit_views.rs = 100.00, `:19` envelope.rs = 100.00,
  `:43` zanshin-jj/commit_views.rs = 98.13, `:52` op_support.rs = 99.59, `:54` repo.rs = 96.46.
- `_bmad-output/implementation-artifacts/deferred-work.md:201` — the bullet to strike through.
- `spec-9-6-read-views-show-evolog-interdiff.md:11-29` — the first `deferred:` item gains a
  `resolved: >-` block (convention: the same file's `:45-…`).

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- add `table ChangeIdRef { id: string; }`, `table CommitIdRef { id: string; }`
  and `union RevisionRef { ChangeIdRef, CommitIdRef }` before `InterdiffRequest`, each with a doc
  comment stating the currency (reverse-hex change-id prefix vs commit-id HEX prefix, the latter
  visibility-blind so a hidden predecessor resolves); change `from`/`to` to `RevisionRef`; rewrite
  the `InterdiffRequest` doc and the `EvologEntry.predecessor_commit_ids` doc so they describe the
  composition instead of denying it; extend the request-table banner to note that a union field
  occupies TWO vtable slots.
- `crates/zanshin-jj/src/op_support.rs` -- add `pub(crate) enum CommitPrefixError { Malformed,
  Ambiguous, NotFound, Backend(String) }` and `pub(crate) fn resolve_commit_id_prefix(repo: &dyn
  Repo, id: &crate::CommitId) -> Result<Commit, CommitPrefixError>` next to `resolve_commit`:
  empty → `Malformed`, `HexPrefix::try_from_hex` → `None` = `Malformed`,
  `repo.index().resolve_commit_id_prefix(&prefix)` → `SingleMatch` → `repo.store().get_commit`,
  `AmbiguousMatch` → `Ambiguous`, `NoMatch` → `NotFound`. Document WHY the index lookup (not a
  revset, not an `IdPrefixContext`) and that it therefore reaches hidden commits.
- `crates/zanshin-jj/src/commit_views.rs` -- add `pub enum RevisionRef { ChangeId(ChangeId),
  CommitId(CommitId) }` (doc: which currency each arm is, and that ONLY `interdiff` takes it); add
  a private `res_commit` mapping `CommitPrefixError` onto the taxonomy above and a private
  side-resolver dispatching absent/change/commit; change `interdiff` to
  `from: Option<&RevisionRef>, to: Option<&RevisionRef>`; rewrite the `:402-409` address-space
  paragraph and the `# Errors` block (add the ambiguity and malformed bullets); update the module
  currency paragraph `:33-40`.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::interdiff` takes `Option<crate::RevisionRef>` twice;
  rewrite the two `evolog` doc paragraphs that say the verbs do not compose (point at the
  `CommitIdRef` arm instead).
- `crates/zanshin-jj/src/lib.rs` -- re-export `RevisionRef`.
- `crates/zanshin-ffi/src/commit_views.rs` -- `InterdiffRequestOwned` holds
  `Option<zanshin_jj::RevisionRef>` twice; the reader dispatches on `from_type()`/`to_type()`
  (NONE → `None`; `ChangeIdRef`/`CommitIdRef` → one `ok_or_else(|| missing_field("from.id"))`
  each; any other tag → `ffi.invalid_argument` naming the unknown tag); extend the reader's and
  the wrapper's `# Errors` blocks (`jj.revset_resolution_error` added, `jj.change_not_found`
  reworded, `jj.invalid_input` widened) and rewrite the `:333-335` non-composition sentence.
- `cargo make codegen` -- run it FIRST right after the `.fbs` edit (nothing Rust- or Dart-side
  compiles until `fbs::RevisionRef` and the two ref tables exist), and run it AGAIN as the last
  step before the gate, once every rustdoc `# Errors` block is final — the header is generated
  from the rustdoc and follow-up H shipped a stale one by skipping the second run. Commit all four
  outputs.
- `packages/zanshin_core/lib/src/ffi/commit_views.dart` -- add `sealed class RevisionRef` with
  `final class ChangeIdRef` / `final class CommitIdRef` (both carrying `id`), modelled on
  `BookmarkKind`; `zanshinInterdiff` takes `RevisionRef?` twice, NUL-guards the inner ids and sets
  `fromType`/`from` (and `toType`/`to`) from the generated `RevisionRefTypeId` + ref builders;
  rewrite the `predecessorCommitIds` doc.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- `InterdiffCommand`,
  `ZanshinWorker.interdiff` and `RepoHandle.interdiff` take `RevisionRef?` twice; keep the
  calling-side NUL guard as the primary one; rewrite every doc sentence claiming a commit hex or a
  hidden commit is unaddressable.
- `crates/test-helpers/src/lib.rs` -- add a `rewrite_commit_files` helper (a `describe_commit`
  twin that also sets a new tree) so a change can be rewritten with different CONTENT; document
  that this is what makes an evolog predecessor's interdiff non-empty.
- `crates/zanshin-jj/tests/commit_views.rs` -- migrate every interdiff call to the union; add the
  motivating-composition test (rewrite content, take `predecessor_commit_ids[0]`, interdiff
  `CommitIdRef(pred)` against `ChangeIdRef(change)`, assert the version diff AND that the same hex
  as a `ChangeIdRef` still refuses); add a refusal table covering malformed / ambiguous / unknown.
  Build the ambiguous prefix DETERMINISTICALLY: add commits until two commit ids share their first
  hex digit (guaranteed within 17 by pigeonhole over 16 digits), then use that one-char prefix.
- `crates/zanshin-ffi/tests/commit_views_ffi.rs` -- make `interdiff_request_bytes` union-aware; add
  the commit-arm round trip through the FFI, the three refusal codes, the absent-inner-id
  (`jj.invalid_input`), the value-without-discriminant (`ffi.invalid_argument`, verifier) and the
  out-of-range-tag (`ffi.invalid_argument`, reader) rows; re-verify and re-comment every
  kind-mismatch row involving `InterdiffRequest`, including the four-way-collision doc block.
- `crates/zanshin-ffi/tests/workspace_ffi.rs` -- re-verify the row that feeds an `InterdiffRequest`
  to `zanshin_workspace_root`; update its comment if the refusal rung moved.
- `crates/zanshin-jj/tests/api_stability.rs` -- update the pinned `Repo::interdiff` fn-pointer type
  and the doc that explains the currency split (it is now a union for this ONE verb); add
  `RevisionRef` to the pinned surface.
- `packages/zanshin_core/test/ffi/commit_views_test.dart` -- NUL tests pass `ChangeIdRef(...)`;
  add a wire-shape test asserting the built buffer carries the right discriminant and id for both
  arms (read back through the generated reader).
- `packages/zanshin_core/test/worker/commit_views_test.dart` -- keep the existing rows green and
  add one real-cdylib call with a `CommitIdRef` built from a commit id read back through an
  existing verb, plus one refusal row proving a Dart-built `CommitIdRef` reaches the Rust
  resolver.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- the `zanshin_interdiff` row's error-code list,
  the rung-4 sentence (name the real reader guard), the request-table count nuance (the two new
  tables are nested union members, not roots), and rows `:47`, `:54`, `:55`, `:58`.
- `_bmad-output/implementation-artifacts/deferred-work.md` + `spec-9-6-…` -- bookkeeping in the
  established convention (strike-through + `RESOLVED 2026-09-06 (spec-epic-9-followup-i-interdiff-revision-ref,
  commit <short>)`; a `resolved: >-` block, frontmatter still parses).

**Acceptance Criteria:**
- Given a change rewritten with different file content, when the head evolog entry's
  `predecessor_commit_ids[0]` is passed as `from = CommitIdRef` and the change as
  `to = ChangeIdRef`, then the result is the per-path diff between the two versions — witnessed in
  `zanshin-jj`, through the FFI envelope, and (for the shape) from Dart.
- Given that same commit hex passed as a `ChangeIdRef`, when `interdiff` runs, then it is refused
  with `jj.change_not_found`, byte-identically to today.
- Given a `CommitIdRef` whose hex prefix matches two or more commits, when `interdiff` runs, then
  it is refused with `jj.revset_resolution_error` and never resolves to one of them.
- Given a `CommitIdRef` that is empty or not hex, then `jj.invalid_input`; given one that is valid
  hex but matches nothing, then `jj.change_not_found`.
- Given a buffer whose union value is present but whose discriminant was never set, then
  `ffi.invalid_argument`; given one whose discriminant byte is out of range, then
  `ffi.invalid_argument`; given a ref table whose `id` is absent, then `jj.invalid_input`.
- Given the pre-existing suites, when `cargo make test` runs, then every interdiff test that does
  not concern the new arm passes with only its call shape changed (both-absent refusal, one-absent
  `@` default, path filtering, conflicted base, no-op-written), and every one of the sixteen
  wrappers is still covered by a kind-mismatch row.
- Given `cargo make test`, when it completes, then the coverage ratchet is green with no baseline
  entry lowered and `crates/zanshin-ffi/src/commit_views.rs` still at 100.00.
- Given `docs/ffi-abi.md` and `docs/rust-error-codes.md`, when read, then no live text claims the
  change-id currency is mandated or that `evolog` and `interdiff` cannot compose, and
  `ffi_abi_doc_sync.rs` passes with `EXPECTED_EXPORTS = 47`.

## Spec Change Log

## Review Triage Log

## Design Notes

**Why the bare index lookup and not the CLI's `IdPrefixContext`.** The CLI resolves a bare hex
symbol through `CommitPrefixResolver`, which first consults the `revsets.short-prefixes`
disambiguation set (default `revsets.log` = `builtin_log()`) and, on `NoMatch`, **falls back to
`repo.index().resolve_commit_id_prefix`** — a pure byte-prefix search over every indexed commit,
with no visibility filter (`jj-lib-0.44.0 id_prefix.rs:161-189`, `default_index/composite.rs:187`;
jj's own `lib/tests/test_id_prefix.rs` asserts a hidden commit resolves under the DEFAULT context).
That fallback is the whole mechanism this follow-up needs, and the default set contains only
visible commits, so a hidden predecessor needs a repo-wide-unique prefix in the CLI too. Adopting
the context would buy one narrow case (a prefix ambiguous repo-wide but unique inside
`builtin_log()`) at the price of a config read plus a revset parse+evaluate per call — which would
give `interdiff` `jj.config_error` and `jj.revset_parse_error` failure modes it does not have
today. We refuse instead of guessing, which is the safe direction and matches the crate's existing
change-id resolver (it calls `repo.resolve_change_id` with no prefix context either). Documented as
a deliberate divergence at the resolver.

**Why `jj.revset_resolution_error` for ambiguity.** It is the registry's ambiguity code — its
Meaning column already reads "ambiguous id" — and it is where a divergent change-id symbol lands
for `show`/`evolog` (row `:55`). jj-lib raises exactly `RevsetResolutionError::AmbiguousCommitIdPrefix`
for this input in the CLI, so the code is the same fault class reported by the same name. Minting
`jj.commit_id_ambiguous` would add a code for a condition the registry already covers.

**The verifier does the union's consistency check for us.** `Verifier::visit_union`
(`flatbuffers-25.12.19 verifier.rs:472-498`) matches on the PRESENCE of the two vtable slots:
`(None, None)` → absent (our `@` default), `(Some, Some)` → the variant closure, anything else →
`new_inconsistent_union` → the buffer fails `root_with_opts` at ladder rung 2. A builder never
writes a default-valued scalar, so "value present, discriminant NONE" is exactly that inconsistent
pair — refused before the reader runs, with no defensive branch to leave uncovered. An
OUT-OF-RANGE tag byte, by contrast, verifies (the generated variant match ends in `_ => Ok(())`,
same as `RequestKind` in follow-up H), so the reader's unknown-tag arm is reachable and must be
tested.

```rust
match req.from_type() {
    fbs::RevisionRef::NONE => Ok(None),
    fbs::RevisionRef::ChangeIdRef => Ok(Some(RevisionRef::ChangeId(ChangeId(
        req.from_as_change_id_ref().and_then(|r| r.id()).ok_or_else(|| missing_field("from.id"))?.to_owned(),
    )))),
    fbs::RevisionRef::CommitIdRef => Ok(Some(RevisionRef::CommitId(CommitId(/* … */)))),
    other => Err(invalid_revision_ref("from", other)),
}
```

**Deterministic ambiguity fixture.** Commit ids are 64 hex chars; with 17 commits in the index two
must share their first digit (pigeonhole over 16), so a loop that adds commits until a one-char
collision exists terminates in at most 17 iterations and yields a genuinely ambiguous prefix —
no probabilistic assertion, no fixture regeneration.

## Verification

**Toolchain (this shell):** `cargo`, `dart` and `flutter` are NOT on the default `PATH`. Prefix
every such command with
`export SDK_PATH=$HOME/development/sdks RUSTUP_HOME=$SDK_PATH/rustup CARGO_HOME=$SDK_PATH/cargo FLUTTER_ROOT=$SDK_PATH/flutter PATH=$FLUTTER_ROOT/bin:$CARGO_HOME/bin:$PATH`
(one `bash -c` per invocation). `flatc 25.12.19` is on the default `PATH`. Run `cargo make test`
UNPIPED and synchronously; it takes ~15 minutes. Disk is tight (~4.5 GiB): on
`No space left on device` delete only `target/debug/incremental`, `target/llvm-cov-target` or
`target/release` and retry — nothing outside `target/`, never `git clean`, never the pre-existing
`git stash` entry.

**Commands:**
- `flatc --version` -- expected: `25.12.19`.
- `cargo make codegen` -- expected: exit 0; the four committed outputs change; the
  `zanshin_ffi.h` / `bindings.dart` diff carries no changed parameter type, name or order.
- `cargo make test` -- expected: exit 0. Rust tests, clippy pedantic `-D warnings`, rustfmt,
  `flutter test`, `dart analyze`/`format`, `cargo deny` and the coverage ratchet all green;
  `coverage-baseline.txt` unchanged or raised, never lowered.
- `grep -rn "do NOT compose\|cannot be composed\|unaddressable\|mandated" docs/ schemas/ crates/ packages/`
  -- expected: no live text asserting the old limitation as current behaviour.
- `python3 -c "import yaml,sys; [yaml.safe_load(open(p).read().split('---')[1]) for p in sys.argv[1:]]" <this spec> <spec-9-6>`
  -- expected: exit 0.

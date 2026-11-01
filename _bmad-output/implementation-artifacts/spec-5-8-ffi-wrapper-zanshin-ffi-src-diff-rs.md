---
title: 'Story 5.8 — FFI wrapper (zanshin-ffi/src/diff.rs): zanshin_diff extern, worker command, RepoHandle.diff, ShowEntry tree labels on the wire'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: 'c244780069f206f6502ba28967679bbbf54bb087'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 5.6's `zanshin_jj::Repo::diff` (`jj diff` as data) and Story 5.5's `Diff` payload builder exist, but no extern, worker command or `RepoHandle` method lets Dart read a diff, so the hunks' `HunkKey`s, sections and `mode_change` flag (deferred-work I1/I2) never reach the GUI; and the FFI `ShowEntry` drops `parent_tree_labels` / `tree_labels` (I3), so a Dart caller cannot name a conflicted parent tree completely.

**Approach:** Add `zanshin_diff(handle, data, len) -> *mut ZanshinBuf` in `crates/zanshin-ffi/src/diff.rs` taking a new `DiffRequest` FlatBuffers request (select_tree's request-buffer pattern) mapped onto `zanshin_jj::DiffOptions`, answering with the existing `Diff` envelope through `precondition_envelope`; wire it to Dart (`zanshinDiff`, `DiffCommand`, `ZanshinWorker.diff`, `RepoHandle.diff`, `zanshin_core.dart` exports); and append the two label vectors to the wire `ShowEntry` and the Dart `ShowEntry`.

## Boundaries & Constraints

**Always:**
- `DiffRequest` (append to `schemas/envelope.fbs`, new `RequestKind.Diff` appended after the last value): `kind`, `revision: string` (`-r`), `from: string`, `to: string` (`--from` / `--to`), `paths: [string]` (house prefix paths), `context: DiffContext` (a `struct DiffContext { value: uint; }` — absent = jj's `diff.git.context` default; struct because `flatc --dart` has no optional scalars, as `MovementOffset`), `whitespace: DiffWhitespace` (new append-only `enum DiffWhitespace : ubyte { Exact, IgnoreAllSpace, IgnoreSpaceChange }` = `-w` / `-b`), `summary: bool`. Ids are lone strings (house change-id currency, as `SelectTreeRequest.revision`).
- Mapping: `from` or `to` present → `DiffRevisions::FromTo { from, to }` (each absent side `@`); otherwise `DiffRevisions::Revision(revision)` (absent = `@`). `revision` together with `from` or `to` → `jj.invalid_input` before the handle borrow / snapshot (the CLI's clap conflict `-r` vs `--from`/`--to`). Absent vectors are empty. A `whitespace` value outside the enum → `ffi.invalid_argument` (select_tree_verb's pattern).
- Extern shape as `zanshin_select_tree`: `debug!`, `catch`, request read BEFORE `session_from_handle`, `precondition_envelope(&mut session.repo, session.repo.diff(&options), map_mutate_err, diff_to_envelope)`, `vec_into_token`. Rustdoc with `# Errors` (every code `Repo::diff` can map to, plus `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`) and `# Safety`. No caching. Writes no operation beyond the pre-verb snapshot.
- Wire `ShowEntry`: append `parent_tree_labels: [string]` and `tree_labels: [string]` (always written, empty = unlabeled, one per id otherwise, exactly as `zanshin_jj::ShowEntry`); `show_view_to_envelope` writes them; the Dart `ShowEntry` gains `parentTreeLabels` / `treeLabels` (absent → `const []`).
- Dart: `zanshinDiff(rawHandle, {revision, from, to, paths, context, whitespace, summary})` in `lib/src/ffi/diff.dart` (interior-NUL guard via `request_bytes.dart` like select_tree; NUL → the same refusal select_tree gives), a Dart `DiffWhitespace` enum with a wire getter; `DiffCommand` (HandleScopedCommand), worker dispatch case and `ZanshinWorker.diff` client method mirroring select_tree's; `RepoHandle.diff(...)` → `Future<Diff>` (closed handle → `StateError`); export `Diff, DiffWhitespace, FileDiff, Hunk, HunkLine, HunkLineKind` from `zanshin_core.dart`.
- `cargo make codegen` regenerates the generated Rust/Dart/header/bindings; commit what it emits. Docs: `docs/ffi-abi.md` (new index row + section, export counts 114 → 115, request-table count, `Diff` section's "No extern yet"/"Not exported" lines, `ShowEntry` labels), `ffi_abi_doc_sync.rs`'s `EXPECTED_EXPORTS` → 115; `schemas/envelope.fbs` comment `Story 5-8 : Diff` marked done like its siblings.
- Every `pub` item doc-commented; clippy pedantic refactor-not-suppress.

**Never:**
- No change to `zanshin_jj` behaviour (`Repo::diff`, `compute_hunks`) — this story is transport only. No word segments / language / syntax classes (5.2–5.4). No fileset DSL, no multi-revision `-r`. No caching or memoization. No UI code. No regeneration of committed fixtures. No extern for `compute_hunks`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Default | empty `DiffRequest` (kind only) | the `Diff` envelope `repo.diff(&DiffOptions::default())` builds for `@`; `precondition` present | — |
| Revision | `revision` = C's change id, C modifies `f.txt` | one `FileDiff` `f.txt`, its `sections` and hunk keys equal `Repo::diff`'s; `commit_id` = C, `from_commit_id` absent | — |
| From/to | `from` = A, `to` = C | `from_commit_id` = A, `commit_id` = C; only `to` set → from = `@` | — |
| Conflict | `revision` with `from` | — | `jj.invalid_input`, no `precondition` |
| Options | `paths`, `context {0}`, `IgnoreAllSpace`, `summary: true` | reach `DiffOptions` field by field (summary → hunks empty) | unknown whitespace value → `ffi.invalid_argument` |
| Unmatched path | `paths: ["nope"]` | empty files, one `jj.paths_unmatched` warning on the envelope | — |
| Bad input | handle 0 / null data / garbage bytes / wrong kind | — | `ffi.invalid_handle` / `ffi.null_pointer` / `ffi.invalid_argument` ×2 |
| Unknown revision | `revision` = `zzzz…` | — | `jj.change_not_found` |
| Dart round trip | real cdylib, `RepoHandle.diff(revision: …)` | `Diff` with files, hunks, keys, counts, pins; keys fed back to `selectTree` are accepted | interior NUL → refusal; closed handle → `StateError` |
| Show labels | `show` of a merge child / conflicted tree | wire + Dart `parentTreeLabels`/`treeLabels` equal `zanshin_jj::ShowEntry`'s; a plain commit's are empty | — |

</intent-contract>

## Code Map

- `crates/zanshin-ffi/src/select_tree.rs:29` -- `pub(crate) strings()`; `:96-115` request reader pattern (`reject_null_request`, `root_with_opts`, `invalid_request`, `expect_request_kind`); `:121-135` enum mapper with `ffi.invalid_argument`; `:137-198` extern + rustdoc; `:200+` reader unit tests with request builders.
- `crates/zanshin-ffi/src/diff.rs:18` -- `diff_to_envelope(&RevisionDiff, &CallReport)` already has `precondition_envelope`'s `build` shape; add reader + extern + unit tests here (module doc lines 3-5 announce it).
- `crates/zanshin-ffi/src/envelope.rs:657` -- `precondition_envelope`; `:674`, `:690` request guards; `crates/zanshin-ffi/src/repo.rs` `map_mutate_err`.
- `crates/zanshin-jj/src/hunks.rs:79` `Whitespace` (`Exact`, `IgnoreAllSpace`, `IgnoreSpaceChange`); `:129` `DiffOptions { revisions, paths, context: Option<usize>, whitespace, summary }`; `:147` `DiffRevisions::{Revision(Option<ChangeId>), FromTo { from, to }}`; `crates/zanshin-jj/src/repo.rs:4456` `Repo::diff` (its `# Errors` list → the extern's).
- `crates/zanshin-ffi/src/commit_views.rs:207-224` -- `show_view_to_envelope` writes `parent_tree_ids` / `tree_ids`; add labels; unit test ~`:607-647`. `crates/zanshin-jj/src/commit_views.rs:102-124` -- `ShowEntry` label fields.
- `schemas/envelope.fbs:158-232` `RequestKind` (append `Diff`); `:330-337` `SelectTreeRequest`; `:1644-1648` `MovementOffset` (struct-for-optional precedent); `:2568-2580` `ShowEntry` + doc; `:3134-3143` `Diff` doc/table; `:1450` the `Story 5-8 : Diff` comment.
- `crates/zanshin-ffi/tests/it/select_tree_ffi.rs:32-111,491-530,603` -- `read_and_free`, `parse_envelope`, `error_code`, `Fx` fixture with `Drop`, request building, refusal test; `tests/it/diff_ffi.rs` -- repo contents + wire readers (`keys()`, `kind_and_text()`); `tests/it/commit_views_ffi.rs` -- show tests (add labels assertion); `tests/it/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS`.
- `docs/ffi-abi.md:40,327,591` export/request counts; `:665` `zanshin_select_tree` index row template; `:2220` select_tree section; `:2446-2494` `Diff` payload section ("No extern yet", "Not exported…"). `docs/rust-error-codes.md` -- only if a new code (none expected).
- `packages/zanshin_core/lib/src/ffi/select_tree.dart:94` `SelectTreeVerb` wire-getter pattern; `:215-262` call + NUL guard + `callWithRequest` + decoders. `lib/src/ffi/diff.dart:178-181` `decodeDiffEnvelope(Internal)`; add `zanshinDiff`, `DiffWhitespace` (imports `bindings.dart`, `request_bytes.dart`).
- `packages/zanshin_core/lib/src/worker/commands.dart:2282` `SelectTreeCommand`; `lib/src/worker/isolate.dart:55` imports, `:1769` `ZanshinWorker.selectTree`, `:4587-4610` dispatch case (`handles[handleId]`, `_invalidHandleEnvelope`, `BufferResult`); `lib/src/worker/handle.dart:73,1619-1630` `RepoHandle.selectTree`.
- `packages/zanshin_core/lib/zanshin_core.dart:13,107,109` -- exports (add diff.dart line).
- `packages/zanshin_core/lib/src/ffi/commit_views.dart:217-245,329-333` -- Dart `ShowEntry` + `_mapShowEntry`.
- `packages/zanshin_core/test/worker/select_tree_test.dart:43-74,299,314` -- real-cdylib test pattern (`ZanshinWorker.start`, `initRepo(path, backend: 0)`, NUL and closed-handle cases); `test/ffi/diff_test.dart` -- decode tests; commit_views Dart tests for the labels.
- `_bmad-output/planning-artifacts/epics.md:4914` Story 5.8 (append dated "Delivered" note); `_bmad-output/implementation-artifacts/sprint-status.yaml:119` `5-8-…` (→ done at finalize, bump `last_updated`); `deferred-work.md` items I1–I3 (append a dated 5.8 line each when settled).

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- `RequestKind.Diff`, `DiffWhitespace`, `DiffContext`, `DiffRequest` (documented like `SelectTreeRequest`), `ShowEntry` label vectors, doc updates; then `cargo make codegen` and commit the generated files.
- `crates/zanshin-ffi/src/diff.rs` -- `read_diff_request` → `DiffOptions`, whitespace mapper, `zanshin_diff` extern; inline unit tests for the reader (every field, FromTo vs Revision, conflict refusal, unknown whitespace, wrong kind).
- `crates/zanshin-ffi/src/commit_views.rs` -- write the labels; extend its unit test.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` -- real-handle tests through `zanshin_diff`: default, revision (keys == `Repo::diff`'s), from/to pins, options pass-through (summary/context/whitespace/paths + unmatched warning), refusals, unknown revision. `tests/it/commit_views_ffi.rs` -- labels on a merge's show. `tests/it/ffi_abi_doc_sync.rs` -- 115.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `commit_views.dart`, `worker/commands.dart`, `worker/isolate.dart`, `worker/handle.dart`, `zanshin_core.dart` -- the Dart chain + exports + labels.
- `packages/zanshin_core/test/worker/diff_test.dart` (new, real cdylib) -- `RepoHandle.diff` round trip, keys accepted by `selectTree`, from/to, summary, NUL refusal, closed handle; `test/ffi/diff_test.dart` / commit_views tests -- labels decode, `DiffWhitespace` wire values.
- `docs/ffi-abi.md`, `epics.md`, `sprint-status.yaml`, `deferred-work.md` -- docs and ledgers.

**Acceptance Criteria:**
- Given a repo with a modified file, when Dart calls `RepoHandle.diff(revision: <change>)`, then it receives a `Diff` whose files, hunks, `HunkKey`s, counts and pins equal what `zanshin_jj::Repo::diff` returns for the same options, and passing a file's hunk key to `RepoHandle.selectTree` is accepted (I1, I2 end to end).
- Given a commit whose parent tree is a merge with labels, when Dart calls `show`, then `ShowEntry.parentTreeLabels` / `treeLabels` equal the Rust `ShowEntry`'s (I3).
- Given `cargo make codegen`, then `zanshin_ffi.h` and `bindings.dart` contain `zanshin_diff`, and the doc-sync test passes with 115 exports.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 27 findings — high 0, medium 4, low 18, false 5, maybe-false 0
- findings:
  - `[low]` `patch` (blind) `epic-5-context.md` still says the extern and worker command "come next" / 5.8 "is the next step". — Goal, story list and dependency lines now say 5.8 is done.
  - `[low]` `patch` (blind) `epic-5-context.md` says ids cross "as lone C strings"; the rewrite drops older decisions. — The 5.8 line now names the `DiffRequest` buffer; the dropped decisions are rejected: the file is a cache compiled from the planning docs, and those decisions live in the 5.1/5.5/5.6 specs and epics.md.
  - `[low]` `patch` (blind) I1–I3 are not struck through as `~~…~~ — RESOLVED` like the ledger's other closed items. — Struck through with the commit hash at finalize.
  - `[false]` `reject` (blind) `sprint-status.yaml` is missing from the change set. — It is a finalize step (Code Map: "→ done at finalize"); done in the finalize commit.
  - `[medium]` `patch` (blind) A negative Dart `context` wraps in `putUint32` (-1 → 4294967295 lines). — `zanshinDiff` and `ZanshinWorker.diff` throw `ArgumentError` for a negative value, as the `limit`/`offset` guards do; new test `a_negative_context_is_refused_on_the_calling_side`.
  - `[low]` `patch` (blind) The Rust `-w` assertion `assert_ne!(…, Some(1))` passes for many outcomes. — Exact baseline asserted `Some(1)`, `-w` asserted `Some(0)`.
  - `[low]` `patch` (blind) From/to pins are only checked for presence / inequality. — Rust: the extern result is compared to `Repo::diff` for the same options (pins included, `assert_wire_is`); Dart: `fromCommitId` now equals `a`'s commit id (same patch as the gap layer's `to` row).
  - `[low]` `patch` (blind) The labels test never shows `tree_labels` non-empty, and Dart labels are decode-tested only. — `!expected.tree_labels.is_empty()` added; the Dart side's real-cdylib show is the same generated decoder the synthetic test drives, rejected.
  - `[low]` `reject` (blind) A present-but-empty id (`""`) is undefined. — Same reading as `SelectTreeRequest`'s ids (an empty `ChangeId` resolves to `jj.change_not_found`); a Dart caller passes `null` for absence (house null-for-absence rule).
  - `[low]` `reject` (blind) Error arms (path leaving the repo, ambiguous prefix, StateError after worker close) untested through the extern. — They come from `Repo::diff` / `build_matcher` / `resolve_or_wc`, tested in zanshin-jj (Story 5.6), and the shared worker close path; the extern only maps `MutateError`.
  - `[low]` `reject` (blind) The Rust default-request test's `@` is empty. — The Dart worker test's `@` is non-empty and asserts `diff()` equals `diff(revision: at)`.
  - `[low]` `reject` (blind) `diff.rs` imports `select_tree::strings`. — Already `pub(crate)` and used across modules; moving it is a refactor with no named harm.
  - `[medium]` `patch` (edge) Negative `context` truncates in `zanshinDiff`. — Same root cause as the blind context row; same patch.
  - `[medium]` `patch` (edge) Negative `context` crosses the isolate unchecked. — Same patch (guard on the calling side too).
  - `[low]` `patch` (edge) The `-w` assertion is weak. — Same as the blind row; same patch.
  - `[false]` `reject` (edge) `sprint-status.yaml` still says backlog. — Finalize step, as above.
  - `[low]` `reject` (edge) The Dart test checks shapes, not equality with `Repo::diff`. — Equality is witnessed on the Rust wire; the Dart decoder is field-by-field tested in `test/ffi/diff_test.dart` (Story 5.5/5.6).
  - `[medium]` `patch` (gap) `to: at` equals an absent `to` in the Dart fixture, so dropping `to` passes. — Test now moves `@` off `at` and asserts `diff(from: a, to: at)` = `diff(revision: at)` ≠ `diff()`.
  - `[low]` `reject` (gap) The worker's unknown-handle branch for `DiffCommand` is untested. — Copied boilerplate untested for most commands (select_tree included); the gap layer itself suggests a shared cross-command test, not one per command; no named harm for this story.
  - `[false]` `reject` (intent) Epic surface: two-id `zanshin_diff_compute` vs the request buffer. — Deliberate, recorded in Design Notes and the epics.md "Delivered" note: 5.6 grew the read to `jj diff`'s full option set.
  - `[low]` `reject` (intent) No conflicted or mode-change file goes through the extern end to end. — The extern passes `Repo::diff`'s result to the unchanged 5.5 builder; conflicted keys are round-tripped through `select_tree` in zanshin-jj (5.1), `mode_change` on the wire in diff_ffi's builder test.
  - `[false]` `reject` (intent) I2-b: no read yields a conflicted side's materialized text. — The hunk lines carry the materialized conflict text exactly as `jj diff --git` prints it, and `select_tree` needs only the keys (it materializes itself); a full-side read is not what the CLI's diff offers.
  - `[false]` `reject` (intent) I2-c: the read takes revisions, not trees. — A merge's parent tree is the `-r` form's left side (merged parents), the `left` `select_tree` checks; `jj diff` has no tree-id spelling, and "trees" was 5.1's internal input, delivered by `compute_hunks`.
  - `[low]` `reject` (intent) I3-b: no Dart path consumes the labels. — I3's follow-up asks for them on the wire `ShowEntry`; `select_tree` reads labels itself and checks `left` by id; a consumer is UI work (10.26).
  - `[low]` `reject` (intent) `IgnoreSpaceChange` not sent through the Rust extern test. — Reader unit test maps it; Dart worker test sends it through the real extern.
  - `[low]` `patch` (intent) The Rust `-w` assertion is weak alone. — Same as the blind row; same patch.
  - `[low]` `reject` (intent) `assert_wire_is` maps non-Added kinds to Modified. — Pre-existing 5.6 helper; the fixtures hold no rename/copy; kinds round-trip in the builder unit test.

## Design Notes

Why a request buffer, not lone C strings (the epic's `zanshin_diff_compute(handle, from_id, to_id)`): 5.6 grew the read to `jj diff`'s full option set (`-r`, `--from/--to`, paths, context, `-w/-b`, summary); ADR-0001's composite-input pattern carries that set, and ids still cross as plain strings inside it. The extern is named `zanshin_diff` (noun = verb, like `zanshin_select_tree`, `zanshin_interdiff`). FromTo is inferred from `from`/`to` presence: `FromTo { None, None }` (= `@` vs `@`, always empty) is the only `DiffRevisions` value it cannot express, and the CLI has no spelling for it either.

## Verification

**Commands:**
- `cargo make codegen` -- expected: succeeds; generated files updated and committed
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it -- diff_ffi:: commit_views_ffi:: ffi_abi_doc_sync:: select_tree_ffi::` -- expected: pass
- `cargo clippy -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean
- `cargo make --allow-private test-core` (or `flutter test` in `packages/zanshin_core`), `dart analyze --fatal-infos --fatal-warnings packages/zanshin_core`, `dart format --set-exit-if-changed packages/zanshin_core` -- expected: pass/clean
- No full gate (`cargo make test`/`test-full`/`coverage`) — story-loop gate rule. Parity oracle not needed (no jj verb changes; transport only).

**Verification notes (run on 2026-11-01; full gate deferred to the story loop by its gate rule):**
- `cargo make codegen` -- succeeded; `envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart` regenerated and committed (header + bindings contain `zanshin_diff`).
- `cargo test -p zanshin-ffi --lib` -- 238 passed (before and after the review patches).
- `cargo test -p zanshin-ffi --test it -- diff_ffi:: commit_views_ffi:: ffi_abi_doc_sync:: select_tree_ffi::` -- 46 passed (before and after the review patches; doc-sync with 115 exports).
- `cargo clippy -p zanshin-ffi --all-targets -- -D warnings` -- clean. `cargo fmt --all --check` -- clean.
- `cargo make --allow-private test-core` -- 1183 passed after the review patches (1182 before). `dart analyze --fatal-infos --fatal-warnings packages/zanshin_core` -- no issues. `dart format --set-exit-if-changed packages/zanshin_core` -- 0 changed.
- Not run: the parity oracle (no jj verb changed), coverage and the full gate (story-loop gate rule).

## Auto Run Result

Status: done.

**Summary.** `zanshin_diff(handle, data, len)` (`crates/zanshin-ffi/src/diff.rs`) is `jj diff` as data on the FFI: a `DiffRequest` buffer (`revision` = `-r`; `from`/`to` = `--from`/`--to`, either selecting that form, an absent side `@`; `revision` with either = `jj.invalid_input` before the snapshot, the CLI's clap conflict; `paths`; `context` as a `DiffContext` struct; `DiffWhitespace` `-w`/`-b`; `summary`) mapped onto `zanshin_jj::DiffOptions`, answering Story 5.5/5.6's `Diff` envelope through `precondition_envelope`. Dart: `zanshinDiff`, `DiffCommand`, `ZanshinWorker.diff`, `RepoHandle.diff` → `Future<Diff>` (negative `context` and interior NULs refused on the calling side), exports `Diff, DiffWhitespace, FileDiff, Hunk, HunkLine, HunkLineKind`. The wire and Dart `ShowEntry` gain `parent_tree_labels` / `tree_labels`.

**Deferred-work items.**
- I1 — fixed (commit b96036dd260a23def4dde13d00da91781b59ec38): the keys reach Dart through `RepoHandle.diff`, and a reported hunk key is accepted by `RepoHandle.selectTree` (real-cdylib test).
- I2 — fixed (commit b96036dd260a23def4dde13d00da91781b59ec38): `RepoHandle.diff` yields per file the sections cut over the materialized conflict text, the hunk lines as `jj diff --git` prints them and `modeChange`; a merge's parent tree is the `-r` form's left side (merged parents), as in the CLI.
- I3 — fixed (commit b96036dd260a23def4dde13d00da91781b59ec38): labels on the wire `ShowEntry` (always written) and the Dart `ShowEntry`; witnessed on a conflicted merge against `Repo::show`.

**Files changed.**
- `schemas/envelope.fbs` + regenerated Rust/Dart/header/bindings -- `RequestKind.Diff`, `DiffWhitespace`, `DiffContext`, `DiffRequest`, `ShowEntry` labels.
- `crates/zanshin-ffi/src/diff.rs` -- request reader, whitespace mapper, `zanshin_diff`, unit tests. `src/commit_views.rs` -- labels written.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `commit_views_ffi.rs`, `ffi_abi_doc_sync.rs` -- real-handle extern tests, labels test, 115 exports.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `commit_views.dart`, `worker/commands.dart`, `worker/isolate.dart`, `worker/handle.dart`, `lib/zanshin_core.dart` -- the Dart chain, labels, exports.
- `packages/zanshin_core/test/worker/diff_test.dart` (new), `test/ffi/diff_test.dart`, `test/ffi/commit_views_test.dart` -- real-cdylib round trip and decode tests.
- `docs/ffi-abi.md` -- index row, `zanshin_diff` section, counts, labels. `epics.md` -- Story 5.8 "Delivered" note. `sprint-status.yaml` -- 5-8 done. `deferred-work.md` -- I1–I3 resolved. `epic-5-context.md` -- recompiled in step-01 (epics.md was newer), 5.8 marked done in review.

**Review.** 27 findings: 0 high, 4 medium, 18 low, 5 false. Patched: 2 medium entries (negative Dart `context` wrapping — guard on both calling sides + test; the Dart chain's `to` untested because `to: at` equalled `@` — test now moves `@`), and low entries (exact `-w` assertions, non-empty `tree_labels` assertion, `fromCommitId` equality, epic-5-context staleness, ledger strike-throughs). Deferred: none. Rejected, with reasons in the Review Triage Log: empty-string ids, untested shared error arms, the Rust default-request fixture, the `strings` import, Dart shape-only assertions, the worker's unknown-handle branch, conflicted/mode files through the extern, `IgnoreSpaceChange` in the Rust extern test, `assert_wire_is`'s kind mapping, I3-b's label consumer; false: `sprint-status.yaml` (twice, finalize step), the epic's two-id surface, I2-b (materialized text) and I2-c (trees vs revisions).

**Follow-up review recommended: true.** Two medium entries were patched on a first pass. The unverified risk: a conflicted file's and a mode-change file's keys have never travelled through `zanshin_diff` → Dart → `selectTree` end to end (only plain files do; the conflicted case rests on zanshin-jj's Story 5.1 round trip), and per-file coverage of `crates/zanshin-ffi/src/diff.rs` is measured only at the loop's final gate.

**Verification.** See the verification notes above; every targeted command passed.

**Residual risks.**
- Coverage of `crates/zanshin-ffi/src/diff.rs` / `commit_views.rs` is measured only at the loop's final gate (the zanshin_core cdylib test credits the extern).
- The worker's unknown-handle branch for `DiffCommand` is untested (as for most commands).

---
title: 'Epic 9 follow-up A2: finish the FFI-helper dedupe'
type: 'refactor'
created: '2026-09-05'
status: 'done'
baseline_revision: 'ea6005ef66ce1216a797c627a254063d952fad57'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The 2026-09-05 dedupe run (`spec-epic-9-followup-a-dedupe-ffi-helpers`) deliberately
scoped itself to the NAMED copies of three helpers and recorded four wider items in
`deferred-work.md` § "Deferred from: spec-epic-9-followup-a-dedupe-ffi-helpers (2026-09-05)": 19
inline `session_from_handle` borrows still spelled by hand in nine `zanshin-ffi` modules, 23 inlined
`readToken` bodies in eleven `zanshin_core` FFI adapters, `ZanshinWorker._rejectInteriorNuls`
re-spelling the guard that run just single-sourced, and ten worker command arms with no
closed-handle test. Every one is a place a future edit can desync, and the ledger entry is the
proof the debt is known but unpaid.

**Approach:** A CLOSING run that resolves all four ledger entries and nothing else. Items 1–3 are
pure re-pointings at helpers that already exist — no new abstraction is invented, only the one
already-shipped spelling is called — with no observable behaviour change on any surface (same
bytes, same codes, same messages, same `ArgumentError` `name`s). Item 4 is test-only: ten
closed-handle worker tests modelled verbatim on `test/worker/file_test.dart`'s four. Item 3 needs
one genuinely new symbol, a list variant `rejectInteriorNuls`, because six adapter call sites
currently hand-write the `for` loop over the scalar form.

## Boundaries & Constraints

**Always:**
- Behaviour-preserving for items 1–3. Every replaced expression must produce the identical error
  code, `context`, message and `name` argument. The FFI wire is untouched: no `.fbs` edit, no
  `extern "C"` signature change, therefore **no `cargo make codegen` run and no diff in any
  generated file** (`zanshin_ffi.h`, `bindings.dart`, `*_generated.rs`, `*.ffi_generated.dart`).
- Every `unsafe` block keeps a `// SAFETY:` comment. The established replacement is the one-line
  `// SAFETY: see \`session_from_handle\`.` that `git.rs` already uses at all six of its call sites
  — that IS the "delete the per-site duplicated SAFETY comments" the ledger asks for: the
  three-line duplicate goes, the pointer stays. Project-context forbids an `unsafe` block with no
  SAFETY comment.
- Clean up only the orphans this change creates: imports the re-pointing leaves unused must go
  (`-D warnings` / `--fatal-infos --fatal-warnings` catch them). Do not touch anything else in the
  files.
- Coverage may rise but never drop. Items 1's deletions remove COVERED Rust lines from nine files;
  eight are at `100.00` in `coverage-baseline.txt` and stay there, `graph.rs` is at `99.81` with
  `epsilon_pct = 0.10` of slack. Items 2–4 are Dart-only and cannot move a Rust-only ratchet.
- The ten new tests assert exactly what the four existing `file_test.dart` ones assert: a
  `ZanshinFfiException` whose `code` is `ffi.invalid_handle`, on the WORKER method (not the
  `RepoHandle` wrapper, whose guard is a synchronous `StateError`).
- Bookkeeping is part of the run: all four ledger bullets struck through, and the four matching
  `deferred:` items in `spec-epic-9-followup-a-dedupe-ffi-helpers.md` given a `resolved:` field.
- `cargo make test` is the single gate, run unpiped and synchronously, and must exit 0.
- Commits use `--no-gpg-sign` and stay on `main`.

**Block If:**
- The gate can only be made green by lowering a `coverage-baseline.txt` entry or adding an
  `exclude_prefix`: HALT with `blocked`, blocking condition `coverage ratchet regression`.
- A re-pointing turns out NOT to be behaviour-preserving (a supposedly identical inline site
  differs in code, `context` or message): HALT with `blocked`, blocking condition
  `not a pure refactor`.
- A closed-handle test cannot be written without inventing new production behaviour: HALT with
  `blocked`, blocking condition `worker arm not testable as specified`.

**Never:**
- Do NOT convert `repo.rs:593` (`zanshin_repo_close`). It is a different shape — `if let Some(…)`
  followed by `handle_drop`, not `.ok_or_else(…)?` — and carries its own eight-line SAFETY comment
  about close ordering. It is not one of the 19 sites the ledger counted.
- Do NOT widen: no `docs/ffi-abi.md` pass, no `.fbs` change, no new error code, no new public API
  on `zanshin-jj` or `zanshin_core` beyond the one `rejectInteriorNuls` list helper, no behaviour
  change to any verb, no reformatting or "improvement" of adjacent code.
- Do NOT open a new ledger entry for further duplication of the same shape. This run exists to
  leave the ledger SMALLER — a same-shape leftover is either fixed here (if it is a few lines) or
  rejected, never deferred.
- Do NOT write a literal NUL byte into any source or spec file. Write `U+0000` or a `\u0000`-style
  escape in prose; in Dart test strings use an escape sequence. The previous run tripped over this
  twice (a committed blob was classified binary).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Zero handle at any of the 19 re-pointed Rust wrappers | `handle = 0` | `Envelope{ok:false, error.code="ffi.invalid_handle", context=null}` — byte-identical to baseline | Unchanged |
| Live handle at those wrappers | valid handle from `zanshin_repo_open`/`_init` | success envelope, unchanged payload | Unchanged |
| Any of the 23 re-pointed Dart adapters returns a token | any `zanshin_*` call | envelope bytes copied out, token freed exactly once via `buf.dispose()` in a `finally` | Unchanged |
| `diagnostics.dart` / `events.dart` decode-inside-try sites | any token | decode now runs on the copy AFTER `dispose()` instead of before; `Uint8List.fromList` already copies, so the decoded value is identical | Unchanged |
| Worker method given a list whose entry has an interior NUL | e.g. `bookmarkCreate(id, ['a<NUL>b'])` | `ArgumentError.value(value, 'names', 'must not contain an interior NUL (U+0000)')` — same message, same `name`, same `invalidValue` | Unchanged |
| Worker method given a scalar with an interior NUL | e.g. `workspaceRoot(id, name: 'a<NUL>b')` | `ArgumentError.value(name, 'name', …)` / `(revision, 'revision', …)` — unchanged | Unchanged |
| Each of the ten previously-untested worker arms, handle closed | `handles[handleId] == null` | `ZanshinFfiException` with `code == 'ffi.invalid_handle'` | This IS the assertion |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `ea6005e`. Line numbers shift as edits land —
re-grep rather than trusting a number after the first edit in a file.

**Item 1 — 19 inline `session_from_handle` borrows → the shared helper**

- `crates/zanshin-ffi/src/envelope.rs:235-243` — `pub(crate) unsafe fn session_from_handle<'a>(handle: u64) -> Result<&'a mut RepoSession, FfiErrorObj>`, already crate-visible. `:212-224` is its banner, whose second paragraph ("NOT yet the only spelling in the crate: nine other modules …") becomes FALSE with this change and must be rewritten to say it now IS the only `.ok_or_else` spelling, with `repo.rs`'s close-path `if let Some` named as the deliberate exception.
- `crates/zanshin-ffi/src/git.rs:230-232` — the reference call-site shape to copy: `// SAFETY: see \`session_from_handle\`.` then `let session = unsafe { session_from_handle(handle) }?;`. Six such sites (`:232, 266, 314, 367, 422, 480`).
- The 19 sites to convert, each the identical five-line
  `let session =\n unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {\n code: FFI_INVALID_HANDLE.to_owned(),\n context: None,\n })?;` preceded by a three-line SAFETY comment (or, after the first site in a file, by `// SAFETY: see \`zanshin_<first>\`.`):
  - `repo.rs` — `:717, 765, 813, 867, 906, 953, 1033, 1099` (8)
  - `file.rs` — `:330, 379, 423, 469` (4)
  - `status.rs:131`, `change.rs:168`, `graph.rs:278`, `op_log.rs:100`, `bookmarks.rs:92`,
    `remotes.rs:86`, `log_defaults.rs:92` (1 each)
- `crates/zanshin-ffi/src/repo.rs:585-596` — **NOT converted.** `zanshin_repo_close`'s
  `if let Some(session) = unsafe { handle_from_raw::<RepoSession>(…) } { session.close(); }` plus
  `handle_drop`, with its own close-ordering SAFETY comment. Leave verbatim.
- Import surgery per file (add `session_from_handle` to the existing `use crate::envelope::{…}`
  list in all nine):
  - delete `use crate::handle::handle_from_raw;` — `status.rs:16`, `change.rs:19`, `graph.rs:29`,
    `op_log.rs:16`, `bookmarks.rs:16`, `remotes.rs:16`, `log_defaults.rs:20`, `file.rs:24`.
    `repo.rs:35` (`use crate::handle::{handle_drop, handle_from_raw, handle_into_raw};`) KEEPS
    `handle_from_raw` — the close path at `:593` still uses it.
  - delete `use crate::repo::RepoSession;` — same eight files (`status.rs:17`, `change.rs:20`,
    `graph.rs:30`, `op_log.rs:17`, `bookmarks.rs:17`, `remotes.rs:17`, `log_defaults.rs:21`,
    `file.rs:25`). `graph.rs:11`'s doc mention of `RepoSession` is a plain code span, not an
    intra-doc link, so it does not keep the import alive. `repo.rs` DEFINES `RepoSession` (`:325`).
  - drop `FFI_INVALID_HANDLE` from the `crate::envelope::{…}` list in those same eight
    (`status.rs:13`, `op_log.rs:13`, `change.rs:16`, `graph.rs:24`, `bookmarks.rs:13`,
    `file.rs:19`, `log_defaults.rs:17`, `remotes.rs:13`). `repo.rs` KEEPS it (`:581`).
  - **CORRECTED during execution — do NOT drop `FfiErrorObj` anywhere.** This bullet originally
    said to drop it from `status.rs:13` and `log_defaults.rs:17` "because those two have no other
    use". That is false: both use it in their own error mappers (`status.rs`'s `map_status_err`,
    `log_defaults.rs`'s config-error arm), so removing it fails the build with `E0422`/`E0425`.
    All nine files KEEP `FfiErrorObj` (`change.rs:30`, `op_log.rs:19`, `graph.rs:34+`,
    `remotes.rs:19`, `bookmarks.rs:19`, `file.rs:37+`, `repo.rs:40+`, plus these two). Only
    `handle_from_raw`, `RepoSession` and `FFI_INVALID_HANDLE` are orphaned by the re-pointing.
- `coverage-baseline.txt:15,16,19,22,24,27,29,30,31,32` — `bookmarks/change/envelope/file/graph/
  log_defaults/op_log/remotes/repo/status.rs`; all `100.00` except `graph.rs = 99.81`.

**Item 2 — 23 inlined `readToken` bodies → `ffi/request_bytes.dart`'s `readToken`**

- `packages/zanshin_core/lib/src/ffi/request_bytes.dart:70-77` — the destination, already
  package-visible and documented (null-token note included). No change needed for item 2.
- The 23 sites, each the identical
  `final buf = FfiBuffer.fromToken(token);\n try { return Uint8List.fromList(buf.bytes); } finally { buf.dispose(); }`:
  - `mutate.dart` — `:40, 58, 73, 88, 100, 119, 163, 194` (8). **The ledger says "four blocks
    inside mutate.dart"; the real count is 8.** Its "~23" total is right (15 + 8), so the undercount
    is inside mutate.dart only — do all eight.
  - `repo.dart` — `:25, 45, 64, 87, 106, 126` (6)
  - `status.dart:23`, `bookmarks.dart:23`, `op_log.dart:22`, `remotes.dart:23`,
    `log_defaults.dart:23`, `change.dart:30`, `graph.dart:118` (1 each)
  - `diagnostics.dart:52-60` — variant: decodes INSIDE the `try`, then disposes. Becomes
    `decodeDiagnosticsEnvelope(readToken(zanshin_diagnostics()))`; identical because
    `Uint8List.fromList` already copies.
  - `events.dart:106-113` — variant: `final Uint8List bytes; try { bytes = … } finally { … }` then
    `onEvent(decodeEventEnvelope(bytes));`, all inside an outer `try/catch (e, st)`. Becomes
    `onEvent(decodeEventEnvelope(readToken(token)));` inside that same outer try.
- `prefer_expression_function_bodies` is ON: a body that collapses to a single `return` MUST become
  `=>` (e.g. `Uint8List zanshinStatus(int rawHandle) => readToken(zanshin_status(rawHandle));`).
- Import pruning: `dart:ffi as ffi`, `ffi_buffer.dart` and `bindings.dart` go unused in whichever
  files lose their last reference. `bindings.dart` survives wherever a `zanshin_*` symbol is still
  called. Let `dart analyze` decide — do not guess.
- Files that must gain `import 'request_bytes.dart';` (relative, `directives_ordering` applies):
  the eleven above minus the six that already import it (`mutate.dart:13` already does).

**Item 3 — one spelling of the interior-NUL guard**

- `packages/zanshin_core/lib/src/ffi/request_bytes.dart:57-61` — `rejectInteriorNul(String? value, String name)`, the single source of the message and `name`. ADD a list variant next to it:
  `void rejectInteriorNuls(Iterable<String> values, String name)` looping `rejectInteriorNul`.
- `packages/zanshin_core/lib/src/worker/isolate.dart`:
  - `:1291-1298` `static void _rejectInteriorNuls(List<String> values, String name)` — DELETE.
  - `:1249` and `:1284` — `_rejectInteriorNuls(names, 'names');` → `rejectInteriorNuls(names, 'names');`
  - `:1208-1210` (`workspaceRoot`) and `:1250-1252` (`bookmarkCreate`) — scalar hand-rolls
    `if (x != null && x.codeUnits.contains(0)) { throw ArgumentError.value(x, '<name>', 'must not contain an interior NUL (U+0000)'); }` → `rejectInteriorNul(name, 'name');` /
    `rejectInteriorNul(revision, 'revision');`. The scalar helper already null-guards, so this is
    literally the same predicate and the same throw. Including these is what removes the SECOND
    SPELLING the ledger names; leaving them would fail the item's own purpose.
  - Add `import '../ffi/request_bytes.dart';` unprefixed (the file's `../ffi/log_forwarder.dart`
    import is the precedent), in `directives_ordering` position after `../ffi/repo_detect.dart`.
  - The `// WHY here and not only in the adapter:` comments at `:1201-1207` and `:1242-1248` STAY —
    they explain the two-layer design, not the spelling.
- The six adapter `for` loops → `rejectInteriorNuls(…)` with the SAME `name` argument:
  `mutate.dart:151-153` and `:188-190` (`'paths'`), `bookmark_ops.dart:42-44` and `:59-61`
  (`'names'`), `file.dart:26-28` (`'paths'`), `commit_views.dart:99-101` (`'paths'`).
- `packages/zanshin_core/test/ffi/request_bytes_test.dart` — existing witness pinning the literal
  message, `name` and `invalidValue` for the scalar form. Extend it with the list form.

**Item 4 — ten closed-handle worker tests**

- `packages/zanshin_core/test/worker/file_test.dart:174-212` — the four-test model. Shape:
  `initRepo` → `handle.close()` → `expectLater(worker.<method>(handle.handleId, …), throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')))`. No
  `handle.close()` afterwards (already closed).
- Worker methods and their arities (`packages/zanshin_core/lib/src/worker/isolate.dart`):
  `describe(id, {required changeId, required description})` `:665`; `newChange(id, List<String> parents)` `:691`; `edit(id, String changeId)` `:708`; `abandon(id, List<String> changeIds)` `:725`;
  `gitFetch(id, String remoteName)` `:761`; `gitImport(id)` `:950`;
  `gitRemoteAdd(id, {required name, required url, String? pushUrl})` `:978`;
  `gitRemoteRemove(id, String name)` `:1006`; `gitRemoteRename(id, String oldName, String newName)`
  `:1023`; `gitRemoteSetUrl(id, {required name, String? url, String? pushUrl})` `:1045`.
- Placement: `describe`/`newChange`/`edit`/`abandon`/`gitFetch` into
  `test/worker/mutate_test.dart` beside its `undo`/`restore`/`absorb` closed-handle tests
  (`:123, 219, 229`), using `backend: 0` like its siblings — except `gitFetch`, whose file-mates use
  `backend: 1` (`:150`). `gitImport` + the four `gitRemote*` into `test/worker/git_test.dart` beside
  `gitExport_on_a_closed_handle_surfaces_ffi_invalid_handle` (`:191-200`), `backend: 1`, following
  its `final int handleId = handle.handleId;`-before-close local.
- A closed handle is rejected by the worker's own map lookup BEFORE any FFI call, so `gitFetch`
  spawns no `git` subprocess here — the reason `mutate_test.dart:133-148` avoids a happy-path fetch
  does not apply.
- No `extern "C"` function is added or removed, so the coverage guard's extern-fn check is
  unaffected; coverage is Rust-only so these ten tests do not move the ratchet.

**Bookkeeping targets**
- `_bmad-output/implementation-artifacts/deferred-work.md:234, 236, 238, 240` — the four bullets.
  Convention in the same file (`:178`, `:216`, `:218`, `:220`): the **RESOLVED** stamp goes
  IMMEDIATELY after the strikethrough, the original body is kept verbatim as the audit trail, and
  what actually happened goes in a trailing **Resolution:** sentence —
  `~~**title**~~ **RESOLVED <date> (<spec slug>, commit <short hash>)** [locations] — <original
  body, unchanged> **Resolution:** <what was done>`. (`:182` is a different, older shape with the
  stamp at the END; follow the four `:216`-`:220` entries, which are the same run's own.)
- `_bmad-output/implementation-artifacts/spec-epic-9-followup-a-dedupe-ffi-helpers.md:12-61` — the
  four `deferred:` items, in the same order as the ledger bullets; each gains a `resolved: >-`
  block scalar. Keep the YAML valid.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-ffi/src/{repo,file,status,change,graph,op_log,bookmarks,remotes,log_defaults}.rs` --
  replace each of the 19 inline `.ok_or_else(…)` borrows with `// SAFETY: see \`session_from_handle\`.` + `let session = unsafe { session_from_handle(handle) }?;`, delete the
  per-site three-line SAFETY duplicates, add `session_from_handle` to each file's
  `use crate::envelope::{…}` list, and delete the imports the change orphans (per the Code Map's
  per-file list). Leave `repo.rs:585-596` untouched. -- one spelling of the unbounded-lifetime
  contract instead of twenty.
- `crates/zanshin-ffi/src/envelope.rs` -- rewrite the second paragraph of the
  `── Shared handle borrow ──` banner (`:219-224`): it currently records the nine modules as still
  inline, which this change makes false. State that it is now the only `.ok_or_else` spelling and
  name `zanshin_repo_close`'s `if let Some` close path as the one deliberate non-user. -- a banner
  that lies is worse than no banner.
- `packages/zanshin_core/lib/src/ffi/{status,bookmarks,op_log,remotes,log_defaults,change,diagnostics,events,graph,repo,mutate}.dart` --
  replace all 23 inlined token reads with `readToken(<call>)`, import `request_bytes.dart` where
  missing, collapse now-single-return bodies to `=>` (`prefer_expression_function_bodies`), and
  drop the imports `dart analyze` then reports unused. -- one definition of the token-ownership
  discipline; a change to it stops needing a dozen edits.
- `packages/zanshin_core/lib/src/ffi/request_bytes.dart` -- add
  `void rejectInteriorNuls(Iterable<String> values, String name)` delegating to `rejectInteriorNul`,
  documented as the list form of the same guard. -- six call sites hand-write this loop; the list
  form is what lets them stop.
- `packages/zanshin_core/lib/src/ffi/{mutate,bookmark_ops,file,commit_views}.dart` -- replace the
  six `for (final x in xs) rejectInteriorNul(x, '<name>');` loops with
  `rejectInteriorNuls(xs, '<name>');`, same `name` argument. -- identical throw, six fewer loops.
- `packages/zanshin_core/lib/src/worker/isolate.dart` -- delete `_rejectInteriorNuls`, import
  `../ffi/request_bytes.dart`, and re-point its two list call sites plus the two scalar hand-rolls
  (`workspaceRoot`'s `name`, `bookmarkCreate`'s `revision`) at the shared guards. Keep both
  `// WHY here and not only in the adapter:` comments. -- the message and its `name` argument are
  then produced in exactly one place in the whole package.
- `packages/zanshin_core/test/ffi/request_bytes_test.dart` -- add cases for `rejectInteriorNuls`:
  an entry with an interior NUL throws with the literal message, the list's `name` and that ENTRY as
  `invalidValue`; an empty list and a NUL-free list are accepted. Use a `\u0000` escape, never a
  literal NUL byte. -- the list variant is new code and the only assertion of which value the list
  form reports.
- `packages/zanshin_core/test/worker/mutate_test.dart` -- add five closed-handle tests
  (`describe`, `newChange`, `edit`, `abandon`, `gitFetch`) modelled on `file_test.dart:174-212`. --
  five of the ten arms whose unknown-handle reply is currently witnessed by nothing.
- `packages/zanshin_core/test/worker/git_test.dart` -- add five closed-handle tests (`gitImport`,
  `gitRemoteAdd`, `gitRemoteRemove`, `gitRemoteRename`, `gitRemoteSetUrl`) beside the existing
  `gitExport` one. -- the other five arms.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- strike through all four bullets of the
  `spec-epic-9-followup-a-dedupe-ffi-helpers` section in the file's existing convention: the
  `**RESOLVED 2026-09-05 (spec-epic-9-followup-a2-finish-ffi-helper-dedupe, commit <short hash>)**`
  stamp immediately after the strikethrough, the original body kept verbatim, and a trailing
  `**Resolution:** <what was done>`. Update the section preamble too — it says the entries are
  "recorded here so the next pass has the counts already done", which a closing run makes false.
  -- a closing run that leaves its own ledger section open has not closed anything.
- `_bmad-output/implementation-artifacts/spec-epic-9-followup-a-dedupe-ffi-helpers.md` -- add a
  `resolved: >-` block scalar to each of its four `deferred:` items, keeping the YAML valid. -- the
  spec frontmatter is the per-run evidence trail.

**Acceptance Criteria:**
- Given `crates/zanshin-ffi/src/`, when it is grepped for
  `handle_from_raw::<RepoSession>`, then exactly TWO hits remain — `envelope.rs`'s own
  `session_from_handle` body (the helper IS that expression) and `repo.rs`'s
  `zanshin_repo_close` close path — i.e. exactly one CALLER outside the helper, and
  `grep -c "session_from_handle(handle)"` over the crate returns 32 (13 pre-existing + 19
  converted).
- Given `packages/zanshin_core/lib/`, when it is grepped for `FfiBuffer.fromToken`, then exactly
  FOUR lines match, of which exactly two are code: the definition in `ffi_buffer.dart` and the
  single call in `request_bytes.dart`'s `readToken`. The other two are doc comments (a `[…]`
  reference in `ffi_buffer.dart`'s class doc and a prose mention in `readToken`'s own doc), so
  the check is "one caller", not "two lines".
- Given `packages/zanshin_core/lib/`, when it is grepped for `codeUnits.contains(0)` and for
  `must not contain an interior NUL`, then each returns exactly one hit and both are inside
  `request_bytes.dart`'s `rejectInteriorNul`.
- Given `packages/zanshin_core/test/worker/`, when it is grepped for the ten worker methods called
  as `worker.<method>(`, then each of `describe`, `newChange`, `edit`, `abandon`, `gitFetch`,
  `gitImport`, `gitRemoteAdd`, `gitRemoteRemove`, `gitRemoteRename`, `gitRemoteSetUrl` has at least
  one hit, inside a test asserting `ffi.invalid_handle`.
- Given a clean tree, when `cargo make test` runs unpiped, then it exits 0 and no
  `coverage-baseline.txt` entry is lower than at baseline `ea6005e`.
- Given the change is staged, when `git status --porcelain` is read, then no generated file
  (`zanshin_ffi.h`, `bindings.dart`, `*_generated.rs`, `*.ffi_generated.dart`) and no `schemas/*.fbs`
  appears in the diff.
- Given the run is finished, when `deferred-work.md` is read, then all four bullets of the
  `spec-epic-9-followup-a-dedupe-ffi-helpers` section are struck through with a resolution line
  naming this spec's slug and a commit, and no new bullet has been added under a section for this
  run.

## Spec Change Log

- **2026-09-05, during execution.** Two Code Map facts were wrong and were corrected against the
  compiler and the acceptance greps rather than followed:
  - `FfiErrorObj` is NOT droppable from `status.rs:13` or `log_defaults.rs:17` — both files still
    use it in their `map_status_err` / `map_log_defaults_err` mappers (`E0422`/`E0425` on removal).
    All nine files keep `FfiErrorObj`; only `handle_from_raw`, `RepoSession` and
    `FFI_INVALID_HANDLE` were orphaned, exactly as mapped.
  - Item 3's site list missed three hand-rolled scalar guards in `graph.dart:96-104` (`revset`,
    `prioritize`, `shortPrefixes`). The Acceptance Criteria demand exactly one
    `codeUnits.contains(0)` hit in `lib/`, and the closing-run rule says a few-line same-shape
    leftover is fixed here rather than deferred, so they were re-pointed at `rejectInteriorNul`.
    All three are non-nullable `String`, so the helper's null-guard is a no-op and the throw is
    unchanged.
  - Counts confirmed as mapped: 19 Rust sites (not "~20"), 8 `readToken` blocks in `mutate.dart`
    (not four), 23 total.

- **2026-09-05, review pass (9 PATCH findings, doc/bookkeeping only — no code defects).** The
  refactor falsified nine statements that describe it. All corrected: the `request_bytes.dart`
  file banner (it scoped the file to six request-buffer adapters; 17 files import it now, and the
  three helper groups have three different reaches) and `readToken`'s null-token rationale (its
  newest caller, `events.dart`, gets its token from a `NativeCallable` callback, not an
  `extern "C"` return); the `request_bytes_test.dart` header; `envelope.rs`'s banner FIRST
  paragraph (the second was already rewritten, the first still named only the four originally-
  extracted modules); `diagnostics.dart`'s pointer at a `repo.dart` pattern this run deleted;
  two `deferred-work.md` leftovers (a preamble promising a "next pass" for a now-closed section,
  and a struck bullet whose preserved body contradicted its own Resolution in the present tense);
  and three statements in THIS spec — the two grep expectations in Acceptance Criteria and
  Verification that undercounted their own hits (`handle_from_raw::<RepoSession>` leaves two, not
  one, because the helper's body IS that expression; `FfiBuffer.fromToken` matches four lines, two
  of them doc comments), the Code Map's `FfiErrorObj` instruction (now corrected in place so a
  reader does not meet the build-breaking version first), and the stated `deferred-work.md`
  convention, which did not match the shape the file actually uses.

- **2026-09-05, matrix test audit (3 deferrals converted to patches — the `deferred:` list is now
  empty).** The review pass had recorded three test-strengthening items as deferrals. None needed a
  product decision or another subsystem, and two of them left an I/O-matrix row only half-witnessed,
  so under this run's closing mandate all three were fixed instead:
  - Matrix row 1 promises `context=null`, but every zero-handle test asserted `error.code` alone
    (only `log_defaults_ffi.rs` also pinned the absent context). Added the assertion at all 19
    re-pointed wrappers: `repo_write_ffi.rs` gained an `assert_invalid_handle` helper that replaces
    its eight duplicated code-only blocks, and `file_ffi.rs` (×4), `status/change/op_log/bookmarks/
    remotes/graph_ffi.rs` gained one line each. Deliberately NOT folded into `graph_ffi.rs`'s shared
    `assert_error`, which also serves codes that DO carry a context.
  - Matrix rows 5–6 promise "same `name`", the one genuinely per-site value and the thing the
    `not a pure refactor` Block-If exists for; every call-site test matched `throwsArgumentError` by
    type alone. All eleven re-pointed guard sites now pin `e.name`: `bookmark_ops` (×2 adapter,
    ×3 worker), `mutate` (×2), `commit_views`, `file`, `graph` (×3 worker), `workspace` (×1).
  - `readToken` had no direct test although every adapter now funnels through it. Added
    `readToken (real cdylib)` to `request_bytes_test.dart`, driving a real `zanshin_diagnostics`
    token, reading it back through the generated `fbs.Envelope` accessor, and pinning that the
    returned list is an independent heap copy that outlives the freed token.

## Review Triage Log

### 2026-09-05 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 9: (high 0, medium 3, low 6)
- defer: 3: (high 0, medium 2, low 1)
- reject: 13: (high 0, medium 0, low 13)
- addressed_findings:
  - `[medium]` `[patch]` `request_bytes.dart`'s file banner still scoped the file to "the six FFI
    adapter files that pass a request buffer" although seventeen files now import it — the very
    defect this run fixed in `envelope.rs`. Banner rewritten to state the three helper groups'
    three different reaches (commit `aa3b232`).
  - `[medium]` `[patch]` `deferred-work.md`'s closed section kept a "next pass" preamble and one
    struck bullet whose preserved body contradicted its own Resolution in the present tense. Both
    now read as history.
  - `[medium]` `[patch]` This spec's own two grep expectations undercounted their hits, so a
    re-verifier following them would have concluded the run failed. `handle_from_raw::<RepoSession>`
    leaves TWO hits (the helper's body IS that expression); `FfiBuffer.fromToken` matches four lines,
    two of them doc comments. Corrected in both Acceptance Criteria and Verification.
  - `[low]` `[patch]` `envelope.rs`'s banner had its second paragraph rewritten but not its first,
    which still named only the four originally-extracted modules; reworded to the crate-wide role.
  - `[low]` `[patch]` `diagnostics.dart` pointed at a `repo.dart` decode pattern this run deleted;
    retargeted at `readToken` (its now-orphaned `ffi_buffer.dart` import removed with it).
  - `[low]` `[patch]` `readToken`'s null-token rationale argued from "every `extern "C"` wrapper
    returns a real token", but its newest caller receives the token from a `NativeCallable`; clause
    added for the callback path.
  - `[low]` `[patch]` `request_bytes_test.dart`'s header no longer covered `graph.dart` or the
    worker call sites; updated.
  - `[low]` `[patch]` The Code Map still instructed dropping `FfiErrorObj` from `status.rs` and
    `log_defaults.rs`, which the Change Log records as build-breaking; corrected in place so the
    wrong instruction is not the first thing a reader meets.
  - `[low]` `[patch]` The stated `deferred-work.md` convention did not match the shape the file
    actually uses; corrected, along with the matching task line.

Rejected as noise or as excluded by the intent's own authority: the `Iterable<String>` vs
`List<String>` signature of `rejectInteriorNuls` (the intent prescribes `Iterable`, and no call site
passes a lazy or single-subscription iterable); a `docs/ffi-abi.md` snippet refresh (the intent
explicitly forbids a `ffi-abi.md` pass); the ten new tests not distinguishing arms and being
verbatim copy-paste (the intent prescribes exactly that assertion shape, "modelled verbatim on
`file_test.dart`'s four"); the unprefixed `request_bytes.dart` import in `isolate.dart` (intent
prescribes unprefixed); a durability guard against a future 34th arm shipping without a witness;
NUL-literal spelling inconsistency against pre-existing tests; the two helper names differing by one
trailing character; the coverage paragraph's direction of reasoning (inside `<intent-contract>`,
read-only, and the predicted outcome held); and the descriptive intent-alignment observations about
`graph.dart` being outside the matrix and the per-file coverage signal moving into `envelope.rs`.

## Design Notes

**Why the SAFETY comment survives.** The ledger phrases item 1 as "deleting the per-site duplicated
SAFETY comments", but project-context is explicit that every `unsafe` block needs a `// SAFETY:`
comment. The two are reconciled by the shape `git.rs` already ships: the three-line duplicate (which
is what can desync) is deleted, and a one-line pointer to the single documented contract replaces
it. Copying an existing in-tree convention is also cheaper to review than inventing a second one.

**Why the two scalar hand-rolls in `isolate.dart` are in scope.** Item 3's ledger text names
`_rejectInteriorNuls`, but its stated grievance is that "the message this run just single-sourced
still has a second spelling one layer up". `workspaceRoot` and `bookmarkCreate` each hand-write that
same literal for a scalar. Fixing only the list form would leave the grievance standing while
marking it resolved. It is four lines, and the closing-run rule says fix a few-line same-shape
leftover here rather than open a new entry.

**Why `diagnostics.dart` and `events.dart` are safe.** Both decode inside the `try` and dispose in
the `finally`, so the decode currently runs while the native buffer is still alive. After the change
the decode runs on the `Uint8List.fromList` copy, after disposal. That copy is already independent
of the native memory today — the existing code returns it across an isolate port precisely because
it is a heap copy — so the observable result is identical and the native buffer's lifetime only gets
shorter.

## Verification

**Commands:**
- `cargo make test` -- expected: exit 0. Run unpiped and synchronously, allow ~8-10 minutes
  (cargo test + clippy pedantic `-D warnings` + rustfmt + `flutter test` + dart analyze/format +
  `cargo deny` + the coverage ratchet). The single gate.
- `grep -rn "handle_from_raw::<RepoSession>" crates/zanshin-ffi/src/` -- expected: exactly two hits
  — `envelope.rs`'s `session_from_handle` body (the helper is that expression) and `repo.rs`'s
  `zanshin_repo_close`. One caller outside the helper.
- `grep -rc "session_from_handle(handle)" crates/zanshin-ffi/src/` summed -- expected: 32.
- `grep -rn "FfiBuffer.fromToken" packages/zanshin_core/lib/` -- expected: four matching lines, two
  of them code (`ffi_buffer.dart` definition, `request_bytes.dart` call) and two doc comments.
  The assertion is one caller.
- `grep -rn "codeUnits.contains(0)" packages/zanshin_core/lib/` -- expected: one hit, in
  `request_bytes.dart`.
- `git status --porcelain` -- expected: clean after each commit; no generated file and no
  `schemas/*.fbs` in any diff.
- `git diff --stat` before committing -- expected: only the files named in Tasks & Acceptance.

## Auto Run Result

Status: done
Blocking condition: none

### Summary

The four ledger entries the 2026-09-05 dedupe run left open are closed, and nothing else was
widened. 19 hand-spelled `session_from_handle` borrows in nine `zanshin-ffi` modules now call the
one crate helper behind `git.rs`'s existing one-line SAFETY pointer; `zanshin_repo_close`'s
differently-shaped close path is untouched, as the intent required. 23 inlined `readToken` bodies in
eleven `zanshin_core` adapters now call the single `readToken`, leaving `FfiBuffer.fromToken` with
exactly one caller. The interior-NUL guard has one spelling in the package: a new list variant
`rejectInteriorNuls` replaced six hand-written `for` loops, `ZanshinWorker._rejectInteriorNuls` is
gone, and the remaining hand-rolled scalar throws delegate. Ten closed-handle worker tests give all
33 handle-taking dispatch arms a witness. No behaviour changed on any surface.

Two Code Map errors were found and corrected during execution rather than followed: `FfiErrorObj`
is NOT droppable from `status.rs` or `log_defaults.rs` (both still use it in their error mappers —
`E0422`/`E0425` on removal), and `graph.dart` held three further hand-rolled scalar guards the Code
Map never listed, which the acceptance criterion "exactly one `codeUnits.contains(0)` hit in `lib/`"
made mandatory to convert. Both are recorded in the Spec Change Log.

### Files changed

Commit `53fc8f6` — the refactor:
- `crates/zanshin-ffi/src/{repo,file,status,change,graph,op_log,bookmarks,remotes,log_defaults}.rs`
  -- 19 inline borrows re-pointed at the shared helper; orphaned imports deleted.
- `crates/zanshin-ffi/src/envelope.rs` -- banner rewritten; it no longer claims nine modules inline
  the borrow.
- `packages/zanshin_core/lib/src/ffi/{status,bookmarks,op_log,remotes,log_defaults,change,diagnostics,events,graph,repo,mutate}.dart`
  -- 23 token reads re-pointed at `readToken`; single-return bodies collapsed to `=>`; unused
  imports dropped.
- `packages/zanshin_core/lib/src/ffi/request_bytes.dart` -- adds `rejectInteriorNuls`.
- `packages/zanshin_core/lib/src/ffi/{mutate,bookmark_ops,file,commit_views}.dart` -- six `for`
  loops replaced by the list guard.
- `packages/zanshin_core/lib/src/worker/isolate.dart` -- `_rejectInteriorNuls` deleted, four call
  sites re-pointed at the shared guards.
- `packages/zanshin_core/test/ffi/request_bytes_test.dart` -- list-form guard cases.
- `packages/zanshin_core/test/worker/{mutate,git}_test.dart` -- the ten closed-handle tests.

Commit `73469bd` — bookkeeping: `deferred-work.md`'s four bullets struck through; four `resolved:`
fields added to `spec-epic-9-followup-a-dedupe-ffi-helpers.md`.

Commit `aa3b232` — review patches: the nine statements the refactor falsified, in
`envelope.rs`, `diagnostics.dart`, `request_bytes.dart`, `request_bytes_test.dart`,
`deferred-work.md` and this spec.

Commit `12ae4fa` — matrix test audit: the three deferrals converted to patches. Test-only, no
production file touched. Eight `crates/zanshin-ffi/tests/*_ffi.rs` suites gained the
`context == null` assertion at all 19 re-pointed wrappers (`repo_write_ffi.rs` via a new
`assert_invalid_handle` helper that also collapses its eight duplicated code-only blocks); eight
`packages/zanshin_core/test/` files gained the `e.name` pin at all eleven re-pointed guard sites;
`request_bytes_test.dart` gained the `readToken (real cdylib)` group.

### Review findings breakdown

Patches applied: 9 (medium 3, low 6) — all doc, comment or bookkeeping text that the refactor made
untrue; zero behaviour change. Items rejected: 13, listed with reasons in the Review Triage Log. No
`intent_gap` and no `bad_spec`: no reviewer found the code wrong, so no revert or re-derivation was
triggered. The 3 items the review pass had deferred (medium 2, low 1) were all converted to patches
by the matrix test audit, so `deferred` is empty and this closing run opened no new ledger debt of
its own — see the third Spec Change Log entry.

### Follow-up review recommendation

`true`. Patched findings this pass: high 0, medium 3, low 6. Score = 3 x 3 + 1 x 6 = 15, which is
at or above the threshold of 5. No `high`-severity patch was applied; the recommendation is driven
entirely by the volume of falsified-documentation fixes, not by any defect in the shipped code.

### Verification performed

- `cargo make test`, run unpiped and synchronously, four times by this workflow: exit 0 after the
  refactor (377.73 s), after the review patches (467.63 s), independently re-confirmed on the
  as-committed tree before the audit, and finally on the audited tree (388.24 s). One intermediate
  run exited 105 on `dart format --set-exit-if-changed` alone (three audit files); formatted and
  re-run green. Coverage held at 99.20 % (8315/8382 lines over 46 files) throughout;
  `coverage-baseline.txt` is byte-unchanged, so the ratchet neither regressed nor auto-raised, and
  no `exclude_prefix` was added. `extern-coverage: OK`.
- `grep -rn "handle_from_raw::<RepoSession>" crates/zanshin-ffi/src/` -- two hits as expected:
  `envelope.rs:238` (the helper's own body) and `repo.rs:593` (the deliberate close-path
  non-user). One caller outside the helper.
- `session_from_handle(handle)` across the crate -- exactly 32 (13 pre-existing + 19 converted).
- `grep -rn "FfiBuffer.fromToken" packages/zanshin_core/lib/` -- four lines: the definition, the
  single call in `readToken`, and two doc comments.
- `grep -rn "codeUnits.contains(0)"` and the literal NUL message in `packages/zanshin_core/lib/` --
  one hit each, both inside `rejectInteriorNul`.
- Matrix audit: all seven I/O-matrix rows have a covering test that ran and passed — rows 1, 5 and 6
  only after commit `12ae4fa` added the assertions their "byte-identical" / "same `name`" halves
  needed. The ten new closed-handle tests and the four new list-guard cases were re-run by name under the expanded
  reporter (47/47 passing) to confirm they are registered and not skipped, rather than inferred
  from the aggregate count.
- `git diff --stat ea6005e..HEAD` restricted to `zanshin_ffi.h`, `bindings.dart`, `*_generated.rs`,
  `*.ffi_generated.dart` and `schemas/` -- empty. No codegen was run.
- `git status --porcelain` -- clean.

### Residual risks

- Behaviour preservation for items 1-3 rested on the pre-existing suite rather than on new
  differential tests. The matrix-audit pass closed the two places that evidence was thinnest: all 19
  re-pointed Rust wrappers now pin `context == null`, and all eleven re-pointed Dart guard sites now
  pin `e.name`. What remains unwitnessed is only the payload half of a SUCCESS envelope being
  byte-identical across the refactor, which no test in the repo asserted before either. Commit
  `53fc8f6` is cleanly revertible.
- The one intended behavioural delta is in `diagnostics.dart` and `events.dart`: decoding now runs
  on the `Uint8List.fromList` copy after `dispose()` instead of before. `fromList` already copies,
  so the decoded value is identical and the native buffer's lifetime only shortens. Both paths are
  exercised against the real cdylib and pass.
- The frontmatter `warnings` are dispositioned as follows. `multiple-goals`: accepted deliberately
  — the four goals are one closing transaction over a single ledger section, and splitting them
  would have left that section open. `oversized`: accepted — the size is breadth of mechanical
  re-pointing, not depth, and the gate plus the acceptance greps bound it.

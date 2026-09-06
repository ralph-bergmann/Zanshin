---
title: 'Epic 9 follow-up G: bring `docs/ffi-abi.md` current for all 47 exported symbols and guard it with a doc-sync test'
type: 'chore'
created: '2026-09-06'
status: 'done'
baseline_revision: 'd115e5f9ef066e2147c8e27885e4de0d0f5a80c3'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** `docs/ffi-abi.md` has not been touched since Story 4.9 (2026-08-24) while seven
stories landed on the FFI surface. The cdylib now exports **47** `extern "C"` symbols; the doc
gives **6** of them a heading and mentions 22 by name at all, so **31 exported symbols appear
nowhere in it**. It documents none of Story 6.5's six mutation wrappers, none of Epic 9's
entry points, and — most importantly — not the **composite request-buffer convention** that 16
of the 47 symbols share, even though that convention is the one thing a new wrapper author
cannot read off any single source file. Thirteen statements in the surviving text are now false
(a stale infallible-symbol list, a `_onNativeEvent` code sample naming a function that does not
exist, `v0.42.0` anchors for a pin that moved to `=0.44.0`, an "only file allowed to import
`dart:ffi`" claim contradicted by ten files, an error table missing `watcher.io_error`). Nothing
detects any of this: the repo has **no doc-staleness check of any kind**.

**Approach:** One doc pass on `docs/ffi-abi.md` — (a) the request-buffer convention documented
ONCE, (b) a 47-row symbol index whose every row is derived from the ACTUAL committed artifacts
(signature from `crates/zanshin-ffi/include/zanshin_ffi.h`, request/payload table from
`schemas/envelope.fbs`, error codes verbatim from that symbol's header `# Errors` block,
cross-checked against `docs/rust-error-codes.md`), (c) the thirteen falsified statements
corrected in place — plus one new Rust integration test that fails when a `zanshin_` function
exported from the header has no heading or table row in the doc. This is a CLOSING run for the
one `docs/ffi-abi.md` ledger entry; the only other work is bookkeeping.

## Boundaries & Constraints

**Always:**
- **Every row is derived from the artifacts, never from memory or from this spec.** Signatures
  come from `crates/zanshin-ffi/include/zanshin_ffi.h`; request and payload tables from
  `schemas/envelope.fbs`; a symbol's error codes are **exactly the codes bulleted in its own
  header `# Errors` block**, cross-checked against `docs/rust-error-codes.md`. Re-read each one;
  do not copy the counts or names in this spec's Code Map without checking them.
- **All 47 exported symbols get a row. There is no allow-list and no exemption.** The self-check
  must pass with an empty exception set on the first green run.
- **`internal.panic` is documented ONCE**, in the envelope/convention prose, as the universal
  `catch_unwind` backstop every fallible wrapper carries. It appears in no `# Errors` block, so
  it appears in no row. Likewise the per-code *conditions* stay in the header rustdoc — the
  index names codes, the header explains them, and the doc says so explicitly.
- **Source edits are confined to `# Errors` rustdoc bullets that the cross-check proves the
  generated header omits.** The header is a *generated document*; the only way to fix a
  generated document is to edit its source and regenerate. Two gaps are already evidenced and
  are the expected complete set (see Code Map). If the cross-check finds more, fix those the
  same way; if it finds none beyond the two, do not invent any.
- One `cargo make codegen` run after the rustdoc edits; commit the regenerated
  `crates/zanshin-ffi/include/zanshin_ffi.h` and `packages/zanshin_core/lib/src/ffi/bindings.dart`
  in the same commit. Their diff must be doc-comment hunks only.
- **The self-check is a Rust integration test in `crates/zanshin-ffi/tests/`, with no new
  dependency**: repo root via `env!("CARGO_MANIFEST_DIR")` + two `.parent()` (the idiom already
  written twice — `crates/test-helpers/src/lib.rs:42-48`, `crates/xtask/src/tasks/gen_fixture.rs:102-104`),
  parsing via plain `str` methods (the house rule stated at
  `crates/xtask/src/tasks/coverage_check.rs:22-32`). It needs no `Makefile.toml` wiring:
  `cargo make test` runs `cargo test --workspace` (`Makefile.toml:76-77`).
- SPDX identifier on the first line of the new `.rs` file; it must be clippy-pedantic clean under
  `cargo clippy --workspace --all-targets -- -D warnings` (`Makefile.toml:83-86`).
- The existing prose sections keep their position and their wording **except** where the
  falsified-statement list says otherwise. This is a correction pass, not a rewrite.

**Block If:**
- The `cargo make codegen` diff moves an `extern "C"` **signature** line (anything beyond doc
  comments) in `zanshin_ffi.h` or `bindings.dart` → HALT, blocking condition
  `unexpected codegen drift`.
- The cross-check finds a wrapper that emits an `error.code` which `docs/rust-error-codes.md`
  does not register at all (as opposed to a header `# Errors` bullet merely missing) → that
  needs a registry decision, not a doc edit → HALT, blocking condition `unregistered error code`.

**Never:**
- No `schemas/envelope.fbs` edit — not even a comment. It regenerates 500 KB of committed Rust
  and the intent forbids schema change.
- No behaviour change, no signature change, no new dependency (there is no `regex` crate in the
  workspace and adding one would be a `cargo deny` surface).
- No allow-list / `EXPECT_MISSING` escape hatch in the self-check, and no lowering of
  `coverage-baseline.txt` (a file under `tests/` is excluded from the ratchet by
  `Makefile.toml:519`'s `--ignore-filename-regex`, so the baseline must not move at all).
- Do **not** add the reverse direction (doc names a symbol the header does not export) to the
  self-check — the intent asked for one direction; keep it to that.
- Do **not** fix the other header-rustdoc blemishes found during investigation (six `# Safety`
  blocks omitting `zanshin_repo_convert` from the valid-handle list; `zanshin_ffi_version`
  having no `# Safety` despite a caller-must-free contract; internal Rust helper names such as
  `vec_into_token` leaking into the public header; four symbols never naming their payload
  table in prose). They are recorded in Design Notes as observed-and-not-touched.
- Do **not** touch the stale comments outside the doc's own surface
  (`crates/zanshin-ffi/src/ffi_strings.rs:15` and `schemas/envelope.fbs:965` still pointing at
  `app/lib/src/ffi/ffi_buffer.dart`; `crates/zanshin-ffi/src/events.rs:5` and
  `schemas/envelope.fbs:453` still calling the `Progress` producer "future").

## I/O & Edge-Case Matrix

The matrix describes the new self-check test's parser, which is the only executable artifact.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Doc is current | All 47 header symbols appear in a heading or a first table cell in `docs/ffi-abi.md` | Test passes | No error expected |
| Symbol added, doc not updated | Header exports `zanshin_x`; the doc names it nowhere | Test FAILS, panic message lists every uncovered name, sorted, and points at `docs/ffi-abi.md` | Assertion failure with the full list — never just the first |
| Header comment lines | ` * … via \`zanshin_buffer_free_token\`.` inside a `/** */` block | NOT counted as an export (comment lines are skipped) | No error expected |
| Multi-line declaration | `zanshin_graph_slice` spans `zanshin_ffi.h:1056-1060` | Counted once — the name sits on the declaration-start line | No error expected |
| Type names, not functions | `ZanshinBuf`, `ZANSHIN_FFI_H` | NOT counted (the scan matches lowercase `zanshin_` followed by an identifier and `(`) | No error expected |
| Mention in a non-first table cell | `zanshin_undo` named only inside an *Error codes* cell of another row | NOT counted as coverage | Test fails for `zanshin_undo` |
| Artifact missing / unreadable | Either file cannot be read | Test fails with the path in the message | Read errors are `expect`ed with the path |

</intent-contract>

## Code Map

Zanshin anchors read against the working tree at baseline `d115e5f`; jj CLI anchors at tag
`v0.44.0` (`git -C ../jj show v0.44.0:<path>`).

**The two authoritative inputs (read-only for the doc pass; the header is regenerated once)**
- `crates/zanshin-ffi/include/zanshin_ffi.h` — 1682 lines, **47** exported `zanshin_*` functions.
  Declaration lines: `:310, 355, 389, 408, 435, 486, 516, 563, 581, 594, 607, 619, 634, 652, 687,
  723, 754, 786, 819, 845, 885, 926, 967, 1010, 1056, 1085, 1107, 1120, 1137, 1156, 1176, 1195,
  1217, 1241, 1266, 1291, 1323, 1354, 1387, 1425, 1449, 1491, 1541, 1591, 1611, 1638, 1680`.
  Every one carries a `/** */` block; **38** carry a `# Errors` section — the 9 without are the 8
  genuinely infallible symbols plus `zanshin_diagnostics` (`:565-581`, prose says "infallible"
  while returning a `ZanshinBuf*`).
- `schemas/envelope.fbs` — `:31-39` the request-table banner (request tables are NOT in the
  union; field order is the wire contract, append-only); `:41-266` the **15** request tables;
  `:268-291` the union registry block, which is the per-story attribution source; `:924-951` the
  `Payload` union, **25** members; `:966-970` `Envelope`.

**Shape grouping (verified against the header; use it to fill the index's Args column)**
- infallible `void` (7): `zanshin_events_register`, `_events_unregister`, `zanshin_string_free`,
  `zanshin_buffer_free_token`, `zanshin_buffer_free`, `zanshin_log`, `zanshin_logging_init`
- infallible plain value (1): `zanshin_ffi_version` → `char *`
- fallible, no args (1): `zanshin_diagnostics`
- fallible, C string(s) only (4): `zanshin_repo_open`, `_repo_clone`, `_repo_detect`, `_repo_convert`
- fallible, handle only (9): `zanshin_bookmarks`, `_git_import`, `_git_export`, `_log_defaults`,
  `_remotes`, `_repo_close`, `_undo`, `_status`, `_workspace_list`
- fallible, handle + C string(s) (6): `zanshin_change`, `_git_remote_remove`, `_git_remote_rename`,
  `_describe`, `_edit`, `_git_fetch`
- fallible, handle + request buffer (16): `zanshin_bookmark_create`, `_bookmark_delete`, `_show`,
  `_evolog`, `_interdiff`, `_file_list`, `_file_show`, `_file_annotate`, `_file_search`,
  `_git_remote_add`, `_git_remote_set_url`, `_new_change`, `_abandon`, `_restore`, `_absorb`,
  `_workspace_root`
- mixed, do not fit the above (2): `zanshin_repo_init(const char*, int32_t)` and
  `zanshin_graph_slice(uint64_t, const char*, const char*, bool, const char*)`
- `zanshin_op_log(uint64_t, int64_t limit)` is handle + scalar (1). 7+1+1+4+9+6+16+2+1 = 47.

**Story attribution — resolve it, never guess it.** `schemas/envelope.fbs:268-291` is the primary
source and covers every payload-returning symbol, but it has no line for `RepoDetect` and none of
the infrastructure symbols. For those, the owning story is the spec file in
`_bmad-output/implementation-artifacts/` that introduced them; the mapping is already resolved:
- Story 3.2 — `zanshin_ffi_version`, `zanshin_string_free`, `zanshin_buffer_free`,
  `zanshin_buffer_free_token` (`3-2-handle-module-ffi-strings-zanshin-ffi-version.md`)
- Story 3.3 — `zanshin_log`, `zanshin_logging_init` (`3-3-tracing-init-with-rotating-file-sink.md`,
  AR-P-5; `crates/zanshin-ffi/src/logging.rs:2` carries the AR-P-5 anchor but no story)
- Story 3.4c — `zanshin_repo_detect`, `zanshin_repo_convert`
  (`3-4c-repo-detect-convert-ffi-wrappers-zanshin-repo-detect-convert.md`; the doc's surviving
  heading at `docs/ffi-abi.md:75` already says 3.4c)
- Story 3.6 — `zanshin_events_register`, `zanshin_events_unregister`
  (`3-6-nativecallable-listener-dispatch-events-progress-callbacks.md`)
- Story 3.8 — `zanshin_diagnostics` (`3-8-diagnostics-api-wip-minimal.md`)
- ~~Story 6.4a — `zanshin_git_fetch`~~ **Corrected during implementation: the owning story is
  6.5.** `spec-6-4a-git-fetch-progress-callback.md` never mentions the symbol;
  `spec-6-5-ffi-mutation-surface.md` introduces it. 6.4a owns the domain side and the
  `Progress` producer (`envelope.fbs:453`), which is what the index row records.

**Facts the request-buffer convention section must state (all verified)**
- Dart builds the table with the flatc-generated `<X>RequestObjectBuilder(...).toBytes()`.
- `packages/zanshin_core/lib/src/ffi/request_bytes.dart:46-54` `withRequestBytes` — malloc-copy,
  call, `malloc.free` in a `finally`. AR-P-5 **inbound** rule (Dart allocates AND frees; Rust
  only borrows) — the reverse of the outbound token rule. `:40-45` documents why an empty buffer
  is deliberately NOT collapsed to `nullptr`: that would change the observable code to
  `ffi.null_pointer`.
- `:110-113` `callWithRequest` composes it with `readToken`.
- Rust side, one shape for all 16: `crates/zanshin-ffi/src/envelope.rs:183-191`
  `reject_null_request` → `ffi.null_pointer`, **no context**; then
  `std::slice::from_raw_parts(data, len)`; then `flatbuffers::root_with_opts::<fbs::X>(...)` →
  on failure `envelope.rs:194-199` `invalid_request` → `ffi.invalid_argument` with the
  flatbuffers verifier message in `context`. A zero-length or garbage buffer fails verification
  and therefore lands on `ffi.invalid_argument`, not `ffi.null_pointer`.
- An ABSENT but REQUIRED field inside an otherwise valid request is `jj.invalid_input`
  (`envelope.rs:201-206`) — a different layer from the two above.
- Worked example of the reader shape: `crates/zanshin-ffi/src/commit_views.rs:51-56` (the module
  banner explaining the unbounded-lifetime SAFETY argument) and `:82-98` `read_show_request`.
- Interior NUL: rejected **Dart-side, at two layers** —
  `request_bytes.dart:56-73` `rejectInteriorNul` (`ArgumentError`) is the direct-caller backstop;
  the primary guard is in `ZanshinWorker`/`RepoHandle`, because a throw inside the worker isolate
  surfaces as `internal.dispatch_error` rather than as the documented `ArgumentError`. Rationale
  to carry over: a FlatBuffers string is length-prefixed, so a NUL survives the wire and lands in
  a jj id, path, pattern, name or URL. `:81-85` `rejectInteriorNuls` is the list form.
- `ChangeIdList` (`envelope.fbs:41-45`) is the only request table shared by two symbols
  (`zanshin_new_change`'s `parents`, `zanshin_abandon`'s `change_ids`). Every other request table
  has exactly one caller; no request table is orphaned.
- Known, ledger-tracked caveat to name (do NOT fix here): request tables carry no
  `file_identifier`, so they verify interchangeably — tracked as an open must-have in
  `_bmad-output/implementation-artifacts/deferred-work.md:194`.
- `WatcherEvent` and `Progress` are the two `Payload` members no exported symbol returns; they
  arrive through the `zanshin_events_register` callback.

**The two rustdoc `# Errors` gaps to fix (evidence checked at baseline)**
- `watcher.io_error` appears **nowhere** in `zanshin_ffi.h`, yet
  `crates/zanshin-ffi/src/repo.rs:483, 521, 553, 673` each call `arm_session(repo)?`, which
  returns it (`repo.rs:355-357` `map_watcher_err`), and `docs/rust-error-codes.md:52` states it is
  returned by exactly `zanshin_repo_open`/`_init`/`_clone`/`_convert`. `docs/ffi-abi.md:200-206`
  already describes the strict-fail arming behaviour, so the doc contradicts its own error table
  at `:146-152`. Add the bullet to the four `# Errors` blocks at `repo.rs:466, 496, 534, 654`.
- `jj.config_error` is missing from `zanshin_graph_slice`'s `# Errors` (`zanshin_ffi.h:1032-1042`)
  though `crates/zanshin-ffi/src/graph.rs:46-47` maps it and `graph.rs:749-752` asserts it — and
  `docs/ffi-abi.md:454` already documents it. Add the bullet to the block at `graph.rs:239`.

**The falsified statements to correct in `docs/ffi-abi.md` (line numbers at baseline)**
1. `:24-26` infallible list names 4 of the 8 plain-returning symbols; and "infallible ⇒ no
   envelope" no longer holds — `zanshin_diagnostics` is documented infallible yet returns an
   envelope (`zanshin_ffi.h:571-576`).
2. `:146-152` `zanshin_repo_convert` error table omits `watcher.io_error` (see above).
3. `:259` sample declares `_onNativeEvent`; the real handler is `_handleNativeEvent` at
   `packages/zanshin_core/lib/src/ffi/events.dart:104`, using `readToken(token)` — not
   `FfiBuffer.fromToken` + `try/finally dispose()`.
4. `:308` "`_onNativeEvent`/`onEvent` handler" — the lookup is in the `registerEventSink` closure
   at `packages/zanshin_core/lib/src/worker/isolate.dart:1349-1352`.
5. `:312-314` "the raw handle is used only for … `zanshin_repo_close`, read wrappers" — Story 6.5
   and Epic 9 dispatch the raw handle to every mutation wrapper too (`isolate.dart:1513` ff.).
6. `:328-329` "the only new file … allowed to import `dart:ffi`" — **fourteen** files under
   `packages/zanshin_core/lib/` import it (the "ten" this Code Map first recorded was an
   undercount, corrected during implementation). The true invariant, and what the doc states
   instead of a brittle count, is that `dart:ffi` never reaches `lib/src/worker/`.
7. `:610` "the layered config the jj CLI would have **at v0.42.0**" — a claim about current
   behaviour; `Cargo.toml:33` pins `jj-lib =0.44.0` and `crates/zanshin-jj/src/config.rs:60` says
   v0.44.0.
8. `:615` "verbatim from `cli/src/config/{revsets,misc}.toml` @ v0.42.0" — same; `config.rs:60-63`
   says v0.44.0. The "7-entry" count is still correct (`config.rs:86-108`).
9. `:615` the builtin-layer enumeration omits `ui.conflict-marker-style`, added by Story 9.4
   (`config.rs:84`).
10. `:423` `test_log_bad_short_prefixes` @ v0.42.0 — legitimate provenance, stale anchor. Re-read
    `git -C ../jj show v0.44.0:cli/tests/test_log_command.rs`; if the test still pins
    warn-and-degrade, re-anchor to `@ v0.44.0`; if it cannot be read or no longer says this, keep
    `@ v0.42.0` and append ", not re-verified at the current 0.44.0 pin".
11. `:651` citation `cli/src/cli_util.rs:991-995` — the code implementing the rule cites
    `987-1009` (`crates/zanshin-jj/src/config.rs:407`).
12. `:471-472` `syntheticElided = true` — the real default is `defaultSyntheticElided`
    (`packages/zanshin_core/lib/src/worker/handle.dart:126`).
13. `:75` heading "## Exported symbols (Story 3.4c)" introduces exactly two symbols and is false
    read as an inventory. The new index supersedes it.

**Self-check host and precedents**
- New file `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs`. Siblings for style:
  `crates/zanshin-ffi/tests/repo_ffi.rs`, `workspace_ffi.rs`.
- Repo-root idiom: `crates/test-helpers/src/lib.rs:42-48`.
- Nearest existing guard in spirit (an FFI-symbol grep cross-checked against a second committed
  artifact): the extern-fn coverage guard, `Makefile.toml:537-564`. Its `EXTERN_COV_ALLOW`
  allow-list is deliberately NOT copied — this run backfills instead of exempting.
- `Makefile.toml:47-72` the `test` task's 22 dependencies (no edit needed); `:76-77`
  `cargo test --workspace`; `:83-86` clippy `--all-targets`; `:289-344` `codegen`; `:519` the
  coverage `--ignore-filename-regex` that excludes `/tests/`.

**Gates / bookkeeping**
- `coverage-baseline.txt` — must be unchanged by this run.
- `_bmad-output/implementation-artifacts/deferred-work.md:214` — the `docs/ffi-abi.md` bullet to
  strike through and mark resolved. The follow-up-E section starts at `:248`; the new follow-up-D
  section is inserted immediately before it.
- `_bmad-output/implementation-artifacts/spec-epic-9-followup-d-symlinked-workspace-path.md:11-34`
  — the single `deferred:` item to lift verbatim into the ledger.
- `spec-9-3-…` … `spec-9-8-…` — each has one `deferred:` item mentioning `docs/ffi-abi.md`; each
  gains a `resolved: >-` block scalar.

## Tasks & Acceptance

**Execution:**
- `docs/ffi-abi.md` -- add a new `## Request-buffer contract` section immediately after
  `## Envelope format` -- the (a) deliverable: how a caller builds the table, the AR-P-5 inbound
  ownership rule (Dart allocates and frees; Rust borrows) and how it is the REVERSE of the
  outbound token rule, the exact refusal ladder (`ffi.null_pointer` for a null `data` with no
  context → `ffi.invalid_argument` with the verifier message for anything that does not verify,
  including a zero-length buffer → `jj.invalid_input` for an absent required field inside a valid
  request), the deliberate non-collapse of an empty buffer to `nullptr`, the interior-NUL rule and
  its two enforcement layers with the length-prefix rationale, `ChangeIdList` as the one shared
  table, the append-only field-order contract, and the no-`file_identifier` caveat with its
  ledger pointer. Document `internal.panic` here (or in `## Envelope format`) as the universal
  `catch_unwind` backstop that no row repeats.
- `docs/ffi-abi.md` -- replace the `## Exported symbols (Story 3.4c)` heading with a
  `## Symbol index` section carrying ONE table with a row per exported symbol, columns
  `| Symbol | Args | Request table | Success payload | Error codes | Story |`, sorted so related
  nouns sit together, and re-head the two surviving `###` blocks under a following
  `## Per-symbol contracts` -- the (b) deliverable and the self-check's data source. State above
  the table that the header rustdoc is authoritative for each code's condition and that the
  index names codes only.
- `docs/ffi-abi.md` -- apply corrections 1-13 from the Code Map in place -- the (c) deliverable;
  nothing else in the surviving prose moves.
- `crates/zanshin-ffi/src/repo.rs` -- add the `watcher.io_error` bullet to the four `# Errors`
  blocks at `:466, :496, :534, :654` -- the generated header currently documents no symbol as
  able to return it, contradicting `docs/rust-error-codes.md:52`.
- `crates/zanshin-ffi/src/graph.rs` -- add the `jj.config_error` bullet to the `# Errors` block at
  `:239` -- `graph.rs:46-47` maps it and `:749-752` asserts it.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` --
  regenerate via one `cargo make codegen` -- generated output is committed and never hand-edited.
- `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` -- new integration test file structured as TWO
  pure functions over `&str` — `exported_symbols(header_src)` and `documented_symbols(doc_src)`,
  both returning a sorted set — plus a `read_artifact(path) -> Result<String, String>` helper
  whose error names the path; the top-level test reads both artifacts from the repo root and
  asserts the export set is a subset of the covered set, naming EVERY miss sorted in one message
  -- the guard that keeps the doc from going stale silently again. Purity is what makes the guard
  itself testable.
- `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` -- add one `#[test]` per I/O-matrix row, driving
  the two pure functions with small inline `&str` fixtures (a doc-comment line naming a symbol; a
  wrapped multi-line declaration; `ZanshinBuf`/`ZANSHIN_FFI_H`; a name appearing only in a
  non-first table cell; a symbol present in the header and absent from the doc; a missing-path
  read) -- a guard nobody tests is a guard that silently stops guarding. Test names describe the
  scenario, per the project's naming rule.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- strike through the `docs/ffi-abi.md`
  bullet at `:214` in the file's existing convention and append
  ` — RESOLVED 2026-09-06 (spec-epic-9-followup-g-ffi-abi-doc-pass, commit <short hash>): <one
  line>`; and insert a new `## Deferred from: spec-epic-9-followup-d-symlinked-workspace-path
  (2026-09-05)` section immediately before the follow-up-E section at `:248`, carrying follow-up
  D's single frontmatter deferral verbatim in the file's bullet style -- the central ledger must
  be complete.
- `_bmad-output/implementation-artifacts/spec-9-3-content-ops-restore-absorb.md`,
  `spec-9-4-file-reads-list-show-annotate-search.md`, `spec-9-7-workspace-reads-list-root.md`,
  `spec-9-8-bookmark-crud-create-delete.md` -- add a `resolved: >-` block scalar to the one
  `deferred:` item in each that mentions `docs/ffi-abi.md`; if an item is a plain string rather
  than a mapping, convert just that item to the `summary:`/`evidence:`/`resolved:` shape without
  changing its text -- each of these specs carried the item forward and must record its close.
  **Corrected during implementation: FOUR files, not six.** The dispatching intent asserted that
  every spec from 9-3 to 9-8 carries a matching `deferred:` item; it does not.
  `spec-9-5-git-local-sync-remote-config.md:847` mentions `docs/ffi-abi.md` only in its Review
  Triage Log, and says the item was "already recorded as deferred by Story 9.4";
  `spec-9-6-read-views-show-evolog-interdiff.md` does not mention the file at all. Neither has a
  frontmatter item to annotate, so neither is touched.

**Acceptance Criteria:**
- Given the doc pass is complete, when `cargo test -p zanshin-ffi --test ffi_abi_doc_sync` runs,
  then it passes with no allow-list, exception set or `#[ignore]` anywhere in the file.
- Given a reviewer removes any one symbol's row from `docs/ffi-abi.md`, when the test runs, then
  it fails and its message names exactly that symbol.
- Given the test file, when `cargo test -p zanshin-ffi --test ffi_abi_doc_sync` runs, then every
  row of the I/O matrix is exercised by a named test that actually ran and passed — none is
  `#[ignore]`d, filtered out, or covered only by the manual negative probe.
- Given the index table, when each row is compared with the header, then the row's Error codes
  cell contains exactly the codes bulleted in that symbol's `# Errors` block — no more, no fewer
  — and every named code exists as a row in `docs/rust-error-codes.md`.
- Given the index table, when the 8 infallible symbols' rows are read, then their Error codes
  cell is `—` and the doc explains once, elsewhere, that `internal.panic` is the universal
  backstop.
- Given `cargo make codegen` has run, when
  `git diff -- crates/zanshin-ffi/include packages/zanshin_core/lib/src/ffi/bindings.dart` is
  inspected, then only doc-comment lines moved and no declaration line changed.
- Given the run is complete, when `git diff -- coverage-baseline.txt schemas/` is inspected, then
  it is empty.
- Given the ledger, when the `docs/ffi-abi.md` bullet and the new follow-up-D section are read,
  then the bullet is struck through with a resolution line and the ledger holds one MORE resolved
  item and no new open one.
- Given each `spec-9-*` file that actually carries a `docs/ffi-abi.md` item in its `deferred:`
  frontmatter (four of them — 9-3, 9-4, 9-7, 9-8; see the corrected task above), when its YAML
  frontmatter is parsed, then it parses and that item carries a `resolved:` field.

## Spec Change Log

## Review Triage Log

### 2026-09-06 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 14: (high 1, medium 6, low 7)
- defer: 0
- reject: 14: (high 0, medium 1, low 13)
- addressed_findings:
  - `[high]` `[patch]` **The pass introduced a false safety claim.** The new `internal.panic`
    section said "no panic ever crosses the C ABI" and that "the `void`-returning infallible
    functions are `catch_unwind`-wrapped too". Verified: `crates/zanshin-ffi/src/ffi_strings.rs`
    contains no `catch_unwind` at all, so `zanshin_string_free`, `zanshin_buffer_free` and
    `zanshin_buffer_free_token` are NOT wrapped — only four of the seven are (`logging.rs`,
    `events.rs`). Rewritten to name the four that are wrapped and the three that are not, and to
    say why nothing was added to them (pointer checks plus a `drop`). Shipping this was the exact
    defect class the run exists to remove.
  - `[low]` `[patch]` The `panic = "unwind"` precondition (`envelope.rs:499-502`) was dropped in
    the move from rustdoc into the doc; restored with its citation.
  - `[low]` `[patch]` `zanshin_diagnostics` "always answers `ok == true`" contradicted the
    backstop paragraph; reworded to "for every input — the backstop is its only `ok == false` arm".
  - `[medium]` `[patch]` The guard could pass VACUOUSLY: only `!exported.is_empty()` was asserted,
    so a scanner regression that silently dropped symbols would leave it green. Pinned with
    `EXPECTED_EXPORTS = 47` (the `test-cargo-hygiene` expected-count precedent), and
    `declared_symbol` — which bailed after the first `zanshin_` on a line — became
    `declared_symbols`, scanning every occurrence, with a fixture test for a `zanshin_`-prefixed
    return type.
  - `[medium]` `[patch]` `documented_symbols` was not fence-aware, so a `#`- or `|`-prefixed line
    inside one of the doc's own ```c / ```dart samples counted as coverage. Fence toggle added,
    with a fixture test.
  - `[medium]` `[patch]` **The strongest claim in the change had no committed check.** The AC
    "the row's Error codes cell contains exactly the codes bulleted in that symbol's `# Errors`
    block" was verified by a one-off script that was never committed, so five of the six index
    columns could rot exactly as the doc had. Three tests now enforce it against the real
    artifacts — per-symbol set equality against the rustdoc bullets, registry membership for every
    named code, and `internal.panic` in no row — plus two fixture tests for the parser (a
    `# Safety` mention must not count; a dropped code must be detected).
  - `[low]` `[patch]` The negative test re-implemented the filter instead of driving the
    production path; `missing_symbols` extracted and both call it.
  - `[medium]` `[patch]` The request-buffer contract documented the refusal ladder but not the
    caller's `len` obligation — an over-long `len` is an out-of-bounds read before any
    verification runs, i.e. UB, not a refusal. Stated explicitly.
  - `[medium]` `[patch]` The interior-NUL section named two Dart layers and no Rust layer without
    saying that Rust never re-checks; a caller bypassing the adapters is unguarded. Stated.
  - `[low]` `[patch]` `(strict-fail, OQ-1)` reached the public generated header with no expansion;
    the four `watcher.io_error` bullets now spell the rule out instead.
  - `[medium]` `[patch]` In `zanshin_repo_clone`'s block the new bullet ("the cloned workspace
    persists") sat three lines under "the partial workspace is already rolled back". Both are
    true; the bullet now says arming runs AFTER the clone has succeeded, so the rollback does not
    apply. The `init`/`convert` bullets got the same clarification.
  - `[low]` `[patch]` The no-`file_identifier` caveat cited `deferred-work.md:194` — a line number
    in a file this very change inserts a section into. Now cited by the bullet's title.
  - `[low]` `[patch]` Three Code Map/task facts the implementation disproved were left standing in
    the spec: the intent's premise that all six `spec-9-*` specs carry the deferral (only four do
    — 9-5 mentions it in prose only, 9-6 not at all), "ten" files importing `dart:ffi` (fourteen),
    and `zanshin_git_fetch`'s owning story (6.5, not 6.4a). All three corrected in place with
    their evidence, and the last acceptance criterion rewritten so it is satisfiable.
  - `[low]` `[patch]` The lifted follow-up-D ledger entry dropped that item's own reason for
    having been spec-only; the preamble now records that this lift overrides that call.
  - Rejected (not fixed, with reasons): the "eight vs nine infallible" reading (the text already
    distinguishes plain-return from no-`# Errors` explicitly); guarding the doc's other prose
    counts (16/15/25) — the export-count pin covers the failure mode that matters; group
    separators, anchors and a TOC for the index (the nine-group ordering was verified correct, the
    rest is cosmetic); the overloaded `—` legend and the two narrative Story cells (both explained
    in the text); the reverse-direction guard (matches the intent's literal predicate; recorded as
    a design choice); a panic-return contract for `zanshin_ffi_version`; a recovery paragraph for
    arming failure (already in *Async events*); enforcing the "no `dart:ffi` in `lib/src/worker/`"
    invariant with a new lint; `verify-codegen` being outside `cargo make test` (pre-existing,
    deliberately deferred at `Makefile.toml:349`, and mitigated by the extern-fn coverage guard);
    a path-existence check over every citation (the doc legitimately cites jj-CLI and jj-lib paths
    absent from this repo); mid-line block-comment state tracking (a shape cbindgen never emits;
    the multi-occurrence fix covers the real risk); and speculative parser cases (two declarations
    on one line, a duplicate index row, an empty document).

## Design Notes

**Why editing `# Errors` rustdoc is inside a "documentation-only" run.** `zanshin_ffi.h` is a
committed *generated document* — cbindgen lifts the rustdoc verbatim. Its `# Errors` blocks are
the per-symbol contract the new index is derived from, so writing an index that contradicts the
header would create exactly the drift this run exists to kill. The edits are comment-only, change
no behaviour, and the same shape has precedent in this epic: `spec-epic-9-followup-b` corrected
14 doc sites across module/facade/`extern "C"` layers and regenerated both artifacts. The
boundary is drawn tightly: only bullets the index proves missing, nothing else in the rustdoc.

**Two of the intent's named (c) items turn out to be non-issues, and that is a finding, not a
skip.** `AbsorbSkippedPath` appears nowhere in `docs/` — the rename is invisible to this doc
because the doc never documented absorb at all, so the fix is coverage (a row + the `AbsorbResult`
payload), not a rename. And the `session_id` correlation section (`:305-324`) was verified
accurate against `schemas/envelope.fbs:300-303, 445-450, 456-461` and
`packages/zanshin_core/lib/src/worker/isolate.dart:1343-1352`; it is NOT superseded and must be
left alone. Thirteen *other* statements are false; those are the real (c) work.

**Why an index table rather than 47 prose sections.** The header already carries a full rustdoc
block per symbol; reproducing it would double the maintenance surface the self-check is meant to
protect and would put 1700 lines of prose one edit away from drifting again. The doc's job is the
cross-cutting contract plus a navigable index; the four symbols whose contract genuinely exceeds
their rustdoc (`repo_detect`, `repo_convert`, `graph_slice`, `log_defaults`) keep their prose
sections. The index is also what makes the guard cheap: one row per symbol is a mechanically
checkable invariant, where "has adequate prose" is not.

**Why the guard is one-directional.** The intent asked for "a `zanshin_` function … has no
heading/row". The reverse check (a doc row for a symbol the header no longer exports) is five more
lines and would catch a rarer drift, but it is not what was asked and the project's Simplicity
First rule says not to add it speculatively. Recorded here so a later reader sees it was a choice.

**Parsing rule, verified empirically at baseline.** Skipping lines whose trimmed start is `*`,
`/*` or `//` and then matching lowercase `zanshin_` + identifier + `(` yields exactly the 47
names, with no false positives — `ZanshinBuf`, `ZANSHIN_FFI_H` and the
`void (*callback)(ZanshinBuf *event)` parameter are all excluded by the lowercase prefix, and
`zanshin_graph_slice`'s wrapped declaration is caught because the name is on the first line.

**Observed and deliberately not touched** (mention-don't-fix, per the project's surgical-change
rule): six `# Safety` blocks omit `zanshin_repo_convert` from the valid-handle list
(`zanshin_ffi.h:402, 425, 1133, 1150, 1233, 1605`); `zanshin_ffi_version` has no `# Safety`
despite a caller-must-free contract (`:298-310`); internal Rust helper names (`string_to_cstring`,
`vec_into_ffi_buf`, `vec_into_token`) leak into the public header; four symbols never name their
payload table in prose (`zanshin_op_log`, `_repo_detect`, `_diagnostics`, `_repo_convert`);
`RepoDetect` is the only union member with no story line in the registry block; and the stale
`app/lib/src/ffi/…` paths plus future-tense `Progress` comments listed under **Never**. None is
false-by-omission in the way the two `# Errors` gaps are, and none is in this doc's surface.

## Verification

**Commands:**
- `cargo make codegen` -- run ONCE, after the two rustdoc edits; expected: only doc-comment hunks
  in `zanshin_ffi.h` and `bindings.dart`.
- `git diff --stat -- crates/zanshin-ffi/include packages/zanshin_core/lib/src/ffi/bindings.dart`
  -- expected: two files, doc-comment lines only; no declaration line moved.
- `cargo test -p zanshin-ffi --test ffi_abi_doc_sync` -- expected: pass.
- Negative probe: delete one symbol's row from `docs/ffi-abi.md`, re-run the test -- expected:
  FAIL naming exactly that symbol; restore the row.
- `cargo clippy --workspace --all-targets -- -D warnings` -- expected: clean, INCLUDING the new
  test file.
- `git diff -- coverage-baseline.txt schemas/` -- expected: empty.
- For each of the six `spec-9-*` files and `deferred-work.md`: parse the YAML frontmatter (e.g.
  `python3 -c "import sys,yaml; yaml.safe_load(...)"`) -- expected: parses without error.
- `cargo make test` -- expected: exit 0. Run unpiped and synchronously, allow ~15 minutes. The
  single gate; it ends with the coverage ratchet.
- `git status --porcelain` -- expected: clean after the final commit.

**Manual checks (if no CLI):**
- Spot-check five index rows spanning different shapes (one infallible, one handle-only, one
  request-buffer, one C-string, `zanshin_graph_slice`) against the header's `# Errors` block and
  against `schemas/envelope.fbs` — every field of the row must be traceable to a line in one of
  those two files. (Superseded for the Error-codes column by the review pass, which committed
  `every_index_row_names_exactly_the_error_codes_its_rustdoc_bullets_do`.)

## Auto Run Result

Status: done
Blocking condition: none

### Summary

`docs/ffi-abi.md` is current for the whole FFI surface again, and can no longer go stale
silently. Three things landed.

**(a) The request-buffer convention is documented once.** A new `## Request-buffer contract`
section covers the shared three-parameter shape, the AR-P-5 **inbound** ownership rule (Dart
allocates AND frees; Rust only borrows) as the explicit reverse of the outbound token rule, the
three-layer refusal ladder — `ffi.null_pointer` with no context → `ffi.invalid_argument` with the
verifier message, where a zero-length or garbage buffer lands → `jj.invalid_input` for a required
field absent from an otherwise valid table — the caller's `len` obligation (an over-long `len` is
an out-of-bounds read before verification runs: UB, not a refusal), the deliberate non-collapse
of an empty buffer to `nullptr`, the interior-NUL rule with both Dart enforcement layers **and**
the fact that Rust never re-checks, the 15 request tables with `ChangeIdList` as the only shared
one, the append-only field-order contract, and the open no-`file_identifier` caveat cited by
ledger-bullet title rather than by line.

**(b) A `## Symbol index` with one row per exported symbol — all 47, no allow-list.** Columns are
`| Symbol | Args | Request table | Success payload | Error codes | Story |`, grouped by noun.
Every row is derived: signature from `crates/zanshin-ffi/include/zanshin_ffi.h`, request and
payload tables from `schemas/envelope.fbs`, error codes verbatim from that symbol's `# Errors`
block, cross-checked against `docs/rust-error-codes.md`. `internal.panic` is documented once as
the universal backstop and appears in no row.

**(c) Fifteen falsified statements corrected.** Thirteen were found in planning (the infallible
list naming 4 of 8; `zanshin_repo_convert`'s error table; a `_onNativeEvent` sample naming a
function that does not exist; the event-demux lookup site; "the raw handle is used only for close
plus read wrappers", false since Story 6.5; "the only file allowed to import `dart:ffi`",
contradicted by fourteen files; three `v0.42.0` anchors for a pin that moved to `=0.44.0`; the
missing `ui.conflict-marker-style` builtin; a stale `cli_util.rs` line range; `syntheticElided =
true`), and two more were introduced by the pass itself and caught in review — see the Triage Log.

Two premises the dispatching intent named turned out to be **non-issues, and that is a finding**:
`AbsorbSkippedPath`/`SkippedPath` appears nowhere under `docs/`, so the gap was coverage rather
than a stale name; and the `session_id` correlation section was verified accurate and left alone.
A third intent premise was simply false: only four of the six `spec-9-*` specs carry a
`docs/ffi-abi.md` deferral.

**The guard.** `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` — no new dependency, no
`Makefile.toml` wiring (`cargo make test` already runs `cargo test --workspace`). Fifteen tests
over four pure `&str` scanners: the header's export set must be a subset of the doc's covered set
(naming every miss, sorted, in one message), the export count is pinned at 47 so a scanner
regression cannot make the subset check pass vacuously, every index row's Error-codes cell must
equal that symbol's `# Errors` bullets exactly, every named code must be registered, and
`internal.panic` must appear in no row. Ten fixture tests pin the parsing rules themselves.

Two `# Errors` rustdoc gaps the cross-check proved were fixed at the source and regenerated
(comment-only, one `cargo make codegen`, no declaration line moved, no `.fbs` edit):
`watcher.io_error` was documented on **no** symbol although `arm_session` returns it from
`zanshin_repo_open`/`_init`/`_clone`/`_convert`, and `jj.config_error` was missing from
`zanshin_graph_slice` although `graph.rs:46-47` maps it and `:749-752` asserts it.

### Files changed

- `docs/ffi-abi.md` — the doc pass: request-buffer contract, 47-row symbol index, fifteen corrections.
- `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` — new; the doc-staleness guard (15 tests).
- `crates/zanshin-ffi/src/repo.rs` — `watcher.io_error` added to four `# Errors` blocks (comment-only).
- `crates/zanshin-ffi/src/graph.rs` — `jj.config_error` added to one `# Errors` block (comment-only).
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` — regenerated; doc-comment hunks only.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the `docs/ffi-abi.md` fruit struck through and resolved; follow-up D's single deferral lifted into a new section before follow-up E.
- `spec-9-3-…`, `spec-9-4-…`, `spec-9-7-…`, `spec-9-8-…` — `resolved:` block scalars on their `docs/ffi-abi.md` deferrals (9-5 and 9-6 carry no such frontmatter item).

### Review findings breakdown

- Patches applied: **14** (high 1, medium 6, low 7) — detailed in the Triage Log.
- Items deferred: **0**. The ledger ends this run with one item resolved and none added.
- Items rejected: **14** (medium 1, low 13), each with a reason recorded in the Triage Log.

Follow-up review recommendation: **true** — a `high`-severity patch was applied (the false
`catch_unwind` claim), and the weighted score is 3×6 + 1×7 = 25, well over the threshold of 5.

### Verification performed

- `cargo make test` — **exit 0** (620 s), run unpiped and synchronously. Coverage held at 99.22 %
  (8492/8559); `coverage-baseline.txt` did not move, as expected for a file under `tests/`.
- `cargo test -p zanshin-ffi --test ffi_abi_doc_sync` — 15 passed, 0 ignored.
- Negative probe: removing `zanshin_absorb`'s index row fails with
  `1 of 47 symbols … zanshin_absorb`; row restored via `git checkout`.
- Independent script cross-check (before the equivalent test was committed): all 47 rows matched
  their header `# Errors` block exactly, all 31 named codes registered, `internal.panic` in no row.
- `git diff` over the regenerated header and bindings, filtered to non-comment lines: empty.
- `git diff -- coverage-baseline.txt schemas/`: empty.
- `cargo fmt --all --check`: clean. `cargo clippy -p zanshin-ffi --all-targets -- -D warnings`: clean.
- All touched YAML frontmatter re-parsed with `yaml.safe_load`.

### Residual risks

- **The guard is one-directional.** A row for a symbol the header no longer exports is not caught.
  This matches the intent's literal predicate and is recorded in the test's module doc.
- **Five of the six index columns beyond Error codes are still unguarded.** Args, Request table,
  Success payload and Story are verified by reading, not by a test. Error codes — the column most
  likely to drift, and the one the spec made an acceptance criterion — is now enforced.
- **The doc's other prose counts (16 request-buffer symbols, 15 request tables, 25 union members)
  are unguarded.** Only the export count is pinned; a `.fbs` change could leave the others stale.
- **`EXPECTED_EXPORTS` must be bumped deliberately** when a symbol lands. That is the intended
  cost: it forces a reader back to the doc's prose counts at the same moment.
- **The guard reads the committed header**, and `verify-codegen` is deliberately outside
  `cargo make test` (`Makefile.toml:349`), so a new `extern "C" fn` added without running
  `cargo make codegen` is invisible to it. Pre-existing repo posture, mitigated by the extern-fn
  coverage guard, which requires a Dart test calling the symbol through the cdylib.

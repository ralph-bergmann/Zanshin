---
title: 'Story 9.16 closing run — cbindgen skips the FlatBuffers module, so the header carries no VT_*/ENUM_* constants'
type: 'chore'
created: '2026-10-23'
status: 'done'
baseline_revision: 'b68d9023eb9f630b7642bd6b905a07feb5e497c3'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 9.16's deferred item 1, verified at `b68d902`: cbindgen 0.28 parses the flatc-generated module `envelope_generated` (`crates/zanshin-ffi/src/lib.rs:15-18`) and emits its associated consts as `<Table>_VT_<FIELD>` defines — but only one per bare name across all tables, so every regeneration silently adds and drops tables' offsets (`zanshin_ffi.h` holds 255 such lines incl. `ENUM_MIN_*/ENUM_MAX_*`, mirrored into `packages/zanshin_core/lib/src/ffi/bindings.dart`). `cbindgen.toml`'s `[export] exclude` comment states these "must NOT appear in the C header", yet its per-name list (`VT_CODE`, `VT_OK`, …, `ENUM_MIN_PAYLOAD`) covers only the first schema's names. No C, Dart or Rust consumer reads any of them (grep over `packages`, `app`, `crates` outside the generated files: none).

**Approach:** Make the header silent: annotate the `envelope_generated` module declaration with `/// cbindgen:ignore` so cbindgen skips the whole generated module (probed: the regenerated header differs from the committed one only by the removed `_VT_`/`ENUM_MIN_`/`ENUM_MAX_` lines — no function, typedef or other item changes); replace the now-dead per-name exclude list in `cbindgen.toml` with a comment pointing at the annotation; regenerate with `cargo make codegen`; add a guard test that the header carries no `#define` but its include guard.

## Boundaries & Constraints

**Always:** All `zanshin_*` function declarations, `ZanshinBuf` and every hand-written item stay byte-identical in `zanshin_ffi.h` (78 exports, `EXPECTED_EXPORTS` unchanged); the generated outputs are produced only by `cargo make codegen`, never hand-edited; the Rust `fbs` re-export (`lib.rs:27`) and its users are untouched.

**Never:** No schema (`schemas/*.fbs`) change, no flatc output change, no per-table prefixing of the constants, no hand edit of `zanshin_ffi.h` / `bindings.dart`, no change to Story 9.16's spec or verbs, no `epics.md` / `epic-9-context.md` change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Regenerated header | `cargo make codegen` after the change | no line containing `_VT_`, `ENUM_MIN_` or `ENUM_MAX_`; the only `#define` is `ZANSHIN_FFI_H`; 78 `zanshin_*` declarations | No error expected |
| Regenerated Dart bindings | same run | `bindings.dart` carries no `_VT_` / `ENUM_M*` constants; every `zanshin_*` binding unchanged | No error expected |
| A future schema adds a table | new `VT_*` names in `envelope_generated.rs` | header stays silent (module ignored) | guard test fails if a `#define` other than the include guard ever appears |

</intent-contract>

## Code Map

- `crates/zanshin-ffi/src/lib.rs:15-18` -- `#[allow(warnings)] pub(crate) mod envelope_generated;` with a WHY comment; add `/// cbindgen:ignore` (doc-comment form cbindgen 0.28 honours on `mod` items) and extend the WHY. Only `zanshin_ffi.h` consumers are affected; `pub use envelope_generated::zanshin::ffi as fbs` (:27) is not parsed by cbindgen.
- `cbindgen.toml:21-50` -- `[export] exclude` per-name list + WHY comment; dead once the module is ignored → replace with a comment naming the `cbindgen:ignore` annotation as the mechanism (drop the `[export]` table if empty).
- `Makefile.toml:531-591` -- READ-ONLY: `codegen` = flatc-rust, flatc-dart, cbindgen (`--config cbindgen.toml --crate zanshin-ffi --output crates/zanshin-ffi/include/zanshin_ffi.h`), ffigen (`packages/zanshin_core/ffigen.yaml`, header entry point; `functions.include: zanshin_.*` — macros were passed through).
- `crates/zanshin-ffi/include/zanshin_ffi.h` / `packages/zanshin_core/lib/src/ffi/bindings.dart` -- generated outputs; regenerate and commit.
- `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs` -- reuse `read_artifact(HEADER_PATH)`; add the guard test here (it already owns header-shape guards).
- `crates/xtask/src/tasks/gate_plan.rs:197` -- READ-ONLY: `cbindgen.toml` already maps to the RUST+APP groups.
- `_bmad-output/implementation-artifacts/deferred-work.md:49` and `:1876-1878` -- the two ledger entries for this leak (Story 1.5 review + Story 9.16) → mark RESOLVED with the fix commit.
- `_bmad-output/implementation-artifacts/sprint-status.yaml:204` -- `9-16-…` note: append the closing-run resolution.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-ffi/src/lib.rs` -- add `/// cbindgen:ignore` on the `envelope_generated` module, WHY comment says cbindgen would otherwise emit one `VT_*` per bare name -- item 1.
- `cbindgen.toml` -- replace the per-name exclude list with the comment pointing at the annotation -- item 1 (dead config).
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` -- `cargo make codegen`, commit the result -- item 1.
- `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs` -- test: every `#define` in the committed header is the include guard; plus a fixture test that a `Table_VT_X` define is reported -- item 1 guard.
- `_bmad-output/implementation-artifacts/deferred-work.md`, `sprint-status.yaml` -- resolve both ledger entries; note the closing run (spec commit).

**Acceptance Criteria:**
- Given the changed config, when `cargo make codegen` runs, then `zanshin_ffi.h` and `bindings.dart` contain no FlatBuffers `VT_*`/`ENUM_*` constants and no other diff.
- Given the committed header, when `cargo test -p zanshin-ffi --test it ffi_abi_doc_sync::` runs, then the new guard and the 78-export pin pass.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 22 findings — high 0, medium 0, low 9, false 13, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `Makefile.toml` `[tasks.codegen]` WHY says flatc runs first so cbindgen sees the generated types — stale now that cbindgen skips the module; reworded to the remaining reason (the crate cannot compile without the accessors; deterministic order), commit 3c8dae1.
  - `[low]` `[reject]` (blind) the "new `*_generated` module gets `cbindgen:ignore`" rule is not in `project-context.md` / the flatc task — a new module without it fails `the_header_defines_no_macro_but_its_include_guard`, whose message names the annotation, so nothing can leak silently; an extra rule in an agent-context file adds nothing the guard does not enforce.
  - `[false]` `[reject]` (blind) `ffigen.yaml` has no `macros:` filter, so the Dart side has no guard — ffigen only reads `zanshin_ffi.h`, whose every `#define` but the include guard the new test refuses; no macro can reach `bindings.dart` without failing that test first.
  - `[low]` `[patch]` (blind) the guard's failure message always blames a flatc module, misleading for a deliberate future C-visible constant — message now names both causes, commit 3c8dae1.
  - `[false]` `[reject]` (blind) the guard only checks `#define`, so typedefs/structs/typed consts from an un-annotated module go unnoticed — the pre-change probe (module parsed) produced only `#define` lines from it (the regenerated header's diff is `_VT_`/`ENUM_M*` deletions only); under the committed `cbindgen.toml` the module emits nothing else.
  - `[low]` `[reject]` (blind) the `#define` scanner misses `# define X` / `#\tdefine X`, `INCLUDE_GUARD` duplicates `cbindgen.toml`, fixtures lack edge cases — cbindgen never emits the spaced form or changes its guard spelling unasked; handling them adds parsing for a form no generator here writes. Sub-claims refuted: a `#define` inside a doc block starts ` * ` and is not matched; a guard-prefix name like `ZANSHIN_FFI_H_EXTRA` would itself be reported as stray.
  - `[low]` `[reject]` (blind) correctness rests on an unpinned cbindgen honouring module-level `cbindgen:ignore` — cbindgen has honoured it on `mod` items for many releases, and whatever version runs, a leak fails the guard test; pinning the tool is a dev-setup change outside item 1.
  - `[low]` `[patch]` (blind) `lib.rs`: the lint WHY no longer sits above the `#[allow(warnings)]` it explains — reordered (cbindgen WHY above `/// cbindgen:ignore`, lint WHY above `#[allow(warnings)]`), header regenerated byte-identical, commit 3c8dae1.
  - `[false]` `[reject]` (blind) the resolved ledger entries contradict themselves — the 3-0 entry labels the old text "Original:", the 9.16 entry is struck through with RESOLVED and "Follow-up: Done"; the remaining bullet is historical evidence, not a live status.
  - `[false]` `[reject]` (blind) the closing spec is untracked, so ledger references dangle — it is committed at finalize (this pass), in the same commit as the ledger edits.
  - `[low]` `[reject]` (edge) `stray_defines` misses `# define NAME` — same as the blind scanner row: cbindgen never writes that form; rejected for the same reason.
  - `[low]` `[patch]` (edge, side note) the `[tasks.codegen]` WHY is out of date — same defect as the first blind row; patched there.
  - `[false]` `[reject]` (intent) `ENUM_MIN_*`/`ENUM_MAX_*` removed beyond item 1's `VT_*` — the item's follow-up asks for a header that is "complete or silent", and `cbindgen.toml`'s own comment already said both kinds must not appear; ignoring the module is the one mechanism, and nothing consumes either kind.
  - `[false]` `[reject]` (intent) the Story 3-0 ledger entry was resolved too — it is the same root cause and the same fix; leaving it open would misstate the ledger.
  - `[false]` `[reject]` (intent) `bindings.dart` changed though item 1 names only the header — ffigen regenerates it from the header; committing codegen output is required by the run's gate rule.
  - `[false]` `[reject]` (intent) resolving ledger entries is an edit the intent did not ask for — the intent forbids re-mirroring, not resolving; marking a fixed item resolved is the established closing-run practice (e.g. spec-9-40-closing).
  - `[false]` `[reject]` (intent) the test checks the committed header, not cbindgen's behaviour — the header reaches consumers only through committed codegen output, so the committed artifact is the surface; the regeneration probe (byte-identical) is recorded below.
  - `[low]` `[patch]` (intent) the guard enforces a stricter "no `#define` but the guard" policy than stated — grouped with the failure-message row: the message now says a new public constant needs an explicit decision, commit 3c8dae1.
  - `[false]` `[reject]` (intent) nothing tests the Dart side — `bindings.dart` is a pure function of the guarded header; the zanshin_core suite (953 tests) exercised every binding.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize (this pass).
  - `[false]` `[reject]` (intent) verification outcomes not recorded — written at finalize (this pass).
  - `[false]` `[reject]` (intent) no "Surfaced in the closing run" section — no new finding was deferred (`deferred: []`), so nothing is mirrored.

## Verification

**Commands (targeted; the story loop runs the full gate — do NOT run `cargo make test`, `cargo make test-full` or `cargo make coverage`):**
- `cargo make codegen` -- expected: only the VT_/ENUM_ lines leave the two generated files.
- `cargo test -p zanshin-ffi --test it ffi_abi_doc_sync::` -- expected: green.
- `cargo clippy -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `cd packages/zanshin_core`: `dart analyze`, `dart format --set-exit-if-changed lib test`, `flutter test` (or `dart test`) -- expected: clean/green (bindings.dart changed).

**Verification notes (run 2026-10-23; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo make codegen` (implementer, after the fix and again after the review reorder) — `zanshin_ffi.h` and `bindings.dart` lose 630 lines each, all `_VT_`/`ENUM_MIN_`/`ENUM_MAX_` defines or their blank separators; no other line changes; the only `#define` left is `ZANSHIN_FFI_H`; 78 `zanshin_*` declarations unchanged. Independent re-run of `cbindgen --config cbindgen.toml --crate zanshin-ffi` into the scratchpad after each commit — byte-identical to the committed header.
- `cargo test -p zanshin-ffi --test it ffi_abi_doc_sync::` — 17 passed (incl. `the_header_defines_no_macro_but_its_include_guard`, `a_flatbuffers_vtable_define_is_reported_as_stray`, the 78-export pin), before and after the review patches.
- `cargo clippy -p zanshin-ffi --all-targets -- -D warnings` — clean (before and after patches).
- `cargo fmt --all --check` — clean.
- `packages/zanshin_core`: `dart analyze` — no issues; `dart format --set-exit-if-changed lib test` — 0 changed; the package suite via `cargo make --allow-private test-core` (implementer; plain `dart test` needs the task's pinned `XDG_CONFIG_HOME`) — 953 passed.
- No parity oracle (no jj verb changed), no schema change.
- Matrix audit: row 1 (regenerated header) — `ffi_abi_doc_sync::the_header_defines_no_macro_but_its_include_guard` + `every_exported_symbol_has_a_heading_or_an_index_row_in_the_abi_doc` (78-export pin), ran and passed; row 2 (Dart bindings) — `bindings.dart` is ffigen's output of the guarded header (codegen re-run shows no drift) and the zanshin_core suite exercising the bindings passed; row 3 (future table) — `a_flatbuffers_vtable_define_is_reported_as_stray` plus the committed-header guard, ran and passed.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (3154d45c8e4304ed75d24dbae54e158c54194ab1; review patches 3c8dae196b72846cc0b035bf263bd07e077f6e5a).** Verified real at `b68d902`: cbindgen 0.28 parsed the flatc module `envelope_generated` and emitted its associated consts as `<Table>_VT_*` defines, one per bare name across all tables, plus every `ENUM_MIN_*`/`ENUM_MAX_*`; `cbindgen.toml`'s per-name exclude list covered only the first schema. The header is now silent: `/// cbindgen:ignore` on `mod envelope_generated` (`crates/zanshin-ffi/src/lib.rs`) skips the whole module, the dead exclude list is gone, regenerated `zanshin_ffi.h`/`bindings.dart` lose only those defines (no consumer read them), and `ffi_abi_doc_sync` fails if any `#define` but the include guard reaches the header.

**New findings:** none (`deferred: []`; nothing mirrored into deferred-work.md).

**Files changed:**
- `crates/zanshin-ffi/src/lib.rs` (3154d45, 3c8dae1) — `/// cbindgen:ignore` on the flatc module, WHY comments.
- `cbindgen.toml` (3154d45) — per-name `[export] exclude` list replaced by a comment naming the annotation.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` (3154d45) — regenerated; VT_/ENUM_ defines removed.
- `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs` (3154d45, 3c8dae1) — `stray_defines` scanner, committed-header guard, fixture test; neutral failure message.
- `Makefile.toml` (3c8dae1) — `[tasks.codegen]` WHY no longer claims cbindgen reads the flatc module.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the Story 3-0 and Story 9.16 entries resolved (spec commit).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `9-16-…` note records the closing run (spec commit).

**Review:** 22 findings (low 9, false 13). Patched (3 low entries): stale codegen WHY (blind + edge), guard failure message / stated policy (blind + intent), lint-WHY placement in `lib.rs`. Rejected low: agent-context rule for new generated modules (the guard enforces it), spaced `# define` / duplicated guard name / fixture edge cases (cbindgen never writes those forms), unpinned cbindgen (the guard catches any version's leak; tool pinning is outside item 1). Rejected false: ffigen macro filter, non-`#define` leaks, ledger wording, untracked spec, ENUM_* scope, 3-0 ledger entry, bindings.dart regeneration, ledger edits, artifact-vs-cbindgen test surface, untested Dart side, finalize-time sections, no Surfaced section.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 3 entries.

**Residual risks:** a future flatc module declared without `/// cbindgen:ignore` leaks again until codegen is re-run and the guard test fails (the guard reads the committed header, not cbindgen live); `Makefile.toml` changed (comment only), so the loop's final gate runs every step; coverage not measured (test-only additions in `src/`-free code, plus a doc comment).

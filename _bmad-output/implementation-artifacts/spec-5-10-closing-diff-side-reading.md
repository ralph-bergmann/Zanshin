---
title: 'Story 5.10 closing run — read each diff side as color-words does'
type: 'bugfix'
created: '2026-11-12'
status: 'done'
baseline_revision: '5492f38e2272609d4143672d06ae27a526effe08'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 5.10 deferred item 1: `DiffReader::file` (`crates/zanshin-jj/src/hunks.rs`) reads each side through jj-lib's `git_diff_part` (the `jj diff --git` reader), while jj's default color-words format reads it through the CLI's `diff_content_as_merge` and decides binary before comparing contents. Three named differences: (a) an access-denied side fails the whole `Repo::diff`, the CLI prints `Access denied to <path>: …` and goes on; (b) a Git submodule side reads empty, the CLI diffs the text `Git submodule checked out at <commit id hex>`; (c) a binary file whose contents are equal on both sides (mode-only change, rename) is not binary, the CLI prints `(binary)`.

**Approach:** Verified per case. (a) cannot occur in Zanshin: only jj's test-only `SecretBackend` (`testing` feature, dev-dependency only in `crates/zanshin-jj/Cargo.toml:42-50`) raises `BackendError::ReadAccessDenied`, the single source of `MaterializedTreeValue::AccessDenied`; the Git and simple backends never do — reject, no wire marker. (b) and (c) are real with the Git backend — fix them in `DiffReader::file` like the CLI's `diff_content_with` / `show_color_words_diff` (`cli/src/diff_util.rs:1428-1468, 1618-1620` @ v0.47.0).

## Boundaries & Constraints

**Always:**
- A Git submodule side's content is `format!("Git submodule checked out at {id}")` (full hex id, no line break), not binary — so it gets hunks like any text (Generic language), as the CLI shows them.
- `FileDiff::binary` = either side's content is binary (NUL in the first 8000 bytes, jj-lib's `file_util::is_binary` via `git_diff_part` / `file_content_for_diff`), checked before comparing contents; a binary file gets no hunks.
- `FileDiff::fingerprint` keeps its values for unchanged inputs: its binary part (`<` / `>` contents) is added only when the contents differ, as before. So the mode-only fingerprint shared by `mode.sh` and `binmode.dat` stays equal (`tests/it/hunks.rs:378`).
- Every other side kind keeps `git_diff_part`'s reading (identical to `diff_content_with` for Absent, File, Symlink, FileConflict, OtherConflict).
- Docs that state the old binary rule follow the new one: `hunks.rs` module doc and `FileDiff::binary`, `schemas/envelope.fbs` `FileDiff` doc, `packages/zanshin_core/lib/src/ffi/diff.dart` `binary` doc, `docs/ffi-abi.md` `FileDiff` text.

**Never:**
- No access-denied wire marker, no schema field; no change to the inspector code (`inspector_diff.dart` already draws the binary note beside the mode row).
- No full gate (`cargo make test` / `test-full` / `coverage`); targeted checks only.
- No `jj` outside temp dirs; no edit of planning / agent-context files.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Submodule added | Git commit adding gitlink `sub` at `0123…4567` | one hunk, one Added line (right 1) `Git submodule checked out at 0123456789abcdef0123456789abcdef01234567`, as `jj diff --color=debug` | — |
| Binary mode-only | `bin.dat` with a NUL, `jj file chmod x` | `binary: true`, `mode_change: true`, no hunks; CLI prints `(binary)` | — |
| Binary content change | NUL file, contents changed | `binary: true` (unchanged) | — |
| Text mode-only | `mode.sh` chmod | `binary: false`, `mode_change: true` (unchanged) | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:652-669` -- `DiffReader::file`: reads sides with `git_diff_part(...).map_err(be)?`, then `binary = texts.before != texts.after && (left.is_binary || right.is_binary)`. Fingerprint call :697-702 (`binary.then_some(texts)`). Module doc :6-10 and `FileDiff::binary` doc :113-115 state the old rule.
- jj-lib `diff_presentation/unified.rs:60-142` (`git_diff_part`): `GitSubmodule` → empty contents (:100-108); `AccessDenied` → `Err`. `diff_presentation::FileContent { is_binary, contents: BString }` (public fields).
- CLI `cli/src/diff_util.rs` @ v0.47.0: `diff_content_with` :1428-1468 (submodule text :1451-1454), binary-first check :1618-1620, access denied skip :1518-1536.
- `crates/zanshin-jj/tests/it/hunks.rs:384-392` -- test `a_mode_only_change_of_a_binary_file_is_not_binary` asserts the old rule (`!binmode.binary`); invert. `:370-382` asserts the shared mode fingerprint (must stay).
- `crates/zanshin-parity/tests/oracle/diff_color_words.rs` -- `fresh_repo(&["git","init"], &[])`, `jj()`, `driver::git()` (hermetic git), `assert_same(root, witness)` (one changed file, compares hunks, requires lines); `cli_hunks` parser skips `header` lines only (a `(binary)` line would misparse → check binary separately).
- `schemas/envelope.fbs:3234` -- `FileDiff` doc (`binary: the contents differ and …`); doc-only, then `cargo make codegen` (doc comments land in generated code).
- `packages/zanshin_core/lib/src/ffi/diff.dart:192` -- `binary` doc.
- `docs/ffi-abi.md:2509` -- `FileDiff` text on binary.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs` -- add `async fn diff_content(path, value, &ConflictMaterializeOptions) -> Result<FileContent<BString>, MutateError>`: `GitSubmodule(id)` → not binary, the CLI's text; otherwise `git_diff_part(..).content`; doc names `diff_content_with` @ v0.47.0 and why access denied stays an error (unreachable). Use it for both sides; `binary = left.is_binary || right.is_binary`; fingerprint binary part only when `binary && texts differ`. Update module + `FileDiff::binary` docs. Inline test is not possible without a store; covered by the integration test below. -- items (b), (c).
- `crates/zanshin-jj/tests/it/hunks.rs` -- invert the binmode test (`binary && mode_change`, no hunks), rename it; add a submodule test if the fixture can build a gitlink via jj-lib (`TreeValue::GitSubmodule` through a tree builder) — else rely on the oracle witness. -- covers the new lines.
- `crates/zanshin-parity/tests/oracle/diff_color_words.rs` -- witness `a_submodule_side_matches_the_cli` (colocated repo, `git update-index --add --cacheinfo 160000,<id>,sub` + commit, diff `-r @-`); witness `a_binary_mode_change_is_binary_like_the_cli` (CLI stdout contains `(binary)`, Zanshin's file `binary && mode_change`). -- parity.
- `schemas/envelope.fbs`, `packages/zanshin_core/lib/src/ffi/diff.dart`, `docs/ffi-abi.md` -- binary doc text; `cargo make codegen`, commit output. -- docs follow.

**Acceptance Criteria:**
- Given a revision adding a Git submodule, when `Repo::diff` runs, then its lines equal `jj diff --color=debug`'s.
- Given a mode-only change of a binary file, when `Repo::diff` runs, then the file is binary with no hunks and its fingerprint equals a text file's mode-only fingerprint.

## Spec Change Log

## Review Triage Log

### 2026-11-12 — Review pass
- verdicts: 14 findings — high 0, medium 0, low 9, false 5, maybe-false 0 (edge-case hunter: none; verification gap: none)
- findings:
  - `[low]` `[patch]` (blind) `envelope.fbs` / `diff.dart` docs name only the mode-only case, not the rename case or the submodule text — real; patched: both docs say "mode-only change or rename", the schema doc names the submodule text; codegen rerun.
  - `[low]` `[reject]` (blind) No test for a binary rename with equal contents — real gap, but the rename runs through the same `left.is_binary || right.is_binary` expression the mode-only test pins; a rename witness needs copy-record setup for no new branch.
  - `[low]` `[reject]` (blind) The binary mode-change witness only checks `contains("(binary)")` — the Zanshin side asserts no hunks, and `tests/it/hunks.rs:378` pins the fingerprint; the CLI cannot print hunks for a binary file (`diff_util.rs:1618`).
  - `[low]` `[reject]` (blind) Submodule parity covers only the added branch — modified / removed sides go through the same `diff_content` per side and the shared walk; no new branch to cover.
  - `[low]` `[reject]` (blind) `diff_content` rebuilds `FileContent<Vec<u8>>` instead of returning `FileContent<BString>` — zanshin-jj has no `bstr` dependency, so naming `BString` would add one for 4 lines; `id.hex()` prints the same text as the CLI's `{id}`.
  - `[low]` `[patch]` (blind) The `envelope.fbs` reflow left a ~117-char line, copied into the generated files — real; patched with the doc patch above (re-wrapped, codegen rerun).
  - `[low]` `[reject]` (blind) FFI / Dart have no test for `binary && mode_change` — the FFI copies two independent bools, each already tested; the inspector draws the pair (`graph_inspector_test.dart:2127-2152`).
  - `[low]` `[reject]` (blind) The access-denied assumption has no guard — the `diff_content` doc records it at the site; a guard would add a test-only backend path to production code. The pin-bump checklist is a memory/agent-context file this run may not edit.
  - `[low]` `[reject]` (blind) `deferred-work.md` still lists the item as open — the story loop closes ledger items after the run (precedent commit 847a4752); this run's rules keep it out.
  - `[false]` `[reject]` (blind) The spec is out of sync with the code (type, line numbers, empty logs) — a fix edits this build's spec (rule: reject); the logs are written in this step.
  - `[false]` `[reject]` (intent) No `## Auto Run Result` and no commit yet — both are written at finalize, after this review.
  - `[false]` `[reject]` (intent) Conflict sides keep `git_diff_part`, which materializes where the CLI keeps a `Merge` — the walk reads the terms itself (`conflict_terms`, `pair`) and `materialize` diffs the same marker text; FileConflict is never binary in either reader; Story 5.10's two conflict oracle witnesses pass.
  - `[false]` `[reject]` (intent) The inspector drawing of `binary && modeChange` is untested — `graph_inspector_test.dart:2127-2152` covers it (verification-gap layer traced it).
  - `[false]` `[reject]` (intent) Access denied still fails the whole diff at the CLI surface — unreachable: only jj's test-only `SecretBackend` (dev-dependency `testing` feature) raises `ReadAccessDenied`.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it hunks::` and `-- diff::` -- pass.
- `cargo test -p zanshin-jj --lib hunks::` -- pass.
- `cargo test -p zanshin-parity --test oracle diff_color_words::` -- pass.
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- generated files committed. If generated Dart/Rust changed: `cargo test -p zanshin-ffi --lib diff::`, `cargo test -p zanshin-ffi --test it ffi_abi_doc_sync::`, and in `packages/zanshin_core`: `dart analyze`, `dart format --set-exit-if-changed .`.

**Verification notes (2026-11-12, story-loop gate rule, no full gate):**
- `cargo test -p zanshin-jj --test it -- hunks:: diff::` — 62 passed.
- `cargo test -p zanshin-jj --lib hunks::` — 17 passed.
- `cargo test -p zanshin-parity --test oracle diff_color_words::` — 11 passed (2 new witnesses against the pinned CLI).
- `cargo test -p zanshin-ffi --lib diff::` — 8 passed; `cargo test -p zanshin-ffi --test it ffi_abi_doc_sync::` — 17 passed (after the review doc patch).
- `cargo clippy -p zanshin-jj -p zanshin-parity -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — rerun after the review patch; output committed (doc comments only).
- `packages/zanshin_core`: `dart analyze` clean, `dart format --set-exit-if-changed .` 0 changed, `flutter test test/ffi/diff_test.dart test/worker/diff_test.dart` — 21 passed.
- Not run: full gate, coverage (left to the loop's final gate).

## Auto Run Result

Status: done

**Item 1** (diff sides read like `git_diff_part`, not color-words):
- Part (b), Git submodule side: fixed — reads as the CLI's text `Git submodule checked out at <id>` and diffs like any text (commit 8ed9991e87102913522a45b134ed5f97fc8e9da3).
- Part (c), binary file with equal contents (mode-only change, rename): fixed — `binary` is checked before the contents are compared, as the CLI; fingerprints keep their values (commit 8ed9991e87102913522a45b134ed5f97fc8e9da3).
- Part (a), access denied: rejected — cannot occur in Zanshin. `MaterializedTreeValue::AccessDenied` comes only from `BackendError::ReadAccessDenied`, which only jj's test-only `SecretBackend` raises (jj-lib `testing` feature, a dev-dependency of `zanshin-jj` only); the Git and simple backends never raise it. No wire marker added; the reason is in the `diff_content` doc.

**Files changed:**
- `crates/zanshin-jj/src/hunks.rs` — `diff_content` (submodule text, else `git_diff_part`); binary-first rule; docs.
- `crates/zanshin-jj/tests/it/hunks.rs` — binmode test inverted; new submodule test.
- `crates/zanshin-parity/tests/oracle/diff_color_words.rs` — witnesses `a_submodule_side_matches_the_cli`, `a_binary_mode_change_is_binary_like_the_cli`.
- `schemas/envelope.fbs` + generated Rust/Dart, `packages/zanshin_core/lib/src/ffi/diff.dart`, `docs/ffi-abi.md` — binary / submodule docs.

**Review.** 14 findings (low 9, false 5). Patched (2 low): schema and Dart docs name the rename case and the submodule text; the schema paragraph is re-wrapped. Rejected: binary-rename test (same expression), weak `(binary)` witness (Zanshin side asserts no hunks, fingerprint pinned elsewhere), modified/removed submodule witnesses (same code path), `FileContent<Vec<u8>>` (no `bstr` dependency), FFI/Dart flag-pair test (independent bools, inspector already tested), access-denied guard (doc records it), ledger close (the loop does it), spec-sync (edits the spec), and the intent auditor's false rows — reasons in the triage log. No deferrals.

**Follow-up review recommended:** `false` (0 high, 0 medium, 2 low patched).

**Inspector.** No inspector code changed, but what it draws changes: a mode-only change or equal-content rename of a binary file now shows the "Binary file" note (beside the mode row), and a Git submodule shows one added line with the CLI's text. The console session should check the catalogue with Marionette.

**Residual risks.** Coverage not measured (`diff_content` should be fully covered by the submodule test and every other diff test). Submodule fingerprints change (they were content-less before), so a submodule bump marked Viewed shows as unviewed once.

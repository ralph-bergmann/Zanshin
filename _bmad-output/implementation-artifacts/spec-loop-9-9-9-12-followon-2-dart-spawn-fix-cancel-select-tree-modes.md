---
title: 'Loop 9.9–9.12 second follow-on — Dart spawns only detached, `fix` cancel + per-tool timeout, `select_tree` mode and conflict sections, a stale doc bullet'
type: 'feature'
created: '2026-10-24'
status: 'done'
baseline_revision: '44b4c00fd1431535be1c5d9d85b7d063f03877f1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-9-52-network-verbs-helper-thread-progress-cancel.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The GUI has no read yet that yields a file's select_tree inputs: a conflicted side's materialized text (a merge's parent tree is held by no revision, so `file show` cannot produce it) and whether a file offers the mode toggle.
    evidence: |-
      select_tree now keys conflicted files over their materialized text (ui.conflict-marker-style + the tree's labels) and accepts FileChoice::ModeAndHunks only for two file-like sides whose modes differ; no read reports either. Extends the pre-existing ledger item "No read yields a file's sections and HunkKeys yet" (Story 5.1); the tests stack @ on the merge to get the text through file_show.
    location: >-
      crates/zanshin-jj/src/select_tree.rs, crates/zanshin-jj/src/file.rs materialize_file_like
    severity: medium
  - summary: >-
      The house rule "Dart code starts child processes only detached" is not scoped, but test code spawns non-detached (about 20 `Process.run` / `runSync` calls in the zanshin_core and app suites, plus this run's `chmod` in select_tree_test.dart); the guard scans `lib/` only.
    evidence: |-
      project-context.md § Dart (the rule this run added) vs packages/zanshin_core/test/worker/{network_operation,warnings,error_reports,select_tree}_test.dart, test/environment/login_shell_test.dart. The fix edits the agent-context rules file, so it is deferred (workflow rule): scope the rule to shipped `lib/` code and say tests may spawn non-detached when no witness depends on a cdylib child's exit status.
    location: >-
      _bmad-output/project-context.md (Dart bullets), app/test/process_spawn_guard_test.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** Four items Ralph decided on 2026-10-24, verified at `44b4c00`:
1. Under a Dart host the VM's exit-code handler `waitpid`s ANY pid while a Dart-started non-detached child lives, so it can reap a child the cdylib started (`fix`'s tool → ECHILD, old content silently kept; jj-lib's `git`, signing). The only Dart spawn today is `login_shell.dart:145` (`detachedWithStdio`), but nothing keeps it so.
2. `fix` (`crates/zanshin-jj/src/fix.rs` `Runner::run_tool`) waits on a tool with no deadline and no cancel: a tool that never exits blocks the repo's worker for good (the CLI's user can Ctrl-C).
3. `select_tree` keeps a mode change and a conflicted file whole-only, but the CLI's builtin diff editor offers a separate `FileMode` toggle (`cli/src/merge_tools/builtin.rs:296-301` @ v0.46.0) and sections a conflicted file over its materialized markers, written back through `conflicts::update_from_content` (`:405-465`).
4. `docs/rust-error-codes.md:200` says the `trunk()` fallback is not ported; Story 9.56 ported it (`jj.trunk_alias_unresolved`, same file `:181`).

**Approach:** (1) a project-context house rule + an app-side guard test scanning every Dart `lib/` tree. (2) `fix` becomes a 9.52-style cancellable operation (token on `FixRequest`, helper isolate, `NetworkOperation<FixResult>`), each tool runs in its own process group that a cancel or the new optional `fix.tools.<name>.timeout` kills; a cancel refuses `jj.cancelled` with no operation, as the CLI's Ctrl-C exits before `tx.finish`. (3) a new `FileChoice::ModeAndHunks` arm and sections over materialized conflicts, applied exactly as `apply_diff_builtin`/`apply_changes`/`write_file` do. (4) drop the stale bullet.

## Boundaries & Constraints

**Always:**
- SAFETY: never a bare `cd <name>` (zoxide may jump into one of Ralph's real repos); absolute paths only; run jj (stock or built) only inside temp dirs a test or you created. Every subagent brief repeats this.
- CLI v0.46.0 is the spec (`git -C /Users/ralph.bergmann/development/projects/privat/jj show v0.46.0:<path>`). Ctrl-C (`cli/src/cleanup_guard.rs` `init`) runs the guards and `exit(1)`: no `tx.finish`, so no fix operation; the pre-verb snapshot's operation stays; blobs already written are unreferenced.
- Item 1: rule under project-context.md § Language-Specific Rules › **Dart:** — "Dart code starts a child process only with `ProcessStartMode.detached` / `.detachedWithStdio`, or the process is started from Rust", plus the ECHILD reason in one or two lines and the guard's path. Guard = `app/test/process_spawn_guard_test.dart`: scans `app/lib/**.dart` and `packages/*/lib/**.dart` (generated files included), comments stripped, and fails naming file:line for every `Process.run` / `Process.runSync` reference (call or tear-off, `io.`-prefixed too) and every `Process.start` whose argument list lacks `mode:` with `detached` or `detachedWithStdio`; a tear-off `Process.start` fails too. It also self-tests its matcher on in-test samples (a bad `run`, a bad `start`, a detached `start`, a commented one). Every package rule in `crates/xtask/src/tasks/gate_plan.rs` already plans `APP`; record that the guard relies on it (a comment at the Dart package rules + an xtask unit test that `app/lib/x.dart` and each `packages/<p>/lib/x.dart` plan `test-flutter`). No Rust change for ECHILD (no reap-proof wait).
- Item 2 cancel — 9.52's pattern end to end: `schemas/envelope.fbs` `FixRequest` appends `cancel_token: uint64` (0 = none); `zanshin_fix` attaches it first (`zanshin_jj::cancel::attach`, as `zanshin_git_remote_changes`); `Repo::fix(&mut self, options, cancel: Option<&CancelGuard>)`; `MutateError::Cancelled` → `jj.cancelled`. Checkpoints: at the verb body's start (after the pre-verb snapshot), before each tool run, and after `fix_files` before the finish. A tool running when the cancel lands is killed (below); `fix_one_file` then returns `Err(FixError::FixContent(Box::new(cancel::Cancelled)))` so `fix_files` stops. A cancelled fix writes no operation; the tools' warnings so far ride the refusal (as on any failure today). Dart: `FixCommand` runs through the worker's scheduler on an `Isolate.run` helper (`_fixOnHelper`, like `_remoteChangesOnHelper`), `scheduler.cancel` accepts a `FixCommand`, `ZanshinWorker.fix` / `RepoHandle.fix` return `NetworkOperation<FixResult>` (empty `progress`); closed-handle / NUL guards stay synchronous throws.
- Item 2 kill: each tool is spawned with `process_group(0)`; on cancel or timeout SIGTERM the group (`killpg`), SIGKILL it if the tool has not exited `KILL_GRACE` (2 s, `cancel.rs`) later. The unsafe `killpg` lives in `cancel.rs` next to its `kill` with a `// SAFETY:` comment. Tool exit is noticed without polling latency; a cancel within ~`POLL_INTERVAL` (50 ms). After a kill, pipes are waited on at most the grace (a descendant that left the group must not hang the call); stderr read until then is recorded as today. A lost exit status (`ECHILD`) keeps today's handling.
- Item 2 timeout: `RawToolConfig` gains `#[serde(default)] timeout` — a non-negative integer of seconds, or a string `<n>ms` / `<n>s` / `<n>m` (non-negative integer `n`), the integer-or-unit-string shape of jj's `snapshot.max-new-file-size`; `0` (any unit) = no timeout (lets a higher layer switch a lower layer's off); absent = no timeout, the CLI's behavior. A malformed value refuses the call as `MutateError::Config` naming `fix.tools.<name>` (the existing deserialize path). Per tool run (one file, one tool). A timed-out run is a failed run: killed, its output discarded, the file keeps the previous tool's content, the next tool runs; it warns the NEW `WarningKind::FixToolTimedOut` → `jj.fix_tool_timed_out` "Fix tool `{name}` timed out after {timeout} for `{path}`" ({timeout} as configured, normalized: `30s`, `500ms`, `2m`), NOT also `jj.fix_tool_failed`. Follow the 6 steps of rust-error-codes.md "A new warning code" (WarningKind + rustdoc, envelope const + arm, literal-table test, api_stability pin, Dart `ZanshinWarningCode` + pin test, registry row).
- Item 3: `FileChoice::ModeAndHunks(Vec<HunkKey>)` = the right side's mode plus these sections (empty: the mode change only); `Hunks` keeps the left mode. Wire: `FileSelection` appends `mode: bool`; `mode` with `whole` refuses `jj.invalid_input` ("{path} is selected whole and by its mode"); Dart `FileSelection.modeAndHunks(path, hunks)` + `mode` field. A file side is **file-like** when it is a resolved regular file or a file conflict (`to_file_merge()` is `Some`); its mode is the builtin's (`read_file_contents`): resolved → its bit, conflict → executable iff the materialized `executable == Some(true)`. Its text is its content, a conflict materialized with `ui.conflict-marker-style` (`crate::config::conflict_marker_style(&ctx.config)`), `marker_len: None`, `store.merge_options()`, and its tree's labels (reuse `file.rs`' materialization; extract a `pub(crate)` helper, the one place Epic 5 cuts conflict sections too). Rules:
  - `ModeAndHunks` on a path whose two sides are not both file-like, or whose modes are equal → stale `"{path} has no mode change"`.
  - Keys need both sides file-like and both texts text (`is_text`); else stale `whole_only`. Keys checked against `sections(left_text, right_text)` as today.
  - Nothing selected (`Hunks([])`, unlisted) → left value (unchanged behavior).
  - Mode only on non-text sides (binary) → `override_file_executable_bit(left value, right mode)` (every term).
  - Otherwise `C = assemble(selected)`, `executable` = right mode for `ModeAndHunks` else left mode, written as builtin `write_file`: copy id = `resolve_file_copy_id(left)` else `CopyId::placeholder()`; left resolved → `File{write(C), executable, copy_id}`; left file conflict → `update_from_content(left file ids, store, path, C, MIN_CONFLICT_MARKER_LEN)`: resolved → `Merge::resolved(id.map(File{id, executable, copy_id}))`, else `left.with_new_file_ids(&ids)` (which keeps the old bits — the builtin's quirk, kept).
  - Still whole-only (module doc divergences, ADR-0003 likewise): added/deleted files, symlinks, submodules, a non-file conflict (`OtherConflict`; the builtin sections its description and panics writing it back), lines inside a section, and a binary file's content toggled apart from its mode change.
  - Staleness rules as 9.50 defined them (`jj.stale_selection`, `check_left`).
- Docs (one change each, in the item's commit): project-context.md (item 1 rule; item 2 — the `Isolate.run` exception bullet names `fix`); `docs/rust-error-codes.md` (item 4 bullet removed, `trunk()` named as ported under § Warning Codes if a pointer is needed; `jj.cancelled` emitters + `zanshin_fix`; the `jj.fix_tool_timed_out` row; `jj.invalid_input` / `jj.stale_selection` emitter text for item 3 if they list select_tree reasons); `docs/ffi-abi.md` (`FixRequest.cancel_token`, the Cancel subsection: fix kills its tool's process group, not by env token; `fix.tools.<name>.timeout`; `FileSelection.mode`); ADR-0003 `:175-185` (the mode/conflict divergence removed, the remaining whole-only list kept); `select_tree.rs` module doc; `Repo::fix` / `FixOptions` / `RepoHandle.fix` docs name the timeout key and the cancel.
- Commits on `main`, `git commit --no-gpg-sign`, message ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`: one code commit per item (1, 2, 3, 4), codegen output committed with its item; spec / ledger bookkeeping separately afterwards (step-04/05 of this workflow).

**Never:** No reap-proof wait or other Rust ECHILD change; no change to the 9.52 env-token descendant walk (fix does not use `env_pair`); no fix progress events; no `deny_unknown_fields`; no timeout default; no new error code (cancel is `jj.cancelled`); no line-level selection, no added/deleted-file or binary-content sections; no Epic 5 read; no UI; no change to the 9.9 / 9.50 specs beyond the bookkeeping fields; no full gate (`cargo make test` / `test-full` / `coverage`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| guard, clean tree | today's `lib/` trees | passes | — |
| guard, bad spawn | sample `Process.run('x', [])` / `Process.start('x', [])` | matcher flags it; `mode: ProcessStartMode.detached` / `.detachedWithStdio` passes | test fails naming file:line |
| fix cancel mid-tool | tool `sleep 30` (via `sh -c`), cancel after start | returns < 10 s; head op = the pre-call head (or the snapshot's), file content unchanged, the tool's process group gone | `jj.cancelled` |
| fix cancel before tools | token cancelled before the call | no tool starts | `jj.cancelled` |
| fix cancel too late | cancel after the result | normal result | none |
| timeout hit | `timeout = "200ms"`, tool sleeps 30 s, second tool `tr a-z A-Z` | returns < 10 s; first run killed, second tool runs on the old content; one `jj.fix_tool_timed_out` naming tool + `200ms` + path | ok result |
| timeout not hit | `timeout = 30`, fast tool | as without timeout | — |
| timeout `0` / absent | — | no deadline | — |
| timeout malformed | `"soon"`, `-1`, `1.5` | — | `jj.config_error` naming `fix.tools.<name>` |
| mode only | `f` `a..e`→`A..E` and +x, `ModeAndHunks([])` | `f` = left text, executable; oracle = `--tool` writing left text, keeping +x | — |
| sections, no mode | same, `Hunks([k1,k3])` | `A b c d E`, not executable; oracle = tool writing it + `chmod -x` | — |
| mode on no mode change | `ModeAndHunks` on an exec-equal file | — | `jj.stale_selection` |
| mode + whole | wire `whole` + `mode` | — | `jj.invalid_input` |
| binary + mode | binary content, +x, `ModeAndHunks([])` | left content, executable | keys on it: `jj.stale_selection` |
| conflict left → resolved right | merge parent conflicted on `f`, revision resolves it; all keys | resolved `f` = right text | — |
| conflict left, some keys | as above, a subset | `update_from_content` result: a conflict with new file ids or a resolved file, exactly as builtin | — |
| resolved left → conflict right | revision conflicted on `f`; a subset | resolved `f` = assembled text (markers included, as builtin) | — |
| other conflict | file/symlink conflict, keys | — | `jj.stale_selection` (whole only) |
| doc | `rust-error-codes.md` | no "not ported" `trunk()` bullet | — |

</intent-contract>

## Code Map

**Item 1**
- `packages/zanshin_core/lib/src/environment/login_shell.dart:145` -- the one spawn (`mode: .detachedWithStdio`) the guard must accept (dot-shorthand form).
- `app/test/` (new `process_spawn_guard_test.dart`) -- repo root = `Directory.current.parent` under `flutter test` from `app/`; resolve robustly (walk up to the dir holding `Cargo.toml` + `app/`).
- `crates/xtask/src/tasks/gate_plan.rs:~255-290` -- Dart package rules (each includes `APP`); its `#[cfg(test)]` module for the new plan test.
- `_bmad-output/project-context.md:120-128` -- **Dart:** bullets (the `Isolate.run` exception bullet sits here too).

**Item 2**
- `crates/zanshin-jj/src/fix.rs:196-222` `RawToolConfig` / `ToolConfig` (+ `timeout`); `:361-500` `Runner`, `fix_one_file`, `run_tool` (spawn `:448`, wait `:462-476`); `:539-606` `fix` (checkpoints, `outcome.map_err(be)` → cancel first); inline tests `:608+` (timeout parsing, `get_tools_config` refusal).
- `crates/zanshin-jj/src/cancel.rs:51-59,185-196,420-430` -- `POLL_INTERVAL`, `KILL_GRACE`, `Cancelled`, crate helpers `is_cancelled` / `checkpoint`, the existing `libc::kill` site; add `pub(crate) fn kill_group`.
- `crates/zanshin-jj/src/repo.rs:3339` `Repo::fix`; `:1826-1839` `remote_changes` (guard plumbing example); `crates/zanshin-jj/src/warning.rs` `WarningKind` (new variant after `FixToolFailed`).
- `crates/zanshin-ffi/src/metaedit_duplicate_fix.rs:271` `zanshin_fix` (+ request reader); `crates/zanshin-ffi/src/remotes.rs:289-308` (attach-first template); `crates/zanshin-ffi/src/envelope.rs:381-385` (fix warning consts, `warning_code()`, literal-table test).
- `schemas/envelope.fbs:427-433` `FixRequest`; `cargo make codegen`.
- Dart: `packages/zanshin_core/lib/src/worker/isolate.dart` `fix` (`:1987`), `remoteChanges` (`:1361`, template), `FixCommand` arm (`:3692`), `GitRemoteChangesCommand` arm (`:3493`), `scheduler.cancel` (`:~4478-4490`), helpers (`:4508-4520`); `handle.dart:1254-1290` `fix`; `commands.dart:2166` `FixCommand`; `ffi/metaedit_duplicate_fix.dart:94` `zanshinFix` (+ `cancelToken`); `ffi/warning.dart` `ZanshinWarningCode`.
- Tests: `crates/zanshin-jj/tests/it/fix.rs` (cancel + timeout rows; tool = `sh -c` scripts in a tempdir; cancel from a second thread via `cancel::register/attach/cancel` as `tests/it/network_cancel.rs` does); `crates/zanshin-jj/tests/it/api_stability.rs` (`Repo::fix` signature, `WarningKind` arm); `crates/zanshin-ffi/tests/it/metaedit_duplicate_fix_ffi.rs` (token on the request, cancelled → `jj.cancelled`); `packages/zanshin_core/test/worker/metaedit_duplicate_fix_test.dart` (`.result`; a cancel of a `sleep` tool → `jj.cancelled`, robust to ECHILD — the flag decides), `test/ffi/warning_test.dart` pin.

**Item 3**
- `crates/zanshin-jj/src/select_tree.rs:1-43` module doc; `:83-91` `FileChoice`; `:250-260` `select_tree` (takes config now); `:283-319` `build`; `:323-372` `select_sections` (generalize: file-like sides, modes, materialized texts, the write-back); `:410-414` `is_text`; inline tests.
- `crates/zanshin-jj/src/repo.rs:3431-3432` -- `with_checked_verb(.., |repo, ctx| select_tree(repo.workspace(), &ctx.config, options))`.
- `crates/zanshin-jj/src/file.rs:370-405` -- conflict materialization to extract/share (`materialize_tree_value`, `materialize_merge_result_to_bytes`, `ConflictMaterializeOptions`).
- jj-lib 0.46.0 (`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src/`): `conflicts.rs` `update_from_content`, `MIN_CONFLICT_MARKER_LEN`, `MaterializedTreeValue::FileConflict { executable, .. }`; `backend.rs` `MergedTreeValueExt::to_copy_id_merge`; `merge.rs` `to_file_merge`, `with_new_file_ids`, `SameChange`.
- `crates/zanshin-ffi/src/select_tree.rs:47-88` -- reader `(whole, mode, hunks)`; its inline tests `:164-260`.
- `schemas/envelope.fbs:214-222` `FileSelection` (+ `mode: bool`, doc); codegen.
- `packages/zanshin_core/lib/src/ffi/select_tree.dart:62-79` `FileSelection` + its encoder; `test/worker/select_tree_test.dart`.
- Tests: `crates/zanshin-jj/tests/it/select_tree.rs` (matrix rows; conflicts built with two siblings + `new_change` merge or a rebase; expected values computed with jj-lib's `update_from_content` / materialization per the rules above); `crates/zanshin-parity/tests/oracle/scenarios.rs:574-620,2138-2190` (two `split --tool` scenarios: mode only, sections without mode; the tool script uses `printf` + `chmod`); `crates/zanshin-ffi/tests/it/select_tree_ffi.rs` (`mode` on the wire, `mode`+`whole` refusal); api_stability `FileChoice` pin if any.
- `docs/adr/0003-jj-operation-api-surface.md:175-185`.

**Item 4**
- `docs/rust-error-codes.md:200` -- the bullet; `:181` the ported row.

## Tasks & Acceptance

**Execution:**
- Item 4: `docs/rust-error-codes.md` -- remove the `trunk()` bullet -- stale since Story 9.56. Commit.
- Item 1: `app/test/process_spawn_guard_test.dart`, `crates/xtask/src/tasks/gate_plan.rs` (comment + test), `_bmad-output/project-context.md` -- the rule, guard and gate note. Commit.
- Item 2: `schemas/envelope.fbs` + codegen; `crates/zanshin-jj/src/{fix.rs,cancel.rs,repo.rs,warning.rs}`; `crates/zanshin-ffi/src/{metaedit_duplicate_fix.rs,envelope.rs}`; Dart `ffi/metaedit_duplicate_fix.dart`, `ffi/warning.dart`, `worker/{commands,isolate,handle}.dart`; tests listed in the Code Map; docs. Commit.
- Item 3: `schemas/envelope.fbs` + codegen; `crates/zanshin-jj/src/{select_tree.rs,file.rs,repo.rs}`; `crates/zanshin-ffi/src/select_tree.rs`; Dart `ffi/select_tree.dart`; tests incl. the two oracle scenarios; ADR-0003 and docs. Commit.

**Acceptance Criteria:**
- Given the Dart `lib/` trees, when `flutter test test/process_spawn_guard_test.dart` runs in `app/`, then it passes today and its self-test shows a non-detached spawn would fail it.
- Given a running `RepoHandle.fix` whose tool never exits, when the GUI calls `cancel()` on its `NetworkOperation`, then `result` refuses `jj.cancelled` within a few seconds and the repo has no fix operation.
- Given `fix.tools.<name>.timeout`, when a tool overruns it, then the run is killed, the call succeeds with `jj.fix_tool_timed_out`, and the stock CLI (which ignores the key) still parses the same config.
- Given a mode change or a conflicted file, when the GUI selects the mode toggle and/or sections through `RepoHandle.selectTree`, then the tree equals what the builtin diff editor writes for the same choice, and `split --tool` oracle scenarios for the mode cases match the stock CLI.
- Given the targeted checks below, then each passes and the tree is clean after the commits.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 30 findings — high 0, medium 1, low 26, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) a `FixCommand` cancelled while queued (`_NetworkScheduler.cancel`'s new `|| command is FixCommand`) is untested — Dart test added: a fix queued behind a running fix and cancelled starts cancelled (`a_fix_queued_behind_another_and_cancelled_starts_cancelled`), commit 73134a30cfb4ab99d9cb5daa66c653d12b909cb6.
  - `[low]` `[patch]` (verification-gap) `ToolProcess::kill`'s SIGKILL escalation is never exercised (every sleeper dies on SIGTERM) — test added with a TERM-ignoring tool under `timeout = '1s'` (200 ms raced the trap install under load): `FixToolTimedOut`, group gone, 2.9 s ≤ elapsed < 9 s proves the SIGKILL, commit 73134a3.
  - `[low]` `[patch]` (verification-gap) `select_tree`'s `ui.conflict-marker-style` read and its `jj.config_error` are unverified — tests added: a `git`-style conflicted left keyed from `file show` under that style, and a `nonsense` style refused — by the start-up, which reads the style first, as `Precondition(Config)` → `jj.config_error` (`an_unknown_marker_style_refuses_as_a_config_error`); the `MutateError::Config` doc bullet was dropped, commit 73134a3.
  - `[low]` `[defer]` (blind) the rule says "Dart code" but tests spawn non-detached and the guard scans `lib/` only — the fix edits project-context.md (agent-context rules file) → deferred; mirrored to deferred-work.md.
  - `[medium]` `[defer]` (blind) the GUI cannot get a conflicted side's materialized text (a merge's parent tree) nor whether a file offers the mode toggle — the read side is the pre-existing Story 5.1 ledger item (intent: backend arm only); the new inputs are recorded as a deferred finding and mirrored.
  - `[low]` `[patch]` (blind) no oracle scenario for the mode toggle together with sections — `split_tool_mode_and_sections` added. The conflict cases and a non-default marker style stay out of the oracle: the `--tool` path snapshots the right directory and parses markers against the RIGHT tree's conflict, the builtin parses against the LEFT, so the stock CLI's scripted editor cannot witness the builtin's write-back.
  - `[low]` `[patch]` (blind) the config path of `select_tree` is untested — same root as the verification-gap marker-style row; fixed with it.
  - `[low]` `[reject]` (blind) the kept `with_new_file_ids` quirk and the file-conflict mode rule are unpinned — the toggle on a conflicted file whose exec bits differ needs a hand-built exec-bit conflict fixture; rarely met, the write path is jj-lib's `with_new_file_ids`, and the conflict write-back tests exercise `update_from_content` both ways.
  - `[low]` `[patch]` (blind) `MaterializedTreeValue::AccessDenied` is an undocumented divergence (the builtin sections the text "Access denied: …") — module-doc bullet added.
  - `[low]` `[patch]` (blind) SIGKILL escalation untested — same root as the verification-gap kill row; fixed with it.
  - `[low]` `[patch]` (blind) the Dart cancel test can pass through the pre-tool checkpoint without the kill — `expect(marker.existsSync(), isTrue)` before `cancel()`.
  - `[low]` `[reject]` (blind) four unmanaged threads per tool run; `thread::spawn` panics on exhaustion; pipe threads leak while an out-of-group descendant holds the pipes — the old code's scoped spawn panicked the same way; the threads end with the descendant; a fallback path adds complexity for resource exhaustion only.
  - `[low]` `[reject]` (blind) a tool that exits in time but leaves an out-of-group descendant holding its pipes is reported timed out — the run has not ended (the CLI's `wait_with_output` waits for the pipes too, forever); with a timeout, reporting the overrun is the defensible reading; a daemonizing formatter is rare.
  - `[low]` `[patch]` (blind) the cancelled refusal's payload is underspecified (stderr collected so far lost) — `Repo::fix` doc and ffi-abi § Cancel now say a refusal returns no `FixResult` (warnings ride, stderr does not).
  - `[low]` `[patch]` (blind) `kill_group` sends nothing off macOS although `killpg` is POSIX — the non-macOS arm sends `killpg` too.
  - `[low]` `[reject]` (blind) the guard misses `package:process`, a `mode:` in a nested call, odd-quote interpolations — no package depends on `package:process`; the other two need a Dart parser for contrived code; the guard's doc now states its limits (edge row below).
  - `[low]` `[patch]` (blind) doc comments over 100 columns / a dangling short line — reflowed.
  - `[low]` `[reject]` (edge) `killpg` after the leader was reaped could hit a reused pgid — a pgid stays reserved while any member lives; the window needs the group emptied AND macOS's sequential pids to wrap to that exact id within the kill grace; a `WNOWAIT` zombie hold adds complexity for that.
  - `[low]` `[patch]` (edge) non-macOS `kill_group` no-op — same root as the blind non-macOS row; fixed with it.
  - `[low]` `[reject]` (edge) a spawn inside a string interpolation passes the guard — contrived; fixing needs interpolation parsing; limit documented.
  - `[low]` `[reject]` (edge) a detached `mode:` in a nested call's arguments counts for the outer `Process.start` — contrived; limit documented.
  - `[low]` `[defer]` (edge) the diff's own `chmod` test spawn breaks the unscoped rule — same root as the blind rule-scope row; deferred with it.
  - `[low]` `[patch]` (edge) the guard's doc claims it names every reference — doc now states its two limits.
  - `[low]` `[defer]` (intent) the rule's surface (all Dart) vs the guard's (`lib/`) — same root as the blind rule-scope row; deferred with it.
  - `[false]` `[reject]` (intent) item 2b read as "a timeout code instead of `jj.fix_tool_failed`" where "plus" could mean both — the CLI counts a failed run by skipping it with ONE warning per run; the intent asks that warning to name tool and timeout, which `jj.fix_tool_failed`'s "exited with non-zero exit code" text cannot; emitting both would warn twice for one event. Recorded in the Auto Run Result for Ralph's eye.
  - `[low]` `[reject]` (intent) Ctrl-C parity asserted, not witnessed (no oracle interrupt; the snapshot-before-cancel case untested; SIGINT vs SIGTERM) — an interrupted CLI cannot be scripted deterministically; the checkpoint sits after `with_verb`'s pre-verb snapshot by construction (9.26 pins that snapshot for every verb); the terminal's SIGINT is terminal UX the GUI replaces.
  - `[low]` `[patch]` (intent) queued fix cancel untested — same root as the verification-gap queued row; fixed with it.
  - `[low]` `[reject]` (intent) conflict witnesses re-derive the builtin's rule with jj-lib rather than run the builtin editor — the builtin editor is interactive-only (`apply_diff_builtin` is private) and the `--tool` path parses against the right tree (see the oracle row); the intent names exactly this fallback ("else zanshin-jj tests built from builtin.rs' rules").
  - `[false]` `[reject]` (intent) a mode-only toggle over an equal-text file-conflict left loses the toggle where the builtin applies it — for non-empty equal texts `make_diff_sections` yields an Unchanged section, so `get_selected_contents` returns `Text` and the builtin also writes through `update_from_content` → `with_new_file_ids` (bits kept); only an empty text gives `Unchanged`, and a conflict never materializes empty.
  - `[false]` `[reject]` (intent) staleness extended beyond 9.50 (a new "has no mode change" reason; keys on a mode-change file now "not a current section") — same code, same rule (a selection that is not one of the file's current parts is stale); the new arm needs its stale case and a mode-change text file now has sections, which is item 3 itself.

## Design Notes

- **Why a process group and not 9.52's env token for fix.** The tools are Zanshin's own children, and macOS hides the environment of Apple's binaries (`/bin/sh`, `sed`, …) — the env-token walk would miss exactly the common fix tools. A group per tool kills the tool and what it forks, and needs no descendant walk.
- **Why `jj.cancelled` and not a data result.** A cancelled push reports data because remotes may already hold its refs; a cancelled fix leaves nothing behind (no operation, unreferenced blobs), exactly the CLI's Ctrl-C.
- **Why `ModeAndHunks` and not a `mode` flag on `Hunks`.** Additive: the 9.50 arms and their callers keep their meaning; the new arm is the builtin's checked `FileMode` section.

## Verification

**Commands (targeted; the orchestrating session runs the full gate — no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj --lib` and `cargo test -p zanshin-jj --test it fix::` / `select_tree::` / `api_stability::` / `network_cancel::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it` -- expected: pass (incl. `ffi_abi_doc_sync`).
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (with the two new scenarios).
- `cargo test -p xtask` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p xtask --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen` -- expected: regenerated files committed, no drift afterwards.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed lib test`, and with the gate's pinned env `dart test test/worker/metaedit_duplicate_fix_test.dart test/worker/select_tree_test.dart test/worker/network_operation_test.dart test/ffi/warning_test.dart` -- expected: pass.
- `app`: `flutter test test/process_spawn_guard_test.dart`, `dart analyze`, `dart format --set-exit-if-changed lib test` -- expected: pass.

**Verification notes (2026-10-24, after the review patches, HEAD 73134a30cfb4ab99d9cb5daa66c653d12b909cb6; no `cargo make test` / `test-full` / `coverage` per the gate rule):**
- `cargo fmt --all --check`, `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p xtask --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj --lib` — 358 passed; `cargo test -p zanshin-jj --test it` (every module) — 1238 passed, 1 ignored (pre-existing).
- `cargo test -p zanshin-ffi --lib` — 214 passed; `cargo test -p zanshin-ffi --test it` — 352 passed (incl. `ffi_abi_doc_sync`).
- `cargo test -p zanshin-parity --test oracle` — 334 passed (incl. the new `fix_tool_timeout_key`, `split_tool_mode_only`, `split_tool_sections_no_mode`, `split_tool_mode_and_sections`).
- `cargo test -p xtask` — 26 passed (incl. `every_dart_lib_tree_plans_the_apps_spawn_guard`).
- `cargo make codegen` — no drift (regenerated header / bindings / FlatBuffers committed with items 2, 3 and the review patch).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed lib test` — 0 changed; pinned env `dart test test/worker/{metaedit_duplicate_fix,select_tree,network_operation}_test.dart test/ffi/warning_test.dart` — 202 passed.
- `app`: `flutter test test/process_spawn_guard_test.dart` — 4 passed; `dart analyze` — no issues; `dart format --set-exit-if-changed lib test` — 0 changed.
- Matrix audit: guard rows — `process_spawn_guard_test.dart` (matcher self-tests + the tree scan); fix cancel mid-tool / before tools / too late — `fix::a_fix_cancelled_while_its_tool_runs_kills_the_tools_group_and_writes_nothing`, `fix::a_fix_cancelled_before_it_starts_runs_no_tool`, `fix::a_cancel_after_the_fix_returned_changes_nothing` (+ FFI `a_fix_whose_token_was_cancelled_refuses_jj_cancelled_and_writes_nothing`, Dart cancel + queued-cancel tests); timeout hit / not hit / `0`-absent / malformed — `fix::a_tool_overrunning_its_timeout_…`, `fix::a_timed_out_tool_ignoring_sigterm_…`, `fix::a_timeout_the_tool_stays_within_changes_nothing`, unit `a_tools_timeout_reads_as_seconds_or_a_unit_string`, `fix::a_malformed_timeout_is_refused_naming_the_tool`; mode only / sections no mode — `select_tree::the_mode_toggle_alone_…`, `select_tree::sections_keep_the_left_mode_…` + the oracle scenarios; mode without a mode change — `select_tree::the_mode_toggle_without_a_mode_change_is_stale`; mode + whole — FFI reader unit test ("is selected whole and by its mode"); binary + mode — `select_tree::a_binary_files_mode_is_taken_alone_…`; conflict rows — `select_tree::a_conflicted_left_is_sectioned_over_its_markers_…`, `…_in_the_configured_marker_style`, `a_conflict_edited_inside_a_side_keeps_the_conflict_with_new_file_ids`, `a_resolved_left_takes_the_assembled_text_of_a_conflicted_right_markers_included`; other conflict — `a_non_file_conflict_has_no_sections_and_no_mode_toggle`; doc — the bullet is gone (51b5997). All ran and passed.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (af46df3d2eb1d5566dbd845d505dcd4c7d13f978; review patch 73134a30cfb4ab99d9cb5daa66c653d12b909cb6).** Verified real at `44b4c00`: one Dart spawn (`login_shell.dart:145`, `detachedWithStdio`), nothing keeping it so. House rule in project-context.md § Dart (detached only, or from Rust; the ECHILD reason); guard `app/test/process_spawn_guard_test.dart` over `app/lib` and `packages/*/lib` (flags `Process.run` / `runSync` and a `Process.start` without a detached `mode:`, tear-offs and `io.`-prefixed too; comments and strings blanked; self-tested; its two limits documented). Every package rule in `gate_plan.rs` already plans `APP`, so no rule changed: a comment records the dependency and `every_dart_lib_tree_plans_the_apps_spawn_guard` pins it. No Rust change.
- **2 — fixed (bb053950f2fa711f2a8f7163949b585d642d9e35, test follow-ups bab7c0312cccab5d1eea737c1a71374be0cb0f6c and 994712035e5fe3d982f025cb2a1631566099fde9; review patch 73134a30cfb4ab99d9cb5daa66c653d12b909cb6).** Verified real: `run_tool` waited with no deadline and no cancel. Cancel, 9.52's pattern end to end: `FixRequest.cancel_token`, `zanshin_fix` attaches it first, `Repo::fix(options, cancel)`, checkpoints after the pre-verb snapshot / before each tool run / after `fix_files`; Dart runs `FixCommand` on an `Isolate.run` helper and `RepoHandle.fix` returns `NetworkOperation<FixResult>` (queued cancel included). A cancelled fix refuses `jj.cancelled` and writes no operation — the CLI's Ctrl-C runs its cleanup guards and `exit(1)` before `tx.finish` (`cli/src/cleanup_guard.rs` @ v0.46.0); the pre-verb snapshot stays. Each tool is its own process group (`process_group(0)`): SIGTERM, SIGKILL after 2 s (`cancel::kill_group`, POSIX `killpg`, every unix). Timeout `fix.tools.<name>.timeout`: integer seconds or `<n>ms` / `<n>s` / `<n>m` (the integer-or-unit-string shape of `snapshot.max-new-file-size`), `0` or absent = none, malformed → `jj.config_error`; an overrun is a failed run (killed, output discarded, the next tool runs on the previous content) warning the new `jj.fix_tool_timed_out` "Fix tool `{name}` timed out after {timeout} for `{path}`" — ONE warning per run, not also `jj.fix_tool_failed` (the review's alternative reading "both warnings" was judged false; Ralph may flip it with one line). Oracle `fix_tool_timeout_key`: the stock CLI accepts a config carrying the key.
- **3 — fixed (b08ea22788b10becc2d1794f394cd571c3cc1200; review patch 73134a30cfb4ab99d9cb5daa66c653d12b909cb6).** Verified real: both cases were whole-only. New `FileChoice::ModeAndHunks` (wire `FileSelection.mode`; `mode` + `whole` → `jj.invalid_input`; Dart `FileSelection.modeAndHunks`); file-like sides (resolved file or file conflict) read as `read_file_contents` does (`file::materialize_file_like`, the conflict text shared with `file show`, `ui.conflict-marker-style` + the tree's labels); write-back as the builtin's `write_file` (new file with the left copy id over a resolved left, `update_from_content(…, MIN_CONFLICT_MARKER_LEN)` over a conflicted left, `with_new_file_ids` quirk kept); a binary file's mode alone via the override. Divergence removed from the module doc and ADR-0003; the remaining whole-only cases (added/deleted, symlink, submodule, non-file conflict, access-denied side, binary content apart from its mode, single lines) are listed. Witnesses: zanshin-jj tests from builtin.rs' rules for every case, the oracle for the three mode cases (`split_tool_mode_only`, `split_tool_sections_no_mode`, `split_tool_mode_and_sections`); conflict cases cannot go through `--tool` (it parses markers against the right tree, the builtin against the left). Staleness unchanged (new arm's own reason "has no mode change").
- **4 — fixed (51b5997bba2cc4370a5c88d0cbd0f0695d85b1d2).** Verified real: `docs/rust-error-codes.md:200` called the `trunk()` fallback unported; the bullet is removed (its row `jj.trunk_alias_unresolved` stands at `:181`).

**New findings (deferred, mirrored to deferred-work.md):** the GUI has no read yet for a conflicted side's materialized text / the mode-toggle availability (medium, extends the Story 5.1 ledger item); the house rule is unscoped while test code spawns non-detached (low; its fix edits project-context.md, so deferred by the workflow's agent-context rule).

**Files changed:** `app/test/process_spawn_guard_test.dart` (new); `crates/xtask/src/tasks/gate_plan.rs`; `_bmad-output/project-context.md`; `schemas/envelope.fbs` + regenerated `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`, `bindings.dart`; `crates/zanshin-jj/{Cargo.toml,src/fix.rs,src/cancel.rs,src/select_tree.rs,src/file.rs,src/repo.rs,src/warning.rs}`; `crates/zanshin-ffi/src/{metaedit_duplicate_fix.rs,select_tree.rs,envelope.rs}`; Dart `packages/zanshin_core/lib/src/{ffi/metaedit_duplicate_fix.dart,ffi/select_tree.dart,ffi/warning.dart,worker/commands.dart,worker/isolate.dart,worker/handle.dart}`; tests in `crates/zanshin-jj/tests/it/{fix,select_tree,api_stability,network_cancel,login_shell_environment}.rs`, `crates/zanshin-ffi/tests/it/{metaedit_duplicate_fix_ffi,select_tree_ffi}.rs`, `crates/zanshin-parity/tests/oracle/{main,scenarios}.rs`, `packages/zanshin_core/test/{worker/metaedit_duplicate_fix_test,worker/select_tree_test,ffi/warning_test}.dart`; docs `docs/rust-error-codes.md`, `docs/ffi-abi.md`, `docs/adr/0003-jj-operation-api-surface.md`; bookkeeping `deferred-work.md`, `spec-9-9-metaedit-duplicate-fix.md` / `spec-9-50-hunk-selection-select-tree.md` (`resolved:` fields only), `sprint-status.yaml` (10-26 note), this spec.

**Review:** 30 findings (medium 1, low 26, false 3). Patched (10 entries, all low, commit 73134a3): queued fix cancel test, SIGKILL-escalation test, marker-style tests (a bad style refuses at the start-up as `Precondition(Config)`), the cancel test's marker assertion, `split_tool_mode_and_sections`, `killpg` off macOS, the AccessDenied divergence bullet, refusal-returns-no-stderr docs, the guard's documented limits, doc reflow. Deferred: the GUI's select_tree inputs read (medium), the rule's scope (low). Rejected: the conflict-mode quirk test (needs an exec-bit conflict fixture, rarely met), thread cost/leaks (old code panicked alike; threads end with the descendant), exit-in-time-but-pipes-held reported as timed out (the run has not ended; the CLI waits forever), guard matcher gaps (contrived, documented), a reused-pgid `killpg` (needs a wrap to the same pid within the grace), the Ctrl-C oracle (not scriptable; snapshot pinned by 9.26), conflict witnesses via jj-lib (the intent's own fallback); false: the "both warnings" reading, the equal-text mode toggle (the builtin loses it too), staleness extension (item 3 itself).

**Follow-up review recommended:** false — patched entries at entry verdict: high 0, medium 0, low 10.

**Residual risks:** coverage not measured (gate rule) — new lines in `fix.rs` (`ToolProcess`), `cancel.rs` (`kill_group`), `select_tree.rs` and `file.rs` have witnesses; the orchestrating session's full gate runs the ratchet. A cancel/timeout can take up to ~4 s (two 2 s graces). `epic-9-context.md` (a cached, generated context) still calls mode changes and conflicts whole-only. The non-macOS `killpg` path compiles but is untested here. The SIGKILL test adds ~3 s, the stderr test ~2 s to the suite.

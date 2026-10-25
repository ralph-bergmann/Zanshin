---
title: 'Fix-up after the 2026-10-25 follow-up fixes — kill_group test flakes: bash swallows the SIGTERM'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: '660cafd2626bf03be9103d7c387c8f85955f3323'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The orchestrator's `cargo make test` after 2364ea3 fails in `cargo test` (failure 1): `cancel::tests::kill_group_signals_a_whole_group_and_never_ours` asserts the leader `/bin/sh -c "sleep 30 & echo $! > f; wait"` died by SIGTERM after `kill_group(leader, Terminate)`, but under load it exits normally with status 0 (`left: None`). `cancel.rs` is unchanged since 7619a28; this is a flake of the test, not of `kill_group`.

**Approach:** Root cause (evidence in Design Notes): `/bin/sh` is bash 3.2, which catches SIGTERM; when the group's SIGTERM reaches it while its `wait` builtin is handling the member's death (same signal), bash records the signal, returns from `wait` (status 0) and exits 0. `kill_group` delivered SIGTERM to every member every time. The test makes the leader `exec sleep 30` after recording the member's pid and waits — deterministically, via the leader's own `KERN_PROCARGS2` — until the exec happened, so the leader is a plain `sleep` (default SIGTERM disposition) when the group is signalled.

## Boundaries & Constraints

**Always:** The test still proves a whole-group kill: the leader dies by SIGTERM and the forked member dies too; the no-op calls (0, 1, `u32::MAX`) stay; every line of the changed test runs (coverage ratchet, `cancel.rs` at 100%).

**Never:** No change to `kill_group` or any non-test code; no sleep-as-sync, retry, relaxed assert or `#[ignore]`; no full `cargo make test` / `test-full` / `coverage` in this run (orchestrator rule — it reruns the gate itself).

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/cancel.rs:217-232` -- `kill_group`: `killpg(group, SIGTERM|SIGKILL)`, no-op for group ≤ 1. Read-only (no defect).
- `crates/zanshin-jj/src/cancel.rs:700-735` -- the flaky test: script (713), file poll (719-722), `kill_group` (728), status assert (730), member-death poll (731-734).
- `crates/zanshin-jj/src/cancel.rs:316-328` -- `split_procargs` (args, env) — reuse to read the leader's argv.
- `crates/zanshin-jj/src/cancel.rs:407` -- `process::procargs(pid)` (macOS) — the leader's `KERN_PROCARGS2` buffer.
- `crates/zanshin-jj/src/cancel.rs:737-749` -- `poll_until` test helper.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/cancel.rs` -- in `kill_group_signals_a_whole_group_and_never_ours`: script becomes `sleep 30 & echo $! > '<f>'; exec sleep 30`; replace the file poll with a `poll_until` on the leader's argv (`split_procargs(&procargs(leader))`.0 == `["sleep", "30"]`), one-line comment saying why (bash catches SIGTERM and can exit 0 when the member dies of the same signal); keep the member-pid read, `kill_group`, both asserts -- removes the bash race at its cause.

**Acceptance Criteria:**
- Given the fix, when the test runs 320 times (8 parallel lanes × 40) with the whole lib suite looping as load, then 0 fail (before: 156 / 320 failed).
- Given the fix, when `cargo test -p zanshin-jj --lib cancel::` runs, then all pass.
- Given the fix, when `cargo clippy -p zanshin-jj --all-targets -- -D warnings` and `cargo fmt --all --check` run, then both are clean.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 13 findings — high 0, medium 2, low 5, false 6, maybe-false 0 (verification-gap layer: no gaps)
- findings:
  - `[medium]` `[patch]` (blind) the member is never checked to have exec'd — a pre-exec bash fork of `sleep 30 &` inherits bash's SIGTERM handler and could survive, flaking the member-death poll; "no shell left in the group" unproven — the test now also polls the member's argv for `sleep 30` before `kill_group` (shared `execs_sleep` closure) (c36ba29).
  - `[low]` `[reject]` (blind) a timed-out poll or failed parse leaks the group (no drop guard) — the old test leaked the same way on any failed assert; only on an already-failing run, and the fix adds a guard type.
  - `[low]` `[patch]` (blind) the WHY comment says "bash" while the code spawns `/bin/sh`, and "after the `echo`" dangles — reworded: "`/bin/sh` (bash 3.2 on macOS) catches SIGTERM, so signal only once both group members have exec'd `sleep`; the exec follows the `echo`, so the pid file is complete." (c36ba29).
  - `[low]` `[patch]` (blind) the leader poll's message claims it checks the recorded pid — now "the leader execs `sleep`" (c36ba29).
  - `[false]` `[reject]` (blind) the argv match relies on bash passing bare `sleep` as argv[0] — every shell passes the command word as written as argv[0] (POSIX exec convention); the test is macOS-only with a fixed `/bin/sh`, and 640 loop runs matched.
  - `[false]` `[reject]` (blind) `leader_pid` vs `leader.id()` are two spellings of one pid — no named harm: `kill_group` takes the `u32` group id, the poll needs a `pid_t`; both name the same process.
  - `[low]` `[reject]` (blind) `kill_group`'s docs do not warn that a shell leader may exit 0 on SIGTERM — pre-existing; the only caller (`fix.rs` kill/wait) returns `Cancelled` and escalates to SIGKILL regardless of exit status, so no caller is wrong today; a doc note for a hypothetical caller.
  - `[medium]` `[patch]` (edge) member may still be a pre-exec fork when killpg runs — same root cause as the first row, same fix (c36ba29).
  - `[low]` `[patch]` (edge, claim) Design Notes' "no shell is left in the group" checked only for the leader — same root cause, now established by the member argv poll (c36ba29).
  - `[false]` `[reject]` (intent) the full gate / 100% coverage is not shown — by the orchestrator's instruction this run must not run the gate; every new test line is on its straight-line path (all ran in the passing runs).
  - `[false]` `[reject]` (intent) the test no longer exercises a SIGTERM-catching shell leader — `kill_group`'s contract is delivering the signal to the whole group, which the test still proves; what a catching leader does with it is the tool's (and `fix.rs` escalates to SIGKILL).
  - `[false]` `[reject]` (intent) the after count and `## Auto Run Result` / fix hash are missing — written at finalize below (after: 320/320 passed, twice; fix c36ba29).
  - `[false]` `[reject]` (intent) the member-death check passes for any exit, not a signal — pre-existing and unchanged; the member is `sleep 30`, polled ≤ 10 s, so only a signal ends it within the poll.

## Design Notes

Evidence (scratch harness mirroring the test: spawn as group leader, wait for the pid file, `killpg(SIGTERM)`, `wait`):
- `/bin/sh` = GNU bash 3.2.57 (`/private/var/select/sh -> /bin/bash`).
- Test under load (loop: 8 lanes × 40 + lib suite looping): 156/320 failed; a debug message showed `unix_wait_status(0)`, i.e. exit code 0, not 143 — the shell exited normally, so it had a SIGTERM handler (default disposition cannot exit 0).
- Script as in the test, kill at once: 53/200 exit 0; kill 300 ms later (shell surely in `wait`): 2/30 exit 0 — every time bash printed `Terminated: 15 sleep 30`, so the member did die.
- Member immune to the SIGTERM (`(trap '' TERM; exec sleep 2) & …; wait`): 200/200 leader died by SIGTERM — the race needs the member's death during `wait`.

So `kill_group` is correct; the test depended on bash's racy handling of a caught SIGTERM inside `wait`. After `exec sleep 30` no shell is left in the group; observing argv `sleep 30` on the leader's pid proves the exec happened (and the `echo` before it completed).

## Verification

**Commands:**
- `<scratchpad>/loop.sh <lib test binary> 40 8` -- expected: `pass: 320 fail: 0`
- `cargo test -p zanshin-jj --lib cancel::` -- expected: all passed
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean
- `cargo fmt --all --check` -- expected: clean

## Auto Run Result

Status: done

**Failures (from the orchestrator's `cargo make test` after 2364ea3):**
1. `cargo test` — `cancel::tests::kill_group_signals_a_whole_group_and_never_ours` (`left: None, right: Some(15)`) — FIXED by c36ba29 (pending the orchestrator's gate rerun, which this run must not start). Root cause: the TEST was racy, `kill_group` has no defect. `/bin/sh` is bash 3.2, which catches SIGTERM; when the group's SIGTERM reached it inside `wait` while it was handling the member's death (killed by the same signal), it returned from `wait` and exited 0 (wait status 0, not 143 — evidence in Design Notes; with a SIGTERM-immune member the leader died by SIGTERM 200/200). The member always died. Fix: the leader `exec sleep 30` after recording the member's pid, and the test polls both the leader's and the member's argv (`KERN_PROCARGS2`) until each is `sleep 30` before `kill_group`, so no shell is in the group when it is signalled. Deterministic sync on observable state; no sleep-as-sync, retry, relaxed assert or `#[ignore]`.

**Loop under load** (8 lanes × 40 runs of the test, lib suite looping in parallel): before 156 / 320 failed (and 38 / 80 in a debug run); after 0 / 320 failed — run three times (implementer twice, orchestrating run once on the final code).

**Files changed:** `crates/zanshin-jj/src/cancel.rs` (that test only: script, `execs_sleep` argv polls for leader and member, WHY comment), this spec.

**Review:** 13 findings — 5 rows patched in 3 entries (one medium root cause: the member's exec was not awaited — 3 rows; the WHY comment; the leader assert message), 0 deferred, 8 rejected with reasons in the triage log (2 low: failure-path leak, `kill_group` doc note; 6 false). Follow-up review: false (patched entries: 0 high, 1 medium, 2 low).

**Verification:** `cargo test -p zanshin-jj --lib cancel::` 9 passed; `cargo clippy -p zanshin-jj --all-targets -- -D warnings` clean; `cargo fmt --all --check` clean; loop 320/320 passed on the final code. Full `cargo make test` / coverage NOT run (orchestrator rule).

**Residual risk:** the gate's coverage step must confirm `cancel.rs` stays at 100% (every new test line is on the test's straight-line path and ran). The production `fix` cancel path is unaffected: it escalates to SIGKILL regardless of a tool's exit status.

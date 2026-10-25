---
title: 'Story 9.45 closing run: every call sees the Git directory `store/git_target` names now'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: 'e4501177b4166d74f9c617a5dee574dae966b8a1'
review_loop_iteration: 1
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      An open handle keeps the gix config snapshot its GitBackend took at load, so a terminal `git remote add` / `git config` beside it stays invisible until the handle reloads, while the CLI sees it on its next command.
    evidence: |-
      jj-lib 0.46.0 `git_backend.rs:346` opens a `gix::ThreadSafeRepository` once in `GitBackend::load`; `git_repo()` (:367) hands out thread-local copies of that snapshot. A `Repo` handle reloads its workspace only on a config-stack, per-command or (since this run) `store/git_target` change, never on a Git config edit. Pre-existing, not caused by this run.
    location: >-
      crates/zanshin-jj/src/repo.rs (refresh_settings reload rule); jj-lib git_backend.rs:346
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Story 9.45 deferred item 1: jj-lib's `GitBackend` resolves `.jj/repo/store/git_target` once at `Workspace::load`, and a `Repo` handle reloads its workspace only when the config-stack fingerprint or the per-command resolution changes (`Repo::refresh_settings`). After the default workspace's colocation is toggled — by Zanshin on another handle (`colocation::reload` replaces only the calling handle's workspace) or by `jj git colocation enable|disable` in a terminal — every other open handle on that repo (default or child workspace) keeps a backend on the moved-away Git directory, and its next call fails or reports the old layout. The CLI loads the workspace afresh for every command (Ralph 2026-10-23: behave like the CLI).

**Approach:** Record the raw bytes of `store/git_target` (absent for a non-Git backend) when the handle loads, and make `refresh_settings` — the shared start of every call — also reload when the bytes on disk differ.

## Boundaries & Constraints

**Always:** One reload rule in `Repo::refresh_settings`, the single point every call path passes (`start_command`, `remote_changes`, tests); the bytes are read before `loader.load` in `load_effective` (a change in between costs one redundant reload later, never a missed one — the fingerprint's convention). An unreadable `git_target` reads as absent (no new error path: if the file vanished the reload's own load reports it as today).

**Never:** No change to `colocation.rs`, the verbs, the FFI, schema or Dart; no polling, watcher or caching beyond this per-call compare; no new error code or warning.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Sibling default handle after enable | handles A, B on a non-colocated root; A enables | B's next `git_colocation_status` reports `colocated`, `git_repo_path` = `<root>/.git`; B's `git_colocation_disable` converts back | — |
| Sibling after disable | A disables (from the enabled state) | B reports not colocated, `git_repo_path` = `store/git` | — |
| Child handle after the default toggles | handle C at `ws2`, A (default) enables | C's status `git_repo_path` canonicalizes to `<root>/.git`; C's next mutation succeeds | — |
| External toggle (CLI-like) | `git_target` rewritten and Git dir moved on disk behind an open handle | next call follows the disk | — |
| Unchanged `git_target` | two calls in a row, nothing changed | no reload (same store `Arc`) | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/repo.rs` -- `struct Repo` (:203, add the field next to `stack_fingerprint` :207); `load_effective` (:260, read via `loader.repo_path().join("store").join("git_target")` before `loader.load`, :279); `refresh_settings` (:339, `reload` condition :353, add `|| read != self.git_target`); its rustdoc (:312-338) and the struct rustdoc (:195-197) name the reload triggers — extend them. Inline tests at :4850-4971 (`open_fixture()`, `only_a_command_scope_for_the_call_reloads_the_workspace` uses `Arc::ptr_eq` on `workspace.repo_loader().store()` as the no-reload witness).
- `crates/zanshin-jj/src/colocation.rs` -- `reload` (read-only: it replaces the calling handle's `Workspace` through `&mut Workspace`, so it cannot update `Repo`'s recorded bytes — the facades `git_colocation_enable/disable` (`repo.rs:2132`, `:2157`) must: if the store `Arc` changed across `with_verb` (the workspace WAS reloaded), re-record the bytes from disk; otherwise keep them. Without that, the toggling handle stays on its own pre-toggle bytes, and a sibling toggling BACK restores those bytes → the toggling handle never reloads and runs on a vanished Git dir).
- `crates/zanshin-jj/src/repo.rs` -- the three `&self` op-pinned reads skip `refresh_settings` entirely: `commit_contents` (:1269), `revset_counts` (:1302), `find_changes` (:1333) — they must also follow `git_target`. `reload_workspace` (:2017, `Workspace::load` with `self.settings`, replaces only `self.workspace`, leaving pending precondition/warnings untouched) is the reload they reuse; map its `MutateError` to their `Backend(String)` arms (`CommitContentError::Backend`, `Warned<RevsetSearchError::Backend>` with no warnings). Callers to update for `&mut self`: `crates/zanshin-ffi/src/{commit_contents,revset_search}.rs` (already `&mut RepoSession`), `crates/zanshin-ffi/tests/it/commit_contents_ffi.rs`, `crates/zanshin-ffi/benches/graph_topology.rs`, `crates/zanshin-jj/tests/it/{graph_topology,revset_search,commit_contents,when_commands,api_stability}.rs`, `crates/zanshin-jj/benches/revset_counts.rs`, `crates/zanshin-jj/src/{revset_search,warning,topology,commit_content}.rs` (inline tests/docs), `crates/zanshin-jj/README.md` if it shows a call.
- jj-lib 0.46.0 `git_backend.rs:330-345` -- `GitBackend::load` reads `store/git_target` (the bytes compared); `wc_ops.rs:361` `is_colocated_git_workspace` errors on a stale backend (why the sibling call fails today).
- `crates/zanshin-jj/tests/it/git_colocation.rs` -- fixtures `repo(colocate, commit)` (:54), `child(colocate)` (:81), `store`, `git_target`, `status_of`; add the sibling-handle witnesses here.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/repo.rs` -- field `git_target: Option<Vec<u8>>`, a small `fn read_git_target(repo_path: &Path) -> Option<Vec<u8>>`, read in `load_effective`, compared in `refresh_settings`; rustdoc updated (say "the Git directory" reaches the next call — not that the handle now loads like the CLI in every respect); inline test: a rewritten `git_target` bytes reloads (store `Arc` changes), unchanged bytes do not.
- `crates/zanshin-jj/src/repo.rs` -- a private `follow_git_target(&mut self) -> Result<(), MutateError>` (bytes differ → `reload_workspace()`, then record the new bytes); `commit_contents`, `revset_counts`, `find_changes` become `&mut self` and call it first (their docs: "the Git directory on disk now, Story 9.45 closing run"); update every caller listed in the Code Map.
- `crates/zanshin-jj/src/repo.rs` -- `git_colocation_enable/disable` re-record the bytes iff the store `Arc` changed across `with_verb` (see Code Map).
- `crates/zanshin-jj/tests/it/git_colocation.rs` -- witnesses for the matrix rows: sibling default handle after enable and after disable; the TOGGLING handle after a sibling toggles back (a enables, b disables → a's status not colocated, a commits); child handle after the default enables (status `colocated` + equals a fresh open at ws2; a commit on the child exported to the moved repo) and after the default disables; an on-disk toggle behind an open handle (the move done by another handle stands in for the CLI — same files changed); `commit_contents` / `revset_counts` / `find_changes` on a sibling handle after a toggle succeed (a commit created after the move is readable).

**Acceptance Criteria:**
- Given two open handles on one repo, when one toggles colocation, then the other's next call runs on the Git directory now on disk (no `jj.jj_lib_error`/backend error, status agrees with a fresh `Repo::open`).
- Given no change to `git_target`, when calls repeat, then no reload happens (existing no-reload tests stay green).

## Spec Change Log

### 2026-10-25 — review pass 1 (bad_spec)
- **Trigger:** edge-case-hunter: `commit_contents` / `revset_counts` / `find_changes` take `&self` and never pass `refresh_settings`, so a sibling handle's op-pinned graph read after a toggle still runs on the moved-away Git dir; blind-hunter: the toggling handle's recorded bytes stay pre-toggle, so after a sibling toggles back it never reloads.
- **Amended:** Code Map (the three reads, their callers, `reload_workspace`; the colocation facades' re-record rule), Tasks (follow_git_target + `&mut self` reads; facade re-record; witnesses for the toggle-back, child disable, the three reads; narrower doc wording).
- **Known-bad state avoided:** a handle whose recorded bytes equal the disk while its backend points elsewhere (silent stale backend); op-pinned reads failing with backend errors after a toggle.
- **KEEP:** pass 1's implementation (`/private/tmp/claude-502/-Users-ralph-bergmann-development-projects-privat-Zanshin/3de036ab-d604-49f9-950a-7472f6e9ecc9/scratchpad/closing-9-45-pass1-keep.diff`) is correct as far as it goes — the field, `read_git_target`, the read in `load_effective` before the load, the `refresh_settings` condition, the inline unit test, the four sibling tests; reapply it, then add the amendments. Wrap the `load_effective` doc paragraph evenly.

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 14 findings — high 0, medium 4, low 8, false 2, maybe-false 0
- findings:
  - `medium` `bad_spec` (blind-hunter) `Repo::git_target` goes stale after the handle's own toggle (`colocation::reload` replaces only the workspace) — verified worse than redundant: a enables (bytes stay `git`), b disables (disk back to `git`) → a sees equal bytes, never reloads, runs on the vanished `<root>/.git`; amendment: facades re-record iff the store `Arc` changed.
  - `low` `bad_spec` (blind-hunter) no test follows the toggling handle after a sibling toggles back — the witness for the row above; amendment adds it.
  - `low` `bad_spec` (blind-hunter) child coverage thin (no `colocated`/fresh-open compare, commit export unchecked, no default-disable counterpart) — amendment adds the asserts and the disable row.
  - `medium` `defer` (blind-hunter) the docs claim CLI-like loading but only `git_target` is watched; jj-lib's `GitBackend` keeps a gix config snapshot from load, so a terminal `git remote add`/`git config` beside an open handle stays invisible until a reload — pre-existing (not caused by this change); doc wording narrowed in the amendment; deferred, mirrored into deferred-work.md.
  - `low` `reject` (blind-hunter) reload-failure path (`git_target` naming a non-resolving path) untested — the failure is `load_effective`'s existing `Backend` error and the next call retries; unlikely in use, a test adds a fixture for a corrupt store only.
  - `low` `bad_spec` (blind-hunter) uneven wrap of the `load_effective` doc paragraph — KEEP note asks for an even wrap.
  - `medium` `bad_spec` (edge-case-hunter) `commit_contents`/`revset_counts`/`find_changes` skip the check — verified: `&self`, no `refresh_settings`; after a toggle their gix odb is rooted at the old path → objects written after the move are not found; amendment: `follow_git_target` + `&mut self`.
  - `medium` `bad_spec` (edge-case-hunter) toggling handle keeps old bytes → redundant reload — same root as the first row (worse than redundant, see there).
  - `low` `bad_spec` (edge-case-hunter, claim) "refresh_settings is the shared start of every call" is false for the three `&self` reads — same root as the `&self` row.
  - `low` `reject` (intent-alignment) a CLI-caused toggle is not exercised with the stock jj binary — the CLI toggle changes exactly the files a second handle's toggle changes (`git_target`, the moved Git dir, `core.bare`), and the parity harness compares one call per side with no handle held open across a CLI step.
  - `low` `reject` (intent-alignment) "(or the Git dir it names)" — a directory change with identical bytes is not detected — no toggle produces it; a hand-moved external repo breaks the CLI's load too (Design Notes).
  - `false` `reject` (intent-alignment) `colocation.rs` `reload` not touched — the item names it as a location, not as a required change; the amendment handles its effect in the facades.
  - `low` `bad_spec` (intent-alignment) child test checks only that the commit succeeds, not where it was exported — same root as the blind-hunter child row; the amendment asserts the export.
  - `false` `reject` (intent-alignment) no `## Auto Run Result` / commit hash — written at finalization.

### 2026-10-26 — Review pass
- verdicts: 23 findings — high 0, medium 0, low 15, false 8, maybe-false 0
- findings:
  - `low` `patch` (verification-gap) the reload-failure error path of the three op-pinned reads is untested (pre-verified) — `op_pinned_reads_report_a_git_target_that_no_longer_loads` added: broken `git_target`, malformed op id → each read returns `Backend` first, empty warnings.
  - `low` `reject` (verification-gap) `toggle_colocation` re-reads the bytes after the toggle's own load, so a concurrent toggle by another process inside that window is missed — needs a second toggle racing within one call; the fix threads bytes out of `colocation::reload`, more plumbing than the window is worth.
  - `low` `reject` (edge-case-hunter) same race as the row above — same reason.
  - `low` `patch` (edge-case-hunter) `reload_workspace` (remote verbs, `reload_after_config_write`) loads the current `git_target` without recording its bytes, so a sibling's toggle-and-back around such a verb leaves a stale backend — `reload_workspace` now reads the bytes before its load and records them (`follow_git_target` reuses it).
  - `low` `patch` (edge-case-hunter) `crates/zanshin-jj/README.md` still says `commit_contents` takes `&self` — now `&mut self`, with the reload sentence.
  - `low` `patch` (blind-hunter) the reads' reload failure read `jj-lib error: jj-lib error: …` (`MutateError::Backend`'s Display wrapped again) — `follow_git_target` now fails with the bare jj-lib reason (`load_workspace_again`); the new test asserts a single prefix.
  - `false` `reject` (blind-hunter) the reload now precedes id validation, breaking "every commit id is checked before any load" — that sentence is about commit loads, which still follow the id checks; the CLI too loads the workspace before it resolves any id.
  - `low` `patch` (blind-hunter) README stale — same root and fix as the edge-case README row.
  - `low` `reject` (blind-hunter) FFI rustdoc / `docs/ffi-abi.md` `jj.jj_lib_error` bullets do not name the reload — they describe load failures, and a workspace reload is one; no code, field or code-string changes.
  - `low` `reject` (blind-hunter) `toggle_colocation` records after the load — same race as the verification-gap row.
  - `false` `reject` (blind-hunter) a `git_target` change in `refresh_settings` runs a full `load_effective` with a second fix-up pass and resets pending state — the identical path a config change has always taken (its doc: "the reload's own fix-up is then a no-op"), and `start_command` resets the pending report and warnings right after the refresh anyway.
  - `low` `reject` (blind-hunter) the toggle's failure and no-op branches of the re-record are not asserted — both run in existing witnesses (`a_failure_after_the_move_still_reloads_the_handle`, `enable_on_a_colocated_workspace_converts_nothing`); asserting the private bytes adds a test-only accessor.
  - `low` `reject` (blind-hunter) op-pinned reads untested on a child handle and on the toggling handle after a toggle-back — the same `follow_git_target` path; the child's `repo_path` is the shared `.jj/repo` (child status witnesses prove it).
  - `low` `reject` (blind-hunter) the absent-bytes case (`None == None`) is untested — it runs in `a_non_git_backend_refuses_all_three` (local backend, no `git_target`); unreadable-file reload reports through the existing load error.
  - `false` `reject` (blind-hunter) the gix-config deferral is not mirrored into deferred-work.md — written at finalization, in the spec's commit.
  - `low` `reject` (blind-hunter) the two inline tests duplicate a body and `has_object` re-spawns git — cosmetic; each test names the entry point it pins.
  - `low` `reject` (intent-alignment) carried — no test runs the stock jj binary beside an open handle; pass-1 reason (same files changed, harness compares one call per side).
  - `low` `reject` (intent-alignment) FFI/Dart surfaces untested — the extern fns call the same `Repo` methods unchanged (`&mut RepoSession` already).
  - `low` `reject` (intent-alignment) carried — "(or the Git dir it names)" not detected beyond the bytes; pass-1 reason.
  - `false` `reject` (intent-alignment) carried — other load-time `GitBackend` state (gix config) stays cached; already deferred in pass 1, not deferred again.
  - `false` `reject` (intent-alignment) a double toggle between two calls restores the bytes and nothing reloads — the Git directory is then back at the very path the backend opened, so no read is stale.
  - `false` `reject` (intent-alignment) `&self` → `&mut self` and `toggle_colocation` as collateral — required by the item ("every call"), recorded in the spec.
  - `false` `reject` (intent-alignment) Auto Run Result / deferred-work mirror absent — written at finalization.

## Design Notes

Comparing the file's bytes, not the resolved path: every toggle (`git` ↔ `../../../.git`) rewrites them, the compare is one small read per call, and it never mis-fires the way comparing jj-lib's canonicalized path against gix's `path()` could. A Git directory moved without rewriting `git_target` (an external repo relocated by hand) breaks the CLI's load too; out of scope.

## Verification

**Commands (gate rule of this run — no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-jj --lib` -- expected: pass
- `cargo test -p zanshin-jj --test it -- git_colocation:: when_commands:: workspace_update_stale::` -- expected: pass
- `cargo test -p zanshin-jj --test it -- commit_contents:: revset_search:: graph_topology:: api_stability::` -- expected: pass
- `cargo test -p zanshin-ffi --lib` and `--test it -- git_ffi:: commit_contents_ffi:: revset_search` -- expected: pass (dependent)
- `cargo clippy -p zanshin-ffi --all-targets -- -D warnings` (benches compile) -- expected: clean
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean

**Results (2026-10-26, on the patched tree committed as 6c19d53; the full gate is the story loop's, not run here):**
- `cargo test -p zanshin-jj --lib` — 402 passed (incl. `a_rewritten_git_target_reloads_the_workspace`, `follow_git_target_reloads_only_on_changed_bytes`)
- `cargo test -p zanshin-jj --test it -- git_colocation:: when_commands:: workspace_update_stale:: commit_contents:: revset_search:: graph_topology:: api_stability:: git_remote` — 165 passed (the 8 new `git_colocation` witnesses included)
- `cargo test -p zanshin-ffi --lib` — 229 passed; `--test it -- git_ffi:: commit_contents_ffi:: revset_search` — 32 passed
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean (benches compile); `cargo fmt --all --check` — clean
- Matrix audit: every row has a passing witness — sibling after enable / after disable (`a_sibling_default_handle_follows_an_enable|_a_disable`), child (`a_child_handle_follows_the_default_workspace_enabling|_disabling`), on-disk toggle behind an open handle (`an_open_handle_writes_through_a_git_repo_moved_behind_it`, `op_pinned_reads_on_a_sibling_follow_a_toggle`), unchanged bytes (both inline tests). The implementer disabled each fix once: the toggle-back and op-pinned witnesses failed.
- Not run: the parity oracle (no jj verb's behavior on a single handle changed), `cargo make codegen` (no FFI/schema change), Dart checks (no Dart change), coverage (gate rule).

## Auto Run Result

Status: done

**Summary.** A `Repo` handle now records the bytes of `.jj/repo/store/git_target` it loaded with and follows the Git directory on disk at every call, like the CLI's per-command load: `refresh_settings` (the start of every `&mut` verb) reloads when the bytes differ; the op-pinned reads `commit_contents`, `revset_counts`, `find_changes` became `&mut self` and reload the workspace first (`follow_git_target`, a reload failure = their `Backend` arm with the bare jj-lib reason); `reload_workspace` and the handle's own `git_colocation_enable/disable` (`toggle_colocation`, iff the store `Arc` changed) re-record the bytes, so a sibling toggling back still reloads the toggling handle.

**Files changed (code commit 6c19d53d59ece51444f53787c497219367a28a5e):**
- `crates/zanshin-jj/src/repo.rs` -- `git_target` field, `read_git_target`, the reload rule, `follow_git_target`, `load_workspace_again`, `toggle_colocation`, `&mut self` reads, docs; two inline tests.
- `crates/zanshin-jj/tests/it/git_colocation.rs` -- 8 sibling-handle witnesses (default after enable/disable, toggle-back, child after enable/disable, write-through, op-pinned reads, broken `git_target`).
- `crates/zanshin-jj/tests/it/{api_stability,commit_contents,revset_search}.rs`, `benches/revset_counts.rs`, `README.md` -- `&mut self` callers and doc.

**Items:**
- 1 (a second open handle keeps a GitBackend on the old Git directory after a colocation toggle) -- fixed (6c19d53d59ece51444f53787c497219367a28a5e).

**Review:** pass 1 (14 findings: medium 4, low 8, false 2) looped back once as bad_spec (the three `&self` reads skipped the rule; the toggling handle's recorded bytes went stale — worse than redundant: after a sibling's toggle-back it never reloaded). Pass 2 (23 findings: low 15, false 8): patched 4 low entries — reload-failure witness, `reload_workspace` records the bytes, README, single `jj-lib error:` prefix. Deferred (new, mirrored into deferred-work.md "Surfaced in the closing run of Story 9.45"): the gix config snapshot an open handle keeps from load (terminal `git remote add`/`git config` beside it stays invisible) — medium, pre-existing. Rejected: the same-call concurrent-toggle race in `toggle_colocation` (needs a racing second toggle inside one call; fix would thread bytes out of `colocation.rs`), FFI doc bullets (a reload is a load), branch-level asserts already executed by existing witnesses, a stock-jj-binary witness (same files; the harness compares one call per side), "(or the Git dir it names)" beyond the bytes (no toggle produces it), cosmetic test duplication; false: validation order (commit loads still follow the id checks, CLI loads the workspace first), the full-reload path (same as a config change), double toggle (path valid again), collateral `&mut self`, finalization rows.

**Follow-up review recommended:** false — pass 2 is a loopback whose patches were all low (patched: 4 low, 0 medium, 0 high).

**Residual risks:** coverage of `repo.rs` is measured only by the story loop's final gate (the new lines all run in witnesses); the `&self` → `&mut self` change on three public reads is an API break inside the workspace (all callers updated).
</content>
</invoke>

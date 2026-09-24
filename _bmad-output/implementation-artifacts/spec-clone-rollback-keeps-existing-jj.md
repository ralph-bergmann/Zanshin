---
title: 'Clone rollback keeps a pre-existing .jj/ (data-loss fix)'
type: 'bugfix'
created: '2026-09-24'
status: 'done'
route: 'oneshot'
baseline_revision: 'b974695050c6b27be6e4561d5350241f697d3a35'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/project-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `Repo::clone` into a directory that already holds a jj workspace fails in `init_internal_git` (`DestinationExists`, jj-lib 0.44.0 `workspace.rs:121-129`). The rollback (`crates/zanshin-jj/src/repo.rs::roll_back_clone`, run from `clone_reported`'s `inspect_err`) then deletes that PRE-EXISTING `.jj/`: the user's op log and, for a non-colocated repo, its whole Git store. The jj CLI cannot do this, because `jj git clone` refuses a non-empty destination before writing anything. The bug was first surfaced by Story 3.4a (`deferred-work.md` "Clone rollback may delete a pre-existing `target/.jj` on failure") and again by Story 9.33 (spec frontmatter deferred item 1, and the `9-20` HANDED OVER note in `sprint-status.yaml`).

**Approach:** Minimal safety fix.
- Before creating anything, `clone_reported` records whether anything already exists at `<target>/.jj` (`symlink_metadata`, so a file or symlink counts too). On failure the rollback runs only when this call created `.jj/`; a pre-existing one is never touched.
- The refusal itself (`CloneFailed` carrying jj-lib's "already exists" text) is unchanged. Full non-empty-destination parity (refuse like the CLI, create the destination) stays Story 9.20's.
- Add a regression test: a clone into an existing jj workspace fails, reports no `jj.clone_cleanup_failed`, and the workspace still opens afterwards.
- Correct the docs that describe the old behaviour.
- Close the bookkeeping: `deferred-work.md` (the 3.4a entry and the 9.33 entry marked resolved; the end-to-end clean-up-witness entry reworded — its only fault-free trigger is gone), the `9-20` note in `sprint-status.yaml`, and a resolution line in `spec-9-33-creation-paths-report-identity-snapshot.md`'s Auto Run Result.

</frozen-after-approval>

## Implementation Notes

- **Reproduced first.** `tests/repo.rs::a_clone_into_an_existing_jj_workspace_fails_and_keeps_it` failed on the unfixed code: after the refused clone, `Repo::open` answered `NotARepo`, so the workspace's `.jj/` was gone. It passes with the fix.
- **Fix** (`crates/zanshin-jj/src/repo.rs::Repo::clone_reported`): `jj_preexisted = <target>/.jj.symlink_metadata().is_ok()` is taken after the target is canonicalized and the settings are resolved, before `clone_into`. The `inspect_err` rollback runs only when `!jj_preexisted`. `roll_back_clone` itself is unchanged; only its rustdoc changed.
- **Dropped test for a `.jj` regular FILE.** In that case `user_settings_for_new_workspace` already fails (`RepoError::Config`, ENOTDIR on `.jj/repo/config-id`) before `clone_into`, so no rollback ever ran. The file was never at risk and the test would not exercise the new guard.
- **Docs:** the rustdoc of `Repo::clone` and `roll_back_clone` in `crates/zanshin-jj/src/repo.rs`, and `zanshin_repo_clone` in `crates/zanshin-ffi/src/repo.rs` (+ codegen: `zanshin_ffi.h`, `bindings.dart`).
- **Bookkeeping:**
  - `deferred-work.md`: the 3.4a entry and the 9.33 data-loss entry are struck through as RESOLVED. The end-to-end `jj.clone_cleanup_failed` witness entry is reworded: its only fault-free trigger is gone, so a fault seam is needed.
  - `sprint-status.yaml`: the `9-20` handover note now says FIXED.
  - `spec-9-33-…`: the Auto Run Result gains a post-story resolution line. Its frontmatter `deferred` list is append-only and stays unchanged.
- **Review patches:**
  - The guard counts only `NotFound` as absent; an unreadable entry is treated as someone else's.
  - The regression test now checks a sentinel inside the existing `.jj/`.
  - New `a_clone_over_a_dangling_jj_symlink_fails_and_keeps_the_link` pins `symlink_metadata` over `exists()`.
  - `Repo::clone`'s `# Errors` names the refusal.
  - The resolved deferred-work entries are trimmed to their resolution.
  - The `9-20` / `9-33` sprint-status notes are updated.
- **Verification:**
  - `cargo make codegen` stable, and only the clone rustdoc lands in `zanshin_ffi.h` / `bindings.dart`.
  - `cargo make --allow-private` PASS: test-cargo (76 suites), test-clippy, test-fmt, test-dart-analyze/format, test-core (464 tests), test-core-analyze/format, all `test-shell*` / `test-settings*`, test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene and coverage.
  - The Rust steps and coverage were re-run after the review patches.
  - test-flutter fails only on the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card tests.
  - Coverage is 99.46% (13679/13753), with no baseline change and extern-coverage OK.
  - `pubspec.lock` drift was reverted.

## Review Triage Log

Blind Hunter (the one oneshot layer), 11 findings:

- `[low]` patch — `symlink_metadata().is_ok()` failed open on non-`NotFound` errors. Now `!matches!(…, Err(e) if e.kind() == NotFound)`. If `.jj` cannot be stat'ed, the rollback could not remove it either, so harm was nil; this is a direct correction.
- `[low]` reject — There is a race window between the stat and `init_internal_git` if another process creates `.jj/` in between. That needs a concurrent `jj init` into the same directory within microseconds. Closing it atomically means carrying `DestinationExists` through `clone_into` before `creation_error` stringifies it, which is more than a direct correction.
- `[low]` patch — The test's empty-warnings assertion also held on the unfixed code, and `Repo::open` only proves that some `.jj/` exists. A sentinel file inside the existing `.jj/` is now asserted unchanged, and the doc no longer overclaims.
- `[low]` patch — Nothing pinned `symlink_metadata` over `exists()`. Added the dangling-symlink test: init refuses with `DestinationExists`, and the link survives. `remove_dir_all` would delete the link itself.
- `[low]` patch — The comment claimed a `.jj` file is refused by the init. A non-directory already fails the config read; the comment now says so, and `Repo::clone`'s `# Errors` names the refusal. The FFI `# Errors` already covers it as `jj.jj_lib_error` "clone failed; detail in context".
- `[low]` defer — There is no typed refusal for a clone into an existing workspace (a generic `CloneFailed`), and no FFI-level test of the contract. The typed code belongs with Story 9.20's non-empty-destination refusal (deferred-work + the `9-20` note). The FFI maps the Rust outcome unchanged, and `creation_envelope` is witnessed (9.33).
- `[low]` defer — The conversions' rollback deletes a dangling `.jj` symlink, because `detect_repo` follows the link and init then refuses. This is pre-existing and only a broken link is lost (deferred-work).
- `[low]` patch — The resolved deferred-work entries kept their pre-fix text. Both are now trimmed to the resolution plus their origin.
- `[low]` patch — Two sprint-status spots were stale: the `9-20` note's "witness once the rollback is fixed" and the `9-33` DEFERRED list. Both are updated (fault seam; FIXED marker).
- `[low]` patch — The spec had no gate record. The review ran before finalization; the gate run is now recorded above, and coverage raised no baseline. The in-progress status is by design until finalize.
- `[low]` patch — The `Repo::clone` rustdoc line was over the width limit. It is rewrapped.


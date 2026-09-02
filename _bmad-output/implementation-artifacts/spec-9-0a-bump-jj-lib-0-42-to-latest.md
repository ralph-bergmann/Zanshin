---
title: 'Story 9.0a: Bump jj-lib 0.42.0 → 0.44.0 (precursor)'
type: 'chore'
created: '2026-09-02'
status: 'done'
baseline_revision: '6c815e81e53c8caf457ad9a1afbe02e444db248d'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      The CLI-at-tag config mirror was not re-synced to v0.44.0, so the new
      `builtin_log()` alias does not exist in Zanshin.
    evidence: |-
      `BUILTIN_CONFIG_TOML` is documented as "verbatim from cli/src/config/revsets.toml
      at v0.42.0". At v0.44.0 that file sets `log = "builtin_log()"` and adds the alias
      `'builtin_log()' = '...'`. Zanshin still carries the expanded literal, so the
      denoted default set is identical (no wrong output today), but a user who overrides
      `builtin_log()` — the 0.44-supported customization point — is honoured by jj and
      silently ignored by Zanshin. Out of scope here: the intent scoped the lockstep bump
      to the two named prose docs, and this is a config mirror, not an API-diff absorb.
    location: >-
      crates/zanshin-jj/src/config.rs:59,74-105
    severity: medium
  - summary: >-
      `abandon()` does not guard immutable descendants the way the jj CLI does.
    evidence: |-
      jj 0.44 added a leading `immutable` argument to `rebase_descendants_with_options`;
      we pass `RevsetExpression::none()`, which is exactly what jj-lib's own
      `rebase_descendants()` passes, so this faithfully preserves pre-0.44 behaviour and
      is correct for a pin bump. But the CLI resolves the real immutable set
      (`cli_util::rebase_mutable_descendants`), so abandoning a commit with immutable
      descendants rewrites them where jj would refuse. This is a pre-existing CLI-parity
      gap surfaced by the new parameter, not introduced by it. Story 9.1 re-ports exactly
      this `check_rewritable` / immutable-heads guard.
    location: >-
      crates/zanshin-jj/src/mutate.rs:379-390
    severity: medium
  - summary: >-
      Roughly two dozen in-code `@ v0.42.0` provenance citations still point at the
      superseded tag.
    evidence: |-
      CLAUDE.md's own rule is to bump the reference tag in lockstep when the jj-lib pin
      moves. The two prose docs were bumped, but code-comment citations were not, e.g.
      crates/zanshin-jj/src/{revset.rs:19,82, graph.rs:5,27,61,111,142, config.rs:6,36,59,108,
      convert.rs:31,176,203,233, op_log.rs:120, commit_meta.rs:9, remotes.rs:244} plus
      docs/ffi-abi.md and docs/rust-error-codes.md. Each is a prior-art anchor that now
      names a tag that is no longer the pin.
    severity: low
  - summary: >-
      Test oracles duplicate the same `Workspace::load` + settings boilerplate about
      twenty times across ten files.
    evidence: |-
      This pin bump had to touch every one of those call sites purely to swap the factory
      constructor. A shared `test_helpers` oracle-workspace helper would make the next
      bump a one-line change; `test-helpers`' `make_test_settings` is private, which is
      why tests/convert.rs copies the settings TOML literal again.
    severity: low
  - summary: >-
      Nothing enforces that the documented jj-lib version matches the workspace pin.
    evidence: |-
      project-context.md claimed `jj-lib =0.41.0` while the workspace actually pinned
      =0.42.0 — two releases stale, and nothing surfaced it until this story. With no CI,
      a check in `cargo make test` asserting the documented version equals the pin would
      prevent the recurrence.
    severity: low
  - summary: >-
      The zanshin-jj README still asserts a product limitation pinned to jj 0.42.
    evidence: |-
      crates/zanshin-jj/README.md states "In-place jj-native conversion is impossible in
      jj 0.42". The bump neither re-verified that claim against 0.44 nor re-worded it.
    location: >-
      crates/zanshin-jj/README.md:75-78
    severity: low
---

<intent-contract>

## Intent

**Problem:** The workspace pins `jj-lib =0.42.0`; upstream is at `0.44.0`. Epic 9 builds the whole jj operation surface against jj-lib, so every operation story would be written against a stale API and the `../jj` CLI prior-art would be read at the wrong tag.

**Approach:** Bump `jj-lib` to `=0.44.0` and the pins that track it (`gix` 0.84.0 → 0.85.0; re-verify the exact `chrono` pin), absorb the resulting API diff inside `zanshin-jj` module bodies (plus its tests/bench, `test-helpers`, `xtask`), and move the `../jj` reference-tag mentions in `CLAUDE.md` / `project-context.md` in lockstep. Behavior stays identical; only the pin moves.

## Boundaries & Constraints

**Always:**
- `zanshin-jj`'s **public surface stays stable** — absorb the diff inside module bodies (anti-corruption layer, FR-JJ-16).
- Behavior-preserving: where 0.44 adds a parameter, pass the value that reproduces 0.42 behavior (jj's own default), with a `// WHY:` comment.
- The full gate is the definition of done: `cargo make test` green, including clippy pedantic `-D warnings`, rustfmt, `cargo deny`, and the coverage ratchet.
- Commit on `main` with `--no-gpg-sign`; never edit git config.

**Block If:**
- An API change cannot be absorbed inside `zanshin-jj` without changing its public surface (or an `extern "C"` signature), i.e. the bump would force feature work.
- `cargo deny` reports an advisory/ban in the new dependency graph that cannot be resolved by the bump itself.
- The coverage ratchet regresses and the drop is not recoverable by adding a test for code this story actually touched.

**Never:**
- Do not thread the new `object_hash` parameter through `Repo::init`/`Repo::clone`'s public API, FFI, or Dart — that is Story 9.20 (`git init`/`git clone`) work, not a pin bump. Mirror jj's own default instead.
- Do not add features, refactor adjacent code, or rewrite *historical* doc references (Story-3.5 rationale, the "jj-0.42 feasibility map" artifact name, dated changelog lines). Only the **operative** reference-tag instructions and the jj-lib pin statement move.
- Do not lower `coverage-baseline.txt` or add an `exclude_prefix` to pass the gate.

</intent-contract>

## Code Map

Nine breaking changes, all verified against the vendored `jj-lib-0.42.0` source and `v0.44.0` in `../jj`.

- `Cargo.toml` -- L33 `jj-lib =0.42.0`→`=0.44.0`; L38 `gix` 0.84.0→0.85.0 (its `# WHY:` comment cites `gix::remote::fetch::Tags` for `add_remote`, which goes stale — restate as `gix::Repository`/`Direction` in `remotes.rs` + `gix::hash::Kind` in `repo.rs`); L29 re-verify the exact `chrono` pin (locked 0.4.45; jj 0.44 wants `^0.4.44`).
- `crates/zanshin-jj/src/repo.rs` -- 4 breaks. L470 `git::add_remote` lost its trailing `fetch_tags` arg (5→4). L521 `GitFetch::fetch` lost `fetch_tags_override` (5→4; `git::FetchTagsOverride` deleted). L536 `GitImportStats.changed_remote_bookmarks` is now `Vec<GitImportRefUpdate>` (fields `symbol`/`old_remote_ref`/`new_target`) instead of tuple pairs. L416+L457 `Workspace::init_internal_git` gained `object_hash: gix::hash::Kind`. Also L398/480/576 `StoreFactories::default()`.
- `crates/zanshin-jj/src/revset.rs` -- L149 `RevsetParseContext` lost `use_glob_by_default` (field removed upstream; delete the line).
- `crates/zanshin-jj/src/commit_meta.rs` -- L199 `RevsetContainingFn` is now async (returns `LocalBoxFuture`); the consumer call needs `pollster::block_on(...)`. The `Box<RevsetContainingFn<'a>>` annotations at L118/L130 and the producer at `graph.rs:196` need no textual edit.
- `crates/zanshin-jj/src/mutate.rs` -- L378 `MutableRepo::rebase_descendants_with_options` gained a leading `immutable: &Arc<ResolvedRevsetExpression>` param. Plain `rebase_descendants()` (L209/260/267/307) is unchanged.
- **`StoreFactories::default()` removed → `jj_lib::default_backend_factories::default_backend_factories()`**, and `default_working_copy_factories`/`default_working_copy_factory` moved from `jj_lib::workspace` to that same new module. Sites: `crates/zanshin-jj/src/repo.rs`, `crates/test-helpers/src/lib.rs` (L123, L344, import L17), `crates/zanshin-jj/benches/graph_blueprint.rs` (L34/L87), and `crates/zanshin-jj/tests/{concurrent_writes,revset,change,remotes,bookmarks,status,remotes_write,mutate,op_log}.rs`.
- `crates/zanshin-jj/tests/remotes.rs` (L70), `tests/remotes_write.rs` (L176) -- the `add_remote` arity fix; `remotes_write.rs` oracles may shift because 0.44 makes fetched tags tracked remote refs.
- `crates/xtask/src/tasks/gen_fixture.rs` -- L78 `init_internal_git` arity; `crates/xtask/Cargo.toml` has **no `gix` dep** — add one only if `gix::hash::Kind` is not reachable via a `jj_lib` re-export.
- `crates/zanshin-jj/src/remotes.rs` -- L232 `GitFetch::fetch` arity; direct `gix` usage (L13/57/61) is unaffected by gix 0.85.
- `CLAUDE.md` L28-29 -- operative reference tag `v0.42.0`→`v0.44.0` and the quoted `jj-lib =0.42.0` pin.
- `_bmad-output/project-context.md` -- L36 stale `jj-lib =0.41.0`→`=0.44.0`; L727 `git show v0.42.0:` example→`v0.44.0`; L730 vendored path `jj-lib-0.42.0`→`jj-lib-0.44.0`. Leave L231/L724/L743 (historical).
- `coverage-baseline.txt` -- ratchet baseline; commit any auto-raise with the code.

## Tasks & Acceptance

**Execution:**
- `Cargo.toml` -- bump `jj-lib`/`gix`, re-verify the `chrono` exact pin against what cargo resolves, refresh the stale `gix` `# WHY:` comment -- the pin bump is the story.
- `crates/zanshin-jj/src/{repo,revset,commit_meta,mutate,remotes}.rs` -- apply the absorbs listed in the Code Map, behavior-preserving -- keeps the public surface stable per FR-JJ-16.
- `crates/test-helpers/src/lib.rs`, `crates/xtask/src/tasks/gen_fixture.rs` (+ `crates/xtask/Cargo.toml` if needed) -- factory-module moves and `init_internal_git` arity -- the non-production jj-lib consumers must compile too.
- `crates/zanshin-jj/tests/*.rs`, `crates/zanshin-jj/benches/graph_blueprint.rs` -- factory/arity updates; re-verify any oracle that fetched tags touch -- the gate runs them.
- `CLAUDE.md`, `_bmad-output/project-context.md` -- move the operative reference-tag + pin statements only -- prior-art must be read at the pinned tag.
- `coverage-baseline.txt` -- commit the ratchet's auto-raise if it rises -- baseline travels with the code that earned it.

**Acceptance Criteria:**
- Given the bumped workspace, when `cargo make test` runs, then it passes end to end — tests, clippy pedantic with `-D warnings`, rustfmt, `cargo deny`, and the coverage ratchet — with no baseline lowered and no `exclude_prefix` added.
- Given `Cargo.lock` after the bump, when the resolved versions are inspected, then `jj-lib` is `0.44.0` and `gix` is `0.85.0`, and the `chrono` exact pin matches what jj-lib 0.44 transitively resolves to.
- Given `zanshin-jj`'s public API, when compared against the pre-bump surface, then it is unchanged — every absorb sits inside a module body, and `crates/zanshin-jj/tests/api_stability.rs` still passes untouched.
- Given no `extern "C"` signature changed, when the FFI surface is checked, then `zanshin_ffi.h` and `bindings.dart` need no regeneration; if any signature did change, then `cargo make codegen` was run and both generated files are committed in the same change.
- Given a repository initialized through `Repo::init`, when its Git object hash is inspected, then it is SHA-1, identical to pre-bump behavior.
- Given `CLAUDE.md` and `project-context.md`, when their operative jj reference-tag instructions are read, then they name `v0.44.0` and the `jj-lib =0.44.0` pin, while dated/historical mentions are left intact.

## Spec Change Log

## Review Triage Log

### 2026-09-02 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 5: (high 1, medium 0, low 4)
- defer: 6: (high 0, medium 2, low 4)
- reject: 7: (high 0, medium 0, low 7)
- addressed_findings:
  - `[high]` `[patch]` Deleting `use_glob_by_default: false` was NOT behavior-preserving, and the commit message's justification was inverted. Verified in both crate sources: jj-lib 0.42 `revset.rs:1252` mapped `false` → `"substring"`, while 0.44 `revset.rs:1254-1257` unconditionally calls `StringPattern::glob(value)`, which `str_util.rs:141-146` degrades to `exact` when the value holds no glob metacharacter. So every bare/quoted pattern argument (`description`, `author`, `bookmarks`, `tags`, `files`, …) flipped from substring to exact matching on a user-typed, FFI-exposed surface, with no comment and no test. Fixed by documenting both user-visible revset-language deltas (this one plus 0.44 dropping Git-like `refs/heads/*` symbol resolution) at the site in `parse_revset_with`, and adding a regression test pinning bare-argument-is-exact while explicit `substring:` still matches. Triaged `patch` rather than `bad_spec` deliberately: the code change is forced by upstream and is correct — re-deriving it from an amended spec would reproduce identical code, so the only real gap was documentation plus verification, which is additive.
  - `[low]` `[patch]` `tests/graph.rs` oracle caveat was inverted by this bump — it still warned that the local jj binary was 0.44.0 "not the pinned 0.42.0". Re-anchored to state the oracle now matches the pin, keeping the old cross-version argument as history.
  - `[low]` `[patch]` `Cargo.toml` gix `# WHY:` named only `remotes.rs`/`repo.rs`, but this same change made `crates/xtask` a third consumer. Added.
  - `[low]` `[patch]` `Cargo.toml` chrono `# WHY:` claimed the pin tracked "jj-lib's exact transitive version" while jj-lib 0.44 declares a caret `^0.4.44`. Reworded to state the real relationship, since re-verifying this pin was explicitly in the story's scope.
  - `[low]` `[patch]` Both `GitFetch::fetch` call sites dropped one of two consecutive `None`s; removing the wrong one would have silently changed `depth` with no compile error. Made the surviving argument self-evident via a named `depth` local plus a note.

## Design Notes

**`object_hash` is deliberately hardcoded, not threaded through.** `Workspace::init_internal_git` gained `object_hash: gix::hash::Kind` in 0.44. FR-JJ-17 ("pass CLI parameters through") would argue for exposing it — but jj's CLI applies it as a *config-driven default* (`git.object-hash`, default `"sha1"`), which FR-JJ-17's own carve-out permits mirroring, and the user-facing `git init`/`git clone` parameter surface is Story 9.20's scope. Passing `gix::hash::Kind::Sha1` reproduces 0.42 behavior exactly. Add a `// WHY:` comment pointing at 9.20 so the deferral is visible at the call site.

**Async `RevsetContainingFn`.** The consumer fix mirrors the existing `commit.is_empty(repo_dyn)` pattern five lines below the break in `commit_meta.rs` — wrap in `pollster::block_on`, keep the surrounding `.map_err(jj)?`. `pollster` is already a workspace dependency.

**`rebase_descendants_with_options`.** Pass `&RevsetExpression::none()` as the new `immutable` argument — this is exactly what jj's own `rebase_descendants()` passes internally, so 0.42 semantics are preserved rather than newly constrained.

## Verification

**Commands:**
- `cargo make test` -- expected: green end to end (tests + clippy `-D warnings` + rustfmt + `cargo deny` + coverage ratchet). This is the single gate.
- `grep -A1 '^name = "jj-lib"$' Cargo.lock` -- expected: `version = "0.44.0"`; same check for `gix` → `0.85.0`.
- `git status --porcelain` -- expected: after the run, no unintended files; `coverage-baseline.txt` appears only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff `crates/zanshin-jj/src/lib.rs` and the crate's `pub` items: confirm no public signature moved (the anti-corruption boundary held).

## Auto Run Result

Status: done
Commits: `7846914` (the bump) and `5a792b4` (review follow-up), both on `main`, baseline `6c815e8`.

**Summary.** `jj-lib` moved `=0.42.0` → `=0.44.0` and `gix` `0.84.0` → `0.85.0`; `chrono` stays `=0.4.45` (jj-lib 0.44 declares caret `^0.4.44`, and 0.4.45 is what cargo resolves). Nine breaking API changes were absorbed inside `zanshin-jj` module bodies — the crate's public surface is unchanged, `tests/api_stability.rs` passes untouched, and no `extern "C"` signature moved, so `zanshin_ffi.h` / `bindings.dart` needed no regeneration. Two items the plan did not predict surfaced during execution: jj 0.44 removed the `git_head()` / `git_refs()` *revset* functions (only test oracles used them; they now read the `View` directly, which is strictly tighter than upstream's suggested `first_parent(@)` approximation), and `cargo deny` flagged a yanked `chacha20 0.10.0` pulled in transitively, resolved by the bump itself to 0.10.2.

**Files changed.**
- `Cargo.toml` — the pins, plus corrected `# WHY:` comments for `chrono` (caret-resolved, not an upstream exact pin) and `gix` (now also consumed by `xtask`).
- `Cargo.lock` — resolved graph, including `chacha20` 0.10.0 → 0.10.2.
- `crates/zanshin-jj/src/repo.rs` — backend-factory move, `init_internal_git`'s new `object_hash`, `add_remote` arity, `GitFetch::fetch` arity, `GitImportRefUpdate` shape.
- `crates/zanshin-jj/src/revset.rs` — dropped the removed `use_glob_by_default` field and documented the two user-visible revset-language deltas it implies.
- `crates/zanshin-jj/src/commit_meta.rs` — async `RevsetContainingFn` driven with `pollster`.
- `crates/zanshin-jj/src/mutate.rs` — `rebase_descendants_with_options`'s new leading `immutable` argument.
- `crates/zanshin-jj/src/remotes.rs` — `GitFetch::fetch` arity, surviving argument named `depth`.
- `crates/test-helpers/src/lib.rs`, `crates/xtask/{Cargo.toml,src/tasks/gen_fixture.rs}`, `crates/zanshin-jj/benches/graph_blueprint.rs` — factory-module move; `xtask` gained a `gix` dep for `gix::hash::Kind`.
- `crates/zanshin-jj/tests/*.rs` — factory/arity updates, `git_head`/`git_refs` oracles moved to direct `View` reads, and the new `revset_bare_pattern_arg_is_exact_not_substring` regression test.
- `CLAUDE.md`, `_bmad-output/project-context.md` — operative `../jj` reference tag → `v0.44.0` and the jj-lib pin statement (the latter was additionally stale at `=0.41.0`).

**Review findings.** 5 patched (1 high, 4 low), 6 deferred (2 medium, 4 low — see frontmatter `deferred`), 7 rejected as noise. The high-severity patch: deleting `use_glob_by_default: false` was not behavior-preserving and the original commit message's rationale was inverted — bare pattern arguments to revset functions flipped from substring to glob-i.e.-exact matching on a user-typed, FFI-exposed surface. Verified in both vendored crates, then documented at the site and pinned by a regression test; the new behavior is kept because it is what the jj CLI (the project's semantic reference) has always done. Note for future readers: this spec's Code Map mischaracterized that removal as a mechanical "delete the line", which is what let the mischaracterization through to the first commit.

**Follow-up review recommended:** true. Patched this pass: high 1, medium 0, low 4 → score `3×0 + 1×4 = 4`, below the threshold of 5, but the presence of a high-severity patched finding sets the flag regardless.

**Verification performed.** `cargo make test` run to completion twice by the orchestrator (once after the bump, once after the patches), both with the exit code captured unpiped: `GATE_EXIT:0`. That gate covers `cargo test --workspace`, clippy pedantic `-D warnings`, rustfmt, `flutter test` + `dart analyze`/`format`, `cargo deny` (log shows `advisories ok, bans ok`), and the coverage ratchet (`coverage-check: OK — coverage held at 99.00% (4942/4992 lines)`, `coverage-baseline.txt` untouched, no `exclude_prefix` added). The new regression test was confirmed present in the run output rather than assumed. `Cargo.lock` inspected directly: `jj-lib 0.44.0`, `gix 0.85.0`, `chrono 0.4.45`. No public item changed in `crates/zanshin-jj/src` per a `pub`-signature diff of the change.

**Residual risks.**
- Behavioral, not compile-visible: jj 0.44 fetches tags as tracked `<name>@<remote>` refs and no longer honours Git's `tagOpt`, so the first real fetch against a tag-bearing repo re-fetches tags to initialize tracking state, and cloned repos no longer carry `remote.origin.tagOpt`. Our refspecs already glob `*`, so selection is unchanged.
- `CopyRecords::add_records` now de-duplicates identical records across merge parents, so a rename may be reported in a merge commit where 0.42 dropped it.
- The revset string-pattern flip is now documented and tested, but any user-saved revset relying on substring semantics changes meaning; likewise Git-like symbols (`refs/heads/main`) no longer resolve.
- `object_hash` is hardcoded to SHA-1 (jj's own default, reproducing prior behavior). Exposing it is Story 9.20's scope; a SHA-256 remote is consequently not supported yet.

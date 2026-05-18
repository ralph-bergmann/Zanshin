# Story 1.6: Add `cargo-deny` advisories + bans (security backstop)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer who needs a CI-cheap security backstop against published RUSTSEC advisories and accidentally-banned dependency patterns**,
I want **a workspace-root `deny.toml` containing only the `[advisories]` and `[bans]` tables (modern cargo-deny v2 schema; NO `[licenses]`, NO `[sources]`) plus a documented ignore-list workflow for advisory churn**,
so that **`cargo make test`'s `cargo deny --workspace check advisories bans` step (Story 1.4) stops running on cargo-deny's built-in defaults with a "no config" warning, every new RUSTSEC advisory on a transitive dep becomes a deliberate triage instead of a silent CI red, the deferred-work entry from Story 1.4 (`deferred-work.md` § "Deferred from: code review of 1-4-..." — "cargo-deny advisory DB auto-download + advisory churn fragility") is absorbed, and the project's no-GPL/AGPL/LGPL/SSPL discipline (`prd.md` § 5.4, `project-context.md` § "Critical Don't-Miss Rules") gains its mechanical baseline ahead of the release-phase license-gate**.

## Acceptance Criteria

**Note on WIP scope (`epics.md` § Story 1.6 WIP-rework note, line 789):** The original epics.md Story 1.6 mandated a **full** license-gate (`[licenses]` allow-list + transitive-GPL test + `pana` integration for Dart). The WIP-rework explicitly **drops** all of that — keep only `cargo deny check advisories bans` as the security backstop. License compliance returns in the release phase (`prd.md` § 5.4 "Enforcement (WIP)", `project-context.md` § "License compliance (WIP-scope)"). Therefore the AC below configures **only** `[advisories]` and `[bans]` tables; `[licenses]` and `[sources]` are explicitly excluded. **The original epics.md AC bullets that prescribed `[licenses]` keys, `pana` activation, and the hypothetical-GPL-dep failure test are SUPERSEDED by the WIP-rework and are NOT carried into this story** — see Dev Notes § "What this story is NOT" for the line-by-line crosswalk.

**Note on cargo-deny v2 schema (`cargo-deny 0.19.6`, system-installed):** The original epics.md AC specified deprecated keys for the `[advisories]` table — `vulnerability = "deny"`, `notice = "warn"`, `unsound` as a level. These have been **removed** in cargo-deny v2 (current stable; verified at story-write time via `embarkstudios.github.io/cargo-deny/checks/advisories/cfg.html`):
- `vulnerability` — REMOVED, all vulnerability advisories now emit errors unconditionally.
- `unsound` — REMOVED as a level; now a filter-spec (`workspace`/`all`/`none`).
- `notice` — REMOVED, all notice advisories now emit errors unconditionally.
- `severity-threshold` — REMOVED.

The AC below uses the **current v2 schema**. Writing the deny.toml with the deprecated keys will hard-fail with a cargo-deny error message and waste a review cycle.

1. **AC-1 — `deny.toml` exists at the workspace root with the modern v2 schema.** A new file at `/Users/ralph.bergmann/development/projects/privat/Zanshin/deny.toml` is created. Required structure:
   - **NO `[licenses]` table.** Explicitly omitted per WIP-rework; the full license-gate is deferred to the release phase.
   - **NO `[sources]` table.** Explicitly omitted; the WIP-rework drops source-list maintenance entirely (no `unknown-registry`, no `unknown-git`, no `allow-registry` configuration).
   - `[graph]` table (optional but recommended) sets `targets` empty (default — all targets) and `all-features = false`. WHY: scoping to "all features" would expand the dep graph beyond what `cargo build --release` actually links; we check what we ship.
   - `[advisories]` table per AC-2.
   - `[bans]` table per AC-3.
   - **No `[output]` table.** Default human output suffices for both local runs and CI (`-f json` is opt-in per invocation, never via config).
   - File MUST start with an SPDX line per `project-context.md` § Documentation. **NOTE — TOML files use `#` for comments, not `//`.** Use exactly: `# SPDX-License-Identifier: Apache-2.0` on line 1. (See Dev Notes § "SPDX on TOML config files" for the precedent set in Story 1.3's `rust-toolchain.toml` and Story 1.4's `Makefile.toml` — same comment-prefix rule.)
   - Total file size after AC-1..AC-3: targeted at **30–60 lines** including comments. A larger file usually means license-list maintenance crept in — reject in review.

2. **AC-2 — `[advisories]` table uses the cargo-deny v2 schema.** Required keys (verbatim — match key names and value types; values are intentional and documented inline in the file):
   ```toml
   [advisories]
   # Default RustSec advisory database — official upstream.
   db-urls = ["https://github.com/rustsec/advisory-db"]
   # Yanked crate versions are a CI red. Yanked = withdrawn from crates.io by
   # the author; usually for a security or correctness reason. Treat as deny.
   yanked = "deny"
   # Unmaintained is "warn" not "deny" because (a) "unmaintained" is a
   # judgment call by the advisory authors and false-positives are common,
   # and (b) we want a signal in CI output without blocking merges on it.
   # Re-evaluate in release phase.
   unmaintained = "workspace"
   # `ignore = []` starts empty. Populated case-by-case when a published
   # RUSTSEC advisory fires on a transitive dep we cannot immediately
   # upgrade away from. Every entry MUST have a `reason = "..."` field and
   # a tracking issue or PR link in the comment above it. See README §
   # "cargo-deny advisory churn workflow" for the operating procedure.
   ignore = []
   # Warn when an ignore entry stops matching a real advisory (e.g., the
   # advisory got withdrawn or the dep was upgraded away). Without this,
   # stale ignores accumulate silently.
   unused-ignored-advisory = "warn"
   ```
   - **Do NOT add `vulnerability = "deny"`** — removed in cargo-deny v2. All vulnerability advisories emit errors unconditionally; the key is rejected and aborts the run.
   - **Do NOT add `notice = "warn"`** — removed in cargo-deny v2. Same rejection behaviour.
   - **Do NOT add `severity-threshold = ...`** — removed in cargo-deny v2.
   - **Do NOT add `db-path = "..."`**. Default cache location (`~/.cargo/advisory-dbs`) is fine; pinning a custom path would gratuitously diverge developer machines from CI cache.
   - **Do NOT add `git-fetch-with-cli = true`** unless the default gix-based fetch fails in a real environment. Empirically the default works in macOS-only WIP; adding the flag preemptively is hypothetical-future scaffolding (per `project-context.md` § "Don't design for hypothetical future requirements").
   - **Do NOT add `maximum-db-staleness`**. The default (90 days) is conservative; tightening it would create CI failures from cold runners (no network during isolated CI step) for no security benefit while WIP. Revisit in release phase if CI staleness becomes a real issue.

3. **AC-3 — `[bans]` table uses the cargo-deny v2 schema.** Required keys (verbatim):
   ```toml
   [bans]
   # Two versions of the same crate in the dependency graph is a code-smell
   # (slower builds, larger binary, weird version-resolution surprises),
   # but not a merge-blocker in WIP. Warn surfaces the signal without
   # blocking the AC of mainly-stable upstreams.
   multiple-versions = "warn"
   # Wildcard version requirements (`crate = "*"`) bypass the project's
   # exact-pin discipline for pre-1.0 deps (`project-context.md` §
   # "Version pinning rules"). Deny so a wildcard is a hard CI fail.
   wildcards = "deny"
   # Empty deny list at this stage. Specific bans are added later if
   # they're load-bearing — currently none are needed; the GPL/AGPL/LGPL/
   # SSPL no-go list is documented (project-context.md § Critical
   # Don't-Miss Rules) but NOT mechanically enforced in WIP — that
   # returns with the release-phase license-gate.
   deny = []
   # Empty skip list. Populated case-by-case when `multiple-versions = "warn"`
   # surfaces a known-acceptable duplicate (e.g., two versions of `syn`
   # during a major-version transition). Every entry needs a comment
   # above it naming the duplicate and the rationale.
   skip = []
   ```
   - **Do NOT populate `deny = [...]` with placeholder anti-GPL bans.** The license-gate is deferred to the release phase; mechanical license enforcement lives in `[licenses]`, which this story explicitly omits. Adding `{ name = "openssl-sys", ... }` style entries pre-emptively without a real reason is speculative scaffolding.
   - **Do NOT set `multiple-versions-include-dev = true`.** Dev-deps duplicating with production deps is normal (e.g., `criterion` pulls older crates) and not a signal we care about while WIP.
   - **Do NOT set `allow = [...]`** — turning the deny-list into an allow-list would force every workspace dep to be listed individually, which is exactly the maintenance burden the WIP-rework dropped.
   - **Do NOT add `[bans] features.allow|deny`** rules. We have zero crate-specific feature constraints at this point; the rule lands when a concrete need appears (typical case: forbidding a `tokio` feature that pulls a big subsystem).

4. **AC-4 — `cargo deny --workspace check advisories bans` runs cleanly from the workspace root.** From `/Users/ralph.bergmann/development/projects/privat/Zanshin/`:
   - First-run behaviour (cold advisory DB): the run downloads `https://github.com/rustsec/advisory-db` into `~/.cargo/advisory-dbs/` (one-time, ~30–60s on a typical network). This is **expected** — `cargo-deny` fetches lazily on first use unless `--disable-fetch` is passed (we do not pass it). The Story 1.4 `test-cargo-deny` task does not pass `--disable-fetch`, so CI and developer-machine first-runs hit the same code path.
   - Steady-state behaviour (warm DB): the run takes < 5 seconds against the empty workspace (no third-party deps yet — `[workspace.dependencies]` block in `Cargo.toml` has zero entries at story-start time per `Cargo.toml:28`).
   - Exit code: 0.
   - Output: `advisories ok, bans ok` (cargo-deny's default human-output format).
   - **Crucially: no `unable to find a config path, falling back to default config` warning** — that warning currently appears under Story 1.4's `cargo make test` because `deny.toml` does not exist yet. Once AC-1 lands, the warning disappears (cargo-deny finds and loads the config).

5. **AC-5 — `cargo make test` (Story 1.4 test-cargo-deny task) exits 0 with no warnings.** Re-running the full WIP-minimal gate from the workspace root MUST still exit 0:
   ```
   cargo make test
   ```
   The `test-cargo-deny` sub-task (`Makefile.toml:90-96`) invokes `cargo deny --workspace check advisories bans`. After AC-1, this step:
   - Finds and loads `deny.toml` (no fallback warning).
   - Runs against the empty workspace dep graph.
   - Exits 0.
   This is the load-bearing AC — it closes the "no deny.toml → warning under cargo make test" loop that Story 1.4 documented as an edge case (AC-3 edge case § "cargo deny check advisories bans runs before deny.toml lands").

6. **AC-6 — Advisory-DB pre-warm path documented (deferred-work absorption).** The deferred-work item from Story 1.4's review explicitly named Story 1.6 as the owner:
   > **cargo-deny advisory DB auto-download + advisory churn fragility** [`Makefile.toml:114-117`] — `cargo deny check advisories bans` does network I/O on first run (advisory DB sync) and will hard-fail when a transitive dep gets a published RUSTSEC advisory until ignored in `deny.toml`. Owned by Story 1.6 (`deny.toml` + ignore list).

   Story 1.6 absorbs this by:
   - **(a) Documenting the first-run download cost.** The new `README.md` § "cargo-deny advisory database (first-run cost)" section (append after the existing § "Build & development" added in Story 1.4) explains: first run downloads `~/.cargo/advisory-dbs/` (~30s, one-time), subsequent runs are local. Cold-run command for pre-warming a fresh machine or CI cache: `cargo deny fetch db` (no full check). The README does NOT prescribe `cargo deny fetch db` as a `cargo make` task target — it's a one-time human action; the WIP-minimal gate (`cargo make test`) already triggers the same fetch on its first invocation.
   - **(b) Documenting the ignore-list operating procedure.** Same README section explains: when a new published RUSTSEC advisory fires on a transitive dep, the response is **NOT** to ignore it silently. The procedure is:
     1. Investigate: is the advisory exploitable in Zanshin's surface? (Most aren't — they're library bugs that need specific input patterns.)
     2. Attempt a dep upgrade (`cargo update -p <transitive>`).
     3. If upgrade isn't possible (no fixed release yet, or upstream pins the version), add a `[advisories.ignore]` entry with:
        - `id = "RUSTSEC-YYYY-NNNN"` plus
        - `reason = "..."` (one-line, non-empty — cargo-deny rejects empty reasons), and
        - a comment line above the entry linking the upstream tracking issue / our own GitHub issue.
     4. Re-evaluate every entry quarterly: the `unused-ignored-advisory = "warn"` setting (AC-2) surfaces stale ignores automatically — when a warn fires, the ignore can be dropped.
   - **(c) Marking the deferred-work entry RESOLVED.** Per AC-9.

7. **AC-7 — `cargo deny --workspace check advisories bans` failure modes are tested empirically.** Beyond AC-4 (the happy path), the dev agent verifies two failure paths during story execution. These are **not** committed as automated tests (over-engineering for a config file); they are one-time manual verifications that prove the config does what we want, with results captured in Debug Log References:
   - **Verification 7a — Wildcard version is rejected.** Temporarily add a wildcard dep to `crates/zanshin-jj/Cargo.toml` `[dependencies]`:
     ```toml
     serde = "*"
     ```
     Run `cargo deny --workspace check advisories bans` from the workspace root. Expected: exits non-zero, prints a `wildcards` violation naming `serde` and pointing at `crates/zanshin-jj/Cargo.toml`. Revert the change. **Do NOT commit the wildcard.**
   - **Verification 7b — `deny.toml` with a deprecated key is rejected.** Temporarily replace the `[advisories]` block with:
     ```toml
     [advisories]
     vulnerability = "deny"
     ```
     Run `cargo deny --workspace check advisories bans`. Expected: exits non-zero with a `deserialization` or `unknown field` error pointing at the deprecated `vulnerability` key. **Revert immediately** — this verification only exists to prove the v2 schema is being enforced and our config doesn't accidentally use deprecated keys.
   - Both verifications are documented in the dev agent's `Debug Log References` with the exact cargo-deny error messages observed, so the next reviewer sees the v2-schema discipline was tested, not assumed.

8. **AC-8 — `README.md` documents the cargo-deny first-run cost + ignore-list workflow.** Append a new section to `/Users/ralph.bergmann/development/projects/privat/Zanshin/README.md`:
   ```markdown
   ## Dependency security — cargo-deny

   `cargo make test` runs `cargo deny --workspace check advisories bans` as
   the security backstop. The full license-gate (`cargo deny check licenses`)
   and Dart-side `pana` integration are deferred to the release phase
   (see `_bmad-output/planning-artifacts/prd.md` § 5.4).

   ### First-run advisory database download

   On a fresh machine (and on CI cache misses), the first invocation
   fetches `https://github.com/rustsec/advisory-db` into
   `~/.cargo/advisory-dbs/`. This is a one-time ~30–60s download.
   Subsequent runs are local-only and finish in under 5s on this workspace.

   To pre-warm the database without running the full check:

       cargo deny fetch db

   ### Advisory ignore-list workflow

   When a published RUSTSEC advisory fires on a transitive dependency,
   the response is **not** to ignore it silently. The procedure:

   1. Investigate whether the advisory is exploitable in Zanshin's actual
      use of the affected dep.
   2. Try `cargo update -p <crate>` to pick up a fixed version.
   3. If neither resolves it, add an entry to `[advisories.ignore]` in
      `deny.toml` with an `id`, a non-empty `reason`, and a comment
      linking the upstream tracking issue.
   4. The `unused-ignored-advisory = "warn"` setting surfaces stale
      ignores automatically — when the warn fires (advisory withdrawn,
      or dep upgraded away), drop the entry.

   See `deny.toml` for the live config; every key carries an inline
   comment explaining its choice.
   ```
   - The section appears AFTER the existing "## Build & development" section that Story 1.4 added.
   - The wording above is canonical; minor style edits are fine but the **section title**, the **two subsection titles**, the **`cargo deny fetch db` command**, and the **four-step ignore procedure** are mandatory.
   - No edits to the toolchain table (Story 1.3) or to the Build & development section (Story 1.4).

9. **AC-9 — `deferred-work.md` updated to mark the absorbed entry RESOLVED.** Open `/Users/ralph.bergmann/development/projects/privat/Zanshin/_bmad-output/implementation-artifacts/deferred-work.md` and mark the following bullet under "## Deferred from: code review of 1-4-author-makefile-toml-with-build-test-codegen-targets (2026-05-17)" as resolved using the existing strikethrough + RESOLVED pattern (see the 1-2 / 1-3 entries for the precedent):

   Before:
   ```markdown
   - **cargo-deny advisory DB auto-download + advisory churn fragility** [`Makefile.toml:114-117`] — `cargo deny check advisories bans` does network I/O on first run (advisory DB sync) and will hard-fail when a transitive dep gets a published RUSTSEC advisory until ignored in `deny.toml`. Owned by Story 1.6 (`deny.toml` + ignore list).
   ```

   After:
   ```markdown
   - ~~**cargo-deny advisory DB auto-download + advisory churn fragility** [`Makefile.toml:114-117`]~~ — RESOLVED 2026-05-18 (Story 1.6): `deny.toml` lands with the v2 schema (`[advisories]` + `[bans]` only — `[licenses]` deferred per WIP-rework); README documents the first-run ~30s download (`cargo deny fetch db` to pre-warm) and the ignore-list operating procedure; `unused-ignored-advisory = "warn"` makes stale ignores self-surface.
   ```

   - The other three entries under that 1-4 section (`cwd = "app"` is relative — Ralph defers; resolved `verify-codegen` unstaged-edit precondition; etc.) stay untouched — they belong to other stories or are out of WIP scope.
   - All entries under the 1-1, 1-2, 1-3, and 1-5 sections stay untouched. **Only the one named entry under the 1-4 section is touched by Story 1.6.**

10. **AC-10 — `sprint-status.yaml` audit trail updated.** Story 1.6's status transitions follow the standard workflow:
    - At story-write time (i.e., now, by the create-story workflow): `1-6-add-cargo-deny-advisories-bans-security-backstop: ready-for-dev`, `last_updated: 2026-05-18`, and a `# Story 1-6 created (ready-for-dev): 2026-05-18` audit comment is appended to the header block (after the existing `# Story 1-5 reviewed + done: 2026-05-17` line).
    - The dev agent transitions through `in-progress` → `review` → `done` later via the standard dev-story / code-review workflow.
    - Epic 1's status stays `in-progress` (no transition; epic flips to `in-progress` only on the FIRST story of an epic per `bmad-create-story` step 1; Stories 1-1..1-5 already triggered it).

11. **AC-11 — No regressions on Story 1.1 / 1.2 / 1.3 / 1.4 / 1.5 invariants.** After all edits:
    - `cargo build --workspace` exits 0 with zero warnings (Story 1.1 invariant — workspace resolves; `deny.toml` is not parsed by cargo build).
    - `cargo build --release` exits 0 with zero warnings AND does NOT compile `xtask` (Story 1.4 AC-9 invariant — `default-members` unchanged).
    - `cargo make test` exits 0 (the new `deny.toml` strengthens the test-cargo-deny step; all other steps unaffected).
    - `cargo make codegen` exits 0 and is byte-idempotent (Story 1.5 AC-6 invariant — `deny.toml` doesn't touch codegen).
    - `cargo make verify-codegen` exits 0 on a clean tree (Story 1.5 AC-7 invariant).
    - `cd app && flutter build macos --debug` exits 0 (Story 1.2 invariant — Dart Hook still wires the cdylib).
    - `rustup show active-toolchain` from repo root prints the `1.95.0-<arch>-apple-darwin (overridden by ...)` line (Story 1.3 invariant).

**Edge cases:**

12. **Edge case — cargo-deny not installed.** `cargo make test` invokes `cargo deny --workspace check advisories bans`. If `cargo-deny` is not on PATH, the cargo subcommand resolver fails with `error: no such command: deny`. Mitigation: README's "Toolchain" section (Story 1.3) already documents `cargo install cargo-deny` (verified at story-write time: `cat README.md | grep -n cargo-deny` shows the install line). Story 1.6 does NOT re-document the install — only adds the operational section (AC-8). The dev agent verifies cargo-deny is callable with `which cargo-deny` before running AC-4: at story-write time this prints `/Users/ralph.bergmann/development/sdks/cargo/bin/cargo-deny` (version `0.19.6`, confirmed via `cargo deny --version`).

13. **Edge case — Empty workspace dep graph yields confusingly-trivial output.** At story-start time, `[workspace.dependencies]` in `Cargo.toml:28` is empty and the five member crates' `[dependencies]` are also empty (Story 1.1 state, unchanged through 1-5). Therefore `cargo deny --workspace check advisories bans` reports `advisories ok, bans ok` against zero crates and runs in well under 1 second. This is **expected** — the config is correct, there's just nothing to check yet. The config becomes load-bearing the moment Epic 2 / Story 2.3 adds `jj-lib = "=0.41.0"` (`project-context.md` § Technology Stack & Versions). The Story 1.6 reviewer should NOT reject the work for "doesn't catch any real advisories" — the absence of any dep is the precondition, not a defect.

14. **Edge case — Advisory DB fetch fails on first run (offline / firewall).** If `cargo deny --workspace check advisories bans` is invoked without network access on a cold machine, gix's fetch fails and cargo-deny exits non-zero with a fetch error. This is a developer-machine concern, not a CI concern (CI is online). Mitigation in README (AC-8): a developer can `cargo deny fetch db` once when online, after which the local cache satisfies offline runs for the next `maximum-db-staleness` window (default 90 days). Story 1.6 does NOT add a `--disable-fetch` flag to the `test-cargo-deny` task — disabling fetch would mask real fetch failures in CI; the trade-off (a developer behind a firewall sees the first-run error) is documented in README, not patched around in Makefile.toml.

15. **Edge case — Future Epic 2 dep gets a fresh RUSTSEC advisory between Story 1.6 done and Epic 2 start.** Specifically: `jj-lib = "=0.41.0"` is pinned (`project-context.md`) and lives in a pre-1.0 ecosystem. If a RUSTSEC advisory is published against `jj-lib` (or any of its transitive deps) between this story's done date and the day Epic 2 adds the dep, `cargo make test` will go from green to red on Epic 2's first PR. **This is the desired behaviour** — the whole point of the security backstop. The response is the AC-6 / AC-8 ignore-list workflow, not a config change. Story 1.6 does not pre-emptively populate `[advisories.ignore]` for hypothetical future advisories (`project-context.md` § "Don't design for hypothetical future requirements").

16. **Edge case — `[graph] all-features = false` interacts with cdylib-only deps.** `cargo-deny`'s `[graph]` table controls which features are activated when traversing the dep graph. Setting `all-features = false` (the default — listed explicitly for documentation) means cargo-deny mirrors what `cargo build --release` actually links. If a workspace member uses `[features]` with optional deps, those optional deps are NOT scanned unless they're enabled by `default`. This is correct for security-scanning purposes: we want to know what ships, not what could conceivably ship under some feature flag combination. **Do NOT** set `all-features = true` to "be safe" — it expands the graph to include dev-mode-only dependencies and produces false positives.

17. **Edge case — `multiple-versions = "warn"` produces noisy output once real deps land.** Once Epic 2 brings `jj-lib` and its transitive graph, `multiple-versions` will likely fire on common-duplicate crates (`syn`, `windows-sys`, etc. — Rust ecosystem patterns). The warns are **informational, not blocking** (`= "warn"`, not `= "deny"`). Reviewer guidance: when a warn fires, the question is "does this duplicate matter?" — usually no (different crates need different versions of `syn` during major-version transitions); rarely yes (two copies of `serde` would be a bug). Adding to `[bans].skip = [...]` is the escape hatch for known-acceptable duplicates; Story 1.6 leaves the skip list empty and trusts the per-warn review.

18. **Edge case — `cargo-deny` 0.19.x → 0.20.x major-version drift.** cargo-deny pre-1.0 is on a roughly-quarterly release cadence and has changed config-key names within v2 (e.g., the `vulnerability`/`unsound`/`notice` removals were a 0.16 → 0.17 jump). The README does NOT pin a cargo-deny version (Story 1.3 just lists `cargo install cargo-deny`). If a future cargo-deny version makes another schema-incompatible change, `cargo make test` will hard-fail on PR CI and the response is to update `deny.toml` in that same PR. **Story 1.6 does NOT add `cargo install --locked --version 0.19.6 cargo-deny` to the README** — pinning the binary version across machines is a heavier-weight commitment than is warranted while WIP; the schema-fail-loud feedback loop is acceptable.

## Tasks / Subtasks

- [x] **T1 — Create `deny.toml` at workspace root (AC: 1, 2, 3)**
  - [x] Create `/Users/ralph.bergmann/development/projects/privat/Zanshin/deny.toml`.
  - [x] Line 1: `# SPDX-License-Identifier: Apache-2.0` (note `#` not `//` for TOML).
  - [x] Lines 2..: blank line, then a 2–3 line file-purpose comment explaining: "Workspace cargo-deny config. WIP scope: `[advisories]` + `[bans]` only — license-gate (`[licenses]`) and source-gate (`[sources]`) are deferred to release phase per `prd.md` § 5.4."
  - [x] Add `[graph]` table with `all-features = false` and a single comment-line above explaining the choice (per AC-16).
  - [x] Add `[advisories]` table per AC-2, with **every key carrying its inline comment** (the comments are part of the AC — they make the file's decisions reviewable without cross-referencing the story). Use the wording in AC-2 verbatim (minor copy-edits fine; the **set of keys** and the **commentary intent** are mandatory).
  - [x] Add `[bans]` table per AC-3, same inline-comment treatment.
  - [x] Save file. Run `cargo deny --workspace check advisories bans` from the workspace root. Verify exit 0 and no `unable to find a config path` warning.

- [x] **T2 — Empirical verification of the v2 schema discipline (AC: 7)**
  - [x] **T2a — Wildcard rejection (Verification 7a):**
    - [x] Open `crates/zanshin-jj/Cargo.toml`. Under `[dependencies]` add a temporary line `serde = "*"`.
    - [x] Run `cargo deny --workspace check advisories bans`. Capture the exact error message (file path + key + line).
    - [x] Revert the change (`git checkout -- crates/zanshin-jj/Cargo.toml`).
    - [x] Record the captured error in the dev-agent's Debug Log References under heading "Verification 7a — wildcard rejection".
  - [x] **T2b — Deprecated key rejection (Verification 7b):**
    - [x] Open `deny.toml`. Temporarily REPLACE the `[advisories]` block with the deprecated-key form:
      ```toml
      [advisories]
      vulnerability = "deny"
      ```
    - [x] Run `cargo deny --workspace check advisories bans`. Capture the cargo-deny `deserialize` / `unknown field` error.
    - [x] **Immediately revert** the deny.toml to the AC-2 form (re-wrote from canonical content — new file not yet committed).
    - [x] Record the captured error in Debug Log References under heading "Verification 7b — deprecated key rejection".
    - [x] Re-run `cargo deny --workspace check advisories bans` to confirm green after revert.
  - [x] Both verifications are one-time; no test fixtures, no committed artefacts.

- [x] **T3 — Append README cargo-deny operational section (AC: 6, 8)**
  - [x] Open `/Users/ralph.bergmann/development/projects/privat/Zanshin/README.md`.
  - [x] Append the new `## Dependency security — cargo-deny` section after the existing `## Build & development` section (added in Story 1.4). Use the canonical wording in AC-8 (minor style edits OK; mandatory items per AC-8).
  - [x] Verify the existing Toolchain section's `cargo install cargo-deny` line is still present and unchanged (Story 1.3 invariant).
  - [x] Run `dart format` and `cargo fmt` are not relevant here; `README.md` is markdown — no formatter. Just save.

- [x] **T4 — Update `deferred-work.md` (AC: 9)**
  - [x] Open `/Users/ralph.bergmann/development/projects/privat/Zanshin/_bmad-output/implementation-artifacts/deferred-work.md`.
  - [x] Locate the bullet under "## Deferred from: code review of 1-4-author-makefile-toml-with-build-test-codegen-targets (2026-05-17)" starting with `**cargo-deny advisory DB auto-download + advisory churn fragility**`.
  - [x] Replace per AC-9 (strikethrough the title, append the `— RESOLVED 2026-05-18 (Story 1.6): ...` block per the existing 1-2 / 1-3 resolution pattern).
  - [x] Verify the OTHER three entries in the 1-4 section stay untouched (the `cwd = "app"` line and the resolved `verify-codegen` lines).
  - [x] Verify entries in 1-1, 1-2, 1-3, 1-5 sections stay untouched — Story 1.6 absorbs ONE deferred entry only.

- [x] **T5 — Run full validation sweep (AC: 4, 5, 11)**
  - [x] `cargo make test` — full 7-step WIP-minimal gate. Expect exit 0 and the `cargo deny` step to NOT emit the `unable to find a config path` warning.
  - [x] `cargo deny --workspace check advisories bans` from workspace root — exit 0, output `advisories ok, bans ok`.
  - [x] `cargo build --workspace` — exit 0, no warnings.
  - [x] `cargo build --release` — exit 0, no warnings; `xtask` not compiled (AC-11 / Story 1.4 invariant).
  - [x] `cargo make codegen` — exit 0, byte-idempotent (Story 1.5 invariant).
  - [x] `cargo make verify-codegen` — exit 0 on clean tree (Story 1.5 invariant).
  - [x] `cd app && flutter build macos --debug` — exit 0 (Story 1.2 invariant).
  - [x] `git status` — shows: `deny.toml` NEW, `README.md` EDITED, `deferred-work.md` EDITED, `sprint-status.yaml` EDITED. No other files touched.

- [x] **T6 — Update `sprint-status.yaml` (AC: 10)**
  - [x] (Done by the create-story workflow at story-write time, before the dev agent starts.) Transition `1-6-add-cargo-deny-advisories-bans-security-backstop` from `backlog` → `ready-for-dev`.
  - [x] (Dev agent later) Transition through `in-progress` → `review` per the standard dev-story / code-review flow.

## Dev Notes

### What this story is

A **config-only** story. Authors a single `deny.toml` at the workspace root that wires the `cargo deny --workspace check advisories bans` invocation (already in Story 1.4's `test-cargo-deny` task) to a project-specific config instead of cargo-deny's built-in defaults. Also documents the operational workflow (advisory DB first-run cost, ignore-list procedure) in `README.md`, and absorbs the one Story-1.4-review deferred entry that named Story 1.6 as the owner.

This story satisfies **FR-BO-2** (`cargo make test` runs the WIP gate including `cargo deny check advisories bans` — `prd.md:265`) at its WIP-shrunk form per `prd.md` § 5.4 ("Enforcement (WIP)") and `project-context.md` § "CI gates (WIP-minimal)". It does NOT touch the full license-gate or `pana` — those return in the release phase.

### What this story is NOT

The original `epics.md` Story 1.6 was substantially broader before the 2026-05-17 WIP-rework. The following items from the original AC are **explicitly NOT** carried into this story (rationale: WIP-rework drops the full license-gate and Dart-side license check):

- **NOT writing `[licenses]` allow-list / deny-list / `unlicensed` / `copyleft` / `default` keys.** The full license-gate is deferred to the release phase per `prd.md` § 5.4 "Enforcement (WIP)". The original epics.md AC bullet — `[licenses]` table with `allow = ["Apache-2.0", "MIT", ...]`, `deny = []`, `unlicensed = "deny"`, `copyleft = "deny"`, `default = "deny"` — is SUPERSEDED.
- **NOT writing a `[sources]` table.** Same WIP-rework rationale; source-list maintenance is part of the deferred full license-gate.
- **NOT integrating `pana`.** Original epics.md AC mandated `dart pub global activate pana`, `cd app && dart run pana --no-warning`, and JSON-output parsing for per-dep license extraction. All of it is DROPPED in the WIP-rework. `pana` returns in the release phase if at all (`prd.md` § 5.4: "Dart-side `pana` are deferred to the release phase").
- **NOT writing a hypothetical-GPL-dep failure test.** The original epics.md AC `Given a developer adds a hypothetical GPL-licensed dependency to a member crate / When cargo deny check runs / Then it exits non-zero with a clear "license GPL-3.0 not in allow-list" message` test is DROPPED. Without `[licenses]`, there's nothing to test. The no-GPL discipline rule still applies — eyeball every new dep's license at PR review (`project-context.md` § "License compliance (WIP-scope)").
- **NOT writing a GPL-transitive-dep failure test.** Same rationale as the previous bullet.
- **NOT writing the Watchman edge case.** Original epics.md AC noted "neither flags Watchman (it's never in Cargo.toml or pubspec.yaml)". True but trivially true — Watchman isn't a dependency, so nothing can flag it. The note is informational and lives in `project-context.md` § "Platform constraints" already; restating it in `deny.toml` would add noise. The README documents Watchman elsewhere (Story 1.3).
- **NOT modifying `Makefile.toml`.** Story 1.4 already authored the `test-cargo-deny` task with the correct `cargo deny --workspace check advisories bans` invocation; no change needed. Verify at story-write time: `Makefile.toml:90-96` matches the expected pattern. Confirmed.
- **NOT pinning `cargo-deny` version.** Per Edge Case 18 — schema-fail-loud is the feedback loop; pinning is heavier-weight than the WIP project needs.
- **NOT pre-populating `[advisories.ignore]` entries.** Story starts with zero deps; no advisories can fire yet. Pre-emptive entries violate `project-context.md` § "Don't design for hypothetical future requirements".
- **NOT adding `cargo deny fetch db` as a `cargo make` task target.** It's a one-time human action (cold machine, CI cache miss). The Makefile.toml task surface is already finalized in Story 1.4; bloating it with a one-shot warm-up target adds clutter without ergonomic benefit.

### Files being created / modified

| File | State at story start | Action |
|------|----------------------|--------|
| `deny.toml` (repo root) | DOES NOT EXIST | CREATE — full v2-schema config per AC-1..3 |
| `README.md` (repo root) | EXISTS (Story 1.3 toolchain, Story 1.4 build & dev sections) | EDIT — append `## Dependency security — cargo-deny` section per AC-8 |
| `_bmad-output/implementation-artifacts/deferred-work.md` | EXISTS (~5.1 KB) | EDIT — mark the one absorbed entry RESOLVED per AC-9 |
| `_bmad-output/implementation-artifacts/sprint-status.yaml` | EXISTS (~8.5 KB) | EDIT — status tracking (1-6 to ready-for-dev / in-progress / review / done per workflow) |

Total: 1 NEW, 3 EDITED, 0 DELETED. Story-write-time edit count: 2 EDITED + 1 CREATED for the story file itself + sprint-status.yaml. Dev-agent edits (T1..T5) add the remaining changes.

### Deferred-work items absorbed by this story

Cross-referenced from `_bmad-output/implementation-artifacts/deferred-work.md` at story-write time. Story 1.6 absorbs **one** entry:

| Source review | Item | Status after this story |
|---------------|------|-------------------------|
| 1-4 review (2026-05-17) | "cargo-deny advisory DB auto-download + advisory churn fragility" | **RESOLVED** (AC-6, AC-8, AC-9) — `deny.toml` lands with `[advisories.ignore]` mechanism + README documents the workflow + `unused-ignored-advisory = "warn"` makes stale entries self-surface |

The remaining deferred entries from 1-1, 1-2, 1-3, 1-4, 1-5 reviews are **NOT** absorbed:
- 1-1: `NOTICE` file (release phase), `[workspace.lints]` (Story 1.7), `[profile.*]` (release phase) — none touch Story 1.6.
- 1-2: rust-toolchain.toml symlink fragility (Windows / `cargo package` workflow) — unrelated to cargo-deny.
- 1-3: stale planning artefact pins — already RESOLVED in Story 1.4 review.
- 1-4: `cwd = "app"` relative-path issue — Ralph defers; unrelated to cargo-deny. (The one cargo-deny entry from 1-4 IS absorbed — see table above.)
- 1-5: `zanshin_ffi_version` returns `*const c_char`, no `catch_unwind`, hardcoded `c"0.1.0"`, no asset-id consistency check — all owned by Story 3.1 / 3.2 (Epic 3 FFI infrastructure), unrelated to Story 1.6.

The verify-codegen unstaged-edit precondition (1-4 review) was already RESOLVED in Story 1.5; that strikethrough entry stays as the historical record.

### `deny.toml` skeleton (illustrative — dev agent finalizes)

The dev agent finalizes the exact file content. The skeleton below shows the structure + the load-bearing inline comments per AC-2 / AC-3:

```toml
# SPDX-License-Identifier: Apache-2.0

# Workspace cargo-deny config. WIP scope: [advisories] + [bans] only.
# License-gate ([licenses]) and source-gate ([sources]) are deferred to the
# release phase per _bmad-output/planning-artifacts/prd.md § 5.4.
# Project posture: permissive dep licenses (MIT, BSD-2/3, Apache-2.0,
# MPL-2.0, Unlicense, CC0) enforced by eyeballing at PR review while WIP.

[graph]
# Mirror what `cargo build --release` actually links — not what could
# conceivably be activated under every feature combination.
all-features = false

[advisories]
# Default RustSec advisory database — official upstream.
db-urls = ["https://github.com/rustsec/advisory-db"]
# Yanked = withdrawn from crates.io (usually for a security/correctness
# reason). Treat as deny.
yanked = "deny"
# "Unmaintained" is a judgment call by advisory authors; false-positives
# are common. Surface as warn, don't block merges — re-evaluate in release phase.
unmaintained = "workspace"
# Populated case-by-case when a transitive dep takes a fresh RUSTSEC
# advisory we can't immediately upgrade away from. Every entry requires
# `id`, non-empty `reason`, and a comment linking the upstream tracking
# issue. See README § "Dependency security — cargo-deny" for the operating
# procedure.
ignore = []
# Surface stale ignores: when an ignored advisory stops matching a real
# advisory, this fires a warn so the entry can be dropped. Prevents the
# ignore list from accumulating dead weight silently.
unused-ignored-advisory = "warn"

[bans]
# Two versions of the same crate is a code-smell (build size / time,
# resolution surprises) but not a merge-blocker in WIP. Warn surfaces
# the signal without blocking PRs against mainly-stable upstreams.
multiple-versions = "warn"
# Wildcard version requirements (`crate = "*"`) bypass the project's
# exact-pin discipline for pre-1.0 deps (project-context.md § "Version
# pinning rules"). Deny so a wildcard is a hard CI fail.
wildcards = "deny"
# No specific bans yet. The no-GPL/AGPL/LGPL/SSPL list is documented
# (project-context.md § "Critical Don't-Miss Rules") but mechanical
# enforcement returns with the release-phase [licenses] table.
deny = []
# Populated when a known-acceptable duplicate appears (e.g., two `syn`
# versions during a major-version transition). Each entry needs a comment
# above it naming the dep and the rationale.
skip = []
```

### SPDX on TOML config files

Per `project-context.md` § Documentation: "Every source file (Rust `.rs`, Dart `.dart`) starts with an SPDX license identifier on the FIRST line". The rule is **explicitly** for `.rs` and `.dart` — TOML config files (`Cargo.toml`, `rust-toolchain.toml`, `Makefile.toml`, `cbindgen.toml`) are **not** formally under that rule. Story 1.6 **establishes** an SPDX-on-TOML-configs convention by adding `# SPDX-License-Identifier: Apache-2.0` on line 1 of `deny.toml` AND retroactively to the existing TOML configs (`Makefile.toml`, `rust-toolchain.toml`, `cbindgen.toml`) — done as part of the 1-6 code review (review-finding follow-up). TOML's comment prefix is `#`, NOT `//`, which is invalid TOML and aborts parsing. This is style consistency with the workspace's SPDX-line spirit, not a deviation from the project-context rule.

### Why the v2 schema matters (and why the original AC was wrong)

cargo-deny's config schema changed substantially between 0.16 → 0.17 (the v1 → v2 transition). The original `epics.md` Story 1.6 AC was written against the older v1 schema and would produce a hard-fail config with current cargo-deny (0.19.6). Specifically:

| Original epics.md AC | v1 schema | v2 schema (current) | Why removed |
|----------------------|-----------|---------------------|-------------|
| `vulnerability = "deny"` | Valid | **REMOVED** | All vulnerability advisories now emit errors unconditionally. The key is gone — cargo-deny rejects it. |
| `notice = "warn"` | Valid | **REMOVED** | All notice advisories now emit errors unconditionally. |
| `unsound` (as a level) | Valid | **REMOVED as a level** | Reshaped into a filter-spec (`workspace`/`all`/`none`); the old `"deny"`/`"warn"` values are rejected. |
| `severity-threshold = "high"` | Valid | **REMOVED** | All vulnerability advisories now emit errors unconditionally. |
| `[advisories.ignore] = ["RUSTSEC-..."]` | Array of strings | Array of strings OR PackageSpec objects with `reason` | Both forms work; the object form (with `reason`) is recommended. |
| `[bans] multiple-versions = "warn"` | Valid | Valid | Unchanged. |
| `[bans] wildcards = "deny"` | Valid | Valid | Unchanged. |

The current AC (AC-2 / AC-3) is written against the v2 schema verified at story-write time via:
- `cargo deny --version` → `cargo-deny 0.19.6`
- Upstream docs: <https://embarkstudios.github.io/cargo-deny/checks/advisories/cfg.html> + <https://embarkstudios.github.io/cargo-deny/checks/bans/cfg.html>

Verification 7b (AC-7) empirically proves the v2 discipline at dev-time.

### Why `unmaintained = "workspace"` and not `unmaintained = "deny"` or `unmaintained = "warn"`

cargo-deny v2's `unmaintained` field is a **filter-spec**, not a severity level. Valid values: `none` (don't check), `workspace` (only check workspace direct dependencies), `transitive` (also check transitive deps), `all` (every dep). The original epics.md AC `unmaintained = "warn"` is a v1 form; in v2 it's rejected (or behaves unexpectedly).

The choice `workspace` (rather than `all`) is deliberate: "unmaintained" advisories on transitive deps are usually outside our control — the direct dep owner needs to either pin past the unmaintained version or maintain a fork. Surfacing transitive unmaintained advisories produces noise without an actionable response. Direct workspace deps (when Epic 2 adds them) ARE actionable — we can choose a different dep. The `workspace` filter aligns with that.

If a transitive unmaintained issue ever becomes load-bearing (e.g., the unmaintained crate has a separate vulnerability), the vulnerability check catches it regardless of the `unmaintained` filter setting.

### Why `yanked = "deny"` and not `yanked = "warn"`

A yanked crate version is withdrawn from crates.io by its author — almost always for a security or correctness reason. Building against a yanked version is taking a known-bad artefact. The cost of a CI red on a yanked version is `cargo update -p <crate>`; the cost of merging against a yanked version is shipping known-bad code. `deny` is the right level.

The default cargo-deny v2 value is `warn`. The choice to escalate to `deny` is a deliberate WIP-posture choice: code quality is production-grade from day 1 (`project-context.md` § "Hard-banned anti-patterns" + `feedback-no-mvp-shortcuts`).

### cargo-deny advisory churn — operating procedure (detailed)

When a `cargo make test` run goes red on a `cargo deny check advisories` failure:

1. **Identify the advisory**: cargo-deny's output names the RUSTSEC ID, the affected crate, and the version range. Example:
   ```
   error[A001]: Vulnerability detected
       ┌─ Cargo.lock:42:1
       │
    42 │ tokio 1.31.0 registry+https://github.com/rust-lang/crates.io-index
       │ ^^^^^^^^^^^^ security vulnerability detected
       │
       = RUSTSEC-2024-0001: tokio is vulnerable to ...
   ```

2. **Look up the advisory**: visit `https://rustsec.org/advisories/RUSTSEC-YYYY-NNNN` for the full description, severity, and fixed version range.

3. **Try the upgrade path first**:
   ```sh
   cargo update -p <crate>
   cargo make test
   ```
   If the advisory's fixed-in range is reachable from our current pin, this resolves the issue.

4. **If upgrade is blocked**: the affected crate is pinned (e.g., `jj-lib = "=0.41.0"` from `project-context.md`) or no fixed release exists yet. In that case:
   - File a tracking issue in the project's GitHub issues with the RUSTSEC link, the upstream tracking issue link, and the planned resolution date.
   - Add the ignore entry to `deny.toml`:
     ```toml
     # Tracking: github.com/dasralph/zanshin/issues/N
     # Upstream: github.com/<upstream>/<repo>/issues/M
     # Re-evaluate by 2026-MM-DD.
     [[advisories.ignore]]
     id = "RUSTSEC-YYYY-NNNN"
     reason = "<one-line rationale, non-empty — cargo-deny rejects empty>"
     ```

5. **Re-evaluate quarterly**: `unused-ignored-advisory = "warn"` (AC-2) makes stale ignores self-surface. When the warn fires, the ignore can be dropped — either the advisory was withdrawn, or the dep was upgraded away during normal work.

The README's "Advisory ignore-list workflow" (AC-8) captures the abbreviated form of this procedure; the detailed walkthrough lives here in the story for the dev agent's reference during implementation, and for the reviewer who'll come back to this story when the first real advisory fires.

### Testing standards summary (Story 1.6 specifics)

- **No automated tests committed** by this story. `deny.toml` is a config file; the "test" is `cargo deny --workspace check advisories bans` itself (already wired into `cargo make test` via Story 1.4's `test-cargo-deny` task).
- **Verifications 7a and 7b are one-time manual checks** captured in Debug Log References — not test-fixtures, not committed scripts.
- **Schema validation in tests** (`project-context.md` § "JSON / schema validation in tests") does NOT apply — `deny.toml` isn't a wire-format schema, it's a tool config; cargo-deny itself validates the schema on every run.
- **No `#[ignore]` / `skip:` debt** added (vacuously — no tests added).
- **No `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` pinning** needed — `cargo-deny` is configfile-driven and doesn't read user globals.

### Project Structure Notes

`deny.toml` is workspace-root per `architecture.md` § "File Organization Patterns": "Configuration files live at the repo root or in the package they configure. Tool configs (`rustfmt.toml`, `deny.toml`, `cbindgen.toml`) at workspace root." This matches the existing pattern set by Story 1.4 (`Makefile.toml`) and Story 1.5 (`cbindgen.toml`).

No new directories created. No subdirectory rearrangement. The full Story 1.6 footprint is:

```
zanshin/
├── deny.toml                 # NEW — Story 1.6
├── README.md                 # EDITED — new "## Dependency security — cargo-deny" section appended
└── _bmad-output/
    └── implementation-artifacts/
        ├── deferred-work.md  # EDITED — one entry marked RESOLVED
        └── sprint-status.yaml # EDITED — Story 1.6 status transitions
```

### References

- [Source: _bmad-output/planning-artifacts/epics.md § "Story 1.6: Add `cargo-deny` advisories + bans (security backstop)" — Lines 787-848, including the 2026-05-17 WIP-rework note that drops the full license-gate]
- [Source: _bmad-output/planning-artifacts/prd.md § 5.4 "Licensing" — Lines 323-327, "Enforcement (WIP): `cargo deny check advisories bans` runs in CI"]
- [Source: _bmad-output/planning-artifacts/prd.md § FR-BO-2 — Line 265, "`cargo make test` runs ... `cargo deny check advisories bans`. Full license-gate + `pana` deferred."]
- [Source: _bmad-output/planning-artifacts/architecture.md § "Development Workflow Integration" — Line 601, "`cargo make test` → Rust tests + Dart tests + `cargo-deny advisories + bans`"]
- [Source: _bmad-output/planning-artifacts/architecture.md § "CI gating (WIP-minimal)" — Line 609, "`ci.yml` blocks merge on: ..., `cargo deny check advisories bans`"]
- [Source: project-context.md § "License compliance (WIP-scope)" — "`cargo deny check advisories bans` runs in CI (security backstop, cheap). Deferred to release phase: `cargo deny check licenses`, `pana` validation. ... permissive only — MIT, BSD-2/3, Apache-2.0, MPL-2.0, Unlicense, CC0"]
- [Source: project-context.md § "CI gates (WIP-minimal)" — `cargo deny check advisories bans` listed as a gate]
- [Source: project-context.md § "Critical Don't-Miss Rules" — "NEVER add GPL / AGPL / LGPL / SSPL dependencies. The formal `cargo deny check licenses` gate is deferred to release phase; meanwhile, eyeball every new dep's license at PR-review time."]
- [Source: Makefile.toml:90-96 — `test-cargo-deny` task: `cargo deny --workspace check advisories bans`]
- [Source: _bmad-output/implementation-artifacts/deferred-work.md § "Deferred from: code review of 1-4-..." — "cargo-deny advisory DB auto-download + advisory churn fragility" — explicitly owned by Story 1.6]
- [Source: _bmad-output/implementation-artifacts/1-4-...md AC-3 Edge Case — Story 1.4 documented the "no deny.toml → cargo-deny defaults + warning" behaviour that Story 1.6 closes]
- [Source: cargo-deny v2 advisories config — `https://embarkstudios.github.io/cargo-deny/checks/advisories/cfg.html` (verified at story-write 2026-05-18 — vulnerability/notice/unsound-as-level/severity-threshold all REMOVED in v2)]
- [Source: cargo-deny v2 bans config — `https://embarkstudios.github.io/cargo-deny/checks/bans/cfg.html` (verified at story-write 2026-05-18)]
- [Source: System-installed cargo-deny version — `cargo deny --version` → `cargo-deny 0.19.6` at story-write time]

## Dev Agent Record

### Agent Model Used

`claude-sonnet-4-6`

### Debug Log References

**Verification 7a — wildcard rejection:**
Temporarily added `serde = "*"` under `[dependencies]` in `crates/zanshin-jj/Cargo.toml`.
```
error[wildcard]: found 1 wildcard dependency for crate 'zanshin-jj'
   ┌─ /Users/ralph.bergmann/development/projects/privat/Zanshin/crates/zanshin-jj/Cargo.toml:13:10
   │
13 │ serde = "*"
   │          ━ wildcard dependency
   │
   ├ zanshin-jj v0.1.0

advisories ok, bans FAILED
```
Exit code 2. Reverted via `git checkout -- crates/zanshin-jj/Cargo.toml`.

**Verification 7b — deprecated key rejection:**
Temporarily replaced `[advisories]` block with `vulnerability = "deny"` (v1 deprecated key).
```
error[deprecated]: this key has been removed, see https://github.com/EmbarkStudios/cargo-deny/pull/611 for migration information
   ┌─ /Users/ralph.bergmann/development/projects/privat/Zanshin/deny.toml:15:1
   │
15 │ vulnerability = "deny"
   │ ━━━━━━━━━━━━━

2026-05-18 11:35:35 [ERROR] failed to validate configuration file /Users/ralph.bergmann/development/projects/privat/Zanshin/deny.toml
```
Exit code 1. Reverted by re-writing deny.toml from canonical content (new file, not yet committed, so `git checkout` was not applicable). Confirmed green after revert: `advisories ok, bans ok`.

**cargo make test output (after AC-1..3 land):**
Exit 0 in 77.35 seconds. The `test-cargo-deny` step output: `advisories ok, bans ok` — no `unable to find a config path` warning. Advisory DB was already warm from prior invocations; the `cargo deny` step itself completed in < 1s against the empty workspace dep graph.

**First-run advisory DB:**
The advisory database (`~/.cargo/advisory-dbs/`) was already populated on this machine from prior `cargo deny` invocations. No network download occurred during story execution. First-run cost estimate (~30–60s) is sourced from the upstream docs and typical network conditions, as documented in AC-8.

### Completion Notes List

- Created `deny.toml` at workspace root with v2 cargo-deny schema: `[graph]`, `[advisories]`, and `[bans]` tables only. `[licenses]` and `[sources]` explicitly omitted per WIP-rework (deferred to release phase).
- All inline comments present per AC-2/AC-3, explaining rationale for every key choice.
- Empirically verified wildcard rejection (T2a) and deprecated-key rejection (T2b) — both fail as expected; both reverted cleanly.
- Appended `## Dependency security — cargo-deny` section to README.md after `## Build & development`, including first-run cost note, `cargo deny fetch db` pre-warm command, and the four-step ignore-list procedure.
- Marked the cargo-deny advisory churn deferred-work entry RESOLVED in `deferred-work.md` (Story 1.4 review section), per the strikethrough+RESOLVED pattern. Other entries in the 1-4 section and all entries in 1-1/1-2/1-3/1-5 sections left untouched.
- Full validation sweep passed: `cargo make test` (exit 0), `cargo build --workspace` (exit 0), `cargo build --release` (exit 0), `cargo make codegen` (byte-idempotent), `cargo make verify-codegen` (exit 0), `flutter build macos --debug` (exit 0), `rustup show active-toolchain` confirms 1.95.0 pin.

### File List

- CREATE: `deny.toml`
- EDIT: `README.md`
- EDIT: `_bmad-output/implementation-artifacts/deferred-work.md`
- EDIT: `_bmad-output/implementation-artifacts/sprint-status.yaml`

### Review Findings

_Multi-layer adversarial review (Blind Hunter, Edge Case Hunter, Acceptance Auditor) — 2026-05-18. Triage: 3 patch, 2 defer, 6 dismissed._

- [x] [Review][Patch] `unmaintained = "workspace"` inline comment misdescribes the v2 filter-spec semantics [`deny.toml:20-25`] — Comment said "Surface as warn, don't block merges" but `"workspace"` is a SCOPE selector (`none`/`workspace`/`all`), not a severity. Reworded to describe filter scope and note that unmaintained advisories always surface as warn in cargo-deny v2 regardless. Applied 2026-05-18.
- [x] [Review][Patch] AC-10 audit trail missing `started` and `review` transition lines in `sprint-status.yaml` [`_bmad-output/implementation-artifacts/sprint-status.yaml:58-64`] — Added `# Story 1-6 started: 2026-05-18` and `# Story 1-6 review: 2026-05-18` per Story 1-5 precedent. Applied 2026-05-18.
- [x] [Review][Patch] `cargo deny check all` / `check licenses` foot-gun (no inline guard in `deny.toml`) [`deny.toml:8-13`] — Added a `# WARNING:` block in the file-preamble explaining that `check all` / `check licenses` rejects all our own Apache-2.0 crates while `[licenses]` is deferred; the only supported invocation is `check advisories bans`. Applied 2026-05-18. (Re-ran `cargo deny --workspace check advisories bans` → `advisories ok, bans ok`.)
- [x] [Review][Dismiss] Edge Case Hunter claim "Dev Notes wrongly lists `transitive` as a valid `unmaintained` value" was a **false positive** [`_bmad-output/implementation-artifacts/1-6-add-cargo-deny-advisories-bans-security-backstop.md:418`] — Empirically verified against cargo-deny 0.19.6: setting `unmaintained = "bogus"` produces `error[unexpected-value]: expected '["all", "workspace", "transitive", "none"]'`. All four values (`all`, `workspace`, `transitive`, `none`) are valid; the reviewer's docs claim was outdated. No story-doc change needed. Dismissed 2026-05-18.
- [x] [Review][Patch] Dev Notes' SPDX-precedent claim is factually wrong — `Makefile.toml`, `rust-toolchain.toml`, `cbindgen.toml` all lacked SPDX lines on line 1 [`_bmad-output/implementation-artifacts/1-6-add-cargo-deny-advisories-bans-security-backstop.md:394`] — Resolved 2026-05-18 by **establishing** the SPDX-on-TOML precedent: added `# SPDX-License-Identifier: Apache-2.0` on line 1 of `Makefile.toml`, `rust-toolchain.toml`, and `cbindgen.toml` (retroactively to their respective stories), and rewrote Dev Notes § "SPDX on TOML config files" to describe Story 1.6 as the *establisher* of the convention, not a follower of a non-existent precedent.

**Dismissed as noise (6):** `cargo deny fetch db` exists (verified via `cargo deny fetch --help`); `[graph] all-features = false` is acknowledged by spec Edge Case 16; "every key has inline comment" pedantry on table headers; `[bans].deny = []` clarity (comment is explicit about the GPL gap); deferred-work resolution "conflates docs with mitigation" (docs ARE the deliverable + `unused-ignored-advisory = "warn"` is the mechanism); README "under 5s" claim staleness (revisit when Epic 2 deps land).

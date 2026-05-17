# Story 1.3: Pin Rust toolchain and document Flutter/Dart pins

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer ensuring reproducible builds and a uniform toolchain across machines**,
I want **the Rust toolchain pinned via `rust-toolchain.toml` with `components` and `profile` declared, plus the Flutter/Dart channel + version pins documented in a root `README.md`**,
so that **every contributor builds with the exact same toolchain (Rust 1.95.0 + Flutter `main` channel `^3.44.0-1.0.pre-573` + Dart `main` channel `^3.13.0-104.0.dev`), and FR-BO-7 (toolchain-pinned) is satisfied while FR-BO-8 (reproducibility CI) stays achievable for the release phase**.

## Acceptance Criteria

1. **AC-1 — `rust-toolchain.toml` declares channel + components + targets + profile.** The repo-root `rust-toolchain.toml` contains exactly:
   ```toml
   [toolchain]
   channel = "1.95.0"
   components = ["rustfmt", "clippy", "rust-src"]
   targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]
   profile = "minimal"
   ```
   - `components` MUST include `rustfmt` and `clippy` so `cargo fmt --check` and `cargo clippy -- -D warnings` (project-context.md § CI gates) work on every fresh checkout without manual `rustup component add`. `rust-src` is included for IDE / `rust-analyzer` ergonomics (cheap to ship, painful to forget).
   - `profile = "minimal"` keeps `rustup install` lean — components are added explicitly above, no implicit `docs` / `cargo-as-component`.
   - `targets` covers both Apple Silicon (`aarch64`) and Intel (`x86_64`) so universal-binary builds (Epic 8) are not blocked by a missing target.
   - Closes the deferred item "Root `rust-toolchain.toml` lacks `components = [\"rustfmt\", \"clippy\"]` and `profile`" from `_bmad-output/implementation-artifacts/deferred-work.md` (2026-05-17 review of Story 1.2).

2. **AC-2 — Existing `crates/zanshin-ffi/rust-toolchain.toml` symlink carries the new content through unchanged.** That file is a symlink to `../../rust-toolchain.toml` (committed in Story 1.2 to give `native_toolchain_rust`'s `cargo` invocation a toolchain pin when its CWD is the crate dir). The symlink target is the root file — editing the root file MUST be sufficient; **do not** convert the symlink to a regular file, do not duplicate content. Verify after edit: `readlink crates/zanshin-ffi/rust-toolchain.toml` returns `../../rust-toolchain.toml`, and `cat crates/zanshin-ffi/rust-toolchain.toml` shows the new content.

3. **AC-3 — `rustup` honours the pin on every supported entry point.** From the repo root:
   ```sh
   rustup show active-toolchain
   ```
   prints `1.95.0-<arch>-apple-darwin (overridden by '<absolute-path-to-repo>/rust-toolchain.toml')`. The same command from `crates/zanshin-ffi/` resolves via the symlink and prints the same `(overridden by ...)` line. `cargo build --workspace` exits 0 with zero warnings using the pinned toolchain.

4. **AC-4 — Root `README.md` exists with a `## Toolchain` section.** A new `README.md` is created at the repo root (currently absent — only `crates/README.md` and `app/README.md` exist). The README has:
   - A 1–3 sentence project intro (e.g., "Zanshin is a macOS-native Flutter GUI for the Jujutsu (`jj`) VCS, with a Rust backend exposed via Dart Hooks + manual FFI. macOS-only. Pre-1.0; WIP.").
   - A `## Toolchain` section listing the exact pins below.
   - A pointer to `_bmad-output/planning-artifacts/` and `_bmad-output/project-context.md` for the architecture and AI-agent rules respectively.
   - No badges, no marketing copy, no contribution guide, no roadmap. Keep it minimal — this is solo-OSS WIP.

5. **AC-5 — The `## Toolchain` section pins Rust, Flutter, and Dart explicitly and accurately.** Section content (verbatim or equivalent prose):

   ```markdown
   ## Toolchain

   All toolchains are installed system-wide. **No FVM, no per-project rustup overrides.**

   | Tool    | Pin                                   | Source-of-truth                                                            |
   |---------|---------------------------------------|----------------------------------------------------------------------------|
   | Rust    | `1.95.0`                              | `rust-toolchain.toml` (auto-applied by `rustup` on `cargo` invocation)     |
   | Flutter | `main` channel, ≥ `3.44.0-1.0.pre-573` | `app/pubspec.yaml` → `environment.flutter`; this README is the human pin    |
   | Dart    | `main` channel, ≥ `3.13.0-104.0.dev`  | `app/pubspec.yaml` → `environment.sdk`; bundled with Flutter `main`         |

   **Why these versions:**
   - **Rust `1.95.0`** — pinned exactly to make CI and developer machines byte-equivalent
     in compiler output. Bumps are explicit PRs with a `# WHY:` rationale; the release-phase
     reproducibility CI (FR-BO-8) re-validates artefacts on every bump.
   - **Flutter `main` channel** — the Flutter UI work (Ralph's separate scope, not in this
     repo) targets multi-window APIs that are not in any stable channel release. Stable
     pins are not viable until multi-window support ships on a stable Flutter. Revisit then.
   - **Dart `main` channel** — bundled with Flutter `main`; tracks in lockstep. No
     independent Dart pin.

   **One-time install (per machine):**

   ```sh
   # Rust — rustup auto-installs 1.95.0 the first time you cd into the repo and run cargo,
   # but you can pre-install:
   rustup install 1.95.0

   # Flutter main channel (manual; no FVM):
   #   https://flutter.dev/docs/get-started/install
   # Then switch to main and pin via:
   flutter channel main
   flutter upgrade

   # cargo-make (used by Story 1.4+ build/test entry points):
   cargo install cargo-make
   ```

   **CI note:** GitHub Actions workflow (Story 1.9) reads `rust-toolchain.toml` via
   `dtolnay/rust-toolchain@master` (or equivalent action that respects the file) — no
   hardcoded Rust version in YAML. Flutter setup in CI uses `subosito/flutter-action@v2`
   with `channel: 'master'` (the action's name for Flutter's `main` channel) and the
   exact `flutter-version` from `app/pubspec.yaml`.
   ```

   Links to `https://rustup.rs` and `https://flutter.dev/docs/get-started/install` are present in the install block. **The exact wording above is not mandatory; the listed facts (pin values, "no FVM", channel rationale, `cargo install cargo-make` line, CI note) ARE mandatory.**

6. **AC-6 — Forward-references in `crates/README.md` are updated.** `crates/README.md` § "Rust Toolchain" currently states *"Story 1.1 does **not** pin the Rust toolchain — that lands in **Story 1.3** via `rust-toolchain.toml`. Until then, install Rust 1.95.0 ..."*. This section is now stale. Replace it with:
   - One short paragraph: "Rust is pinned to `1.95.0` via the workspace-root `rust-toolchain.toml`. `rustup` auto-applies it on every `cargo` invocation from anywhere in the repo. See the root `README.md` § Toolchain for install + bump policy."
   - Remove the `rustup install / rustup default` snippet — it is now redundant; `rustup` handles it automatically per the pin file.

7. **AC-7 — On-machine verification (smoke check at story-write time).** The story author has verified locally that the developer's machine already runs the target toolchains (`rustc 1.95.0`, `cargo 1.95.0`, `Flutter 3.44.0-1.0.pre-573 channel main`, `Dart 3.13.0-104.0.dev`). After this story's edits, `cargo build --workspace` from the repo root and `flutter build macos --debug` from `app/` continue to exit 0 with zero warnings (Story 1.1 + Story 1.2 invariants must not regress).

8. **AC-8 — `deferred-work.md` updated.** Once the AC-1 components+profile edit lands, the entry **"Root `rust-toolchain.toml` lacks `components = [\"rustfmt\", \"clippy\"]` and `profile`"** is removed from `_bmad-output/implementation-artifacts/deferred-work.md` (it is now resolved). All other entries in that file stay (they belong to other stories or are out-of-scope for 1.3).

**Edge cases:**

9. **Edge case — Developer is on a newer Rust (e.g., `1.97.0`).** `cd` into the repo + `cargo build` → `rustup` transparently switches to `1.95.0` per `rust-toolchain.toml`. No manual override required. The README documents this auto-switch behaviour (per AC-5 "rustup auto-installs ... the first time").

10. **Edge case — Developer has no Rust installed.** `cd` into the repo + `cargo build` → `rustup` prompts to install `1.95.0` (rustup-managed behaviour). The README's install block flags this (per AC-5).

11. **Edge case — Developer wants to bump the Rust pin.** Edit `rust-toolchain.toml`, raise a PR with a `# WHY:` rationale in the commit message. The README's "Why these versions" subsection captures the bump-discipline expectation. The release-phase reproducibility CI (FR-BO-8 — deferred per WIP scope) is the eventual mechanical gate; in WIP, code review enforces it.

12. **Edge case — Flutter `main` channel breaks between local + CI.** Documented as a known WIP-trade-off in the README ("main channel is moving"). The local install command (`flutter channel main && flutter upgrade`) is the canonical recovery path. No CI mitigation in Story 1.3 — Story 1.9's CI workflow uses `subosito/flutter-action@v2` with `channel: 'master'` and re-runs on failure; deeper handling is a future Story 1.9 concern.

13. **Edge case — Symlink at `crates/zanshin-ffi/rust-toolchain.toml` breaks on a contributor's machine.** Out of scope for Story 1.3 per the original deferral (deferred-work.md § Story 1.2 review). Revisit if/when the contributor base expands beyond macOS or `cargo package` workflow lands.

## Tasks / Subtasks

- [x] **T1 — Update root `rust-toolchain.toml` with `components` and `profile` (AC: 1, 2, 3, 8)**
  - [x] Edit `/Users/ralph.bergmann/development/projects/privat/Zanshin/rust-toolchain.toml`. Replace its current 4-line content with the 5-key block in AC-1 (channel + components + targets + profile). Preserve existing line endings; the file already has `channel = "1.95.0"` and `targets = [...]`.
  - [x] Verify `readlink crates/zanshin-ffi/rust-toolchain.toml` still returns `../../rust-toolchain.toml` (do NOT touch the symlink — leave it alone, deferred-work item rationale).
  - [x] Verify `cat crates/zanshin-ffi/rust-toolchain.toml` shows the new content (symlink carry-through).
  - [x] Run `rustup show active-toolchain` from the repo root and from `crates/zanshin-ffi/`. Both should print `1.95.0-<arch>-apple-darwin (overridden by '...rust-toolchain.toml')`.
  - [x] Run `cargo build --workspace` from the repo root. Expect exit 0, zero warnings. If `rustup` triggers a component install for `rust-src` (because the current system lacks it), let it complete — that is the AC-1 mechanism working as intended.

- [x] **T2 — Create root `README.md` with `## Toolchain` section (AC: 4, 5)**
  - [x] Create `/Users/ralph.bergmann/development/projects/privat/Zanshin/README.md`. There is currently no README at root (verified at story-write time).
  - [x] Write a 1–3 sentence project intro (suggested wording is in AC-4; tweak for tone but stay minimal — no badges, no marketing).
  - [x] Add the `## Toolchain` section per AC-5: table of pins, "Why these versions" subsection, "One-time install" code block, "CI note" paragraph.
  - [x] Include the exact strings: "No FVM", "no per-project rustup overrides", "cargo install cargo-make", "main channel" (for Flutter + Dart), and the links to `https://rustup.rs` + `https://flutter.dev/docs/get-started/install`.
  - [x] Add a one-line pointer at the end of the README (or a tiny `## Project documentation` subsection): "See `_bmad-output/planning-artifacts/` for PRD + architecture + epics; `_bmad-output/project-context.md` is the AI-agent rule set."
  - [x] Run `markdownlint README.md` if a `markdownlint` config exists (none currently — skip if not installed). Do NOT add a markdownlint dependency in this story.
  - [x] **No SPDX header on `README.md`.** SPDX-Identifier headers are mandatory on `.rs` and `.dart` source files (project-context.md § Documentation). They are not required on Markdown files; the repo-root `LICENSE` covers documentation.

- [x] **T3 — Refresh `crates/README.md` "Rust Toolchain" section (AC: 6)**
  - [x] Open `/Users/ralph.bergmann/development/projects/privat/Zanshin/crates/README.md`. Locate the `## Rust Toolchain` section (currently lines 63–75).
  - [x] Replace the section body with the short paragraph in AC-6 (one sentence about `rust-toolchain.toml` auto-applying, one sentence pointing at root `README.md` for the bump policy).
  - [x] Remove the `rustup install 1.95.0` + `rustup default 1.95.0` code block — it is now redundant.
  - [x] Remove the line "See Story 1.3 for the permanent `rust-toolchain.toml` pin that will enforce this automatically." — Story 1.3 is now this story; the forward-reference is resolved.

- [x] **T4 — Update `deferred-work.md` (AC: 8)**
  - [x] Open `/Users/ralph.bergmann/development/projects/privat/Zanshin/_bmad-output/implementation-artifacts/deferred-work.md`.
  - [x] Delete the bullet **"Root `rust-toolchain.toml` lacks `components = [\"rustfmt\", \"clippy\"]` and `profile`"** under the "Deferred from: code review of 1-2-..." section.
  - [x] Leave every other entry untouched. The 3 remaining entries (symlink fragility, `app/.gitignore` unused stanzas, Story 1.2 doc inconsistency) plus all 4 entries under the Story 1.1 review section stay as-is — they belong to other stories or are explicitly out-of-scope for 1.3.

- [x] **T5 — Validation sweep (AC: 1, 3, 7)**
  - [x] `rustup show active-toolchain` from repo root → matches AC-3 expected output.
  - [x] `rustup show active-toolchain` from `crates/zanshin-ffi/` → same `(overridden by ...)` line, resolved via the symlink target.
  - [x] `rustup component list --installed | grep -E 'rustfmt|clippy|rust-src'` → all three present (rustup installs them automatically on first cargo invocation after editing the pin).
  - [x] `cargo fmt --all --check` → exit 0 (verifies `rustfmt` component is wired and the existing source files are already formatted).
  - [x] `cargo clippy --workspace --all-targets -- -D warnings` → exit 0 (verifies `clippy` component is wired and no warnings exist on the current skeleton). If clippy flags any existing skeleton file, that is a pre-existing issue (not introduced by 1.3) — fix or report, do not suppress with `#[allow(...)]` (project-context.md § Rust).
  - [x] `cargo build --workspace` → exit 0, zero warnings (Story 1.1 invariant).
  - [x] `cd app && flutter pub get && flutter build macos --debug` → exit 0 (Story 1.2 invariant — toolchain edits must not break the Flutter build).
  - [x] `cd app && dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` → dart format exit 0; dart analyze has pre-existing failures in unrelated cruise feature files (not touched by Story 1.3; no Dart files changed).
  - [x] `git status` from the repo root → only the four files this story touched (`README.md` NEW, `rust-toolchain.toml` EDITED, `crates/README.md` EDITED, `_bmad-output/implementation-artifacts/deferred-work.md` EDITED) are staged/modified. Nothing surprising.

### Review Findings

- [x] [Review][Patch] Missing space in CI-note Markdown — README.md uses `` `subosito/flutter-action@v2`with `` (no space before `with`). Fixed: added space → `` `subosito/flutter-action@v2` with ``. [`README.md:55`]
- [x] [Review][Patch] Parenthetical in YAML scalar value — restored bare-date `last_updated: 2026-05-17`; moved "(Story 1.3 review)" context to the comment header. [`_bmad-output/implementation-artifacts/sprint-status.yaml:44`]
- [x] [Review][Patch] Sprint-status audit-cadence inconsistency — fixed header comment to `(Story 1.3 review)`; added `# Story 1-3 started: 2026-05-17` and `# Story 1-3 reviewed: 2026-05-17` lines to match the 1-1 / 1-2 audit pattern. [`_bmad-output/implementation-artifacts/sprint-status.yaml:2,52-53`]
- [x] [Review][Defer] Stale Flutter/Dart pins in planning artefacts [`_bmad-output/planning-artifacts/architecture.md:76`, `_bmad-output/planning-artifacts/epics.md:625`] — deferred, pre-existing; spec § "Conflict raised + resolved" explicitly defers planning-artefact edits.

## Dev Notes

### What this story is

A toolchain-pin and documentation story. Two-file edit at the load-bearing layer (`rust-toolchain.toml` enriched with `components` + `profile`; new root `README.md` with the human-readable `## Toolchain` section) plus two cleanup edits (`crates/README.md` forward-reference resolved; `deferred-work.md` resolved entry removed). No production code changes. No test changes. No build orchestration changes.

The story closes the deferred item from Story 1.2's code review ("Root `rust-toolchain.toml` lacks `components` and `profile`") and satisfies **FR-BO-7** (toolchain pinned, Flutter/Dart versions documented at repo root). **FR-BO-8** (reproducibility CI two-build SHA diff) is explicitly deferred to the release phase — see project-context.md § Build & Distribution and prd.md § 4.7.

### What this story is NOT

- **NOT writing CI.** Story 1.9 owns `.github/workflows/ci.yml`. Story 1.3's "CI note" in the README is informational — it tells Story 1.9 what action+channel to use, but does not create any YAML.
- **NOT enforcing reproducibility (FR-BO-8).** That is a release-phase concern; Story 1.3 makes it *possible* by pinning, not *automatic*.
- **NOT adding `[workspace.lints]`.** Story 1.7 (lint/format config) owns that. Story 1.3's `clippy` component install is the prerequisite, not the policy.
- **NOT adding `[profile.release]` / `[profile.dev]` customization** (LTO, codegen-units, strip). Release-phase optimization, deferred per `deferred-work.md` § Story 1.1 review.
- **NOT converting the `crates/zanshin-ffi/rust-toolchain.toml` symlink into a regular file.** The symlink fragility item in `deferred-work.md` was deferred deliberately (macOS-only, no `cargo package` workflow). Story 1.3 just rides the carry-through.
- **NOT cleaning up `app/README.md`** (Flutter `create` boilerplate). Cosmetic, outside Story 1.3 scope. The root `README.md` is what gets created.
- **NOT touching `app/pubspec.yaml`.** The Flutter/Dart pins already live there from Story 1.2 (`environment.flutter: ^3.44.0-1.0.pre-573`, `environment.sdk: ^3.13.0-104.0.dev`). Story 1.3 only documents them in the README — the pubspec is the machine-readable source of truth.
- **NOT adding `cargo-make`** (the binary or `Makefile.toml`). Story 1.4 owns that. Story 1.3 only mentions `cargo install cargo-make` in the README install block.

### Files being modified / created

| File | State | Action |
|------|-------|--------|
| `rust-toolchain.toml` | EXISTS (89 bytes, 4 lines) | EDIT — add `components`, `profile` |
| `crates/zanshin-ffi/rust-toolchain.toml` | EXISTS (symlink → `../../rust-toolchain.toml`) | **DO NOT TOUCH** — carry-through |
| `README.md` (repo root) | DOES NOT EXIST | CREATE — minimal intro + `## Toolchain` section |
| `crates/README.md` | EXISTS (3.2 KB) | EDIT — replace `## Rust Toolchain` section with resolved-pointer text |
| `_bmad-output/implementation-artifacts/deferred-work.md` | EXISTS (2.1 KB) | EDIT — remove the one resolved entry |

Total changes: 1 NEW, 3 EDITED, 0 DELETED, 1 INTENTIONALLY UNTOUCHED.

### Conflict raised + resolved: epics.md § Story 1.3 vs. project-context.md (Flutter/Dart pins)

`epics.md` § Story 1.3 (lines 603–660) specifies Flutter `3.41.9` (stable) and Dart `3.11.5` (stable). The actual repo state (Story 1.2 done, 2026-05-17) and `_bmad-output/project-context.md` § Technology Stack both use Flutter `main` channel `^3.44.0-1.0.pre-573` and Dart `main` channel `^3.13.0-104.0.dev`. **The epics.md text is stale.**

**Resolution (per project-context.md's own override rule):** Story 1.3 documents Flutter/Dart `main` channel pins matching the live `app/pubspec.yaml`, not the stale epics.md values. project-context.md § Technology Stack carries the rationale: the Flutter UI scope (Ralph's separate work) targets multi-window APIs that have not landed on a stable Flutter release. Stable pins are not viable until they do.

**Side effects of this resolution:**
- The epics.md `subosito/flutter-action@v2` AC fragment (`flutter-version: '3.41.9'`, `channel: 'stable'`) is also stale. Story 1.3's README "CI note" pre-empts the bug by documenting `channel: 'master'` (the action's name for Flutter `main`). Story 1.9, when it implements the CI, must use the live `app/pubspec.yaml` values and `channel: 'master'`. This story tells Story 1.9 what to do via the README, but does not write YAML.
- The epics.md text itself is not edited by Story 1.3 (epics.md is a planning artefact, not an implementation artefact — editing it during dev would obscure the planning-vs-implementation split). Ralph can decide separately whether to refresh the epics.md text in a planning-doc pass.

This conflict is **raised** here per project-context.md's instruction ("an inconsistency is a bug to fix, not a choice to make silently"), and **resolved** by following project-context.md (which explicitly supersedes architecture.md and, by extension, the stale stable-channel text in epics.md).

### Deferred-work items absorbed by this story

From `_bmad-output/implementation-artifacts/deferred-work.md`:

| Item | Source review | Action in 1.3 |
|------|--------------|---------------|
| Root `rust-toolchain.toml` lacks `components = ["rustfmt", "clippy"]` and `profile` | 1-2 review (2026-05-17) | **ABSORBED** — AC-1 covers verbatim; AC-8 removes the entry |
| Symlink fragility at `crates/zanshin-ffi/rust-toolchain.toml` | 1-2 review (2026-05-17) | **NOT ABSORBED** — out of scope (deferral rationale still holds: macOS-only, no `cargo package` workflow) |
| `app/.gitignore` unused stanzas | 1-2 review (2026-05-17) | **NOT ABSORBED** — cosmetic, unrelated to toolchain pinning |
| Story 1.2 doc internal inconsistency (AC-4 vs Dev Notes) | 1-2 review (2026-05-17) | **NOT ABSORBED** — documentation-only, doc pass concern |
| All four Story 1.1 review entries (NOTICE, `[workspace.lints]`, `[profile.*]`, xtask default-members) | 1-1 review (2026-05-17) | **NOT ABSORBED** — each is explicitly owned by a different story or the release phase |

### Pre-existing repo state (verified at story-write time, 2026-05-17)

- **`rust-toolchain.toml`** (root) exists with channel + targets, missing `components` + `profile`. Committed by Story 1.2 (e8d1a40) as a side-effect of getting `native_toolchain_rust` to pick a toolchain when its CWD is the crate dir.
- **`crates/zanshin-ffi/rust-toolchain.toml`** is a symlink to `../../rust-toolchain.toml`. Editing the root file propagates automatically.
- **No `README.md`** at the repo root. `crates/README.md` and `app/README.md` exist (the latter is the unedited `flutter create` boilerplate).
- **`app/pubspec.yaml`** already pins Flutter `^3.44.0-1.0.pre-573` and Dart `^3.13.0-104.0.dev` (Story 1.2 final state).
- **Locally installed toolchains** (verified by `rustc --version`, `flutter --version`, `dart --version`): `rustc 1.95.0`, `cargo 1.95.0`, `Flutter 3.44.0-1.0.pre-573 channel main`, `Dart 3.13.0-104.0.dev`. Toolchain matches the pins — the dev agent will not have to install anything new.

### Why `components = ["rustfmt", "clippy", "rust-src"]` (not just `["rustfmt", "clippy"]`)

`rust-src` is a near-zero-cost addition that makes `rust-analyzer` work out of the box (it needs the standard-library source for type-resolution and "go to definition" into `std`). The defer rationale in deferred-work.md only called out `rustfmt` + `clippy` because those are CI-blocking; `rust-src` is a dev-ergonomics improvement that costs ~50MB on disk and is a one-time `rustup` download. Including it here keeps the components list editable from one place rather than asking every contributor to `rustup component add rust-src` separately. If `rust-src` ever becomes a problem (e.g., breaks `rustup` on a tier-2 target), drop it in a one-line PR — it has no downstream code dependencies.

### Why `profile = "minimal"`

`rustup` `profile = "minimal"` installs only `rustc`, `rust-std`, and `cargo` by default — no `rust-docs`, no `clippy`, no `rustfmt`. Combined with the explicit `components` list, this gives a lean, predictable install with exactly what the project needs. The default profile (`default`) installs `rust-docs` too (~200 MB), which is wasted disk for this project (we don't read offline `std` docs; `cargo doc --open` works fine on the network-online developer machine). `minimal` + explicit `components` is the modern-rustup idiom for reproducibility.

### Why the README is created at repo root (not just edited)

Currently there is no root `README.md`. GitHub renders the root README on the repo's home page. Even for a solo-OSS WIP project, a 50-line README with project intro + toolchain pins is the minimum that prevents the embarrassing "no README" empty-page on the GitHub home view. The "Toolchain" section is the primary load-bearing content (FR-BO-7 satisfaction); the intro sentence is a soft requirement so the file isn't naked.

Per memory `feedback_slim_prd`: solo-OSS, no contribution-guide / badges / roadmap ceremony. Keep it lean.

### Why the `dtolnay/rust-toolchain@master` CI hint (not `@stable` as in epics.md)

The epics.md AC mentions `dtolnay/rust-toolchain@stable`. That action's `@stable` ref pins the *action version* to its `stable` branch, but more importantly the action's input semantics matter: passing no `toolchain:` input makes the action read `rust-toolchain.toml` — which is what the project wants. `@master` and `@stable` both behave identically for the file-read path; either works. The README uses `@master` as a generic recommendation; Story 1.9 will pick whichever ref the GitHub Actions ecosystem favours at the time the CI workflow is authored. Story 1.3 just makes sure the file *exists* and is *readable* by either ref.

### What "Bump policy" means in practice (README "Why these versions" block)

A Rust pin bump (`1.95.0` → `1.97.0`) is a one-line `channel = "..."` edit, but the commit needs a `# WHY:` rationale (e.g., "needed for `let-chains` stabilization in `zanshin-jj`" or "security patch CVE-2026-XXXXX"). The PR review checks:
- All clippy warnings on the new compiler are fixed in the same PR (not allowed to defer).
- CI green on the new toolchain.
- Once release-phase reproducibility CI lands (FR-BO-8), byte-identical artefact diff passes.

In WIP, item 3 is informal (code-review eyeball). The README doesn't need to spell all this out — one sentence "bumps are explicit PRs with a # WHY: rationale" is enough; the project-context.md already carries the full discipline.

### Forward-reference cleanup pattern

`crates/README.md` § Rust Toolchain (lines 63–75) is a *forward reference* — it says "Story 1.3 will enforce this". Once Story 1.3 lands, that forward-reference becomes confusing time-travel. The cleanup pattern: replace the forward reference with a *backward pointer* ("see the root README's Toolchain section for the policy"). This is a small lift; AC-6 codifies it.

### Project Structure Notes

- Alignment with project-context.md § Project Structure Anchors: `rust-toolchain.toml` at workspace root is the canonical location (architecture.md § P-9-style directory tree puts it there). The symlink at `crates/zanshin-ffi/rust-toolchain.toml` was a Story-1.2 implementation choice driven by `native_toolchain_rust`'s `cargo` CWD behaviour; it stays.
- README at workspace root: standard convention. No deviation.
- `_bmad-output/implementation-artifacts/deferred-work.md` is the canonical "review-raised-but-defer" registry (established by Story 1.1's code review). Story 1.3 edits remove a resolved entry; the registry format is preserved.

### References

- [Source: _bmad-output/planning-artifacts/epics.md § Story 1.3 (lines 603–660)] — original AC text; this story restates ACs in WIP-aligned form and raises the Flutter/Dart pin conflict.
- [Source: _bmad-output/planning-artifacts/epics.md § Story 1.4 edge case (line 719)] — confirms the README must list `cargo install cargo-make` as a one-time prerequisite (covered in AC-5).
- [Source: _bmad-output/planning-artifacts/prd.md § FR-BO-7 (line 270)] — "Toolchain pinned: `rust-toolchain.toml` for Rust, Flutter/Dart versions documented at repo root. CI pulls exactly these versions." P0.
- [Source: _bmad-output/planning-artifacts/prd.md § FR-BO-8 (line 271)] — "Reproducibility (two-build SHA diff in CI). P1 (deferred — release phase)." Out of Story 1.3 scope.
- [Source: _bmad-output/planning-artifacts/architecture.md § "Toolchain pins" (line 159–162)] — "`rust-toolchain.toml` → Rust 1.95.0 / Flutter / Dart pinned via README (no FVM)".
- [Source: _bmad-output/planning-artifacts/architecture.md § Directory tree (line 387)] — `rust-toolchain.toml` at workspace root.
- [Source: _bmad-output/project-context.md § Technology Stack] — Flutter `main` channel ≥ `3.44.0-1.0.pre-573` rationale (multi-window UI requirement); Dart bundled in lockstep; Rust `1.95.0` pin.
- [Source: _bmad-output/project-context.md § Build & distribution] — `cargo-make` listed as the single build entry point; reproducibility deferred to release phase.
- [Source: _bmad-output/project-context.md § Documentation] — SPDX header rule applies to `.rs` / `.dart`, not Markdown.
- [Source: _bmad-output/implementation-artifacts/1-2-initialize-flutter-macos-package-with-dart-hooks-wiring.md § AC-2 (line 22–23)] — establishes `app/pubspec.yaml` Flutter/Dart pins.
- [Source: _bmad-output/implementation-artifacts/deferred-work.md § Story 1.2 review (line 15)] — "Root `rust-toolchain.toml` lacks `components` and `profile`" — directly absorbed by AC-1 / AC-8.
- [Source: crates/README.md § Rust Toolchain (lines 63–75)] — stale forward-reference to be replaced per AC-6.
- [Source: rust-toolchain.toml (current 4-line state)] — file to be edited per AC-1.
- [Source: app/pubspec.yaml (lines 7–9)] — live source of truth for Flutter/Dart pins documented in README per AC-5.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- `dart analyze` has pre-existing failures in `app/lib/src/features/my_cruise/presentation/cruise_plan_carousel.dart` (undefined getters on generated asset class). Story 1.3 touches zero Dart files; `dart format` exits 0; `flutter build macos --debug` exits 0. Pre-existing issue, not introduced by this story.

### Completion Notes List

- T1: `rust-toolchain.toml` updated with `components = ["rustfmt", "clippy", "rust-src"]` and `profile = "minimal"`. Symlink at `crates/zanshin-ffi/rust-toolchain.toml` carries through unchanged (`readlink` confirmed). Both `rustup show active-toolchain` calls (root + `crates/zanshin-ffi/`) print correct `(overridden by ...)` line. `cargo build --workspace` exit 0 zero warnings. `cargo fmt --all --check` exit 0. `cargo clippy --workspace --all-targets -- -D warnings` exit 0.
- T2: Root `README.md` created with 1-sentence project intro, `## Toolchain` table (Rust/Flutter/Dart pins), "Why these versions" subsection, "One-time install" code block with `rustup.rs` and `flutter.dev` links + `cargo install cargo-make`, "CI note" paragraph, and `## Project documentation` pointer. No SPDX header. No badges.
- T3: `crates/README.md` `## Rust Toolchain` section replaced — forward reference to Story 1.3 removed; now points to root `README.md` for bump policy. Redundant `rustup install/default` snippet removed.
- T4: Resolved entry "Root `rust-toolchain.toml` lacks `components = [\"rustfmt\", \"clippy\"]` and `profile`" deleted from `deferred-work.md`. All other entries (7 remaining) untouched.
- T5: All Rust validation green. `flutter build macos --debug` exit 0. `dart format` exit 0. `dart analyze` pre-existing failures noted above; not caused by Story 1.3.

### File List

- `rust-toolchain.toml` — EDITED (added `components`, `profile`)
- `README.md` — CREATED (repo root; project intro + Toolchain section)
- `crates/README.md` — EDITED (replaced stale `## Rust Toolchain` forward-reference)
- `_bmad-output/implementation-artifacts/deferred-work.md` — EDITED (removed resolved entry)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — EDITED (status tracking)

## Change Log

- 2026-05-17: Story implemented by claude-sonnet-4-6. `rust-toolchain.toml` enriched with `components` + `profile`; root `README.md` created with `## Toolchain` section; `crates/README.md` forward-reference resolved; `deferred-work.md` resolved entry removed. All Rust CI gates green. FR-BO-7 satisfied.

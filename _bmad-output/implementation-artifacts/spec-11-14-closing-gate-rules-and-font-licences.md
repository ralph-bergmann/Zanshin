---
title: 'Story 11.14 closing run — pubspec-checked gate rules and the fonts'' OFL texts in the notices'
type: 'chore'
created: '2026-10-17'
status: 'done'
baseline_revision: 'f2d503ed2da33c310fdd320fe1065dba703e8fef'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The Shippori Mincho subset lost the name table's licence description and licence URL (name IDs 13 and 14), so the two shipped TTFs carry only their copyright line.
    evidence: |-
      Closing run of Story 11.14, 2026-10-17: a name-table read of packages/zanshin_ui/assets/fonts/Shippori_Mincho/ShipporiMincho-{Medium,SemiBold}.ttf finds only name IDs 0-6 (pyftsubset's default --name-IDs, SUBSET.txt records the command), while Inter and JetBrains Mono keep IDs 13/14. With the OFL texts in the bundle's NOTICES (item 2 of this run) the licence still ships with the app; OFL-FAQ 2.4/2.8 ask a modified font to keep its licence metadata.
    location: >-
      packages/zanshin_ui/assets/fonts/Shippori_Mincho/
    severity: low
  - summary: >-
      The fonts' OFL entries in the NOTICES belong to no package, so a licence page (LicensePage, showAboutDialog) would not list them.
    evidence: |-
      Review pass 2026-10-17 (edge-case hunter, blind hunter): the three OFL.txt files are CRLF (git ls-files --eol: i/crlf w/crlf); flutter_tools appends them raw and Flutter's runtime parser (packages/flutter/lib/src/services/binding.dart _parseLicenses) splits a chunk's package names at the first "\n\n", finds none and files the text under no package. The texts are in NOTICES.Z, so the OFL containment condition holds; the app has no licence page, and before this run the texts were not in the NOTICES at all, so the missing attribution predates the change.
    location: >-
      packages/zanshin_ui/assets/fonts/*/OFL.txt; packages/zanshin_ui/pubspec.yaml flutter.licenses
    severity: low
  - summary: >-
      The app bundles Yaru's Ubuntu and Ubuntu Mono fonts without the Ubuntu Font Licence in its NOTICES.
    evidence: |-
      Review pass 2026-10-17 (blind hunter), verified: app/build/unit_test_assets/FontManifest.json lists packages/yaru/Ubuntu and packages/yaru/UbuntuMono; the gunzipped NOTICES.Z holds no "UBUNTU FONT LICENCE". Ralph's fork has ../yaru.dart/assets/fonts/LICENCE.txt but no flutter: licenses: entry. UFL 1.0 asks every copy to carry the notice and the licence. Pre-existing; Story 11.10 retires Yaru.
    location: >-
      ../yaru.dart/pubspec.yaml (Ralph's fork); app/pubspec.yaml yaru dependency
    severity: medium
---

<intent-contract>

## Intent

**Problem:** (1) `crates/xtask/src/tasks/gate_plan.rs` `RULES` lists each Dart package's dependents by hand and no test checks them against the pubspecs, so a new `path:` dependency (11.11 adding one to `zanshin_ui`) makes the change-aware gate under-plan silently. (2) The OFL texts of Inter, JetBrains Mono and Shippori Mincho never reach the app bundle: verified 2026-10-17, the name tables of Inter and JetBrains Mono carry only the copyright, a one-line licence notice and a URL, and the Shippori subset only its copyright; nothing puts `OFL.txt` into `NOTICES.Z`. OFL §2 requires each bundled copy to contain the copyright notice and the licence (OFL-FAQ 1.20: an app must include the licence text).

**Approach:** (1) An inline xtask test reads the `path:` dependencies of `app/pubspec.yaml` and `packages/*/pubspec.yaml`, follows them transitively and asserts that every package's rule plans exactly its own steps plus those of every package depending on it; member pubspecs plan every step so the test runs when a dependency changes. (2) `packages/zanshin_ui/pubspec.yaml` lists the three `OFL.txt` files under `flutter: licenses:`, which flutter_tools appends verbatim to the NOTICES of every app depending on the package; an app test pins it.

## Boundaries & Constraints

**Always:**
- Test placement per CLAUDE.md: the gate-plan test inline in `gate_plan.rs`'s `mod tests` (it reads repo files via `env!("CARGO_MANIFEST_DIR")/../..`, like the `Makefile.toml` test); the notices test in `app/test/assets/`.
- The OFL.txt files stay byte-for-byte unchanged; the licence text is never copied into a second file.
- SPDX first line on new Dart files; page width 120; `dart analyze --fatal-infos --fatal-warnings` / `dart format` clean; clippy pedantic `-D warnings` clean for `--all-targets`.
- `cargo make test` runs from the main session only, never from a subagent.

**Never:**
- No new crate dependency (no YAML parser) — `xtask` parses the few `path:` lines itself.
- No `LicenseRegistry.addLicense` call, no `LICENSE` file in `packages/zanshin_ui`, no licence page or About box, no font binary regenerated.
- No change to `RULES` entries other than the new member-pubspec rule; no change to the 11.14 spec, `deferred-work.md`'s existing bullets, `epic-11-context.md`, `epics.md`, `sprint-status.yaml` or `project-context.md`.
- No `coverage-baseline.txt` lowering or `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Rules match the pubspecs | today's tree | the dependents test passes for all 7 members | — |
| New path dependency, rules not updated | e.g. `zanshin_core: path: ../zanshin_core` in `packages/zanshin_ui/pubspec.yaml` | the test fails naming `packages/zanshin_core` and the missing UI steps | assertion message names the member and its dependents |
| New member without own steps | `packages/x/pubspec.yaml` exists, no entry in the test's own-steps table | the test fails telling to add gate steps, a rule and the table entry | panic message |
| Path outside the repo / not a member | `yaru: path: ../../yaru.dart`; `- path: assets/icons/svg/`; a `#` comment | ignored | — |
| A member pubspec changes | `app/pubspec.yaml`, `packages/zanshin_ui/pubspec.yaml` | `plan_for` plans every step (label names the reason) | — |
| App bundle notices | `flutter test` / `flutter build macos --debug` in `app/` | `NOTICES.Z` (gzip) contains each `packages/zanshin_ui/assets/fonts/<font>/OFL.txt` verbatim | — |

</intent-contract>

## Code Map

- `crates/xtask/src/tasks/gate_plan.rs:80-92` group consts (`APP`, `CORE`, `SETTINGS`, `SHELL*`, `UI`); `:127-255` `RULES` (first match wins; docs block first, `spikes/` → Nothing at `:151`; toolchain block `:158-179` with `Exact("pubspec.yaml")`/`Exact("pubspec.lock")` → Everything; package rules `:223-254`); `:257` `classify`; `:279` `plan_for`.
- Same file, tests: `:534` `steps()` helper; `:545` `a_flutter_package_plans_itself_and_every_package_depending_on_it` (hand-coded for shell_pi — becomes the pubspec-derived test); `:575` `every_package_zanshin_ui_depends_on_plans_zanshin_ui_and_the_app` (the four hand-coded paths — removed, subsumed); `:614` `manifests_toolchains_and_the_gate_itself_plan_everything` (add member pubspecs); `:696` reads `Makefile.toml` through `CARGO_MANIFEST_DIR` (pattern to copy). `crates/xtask/` is excluded from coverage; its tests run inside `coverage` (`cargo llvm-cov --workspace`, `Makefile.toml:715-718`).
- Pubspecs today: `app` → core, settings, shell, ui (+ dev shell_pi; `yaru: path: ../../yaru.dart` outside the repo); `zanshin_ui` → settings, shell (+ `- path: assets/icons/svg/` asset entry); `zanshin_shell` → shell_macos, shell_pi; `zanshin_shell_macos` → shell_pi; core, settings, shell_pi → none. The current rules equal own ∪ dependents for every member. Workspace members: root `pubspec.yaml` `workspace: [app, packages/*]`; `spikes/*/dart/pubspec.yaml` are not members.
- `packages/zanshin_ui/pubspec.yaml` `flutter:` section (assets, fonts) -- gets `licenses:`. Font folders `packages/zanshin_ui/assets/fonts/{Inter,JetBrains_Mono,Shippori_Mincho}/OFL.txt` (identical OFL 1.1 body, each headed by its copyright line).
- flutter_tools (`~/development/sdks/flutter/packages/flutter_tools/lib/src/`): `flutter_manifest.dart:240` `additionalLicenses` (`flutter: licenses:` list of package-relative paths); `asset.dart:440-485` collects them from every transitive dependency (containment check: paths must stay in the package); `license_collector.dart:89-129` appends each file raw, joined by the 80-hyphen separator, into `NOTICES` (gzip'd as `NOTICES.Z`). `flutter test` builds the same bundle (`app/build/unit_test_assets/NOTICES.Z` exists).
- flutter_test `binding.dart:1308` `initLicenses()` is a no-op in tests, so `LicenseRegistry.licenses` is empty there — the test reads `NOTICES.Z` through `rootBundle` and `gzip.decode`s it (as `services/binding.dart:207-216` does).
- `app/test/assets/font_manifest_test.dart` -- `_bundledFonts()` reads `FontManifest.json` (family → asset paths `packages/zanshin_ui/assets/fonts/<dir>/<file>`); the notices test joins it.

## Tasks & Acceptance

**Execution:**
- `crates/xtask/src/tasks/gate_plan.rs` -- add a rule `Suffix("/pubspec.yaml")` (label: a Dart package's dependencies, read by the dependents test) → `Need::Everything` in the toolchain block after `pubspec.lock`; extend the RULES comment above the package rules to say the pubspecs check them. Tests: replace the body of `a_flutter_package_plans_itself_and_every_package_depending_on_it` with the pubspec-derived check (members = `app` + every `packages/*/` with a `pubspec.yaml`; a test-local own-steps table member → group const; `path:` values from non-comment lines, cut at `,` `}` space `#`, quotes stripped, resolved lexically against the member dir, kept only when they name a member; transitive dependents; expected = own ∪ dependents' own in `ALL_STEPS` order == `steps(classify("<member>/lib/a.dart"))`; a member without a package rule or without a table entry, or a table entry that is no member, fails with a message saying what to add); delete `every_package_zanshin_ui_depends_on_plans_zanshin_ui_and_the_app`; add `app/pubspec.yaml` and `packages/zanshin_ui/pubspec.yaml` to the plan-everything test and `spikes/ffi-payload-bench/dart/pubspec.yaml` (still `Nothing`) to `docs_need_nothing_except_the_ones_tests_read`.
- `app/test/assets/font_manifest_test.dart` -- add a test: for every font asset of a `packages/zanshin_ui/` family in `FontManifest.json`, the `OFL.txt` in that asset's folder (read from `../packages/zanshin_ui/assets/fonts/<dir>/OFL.txt`) occurs verbatim in the gunzipped `NOTICES.Z`. Run it before the pubspec change to see it fail.
- `packages/zanshin_ui/pubspec.yaml` -- `flutter: licenses:` with the three `assets/fonts/<font>/OFL.txt` paths and a `# WHY:` (OFL §2: every bundled copy carries the copyright and licence; the TTF name tables hold only a link — Shippori's subset not even that; flutter_tools appends these files to the NOTICES of every app depending on the package).

**Acceptance Criteria:**
- Given the current tree, when `cargo test -p xtask gate_plan` runs, then every gate-plan test passes, and with a scratch `zanshin_core: path: ../zanshin_core` added to `packages/zanshin_ui/pubspec.yaml` (reverted afterwards) the dependents test fails naming `packages/zanshin_core`.
- Given a changed `app/pubspec.yaml` or `packages/<name>/pubspec.yaml`, when `cargo xtask gate-plan` plans, then it plans every step; `spikes/*/dart/pubspec.yaml` still plans nothing.
- Given `flutter test` in `app/`, when the notices test runs, then it passes, and it failed before the `licenses:` entry was added.
- Given `flutter build macos --debug` in `app/`, when the bundle's `NOTICES.Z` is gunzipped, then it contains the three OFL texts with their copyright lines.
- Given the change, when `cargo make test` runs unpiped from the main session, then it exits 0 and `coverage-baseline.txt` is not lowered.

## Spec Change Log

## Review Triage Log

### 2026-10-17 — Review pass
- verdicts: 32 findings — high 0, medium 8, low 19, false 5, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap 1) The notices test reads a stale `app/build/unit_test_assets/NOTICES.Z`: `flutter test` rewrites that bundle only when the app's own pubspec or a file-backed asset is newer (`commands/test.dart` `_needsRebuild`; NOTICES.Z is not file-backed), so removing a `licenses:` entry stays green in the gate — patched: `Makefile.toml` `test-flutter` deletes `build/unit_test_assets/AssetManifest.bin` before `flutter test` (WHY comment); the test's comment and hint now say the gate always rebuilds and the delete hint is for manual runs.
  - `[low]` `[reject]` (intent 1) No test runs the whole chain pubspec change → full plan → failing test → no stamp — each link is pinned (`manifests_toolchains_…` for the rule, `Plan::Full` = `ALL_STEPS`, `every_grouped_step_…` for `gate-coverage` in the flow, `cargo llvm-cov --workspace` runs xtask's tests); an end-to-end gate-flow test is out of proportion.
  - `[false]` `[reject]` (intent 2) Equality instead of "at least" makes a deliberate extra step fail — intended and documented (Design Notes); a deliberate extra step belongs in its own rule.
  - `[low]` `[reject]` (intent 3) The member-pubspec rule raises gate cost and its suffix is broader than member pubspecs — grouped with blind 6; rejected there.
  - `[low]` `[reject]` (intent 4) `OWN_STEPS` is not checked against the `Makefile.toml` tasks of each package — a wrong own group passes only with an equally wrong rule; checking it means parsing task `cwd`s, more code than the risk.
  - `[false]` `[reject]` (intent 5) The hosted `path: ^1.9.1` dependency is parsed as a path value — it resolved to no member and was dropped; the name-based reader (edge 1) no longer reads `path:` at all.
  - `[low]` `[patch]` (intent 6) Members come from a glob, not from the root `workspace:` list — grouped with edge 3; patched there.
  - `[low]` `[reject]` (intent 7) The test reads the `flutter test` bundle's NOTICES, not the macOS app's — both come from the same `AssetBundle.build`; this run gunzipped the debug app's `NOTICES.Z` too; a macOS build in the gate is out of proportion.
  - `[medium]` `[patch]` (intent 8) The test can pass against stale data — grouped with verification-gap 1; patched there.
  - `[low]` `[reject]` (intent 9) The test needs an `OFL.txt` in every zanshin_ui font folder — grouped with edge 7; rejected there.
  - `[false]` `[reject]` (intent 10) The Auto Run Result and the ledger mirror are missing — they are written at finalize, in the spec's commit.
  - `[medium]` `[patch]` (edge 1) A version-only dependency on a member (`zanshin_core: any`) is an edge the `path:` reader cannot see; pub resolves a workspace member's name to the member whatever the source (dart.dev/tools/pub/workspaces) — patched: edges are the first-level keys of `dependencies:`/`dev_dependencies:` that name a member (`dependencies()`, `package_name()`); `resolve`/`path_dependencies` removed; RULES comment reworded; parser test `dependencies_are_first_level_member_keys_whatever_their_source`.
  - `[low]` `[patch]` (edge 2) An absolute `path:` is resolved under the member dir and the edge dropped — grouped with edge 1's fix: no path resolution is left.
  - `[low]` `[patch]` (edge 3) A member the root `workspace:` list adds outside `app`/`packages/*` is never checked — patched: `dart_members` reads the root list (`/*` = subdirectories with a pubspec); `the_members_are_the_workspace_entries_holding_a_pubspec`.
  - `[false]` `[reject]` (edge 4) A `pubspec_overrides.yaml` could add a path dependency unseen — overrides change the source of a dependency already declared, they add no edge; edges are read by name whatever the source.
  - `[medium]` `[patch]` (edge 5) A removed `licenses:` entry stays green on the stale bundle — grouped with verification-gap 1; patched there.
  - `[low]` `[reject]` (edge 6) `File('../$folder/OFL.txt')` relies on the asset key matching the repo folder and on the `app/` cwd — `flutter test` always runs in the package dir; a moved package fails loudly (PathNotFoundException); resolving the package root adds code for a rare move.
  - `[low]` `[reject]` (edge 7) A font folder without `OFL.txt` throws a bare FileSystemException — a loud failure; no non-OFL font is planned; a guard only rewords it.
  - `[low]` `[defer]` (edge 8) The CRLF OFL files carry no `\n\n` header, so Flutter's runtime parser files them under no package and a licence page would not list them — the missing attribution predates this change (the texts were not in the NOTICES at all); no licence page exists; deferred and mirrored. The Design Notes' "titled by its copyright line" is wrong for that reason (corrected there).
  - `[low]` `[patch]` (edge 9) The negative test's ui→core edge is a real pair that could become legitimate — patched: `zanshin_core` gets `zanshin_ui: any` (core is pure Dart, never legitimate).
  - `[medium]` `[patch]` (edge 10) The "app test pins it" claim does not hold on a stale bundle — grouped with verification-gap 1; patched there.
  - `[medium]` `[patch]` (blind 1) The dependents test sees only `path:` dependencies while pub resolves members by name — grouped with edge 1; patched there.
  - `[low]` `[patch]` (blind 2) The member set is hard-coded, not read from the root `workspace:` list — grouped with edge 3; patched there.
  - `[medium]` `[patch]` (blind 3) The NOTICES test gives a false green after a `licenses:` removal — grouped with verification-gap 1; patched there.
  - `[low]` `[defer]` (blind 4) CRLF OFL files lose their package attribution in Flutter's parser; the Design Note is wrong — grouped with edge 8; deferred there.
  - `[medium]` `[defer]` (blind 5) The app bundles Yaru's Ubuntu fonts without the Ubuntu Font Licence in its NOTICES — verified (FontManifest lists `packages/yaru/Ubuntu*`, NOTICES has no UFL text); pre-existing and outside this run's items; Story 11.10 retires Yaru; deferred and mirrored.
  - `[low]` `[reject]` (blind 6) `Suffix("/pubspec.yaml")` also catches nested pubspecs (an `example/` app, a fixture) under a label naming the dependents test — none exists in the repo; the effect is over-planning (fail-safe); a depth-checked pattern adds a `Pattern` variant for a case that does not occur.
  - `[low]` `[patch]` (blind 7) Dev dependencies were followed past the first hop, which would force the app's steps onto a member a library only dev-depends on — patched: `reached()` takes a member's regular and dev dependencies, then regular ones only.
  - `[low]` `[patch]` (blind 8) The negative test covered only the "missing" branch — patched: it also asserts the "unexpected" branch (zanshin_settings dropped from zanshin_ui) and the stale `OWN_STEPS` entry (a deleted member pubspec).
  - `[false]` `[reject]` (blind 9) `path: ^1.9.1` is parsed as a path source; a block form would self-edge — the value resolved to no member, a self-edge is excluded by `other != member`; the path reader is gone (edge 1).
  - `[low]` `[reject]` (blind 10) The asset-key-to-folder mapping and the hard-coded `OFL.txt` are coincidental — grouped with edge 6; rejected there.
  - `[low]` `[patch]` (blind 11) The gate docs miss that a member pubspec now plans every step — `docs/coverage.md`'s exhaustive "only when" list patched ("a Dart package's `pubspec.yaml`"); `CLAUDE.md`/`project-context.md` summarise ("root manifests … run everything" never listed crate manifests either), so they stay.

## Design Notes

**Why equality, not "at least".** The RULES comment promises "the package plus every package depending on it"; asserting equality checks that promise in both directions and keeps the old test's "no Rust step for a pure Flutter package" for free. A deliberate extra step for a package would need its own rule entry anyway.

**Why member pubspecs plan everything.** The new test lives in xtask and runs inside `coverage`, which a `packages/zanshin_ui/` change (UI + APP) never plans; an intra-workspace `path:` dependency does not touch `pubspec.lock`. Like `crates/<name>/Cargo.toml` (`CrateManifest`), a Dart manifest changes which packages a change reaches, so it plans every step. Cost: a full run when a member pubspec changes — rare.

**Why `flutter: licenses:`.** It is flutter_tools' own channel for a package's third-party licences: declarative, collected from every transitive dependency, no runtime code, no duplicated text. A `LICENSE` file at the package root would also be collected but would declare the OFL as `zanshin_ui`'s own licence (the code is MIT) or need a copy of the text; `LicenseRegistry.addLicense` needs the texts as assets plus a boot-time call. Display note: the runtime parser takes a chunk's first paragraph as its package names, so a future licence page would title each OFL entry by its copyright line — cosmetic, no page exists. Correction (review): the OFL files are CRLF, so the parser finds no `\n\n`, files each text under no package and a licence page would not list them at all — deferred to the story that adds one.

## Verification

**Commands:**
- `cargo test -p xtask gate_plan` -- all pass; the scratch-dependency mutation makes the dependents test fail, reverted afterwards.
- `flutter test test/assets` in `app/` -- passes; fails before the pubspec change.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` and `packages/zanshin_ui/` -- clean.
- `flutter build macos --debug` in `app/`, then `python3 -c 'import gzip,sys;print(gzip.decompress(open(sys.argv[1],"rb").read()).decode())' app/build/macos/Build/Products/Debug/zanshin.app/Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z` -- contains "SIL OPEN FONT LICENSE Version 1.1" three times with the Inter, JetBrains Mono and Shippori copyright lines.
- `cargo make test` (repo root, unpiped, main session; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`) -- the xtask change plans every step; past the Bash 10-min cap run it detached into a scratch log and poll for the `EXIT=` line -- expected `EXIT=0`.

## Auto Run Result

Status: done (2026-10-17). Blocking condition: none.

**Items handed to this closing run.**
1. **Gate-plan rules unchecked against the pubspecs — fixed** (commit `cc8f353e219114773ff9af4096e67738858af317`).
   - The inline test `a_flutter_package_plans_itself_and_every_package_depending_on_it` now derives each Dart member's dependents from the pubspecs and asserts that its RULES entry plans exactly its own steps plus theirs.
     - Members come from the root `workspace:` list.
     - Edges are dependency keys that name a member, whatever their source.
     - Dev dependencies count only on the first hop.
   - The hand-coded `every_package_zanshin_ui_depends_on_plans_zanshin_ui_and_the_app` is gone.
   - A changed member pubspec (`Suffix("/pubspec.yaml")`) now plans every step, so the test runs whenever a dependency changes.
2. **OFL texts missing from the app's notices — fixed** (commit `4795404859501b7d4b83a56edff90dd7b0e4f29d`).
   - The name tables fall short of OFL §2:
     - Inter and JetBrains Mono carry only the copyright, a one-line notice and a URL.
     - The Shippori subset carries only its copyright.
     - OFL-FAQ 1.20: an app must include the licence text.
   - `packages/zanshin_ui/pubspec.yaml` lists the three `OFL.txt` under `flutter: licenses:`, and flutter_tools appends them to the NOTICES of every app that depends on the package. An app test pins this.
   - Neither ledger option was used:
     - a `LICENSE` file would declare the OFL as the MIT package's own licence;
     - `LicenseRegistry.addLicense` needs assets plus a boot-time call.

**Summary.** Two fixes, one per item. `gate_plan.rs` gained a pubspec-derived check of its package rules, three tests around it (a mutated copy of the real workspace, the dependency reader, the member list) and the member-pubspec rule. `zanshin_ui` ships its fonts' OFL texts through `flutter: licenses:`. The gate's `test-flutter` step forces a fresh test bundle, so the notices test cannot pass on a stale `NOTICES.Z`.

**Files changed:**
- `crates/xtask/src/tasks/gate_plan.rs` — the member-pubspec rule, the RULES comment, and the derived dependents check with its fixture, parser and member tests; the hand-coded test is removed.
- `docs/coverage.md` — a Dart package's pubspec is now among the changes that run coverage.
- `packages/zanshin_ui/pubspec.yaml` — `flutter: licenses:` with the three OFL.txt files.
- `app/test/assets/font_manifest_test.dart` — new test: the bundle's NOTICES.Z holds every bundled zanshin_ui font's OFL.txt verbatim.
- `Makefile.toml` — `test-flutter` deletes `build/unit_test_assets/AssetManifest.bin` before `flutter test`.
- Tracking: this spec; `deferred-work.md` gets the section "Surfaced in the closing run of Story 11.14" (3 items).

**Review findings.** 32 findings (high 0, medium 8, low 19, false 5).
- **Patched, 8 entries:**
  - stale test bundle (medium; verification-gap 1, intent 8, edge 5 and 10, blind 3);
  - dependency edges read by name instead of `path:` (medium; edge 1, blind 1);
  - no path resolution left, so absolute paths are no issue (low);
  - members from the root `workspace:` list (low);
  - dev dependencies only on the first hop (low);
  - the negative test covers the "unexpected" branch and stale `OWN_STEPS` entries (low);
  - a fixture edge that can never be legitimate (low);
  - `docs/coverage.md` (low).
- **Deferred and mirrored, 3:**
  - the Shippori subset lost name IDs 13/14 (low; found while planning);
  - the CRLF OFL texts sit under no package in Flutter's licence parser, so a future licence page would not list them (low; predates the change);
  - Yaru's Ubuntu fonts ship without the Ubuntu Font Licence in the NOTICES (medium; pre-existing; Story 11.10 retires Yaru).
- **Rejected, low:**
  - no end-to-end gate-flow test (each link is pinned);
  - `OWN_STEPS` is not checked against the Makefile `cwd`s (needs a matching wrong rule to pass);
  - the unit-test bundle stands in for the macOS bundle (same `AssetBundle.build`; the debug app was checked by hand);
  - the asset-key-to-folder path and the hard-coded `OFL.txt` (loud failures on rare changes);
  - nested pubspecs also plan every step (none exists; it only over-plans).
- **False, 5:**
  - equality versus "at least" (intended);
  - the hosted `path: ^1.9.1` (2 rows; it resolved to no member, and the path reader is gone);
  - `pubspec_overrides.yaml` adds no edge;
  - the Auto Run Result and ledger mirror are written here.
- The Design Notes' display note was corrected: the CRLF texts get no package at all, rather than being titled by their copyright line.

**Follow-up review recommendation:** true. This first pass patched 2 medium entries (and 6 low, 0 high). The named unverified risk: during review the dependency reader (`dependencies()`, `dart_members()`, `package_name()`) was rewritten as a hand-rolled line reader of YAML. A second pass could check it against the pubspec forms pub accepts: quoted keys, odd indentation, a `workspace:` entry with a glob other than a trailing `/*`. Every one of those forms is absent from today's pubspecs.

**Verification:**
- `cargo test -p xtask gate_plan`: 15 passed.
  - A scratch `zanshin_core: path: ../zanshin_core` in zanshin_ui's pubspec made the dependents test fail, naming `packages/zanshin_core` and the missing `test-ui*` steps (reverted).
  - A scratch extra member made it fail with the "add its steps" message (removed).
  - The fixture test now pins both kinds of drift permanently.
- `cargo clippy -p xtask --all-targets -- -D warnings` and `cargo fmt --check -p xtask`: clean.
- Notices test:
  - It failed before the `licenses:` entry and passed after.
  - `flutter test`: app 66 passed; zanshin_ui 141 passed.
  - `cargo make --allow-private test-flutter` rebuilt the test bundle (`AssetManifest.bin` mtime moved).
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` in `app/` and `packages/zanshin_ui/`: clean.
- Debug app (`flutter build macos --debug`): the bundle's gunzipped `NOTICES.Z` holds "SIL OPEN FONT LICENSE Version 1.1" three times with the Inter, JetBrains Mono and Shippori copyright lines, and each OFL.txt byte for byte (the files are CRLF).
- `cargo make test` (main session, detached log), twice, every step:
  - after implementation: `EXIT=0` in 681 s;
  - after the review patches: `EXIT=0` in 721 s.
  - Coverage held at 99.49 %, extern-coverage OK, `coverage-baseline.txt` unchanged.
- Matrix audit:
  - rules match the pubspecs: `a_flutter_package_plans_itself_…`;
  - new dependency and new member: `a_dependency_the_rules_miss_or_invent_…`;
  - outside, non-member and commented entries: `dependencies_are_first_level_member_keys_…` and `the_members_are_the_workspace_entries_…`;
  - member pubspec plans everything: `manifests_toolchains_…`, with the spike pubspec in `docs_need_nothing_…`;
  - app bundle notices: the font_manifest notices test plus the debug-app check.
  - All of them ran in the green gate.

**Residual risks:**
- A manual `flutter test` in `app/` (outside the gate) still reads a stale `NOTICES.Z` after a licence-file change. The test's failure message says to delete `app/build/unit_test_assets`.
- Every member-pubspec edit now costs a full gate run (~12 min), like a crate manifest.
- The OFL texts reach the NOTICES but not a licence page, which does not exist yet (deferred).

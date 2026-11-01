---
title: 'Story 10.24 — Inspector diff view: ±, focused-file hunks, Unified / Side by side, Viewed'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '4ec4b049460b61bcbb5208c2dc8f0a9eb8c1d5fb'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A graph node keyed by its commit id (hidden or divergent) gets no diff in the inspector, because RepoHandle.diff resolves only change ids.
    evidence: |-
      crates/zanshin-jj/src/hunks.rs:251 resolves the revision through op_support::resolve_or_wc (a ChangeId); a commit id fails jj.change_not_found. jj diff -r takes any revision. The inspector skips the reads for such nodes (graph_inspector.dart _fetch) rather than show another commit's diff.
    location: >-
      crates/zanshin-jj/src/hunks.rs:251
    severity: medium
  - summary: >-
      The diff block lays out every line of the focused file eagerly; a multi-thousand-line file may jank.
    evidence: |-
      inspector_diff.dart builds a non-lazy Column under IntrinsicWidth (unified) and an IntrinsicHeight per row (side by side). Unverified: settle by profiling a large generated file in the running app.
    location: >-
      app/lib/src/features/graph/inspector_diff.dart
    severity: medium (unverified)
  - summary: >-
      The witness "the Settings row changes the layout" waits for the Settings window.
    evidence: |-
      GeneralSettings.diffLayout exists and the inspector follows another writer (tested); the Diffs row itself is Story 11.7 item 3.
    location: >-
      packages/zanshin_settings/lib/src/model/general_settings.dart
    severity: low
  - summary: >-
      The diff view was not checked in the running catalogue against the DS DiffView / DiffHunk / FileRow cards.
    evidence: |-
      Unattended run: no Marionette / Playwright check; only widget tests check the look.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The inspector (10.8) lists a change's files but shows no diff, no ± counts and no review state; Epic 5's line-level `RepoHandle.diff` (5.6/5.8) now exists. Deferred items I1 (the dropped review workflow), I2 (no per-repository store for Viewed) and I3 (conflicted files have no diff display) name this story.

**Approach:** Extend the `GraphDetails` port with `diff`, read one summary diff per selected revision (± per file, header totals, fingerprints) and one diff for the focused file, and draw the focused file's hunks below the file list (DS DiffView / DiffHunk) in Unified or Side by side. Viewed marks persist per repository on the registry's `ProjectEntry`, keyed by (change id, path, fingerprint); the layout is an app preference in `GeneralSettings` (11.7's Settings › Diffs row binds it later).

## Boundaries & Constraints

**Always:**
- Every diff comes from the backend (`RepoHandle.diff(revision: <commit id>, …)`, `jj diff -r` semantics); nothing is computed in Dart except presentation (header text, side-by-side pairing, sums of backend counts).
- Requests: one `summary: true` request per (selected key, layout operation) — re-run after every reload and selection change, together with `show`; one `paths: [focused path]` request per focus (and again after a reload). Replies for an older key/operation/focus are dropped (serial, as `_fetch` does). Nothing is read while stale.
- Focus: the first file starts focused (after a selection change); a reload keeps the focused path when it is still in the file list, else the first file.
- Hunk header text exactly `@@ −{l},{n} +{r},{m} @@` with U+2212 for the minus: `{l}` = `before.start + 1` (or `before.start` when the range is empty), `{n}` = `before.end − before.start`; same for the right side — jj's `to_line_number` (`cli/src/diff_util.rs:1780-1799` @ v0.46.0). Then the hunk's `symbol` when non-null, then `+added` / `−removed` (each only when > 0).
- Side by side pairing (the DS DiffHunk.jsx rule): a context line fills both cells; a run of removed lines followed by a run of added lines is paired row by row, the shorter side's cells empty.
- Lines: mono `ZsType.code` (11 px), no line numbers, the text without its trailing `\n`; a hunk scrolls horizontally on its own for long lines; diff text is selectable (`SelectionArea`/`SelectableText` — whichever the codebase already uses; the glyph colours stay).
- Viewed key = change id + path + that file's summary `fingerprint`; the mark is per repository. A file whose (change id, path, fingerprint) is stored reads as viewed — so a rebase that leaves the file's changes alone keeps the mark and an edit to them resets it. Toggling the diff block's Viewed adds/removes the focused file's key; the folded row's click unfolds and clears it; Mark all adds every listed file's key, Reset removes them.
- Store: a `ProjectViewedStore(SettingsStore, path)` mirroring `ProjectStackStore` (registry entry field `viewedFiles`; a path not in the registry keeps the set in memory for the session; a failed write is swallowed). shortcut: keep only the newest 2000 keys, upgrade to pruning by live change ids if it ever matters.
- Layout preference `GeneralSettings.diffLayout` (`DiffLayoutSetting.unified` default, `.sideBySide`); the inspector reads it from the store and follows another writer's change (the Settings row, 11.7).
- Placeholders (Claude's proposal): a binary file shows one line "Binary file"; a mode-only change "Executable bit changed"; a file with no hunks otherwise "No line changes". A conflicted file shows jj's materialized conflict text as hunks — the backend materializes it (`crates/zanshin-jj/src/hunks.rs:362`), no special Dart code.
- Tokens: hunk band `colors.hunkBg`, range `colors.hunk`, add/rem `colors.add`/`addBg`, `colors.rem`/`remBg`, well `colors.codeBg` + 1 px `colors.flBorder`, radius `metrics.radiusWell`; viewed block border `colors.addEdge`, folded row `colors.addBg` text `colors.add`. Controls from `zanshin_ui` only: `ZsSegmented` (size sm, icons `ZI.splitInline` / `ZI.splitSide`, tooltips "Unified" / "Side by side"), the Viewed toggle as a button with a presentational `ZsCheckbox` (size sm, tone add) + "Viewed".
- Strings in `app/lib/l10n/app_en.arb` (run `flutter gen-l10n`); jj's symbols/sigils/ranges are literals marked `// l10n-ignore: <reason>`.

**Never:** checkboxes on files/hunks (10.25/10.26), drags or grips (10.27), word/syntax marks (5.2–5.4), line numbers, editing, a designed conflict view (9.17's resolve), a meter bar, auto-advance or a V shortcut, a Settings window (11.7). No Material/Yaru widgets. No backend (Rust/FFI/schema) change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Select a change with 2 files | summary: a.dart +3 −1, b.rs +2 −0 | header "2 files +5 −1"; rows show ±; a.dart focused; exactly one `diff(paths:[a.dart])` | — |
| Click b.rs | — | one `diff(paths:[b.rs])`, block shows b.rs hunks; no request for other paths | — |
| Side by side | hunk: 3 removed then 2 added | 3 rows; the 3rd row's right cell empty | — |
| Symbol | Rust hunk symbol `fn main()`; Dart hunk symbol null | header shows `fn main()` / nothing after `@@` | — |
| Mark viewed | toggle on a.dart | block folds to "Viewed — diff folded away. Click to show it again."; row ✓ + dimmed path; header "1/2 viewed" + Mark all | write swallowed on FileSystemException |
| Reload, same fingerprint | new op, a.dart fingerprint unchanged | still viewed, still focused | — |
| Reload, changed lines | fingerprint differs | not viewed | — |
| All viewed | Mark all | "✓ all viewed" + Reset; Reset clears all | — |
| Other repository | same change id/path/fingerprint, other registry path | not viewed | — |
| Focused path gone after reload | a.dart removed | first file focused | — |
| Summary refused | `ZanshinFfiException` | rows without ±, no totals, no diff block; logged | as `show`'s refusal pattern |
| Focused diff refused | exception | block shows the refusal text (`context ?? code`) | — |
| Binary / mode-only / empty | flags | the one-line placeholder | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_ports.dart:761-782` -- `GraphDetails` / `RepoGraphDetails` (show, changeActions): add `Future<Diff> diff(String commitId, {List<String> paths = const [], bool summary = false})` → `_repo.handle.diff(revision: commitId, paths: paths, summary: summary)`.
- `packages/zanshin_core/lib/src/worker/handle.dart:1651` -- `RepoHandle.diff` (exists, 5.8); `packages/zanshin_core/lib/src/ffi/diff.dart` -- `Diff`/`FileDiff`/`Hunk` (`before`/`after` 0-based half-open, `symbol`, `removed`/`added`, `lines`)/`HunkLine`(`kind`, `text` with `\n`); already exported in `packages/zanshin_core/lib/zanshin_core.dart:33`.
- `app/lib/src/features/graph/graph_inspector.dart:33-228` -- `InspectorViewModel` (`_graphChanged` serial pattern, `_fetch`): add summary, focus, focused diff, viewed, layout. `:1074-1209` `_Changes` (header, rows, ↑↓ highlight) and `:1212-1267` `_FileRow`: add ±, ✓/dim, click/Enter focuses, viewed counter + Mark all/Reset, diff block below.
- `app/lib/src/features/graph/graph_stack_store.dart` -- `ProjectStackStore` pattern to copy for `ProjectViewedStore` (new file `inspector_viewed_store.dart`).
- `packages/zanshin_settings/lib/src/model/projects_settings.dart:62-72` -- `ProjectEntry`: add `@Default(<String>[]) List<String> viewedFiles`. `general_settings.dart` -- add `DiffLayoutSetting` enum + `@Default(DiffLayoutSetting.unified) DiffLayoutSetting diffLayout`. Regenerate with `dart run build_runner build -d` in `packages/zanshin_settings` (never hand-edit `.g.dart`/`.freezed.dart`); export the enum from `zanshin_settings.dart`.
- `app/lib/src/features/home/project_graph_host.dart:133` -- wire `InspectorViewModel(graph:, details:, viewed: ProjectViewedStore(host.settings, root), settings: host.settings)`.
- `app/widgetbook/folders/graph.dart:697, :792` -- `_DemoDetails implements GraphDetails`: add a demo `diff` (a few hunks incl. a Rust symbol, binary file) so the catalogue shows the diff.
- Test fakes implementing `GraphDetails`: `app/test/features/graph/graph_inspector_test.dart:61`, `app/test/features/graph/graph_card_menu_test.dart:182`.
- DS reference (read-only): `_bmad-output/implementation-artifacts/design_system/components/content/{DiffView,DiffHunk,FileRow}.{jsx,prompt.md}`, `content.css:2-60`, `ui_kits/desktop/inspector.jsx:166-199`, `kit.css:115-124` (`zk-ch-hd` header, viewed counter 11.5 px dim, Mark all/Reset text buttons).
- Zs controls: `ZsSegmented`/`ZsSegment` (`packages/zanshin_ui/lib/src/controls/zs_segmented.dart:25,86`), `ZsCheckbox` (`zs_checkbox.dart:72`, `presentational`, `ZsCheckboxSize`, `ZsCheckboxTone`), `ZsControl`/`ZsFocusRing` for focusable buttons; icons `ZI.splitInline`, `ZI.splitSide`, `ZI.check`; `ZsType.code`; `ZsColors.hunk/hunkBg/codeBg/flBorder/add/addBg/addEdge/addBgHi/rem/remBg/textMuted/textDim/textFaint`.
- Real-cdylib test pattern: `app/test/features/graph/graph_real_repo_test.dart`, `graph_ports_test.dart`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/model/{general_settings,projects_settings}.dart` + `zanshin_settings.dart` -- add `diffLayout` / `DiffLayoutSetting` and `viewedFiles`; regenerate; add a round-trip/default test in the package's test dir -- preference + per-repository store (I2).
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphDetails.diff` + `RepoGraphDetails.diff` -- data port.
- `app/lib/src/features/graph/inspector_viewed_store.dart` (new) -- `InspectorViewedStore` interface (`Set<String> load()`, `void save(Set<String>)`) + `ProjectViewedStore`, plus `viewedKey(changeId, path, fingerprint)` -- I2.
- `app/lib/src/features/graph/graph_inspector.dart` -- model: `summary`, `focusedPath`, `focusedDiff`, `focusError`, `focus(path)`, `isViewed(path)`, `setViewed(path, bool)`, `markAll()`, `resetViewed()`, `layout` / `setLayout`; widgets: header totals + counter, ± and ✓ on rows, focus on click/Enter, the diff block -- I1.
- `app/lib/src/features/graph/inspector_diff.dart` (new) -- `hunkHeader(Hunk)`, `pairSideBySide(List<HunkLine>)` (pure, public for tests), the DiffView/DiffHunk widgets and placeholders -- I1, I3.
- `app/lib/l10n/app_en.arb` -- new strings (files ± header reuse `inspectorFileCount`, "n/N viewed", "all viewed", "Mark all", "Reset", "Viewed", "Unified", "Side by side", "Diff layout", the folded text, the three placeholders, tooltips "Mark as viewed"/"Mark as not viewed"); `flutter gen-l10n`.
- `app/lib/src/features/home/project_graph_host.dart`, `app/widgetbook/folders/graph.dart`, test fakes -- wiring and fakes.
- Tests: `app/test/features/graph/inspector_diff_test.dart` (header text incl. empty range and U+2212, pairing 3 removed + 2 added → 3 rows/1 empty cell, symbol shown/absent, placeholders), extend `graph_inspector_test.dart` (every I/O matrix row: one request per focus and none for other paths, totals = sum of counts, viewed fold/unfold, survives same fingerprint across a reload, resets on a changed fingerprint, per repository via two `ProjectViewedStore` paths, Mark all/Reset + counter appears with the first viewed file, layout persists in `SettingsStore` and follows an external write, focused path survives a reload / falls back to first), and one real-cdylib test that `RepoGraphDetails.diff` returns the summary and a focused file's hunks of a fixture change.

**Acceptance Criteria:**
- Given a selected change, when the inspector loads, then the header reads "N files +a −r" with a = Σ added and r = Σ removed of the summary, each row shows its ± and the first file's hunks render below the list.
- Given the layout set to Side by side, when the app restarts with the same settings file, then the diff opens side by side; and when another writer changes `general.diffLayout`, the open diff follows.
- Given a file marked Viewed in repository A, when the same change/path/fingerprint is shown in repository B, then it is not viewed.
- Given a conflicted file, when focused, then its hunks show jj's materialized conflict-marker text as delivered by the backend.

## Spec Change Log

- 2026-11-01 (build): `RepoHandle.diff`'s `revision` resolves a **change id** only (`zanshin_jj::hunks::diff` → `op_support::resolve_or_wc`), a commit id fails `jj.change_not_found` (seen in the real-cdylib test). The port is `GraphDetails.diff(String changeId, …)`; a node keyed by its commit id (hidden, divergent) reads no diff (as a refused summary) rather than another commit's. Backend gap: a commit-id `revision` for `diff`, as `show(revset:)` takes. Marionette visual check not run (unattended) — deferred.

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 42 findings — high 0, medium 3, low 29, false 8, maybe-false 2
- findings:
  - (verification-gap) `[low]` `[patch]` no test has two focused-diff reads in flight; the `_focusSerial` guards are unverified — two held-read tests added (focus B while A pending; selection change while pending).
  - (verification-gap) `[low]` `[reject]` host wiring of `ProjectViewedStore(host.settings, root)` is unverified at host level — same `root` as the sibling `ProjectStackStore` on the line above; a host test for both is more than a direct correction for an unlikely regression.
  - (verification-gap) `[low]` `[reject]` `viewedCount` vs `files.length` never meets when the summary omits a listed file — `show` and the summary list the same files of the same revision; not met in everyday use.
  - (edge) `[low]` `[patch]` a refused focused read cannot be retried on the same row — `focus()` returns early only when no refusal is held.
  - (edge) `[low]` `[reject]` a reload keeps the previous op's hunks while the new read runs — deliberate (no flicker), transient until the reply lands.
  - (edge) `[false]` `[reject]` non-`ZanshinFfiException` errors escape `_loadFocus` — the port documents `ZanshinFfiException` as its only failure; `show`/`changeActions` catch the same; anything else is a loud bug, correct behaviour.
  - (edge) `[medium]` `[patch]` an unknown `diffLayout` value fails the whole settings document — `@JsonKey(unknownEnumValue: DiffLayoutSetting.unified)` + decode test.
  - (edge) `[low]` `[reject]` the in-memory `_viewed` set grows past the store's 2000-key cap — 2000 marks in one session is not everyday use; trimming needs the cap shared.
  - (edge) `[low]` `[reject]` two inspector models on one repository overwrite each other's marks — one project window holds one model per repository.
  - (edge) `[low]` `[patch]` a CRLF line keeps a stray `\r` — stripped after the `\n`.
  - (blind) `[low]` `[reject]` the hunk header copies with U+2212 — the design asks for the real minus; the header is not patch text.
  - (blind) `[low]` `[reject]` side-by-side selection interleaves both sides — fixing it needs per-column selection containers, more than a correction, for a rare copy.
  - (blind) `[low]` `[reject]` side-by-side clips long lines — the DS clips side cells (`content.css:34` `overflow:hidden`; tokens and CSS win over prose, epic context); Unified scrolls.
  - (blind) `[low]` `[patch]` a last line without `\n` is indistinguishable — jj's `\ No newline at end of file` marker line rendered after it.
  - (blind) `[low]` `[patch]` (dup of the CRLF row) stray `\r` — same fix.
  - (blind) `[low]` `[patch]` a mode change together with content changes shows no note — the "Executable bit changed" line also shows above hunks.
  - (blind) `[low]` `[reject]` loading, "no entry" and empty diff look the same — a reply always lists the requested path of a listed file; the brief empty block is the loading state.
  - (blind) `[false]` `[reject]` refusals hide the diff / show `context ?? code` — the I/O matrix specifies exactly this, mirroring 10.8's show refusal.
  - (blind) `[maybe-false]` `[defer]` hidden/divergent nodes get no diff — grouped with the intent row below (backend gap).
  - (blind) `[low]` `[reject]` the focused diff is not compared with the shown commit id — an op between the two reads triggers a reload that re-reads both; transient.
  - (blind) `[false]` `[reject]` every reload re-reads both diffs — the story requires re-reading after each reload (item 1).
  - (blind) `[maybe-false]` `[defer]` large diffs are laid out eagerly (Column/IntrinsicWidth, every line) — medium if true (jank on generated files); settle by profiling a multi-thousand-line file in the running app.
  - (blind) `[false]` `[reject]` Viewed marks live in settings.json — I2's decision: the registry entry, next to 10.17's stack toggles.
  - (blind) `[low]` `[patch]` re-marking an already viewed file writes to disk — `_setViewed` skips keys already in the requested state.
  - (blind) `[low]` `[reject]` (dup) in-memory set not trimmed — as the edge row.
  - (blind) `[medium]` `[patch]` (dup) unknown enum value fails settings — as the edge row.
  - (blind) `[false]` `[reject]` the setting's place contradicts its doc — epics.md 11.7 item 3 puts "Diffs › Layout" in the General tab, i.e. `general`.
  - (blind) `[false]` `[reject]` Mark all only after one file is viewed — the design and item 2: "From the first viewed file on".
  - (blind) `[low]` `[patch]` screen readers miss focused/viewed — `Semantics(selected:)` on the row, a label on the ✓.
  - (blind) `[low]` `[patch]` ↩ is taken with modifiers held — handled only without modifiers.
  - (blind) `[low]` `[patch]` (dup) out-of-order focused reads untested — as the verification-gap row.
  - (blind) `[false]` `[reject]` dispose during a read untested/unsafe — `_notify` checks `_disposed`, the replies only assign fields.
  - (blind) `[low]` `[reject]` rename identity under a target-only path untested — 5.6 filters copy records on the target (spec-5-6), so the target path keeps the rename; a test is more than a correction.
  - (blind) `[low]` `[reject]` `setLayout` gives no feedback on a failed write — every app preference swallows the write the same way (10.7's `GraphPreferences`).
  - (intent) `[low]` `[reject]` the focused diff is not pinned to (operation, commit id) — the serial drops replies older than the latest request, and every op change re-requests; same as the blind row.
  - (intent) `[medium]` `[defer]` hidden/divergent nodes (keyed by commit id) get no diff — `RepoHandle.diff` resolves change ids only (`crates/zanshin-jj/src/hunks.rs:251`), unlike `jj diff -r <commit>`; needs a backend/FFI change outside this UI story.
  - (intent) `[false]` `[reject]` the exact-path filter is client-side — the request carries the path; keeping the matching entry is presentation.
  - (intent) `[low]` `[reject]` the symbol / rebase / conflict witnesses are not exercised on the real cdylib — the backend's own suites (5.1 source symbol, materialized conflicts, 5.6 fingerprints) cover them; the app's real-cdylib test covers the port mapping.
  - (intent) `[low]` `[defer]` the Settings row witness — the row is 11.7's (epics.md 11.7 item 3); this story provides the preference.
  - (intent) `[low]` `[reject]` accent / inactive-window and selection-highlight witnesses untested — the colours are fixed data tokens by construction.
  - (intent) `[low]` `[defer]` the Marionette visual check against the DS cards was not run (unattended).
  - (intent) `[low]` `[reject]` the bar's path truncates at the end, not from the left — Flutter has no leading ellipsis; 10.8's rows do the same; more than a direct correction.

## Design Notes

- Rows stay `show`'s `fileChanges` (10.8's list, its empty states and tests); ±, fingerprints and totals are looked up by path in the summary. A file missing from the summary shows no ± and is never viewed.
- Viewed key string: `'$changeId:$fingerprint:$path'` (ids and fingerprints are hex, so the path may hold `:`).
- I1 outcome: ±, Unified / Side by side, Viewed per repository with Mark all / Reset and the counter are built; meter bar, auto-advance and V stay dropped (the floating client drops them). I2: `ProjectEntry.viewedFiles` via `ProjectViewedStore`, next to 10.17's stack toggles. I3: jj's materialized text is shown; a designed conflict view stays 9.17's.
- The Settings › Diffs row itself is 11.7's (epics.md Story 11.7 item 3); this story provides the preference it binds.

## Verification

**Commands:**
- `cd packages/zanshin_settings && dart run build_runner build -d` then `dart test`, `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` -- expected: green.
- `cd app && flutter gen-l10n && flutter test test/features/graph test/l10n test/widgetbook test/features/home` (with the Makefile.toml test env for real-worker tests), `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` -- expected: green.
- Not run (gate rule): `cargo make test`/`test-full`/`coverage`; no Rust/FFI/schema change, so no cargo checks, codegen or parity oracle.

**Manual checks (if no CLI):**
- Marionette visual check of the catalogue's inspector against the DS DiffView/DiffHunk cards -- not possible unattended; record as deferred if skipped.

**Verification notes (2026-11-01, this run):**
- `packages/zanshin_settings`: build_runner regenerated; `flutter test` 41 passed (its tests use flutter_test); `dart analyze --fatal-infos` no issues; `dart format --set-exit-if-changed .` 0 changed.
- `app` (Makefile.toml test env): `flutter test test/features/graph test/l10n test/widgetbook test/features/home test/features/shell` -- after the review patches 1282 passed on the second run; the first run had one failure in `test/features/graph/revset_configs/revset_configs_window_test.dart` ("saved configurations and the default survive a restart and read the same in a second repository", a file this story does not touch), which passed alone and in the rerun -- flaky, pre-existing. `dart analyze --fatal-infos .` no issues (one prefer_if_elements info in the new test fixed); `dart format --set-exit-if-changed .` 0 changed.
- Real-cdylib: `graph_ports_test.dart` `RepoGraphDetails.diff` (summary counts/fingerprints + one focused file's hunks) passed in the run above.
- Not run: cargo checks, `cargo make codegen`, parity oracle (no Rust/FFI/schema/jj-verb change); full gate and coverage (gate rule); Marionette visual check (unattended; deferred).

## Auto Run Result

Status: done. Commit 6b6b2e66 (code); spec, ledger and sprint-status in the following commit.

**Summary.** The inspector reads one summary diff per selection and operation (`GraphDetails.diff` → `RepoHandle.diff(revision: <change id>, summary: true)`) for ± on every row and the header's "N files +a −r", and one diff for the focused file (the first file starts focused; a reload keeps it while listed). The diff block draws the focused file's hunks (jj's `@@ −l,n +r,m @@` with U+2212, jj's source symbol, ±) in Unified or Side by side, with placeholders for binary, mode-only and line-less files and jj's `\ No newline at end of file`. Viewed marks persist per repository, keyed by change id, path and the file's fingerprint, with the "n/N viewed" / "✓ all viewed" counter and Mark all / Reset. The layout is `general.diffLayout`.

**Files.**
- `packages/zanshin_settings/lib/src/model/general_settings.dart` -- `DiffLayoutSetting`, `diffLayout` (unknown values read as unified); `projects_settings.dart` -- `ProjectEntry.viewedFiles`; regenerated code and tests.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphDetails.diff` / `RepoGraphDetails.diff`.
- `app/lib/src/features/graph/inspector_viewed_store.dart` -- `viewedKey`, `InspectorViewedStore`, `ProjectViewedStore`.
- `app/lib/src/features/graph/graph_inspector.dart` -- model (summary, focus, focused diff, viewed, layout) and the Changes header, rows and diff mount.
- `app/lib/src/features/graph/inspector_diff.dart` -- `hunkHeader`, `pairSideBySide`, `InspectorDiffView` and hunks.
- `app/lib/l10n/app_en.arb` (+ generated) -- strings; `app/lib/src/features/home/project_graph_host.dart` -- wiring; `app/widgetbook/folders/graph.dart` -- demo diff.
- Tests: `app/test/features/graph/{graph_inspector_test,inspector_diff_test,graph_ports_test,graph_card_menu_test}.dart`.

**Review.** 42 findings (high 0, medium 3, low 29, false 8, maybe-false 2). Patched (9 entries): unknown `diffLayout` value (medium), out-of-order focused reads now tested, retry after a refused focused read, CRLF `\r`, the no-newline marker, mode note with hunks, no write for an unchanged Viewed state, row semantics, ↩ only without modifiers (low). Deferred (4): commit-id-keyed nodes get no diff (backend resolves change ids only), eager layout of large files (unverified), the Settings row witness (11.7), the Marionette check. Rejected: every other row, each with its reason in the triage log.

**Follow-up review recommendation:** false — one medium entry patched (an annotation plus a decode test), no high.

**Items.**
- **I1** -- fixed (6b6b2e66): ±, Unified / Side by side, Viewed per repository with Mark all / Reset and the "n/N viewed" counter; meter bar, auto-advance and V stay dropped.
- **I2** -- fixed (6b6b2e66): `ProjectEntry.viewedFiles` through `ProjectViewedStore`, next to 10.17's stack toggles.
- **I3** -- partly done (6b6b2e66): a conflicted file's diff shows jj's materialized conflict-marker text as the backend delivers it; left: the designed conflict view (9.17's `resolve`, a later UI story).

**Residual risks.** A hidden or divergent node shows no diff (backend gap, deferred). Large files are laid out eagerly (unprofiled). The view was not checked in the running catalogue. Viewed marks are read once per model; another window's writes are not followed. One flaky pre-existing test (`revset_configs_window_test.dart`) failed once and passed on rerun.

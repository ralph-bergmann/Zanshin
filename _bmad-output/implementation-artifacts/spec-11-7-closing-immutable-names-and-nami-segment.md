---
title: 'Story 11.7 closing run — the Immutable commits page names what matches, the Project tab shows the Nami mark'
type: 'feature'
created: '2026-11-02'
status: 'done'
baseline_revision: '6c8ab870d6a935bcf51d2276a0fe4afc8190f18e'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The Immutable commits page's untracked-remote hints can name a tracked remote ref that disagrees with its local target.
    evidence: |-
      matchNames infers "untracked" from TopologyRef.synced, which is "tracked and agrees"; a tracked, moved remote ref on a commit some untracked ref of the same kind also targets is named too. The bridge has no read of a remote tag's tracking state (bookmarks() carries `tracked` for bookmarks only), so an exact answer needs a bridge read.
    location: >-
      app/lib/src/features/settings/immutable_heads.dart (_untrackedRemote, shortcut comment)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Two items Story 11.7 deferred, both verified real against the current code: (1) the Immutable commits page (`app/lib/src/features/settings/immutable_page.dart`) shows fixed hints for Tags / Remote bookmarks you don't track / Remote tags you don't track and only the count in the Result well — the DS (`design_system/components/settings/ImmutablePage.jsx:66-68, :97`, `ImmutablePage.prompt.md:13, :15`) names this repository's matches in each hint and lists the heads under the count; (2) the Settings window's Project tab segment shows `ZI.folder` (`settings_window.dart:162`) where the DS cards show `NamiMark size={14}` (`settings.card.html:25`, `immutable-page.card.html:18`), because `ZsSegment.icon` takes a glyph name only.

**Approach:** (1) A new read on the `SettingsRepoReads` port, `revsetMembers(revset)` — `graphTopology` of the revset, each node as its refs, change id prefix and root flag — read once per project for `tags()`, `untracked_remote_bookmarks()`, `untracked_remote_tags()`, and for `immutable_heads()` with every recount; pure helpers in `immutable_heads.dart` turn members into names; the page shows them in the hints and as a mono line under the count. (2) `ZsSegment` gains `leading: Widget?` (drawn in place of `icon`); the Project segment passes `ZsNamiMark(size: 14)`.

## Boundaries & Constraints

**Always:**
- Hint names (Claude's proposal for the wording beyond the DS): Tags "Released versions: ‹names›."; Remote bookmarks "Fetched, but not yours to rewrite: ‹names›."; Remote tags "Fetched, but not yours to move: ‹names›." — an empty match list reads "none here" (DS `list()`), remote tags empty reads "None in this repository." (DS). Before the read lands or when it fails, the current fixed hints stay. At most 5 names, then "‹n› more" as the last item; names joined ", ".
- Names: `tags()` → local tag refs' names; the two untracked terms → remote refs of that kind whose remote is not `git` (jj's ignored remote, `parse_remote_refs_arguments` in jj-lib 0.46 `revset.rs:1427`) and not `synced`, as `name@remote`; deduplicated, in the topology's order.
- Heads line under the count (only when the count shows): each member of `immutable_heads()` as its local refs' names, else its remote refs (`name@remote`, not `git`), else `root()` for the root, else its shortest unique change id prefix; deduplicated, joined " · ", at most 8, then "‹n› more". Mono `--fs-id`, `--text-muted`, selectable as the well's other text. Re-read on every recount (after writes).
- `ZsSegment.leading` is shown before the label instead of `icon` (assert: label, icon or leading); the leading widget keeps its own colours.
- l10n: new strings in `app/lib/l10n/app_en.arb` with descriptions, `flutter gen-l10n` output committed. SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings` clean, `dart format`.

**Never:**
- No Rust/FFI/schema change, no new bridge verb (the existing `graphTopology` is enough). No other change to Story 11.7's code (writes, controls, TOML, count, Reset). No edits under `design/` or `design_system/`, `epics.md`, `epic-11-context.md`, `project-context.md`, the Story 11.7 spec or existing deferred-work.md bullets. No golden tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Tags named | `tags()` members carry tags `v1.0.0`, `v1.4.2` | Tags hint "Released versions: v1.0.0, v1.4.2." | — |
| No matches | untracked remote bookmarks → none; remote tags → none | "Fetched, but not yours to rewrite: none here." / "None in this repository." | — |
| Many | 7 tag names | first 5, then "2 more" | — |
| Remote filtering | refs `main@origin` synced, `release@origin` untracked, `x@git` | only `release@origin` | — |
| Read fails / unread | `revsetMembers` throws `ZanshinFfiException` | fixed hints; no heads line | logged FINE |
| Heads | members: node with `main` + `main@origin`; node with tag `v1.0.0`; node without refs (change id `kxyz…`, prefix 4) | "main · v1.0.0 · kxyz" under the count | — |
| After a write | alias changes | heads line re-read with the count | failure drops the line |
| Nami segment | Settings window, project open | the Project segment draws `ZsNamiMark` 14 px before the project name, no folder glyph | — |

</intent-contract>

## Code Map

- `app/lib/src/features/settings/settings_view_model.dart` -- port `SettingsRepoReads` :47-65 (add `revsetMembers`), `RepoSettingsReads` :68-102 (implement via `_repo.handle.graphTopology(revset:, anchors: const [], withTimestamps: false)`; per node `refsOf(i)`, `changeId(i)`, `changeIdPrefixLength(i)`, `isRoot(i)` — `packages/zanshin_core/lib/src/ffi/graph.dart:440-520`); `_load` :240-258 resets state; `_readProject` :279-307 (add the built-ins' read); `recountImmutable` :346-367 (add the heads read, same `identical(reads, _reads)` guard).
- `app/lib/src/features/settings/immutable_heads.dart` -- `immutableBuiltins` :31-36; add `RevsetMember`, `matchNames(members, term)` and `headLabels(members)` as pure functions (import `TopologyRef`, `TopologyRefKind` from zanshin_core, exported at `zanshin_core.dart:62`).
- `app/lib/src/features/settings/immutable_page.dart` -- `builtin(...)` hints :72-85; count row :191-212 (heads line below it).
- `app/lib/l10n/app_en.arb` :1424-1435 (hint keys); run `flutter gen-l10n` in `app/`.
- `packages/zanshin_ui/lib/src/controls/zs_segmented.dart` -- `ZsSegment` :22-42, segment row :295-313.
- `app/lib/src/features/settings/settings_window.dart:159-165` -- Project segment.
- Fakes implementing the port: `app/test/features/settings/settings_window_test.dart:34-66` (`_Reads`), `app/widgetbook/folders/windows.dart:527` (`_DemoSettingsReads`: demo tags `v1.0.0`, `v1.4.2`, untracked `release/1.5.x@origin`, heads `main · v1.0.0 · v1.4.2` per the DS card).
- Tests: `app/test/features/settings/immutable_heads_test.dart` (pure helpers), `settings_window_test.dart` (page hints, heads line, failure, Nami segment), `packages/zanshin_ui/test/controls/zs_segmented_test.dart` (leading slot).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_segmented.dart` -- `leading` field + rendering; test in `zs_segmented_test.dart`.
- `app/lib/src/features/settings/settings_window.dart` -- Project segment `leading: const ZsNamiMark(size: 14)`, no `icon`.
- `app/lib/src/features/settings/immutable_heads.dart` -- `RevsetMember`, `matchNames`, `headLabels`, `nameList` (cap + "more").
- `app/lib/src/features/settings/settings_view_model.dart` -- port method, adapter, `builtinMatches` (term → names, absent = unread) and `immutableHeadLabels` (null = unread), reads and resets.
- `app/lib/src/features/settings/immutable_page.dart`, `app/lib/l10n/app_en.arb` (+ generated) -- hints with names, heads line.
- `app/test/...`, `app/widgetbook/folders/windows.dart` -- fakes answer `revsetMembers`; tests for each matrix row.

**Acceptance Criteria:**
- Given the Immutable commits page over a repository with tags and untracked remote bookmarks, when it renders, then each built-in hint names that repository's matches and the Result well lists the heads under the count.
- Given the Settings window with a project open, when it renders, then the Project tab segment shows the Nami mark before the project name.

## Spec Change Log

## Review Triage Log

### 2026-11-03 — Review pass
- verdicts: 32 findings — high 0, medium 0, low 24, false 8, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind 1) The count (`revsetCounts` at the head op) and the heads (`graphTopology` from head) may read different operations — both read the head at nearly the same moment; an op landing between them is re-read on the next recount; pinning needs a new port parameter. A snapshot by `graphTopology` is the same read the graph makes all the time.
  - `[low]` `[reject]` (blind 2) No size cap on the members read (`tags()` in a repo with thousands of tags) — the page opens rarely and the graph reads whole topologies anyway; a cap needs a bridge read with a limit and refs.
  - `[low]` `[reject]` (blind 3) The built-in hints are read once per project load and go stale after a fetch while the window is open — the count does not follow a fetch either (pre-existing); re-reading them on every recount adds three topology reads per toggle.
  - `[low]` `[reject]` (blind 4) Only `ZanshinFfiException` is caught, so a `StateError`/`RangeError` breaks the open sequence — the neighbouring readers (`_readRemotes`, `_readBookmarks`, the count) catch the same; the prefix length is the shortest unique prefix of that id, never longer.
  - `[low]` `[reject]` (blind 5) Two quick toggles can let an older heads read win — the count has the same pre-existing race under the same guard; the next toggle corrects it; a sequence token adds state for a rare case.
  - `[false]` `[reject]` (blind 6) The Nami mark does not dim when the segment is disabled — `ZsControlCore` wraps the whole segment visual in `Opacity(disabledOpacity)` (`zs_control_core.dart:350`), mark included; `leading` wins over `icon` as its doc says ("in place of [icon]").
  - `[low]` `[reject]` (blind 7) A leading-only segment has no accessible name — no caller makes one; icon-only segments have the same contract (pass `tooltip`).
  - `[false]` `[reject]` (blind 8) The empty state reads three ways — it is the DS's own wording (`ImmutablePage.jsx:66-68`: `list()` → "none here", remote tags "None in this repository.").
  - `[low]` `[reject]` (blind 9) "{count} more" has no plural form, separators and caps are literals — English only, "1 more"/"2 more" need no plural; separators carry no letters (the hard-coded-strings rule's scope).
  - `[low]` `[patch]` (blind 10) Missing tests: failed re-read, project switch reset — patched with verification-gap 1 and 4 (below).
  - `[low]` `[patch]` (blind 11) `find.text('main')` is a weak heads assertion — patched: the test reads the `settings-immutable-heads` Text by key.
  - `[low]` `[defer]` (blind 12) The `synced` shortcut over-reports tracked, moved remote refs — needs a bridge read of remote tracking state; deferred (frontmatter, mirrored in deferred-work.md).
  - `[low]` `[reject]` (edge 1) `StateError` from a closed handle during a switch escapes `Future.wait` — same as blind 4.
  - `[low]` `[reject]` (edge 2) A non-FFI throw from the heads read skips `_notify` — same as blind 4.
  - `[low]` `[reject]` (edge 3) An older heads answer overwrites a newer one — same as blind 5.
  - `[low]` `[patch]` (edge 4) The count waits for the heads read before it shows — patched: `recountImmutable` notifies after the count, before the heads read.
  - `[low]` `[reject]` (edge 5) Uncapped topology read — same as blind 2.
  - `[low]` `[reject]` (edge 6) Stale built-in hints after a repo change — same as blind 3.
  - `[low]` `[defer]` (edge 7) Tracked remote refs listed as untracked — same as blind 12.
  - `[low]` `[reject]` (edge 8) Leading-only segment without a name — same as blind 7.
  - `[false]` `[reject]` (edge 9) `substring` past the id when the prefix length exceeds it — the shortest unique prefix length is computed for that id and is at most its length; the real-repo test now checks it is shorter.
  - `[low]` `[patch]` (verification-gap 1) The switch reset of `builtinMatches`/`immutableHeadLabels` is untested — patched: the switch test scripts members, asserts both filled, then empty/null.
  - `[low]` `[patch]` (verification-gap 2) The named remote hints are never rendered with names — patched: new test "the remote hints name the untracked remote refs" (`release@origin`, `t1@upstream`).
  - `[low]` `[patch]` (verification-gap 3) `RepoSettingsReads.revsetMembers` has no test — patched: `app/test/features/settings/repo_settings_reads_test.dart` on the real worker (refs of `@` with a bookmark, a prefix shorter than the id, the root flag and its `root()` label).
  - `[low]` `[patch]` (verification-gap 4) A failed heads re-read clearing the line is untested — patched in the hints test (unscript `immutable_heads()`, toggle, the line is gone).
  - `[false]` `[reject]` (intent a) "Heads" are jj's `immutable_heads()` members, not the design's config-derived names ("custom revset", "N changes by others") — the design is inspiration and the page shows what jj evaluates (the CLI is the reference); the DS card's own values come out the same for its data.
  - `[false]` `[reject]` (intent b) `graphTopology` instead of the ledger's `findChanges`/`revsetCounts` — neither of those carries names; the ledger's follow-up is a proposal, the intent is the named list.
  - `[low]` `[defer]` (intent c) The untracked approximation — same as blind 12.
  - `[low]` `[reject]` (intent d) Hints refresh only on load — same as blind 3.
  - `[false]` `[reject]` (intent e) The real read is never exercised — now it is (verification-gap 3).
  - `[false]` `[reject]` (intent f) No visual check — not a code defect; recorded under Auto Run Result (already an open ledger line of Story 11.7: the Settings window's running-app checks).
  - `[false]` `[reject]` (intent g) The leading widget does not follow lit/disabled states — disabled dims it (blind 6); the DS mark is a fixed-colour brand tile, not a tinted glyph.

## Design Notes

**Why `graphTopology`.** The bridge has no tag list; `graphTopology` already carries each node's bookmarks and tags with their remote and `synced` flag (the app's `worker_project_repos.dart:100` reads it the same way). A remote entry's `synced` is "tracked and agrees", so a tracked remote ref that disagrees with its local target and sits on a commit some untracked ref also targets would be named too — rare, marked `shortcut:` in the code; an exact answer needs a bridge read of remote ref tracking state.

## Verification

**Commands (gate rule: no `cargo make test`):**
- `flutter test` in `packages/zanshin_ui` and `app` (touched suites at least) -- expected: pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed .` in `packages/zanshin_ui` and `app` -- expected: clean.

**Manual checks (if no CLI):**
- Catalogue Settings window use case (`app/widgetbook/folders/windows.dart`): the Project segment's mark and the Immutable page's hints / heads line, compared with the DS cards.

## Auto Run Result

Status: done (2026-11-03). Blocking condition: none. Code commit: c527fb195778538f79de63829499c932d9c93697.

**Items handed to this closing run.**
1. **The Immutable commits page names no matches and lists no heads — fixed** (commit `c527fb195778538f79de63829499c932d9c93697`). Verified first: the hints were fixed ARB strings and the well showed only the count. The bridge has no tag list and `findChanges`/`revsetCounts` carry no names, so the read is `graphTopology` (each node's bookmarks and tags with remote and `synced`), behind a new port method `SettingsRepoReads.revsetMembers`. The Tags / remote bookmarks / remote tags hints now read "Released versions: v1.0.0, v1.4.2." etc. (DS wording, "none here", "None in this repository.", at most 5 then "‹n› more"); a mono heads line (jj's `immutable_heads()` members as names, `name@remote`, `root()` or the change id prefix; at most 8) stands under the count and is re-read with each recount. Until a read lands, or when it fails, the old hints stay.
2. **The Project tab segment shows a folder glyph — fixed** (commit `c527fb195778538f79de63829499c932d9c93697`). Verified: `ZsSegment.icon` took a glyph name only. `ZsSegment` gains `leading: Widget?` (drawn in place of `icon`); the Project segment passes `ZsNamiMark(size: 14)` as the DS cards do.

**Files changed:**
- `packages/zanshin_ui/lib/src/controls/zs_segmented.dart` (+ test) — the `leading` slot.
- `app/lib/src/features/settings/settings_window.dart` — the Nami mark on the Project segment.
- `app/lib/src/features/settings/immutable_heads.dart` — `RevsetMember`, `matchNames`, `headLabels`, `nameList`.
- `app/lib/src/features/settings/settings_view_model.dart` — port method + adapter, `builtinMatches`, `immutableHeadLabels`, reads and resets; the count now shows before the heads read finishes.
- `app/lib/src/features/settings/immutable_page.dart`, `app/lib/l10n/app_en.arb` (+ generated `app_localizations*.dart`) — named hints, heads line, 6 new strings.
- `app/test/features/settings/{immutable_heads,settings_window,repo_settings_reads}_test.dart` — helpers, page rows, switch reset, failed re-read, the real-worker adapter test (new file).
- `app/widgetbook/folders/windows.dart` — the demo reads answer the DS card's data.
- Tracking: this spec; `deferred-work.md` ("Surfaced in the closing run of Story 11.7": 1 item).

**Review findings.** 32 findings (high 0, medium 0, low 24, false 8).
- **Patched, 7 entries (all low):** the count notifies before the heads read (edge 4); the heads assertion by key (blind 11); the switch-reset test, the named remote hints test, the failed re-read test and a real-worker test of `revsetMembers` (verification-gap 1-4, blind 10). Applied by the parent (a resumed implementation agent reports asynchronously, which this unattended run cannot wait for).
- **Deferred (new, mirrored in deferred-work.md):** the `synced` shortcut can name a tracked, moved remote ref as untracked (low; needs a bridge read of remote tracking state).
- **Rejected, low:** reads at two moments of the head op (blind 1); no cap on the topology read (blind 2, edge 5); built-in hints not re-read after a fetch while the window is open (blind 3, edge 6, intent d); only FFI errors caught, as the neighbouring readers (blind 4, edges 1-2); recount race shared with the existing count (blind 5, edge 3); leading-only segments need a tooltip like icon-only ones (blind 7, edge 8); plural/separator literals (blind 9).
- **False, 8:** the mark not dimming when disabled (the core's `Opacity` dims it), the three empty states (DS wording), the prefix `substring`, jj-evaluated heads vs the design's config labels, `graphTopology` vs the ledger's reads, the real read now tested, the visual check (not a code defect), the mark not following lit states (a fixed-colour brand tile).

**Follow-up review recommendation:** false — 7 low entries patched, 0 medium, 0 high.

**Verification (gate rule: no `cargo make test`):**
- `packages/zanshin_ui`: `dart format --set-exit-if-changed` clean, `dart analyze --fatal-infos --fatal-warnings` no issues, `flutter test` 444 passed.
- `app`: `dart format --set-exit-if-changed lib test widgetbook` 0 changed, `dart analyze --fatal-infos --fatal-warnings` no issues; `flutter test test/features/settings` 36 passed (after the review patches, incl. the real-worker `repo_settings_reads_test.dart`), `flutter test test/l10n` 5 passed. The implementation run's full `app` suite: 1897 passed, 5 failed in `worker_project_repos_test.dart` only ("XDG_CONFIG_HOME is not pinned … run via cargo make" — those tests need the gate's environment; unrelated).
- Matrix audit: tags named, no matches, remote filtering, heads, after a write, read fails/unread and the Nami segment are each covered by `settings_window_test.dart` / `immutable_heads_test.dart` / `zs_segmented_test.dart`; "Many" by `nameList caps and counts the rest`. All ran and passed.
- Not run: Rust checks (no Rust change), codegen (no schema change), the parity oracle (no jj verb).
- Not seen: the catalogue/Marionette comparison with the DS cards (the run allows only synchronous commands; already an open ledger line of Story 11.7 — "The Settings window's running-app checks were not made").

**Residual risks:**
- The untracked-remote hints rely on `synced` (deferred).
- Hints and heads are layout-checked only by widget tests; the visual comparison is still open.

---
title: "Story 10.8 — Inspector — floating panel, header, title-as-describe, meta, bookmark chips, action row, file list"
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: '577af2c267b5a3700bce2e0f97c43525457ec9bf'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The inspector's Immutable flag shows no reason yet; its tooltip reads "Immutable" until 11.7's cached revsetCounts reason producer lands.
    evidence: |-
      The 2026-10-26 note wants "Immutable · <reason>"; 10.6 handed the producer and its term order to 11.7 (epics.md, Story 10.6 Built note).
    location: >-
      app/lib/src/features/graph/graph_inspector.dart (_Header)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Selecting a card opens nothing: the floating shell has an inspector slot, width model and calm pinning, but there is no inspector widget, no `show()` port, no describe form, no resize edge for it, and five open items (I1–I5 of the dispatch) name 10.8.

**Approach:** Build epics.md Story 10.8 (`_bmad-output/planning-artifacts/epics.md:9716-9876`; the 2026-10-14, 2026-10-16 and 2026-10-26 notes win over the original Scope items 1–8) as a `GraphInspector` slot widget over `GraphViewModel` plus a new details port (`show` + `changeActions`), the inspector's `ZsResizeEdge` and exit motion in `FloatingShell`, and the catalogue's floating-shell use case hosting it over fakes. Mounting in the project window stays 10.12's.

## Boundaries & Constraints

**Always:**
- **Open/close:** the inspector shows while `model.selected != null`; × "Close (Esc)" and the Esc chain clear the selection; a vanished selection already clears in `_land`. The host passes `inspector:` only while selected; `FloatingShell` keeps the last inspector mounted for its exit. Motion: in = fade `--dur-panel` 200 with a 12 px slide × `--motion` (reduce motion → fade only); out = fade with the mirrored drift × `--motion` on `--dur-exit-lg` 180, `--ease-exit` (`ShellPanelMotion` in `pinned_panel.dart:262` is the house pattern).
- **Frame:** `ZsIsland(shape: panel)` at the shell's existing slot (top `chromeTop` = 60, right/bottom 12). Fixed header, scrolling body (`ZsScrollArea`). No composer, no diff section.
- **Resize edge** in `FloatingShell` (not in the slot), mirroring `pinned_panel.dart:110-135`: `ZsResizeEdge(side: left, value: layout.inspectorWidth, min: inspectorWMin 380, max: layout.inspectorMax, defaultValue: 460, label "Inspector width", identifier 'inspector-edge', inert: itemDragging, onChanged: controller.inspectorWidth=, onChangeEnd: commitInspectorWidth, onDragStart/End: edgeDragStarted/Ended)`. Removed when the exit starts. Persistence already exists (`floating_shell_view_model.dart:26-76`).
- **I3:** a deselect from elsewhere (graph Esc, a reload that drops the selection) can remove the edge mid-drag. `ZsResizeEdge.dispose` ends an active drag: calls `onDragEnd` (deferred past the locked tree, e.g. a microtask) and `onChangeEnd` if the value changed.
- **Covered selection (I4):** when the inspector opens (`insets.inspectorWidth` 0 → > 0) with a selection, the canvas reveals it with `GraphRevealAlignment.covered` (animated); a width drag or an uncovered card moves nothing.
- **Header:** the full change id, jj's unique prefix (`changeIdPrefixLengthOf`) bold — one `Text.rich`, two spans, no gap — commit id as tooltip. Flags (DS Flag; new app-local widget): "@ Working copy" gold; Immutable with `HatchSwatch`, neutral, not on the root, tooltip "Immutable" (the reason producer is 11.7's — see Design Notes); "Empty", "Merge" (`parentCountOf ≥ 2`), "Conflict". Then `ZsIconButton(ZI.close, sm, "Close (Esc)")`.
- **Title = describe:** subject in `ZsType.inspectorTitle`, full description (from `show`) below. Mutable change: a pen (`ZI.describe`) on hover; click or Enter opens the form; undescribed reads "Describe this change…" dim italic. Immutable/root: plain text, no form.
- **Describe form** replaces the title in place (meta, chips, files stay; the action row hides): Summary + Details `ZsTextField`s; an undescribed change starts empty with Summary focused and selected, else prefilled (first line / rest after the blank line). Enter in Summary or ⌘↩ saves, footer shows the command, Cancel and gold Save. **Save** runs `GraphDescribe` with the CLI's `join_message_paragraphs` of [summary] + [details if non-empty] (`../jj` v0.46.0 `cli/src/description_util.rs`: each paragraph gets a trailing newline if non-empty, joined by "\n") → "S\n\nD\n", "S\n"; sends nothing when that equals the current description. The command shows one `-m` per paragraph.
- **Drafts** per change id for the session (survive selection changes and re-opening). Esc in a field with a draft that differs from the saved text only unfocuses; otherwise Esc closes the form (draft kept). Esc order overall: form → panel (deselect). Esc inside the inspector never reaches the graph twice.
- **Meta** one line: author · date (the card/peek's date format) · "parent"/"parents" + each parent's short id joined " + "; the root shows none. No committer, no signature.
- **Chips:** one per `refsOf(i)`: name, state ✓ synced / local / remote from `GraphRef`. No ↓/↕ (need 9.29), not a drag source (10.10).
- **Action row** (hidden while the form is open; tooltips are each action's full command, ids max(prefix, 8)):
  - immutable or root: gold "New change on top" → `GraphNew(parents:[id])`;
  - @: gold "New change" → `GraphNew(parents:[id])`, "Squash into parent", "Abandon";
  - other mutable: gold "Edit" (`ZI.workingCopyAt`) → `GraphEdit`, "Squash into parent", "Abandon".
  - Squash into parent is always disabled (10.25 enables it): reason = `changeActions(id).squashIntoParent`'s refusal when refused, else "Comes with the commit composer". Abandon quiet, right-aligned, no confirmation → `GraphAbandon([id])`. All disabled with the model's reason while `!actionsEnabled`.
- **Changes:** header "Changes" + file count; rows status letter (A M D R C) + path, renamed/copied `fromPath → path`. One Tab stop, ↑ ↓ move the highlighted row. Empty states: @ "No changes yet — whatever you edit in your editor lands here.", merge "A merge — no changes of its own.", root "The root of all history.", else "This change has no file changes."
- **Data:** new port `GraphDetails { Future<ShowEntry> show(String commitId); Future<ChangeActions> changeActions(String changeId); }` with `RepoGraphDetails` over `RepoHandle.show(revset: commitId)` / `RepoHandle.changeActions`. Fetched on (selected key, `layout.operationId`) change; late replies for an older key/op are dropped; a refusal shows its message in the file list's place.
- **Stale** (`model.stale != null`): no `show()` call; header/meta/chips from view facts; file list shows "Working copy is stale"; action row and describe disabled with that reason.
- **I5:** in `_succeeded`, a `GraphRevert` with a born id and a non-null selection selects the born change (the inspector is open exactly while something is selected).
- **Bridge:** export `ShowEntry`, `Change`, `Signature`, `FileChange`, `FileChangeKind` (and `ActionOutcome` if missing) from `packages/zanshin_core/lib/zanshin_core.dart`.
- **I1:** the parity scenario `describe_gui_text` sends what the GUI sends ("S\n\nD\n" vs CLI `describe -m S -m D`); its ledger row goes.
- Only Zs controls (text entry `ZsTextField`); strings in `app/lib/l10n/app_en.arb` with `@` descriptions, `flutter gen-l10n`; `jj …` commands built from `GraphAction.command`.

**Never:** the diff (10.24), the composer, checkboxes, ± and Viewed (10.25/10.24), hunks (10.26), chip or file drags (10.10/10.27), the card menu's "Describe…" row (10.15 — expose the entry point only), the immutable-reason `revsetCounts` producer (11.7), mounting in `HomePage` (10.12), the toast (10.23), shortcuts (11.13), confirmation dialogs, golden tests, any Rust change outside `crates/zanshin-parity` and `zanshin-ui`'s edge fix, a sample diff.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Save | summary "S", details "D" on a mutable change | one `GraphDescribe(id, "S\n\nD\n")` | refusal → model's outcome |
| Save summary only | "S", "" | `"S\n"` | — |
| Unchanged | text joins to current description | nothing sent, form closes | — |
| Draft | type, select another card, come back | draft restored, form open | — |
| Esc chain | form open, draft dirty, field focused | 1st Esc unfocus, 2nd closes form, 3rd deselects | — |
| Merge | 2 parents | meta "parents abc12345 + def67890" | — |
| Root | root selected | no parents, "The root of all history.", "New change on top", no Immutable flag | — |
| @ empty | @ with no files | "No changes yet — …" ; New change / Squash / Abandon | — |
| Immutable | non-root immutable | hatch flag, no pen, only "New change on top" | — |
| Squash | backend refuses | disabled, tooltip = refusal reason | — |
| Stale | `model.stale` set | no `show` call, "Working copy is stale", actions + describe disabled | — |
| Vanish | reload drops the selection | inspector exits | — |
| Late reply | select A then B fast | only B's entry shown | older reply dropped |
| Covered open | selected card under the panel's area | scrolls clear; uncovered → no scroll | — |
| Edge removed mid-drag | deselect during an edge drag | `edgeDragEnded` called, `calm.held` false | — |
| Revert | inspector open, revert succeeds with born b | selection = b | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:9716-9876` -- Story 10.8; the notes :9719-9757 (2026-10-14), :9759-9790 (2026-10-16), :9792 (2026-10-26) win; witnesses :9753-9756, :9782-9790, :9792. Stale `handle.dart:690`/`:813` citations at :9757 and :9813 (I2).
- `app/lib/src/features/shell/floating_shell.dart:61-110,180-206,297-322,461-552` -- `inspector:` slot (open = non-null), placement, `_inspectorFocus` + `_typingInInspector` (calm pinning done), minimap hide done, `_CalmGroup`; doc :48-58 says the edge is the shell's.
- `app/lib/src/features/shell/pinned_panel.dart:110-135,172,262` -- edge template, `PinnedPanel` header/close/scroll pattern, `ShellPanelMotion`.
- `app/lib/src/features/shell/shell_controller.dart:65-73,115-136,258,292-321` / `shell_layout.dart:48-118` -- inspector width, `inspectorMax`, edge-drag hooks, shrink-first; `shell_scope.dart:27-46`; `graph_insets.dart:20,50`.
- `packages/zanshin_ui/lib/src/controls/zs_resize_edge.dart:67-82,168-176,229-251,350-351` -- I3: `dispose` never ends `_dragging`.
- `app/lib/src/features/graph/graph_view_model.dart:230,245,304-310,325,371-395,434-502,549-599,658-669,743-746` -- selection, stale, actionsEnabled, run, `_succeeded` (I5 at the GraphRevert branch), reveal, vanish.
- `app/lib/src/features/graph/graph_ports.dart:115,137-260,418,461-547,556-616` -- `GraphSource`, actions (`GraphDescribe` :163, `_message` :418), results, `RepoGraphActions` (`describe` verbatim :567). Add `GraphDetails` + `RepoGraphDetails` here.
- `app/lib/src/features/graph/graph_layout.dart:96-171,199-310` -- `GraphRef`, `GraphCommitContent`, view facts accessors.
- `app/lib/src/features/graph/graph_view.dart:57-72,165-195,213-233` -- slot factories (`staleNotice`, `atPill` → add `inspector`), graph Esc, insets. `graph_canvas.dart:390-428` -- `_userSelected` covered reveal; add the open reveal in `didUpdateWidget`. `graph_viewport_render.dart:31-89`.
- `app/lib/src/features/graph/hatch_swatch.dart:36`, `graph_peek.dart` (date/meta formatting), `stale_notice.dart`.
- `packages/zanshin_core/lib/src/worker/handle.dart` -- `RepoHandle.show` (:2088), `describe` (:529), `changeActions` (:1089); models `ffi/commit_views.dart:217` (`ShowEntry`), `ffi/change.dart:42-73`, `ffi/status.dart:55-75`, `ffi/drop_actions.dart:276` (`ChangeActions`); barrel `lib/zanshin_core.dart:12-36`.
- `packages/zanshin_ui/lib/src/`: `controls/zs_button.dart:23-42,119,295-316`, `zs_tooltip.dart:53`, `zs_text_field.dart`, `materials/zs_glass.dart:111-166` (`ZsIsland(shape: panel)`), `design/zs_type.dart:132-256`, `design/zs_metrics.dart:194-203`, `icons/zanshin_icon.dart:149` (`close`, `describe`, `workingCopyAt`, `plus`, `newOnTop`, `squash`, `abandon`, `conflict`, `merge`).
- `crates/zanshin-parity/tests/oracle/scenarios.rs:850-857`, `ledger.rs:139-146`, `main.rs:58,582` -- I1.
- `app/widgetbook/folders/graph.dart:112-125,395-477` -- Floating shell › Controls use case, `_DemoActions`; add a fake `GraphDetails` and pass the inspector.
- Tests: `app/test/features/graph/graph_view_model_test.dart`, `graph_view_test.dart:66-120` (`_Host`, `_Actions`), `graph_controls_test.dart` (shell host pattern), `app/test/helpers/scripted_graph_source.dart`, `app/test/features/shell/` (floating_shell tests), `packages/zanshin_ui/test/controls/zs_resize_edge_test.dart`, `app/test/widgetbook/catalogue_smoke_test.dart`.
- DS (read-only): `_bmad-output/implementation-artifacts/design_system/ui_kits/desktop/inspector.jsx`, `components/graph/Flag.prompt.md`, `components/content/FileRow.prompt.md`, `components/forms/TextField.prompt.md`; client `_bmad-output/implementation-artifacts/design/` inspector files.
- Open items: `_bmad-output/implementation-artifacts/deferred-work.md:1075-1089` (I1, I2), :1383-1385 (I3), :2251-2254 (I4), :2311-2313 (I5).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- export the `ShowEntry` family (+ `ActionOutcome` if absent).
- `packages/zanshin_ui/lib/src/controls/zs_resize_edge.dart` -- end an active drag in `dispose` (I3); test in `zs_resize_edge_test.dart`.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphDetails`, `RepoGraphDetails`; a Dart `joinMessageParagraphs` mirroring the CLI; `GraphDescribe` command shows one `-m` per paragraph.
- `app/lib/src/features/graph/graph_view_model.dart` -- I5 in `_succeeded`.
- `app/lib/src/features/graph/graph_inspector.dart` (new) -- `InspectorViewModel` (fetch, late-reply drop, drafts, form state, Esc steps, `describe()` entry point) and `GraphInspector` (header, flags, title/describe form, meta, chips, action row, file list, stale/empty states, entrance motion).
- `app/lib/src/features/graph/graph_view.dart` / `graph_canvas.dart` -- `GraphView.inspector(...)` factory; covered reveal on open (I4).
- `app/lib/src/features/shell/floating_shell.dart` -- the inspector's `ZsResizeEdge` and exit motion (keep the last inspector during the exit).
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- every inspector string, "Inspector width".
- `app/widgetbook/folders/graph.dart` -- the floating-shell use case hosts the inspector over a fake `GraphDetails` (entries derived from the recorded layout; one rename, one merge) and answers `GraphRevert` with a born id.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `ledger.rs`, `main.rs` -- I1.
- Tests: `app/test/features/graph/graph_inspector_test.dart` (new) -- every matrix row, the action row per state with tooltips, flag swatch + no ◆, unique prefix spans, chips, the `show()` snapshot cycle converges (a fake whose `show` bumps the op once → one refetch, then stable), no diff request, only Zs controls, reduce motion fades without a slide, stale; `graph_view_model_test.dart` -- I5; shell test -- edge drag 380–720 / graph limit / double-click 460 / keys, edge removed mid-drag releases calm, exit keeps the panel until done, top 60; canvas test -- covered vs uncovered on open; catalogue smoke test pumps the use case with a selection.
- `_bmad-output/planning-artifacts/epics.md` -- re-point I2's citations to `RepoHandle.show`; a dated "Built 2026-10-31" note under 10.8 (shipped; handed on to 10.15, 10.24, 10.25, 10.10, 11.7, 9.29, 10.12); `deferred-work.md` -- resolution sub-bullets on I1–I5.

**Acceptance Criteria:**
- Given the catalogue's floating-shell use case with a mutable change selected, when it builds, then the inspector shows at top 60 with header, flags, title, meta, chips, action row and file list, and the minimap is hidden.
- Given a describe form with "S" / "D", when Save is pressed, then the actions fake receives exactly one `GraphDescribe` whose text is "S\n\nD\n", and pressing Save again unchanged sends nothing.
- Given the parity oracle, when `describe_gui_text` runs, then Zanshin and the CLI agree and no ledger row names it.
- Given an edge drag in progress, when the selection is cleared, then the shell's `edgeDragging` is false and `calm.held` is false.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 28 findings — high 0, medium 1, low 21, false 6, maybe-false 0 (the reviewed diff excludes the generated `app_localizations*.dart` and this spec)
- findings:
  - `[low]` `[patch]` (verification-gap) a refused Save keeping the form and draft is untested — added a refusing fake and a test.
  - `[low]` `[patch]` (verification-gap) the Conflict flag is never exercised — added a conflicted entry and a test.
  - `[low]` `[reject]` (verification-gap other) `_shellInsets` in graph_view_test.dart pairs `inspectorWidth: 460` with the minimap inset — test fixture only; the I4 test defines its own closed/open insets.
  - `[low]` `[reject]` (edge) `RepoGraphDetails.show`'s `.single` throws `StateError` on 0 or 2+ entries — a full commit id revset resolves to exactly one commit or the backend refuses with a `ZanshinFfiException`; not reachable in use, a broader catch adds a branch.
  - `[low]` `[patch]` (edge) a refusal at a new operation keeps the old `changeActions` previews — the refusal branch clears `_actions` too.
  - `[low]` `[patch]` (edge) `_DescribeFormState._save`'s `.then` focuses a disposed node after the inspector unmounts mid-save — `mounted` guard.
  - `[medium]` `[patch]` (edge) an untouched Save on a description without the blank line (or without its trailing newline) writes an operation — unchanged now also means "fields equal their prefill"; the implementation run's deferred-work bullet asking Ralph is removed (CLI-parity / spec rule "nothing when unchanged", no decision needed).
  - `[low]` `[patch]` (edge) Esc closes a hidden form (open state set while stale or immutable) instead of the panel — Esc uses the form-shown condition.
  - `[low]` `[reject]` (edge) the inspector's resize edge sits outside the entrance fade, so its hairline shows at full opacity for the 200 ms entrance — cosmetic; putting the edge under the presence needs restructuring the sibling layout the shell contract requires.
  - `[low]` `[patch]` (edge) the mutable title's semantics label is empty while loading — falls back to the placeholder.
  - `[low]` `[reject]` (edge) a transient `show` refusal is never retried until the next operation or reselect — needs new retry behaviour; the next reload (any op, a watcher event) refetches.
  - `[low]` `[patch]` (blind) `_save`'s `.then` after unmount — same as the edge finding; same guard.
  - `[low]` `[reject]` (blind) divergent/hidden nodes ask `changeActions` by change id, so Squash's reason falls back to "Comes with the commit composer" — Squash stays disabled either way; only the reason text differs on a rare node kind, and `changeActions` takes a change id.
  - `[low]` `[reject]` (blind) `.single` StateError — same as the edge finding.
  - `[low]` `[patch]` (blind) the oracle's input is not tied to the Dart join — a ports test pins `fromParagraphs(['C described','Details'])` to the scenario's exact string.
  - `[low]` `[reject]` (blind) the resize edge's entrance fade — same as the edge finding.
  - `[low]` `[reject]` (blind) a divergent/hidden parent falls back to 8 chars of the change id in the meta — rare node kind; mapping change ids to commit-id keys needs a lookup the layout does not offer.
  - `[low]` `[reject]` (blind) the file list's ↑↓ highlight has no row semantics — the list is one labelled stop (DS FileRow); per-row selected semantics come with 10.24/10.25's row actions.
  - `[false]` `[reject]` (blind) ⌘↩ can save twice within a frame — `GraphViewModel._execute` returns `GraphActionDisabled(busy)` while a run is in flight; the second save is refused and changes nothing.
  - `[low]` `[reject]` (blind) missing tests for ⌘↩, the busy reason, `_shortId`'s 12-hex shortcut, A/D/C letters, reveal after a quick close — each a direct mapping of an existing tested path; low value.
  - `[false]` `[reject]` (blind) the kept "last inspector" holds a disposed model in the tree — `ZsPresence` unmounts its child after the exit (shell test "kept for the exit … findsNothing"); only an unmounted widget object is referenced.
  - `[low]` `[reject]` (blind) the Immutable tooltip repeats its label — placeholder until 11.7's reason (deferred).
  - `[low]` `[reject]` (blind) "Close (Esc)" is spoken with its bracket — the epic names the control "Close (Esc)" and `ZsIconButton` uses one label for tooltip and name.
  - `[low]` `[patch]` (blind) the describe fields have no accessible name once filled — `ZsTextField.label` passed.
  - `[false]` `[reject]` (intent) R-A vs R-B: the inspector is not reachable in the app — mounting the graph and its slots in the project window is 10.12's (epic context, 10.7 precedent); the witnesses run in the catalogue's floating shell.
  - `[false]` `[reject]` (intent) I2 adds a dated line number beside the method name — the method name is cited as asked; the line number is extra context, not a stale citation.
  - `[false]` `[reject]` (intent) I5's proxy "selection non-null" vs "inspector open" — the inspector is open exactly while something is selected (epic 2026-10-14 note); before 10.12 a selection moving to the born revert is harmless and is what the inspector will show.
  - `[false]` `[reject]` (intent) I3/I4 witnesses do not drive a real deselect/inspector through `GraphView` — the shell test flips the slot mid-drag exactly as a deselect does (the slot is `GraphView.inspector`, null on no selection), and the I4 test drives `GraphView` with the shell's insets; same observable surface.

## Design Notes

- **Immutable reason:** 10.6 handed the `revsetCounts` reason producer to 11.7 (epics.md:9468); 10.8 shows the swatch and "Immutable" and gains the reason when 11.7's cached producer lands (10.8 and 10.15 reuse it). Deferred item below.
- **Squash's enabled-state reason** "Comes with the commit composer" is Claude's proposal for the case the backend allows it; the epic only says it stays disabled until 10.25.
- **Esc on a dirty draft** unfocuses, a second Esc closes the form; the draft lives on for the session (decision (g), Claude's proposal).
- **"Describe…" from the card menu:** 10.15 builds the menu; 10.8 ships `InspectorViewModel.describe(key)` (select + open form) and tests it.
- Behind/diverged chips wait for 9.29, as the 2026-10-14 note says.

## Verification

**Commands:**
- `cargo test -p zanshin-parity --test oracle` -- green, no `describe_gui_text` row.
- `cargo clippy -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean.
- `flutter test` in `packages/zanshin_ui`, `packages/zanshin_core` (barrel test if any), and `app` (`test/features/graph test/features/shell test/widgetbook`) -- green.
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .` in each touched Dart package -- clean.

**Manual checks:**
- Marionette in the catalogue: Graph › Floating shell, select a card — the inspector in night and paper vs DS inspector cards; describe form open; stale off.

**Verification notes (2026-10-31; gate rule of the story loop: no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-parity --test oracle` -- 501 passed (no `describe_gui_text` row; the CHANGED witness now uses `new_unresolvable_immutable`).
- `cargo clippy -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `packages/zanshin_ui`: `flutter test` 429 passed; `dart analyze --fatal-infos` no issues; `dart format --set-exit-if-changed .` 0 changed.
- `packages/zanshin_core`: `dart analyze --fatal-infos` no issues; `dart format --set-exit-if-changed lib` 0 changed (only the barrel changed; no suite run).
- `app`: `flutter test test/features/graph test/features/shell test/widgetbook test/l10n` 856 passed after the review patches (853 before); `dart analyze --fatal-infos` no issues; `dart format --set-exit-if-changed .` 0 changed.
- No FFI or schema change: no `cargo make codegen`. Marionette catalogue check not done (needs a long-lived `flutter run`, not possible in this unattended run).

## Auto Run Result

Status: done. Code commit `21fa91deb092f802cfb6d206e8054a246c31f853`, plus the docs commit that carries this spec (and the earlier context refresh `577af2c2`).

**Summary.** The inspector for the selected change: `GraphInspector` + `InspectorViewModel` over a new `GraphDetails` port (`show` + `changeActions`), the header with jj's unique prefix bold and the flags (hatch Immutable, no ◆), the title as the describe field with a Summary/Details form (Save = the CLI's `-m` paragraphs, nothing when unchanged, drafts per change for the session, Esc order form → panel), meta, bookmark chips, the action row by state with full-command tooltips (Squash disabled until 10.25), the file list with its empty, stale and refusal states, the resize edge (380–720) and exit motion in `FloatingShell`, the covered-selection reveal on open, and the catalogue's Floating shell use case hosting it over fakes. Mounting in the project window stays 10.12's.

**Files.**
- `app/lib/src/features/graph/graph_inspector.dart` (new) -- `InspectorViewModel`, `GraphInspector` and its sections.
- `app/lib/src/features/graph/graph_ports.dart` -- `joinMessageParagraphs`, `GraphDescribe.fromParagraphs`, `GraphDetails`, `RepoGraphDetails`.
- `app/lib/src/features/graph/graph_view_model.dart` -- I5: revert selects the born change.
- `app/lib/src/features/graph/graph_view.dart`, `graph_canvas.dart` -- `GraphView.inspector`; covered reveal when the inspector opens.
- `app/lib/src/features/shell/floating_shell.dart`, `pinned_panel.dart` (`ShellPanelMotion.drift`), `shell_layout.dart`, `graph_insets.dart` -- inspector edge, exit, `inspectorWidth` 0 while closed.
- `packages/zanshin_ui/lib/src/controls/zs_resize_edge.dart`, `zs_control_core.dart` -- I3: a drag ends in `dispose`; a removed control ignores its pointer-up.
- `packages/zanshin_core/lib/zanshin_core.dart` -- exports `ShowEntry`, `Change`, `Signature`, `FileChange`, `FileChangeKind`.
- `crates/zanshin-parity/tests/oracle/{scenarios,ledger,main}.rs` -- I1.
- `app/lib/l10n/app_en.arb` (+ generated) -- inspector strings.
- `app/widgetbook/folders/graph.dart` -- the inspector in Floating shell › Controls.
- Tests: `graph_inspector_test.dart` (new), `graph_ports_test.dart`, `graph_view_model_test.dart`, `graph_view_test.dart`, `floating_shell_test.dart`, `pinned_panel_test.dart`, `shell_layout_test.dart`, `catalogue_smoke_test.dart`, `zs_resize_edge_test.dart`.
- Docs: epics.md (I2 re-pointed, "Built 2026-10-31" note), deferred-work.md (I1–I5 resolved; "Surfaced in Story 10.8"), sprint-status 10-8 done.

**Open items.**
- I1 — fixed (commit 21fa91de): `describe_gui_text` sends what Save sends ("C described\n\nDetails\n" vs `jj describe -m 'C described' -m Details`), agrees with the CLI, its ledger row is gone; a Dart test pins `fromParagraphs` to that exact string.
- I2 — fixed (docs commit): both 10.8 citations in epics.md name `RepoHandle.show`.
- I3 — fixed (commit 21fa91de): the inspector can close mid-drag (graph Esc, a reload dropping the selection); `ZsResizeEdge.dispose` ends the drag (`onDragEnd`, `onChangeEnd` when changed); witnessed in `zs_resize_edge_test.dart` and `floating_shell_test.dart`.
- I4 — fixed (commit 21fa91de): when the inspector opens, a covered selection scrolls clear (`GraphRevealAlignment.covered`); an uncovered card and a width drag move nothing (`graph_view_test.dart`).
- I5 — fixed (commit 21fa91de): a revert with a selection (the inspector open) selects the born change (`graph_view_model_test.dart`).

**Review.** 28 findings: 10 patched (1 medium: an untouched Save on a non-canonical description wrote an operation; 9 low: unmount guard, stale previews on refusal, Esc on a hidden form, loading title label, field names, and tests for refused Save, Conflict, the oracle string), 18 rejected with reasons in the triage log (6 false, 12 low), 0 deferred from review. One deferred item from implementation (the Immutable flag's reason waits for 11.7), mirrored in deferred-work.md. Patched by verdict: high 0, medium 1, low 9 → follow-up review not recommended.

**Residual risks.** No Marionette/DS visual check (spacing, night/paper look unverified); the resize edge's hairline does not take the 200 ms entrance fade; `RepoGraphDetails` has no real-repo test (no host constructs it until 10.12); the full gate runs at the loop's end.

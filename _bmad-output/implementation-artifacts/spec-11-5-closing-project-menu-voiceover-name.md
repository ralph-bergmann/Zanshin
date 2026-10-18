---
title: 'Story 11.5 closing run — the Project menu gets its VoiceOver name'
type: 'bugfix'
created: '2026-10-18'
status: 'done'
baseline_revision: '837d20be409f360b7ed5ba124f8cf64664a468be'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (deferred-work.md "Surfaced in Story 11.5", surfaced during the build), verified against the current code: the DS names the Project menu "Project" (`<Menu aria-label="Project" …>`, DS components/menus/ProjectMenu.jsx:30, overriding Menu.jsx:82's `aria-label={subject}` through `...rest`), but `ZsMenuPanel` names its container only through `subject` (`Semantics(container: true, label: subject)`, `packages/zanshin_ui/lib/src/controls/zs_menu.dart:837-840`), and `subject` also draws the head (`_Head`, `:809-813`), which the Project menu does not have; `ProjectCapsule` passes no subject (`app/lib/src/features/projects/project_capsule.dart:166-173`), so VoiceOver reads the open Project menu without a name.

**Approach:** As the ledger's follow-up proposes: `ZsMenuAnchor` (and the unexported `ZsMenuPanel` it builds) gain `semanticLabel` (String?), the menu's VoiceOver name apart from the head; the container's label is `semanticLabel ?? subject`, the head still shows only `subject`. `ProjectCapsule` passes `semanticLabel: 'Project'`.

## Boundaries & Constraints

**Always:**
- The field is named `semanticLabel`, as `ZsSheet.semanticLabel` and `ZsFieldList`'s are; its doc says it is the menu's VoiceOver name, read instead of [subject], and draws nothing (DS ProjectMenu.jsx:30 cited where the capsule passes it).
- Without `semanticLabel` every menu reads and draws exactly as today: the subject names the container and fills the head; neither → no name, no head. Submenus, `ZsSelect`'s list and the text field's context menu pass none.
- The DS literal "Project" is spelled as the DS writes it (sentence case).
- SPDX first line, page width 120; `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` clean in `packages/zanshin_ui` and `app/`.

**Never:**
- No change to the Project menu's rows, order, widths, placement or behaviour, or to the capsule's own semantics (still a button named after the project, status value, expanded).
- No menu role or other new semantics flag; no head for the Project menu; no change to `_Head`.
- No change to Story 11.5's other code; no golden tests; no edits under `design/` or `design_system/`; no change to existing deferred-work.md bullets, `epic-11-context.md`, `epics.md`, `sprint-status.yaml` or the Story 11.5 spec; never lower `coverage-baseline.txt`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Name, no head | `ZsMenuAnchor(semanticLabel: 'Project')`, no subject, opened | the panel's container node is labelled "Project"; the panel draws no head (no "Project" text inside it) | — |
| Name beside a subject | `subject: 'feat(onboarding): swipe gestures'`, `semanticLabel: 'Change menu'` | container labelled "Change menu"; the head shows the subject | — |
| Subject only | `subject:` set, no `semanticLabel` | container labelled by the subject, head shown (as today) | — |
| Project menu | `ProjectCapsule`'s menu opened | the container around the menu material is labelled "Project"; no "Project" text in the menu; RECENT is still its first row; rows' labels unchanged | — |

</intent-contract>

## Code Map

- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `ZsMenuAnchor` :171-224 (ctor :173-186, `subject` :203-204, class doc's VoiceOver sentence :168-170); `_ZsMenuAnchorState.build` :290-344 passes `subject`/`headLeading` to `ZsMenuPanel` at :322-338 (inside `Semantics(identifier: widget.identifier)`); `ZsMenuPanel` ctor :424-444, `subject` field :455-456; `ZsMenuPanelState.build` :805-863 — head at :809-813, container `Semantics(container: true, explicitChildNodes: true, label: subject)` at :837-840. Submenus build `ZsMenuPanel` at :890-904 without a subject.
- Other `ZsMenuPanel` builders (read-only, must stay unchanged): `grep -rn "ZsMenuPanel(" packages/zanshin_ui/lib` — `zs_select.dart`, the text field's context menu.
- `app/lib/src/features/projects/project_capsule.dart` -- `_ProjectCapsuleState.build` :161-198, the `ZsMenuAnchor(…)` at :166-173 (add the name there); class doc :13-30 ("VoiceOver reads …" :20-22).
- DS (read-only): `_bmad-output/implementation-artifacts/design_system/components/menus/ProjectMenu.jsx:30` (`aria-label="Project"`), `Menu.jsx:82-90` (`aria-label={subject}`, the head only with `id`/`subject`).
- Tests: `packages/zanshin_ui/test/controls/zs_menu_test.dart` — `_host` :39-70 (hard-coded subject, button "Actions"), `_projectHost` :105-132 (button labelled "Project": scope "no head" checks to `find.descendant(of: find.byType(ZsMenuPanel), …)`), `_openByKey` :79-85, the subject test :457-468 (pattern: `handle = tester.ensureSemantics()`; `tester.getSemantics(find.byType(ZsMenuPanel))` yields the container node); `app/test/features/projects/project_capsule_test.dart` — `_Rig.host` :55-84, `_menu()` = `find.byType(ZsMenuMaterial)` :86, `_openByClick` :103-107, the menu-order test :287-368 (RECENT first row).
- Gate: `zanshin_ui` + `app` Dart change → the change-aware plan runs both packages' Flutter tests, analyze and format; no Rust or `zanshin_core` change, so coverage does not run.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `ZsMenuAnchor.semanticLabel` and `ZsMenuPanel.semanticLabel` (String?, optional); the anchor passes it to its panel; the panel's container label becomes `widget.semanticLabel ?? subject`; docs: the field (VoiceOver name, read instead of the subject, draws nothing), `subject` ("read as its name unless [semanticLabel] gives one"), the class doc's VoiceOver sentence -- the item's library half.
- `packages/zanshin_ui/test/controls/zs_menu_test.dart` -- the matrix's first three rows: a test opening a menu with `semanticLabel` and no subject (container labelled, no head text inside the panel), with both (container takes `semanticLabel`, head shows the subject), and the subject-only case staying as today.
- `app/lib/src/features/projects/project_capsule.dart` -- pass `semanticLabel: 'Project'` (cite DS components/menus/ProjectMenu.jsx:30); the class doc's VoiceOver sentence adds that the menu is named "Project" -- the item's app half.
- `app/test/features/projects/project_capsule_test.dart` -- the matrix's Project menu row: open the menu, expect the node labelled "Project" to contain the menu material, no "Project" text in the menu, RECENT still the menu's first row.

**Acceptance Criteria:**
- Given VoiceOver on and the capsule focused, when the Project menu opens, then the menu's container announces "Project" and the menu shows no head (its first row is RECENT, as before).
- Given the change, when `flutter test`, `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` run in `packages/zanshin_ui` and `app/`, then all pass with every existing menu and capsule test unchanged.
- Given the change, when `cargo make test` runs unpiped from the repo root, then it exits 0 and `coverage-baseline.txt` is unchanged.
- Given the running catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`, Marionette), when `projects/project-capsule/menu-open` is opened, then the menu renders as before (no head above RECENT).

## Spec Change Log

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 16 findings — high 0, medium 0, low 9, false 4, maybe-false 3
- findings:
  - `[low]` `[patch]` (blind 1) `_host`'s new `subject` parameter has no caller that passes it — patched: the parameter is gone, `_host` passes `subject: _subject` inline (the no-subject case runs through `_projectHost`).
  - `[low]` `[patch]` (blind 2) The new `_subject` const is half adopted: the existing subject test still spells the literal, and the subject-only test overlaps it — patched: the existing test uses `_subject`; the subject-only test stays, it is the matrix row's exact-node witness (`getSemantics(find.byType(ZsMenuPanel))` plus the head text), which the older `findsWidgets` check is not.
  - `[low]` `[patch]` (blind 3) The capsule test's name check (`find.ancestor(…bySemanticsLabel('Project'))`, `findsWidgets`) passes for any number of "Project" nodes above the menu — patched: `findsOneWidget`. The suggested `getSemantics(_menu())` was tried and lands on an unlabelled 300 × 283 node inside the named container, so it cannot pin the container; `ZsMenuPanel` is not exported to the app. A deliberate break (no `semanticLabel` in the capsule) fails the patched test.
  - `[low]` `[patch]` (blind 4) The RECENT-first-row loop re-evaluates the finder on every pass and reports no culprit on failure — patched: one list of the texts above RECENT, expected empty with a reason.
  - `[low]` `[patch]` (blind 5) The capsule's class-doc clause "the open menu it reads as "Project"" reads badly — patched: the capsule sentence is restored and the **Menu.** paragraph says "VoiceOver names the open menu "Project" (ProjectMenu.jsx:30); it has no head."
  - `[low]` `[reject]` (blind 6) An empty `semanticLabel` silences a subject-named menu, since `??` falls back only on null — no caller passes an empty name (the one caller passes "Project"), null is the field's documented absence (house rule: null means absent), and treating "" as absent adds a branch for an input nothing supplies.
  - `[low]` `[patch]` (blind 7) Nothing pins that submenus stay unnamed under a named menu — patched: "VoiceOver: a submenu does not take its menu's semanticLabel" opens `More` under a menu named "Change menu" and expects the submenu panel's label empty and exactly one "Change menu" node; a deliberate break (forwarding the field to the submenu's panel) fails it.
  - `[maybe-false]` `[defer]` (blind 8) Nothing shows that VoiceOver itself speaks "Project": the tests and the live check stop at Flutter's semantics tree, and the engine reports a labelled, flagless container as a group — whether macOS VoiceOver reads the Zs controls' semantics (names, hints, roles) is already Story 11.11's ledger item (deferred-work.md:1295-1297, Medium unverified; follow-up: check a menu with Accessibility Inspector); not added again. Rewording the AC would edit this build's spec.
  - `[low]` `[reject]` (edge 1) `semanticLabel: ''` with a subject leaves the menu unnamed — same root cause as blind 6, rejected there.
  - `[maybe-false]` `[defer]` (intent a) The intent's expectation lives at VoiceOver on macOS while the diff and tests exercise only Flutter's semantics tree — grouped with blind 8: already Story 11.11's ledger item, not added again.
  - `[maybe-false]` `[defer]` (intent b) The DS gives the menu `role="menu"` plus the name; the diff adds the name only — grouped with blind 8: the macOS bridge derives roles from flags only (deferred-work.md:1295-1297 names "menu roles"), every Zs menu shares it, and the item asked for the name; not added again.
  - `[low]` `[patch]` (intent c) The capsule test's ancestor check is looser than the library test's exact-node check — grouped with blind 3; patched there.
  - `[false]` `[reject]` (intent d) The "no head" and RECENT checks pass on the baseline too, so only the label checks tell the fix apart — they are the matrix's regression guards for the "no head" half of the item by design; the label checks failed on the baseline-equivalent breaks in the implementation run and in this pass.
  - `[false]` `[reject]` (intent e) The catalogue check is not evidenced by the diff — it ran in the implementation run (Marionette screenshot and a live semantics dump) and is recorded in the Auto Run Result; a manual check does not live in the diff.
  - `[false]` `[reject]` (intent f) The process half (Auto Run Result, deferred mirror) is missing from the diff — written at finalize; with no new deferral, deferred-work.md takes no new section.
  - `[false]` `[reject]` (intent g) The change reaches into `zanshin_ui`, Story 11.11's code — the item names `ZsMenuAnchor` and `ZsMenuPanel`'s container as its location; Story 11.5's own code changes by one argument and one doc line.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` and in `app/` -- expected: all pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_ui` and `app/` -- expected: clean.
- `cargo make test` (repo root, unpiped; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0, coverage baseline unchanged.

**Manual checks (if no CLI):**
- Claude's check (project-context.md "UI tooling"): run the catalogue, connect Marionette, open `projects/project-capsule/menu-open`, screenshot: the menu looks as before (no head). The change adds no pixels; VoiceOver itself is not reachable from this seat — record what was and was not seen in the Auto Run Result.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none. Code commit: 4455307569c3e2a994e17b26f2011d482c5f5da1.

**Items handed to this closing run.**
1. **The Project menu has no VoiceOver name — fixed** (commit `4455307569c3e2a994e17b26f2011d482c5f5da1`).
   - Verified first: the panel's container was `Semantics(container: true, label: subject)` (`packages/zanshin_ui/lib/src/controls/zs_menu.dart`, `ZsMenuPanelState.build`), the same `subject` draws the head (`_Head`), and `ProjectCapsule` passed no subject, so the open Project menu had no name; the DS names it with `aria-label="Project"`, which overrides `Menu.jsx:82`'s `aria-label={subject}` through `...rest` and draws no head (DS components/menus/ProjectMenu.jsx:30).
   - `ZsMenuAnchor` and the unexported `ZsMenuPanel` take `semanticLabel` (the ledger's follow-up, Claude's proposal); the container reads `semanticLabel ?? subject`, the head still shows only the subject; the capsule passes "Project". Story 11.5's code changed by that one argument and one doc line.

**Summary.** One item, fixed: VoiceOver's tree now names the open Project menu "Project" while the menu keeps no head (RECENT stays its first row). Every other menu reads and draws as before: without `semanticLabel` the subject names the menu and fills its head; submenus, `ZsSelect`'s list and the text field's context menu pass no name.

**Files changed:**
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` — `ZsMenuAnchor.semanticLabel` / `ZsMenuPanel.semanticLabel`; the container label falls back to the subject; docs for the field, `subject` and the VoiceOver sentence.
- `packages/zanshin_ui/test/controls/zs_menu_test.dart` — four tests: a name without a subject (no head), a name beside a subject (head kept), subject only (as before), a submenu not taking the name; `_host` / `_projectHost` take `semanticLabel`.
- `app/lib/src/features/projects/project_capsule.dart` — passes `semanticLabel: 'Project'` (DS citation); the **Menu.** doc paragraph names it.
- `app/test/features/projects/project_capsule_test.dart` — the open menu sits under exactly one node labelled "Project", shows no "Project" text, and no text above RECENT.
- Tracking: this spec. No new deferral, so `deferred-work.md` gets no new section.

**Review findings.** 16 findings (high 0, medium 0, low 9, false 4, maybe-false 3).
- **Patched, 6 entries (all low):** the unused `subject` parameter removed from the test host; the existing subject test uses `_subject`; the capsule's name check is `findsOneWidget` (blind 3 + intent c); the RECENT check is one expectation naming any text above it; the capsule's doc clause reworded into the **Menu.** paragraph; a submenu-stays-unnamed test. The implementation subagent was not re-engaged (a resumed agent reports asynchronously, which this unattended run cannot wait for), so the parent applied the patches.
- **Deferred:** none new. Blind 8 with intent a and b (VoiceOver itself and the DS's `role="menu"` are not observed; the engine derives roles from flags only) is already Story 11.11's ledger item (deferred-work.md:1295-1297, Medium unverified, follow-up: check a menu with Accessibility Inspector) and was not added again.
- **Rejected, low:** an empty `semanticLabel` silencing the subject (blind 6 + edge 1: no caller passes "", null is the documented absence, a branch would guard an input nothing supplies).
- **False, 4:** the baseline-passing "no head" guards (by design; the label checks fail on the breaks), the catalogue check outside the diff (recorded here), the process half outside the diff (written at finalize), the change reaching into `zanshin_ui` (the item's own location).

**Follow-up review recommendation:** false — this pass patched 6 entries, all low (0 high, 0 medium).

**Verification:**
- `cargo make test` (repo root, unpiped to a log, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset): exit 0 in the implementation run (app 526, zanshin_ui 396, analyze and format clean in both); after the review patches one run stopped on `omit_obvious_local_variable_types` in the new capsule test (fixed), then exit 0 (the change-aware plan ran the app's and `zanshin_ui`'s test, analyze and format steps: app 526, zanshin_ui 397, no issues, 0 files changed); no Rust or `zanshin_core` change, so coverage did not run and `coverage-baseline.txt` is unchanged.
- Matrix audit: every row has a passing test, run by name with the expanded reporter — name without a head, name beside a subject, subject only (`zs_menu_test.dart`), Project menu (`project_capsule_test.dart`); the rows' labels are the existing menu-order test's, unchanged and passing.
- Deliberate breaks: wiring the container back to `subject` failed both library `semanticLabel` tests and dropping the capsule's name failed the capsule test (implementation run); in the review pass, dropping the capsule's name failed the tightened capsule test and forwarding the name to the submenu's panel failed the new submenu test. Each was restored.
- Seen in the running catalogue (implementation run; `flutter run -d macos -t widgetbook/main.dart`, Marionette `zanshinCatalogue.open` at `projects/project-capsule/menu-open`): the menu as before — no head, RECENT first, five Recent rows, All Projects… ⇧⌘O, Project Settings…, Settings… ⌘,; a live semantics dump showed the `project-menu` node, then a container labelled "Project", then the scroll node with RECENT and the rows unchanged. The catalogue was shut down afterwards.
- Not seen: VoiceOver speaking the name and the role macOS reports for the container (no VoiceOver or Accessibility Inspector from this seat); the review patches changed tests and docs only, so the catalogue was not re-checked after them.

**Residual risks:**
- Whether macOS VoiceOver announces a flagless labelled container's name on entering the menu (focus moves straight to the highlighted row) is unobserved; it is part of Story 11.11's open ledger item on the macOS accessibility bridge.

---
title: 'Story 10.30 — Review findings 2026-11-02: revset errors, the $ pill, ID copy, uniform graph ports'
type: 'feature'
created: '2026-11-02'
status: 'done'
baseline_revision: 'af7e0412d60bb643f20cced3f50544efa2df8e26'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      Merge-up exits deviate from the uniform port rules: never at the centre, 4 px outside their fan slot.
    evidence: |-
      The literal rules gave 199 collinear overlaps on the 10k synthetic free layout; _mergeUpShift keeps the invariants (rule 5) green. Needs Ralph's OK.
    location: >-
      packages/zanshin_core/lib/src/graph_layout/router.dart _mergeUpShift
    severity: medium
  - summary: >-
      The non-first straight parent decision never applies: only a first parent is kindStraight; a same-column second parent is a gutter line.
    evidence: |-
      Pinned by router_test story_10_30_a_merge_whose_first_parent_bends_leaves_the_entry_centre_free; Ralph decides on a geometric reading.
    location: >-
      packages/zanshin_core/lib/src/graph_layout/router.dart _entries
    severity: low
  - summary: >-
      Alias / parameter-expansion revset errors' one-line message names the expansion, not the failure inside it.
    evidence: |-
      render_message reads the top-level pest render only; the CLI prints the cause chain.
    location: >-
      crates/zanshin-jj/src/revset.rs render_message
    severity: low
  - summary: >-
      The inspector's copyable ids work only with a pointer (no focus, no Enter/Space), app and DS kit.
    evidence: |-
      _CopyId is GestureDetector + Semantics(onTap); ZKCopyId has tabIndex but no key handler.
    location: >-
      app/lib/src/features/graph/graph_inspector.dart _CopyId
    severity: medium
  - summary: >-
      The DS UI kit reads the new port API from a not yet regenerated bundle and counts entry lines by edges, not slot owners.
    evidence: |-
      layout.js uses GP.MERGE_UP_SHIFT / GP.exits absent from _ds_bundle.js until republish (NaN meanwhile); ins.length === 1 and sign-0 approaches differ from router.dart.
    location: >-
      _bmad-output/implementation-artifacts/design_system/ui_kits/desktop/layout.js
    severity: low
  - summary: >-
      Copying a parent id is tested only for a parent inside the layout.
    evidence: |-
      _Meta._parents() not-in-layout and stale branches untested for the copied full id.
    location: >-
      app/lib/src/features/graph/graph_inspector.dart _Meta._parents
    severity: low
  - summary: >-
      The raw rule's field-mark guard (span on the term's wrapper, or the value not found in its term) has no test.
    evidence: |-
      Both window tests (revset_configs_window_test.dart:357, :387) take the inside == true path; dropping the guard would fail neither.
    location: >-
      app/lib/src/features/graph/revset_configs/revset_configs_window.dart:423-435 fieldSpan
    severity: low
  - summary: >-
      The inspector's copyable ids tell assistive tech nothing about copying: no hint, "Copied" and the failure popover are not announced.
    evidence: |-
      _CopyId wraps the id in Semantics(label: full, button: true) only; no hint, no SemanticsService.announce / liveRegion.
    location: >-
      app/lib/src/features/graph/graph_inspector.dart _CopyId
    severity: low
  - summary: >-
      epic-10-context.md still lists Story 10.30 as backlog, and its "show jj's own error text in place" rule now contradicts the new one-sentence rule beside it.
    evidence: |-
      epic-10-context.md:41 "(backlog)"; :51 vs :52 not reconciled. A compiled planning cache, so it is left to its next recompile.
    location: >-
      _bmad-output/implementation-artifacts/epic-10-context.md:41,51
    severity: low
---

<intent-contract>

## Intent

**Problem:** Ralph's walk through the running app (epics.md Story 10.30) found: raw-revset errors render jj's pest output (`-->`, `|`, `^---`) in a proportional font; `ZsTextField` loses focus when its message appears/disappears; the `$` pill's accent tint reads as an error/focus; a commit-ID tooltip hangs over "Squash to parent"; the inspector header shows no short commit ID and nothing copies; graph exits and entries use two different port rule sets.

**Approach:** Six fixes, all decided by Ralph (final): a backend one-sentence `message` on `RevsetErrorDetail` shown at the raw rule, in the preview and with the span marked in the field; one stable `ZsTextField` structure; no pill tint (app + DS); inspector click-to-copy IDs with `jj`/`git` subscripts (app + DS), which also removes the hanging tooltip; one port rule set in `router.dart` and `design/graph-layout.jsx`.

## Boundaries & Constraints

**Always:**
- Item 1: the message is built in Rust (`zanshin-jj`), carried over the FFI (`schemas/envelope.fbs` field APPENDED to `RevsetErrorDetail`, `cargo make codegen`, commit both sides) and into the Dart `RevsetErrorDetail`; Dart never parses jj's text. Parse error: `"<Syntax error|Error> at <1-based char column>: <pest message line>"` (e.g. `Syntax error at 93: expected `::`, `..`, `~`, or an expression`); a spanless parse error (`without_span`) drops the ` at N`; a resolution error's message is jj-lib's one-line `Display`. Keep "Did you mean …" candidates. The command preview shows the same sentence.
- Item 2: `ZsTextField` builds the same widget structure with and without a message (the message slot toggles inside it), so the `EditableText` keeps its state and focus.
- Item 3: no tinted pill state at all; the view name's 500 weight in the field stays.
- Item 5: header = short change ID (max(prefix, 8), bold prefix, as the card/peek) + subscript `jj`, short commit ID (max(commit prefix, 8), bold prefix) + subscript `git`, subscripts in `--text-faint` and lowered; the parent ids in the meta line copy too. Click copies the FULL id; tooltip "Click to copy" over the full id (mono); "Copied" shows briefly after a click; a failing clipboard write opens a small popover with the full id as selectable text that stays until dismissed (tap outside / Esc). Graph cards and peek keep click = select. l10n strings in `app_en.arb` (+ regenerated localizations).
- Item 6 rules (top and bottom alike): one line → centre; several → the `kindStraight` line takes the centre, the others fan to their side; several and none straight → centre free; fan = the entry fan (first 24 px, 16 px steps, squeezed to 8, overflow shares the outermost; max `w/2 − 18`). Inner/outer sort orders, shared entry slots (`slots[k] != k` reuse the owner's x), gutter routing, clearance and invariant checks unchanged. Line count at an entry = distinct slot owners.
- DS / prototype edits in place: `design_system/` (SearchDollar/GraphSearch tint removed; ChangeId / inspector header copy variant), `design/graph-layout.jsx` (same port rules), and entry `#16 · 2026-11-02` in `design/DESIGN-SYSTEM-SYNC.md`. No artifact republish. Do not hand-edit generated bundles (`_ds_bundle.js`, `_ds_manifest.json`).
- Gate rule of this run: targeted checks only (no `cargo make test`/`test-full`/`coverage`).

**Never:** click-to-copy on graph cards or the peek; any other tint for the pill; revset highlighting/completion; lowering coverage baselines; running jj outside this repo or own temp dirs.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Syntax error | raw rule `a ::: b` | row + preview: `Syntax error at N: expected …`, span chars marked red in the field, no `-->`/`^---` | — |
| Unknown function | `foo()` | `Error at 1: Function `foo` doesn't exist` + "Did you mean …" | — |
| Resolution error | `nosuch` | jj-lib one-liner (`Revision `nosuch` doesn't exist`) | — |
| Error toggles | typing makes the error appear, then disappear | field keeps focus and caret, typing continues | — |
| Copy ok | click short commit id | clipboard = full commit id, "Copied" shows | — |
| Copy fails | `Clipboard.setData` throws | popover with selectable full id stays open | dismiss by tap outside / Esc |
| Lone bending exit | parent with one child in another column | exit at parent centre | — |
| Straight + bending | two outgoing | straight at centre, bending at ±24 | — |
| Left + right, none straight | two outgoing to both sides | ±24, centre free | — |
| Merge, straight not first parent | child with 2 parents, 2nd same column | straight entry at centre, 1st parent fans at ±24 | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/revset.rs:184` `RevsetErrorDetail` (add `pub message: String`); `:657` `parse_detail` (pest render: `--> L:C` header, last `= <msg>` line — `render_span` at `:720` already parses it); `:685` `resolution_detail`; `:98` `without_span` (also drop the position from `message`); `:156` `bare()` test helper.
- Literal `RevsetErrorDetail {…}` sites to extend: `crates/zanshin-jj/src/mutate.rs:2319`, `commit_views.rs:704`, `tests/it/api_stability.rs:2806`; `crates/zanshin-ffi/src/revset_search.rs:329,359`, `graph.rs:952`, `envelope.rs:2586`.
- `schemas/envelope.fbs:106` table `RevsetErrorDetail` — append `message: string`; `crates/zanshin-ffi/src/envelope.rs:1446` `build_revset_detail`; generated `envelope_generated.rs` + `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` via `cargo make codegen`.
- `packages/zanshin_core/lib/src/ffi/revset_search.dart:118` Dart `RevsetErrorDetail` + `:205` decoder; `lib/src/worker/responses.dart:~190` toString; fakes `app/widgetbook/graph/fake_graph_search_source.dart`, tests in `packages/zanshin_core/test/{ffi,worker}/revset_search_test.dart`.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart:843-851` raw rule errorText (uses `error.context`), `:385-412` span → rule mapping, `:985-995` preview status (uses `error.context`); `revset_config_expression.dart` builds terms (`revsetGroup(value)`), value offset in term = `term.indexOf(value)`.
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart:36` `ZsTextEditingController.buildTextSpan` (add an optional error range painted `colors.rem`), `:525-556` the conditional `Column` (item 2).
- `app/lib/src/features/graph/graph_search_field.dart:645` `tinted`, `:664` `_pill(tinted:)`, `:806-811` tinted colours.
- `app/lib/src/features/graph/graph_inspector.dart:945` `_Header` (ID + `ZsTooltip(message: commitId)` at `:977`), `:1321` `_Meta` parents (`TextSpan`s), `:885` `graphShortId`; `GraphCardData.commitPrefixLength` (`graph_card.dart:300`), `layout.commitIdOf/changeIdOf`.
- `packages/zanshin_ui/lib/src/controls/zs_tooltip.dart` (RawTooltip, manual trigger, `dismissDelay: 0`); `ZsTooltipBubble` is public for self-placed bubbles; `ZsMenuMaterial` for the popover surface.
- `packages/zanshin_core/lib/src/graph_layout/router.dart:28-40` exit/entry constants, `:838` `_fan`, `:852` `_exitFan` (removed), `:867` `_entries`, `:932` `_exits`; tests `packages/zanshin_core/test/graph_layout/router_test.dart`, invariants `invariants*.dart`; app tests over routes in `app/test/features/graph/`.
- `_bmad-output/implementation-artifacts/design/graph-layout.jsx:12-13,199-250` (`EXIT`, `exitFan`, entries, exits incl. `bus`).
- DS: `design_system/components/search/{search.css:14,GraphSearch.jsx,GraphSearch.d.ts,SearchMenu.jsx}`, ChangeId component + inspector header in `design_system/components/` (find by name), `design_system/readme.md`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` (+ literal sites) -- add `message`, build it in `parse_detail`/`resolution_detail`, strip position in `without_span`; inline unit tests for syntax/function/resolution/spanless messages -- item 1 backend.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/envelope.rs` (+ literal sites), `cargo make codegen` -- carry `message` -- FFI.
- `packages/zanshin_core/lib/src/ffi/revset_search.dart`, `worker/responses.dart`, tests, fakes -- `message` field (`String?`, null = absent) -- bridge.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` -- raw rule and preview show `revsetError?.message ?? context ?? code`; pass the field-local span to the raw rule's controller -- item 1 UI.
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart` -- stable structure; controller error range -- items 1/2; widget test pins focus across error toggle.
- `app/lib/src/features/graph/graph_search_field.dart` + DS search files -- drop tint -- item 3.
- `app/lib/src/features/graph/graph_inspector.dart` (+ `app_en.arb`, gen-l10n) -- `_CopyId` widget for header ids and meta parents; remove the commit-id tooltip -- items 4/5; widget tests with pointer moves (tooltip gone after leaving the id / over Squash), clipboard success and failure via `TestDefaultBinaryMessenger` mock on `SystemChannels.platform`.
- `packages/zanshin_core/lib/src/graph_layout/router.dart` + `design/graph-layout.jsx` -- uniform ports -- item 6; router tests for the four witnesses, adjust existing expectations deliberately.
- DS ChangeId/inspector docs, `design/DESIGN-SYSTEM-SYNC.md` #16 -- record the changes.
- Item 2 manual repro with Marionette in the widgetbook catalogue (Configurations window) before/after if it can be started unattended; else record as open.

**Acceptance Criteria:**
- Given a raw revset rule with a syntax error, when the count error arrives, then the row and the preview show the one-line message, the field marks the span, and no `-->`/`^---` text appears.
- Given a focused `ZsTextField`, when its `error` goes from null to a message and back, then it keeps focus and typed characters land in it.
- Given the search field at a non-default view, when it paints, then the pill uses the same colours as at the default view.
- Given the inspector, when the pointer hovers a header id then moves onto "Squash to parent", then no id tooltip remains.
- Given the inspector header, when it shows, then it reads `<short change>`ʲʲ `<short commit>`ᵍⁱᵗ; a click writes the full id to the clipboard; a failing write opens the selectable popover.
- Given the router, then: a lone bending exit leaves at the centre; straight + bending puts the straight one at the centre; left + right leaves the centre free; top and bottom offsets match for equal counts; layout invariants and goldens stay green.

## Spec Change Log

- 2026-11-02 (implementation): item 6 — a **merge-up exit never takes the centre and sits 4 px outside its fan slot** (`_mergeUpShift`). With the plain rule the synthetic 10k free layout reported 199 collinear overlaps (a lone merge-up climbing its parent's column on the centre line of the entries of the cards above), 3 with merge-ups off-centre at the plain slot; with the 4 px shift 0 — the invariant AC holds. Needs Ralph's OK. Matrix row "Merge, straight not first parent" cannot occur: the classifier makes only a first parent `straight` (a same-column second parent is a `gutter` line); pinned as "no straight line → centre free" instead.

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 40 findings — high 0, medium 6, low 21, false 11, maybe-false 2
- findings:
  - Intent auditor:
  - `[low]` `[defer]` "straight" read as `kindStraight`, not geometric same column; a non-first same-column parent is a gutter line — deferred for Ralph (deferred #2).
  - `[medium]` `[defer]` merge-up exception breaks rules 1/4 (lone merge-up not centred, +4 px) — kept because rule 5 (invariants) wins; deferred #1 for Ralph's OK.
  - `[false]` `[reject]` goldens not regenerated — the layout goldens (`test/graph_layout/goldens`) hold rows/lanes/edges, not router geometry; nothing to regenerate; invariants pass (`test-flutter` incl. layout_invariants_test).
  - `[low]` `[reject]` item 4 cause not diagnosed — the offending tooltip is removed by item 5; the pointer-move test pins that no id tooltip stays over Squash.
  - `[false]` `[reject]` item 2 Marionette repro not recorded — it was run (Widgetbook Configurations window, focus kept across error toggles); recorded under Auto Run Result.
  - `[false]` `[reject]` item 1 column relative to the composed revset — the intent's own example ("at 93") is the composed column.
  - `[low]` `[reject]` item 3 test compares to constants, not the default view side by side — the code path has no tinted branch left; the constants are the default view's colours.
  - `[low]` `[reject]` changes outside the six items (`_Flag` ellipsis, epsilon 1e-3, epic context) — each traced: header room for the second id, path-metric rounding, required epic-context recompile.
  - Verification gap:
  - `[medium]` `[patch]` ranged span mapping unpinned — added a ranged-span window test (`all() & trunkk()`, offset 9 length 6 → `TextRange(8, 14)`).
  - `[low]` `[defer]` parent copy tested only for an in-layout parent — deferred #6.
  - `[low]` `[defer]` DS UI kit reads `MERGE_UP_SHIFT` from a stale bundle (NaN until republish) — deferred #5 (the republish regenerates the bundle).
  - `[low]` `[patch]` multi-line expression: pest's column is line-local — `render_message` now writes `at L:C` past line 1; unit test added.
  - Blind hunter:
  - `[low]` `[patch]` column wrong for multi-line (same as above, member) — `at L:C`; the composed-column half is false (intent example).
  - `[low]` `[reject]` fake/widget test model the error at another colon than real jj — catalogue fixture only; the real message is pinned in Rust.
  - `[low]` `[patch]` fieldSpan marks a bogus char when the span is outside the rule — fieldSpan null when the span does not touch the value or indexOf < 0.
  - `[false]` `[reject]` error mark stale while typing — a text change rebuilds with a new expression whose count is pending (error null → errorRange null) in the same frame.
  - `[low]` `[reject]` `_errorRange` written in build into a possibly shared controller — no caller shares a controller between fields; a refactor adds surface.
  - `[false]` `[reject]` always-on stretch Column breaks unbounded-width callers — the inner TextField already needs bounded width; the full app suite (1824) passes.
  - `[low]` `[defer]` alias / parameter-expansion messages lose the cause — deferred #3.
  - `[low]` `[reject]` without_span text surgery brittle — the format is produced two lines above in the same module and pinned by tests (incl. `L:C`).
  - `[medium]` `[defer]` ids copyable only with a pointer — deferred #4 (needs focus + activation in app and DS kit).
  - `[low]` `[reject]` header overflow at narrow inspector widths — the inspector has a fixed minimum width; the flags already ellipsize; two 8-char ids fit.
  - `[medium]` `[defer]` `_mergeUpShift` unapproved but documented as settled — same root cause as deferred #1.
  - `[false]` `[reject]` 199 → 0 overlaps not pinned — app `layout_invariants_test.dart` runs the 10k free collinear check and passes.
  - `[low]` `[reject]` shift can exceed `w/2 − 18` — at most `w/2 − 14`, still inside the card.
  - `[low]` `[defer]` `layout.js` counts edges, not slot owners; sign-0 approach — member of deferred #5.
  - `[false]` `[reject]` Marionette check not done — done (see Auto Run Result).
  - `[low]` `[reject]` graph_edges_test tolerance not explained — float32 path-metric rounding exposed by the new exit x's; 1e-3 px is far below a visible error.
  - Edge case hunter:
  - `[medium]` `[patch]` error mark only drawn with `withComposing` (focused) — marking no longer depends on it; unfocused test added.
  - `[false]` `[reject]` stale range after edit — see above.
  - `[low]` `[reject]` value text occurring earlier in its term (`(` in `((`) — needs a value that is itself a paren; jj would reject it anyway and the mark is cosmetic.
  - `[low]` `[patch]` indexOf −1 — member of the fieldSpan patch.
  - `[low]` `[patch]` multi-line column — member of the `at L:C` patch.
  - `[medium]` `[patch]` popover `autofocus` loses to an existing focus, Esc goes elsewhere — own FocusNode + `requestFocus()` after show; test gives another node focus first.
  - `[low]` `[reject]` header overflow — see above.
  - `[maybe-false]` `[reject]` stack/root commit id labelled `git` — the inspector opens on commits only (a stack card expands); the root's commit id is a real commit id. Would settle: an inspector on a stack key, which the view does not produce.
  - `[false]` `[reject]` `null-popover` identifier — every `_CopyId` call site passes an identifier.
  - `[false]` `[reject]` AC "field marks the span" unmet when unfocused — fixed by the withComposing patch (member).
  - `[false]` `[reject]` top/bottom parity with merge-up — the AC is about equal counts of ordinary lines; the merge-up exception is deferred #1.
  - `[maybe-false]` `[reject]` merge-up may coincide in dense fans — the 10k invariant check finds none; would settle: a hand-built dense fan case; if true only low.

### 2026-11-02 — Review pass (follow-up)
- verdicts: 27 findings — high 0, medium 4, low 14, false 6, maybe-false 3
- findings:
  - Intent auditor:
  - `[false]` `[reject]` message column counts in the composed revset, the field mark in the rule — carried: the intent's own example ("at 93") is the composed column.
  - `[low]` `[reject]` `at L:C` past line 1 is not in the contract's format — pest's column is line-local, so a bare column would be wrong there; the previous pass added it deliberately and pinned it.
  - `[low]` `[defer]` "straight" read as `kindStraight`, matrix row "straight not first parent" never occurs — carried, deferred #2.
  - `[medium]` `[defer]` merge-up exit exception breaks "one line → centre" / top-bottom parity — carried, deferred #1.
  - `[low]` `[defer]` DS `layout.js` counts entry edges, NaN until the bundle is regenerated — carried, deferred #5.
  - `[low]` `[reject]` DS copy variant lives in the UI kit, native `title` tooltip, commit prefix 0 — static design illustration; the app is the implementation the intent's details bind.
  - `[low]` `[reject]` no backend-to-UI test of the column, no rendered-port test — each half is pinned at its level (Rust strings, window via the fake, router geometry + 10k invariants); rendering draws the router's points.
  - Verification gap:
  - `[medium]` `[patch]` graph search footer and broken-variant menu rows still show `context` (pest's multi-line render) — `graph_search_field.dart` footer and the three `graphSearchBroken` sites now read `revsetError?.message ?? context ?? code`; the footer test now feeds a pest `context` plus a `message` and asserts the sentence shows and no `-->`.
  - `[low]` `[defer]` the fieldSpan guard for a wrapper span / missing value is untested — deferred #7 (cosmetic, one window test closes it).
  - `[false]` `[reject]` (other finding) the popover-focus test would fail against the old `autofocus` code — not a defect; it supports the existing test's validity.
  - Blind hunter:
  - `[medium]` `[patch]` search footer / menu rows still raw — member of the footer patch above.
  - `[false]` `[reject]` error mark is colour only (WCAG 1.4.1) — the field's message line (alert icon + sentence with the column) and red edge carry the error; the red span is the intent's specified extra mark.
  - `[false]` `[reject]` the column points into text the user never sees — carried (composed column, intent example).
  - `[low]` `[reject]` `parse_detail` fallback `e.kind().to_string()` lacks the prefix — pest renders always carry a `= ` line, so the fallback is not reached in practice; it still yields one line.
  - `[low]` `[defer]` copy feedback invisible to assistive tech — deferred #8.
  - `[false]` `[reject]` meta-line parent ids copy an id of unclear type — the copied id is the full form of the id shown on that line.
  - `[medium]` `[defer]` merge-up / straight decisions handed back to Ralph while docs present them as settled — carried, same root cause as deferred #1.
  - `[low]` `[defer]` `epic-10-context.md` stale (10.30 backlog; rule 51 vs 52) — deferred #9 (compiled planning cache, agent context).
  - `[false]` `[reject]` end-of-input mark can land on another rule — a rule is marked only when the position lies inside its term range (`start < r.end`); a position at the value's end inside the term is the term's own closing `)`, where the user's text is incomplete, so its last char is the right mark.
  - `[maybe-false]` `[reject]` the previous pass's open verifications (old-code popover test, unfocused mark in the window) — the window test pins `errorRange`, the field test pins the unfocused paint, the verification layer reasons the popover test fails on old code; if true only low.
  - `[low]` `[reject]` DS `ZKCopyId` gaps (setTimeout not cleared, prefix 2, `title` not mono) — static kit illustration, no user meets it.
  - Edge case hunter:
  - `[low]` `[reject]` focus not restored after the failure popover closes — reachable only after a clipboard failure (rare on macOS); the fix adds focus-restore state.
  - `[low]` `[patch]` a successful copy while the failure popover is open shows both — `_copy` success path now hides `_failed` first (mirrors the failure path hiding `_copied`).
  - `[low]` `[reject]` end-of-input mark splits a surrogate pair — needs a non-BMP last char in a revset value; cosmetic.
  - `[maybe-false]` `[reject]` overflowing merge-ups share the outermost slot + shift — carried (dense-fan row of the first pass); 10k invariants green.
  - `[maybe-false]` `[reject]` the prototype draws the same overflow — member of the row above.
  - `[low]` `[patch]` `search.css` header comment still lists the pill tint as an accent use — comment corrected.

## Design Notes

Item 4 is expected to resolve with item 5 (the id's commit-id tooltip goes); if the widget test shows the new copy tooltip also hangs, fix the cause in `ZsTooltip` (shared code) rather than locally. The "Copied" confirmation is a self-placed `ZsTooltipBubble` (RawTooltip dismisses on pointer down, so the tooltip itself cannot show it).

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib revset` and `cargo test -p zanshin-jj --test it revset_search::` -- pass
- `cargo test -p zanshin-ffi` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed
- `flutter test` / `dart analyze` / `dart format --set-exit-if-changed .` in `packages/zanshin_core`, `packages/zanshin_ui`, `app` -- pass

**Verification notes (run 2026-11-02; gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `cargo fmt --all --check` clean; `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` clean.
- `cargo test -p zanshin-jj --lib revset` 26 pass (after review patches); `cargo test -p zanshin-jj --test it revset_search::` 16 pass; `api_stability` pass (implementer); `cargo test -p zanshin-ffi` 239 + 405 pass.
- `cargo make codegen` regenerated `envelope_generated.rs` and `envelope_zanshin.ffi_generated.dart` (committed).
- `cargo make --allow-private test-core` (zanshin_core suite, incl. router tests and layout invariants) 1193 pass.
- `packages/zanshin_ui`: `flutter test` 443 pass; `dart analyze --fatal-infos` clean; `dart format --set-exit-if-changed` clean.
- `app`: `cargo make --allow-private test-flutter` 1824 pass after the review patches (incl. the 10k free-layout collinear check); `dart analyze --fatal-infos` clean; `dart format` clean.
- Parity oracle not run: no jj verb changed.
- Marionette (Widgetbook Configurations window, implementer): row and preview read "Syntax error at 6: expected <EOI>, …", red edge, no `-->`; focus kept while the error went away and came back; inspector showed the `jj` / `git` subscripts. A "before" repro was not recorded separately (the widget test pins the old failure: the `EditableTextState` identity across the toggle).

**Verification notes (follow-up review pass 2026-11-02; same gate rule):**
- `app`: `flutter test test/features/graph/graph_search_field_test.dart test/features/graph/graph_inspector_test.dart` pass; `cargo make --allow-private test-flutter` 1824 pass; `dart analyze --fatal-infos` clean; `dart format --set-exit-if-changed .` clean (after formatting `graph_search_field.dart`).
- No Rust, FFI or `packages/*` change in this pass: no cargo, codegen or parity run needed.

## Auto Run Result

Status: done

**Follow-up review pass (2026-11-02).** 27 findings. Patches: graph search footer and broken-variant menu rows show `revsetError.message` (medium; test extended), `_CopyId` success hides the failure popover (low), stale `search.css` comment (low). Deferred (mirrored in deferred-work.md): fieldSpan guard test, copy feedback for assistive tech, stale `epic-10-context.md`. Rejected rows carry their reasons in the triage log. Files: `app/lib/src/features/graph/{graph_search_field.dart,graph_inspector.dart}`, `app/test/features/graph/graph_search_field_test.dart`, `design_system/components/search/search.css`. Patched by verdict: medium 1, low 2, high 0 → follow-up review recommendation false (converged). Residual risks unchanged from the first pass (merge-up deviation awaits Ralph; DS bundle until republish).

**First pass:**

**Summary.** All six items of Story 10.30: (1) `RevsetErrorDetail.message` built in `zanshin-jj` (`Syntax error|Error at C|L:C: <jj's message>`, spanless without position, resolution = jj-lib's one-liner), appended to the FFI schema, shown at the raw rule and in the preview, the span marked in the field via `ZsTextField.errorRange` (also unfocused); (2) `ZsTextField` keeps one structure with and without a message; (3) the `$` pill has no tint (app + DS); (4) the hanging commit-id tooltip is gone with (5) the inspector's `_CopyId` (short change id ₍jj₎, short commit id ₍git₎, parents too; Click to copy / Copied / selectable popover on clipboard failure); (6) uniform ports in `router.dart`, `design/graph-layout.jsx`, DS `GraphPorts` / UI kit — except merge-up exits (never centre, +4 px) to keep the invariants green, pending Ralph's OK.

**Files.**
- `crates/zanshin-jj/src/revset.rs` — `message`, `render_message`, `without_span`; tests. `tests/it/api_stability.rs` — field.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/{envelope.rs,envelope_generated.rs,graph.rs,revset_search.rs}` — wire field.
- `packages/zanshin_core/lib/src/ffi/{revset_search.dart,envelope_zanshin.ffi_generated.dart}`, `worker/responses.dart` + tests — Dart field.
- `packages/zanshin_core/lib/src/graph_layout/router.dart` + `test/graph_layout/router_test.dart` — port rules, witnesses.
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart` + test — stable structure, `errorRange`.
- `app/lib/src/features/graph/{graph_inspector.dart,graph_search_field.dart,revset_configs/revset_configs_window.dart}`, `app/lib/l10n/*` + tests, `app/widgetbook/graph/fake_graph_search_source.dart`.
- `docs/graph-layout.md`; `_bmad-output/implementation-artifacts/design/{graph-layout.jsx,DESIGN-SYSTEM-SYNC.md (#16)}`; `design_system/` search, graph (GraphEdge, ChangeId, cards), UI kit, readme.

**Review.** 40 findings: 5 patch entries applied (withComposing-independent mark, `at L:C`, fieldSpan guard, ranged-span test, popover focus node), 6 deferred (merge-up exception for Ralph, geometric "straight" reading, alias-expansion cause, keyboard copy, DS kit bundle/owner count, parent-copy branches; mirrored in deferred-work.md), the rest rejected with reasons in the triage log.

**Follow-up review recommendation:** true — three medium patches (mark while unfocused, popover focus, ranged span); the popover-focus test was not shown to fail against the old `autofocus` code, and the unfocused mark is pinned only at `buildTextSpan` level, not in the Configurations window.

**Residual risks.** Merge-up exit deviation awaits Ralph; the DS UI kit computes NaN merge-up exits until the bundle is regenerated at the republish; no visual comparison against DS card renders; coverage ratchet not run (the loop's final gate runs it).

---
title: 'Story 10.32 — Word marks in the inspector diff: faint line, strong changed words'
type: 'feature'
created: '2026-11-12'
status: 'done'
baseline_revision: '921fbc905582314d1f0daaf5d05570a9014c6aff'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The word marks were not checked in the running catalogue or app against the DS Content card.
    evidence: |-
      Unattended run: no long-lived `flutter run` for Marionette, so only widget tests check the marks, and they record paint calls, not pixels (app/test/helpers/word_marks.dart). The catalogue's inspector demo (app/widgetbook/folders/graph.dart, _DemoDetails._diffOf) carries Ralph's three examples for the check. Review rows 26 and 29. Mirrored into deferred-work.md "Surfaced in Story 10.32".
    location: >-
      app/widgetbook/folders/graph.dart; _bmad-output/implementation-artifacts/design_system/components/content/content.card.html
    severity: low
  - summary: >-
      The DS word-mark parser and its hand-copied bundle blocks have no automated check.
    evidence: |-
      zsDiffLine / zsDiffText (design_system/components/content/DiffView.jsx) and their copies in _ds_bundle.js were checked with scratch node scripts only; the repo has no JavaScript test harness, and ds_parity_test / ds_manifest_parity_test cover tokens and component names only. Review row 24. Mirrored into deferred-work.md "Surfaced in Story 10.32".
    location: >-
      _bmad-output/implementation-artifacts/design_system/components/content/DiffView.jsx; _bmad-output/implementation-artifacts/design_system/_ds_bundle.js
    severity: low
---

<intent-contract>

## Intent

**Problem:** The inspector's diff (10.24) draws whole lines, so nobody sees which words of a changed line changed, although every `HunkLine` already carries jj-lib's word segments (5.2, what `jj diff --git` underlines). Deferred item I1 ("Word-level and syntax marks have no consumer story") names this story; syntax marks are deleted (Ralph, 2026-11-12).

**Approach:** Keep each removed/added line's faint fill and draw its `Removed`/`Added` segments on a strong fill of the same hue — two new DS tokens `--add-word-bg` / `--rem-word-bg` (night + paper) in DS `tokens/colors.css` and `ZsColors` — in Unified and Side by side alike, painted under the paragraph so a selection's highlight stays on top. The DS gets the tokens, the marks in `DiffView`/`DiffHunk` (and the Content card), the docs, and a republish.

## Boundaries & Constraints

**Always:**
- Marks come only from `HunkLine.segments`; Dart only maps them onto the shown text (the line text without its trailing `\n` and `\r`): a mark = a `Removed`/`Added` segment cut at the shown text's end (a run that is only a line break has nothing to fill). Changed runs of spaces/indentation are filled like any run.
- No marks at all on a line whose `Equal` segments hold no visible (non-whitespace) character — an inserted line, a wholly new or deleted file: the faint fill alone. Context lines, `Equal` runs and lines without segments look exactly as in 10.24.
- A mark = a block the line's full height under the marked characters (the paragraph's own `getBoxesForSelection` x-extents), in `addWordBg`/`remWordBg` over the line's `addBg`/`remBg`; its glyphs turn `colors.text` (DS rule for coloured text on a stronger tint, states.css:43-44 / readme:142: red or green text cannot keep 4.5:1 there, paper not even on the faint fill). Painted before the paragraph, so `SelectionArea`'s highlight paints over the mark and every glyph keeps its colour (decision 16.10). Side-by-side cells clip their marks to the cell.
- Tokens (Claude's default, NEEDS DESIGN): night `--add-word-bg: rgba(74,222,128,.30)`, `--rem-word-bg: rgba(248,113,113,.30)`; paper `rgba(26,127,69,.22)`, `rgba(194,58,58,.20)`. Data colours: no accent family, contrast, transparency or inactive delta touches them. `--text` keeps ≥ 4.5:1 on `--code-bg` + line fill + word fill over `--fl-bg-solid` in every appearance.
- DS edited in place: `tokens/colors.css` (+ `_ds_manifest.json` token entries), `components/content/{content.css, DiffView.jsx/.d.ts/.prompt.md, DiffHunk.jsx/.d.ts/.prompt.md, content.card.html}`, the hand-compiled `_ds_bundle.js` blocks + their `sourceHashes` (sha256, 12 hex), `readme.md` (colour line + a dated Sync line "from the app, Story 10.32"). DS line strings mark words as git's `--word-diff=plain` prints them: `[-old-]`, `{+new+}`.
- The stale `HunkLine.segments` dartdoc (still describes 5.2's imara-diff pairing and cap) is corrected to jj-lib's words.

**Never:** syntax colours; a structural diff (5.9); computing or changing segments in Dart; a backend/FFI/schema change; golden tests; changing the prototype under `design/`.

## I/O & Edge-Case Matrix

Notation as `crates/zanshin-jj/src/hunks.rs` tests: `[-…-]` Removed, `{+…+}` Added segment.

| Scenario | Lines (segments) | Expected marks | Notes |
|----------|------------------|----------------|-------|
| Rewritten expression | `-    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),\n` / `+… ? {+saveLabel+} : …` | exactly `s.functionWizard_save` / `saveLabel`, glyphs `--text` | — |
| Call split over three lines | `-    Expanded(child: _Line(…)),\n` (all equal); `+    Expanded({+\n+}`; `+{+      +}child: _Line(color: isFirst ? null : lineColor){+,\n+}`; `+{+    +}),\n` | removed line none; line 1 none; line 2 the 6 spaces + `,`; line 3 the 4 spaces | — |
| Inserted comment line | `+  {+// Small side padding.\n+}` | none | changed runs cover the visible text |
| Context line / no segments | ` x\n` one equal; `segments: []` | none | 10.24 look |
| CRLF | `+a{+b\r\n+}` | `b` only | `\r` and `\n` never filled |
| Side by side | the same lines | the same runs per cell, clipped to the cell | — |
| Selection | drag across a marked line | highlight above the mark, glyph colours kept | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/inspector_diff.dart` -- `_text` :50 (shown text), `InspectorDiffHunk._look` :518 (faint fill, ink), unified line `Text` :563, side-by-side `cell` `Text` :602 (maxLines 1, clip); `SelectionArea` :183. Imports `package:flutter/rendering.dart show SemanticsProperties` (extend for `RenderProxyBox`, `RenderParagraph`, `TextSelection`).
- `packages/zanshin_ui/lib/src/design/zs_colors.dart` -- one token = ctor param (~:122), night value (~:420), paper value (~:604), documented field (~:992), `copyWith` param + assignment (~:1355, :1510), `lerp` (~:1673), `toCss` (~:1832), `==` (~:2015), `hashCode` (~:2172); add `addWordBg`/`remWordBg` after `addRing` in each.
- `packages/zanshin_ui/test/design/ds_parity_test.dart` -- resolves 1728 appearances against the DS CSS; red until DS and `ZsColors` agree (no edit).
- `packages/zanshin_ui/test/design/zs_tokens_test.dart` -- place for the word-fill token test (accent independence, 4.5:1).
- `packages/zanshin_core/lib/src/ffi/diff.dart:94-102` -- stale `HunkLine.segments` doc; truth: `schemas/envelope.fbs` `HunkLine` comment / `crates/zanshin-jj/src/hunks.rs:242-246`.
- `crates/zanshin-jj/src/hunks.rs:968-1040` -- read-only: the backend's own witnesses of the three examples (exact segments).
- `app/test/features/graph/inspector_diff_test.dart` -- widget tests (`shellHost`, `_hunk`, `_file`, `view`); `find.text` matches `Text.rich` by plain text.
- `app/test/features/graph/graph_real_repo_test.dart` -- real-cdylib widget-test pattern (worker + temp repo inside `tester.runAsync`, `shellHost`, `setUpIconRegistry`); `graph_ports_test.dart:157` -- how `RepoGraphDetails.diff` is read (`status()` snapshots, `newChange`, `details.show('@')` for the commit id).
- `app/widgetbook/folders/graph.dart:1031-1100` -- `_DemoDetails._diffOf`/`_line`: the catalogue's demo hunks.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- reuses `InspectorDiffView` (gets the marks for free; no edit).
- DS: `_bmad-output/implementation-artifacts/design_system/{tokens/colors.css:71-72,107-108, components/content/*, _ds_bundle.js:1331-1505 (+ header sourceHashes), _ds_manifest.json (token list), readme.md:93,18-45}`; publish per `.claude/skills/design-artifacts/SKILL.md` A (+B).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/design/zs_colors.dart` + DS `tokens/colors.css` + `_ds_manifest.json` -- add `--add-word-bg`/`--rem-word-bg` (`addWordBg`/`remWordBg`) with a contrast comment -- the tokens, kept in parity.
- `packages/zanshin_ui/test/design/zs_tokens_test.dart` -- for every theme × family × contrast × transparency × inactive: the word fills equal the theme's constants and `--text` on them (stacked as above) is ≥ 4.5:1 -- the token witness.
- `app/lib/src/features/graph/inspector_diff.dart` -- `diffWordMarks(HunkLine) -> List<TextRange>` (pure, public for tests), `DiffWordMarks` (a `SingleChildRenderObjectWidget`: paints the marks' boxes the line's height, clipped to itself, then its child), the line text as `Text.rich` with marked runs in `colors.text`; both layouts share one line-text builder -- the marks.
- `app/test/features/graph/inspector_diff_test.dart` -- every matrix row: exact ranges from `diffWordMarks`; per layout the painted rects equal the paragraph's boxes for those ranges in the word colour, glyph colours, no `DiffWordMarks` on unmarked lines; paper too; the selection witness (`paints..rect(word)..rect(selection)..paragraph()`) -- view witnesses.
- `app/test/features/graph/graph_real_repo_test.dart` -- real cdylib: a change rewriting three files with Ralph's examples plus a new file, read through `RepoGraphDetails.diff` and pumped into `InspectorDiffView`; the painted marks and glyph colours are the matrix's (the comment line and the new file none) -- the real-data witness at the paint surface.
- `app/widgetbook/folders/graph.dart` -- the demo diff gets segmented lines (the three examples) so the catalogue shows marks.
- `packages/zanshin_core/lib/src/ffi/diff.dart` -- correct the `segments` dartdoc.
- DS `components/content/{content.css, DiffView.jsx, DiffView.d.ts, DiffView.prompt.md, DiffHunk.jsx, DiffHunk.d.ts, DiffHunk.prompt.md, content.card.html}`, `_ds_bundle.js`, `readme.md` -- `zsDiffLine` parses `[-…-]`/`{+…+}` into runs, both components draw marks with the same rule (`.w`, inline-block so it fills the line), the card shows them, docs + Sync line; then republish (skill A, B) or record that it is left -- the DS leads.
- Ledgers at finalize: `deferred-work.md` (only new deferrals, section "Surfaced in Story 10.32 (bmad-build-auto, 2026-11-12)"), `sprint-status.yaml` (10-32 done, `last_updated`), `epics.md` Story 10.32 a dated note with the defaults chosen.

**Acceptance Criteria:**
- Given the inspector showing a diff read through the real cdylib, when a line holds jj-lib's changed runs and visible unchanged text, then exactly those runs (cut at the line break) are drawn on the strong fill with `--text` glyphs, and nothing else changes from 10.24.
- Given the DS token files and `ZsColors`, when the parity test runs, then the two new tokens match in all 1728 appearances.
- Given a text selection across a marked line, when it paints, then the highlight lies over the word fill and the glyphs keep their colours.

## Spec Change Log

## Review Triage Log

### 2026-11-12 — Review pass
- verdicts: 35 findings — high 0, medium 1, low 28, false 6, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) A mark spans its paragraph's full height, so a line with a hard break (VT, FF, U+2028/2029, a CR inside the line) fills the same x-range on its other visual line. — Real (such a line already lays out on two visual lines in 10.24), but rare in everyday diffs: a form-feed line is only blanks, so it gets no marks at all. Per-line extents need box heights matched to each line box (another `BoxHeightStyle` and its own checks) — more than a direct correction.
  - `[low]` `[patch]` (blind) The test helper derives its expected blocks the way `paint` does and forces its own paint, so a shared error or a setter without `markNeedsPaint` passes. — Grouped with the offset row below: the helper paints at `Offset(31, 7)`; a new test pins that a new fill or new marks set `debugNeedsPaint` and equal ones do not. The marked ranges are compared with literal strings.
  - `[low]` `[patch]` (blind) The helper's result map loses a second line with the same text. — The helper now fails on a repeated line text before storing it.
  - `[low]` `[reject]` (blind) Colour is the only cue for a changed word (mark vs line fill 1.3–2.0:1, glyphs 1.4–3.0:1); jj underlines, and the DS adds edges under Increase contrast. — The marks add detail on top of what each line already says by its sigil, fill and colour, so a reader who cannot tell the fills apart loses nothing 10.24 showed. The DS's increased-contrast edges cover control states; diff line fills get none either. The intent fixes the cue as a fill (Ralph's target look), and a second cue (an underline, at least under Increase contrast) is a new design rule for Ralph — more than a direct correction. Named under residual risks.
  - `[low]` `[patch]` (blind) The DS accessibility lines do not say what VoiceOver does with changed words. — Both prompts' Keyboard · VoiceOver lines and the readme's Sync line now say the marks are visual only and VoiceOver reads the line's text as before.
  - `[low]` `[patch]` (blind) Untested cases: a wholly removed line, a trailing-whitespace run, a side-by-side selection, an appearance change on a mounted tree, real data beyond Unified on night. — Added `-[-fn main() {\n-]` (no marks) and `+x{+  +}\n` (unit and matrix; the mark lies inside its paragraph in both layouts); the repaint test covers a new fill. Not added: a side-by-side selection (the same widget and paint path as the unified selection test; the cell adds only the clip, which the clip test covers) and more real-data layouts (row 28).
  - `[low]` `[patch]` (blind) The DS UI kit's inspector shows the card's hunks without word markup, so the kit shows no marks. — `ui_kits/desktop/data.js` marks `onEnd({+DragEndDetails d+})` and `[-220-]` / `{+260+}`; the kit's revert (`zkInvLines`, `app.jsx`) now swaps the delimiters with the sides; their bundle blocks and source hashes are updated; the readme's Sync line says so.
  - `[low]` `[patch]` (blind) The DS line format has no escape: code holding `[-`, `-]`, `{+` or `+}` loses characters. — The jsx comment, `.d.ts`, both prompts and the Sync line say such code goes in the object form `{ t, s, runs }`; no current DS line holds those pairs.
  - `[low]` `[patch]` (blind) The corrected `HunkLine.segments` dartdoc leaves out a changed line with no changed run and a run that is only a line break. — Added that sentence (`packages/zanshin_core/lib/src/ffi/diff.dart`).
  - `[low]` `[reject]` (blind) Other catalogue diffs (`_HunkSelection`, the undo timeline demo) carry no segments. — The floating-shell inspector demo shows every mark case; the hunk-selection and operation views reuse the same widget, and a picked hunk changes only its header and left edge — more catalogue data than a direct correction, for no new look.
  - `[false]` `[reject]` (blind) The token values are not marked as provisional. — The story adopts Claude's defaults (epics.md 10.32: "Design status … Claude's defaults adopted"), so the DS records them as its values; the epics.md build note names them as open to Ralph's change.
  - `[false]` `[reject]` (blind) The marks would vanish silently if the child were not a paragraph. — `paintedWordMarks` compares the painted fills with blocks computed from the line's own `RichText`; a paint that found no paragraph draws no fill and fails that comparison in every word-mark test.
  - `[low]` `[reject]` (blind) Every paint asks the paragraph for every mark's boxes. — `getBoxesForSelection` queries the laid-out paragraph without a layout; a line's few marks cost far less than painting the line itself, which 10.24's deferred "eager layout of large files" item covers. Caching would need invalidation on every child relayout.
  - `[low]` `[reject]` (blind) The word-fill token test sits in the accent-families group and re-types the appearance loops. — Cosmetic: its subject includes the families (the fills must not follow them), and its loops cover every colour-affecting axis; sharing the parity test's private list couples two files for no named harm.
  - `[low]` `[patch]` (blind) The `.d.ts` types allow `runs` on context and hunk lines, where `.w` gets no fill. — `DiffView.d.ts` and `DiffHunk.d.ts` allow `runs` on `add` / `rem` lines only.
  - `[low]` `[reject]` (edge) A hard break in a unified line makes each mark a full-paragraph column. — Same as the first row.
  - `[low]` `[patch]` (edge) Code holding `[-`, `-]`, `{+` or `+}` loses its delimiters. — Same root cause as the escape row above: documented, object form named.
  - `[low]` `[patch]` (edge) A line copied from git's own `--word-diff=plain` output (no sigil, both kinds) parses as a context line. — The docs no longer say "as git prints them": one line per side with its sigil, `[-…-]` only on a removed line, `{+…+}` only on an added one.
  - `[low]` `[patch]` (edge) An object line with `runs: []` renders blank. — `zsDiffText` falls back to `l.s` when `runs` is empty (jsx, bundle block, source hash).
  - `[low]` `[patch]` (edge) The helper lets a later identical line overwrite an earlier one. — Same as the duplicate-line row above.
  - `[low]` `[reject]` (edge) The real-repo test's cleanup does not run when an expect fails. — Only a failing run leaks, and its worker and repository end with the test process; the file's existing real-repo test (Story 10.12) has the same shape.
  - `[low]` `[reject]` (edge, claim) "Exactly the changed runs are drawn … the line's height" fails for a line with a hard break. — Same as the first row.
  - `[medium]` `[patch]` (verification) `RenderDiffWordMarks.paint`'s offset math is only tested at `Offset.zero`; dropping `offset.dx +` keeps every test green. — The helper paints at `Offset(31, 7)` and builds `bounds` and its expected blocks from that origin, so every caller (the matrix in both layouts and themes, the selection, panel and real-repo tests) now checks the offset.
  - `[low]` `[defer]` (verification) The DS word-mark parser and its hand-copied bundle blocks have no automated check. — The repo has no JavaScript test harness; the scratch node checks passed but are not committed. Added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[patch]` (verification) The comment line's `find.text` check would pass for a marked line too. — The matrix test asserts the comment line has no `DiffWordMarks` ancestor.
  - `[low]` `[defer]` (intent) The Marionette screenshots against the DS card were not taken. — Unattended run: no long-lived `flutter run`; the catalogue demo carries the three examples. Added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[patch]` (intent) "A fake diff port, then the real cdylib": the mark tests pumped `InspectorDiffView` directly, so the panel's port path had no mark witness. — New `graph_inspector_test.dart` test: the fake `GraphDetails.diff` port's segmented lines paint their marks in the inspector panel; the inserted line stays unmarked.
  - `[low]` `[reject]` (intent) The real-data test runs Unified on night only. — It witnesses the data path (jj-lib's segments through the worker to the paint); Side by side and paper differ only in presentation code, which the matrix tests cover with the same segment shapes.
  - `[low]` `[defer]` (intent) The tests record paint calls, not pixels; ancestors (the scroll view, the hunk edge, an opacity) go unchecked. — The offset part is the patched offset row; a pixel-level look is the Marionette pass (same entry as the Marionette row).
  - `[false]` `[reject]` (intent) The 4.5:1 is measured on a modelled stack over `--fl-bg-solid`, not on the inspector's glass. — On the real glass (`--fl-bg-strong` .86 over the canvas) the ground differs from `--fl-bg-solid` by a few RGB units in both themes, and the lowest measured ratio is 5.73:1; red or green text is never drawn on a mark.
  - `[false]` `[reject]` (intent) `--text` glyphs on a mark were not among the adopted defaults. — Item 3 asks that text on the strong fill keeps 4.5:1. With red or green glyphs no visibly stronger fill can (paper `--rem` is near 4.5:1 on the faint fill alone), so `--text` glyphs are the only reading that meets both "strong fill" and "4.5:1"; the DS's rule 6 does the same for tinted states. The epics.md build note records it for Ralph.
  - `[low]` `[patch]` (intent) The DS was not republished, and the DS UI kit's inspector shows no marks. — The kit part is the kit row's patch; the republish follows at finalize (design-artifacts skill A, then B).
  - `[low]` `[reject]` (intent) The Undo Timeline's operation view now draws marks too, untested there. — It reuses `InspectorDiffView` by design (Story 10.29), and its reads carry the same segments; the view's own tests cover the marks.
  - `[false]` `[reject]` (intent) Two extras: the zanshin_core dartdoc rewrite and the replaced catalogue demo hunks. — Both are spec tasks; the dartdoc described a pairing the backend no longer does, and no test depends on the old demo hunk (the catalogue smoke tests pass).
  - `[false]` `[reject]` (intent) I1's outcome and the not-done items are not recorded. — The Auto Run Result and the ledgers are written at finalize; the Marionette check is deferred through the Marionette row.

## Design Notes

- **Why `--text` on the mark:** night `--rem` on a .30 tint falls to ≈3.3:1 and paper `--rem` is ≈4.5:1 on the faint fill alone, so "text keeps 4.5:1" leaves either a barely stronger fill or brighter glyphs; the DS already chose brighter glyphs for tinted states. GitHub's dark diff reads the same way.
- **Why paint under the paragraph:** a `TextSpan.backgroundColor` is drawn by the paragraph after its selection highlight, so a mark would cover the highlight. `DiffWordMarks` asks its child's `RenderParagraph` (found through the `MouseRegion` proxy a `SelectionArea` adds) for the boxes — one layout, exact glyph extents, CJK and emoji included.
- DS markup example: `"-  static const _kSettle = [-220-];"`, `"+  static const _kSettle = {+260+};"`.

## Verification

**Commands (gate rule: no `cargo make test` / `test-full` / `coverage`; no Rust/FFI/schema change, so no cargo checks, codegen or oracle):**
- in `packages/zanshin_ui`: `flutter test test/design`, `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` -- expected: pass / clean.
- in `app`: `cargo make test-app test/features/graph test/features/undo_timeline test/widgetbook` (pinned env for the real-cdylib test), `dart analyze --fatal-infos lib test widgetbook`, `dart format --set-exit-if-changed lib test widgetbook` -- expected: pass / clean.
- in `packages/zanshin_core`: `dart analyze --fatal-infos`, `dart format --set-exit-if-changed lib` -- expected: clean.
- DS bundle: every changed block's `sourceHashes` equals `shasum -a 256 | cut -c1-12` of its `.jsx`.

**Manual checks:**
- Marionette: the catalogue's inspector diff (and the app on a temp repo) against the DS Content card in night and paper; if the app cannot be started unattended, record it as not done.

### Verification notes (2026-11-12, story run)

Toolchain from `~/development/sdks`; every command run from the repo root with absolute paths (the `packages/zanshin_ui` steps through `cargo make --allow-private test-ui*`, whose `cwd` is that package).

| Check | Outcome |
|---|---|
| Probe: the stock `jj` 0.47.0 (`target/llvm-cov-target/debug/jj`, pinned empty config, temp repo in the scratchpad) `jj diff --git --color=debug` on the three examples + a new file | underlines exactly the matrix's runs; the comment's next line is `+{+  +}padding: Spacing.{+spacing2+},` (its indentation is a changed run), the new file's lines are wholly changed |
| `cargo make --allow-private test-ui` (all of `packages/zanshin_ui`, a superset of `flutter test test/design`) | pass, 460 tests; `ds_parity_test` (1728 appearances, the two new tokens included) and the new word-fill test in `zs_tokens_test` ran |
| `cargo make --allow-private test-ui-analyze` (`dart analyze --fatal-infos --fatal-warnings`) | No issues found |
| `cargo make --allow-private test-ui-format` (`dart format --output=none --set-exit-if-changed .`) | 112 files, 0 changed |
| `cargo make test-app test/features/graph test/features/undo_timeline test/widgetbook` (pinned env, real cdylib) | pass, 1374 tests (final state); the real-repo word-mark test, the 5 `diffWordMarks` unit tests, the 6 matrix (2 layouts × night/paper) / clip / selection widget tests and `ds_manifest_parity_test` (parses the edited manifest) included |
| `cargo make test-app test/l10n test/architecture` (extra: the hard-coded-string and layer guards over `app/lib`) | pass, 9 tests |
| `dart analyze --fatal-infos` on `app/lib`, `app/test`, `app/widgetbook` | No issues found |
| `dart format --output=none --set-exit-if-changed` on `app/lib`, `app/test`, `app/widgetbook` | 288 files, 0 changed |
| `dart analyze --fatal-infos` on `packages/zanshin_core`; `dart format --output=none --set-exit-if-changed packages/zanshin_core/lib` | No issues found; 62 files, 0 changed |
| DS bundle: `shasum -a 256` of `DiffView.jsx` / `DiffHunk.jsx`, first 12 hex, against the header's `sourceHashes` | `5869a3e9aecf` / `282be7e95fbe`, equal; `node --check _ds_bundle.js` passes |
| DS bundle behaviour: a scratch node script loads `_ds_bundle.js` with a stub `React.createElement` and renders `DiffView` and `DiffHunk` (unified and split) | no block errors at load; `[-220-]` / `{+260+}` / `{+  +}…{+spacing2+}` become `.w` runs, a `{+// …+}` line after blanks keeps none, the split cells carry the same runs |
| Contrast of `--text` on `--code-bg` + line fill + word fill over `--fl-bg-solid` (scratch script, WCAG 2) | night 5.73 (add) / 7.46 (rem), paper 10.06 / 10.09 — the numbers in `tokens/colors.css` and `readme.md` |

Not done in this run:
- Marionette: not done — the run may not start the catalogue or the app (unattended, no long-running process). The catalogue's demo diff (`_DemoDetails` in `app/widgetbook/folders/graph.dart`: any modified file in the floating shell's inspector) now carries the three examples for that check, and the DS Content card shows marks in both hunks.
- DS republish (`design-artifacts` skill A, then B for the canvas): left to the parent run, as instructed; the DS sources, `_ds_bundle.js` and `_ds_manifest.json` are edited in place.
- No `cargo make test` / `test-full` / `coverage` (gate rule); no Rust, FFI or schema file changed.

### Verification notes (review patches)

- `dart format` + `dart analyze --fatal-infos` on `app/test/helpers/word_marks.dart`, `inspector_diff_test.dart`, `graph_inspector_test.dart`, `graph_real_repo_test.dart` and `packages/zanshin_core/lib/src/ffi/diff.dart`: No issues found; the format check 0 changed.
- `cargo make test-app test/features/graph/inspector_diff_test.dart test/features/graph/graph_inspector_test.dart test/features/graph/graph_real_repo_test.dart`: pass, 117 tests. They now cover: the helper painting at `Offset(31, 7)` and failing on a repeated line text; the setter repaint test; `-[-fn main() {\n-]` and the trailing-blank run `+x{+  +}\n` (unit and matrix; its mark lies inside its paragraph in both layouts); the comment line has no `DiffWordMarks` ancestor; the inspector panel paints the fake diff port's segments.
- DS: `node --check _ds_bundle.js` passes. `shasum -a 256 | cut -c1-12` equals the header's `sourceHashes`: `DiffView.jsx` `4f07a80311ea`, `DiffHunk.jsx` `282be7e95fbe` (unchanged), `ui_kits/desktop/data.js` `21bad2528886`, `ui_kits/desktop/app.jsx` `f69878a91866`. The scratch node check (stub `React`) also passes: `runs: []` renders the plain text, and the object form keeps `s[-3:]` / `i++}` as text.
- Not run (as asked): the wider app folders, `packages/zanshin_ui`, Marionette, the DS republish.

### Verification notes (parent run, after the review patches)

- `cargo make test-app test/features/graph test/features/undo_timeline test/widgetbook`: pass, 1377 tests.
- `cargo make --allow-private test-dart-analyze` (the whole app: lib, test, widgetbook): No issues found; `test-dart-format`: 290 files, 0 changed.
- `cargo make --allow-private test-ui`: pass, 460 tests (`ds_parity_test` over 1728 appearances and the word-fill token test among them); `test-ui-analyze`: No issues found; `test-ui-format`: 112 files, 0 changed.
- `cargo make --allow-private test-core-analyze` / `test-core-format` (`packages/zanshin_core`): No issues found; 165 files, 0 changed.
- DS: `node --check _ds_bundle.js` passes; the four changed sources' `shasum -a 256 | cut -c1-12` equal the bundle header's `sourceHashes`.
- A probe (a scratch test, deleted after the run): a `softWrap: false` paragraph's width includes its trailing spaces, so a trailing-space mark is not clipped.
- DS republished with the design-artifacts skill: the Design System artifact is at version 27 (`1794449669-c70c`; the ten changed files and the index), and the canvas `6sAzL5mDcVpWXevbTcempu` took the new tokens, bundle and fonts (version 41, `1794449713-919d`; its `designSystems` record updated).
- Not run (gate rule): `cargo make test` / `test-full` / `coverage`. No Rust, FFI, schema or jj verb changed, so no cargo checks, codegen or parity oracle. Marionette: not done (deferred).

## Auto Run Result

Status: done. Code commit `cf6cb003e9754b179883ef30e38931405e5aaaf7`; this spec, the ledgers and the epic context follow in the next commit.

**Summary.** The inspector's diff draws jj's changed words.
- Each removed or added line keeps its faint fill (`--rem-bg` / `--add-bg`). Its `Removed` / `Added` segments — jj-lib's own, what `jj diff --git` underlines — lie on a stronger fill of the same hue, the line's full height, with `--text` glyphs, in Unified and Side by side.
- A changed run of spaces is filled; a run that is only a line break has nothing to fill; a line whose unchanged text is only blanks (an inserted line, a new or deleted file) keeps the faint fill alone.
- `DiffWordMarks` paints the fills under the paragraph, so a selection's highlight lies over a mark. The Undo Timeline's operation view reuses the same view and shows the marks too.
- New design-system tokens `--add-word-bg` / `--rem-word-bg` (night `rgba(74,222,128,.30)` / `rgba(248,113,113,.30)`, paper `rgba(26,127,69,.22)` / `rgba(194,58,58,.20)`) in DS `tokens/colors.css` and `ZsColors`; `--text` on them measures 5.7–10.1:1 in every appearance.
- The DS's `DiffView` / `DiffHunk` mark `[-old-]` / `{+new+}` runs (Content card, UI kit); the DS and its canvas are republished.

Claude's defaults for the NEEDS DESIGN items, open to Ralph's change and recorded in epics.md Story 10.32: the token values; the glyphs on a mark turn `--text` (red or green text cannot keep 4.5:1 on a stronger tint — DS readme › Control states, rule 6); a mark fills the line's full height.

**Files.**
- `app/lib/src/features/graph/inspector_diff.dart` — `diffWordMarks`, `DiffWordMarks` / `RenderDiffWordMarks`, one line-text builder for both layouts.
- `packages/zanshin_ui/lib/src/design/zs_colors.dart` — `addWordBg`, `remWordBg`.
- `packages/zanshin_core/lib/src/ffi/diff.dart` — the `HunkLine.segments` dartdoc describes jj-lib's word diff.
- `app/widgetbook/folders/graph.dart` — the catalogue's demo diff carries Ralph's three examples with segments.
- Tests: `app/test/features/graph/inspector_diff_test.dart` (the matrix in both layouts and themes, the clip, the selection, the repaint), `graph_inspector_test.dart` (marks through the panel's fake diff port), `graph_real_repo_test.dart` (the real cdylib), `app/test/helpers/word_marks.dart` (the paint-surface helper), `packages/zanshin_ui/test/design/zs_tokens_test.dart` (the fills fixed per theme, 4.5:1).
- DS (`_bmad-output/implementation-artifacts/design_system/`): `tokens/colors.css`, `_ds_manifest.json`, `components/content/{content.css, DiffView.jsx/.d.ts/.prompt.md, DiffHunk.jsx/.d.ts/.prompt.md, content.card.html}`, `ui_kits/desktop/{data.js, app.jsx}`, `_ds_bundle.js` (blocks and source hashes), `readme.md` (the colour line, the Sync line).
- Ledgers: `epics.md` (Story 10.32 build note), `sprint-status.yaml` (10-32 done), `deferred-work.md` ("Surfaced in Story 10.32"), `epic-10-context.md` (recompiled).

**Review.** 35 findings: high 0, medium 1, low 28, false 6.
- Patched, 12 entries. One medium: the paint helper now paints away from the origin, so the offset math is checked. Eleven low: a duplicate-line guard, a repaint test, a removed-line and a trailing-space case, a precise check of the unmarked comment line, a witness through the panel's fake diff port, the dartdoc's two edge cases, empty `runs` in the DS, the `.d.ts` types, the DS line-format wording and its missing escape, the VoiceOver lines, and the UI kit's marks (its revert now swaps the delimiters too).
- Deferred, 2 (low, mirrored into deferred-work.md): the Marionette check against the DS card; no automated check of the DS parser.
- Rejected, with reasons in the triage log: a hard line break inside a line (rare; per-line extents are more than a correction), colour as the only cue (the intent's fill look; a second cue is Ralph's design call, see residual risks), other catalogue diffs without segments, per-paint box queries, the token test's placement, the real-repo test's cleanup, more real-data layouts, the operation view's reuse; and as false: provisional tokens, a silent missing paragraph, the glass ground, the `--text` glyphs, the spec's extras, the records.

**Follow-up review recommended: false.** This first pass patched no high entry and one medium entry, a test-only change, so no risk is left unverified.

**Verification.** See the verification notes above: every targeted check passed (app 1377 tests, zanshin_ui 460; analyze and format clean in app, zanshin_ui and zanshin_core; the DS bundle parses and its hashes match).

**Items.**
- **I1** — fixed (`cf6cb003e9754b179883ef30e38931405e5aaaf7`): a UI story now renders the segments. The inspector diff (and the operation view) draws the word marks in Ralph's target look; the syntax-mark half is moot (Stories 5.3 and 5.4 were deleted on 2026-11-12, no syntax colours).

**Residual risks.**
- Not seen in the running app or catalogue (Marionette deferred); the widget tests check paint calls, not pixels.
- Colour is the only cue for a changed word (mark vs line fill about 1.3–2.0:1). jj itself underlines changed words; an underline, at least under Increase contrast, would be a design call for Ralph.
- A line holding a hard line break (VT, FF, U+2028/2029, a CR inside the line) lays out on two visual lines, and a mark fills both at its x-range.
- The token values and the `--text` glyphs are Claude's defaults (NEEDS DESIGN).

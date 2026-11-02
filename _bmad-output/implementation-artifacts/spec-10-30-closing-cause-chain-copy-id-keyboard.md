---
title: 'Story 10.30 closing run — revset cause chain, keyboard/AT copy ids, kit entry slots, guard tests'
type: 'bugfix'
created: '2026-11-02'
status: 'done'
baseline_revision: '130aaaacea42abff7b4a67168ac8e36448a1c6a1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['multiple-goals']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 10.30 left six items: (1) an alias / parameter-expansion revset error's one-line `message` names only the expansion ("Error at 1: In alias `x`"), where the CLI prints the cause chain ("Caused by:"); (2) the inspector's copyable ids (`_CopyId`, DS `ZKCopyId`) work only with a pointer; (3) they tell assistive tech nothing about copying; (4) the DS kit's `layout.js` counts entry lines by edges, not router.dart's slot owners, and drops sign-0 approaches to the centre; (5) copying a parent id is untested outside the layout and while stale; (6) the raw rule's field-mark guard is untested.

**Approach:** (1) `parse_detail` appends `: <cause>` per level of `origin()` (the cause's pest message line, `Syntax error: ` for a syntax cause, no column); (2+3) `_CopyId` runs on the house `ZsControlCore` (Tab stop, ↩ / Space, focus ring, one button node) with a hint "Copies the full id", and announces "Copied" / the failure via `SemanticsService.sendAnnouncement`; `ZKCopyId` gets an Enter/Space `onKeyDown`; (4) `layout.js` mirrors router.dart `_entries`: ≥ 2 dashed lines into a single-parent change (not a stack) share the first one's slot, the centre goes to the only owner else the straight one, an approach at the centre counts as the right side; (5+6) widget tests.

## Boundaries & Constraints

**Always:** CLI parity for (1): the CLI's "Caused by:" levels are exactly `origin()`'s chain; the top level keeps its column; `without_span` keeps working (it splits at the first `: `). The wire field's doc (`schemas/envelope.fbs` RevsetErrorDetail.message) follows; `cargo make codegen` output committed. Real parent count for the kit comes from the change (`realParents` set in `app.jsx`'s revset filter; unfiltered nodes count `parents + gapParents`).

**Never:** republishing the DS or regenerating `_ds_bundle.js` (orchestrator's job); changing router.dart; a new FFI field.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Nested alias | `x` → `y` → `a ::: b` | "Error at 1: In alias `x`: In alias `y`: Syntax error: expected <EOI>, `\|`, `&`, or `~`" | — |
| Parameter | `f(p)='p'`, `f(fooo())` | "… In alias `f(p)`: In function parameter `p`: Function `fooo` doesn't exist" | — |
| Keyboard copy | id focused, ↩ or Space | full id on the clipboard, "Copied" announced | write fails → popover + "Couldn't copy. Select the id to copy it." announced |
| Span on `(` | raw rule `a ::: b`, span 0..1 | field `errorRange` null, row shows the message | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/revset.rs` `parse_detail` (~:670), `render_message` / new `message_line`, `RevsetErrorDetail.message` doc (:206); unit tests `parse_errors_carry_a_one_line_message`, new `an_expansion_error_message_names_its_cause`.
- `schemas/envelope.fbs:106` RevsetErrorDetail doc → generated `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`.
- `app/lib/src/features/graph/graph_inspector.dart` `_CopyId` (:949-1150) — reuse `ZsControlCore` (`packages/zanshin_ui/lib/src/controls/zs_control_core.dart`, as `inspector-title` at :1324); `_Meta._parents` (:1547).
- `app/lib/l10n/app_en.arb` + generated `app_localizations*.dart` — `inspectorCopyIdHint`, `inspectorIdCopyFailed`.
- `app/test/features/graph/graph_inspector_test.dart` — `_Details.parents` overrides; keyboard/hint/announcement, outside-layout and stale parent tests.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart:413-436` `fieldSpan`; `app/test/features/graph/revset_configs/revset_configs_window_test.dart` new wrapper-span test.
- `_bmad-output/implementation-artifacts/design_system/ui_kits/desktop/inspector.jsx` `ZKCopyId`; `layout.js` entries (~:160); `app.jsx:168` `realParents`. Reference: `packages/zanshin_core/lib/src/graph_layout/router.dart` `_entries` (:855) and slots (:298).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs`, `schemas/envelope.fbs` (+ codegen) -- item 1.
- `graph_inspector.dart`, `app_en.arb` (+ gen-l10n), `graph_inspector_test.dart` -- items 2, 3, 5.
- `inspector.jsx`, `layout.js`, `app.jsx` -- items 2 (kit), 4.
- `revset_configs_window_test.dart` -- item 6.

**Acceptance Criteria:**
- Given a revset whose alias body fails, when it is parsed, then `detail.message` carries every cause level the CLI prints.
- Given the inspector open, when an id is focused and ↩ or Space is pressed, then the full id is copied and the result announced; its semantics are a focusable button with the hint "Copies the full id".
- Given a dashed-slot node or a sign-0 approach in the kit, when laid out, then entries follow router.dart's owner rules.

## Spec Change Log

- 2026-11-02 (review patch, no loopback): the intent-contract's parenthetical "the CLI's 'Caused by:' levels are exactly `origin()`'s chain" was wrong — the CLI's `print_error_sources` walks `source()`, which also reaches fileset / pattern causes `origin()` (a downcast to `RevsetParseError`) skips. The governing rule "CLI parity for (1)" wins: the code walks `source()`. KEEP: pest message line per level, no columns, `Syntax error: ` only for a revset syntax cause, `without_span` unchanged.

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 16 findings — high 0, medium 2, low 10, false 4, maybe-false 0 (patches applied by the parent session directly)
- findings:
  - `[medium]` `[patch]` (edge) the cause loop walks `origin()`, so a fileset / pattern cause the CLI prints (`files(glob:"[")`) was dropped — now walks `std::error::Error::source()`; pinned "Error at 7: In fileset expression: Invalid file pattern: error parsing glob …".
  - `[medium]` `[patch]` (edge, claim) "CLI levels are exactly origin()'s chain" — same root cause and fix as above; recorded in the Spec Change Log.
  - `[low]` `[patch]` (blind) Esc on the failure popover left keyboard focus nowhere — `_CopyId` owns the control's `FocusNode` and Esc requests it back; tested (`id.hasPrimaryFocus` after Esc).
  - `[false]` `[reject]` (blind) the Tab-stop test never proves the core's node has focus — `ZsControlCore._handleKey` acts only when its own node has primary focus, so ↩ copying proves it; the test now also asserts primary focus after Esc on that node.
  - `[low]` `[patch]` (blind) failure path untested by keyboard, second "Copied" unchecked — the test now fails a Space copy and asserts `['Copied', 'Copied', "Couldn't copy…"]`.
  - `[low]` `[patch]` (blind) untested kind-text fallback could read "Syntax error: Syntax error" — the fallback is gone; a level without a ` = ` line uses its own Display line.
  - `[low]` `[patch]` (blind) `without_span` on a chained message untested — assertion added (`Error: In alias \`x\`: …`).
  - `[low]` `[reject]` (blind) `RecursiveAlias` chain untested — the same source loop as the nested-alias case; no own branch.
  - `[low]` `[patch]` (blind) `docs/ffi-abi.md` lacks `message` — bullet added with the cause-chain format.
  - `[false]` `[reject]` (blind) generated files missing from the diff — excluded from the review diff on purpose; `cargo make codegen` re-run after the doc change, output in the commit.
  - `[low]` `[patch]` (blind) DS `ZKCopyId` has no focus-visible ring and a click-only header comment — `.zk-copyid:focus-visible` ring in kit.css, comment updated. The aria-live / aria-label parts: rejected, item 3 names the app only.
  - `[false]` `[reject]` (blind) `realParents` missing on unfiltered nodes — unfiltered nodes are `repo.changes`, whose `parents + gapParents` is the real parent count the fallback reads.
  - `[false]` `[reject]` (blind) the wrapper-span test lacks a positive counterpart — the existing tests at `revset_configs_window_test.dart:357` / `:387` are the inside path; dropping the guard fails the new one (checked by reasoning: from 0, to 1).
  - `[low]` `[reject]` (intent) item 6's "value not found in its term" branch untested — unreachable: a raw rule's term is the value itself or `revsetGroup(value)` = `(value)` (`revset_config_expression.dart:44`), so `indexOf` never misses; the guard is defensive.
  - `[low]` `[reject]` (intent) the message is one joined line, not the CLI's multi-line "Caused by:" layout — the one-sentence form is Story 10.30's spec'd UI shape; the item asks for the cause the CLI prints, which it carries.
  - `[low]` `[reject]` (intent) the kit's layout port has no test against router.dart — the kit has no harness and its bundle is stale until the orchestrator's republish; a comparison harness is more than the item.

## Design Notes

Item 4 adds `realParents` because the folded kit node no longer knows its change's real parent count, which router.dart's slot rule reads (`parentCounts`). Kit stacks count as not single-parent, as router.dart's stack nodes.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib revset`; `cargo test -p zanshin-jj --test it revset` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed
- app: `flutter test test/features/graph test/l10n`, `dart analyze --fatal-infos`, `dart format --set-exit-if-changed lib test widgetbook` -- pass; zanshin_core analyze + format -- clean
- `node --check ui_kits/desktop/layout.js` -- parses

**Verification notes (2026-11-02, targeted checks only — gate rule of the story loop):**
- `cargo test -p zanshin-jj --lib revset` — 27 passed; `cargo test -p zanshin-jj --test it revset` — 84 passed, 1 ignored.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — regenerated envelope Rust/Dart (doc comment only).
- app: `flutter test test/features/graph test/l10n` — 833 passed; `graph_inspector_test.dart` 68 passed after the matcher fix; `revset_configs_window_test.dart` 28 passed; analyze + format clean.
- packages/zanshin_core: `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` — clean.
- `node --check layout.js` — ok. JSX files not machine-checked.
- After the review patches: `cargo test -p zanshin-jj --lib revset` 27 passed; `--test it revset` 84 passed, 1 ignored; `cargo test -p zanshin-ffi revset` 8 + 12 passed; clippy + fmt clean; `cargo make codegen` re-run and committed; app `flutter test test/features/graph` 828 passed (`graph_inspector_test.dart` 68), analyze + format clean; zanshin_core analyze + format clean.
- Not run (gate rule): full gate, coverage. Not run: parity oracle (no verb changed), Marionette visual check, the DS kit in a browser (its bundle is stale until the orchestrator's republish).

## Auto Run Result

Status: done

**Summary.** (1) A parse error's one-line `message` now appends `: <cause>` per level of its source chain — the levels the CLI's `print_error_sources` prints as "Caused by:" (alias / parameter expansions, fileset and pattern causes), without their columns. (2+3) The inspector's copyable ids run on `ZsControlCore`: a Tab stop with a focus ring, ↩ / Space copy, hint "Copies the full id", "Copied" and the failure announced, Esc on the failure popover returns focus to the id; the DS `ZKCopyId` copies on Enter / Space and shows a focus-visible ring. (4) The kit's `layout.js` counts entries by slot owners as router.dart (dashed lines into a single-parent, non-stack change share one slot; sign-0 approaches go right). (5+6) Tests for the parent-copy branches and the field-mark guard.

**Files changed.**
- `crates/zanshin-jj/src/revset.rs` — cause chain in `parse_detail`, `message_line`, tests.
- `schemas/envelope.fbs`, generated envelopes, `docs/ffi-abi.md` — `message` doc.
- `app/lib/src/features/graph/graph_inspector.dart`, `app/lib/l10n/app_en.arb` (+ generated) — `_CopyId` on `ZsControlCore`, hint, announcements, Esc refocus.
- `app/test/features/graph/graph_inspector_test.dart`, `app/test/features/graph/revset_configs/revset_configs_window_test.dart` — new tests.
- `_bmad-output/implementation-artifacts/design_system/ui_kits/desktop/{inspector.jsx,kit.css,layout.js,app.jsx}` — kit keyboard copy, ring, entry slots, `realParents`.

**Review.** 16 findings: 7 entries patched (1 medium: source() instead of origin(); low: Esc refocus, keyboard failure test, fallback removal, without_span assertion, ffi-abi doc, kit ring/comment), 0 deferred, 9 rejected / false with reasons in the triage log. Follow-up review: false (patched 0 high, 1 medium entry, 6 low).

**Items.**
1. Expansion errors name only the expansion — fixed (commit 8dcbdfadce1b7b67287325f306c2762d5540e679).
2. Copyable ids pointer-only (app and DS kit) — fixed (commit 8dcbdfadce1b7b67287325f306c2762d5540e679).
3. Copyable ids silent to assistive tech — fixed (commit 8dcbdfadce1b7b67287325f306c2762d5540e679).
4. Kit counts entries by edges, not slot owners — fixed (commit 8dcbdfadce1b7b67287325f306c2762d5540e679); the kit renders it only after the orchestrator regenerates `_ds_bundle.js`.
5. Parent copy tested only in-layout — fixed (commit 8dcbdfadce1b7b67287325f306c2762d5540e679): outside-layout and stale tests.
6. Field-mark guard untested — fixed for the reachable wrapper-span branch (commit 8dcbdfadce1b7b67287325f306c2762d5540e679); the "value not found in its term" half rejected: unreachable, the term is the value or `(value)`.

**Residual risks.** No Marionette / VoiceOver check of the focus ring and announcements (mocked channel only); the kit's `layout.js` port is unchecked in a browser; coverage of the changed Rust lines is checked only at the loop's final gate.

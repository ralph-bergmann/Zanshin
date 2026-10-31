---
title: 'Fix run after the 10.2–10.5 review: click slop, catalogue model, jj stale text, focus reload, Reviews dropped'
type: 'bugfix'
created: '2026-10-31'
status: 'done'
baseline_revision: '8e4d698034ab2067800d764c2601b6ea316c7766'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The parity oracle witnesses jj's stale message (and hint) only for the `stale` cause; the
      `sibling_operation` and `operation_not_found` texts are still hand-ported from cli_util.rs.
    evidence: |-
      crates/zanshin-parity/tests/oracle/hints.rs::stale_working_copy_message_is_the_cli_error_line
      builds only a stale second workspace. The other two causes are checked against literals in
      crates/zanshin-jj/src/snapshot.rs (unit test) and tests/it/snapshot_precondition.rs::assert_stale,
      which match cli_util.rs:3040-3075 at v0.46.0 but would not notice a reword at a pin bump.
      Story 9.56's hints had the same gap before this run.
    location: >-
      crates/zanshin-parity/tests/oracle/hints.rs
    severity: low
---

<intent-contract>

## Intent

**Problem:** Ralph's review of Stories 10.2–10.5 (2026-10-31) found five small faults: a card affordance press that moves a little behaves unlike macOS; the catalogue's "Graph / Viewport / View model" use case loses its model on every knob change; the stale-working-copy notice shows a Dart copy of jj's text; file edits made in another app stay invisible until the next jj operation; the rail doc still keeps a hidden Reviews item.

**Approach:** Verify each item against the code, then fix it where real with the smallest change and a test that witnesses it: a 4 px click slop on the card's tap recognizer; a `GlobalKey` that moves the catalogue demo's state into Widgetbook's re-keyed subtree; jj's message carried by Rust in the error context, the notice's command taken from jj's hint; window activation reloads the graph and takes a project reading; the rail doc says Reviews is dropped.

## Boundaries & Constraints

**Always:** Match the jj CLI's observable text exactly (`git -C ../jj show v0.46.0:cli/src/cli_util.rs`, `handle_stale_working_copy` :3010-3079). Keep the stale notice's layout and its "Update working copy" action. Reloads stay coalesced (graph: one in flight + one queued; session: one queued). Gate rule of this run: targeted checks only, no `cargo make test`/`test-full`/`coverage`.

**Never:** A timer or file watcher for item 4; the reload button (10.12 / 11.13); touching packages/zanshin_ui's icon set or the DS (the `reviews` glyph stays); editing epics.md, sprint-status.yaml, project-context.md or epic context files; a new FlatBuffers field when the existing context string can carry the text.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wobbling click | press on •••, pill or add circle, move 2–3 px, release | opens; no pan | — |
| Dragged press | same, move 5 px | nothing opens, no pan | — |
| Empty canvas | press between cards, move 5 px | pans | — |
| Stale `stale` | working copy not updated since op X | context line 4 = `The working copy is stale (not updated since operation X).`; command `jj workspace update-stale` from the hint | — |
| Stale `sibling_operation` | repo at sibling op R of wc op W | line 4 = `The repo was loaded at operation R, which seems to be a sibling of the working copy's operation W`; command `jj op integrate W` | — |
| Stale `operation_not_found` | wc op missing | line 4 = `Could not read working copy's operation.` | — |
| Context without line 4 / no hint | older or hand-built error | message null, command empty | no throw |
| Window turns key | project window inactive → active | graph `reload()` (coalesced) + `refreshNow()`; session takes one reading | read failure logged, as before |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_card_render.dart` -- `RenderGraphCard._tap` (one `TapGestureRecognizer` for body, •••, pill, add circle). A render recognizer has no `gestureSettings`, so its slop is `kTouchSlop` (18 px), not the 1 px the 10.3 review assumed: 2–3 px wobbles already open, but up to 18 px still clicks.
- `app/lib/src/features/graph/graph_viewport_render.dart:605-650` -- `_childHit` pan gate (10.3 review); unchanged.
- `app/widgetbook/folders/graph.dart` -- `_ViewModelDemo` (state owns `FakeGraphSource` + `GraphViewModel`); `package:widgetbook/src/workbench/workbench.dart:82` keys `UseCaseBuilder` on `state.uri` (query included).
- `crates/zanshin-jj/src/snapshot.rs` -- `PreconditionError::StaleWorkingCopy` + `hints()` (Story 9.56); `handle_stale_working_copy` port.
- `crates/zanshin-ffi/src/envelope.rs:614` -- `map_precondition_err` writes the context `<cause>\n<wc_op>\n<repo_op>`; doc at :49 and `crates/zanshin-ffi/src/snapshot.rs:133` (header + `bindings.dart` via codegen), `packages/zanshin_core/lib/src/worker/handle.dart:2766`, `docs/rust-error-codes.md:87`.
- `app/lib/src/features/graph/graph_view_model.dart` -- `GraphStale.fromContext` (the Dart copy), `_fail`, `reload()`/`_requestLayout` coalescing.
- `app/lib/src/features/graph/graph_view.dart` -- `didChangeDependencies` already calls `refreshNow()` when `ZsAppearance.inactive` turns false.
- `app/lib/src/features/projects/project_session.dart` -- private `_refresh()` (coalesced, serial); `app/lib/src/features/home/home_page.dart` is the project window's content (stateless).
- `app/lib/src/features/shell/rail.dart:10` -- the only Reviews mention in app/lib, app/widgetbook, app/test (no hidden item exists).

## Tasks & Acceptance

**Execution:**
- [x] `app/lib/src/features/graph/graph_card_render.dart` -- `graphDragThreshold = 4` (DS ProjectRow "4px threshold") as pre/post-accept slop of `_tap`. (Done in planning, uncommitted; test failed before, passes after.)
- [x] `app/test/features/graph/graph_card_test.dart` -- viewport test: 2 px / 3 px / diagonal wobbles on ••• and the add circle open, 5 px opens nothing and pans nothing, empty canvas still pans; fix the stale "1 px" comment. (Done in planning, uncommitted.)
- [x] `app/widgetbook/folders/graph.dart` -- top-level `GlobalKey` on `_ViewModelDemo`; `app/test/widgetbook/catalogue_smoke_test.dart` -- knob change via `WidgetbookState.updateQueryField` keeps the layout under the notice. (Done in planning, uncommitted; test failed before, passes after. The stale-notice changes below must keep it green.)
- [x] `crates/zanshin-jj/src/snapshot.rs` -- `PreconditionError::message()` with the CLI's three messages (12-hex short ids); unit test; `crates/zanshin-jj/tests/it/snapshot_precondition.rs::assert_stale` checks it.
- [x] `crates/zanshin-ffi/src/envelope.rs` -- context gains line 4, jj's message; docs in envelope.rs, ffi snapshot.rs, handle.dart, rust-error-codes.md; `cargo make codegen`; `crates/zanshin-ffi/tests/it/snapshot_ffi.rs` checks four lines.
- [x] `crates/zanshin-parity/tests/oracle/hints.rs` -- witness: Zanshin's stale message equals the pinned CLI's `Error: ` line for a stale second workspace.
- [x] `app/lib/src/features/graph/graph_view_model.dart` -- `GraphStale.fromError(ZanshinFfiException)`: cause from line 1, message = line 4, command = first backticked span of the first hint; no jj text in Dart; update `graph_view_model_test.dart`, `graph_view_test.dart`, the catalogue's fake/stale notices and `scripted_graph_source.dart` as needed.
- [x] `app/lib/src/features/graph/graph_view.dart` -- activation also calls `model.reload()`; test.
- [x] `app/lib/src/features/projects/project_session.dart` -- public `refresh()`; `home_page.dart` calls it when the window turns active; tests in `project_session_test.dart` and `home_page_test.dart`.
- [x] `app/lib/src/features/shell/rail.dart` -- doc: Reviews is dropped (decision 2026-10-31).

**Acceptance Criteria:**
- Given the catalogue's View model use case after a layout landed, when the stale-cause knob is set, then the notice shows over the cards of that layout.
- Given any stale refusal, when the graph view shows the notice, then its message and command are exactly what Rust sent, and `git grep` finds none of jj's three messages in app/lib.
- Given a project window, when it turns key again, then the graph reloads once (coalesced) and the session reads the open project once.
- Given app/lib, app/widgetbook, app/test, then no Reviews rail item exists and rail.dart says Reviews is dropped.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 29 findings — high 0, medium 0, low 16, false 13, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) "As on macOS" is wrong and the 4 px is a drag-start threshold, not a click slop — the intent itself names the DS drag threshold (4 px) as the line past which nothing opens; the code does what was asked.
  - `[low]` `[reject]` (blind) The wobble test skips the pill, the body and the secondary tap — the pill shares `_Area.bookmarks` with the add circle (pressed), all go through the one `_tap`; no user-facing defect, a coverage nicety.
  - `[false]` `[reject]` (blind) Activation does the work twice (graph reload + session reading, then an op event) — the intent asks for both triggers; a snapshot that writes an operation reloads through the existing coalesced path once, as any outside operation does.
  - `[low]` `[reject]` (blind) An empty command leaves a dangling "·" and an empty Copy — Rust always sends a hint with `jj.stale_working_copy` (`PreconditionError::hints`); only hand-built errors lack one, and guarding it adds branches.
  - `[low]` `[reject]` (blind) `message()` returns `Option` that `map_precondition_err` unwraps with a default — the `None` arm is unreachable for `StaleWorkingCopy`; mirrors `hints()`' shape, no reachable harm.
  - `[low]` `[reject]` (blind) The `#[error]` Display of `StaleWorkingCopy` differs from the CLI text — pre-existing internal Display used in logs only; nothing user-facing reads it, and changing it ripples into other tests.
  - `[low]` `[defer]` (blind) The oracle witnesses only the `stale` cause's message — deferred (frontmatter `deferred`, mirrored to deferred-work.md); the other two causes stay hand-ported like the 9.56 hints.
  - `[low]` `[patch]` (blind) `scripted_graph_source.dart` says "full 40-hex op ids" while Rust sends 128-hex — wording fixed to name the ids stand-ins.
  - `[low]` `[patch]` (blind) zanshin_core `snapshot_test.dart:147` still names and builds the three-line context — renamed and rebuilt around the four-line context.
  - `[low]` `[reject]` (blind) deferred-work.md:2238 and epics.md:9204 still describe the old state — the intent reserves both files for the console session; listed under Auto Run Result for it to book.
  - `[low]` `[reject]` (blind) The home-page test drains the queue through a second `open` — works and is deterministic; a dedicated drain hook would add public surface.
  - `[false]` `[reject]` (blind) The top-level GlobalKey throws if the use case renders twice in one frame — Widgetbook shows one use case per instance and the smoke tests pump one route each; the key is now per Widgetbook instance anyway (edge #2).
  - `[low]` `[reject]` (edge #1) Empty command → dangling "·", empty label and Copy — same as the blind finding above: unreachable from Rust.
  - `[low]` `[patch]` (edge #2) The top-level GlobalKey carries the old state across `ZanshinCatalogueState.open()` of the same route (catalogue.dart:72 promises a fresh start; Widgetbook is keyed on `(_opened, _route)`) — the key is now per Widgetbook instance; a test checks the model survives a knob change and is new after a re-open.
  - `[false]` `[reject]` (edge #3) The project window holds no `GraphView`, so activation reloads no graph — the trigger lives in `GraphView` itself and fires wherever it is mounted; mounting it in the project window is Story 10.12's job.
  - `[false]` `[reject]` (intent) The 4 px cap also applies to the body and secondary tap — one recognizer for the whole card, consistent with the intent's macOS tolerance; the body is a click target too.
  - `[low]` `[reject]` (intent) A press within 4 px released just outside the affordance still opens it — dispatch follows the press area (pre-existing); reaching it needs a release within 4 px of the edge, and a release hit test adds a branch.
  - `[low]` `[reject]` (intent) The pill is not pressed in the test — see the blind coverage row: same `_Area.bookmarks` path as the add circle.
  - `[false]` `[reject]` (intent) The model lives per visit, not per catalogue — the intent's "created once per catalogue" is an "e.g."; the wanted outcome (one model across knob changes) holds and is witnessed.
  - `[low]` `[reject]` (intent) No test switches revset, mode or lane order on the kept model — the same `didUpdateWidget` → `_apply` path the stale-cause knob exercises; the model's own switches are covered in graph_view_model_test.
  - `[false]` `[reject]` (intent) jj's text moved into the catalogue fake and the test helper — they stand in for Rust and must produce what it sends; the AC scopes "no Dart copy" to app/lib, which holds none.
  - `[false]` `[reject]` (intent) `StaleNotice.updateCommand` keeps `jj workspace update-stale` in app/lib — it names what the notice's own button runs, which the intent keeps unchanged; it is not jj's refusal text.
  - `[false]` `[reject]` (intent) The command is a Dart regex parse of the hint — it shows a span of the received hint, no copied text; the notice layout (command beside the sentence) is kept as asked.
  - `[low]` `[defer]` (intent) Only one of three causes is oracle-witnessed — same entry as the blind oracle row.
  - `[false]` `[reject]` (intent) docs/ffi-abi.md untouched — it does not document `jj.stale_working_copy`'s context (rust-error-codes.md does, updated); the FlatBuffers shape is unchanged.
  - `[false]` `[reject]` (intent) The graph trigger has no production path yet — same as edge #3.
  - `[low]` `[reject]` (intent) No end-to-end test shows an outside file edit appearing — the pre-verb snapshot on reads is Story 9.26's, covered there; this run's triggers are witnessed at their call sites.
  - `[false]` `[reject]` (intent) Graph coalescing under load untested — `reload()` is `_requestLayout()`, whose one-in-flight + one-queued coalescing graph_view_model_test "burst: three events during a load…" covers.
  - `[false]` `[reject]` (intent) No Auto Run Result yet — written at finalize.

## Design Notes

- **Where jj's message travels.** The FFI context of `jj.stale_working_copy` gains a fourth line, jj's message without the CLI's `Error: `/`Internal error: ` label — the same convention as the hints, which carry the text without `Hint: `. Lines 1–3 stay, so existing readers keep working; no schema change.
- **The command** shown in the notice is the first backticked span of the error's first hint (Rust already sends jj's hint verbatim, Story 9.56). `StaleNotice.updateCommand` stays: it names what the notice's own button runs (layout and action unchanged), not jj's refusal text.
- **Environment.** Repo `/Users/ralph.bergmann/development/projects/privat/Zanshin`: absolute paths only, never a bare `cd` (zoxide). Run jj only in temp directories a test creates. Commit with `--no-gpg-sign`. Edit files with Edit/Write or Serena, never sed/perl/heredocs.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib snapshot` and `cargo test -p zanshin-jj --test it snapshot_precondition::` -- pass
- `cargo test -p zanshin-ffi --test it snapshot_ffi::` -- pass
- `cargo test -p zanshin-parity --test oracle hints::` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `cargo make codegen` -- committed output
- `flutter test` (app), `dart test` (packages/zanshin_core), `dart analyze --fatal-infos`, `dart format --set-exit-if-changed` on touched packages -- clean

## Auto Run Result

Status: done. Code commit `20b5b0d71905384ab9173a7e8259e8e898a53c37`; spec and ledger in the commit after it.

**Items:**
1. **Fixed** (`20b5b0d7`). Partly real: the intent's evidence was wrong. `RenderGraphCard._tap` has no `gestureSettings`, so its slop was `kTouchSlop` (18 px), not 1 px. A 2–3 px wobble already opened, but up to 18 px still clicked. The recognizer now uses `graphDragThreshold = 4` (DS ProjectRow "4px threshold") as its pre/post-accept slop. A new viewport test checks that 2 px, 3 px and diagonal wobbles on ••• and the add circle open, 5 px opens nothing and pans nothing, and empty canvas still pans; it failed on the 5 px case before the fix.
2. **Fixed** (`20b5b0d7`). Real: verified at `widgetbook/src/workbench/workbench.dart:82`. A smoke test reproduced the empty canvas. The use case now gets one `GlobalKey` per Widgetbook instance (an `Expando` keyed by `WidgetbookState`). Knob changes keep the state, source and model, and `zanshinCatalogue.open` of the same route still starts afresh. The smoke test checks the notice over the cards, the model kept across a knob change, and a new model after a re-open.
3. **Fixed** (`20b5b0d7`). Real. `PreconditionError::message()` returns the CLI's three messages from `cli_util.rs:3040-3075` @ v0.46.0, without the `Error: `/`Internal error: ` label. The FFI context of `jj.stale_working_copy` carries the message as a fourth line, with no schema change. `cargo make codegen` changed only doc text. Dart's `GraphStale.fromError` shows that line, takes the command from the first backticked span of jj's hint, and keeps no copy of jj's text in app/lib. The parity oracle witnesses the `stale` cause against the pinned CLI's `Error:` and `Hint:` lines. The notice's layout and its "Update working copy" action are unchanged.
4. **Fixed** (`20b5b0d7`). Real. When the window turns active, `GraphView` calls `refreshNow()` and then `reload()`, which is coalesced through `_requestLayout`. `ProjectSession.refresh()` is now public and coalesced, and `HomePage` calls it on activation. Tests: `graph_view_test`, `project_session_test` and `home_page_test`. No timer or watcher was added.
5. **Fixed** (`20b5b0d7`). The item was half real. No hidden Reviews item or flag exists in app/lib, app/widgetbook or app/test; the only mention was the doc at `rail.dart:10`, which now says Reviews is dropped (decision 2026-10-31). The icon set and the DS are untouched.

**Files:**
- `app/lib/src/features/graph/graph_card_render.dart`: the 4 px click slop.
- `graph_view.dart`: reload on activation.
- `graph_view_model.dart`: `GraphStale.fromError`.
- `home_page.dart`: `_OnWindowActive` → `projects.refresh`.
- `project_session.dart`: public `refresh()`.
- `rail.dart`: the doc.
- `app/widgetbook/folders/graph.dart`: the per-instance key and the stale notices.
- `app/widgetbook/graph/fake_graph_source.dart`: `staleError` as Rust sends it.
- `crates/zanshin-jj/src/snapshot.rs`: `message()` and `short_op_id`.
- `crates/zanshin-ffi/src/envelope.rs`: context line 4.
- Docs: `crates/zanshin-ffi/src/snapshot.rs`, the header, `bindings.dart`, `handle.dart`, `docs/rust-error-codes.md`.
- Tests: the card, view-model, view, home, session and catalogue tests; `scripted_graph_source.dart`; `snapshot_precondition.rs`; `snapshot_ffi.rs`; zanshin_core `snapshot_test.dart`; the oracle `hints.rs`.

**Review:** 29 findings: 3 patched (all low), 1 deferred entry (low; the blind and intent rows share it; mirrored into deferred-work.md), 12 low rejected and 13 false, each with its reason in the Review Triage Log. Patched counts by verdict: high 0, medium 0, low 3. Follow-up review: **false**.

**For the console session to book:** `deferred-work.md:2237-2239` (the Dart copy of jj's stale text) is resolved by item 3. `epics.md:9204` still describes the three-line context. Neither file was edited here, as the intent asked.

**Verification:** targeted checks only, per the gate rule; no `cargo make test`, `test-full` or `coverage` was run.

| Check | Result |
|---|---|
| `cargo test -p zanshin-jj --lib snapshot` | 15 passed |
| `cargo test -p zanshin-jj --test it snapshot_precondition::` | 29 passed |
| `cargo test -p zanshin-ffi --test it snapshot_ffi::` | 15 passed |
| `cargo test -p zanshin-parity --test oracle hints::` | 7 passed, including the new witness |
| `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` and `cargo fmt --all --check` | clean |
| `cargo make codegen` re-run | output unchanged |
| `flutter test` on `test/features/{graph,home,shell,window}`, `project_session_test`, `projects_window_test` and `test/widgetbook` | 856 passed before the review patches; green again after them |
| `dart test test/ffi/snapshot_test.dart` (zanshin_core) | passed |
| `dart analyze --fatal-infos` and `dart format --set-exit-if-changed` (app: lib, test, widgetbook; zanshin_core) | clean |

`worker_project_repos_test.dart` needs the gate's pinned environment and was not touched; the implementer ran it with that environment and it passed.

**Residual risks:**
- Nobody has looked at the catalogue in Marionette in this run. The notice text should look the same as before, now that it comes from Rust.
- `GraphView` is not yet mounted in the project window (that comes with 10.12), so in the shipped app only the session reading runs on focus.
- The coverage ratchet runs at the console session's gate.
- Only the `stale` cause's message is oracle-witnessed (deferred).

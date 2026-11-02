---
title: 'Story 10.15 — Card action menu (••• and right-click) and the thin bookmark popover'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '54feca43d402e267133fa0d5a77c26b004257c16'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The thin bookmark popover opens on a click (and VoiceOver's action), not on hover and keyboard focus as the 2026-09-28 note asks.
    evidence: |-
      It is a ZsMenuAnchor menu, which takes focus, so a hover must not open it; trigger in graph_card_render.dart _onTapUp _Area.bookmarks.
    location: >-
      app/lib/src/features/graph/graph_card_menu.dart GraphBookmarkMenuHost
    severity: low
  - summary: >-
      The locked menu's "Immutable commits…" row is disabled ("Comes with the Settings window") instead of opening Settings › Project › Immutable commits.
    evidence: |-
      graphCardMenuEntries builds it with enabled false; Story 11.7 (Settings window) is backlog.
    location: >-
      app/lib/src/features/graph/graph_card_menu.dart graphCardMenuEntries
    severity: low
    resolved: >-
      2026-11-02 — fixed (spec-11-7-settings-window, commit 9522ef8): the card menu's Immutable commits… opens Settings on that page.
  - summary: >-
      The card menu, the bookmark popover and the name sheet are not yet checked visually in the running catalogue against the DS Menu card.
    evidence: |-
      Widget tests cover rows, commands, enablement and closing only; the unattended run could not keep a flutter run alive for Marionette.
    location: >-
      app/lib/src/features/graph/graph_card_menu.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** A card's ••• and right-click only flip `GraphCardController.menuOpen`; no menu shows, the bookmark control calls an empty `openBookmarks`, so the shipped verbs (new / -A / -B, edit, describe, squash -r, revert, abandon, bookmark create/delete/rename/move/track/untrack) are unreachable from the card. The commands the UI shows were never parsed by the pinned jj (deferred I1), and remote bookmarks on a card offer no Track/Untrack (deferred I2).

**Approach:** A `GraphCardMenu` host in `GraphView` turns `menuOpen` + the anchor rect the card reports into a `ZsMenuAnchor` (11.11's Menu) with the card's rows built by one pure function over the layout; a second host shows the thin bookmark popover as a menu in the same material, with a small name sheet for Create / Rename / Move to… / Move existing here…. Every row runs through `GraphViewModel.run` (10.9). A shared command file is asserted by a Dart test (the menu's actual `cmd` strings) and run line by line by a new parity-oracle test through `sh` against the pinned jj.

## Boundaries & Constraints

**Always:**
- Menu header: the change id per decision 16.35 (shortest prefix bold, max(prefix, 8) chars, one `Text.rich`) as `headLeading`, the subject (or "(no description set)") as `subject`.
- Rows and right-column commands (full, with the shown short id, `graphShortId` = the inspector's `_shortId` made public); the runner gets the full node key:
  - Mutable: New change on top `jj new <id>` (ZI.newOnTop), Insert after `jj new -A <id>` (insertAfter), Insert before `jj new -B <id>` (insertBefore) · sep · Edit `jj edit <id>` (workingCopyAt; disabled on @, tooltip "Already the working copy"), Describe… `jj describe <id>` (describe; calls `InspectorViewModel.describe(key)`), Squash into parent `jj squash -r <id>` (squash; disabled on a merge "A merge has more than one parent" and when a parent in the layout is immutable "The parent is immutable"), Copy › (copy; Change id = full change id, Description = full description, disabled until content is loaded) · sep · Revert `jj revert -r <id> -B @` (revert), Abandon `jj abandon <id>` (abandon, danger).
  - Revert off with tooltip: on @ "The revert lands below @ — @ itself can't be reverted"; not an ancestor of @ in the layout (walk parent edges from `workingCopyIndex`, direct and indirect) "The revert lands below @ — only changes in @'s history"; content `empty == true` "Nothing to revert — the change is empty". Immutable ancestors of @ allowed. Without @ in the layout the ancestry check is skipped (row on).
  - Immutable non-root (locked menu): New change on top, Insert after (left out when a child of the node in the layout is immutable), Revert (same availability) · sep · note row (`ZsMenuNote`, `HatchSwatch` leading, "Immutable") · Immutable commits… (settings glyph, no command, disabled with tooltip "Comes with the Settings window" until 11.7). No ◆.
  - Root: New change on top only.
- Every row disabled while `!model.actionsEnabled` with tooltip = stale title / busy text (the inspector's `_blocked` strings).
- Opening: ••• click → menu below the ••• circle (anchor box = the circle's rect, flips above without room); right-click → menu at the pointer (zero-size anchor box), clamped 8 px inside the window. A second ••• click closes. The card stays pinned and raised (`menuOpen` already drives both).
- Closing: outside press, Esc (focus back to the graph), row activation, a wheel/trackpad scroll over the graph, a window resize, the window turning inactive, a new selection (`GraphCardController.select`) — all set `menuOpen` to null and close the anchor; the anchor's own close clears `menuOpen`.
- `zanshin_ui`: `ZsMenuNote(label, {leading})` entry (11.5 px `--text-dim`, wrapping, leading in the 16 px column, not focusable, skipped by keys/typeahead/highlight) and `ZsMenuItem.tooltip` (the row shows it on hover, also when disabled; read as the row's hint).
- Bookmark popover (thin): opens from the card's bookmark control (pill or add circle) on click; same material (a `ZsMenuAnchor`), header = the card's id. Per local ref: a submenu `name` (mono) → Rename… (`jj bookmark rename <old> <new>`), Move to… (`jj bookmark move <name> --to <target>`), Delete (`jj bookmark delete <name>`, danger). Per remote ref: `name@remote` row → Track (`jj bookmark track <name>@<remote>`) when the live `bookmarks(allRemotes: true)` read says untracked, Untrack when tracked, disabled "Reading bookmarks…" until the read answers, left out for `git`. Then sep, Create bookmark here… (`jj bookmark create <name> -r <id>`), Move existing here… (`jj bookmark move <name> --to <id>`). Commands come from the existing `GraphBookmark*` actions.
- Name sheet: `ZsSheet` (in the root `Overlay` via `OverlayPortal`) with a title, one mono `ZsTextField` focused at open, the live command in a mono line, Cancel and the gold confirm (disabled while the field is empty); ↩ confirms, Esc cancels.
- Command file `test-fixtures/commands/card-menu.txt`: one command per line, the menu's and popover's `cmd` strings for a fixture card `kmnvxoqp…` (prefix 2) holding local `b-mark` and remote `b-mark@origin`, plus sheet inputs `feature/x` (rename), `@` (move to), `ü` (create; quoted), `b-mark` (move existing). Dart asserts equality; the oracle replaces the word `kmnvxoqp` with `b-mark`'s change id and runs each line in a fresh repo (scenarios::BASE + pushed `b-mark` to a bare `origin`; the track line first untracks) through `sh -c` with the pinned `jj` first on `PATH` and `JJ_EDITOR=true`, asserting exit 0.
- Strings through `app_en.arb` (+ `flutter gen-l10n`); jj commands/words `// l10n-ignore: <reason>`.

**Never:** No Material widgets. No hover-opened popover (a menu that takes focus must not open on hover; see Design Notes). No new Rust/FFI in the cdylib. No drag sources (10.10). No edits to `design/` or `design_system/`. No composed command sequences.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mutable card | right-click | rows as listed; Revert on (ancestor of @) | — |
| @ | ••• | Edit and Revert disabled with tooltips | — |
| Immutable with immutable child | ••• | New on top, Revert, note, Immutable commits… (no Insert after) | — |
| Root | ••• | New change on top only | — |
| Merge / parent immutable | ••• | Squash disabled with reason | — |
| Busy/stale | menu open | rows disabled, tooltip names why; activation runs nothing | — |
| Row run | Abandon | `run(GraphAbandon([key]))`, menu closes | refusal → 10.23's toast |
| Scrolled away | menu open, scroll | menu closes; card stays mounted while open | — |
| Popover remote ref | `b-mark@origin` untracked | Track row → `GraphBookmarkTrack` | read failure → row disabled "Reading bookmarks…" stays, logged |
| Name sheet | empty field | confirm disabled | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_card.dart:172-176` -- `openMenu` / `openBookmarks`: store `menuAnchor` (global rect, `atPointer`) and a `bookmarksOpen` key notifier; `select` closes both.
- `app/lib/src/features/graph/graph_card_render.dart:1125-1146` -- callers: ••• passes `_global(_more)`, bookmarks `_global(_legend ?? _add ?? _card)`, right-click a zero rect at the pointer (keep; it opens even while actions are disabled — rows then show disabled).
- `app/lib/src/features/graph/graph_view.dart:85-326` -- `GraphView` state: mount the two hosts in its `Stack`, close on pointer signal / size change / inactive; add `inspector` (describe) and `bookmarks` (`Future<List<Bookmark>> Function()?`) params; Esc handling at :186-198 stays.
- `app/lib/src/features/graph/graph_canvas.dart:791-813` -- `menuOpen` already pins (`pinnedKeys`) and raises the card.
- `app/lib/src/features/graph/graph_inspector.dart:388-404, 960-1068` -- `_blocked` (stale/busy reason) and `_shortId`; make both public (`graphBlockedReason`, `graphShortId`) for reuse; `InspectorViewModel.describe` at :94.
- `app/lib/src/features/graph/graph_layout.dart:182-312` -- `keyOf`, `changeIdOf`, `changeIdPrefixLengthOf`, `isImmutable`, `rootIndex`, `workingCopyIndex`, `parentCountOf`, `edgeCount`/`childOf`/`parentOf`, `refsOf`, `contentOf`.
- `app/lib/src/features/graph/graph_card.dart:199-345` -- `GraphCardData.of` (immutable, isRoot, isWorkingCopy, merge, content).
- `app/lib/src/features/graph/graph_ports.dart:181-474` -- the `GraphAction`s; `remoteBookmarkSymbol`.
- `app/lib/src/features/graph/hatch_swatch.dart:34` -- `HatchSwatch` for the note row.
- `app/lib/src/features/home/project_graph_host.dart:110-148, 237` -- pass `inspector: graph.inspector` and `bookmarks: () => repo.handle.bookmarks(allRemotes: true)` to `GraphView`.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:21-119, 515-525, 815-830, 991-1129` -- entry types, `step`, the build switch, `_Row`; add `ZsMenuNote`, `ZsMenuItem.tooltip`; export in `packages/zanshin_ui/lib/zanshin_ui.dart:25`.
- `packages/zanshin_ui/lib/src/materials/zs_sheet.dart:39-120`, `controls/zs_text_field.dart:282-301`, `controls/zs_button.dart` -- the name sheet's parts.
- `crates/zanshin-parity/tests/oracle/{main.rs,driver.rs,scenarios.rs:45,git_scenarios.rs:380}` -- new module `card_menu_commands.rs` (declare in main.rs); `driver::fresh_repo`, `driver::command` (copy its envs into the `sh` command), `BASE`, the PUSHED steps.
- `crates/xtask/src/tasks/gate_plan.rs:202-206` -- `test-fixtures/` already plans RUST + APP, so the shared file needs no new rule.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart`, `lib/zanshin_ui.dart`, `test/controls/zs_menu_test.dart` -- `ZsMenuNote` + `ZsMenuItem.tooltip`, exported, tested (note skipped by ↓, tooltip shows on a disabled row).
- `app/lib/src/features/graph/graph_card.dart` -- anchor + bookmarks state in the controller.
- `app/lib/src/features/graph/graph_inspector.dart` -- publish `graphShortId`, `graphBlockedReason`.
- `app/lib/src/features/graph/graph_card_menu.dart` (new) -- `graphCardMenuEntries(...)` (pure), `graphBookmarkMenuEntries(...)` (pure), `GraphCardMenuHost`, `GraphBookmarkMenuHost`, `GraphNameSheet`.
- `app/lib/src/features/graph/graph_view.dart` -- mount hosts, close triggers, new params.
- `app/lib/src/features/home/project_graph_host.dart` -- wire inspector + bookmarks read.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- row labels, reasons, sheet titles/labels, "Reading bookmarks…", "Comes with the Settings window".
- `app/test/features/graph/graph_card_menu_test.dart` (new) -- witnesses below + the command-file equality.
- `test-fixtures/commands/card-menu.txt` (new) -- the shared command lines.
- `crates/zanshin-parity/tests/oracle/card_menu_commands.rs` (new) + `main.rs` -- the oracle run.

**Acceptance Criteria:**
- Given mutable, immutable (with and without an immutable child), @, root and merge cards, when the menu opens, then the rows, their enabled state and tooltips are exactly as in Boundaries.
- Given any enabled row, when activated (click or ↩), then `GraphViewModel.run` receives the matching action with the full key, and the row's right column equals that action's `command` built with the short id.
- Given a disabled row (busy, stale, view fact), when clicked, then nothing runs.
- Given ••• is clicked twice, then the menu opens then closes; given a right-click, then the menu opens at the pointer; given an open menu, when Esc, an outside press, a scroll, a resize or window blur happens, then it closes and `menuOpen` is null.
- Given an open menu whose card is scrolled out of view, then the card stays mounted.
- Given Describe…, then the card is selected and its describe form opens.
- Given the popover on a card with `b-mark` and an untracked `b-mark@origin`, then Track runs `GraphBookmarkTrack('b-mark', 'origin')`; Create… opens the name sheet and confirms `GraphBookmarkCreate([name], revision: key)`; Delete runs `GraphBookmarkDelete(['b-mark'])`.
- Given `test-fixtures/commands/card-menu.txt`, then the Dart test's menu/popover commands equal its lines, and the oracle runs every line successfully with the pinned jj.

## Design Notes

- Menu placement uses `ZsMenuAnchor`'s own rule (below the anchor's left edge, flipped above; at the pointer for a right-click); the design's right alignment under ••• is a small deviation (design is inspiration).
- The popover is a click-opened menu, not the design's hover popover: 11.11's Menu takes focus, which a hover must not steal; the final popover is a later redesign (deferred, Low).
- Revert's ancestry comes from the layout's edges (indirect edges are ancestry through hidden commits), not from a `revsetCounts` call: same answer for every node the view shows, no extra read.
- The note row has no reason after "Immutable" until 11.7's immutable-reason producer exists (the inspector flag does the same).

## Verification

**Commands (gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `flutter gen-l10n` in `app/` -- regenerates localizations (commit them)
- `flutter test` in `packages/zanshin_ui/` and `app/` (graph, home, shell tests, then the whole suite) -- all pass
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .` in both packages -- clean
- `cargo test -p zanshin-parity --test oracle card_menu` -- pass
- `cargo clippy -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean

**Manual checks:**
- Marionette in the catalogue if a long-running `flutter run` is possible; else record why not.

## Verification Notes

- `flutter gen-l10n` (app) regenerated the localizations.
- `flutter test` in `packages/zanshin_ui/`: 439 passed (incl. the new note/tooltip witness). In `app/`: 1559 passed, 5 failed — all in `test/features/projects/worker_project_repos_test.dart` ("XDG_CONFIG_HOME is not pinned to target/test-xdg-config — run via cargo make"), the real-worker tests that need the gate's environment; untouched by this story. `test/features/graph/graph_card_menu_test.dart`: 17 passed.
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .`: clean in both packages.
- `cargo test -p zanshin-parity --test oracle card_menu`: pass — all 15 lines of `test-fixtures/commands/card-menu.txt` exit 0 with the pinned jj.
- `cargo clippy -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check`: clean.
- Marionette check not done: the run forbids long-running/background processes, and a catalogue check needs `flutter run` kept alive while Marionette connects. Ralph's visual check (and the catalogue use case, if wanted) remains.
- Deviations: `GraphView`'s new parameter is `inspectorModel`, not `inspector` (the static `GraphView.inspector` slot builder owns that name). Remote refs show as a `name@remote` submenu holding Track or Untrack (mirrors the local refs' submenu; disabled "Reading bookmarks…" until the read answers; a ref the read no longer lists is left out). Rename… / Move to… / Create… / Move existing here… show no command in the row — the sheet shows it live. Menu commands end in an ellipsis past 170 px (`cmdMaxWidth`). `git_scenarios::PUSHED` became `pub` for the new oracle module.
- Re-verification after the review patches (parent run, 2026-11-01):
  - The patch "clear `open` when the anchor is missing" broke two `graph_view_test.dart` tests that set `menuOpen` directly; the parent changed it to: no anchor → show nothing (keep the key), box not laid out → retry after the frame, then clear.
  - `flutter gen-l10n`: no diff. `dart analyze --fatal-infos` (app): no issues. `dart format --set-exit-if-changed .` (app): 0 changed.
  - `flutter test` in `app/`: 1564 pass, 5 fail — the `worker_project_repos_test.dart` real-worker tests, which pass (33) with `XDG_CONFIG_HOME=target/test-xdg-config`; untouched by this story.
  - `flutter test` in `packages/zanshin_ui/`: 439 pass.
  - `cargo test -p zanshin-parity --test oracle card_menu`: pass (15 lines). `cargo clippy -p zanshin-parity --all-targets -- -D warnings` and `cargo fmt --all --check`: clean.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 44 findings — high 0, medium 4, low 26, false 12, maybe-false 2 (intent-audit divergences counted as findings)
- findings:
  - blind-hunter
    - `[low]` `[reject]` the name sheet confirms while busy/stale or after the change left the layout — `GraphViewModel.run` answers `GraphActionDisabled` and runs nothing; rare (an action starting while the sheet is open); the fix adds gating state.
    - `[low]` `[patch]` `_MenuHost._changed` keeps `open` set when the anchor or box is missing, so the next ••• click toggles closed — the early return clears `open`; a host mounting with a stale key clears it too.
    - `[medium]` `[patch]` a failed bookmark read leaves remote rows "Reading bookmarks…" forever; a non-FFI error escapes the unawaited future — any error is caught and logged; the rows show a failure reason; tested.
    - `[low]` `[reject]` the list is re-read on every open, also without remote refs — one cheap read per click on a placeholder surface; skipping it adds a branch.
    - `[false]` `[reject]` Move to / Move existing here offer no `--allow-backwards` — the CLI's default is the same; jj's refusal reaches 10.23's toast verbatim (CLI parity).
    - `[low]` `[reject]` Move existing here… asks for a typed name instead of a pick — thin placeholder by decision (d); a typo gets jj's refusal.
    - `[low]` `[patch]` whitespace-only input enables Confirm — enabled and sent on the trimmed text.
    - `[false]` `[reject]` Revert's ancestry check is skipped when @ is not in the layout — that is the spec's stated rule (no fact to judge by; jj accepts the revert).
    - `[low]` `[reject]` the immutable parent/child guards look at direct edges only — an immutable commit hidden behind an indirect edge is rare; jj's refusal is shown; the fix needs edge-kind policy.
    - `[low]` `[reject]` the oracle checks the commands run, not the menu's guards against the CLI's refusals — I1 asks that the shown strings parse and run; the guards are the design's view facts.
    - `[low]` `[patch]` Copy is disabled while busy/stale though it only touches the clipboard — Copy no longer gated on `blocked`.
    - `[low]` `[reject]` Copy › Description keeps jj's trailing newline — it copies the description exactly as jj stores and prints it (`jj log -T description`).
    - `[low]` `[reject]` the head shows the change id while a divergent/hidden card's commands name the commit id — rare (divergent or hidden cards); the head's id is the card's own.
    - `[low]` `[reject]` keyboard scroll, reveals and reloads do not close the menu — the design's close triggers are press, Esc, wheel, resize, blur; the menu stays where it opened.
    - `[low]` `[patch]` no tests for resize/inactive close, node leaving the layout, Esc/Cancel in the sheet — inactive and resize close are tested (grouped with verification-gap #1).
    - `[maybe-false]` `[reject]` a disabled row's reason may be read twice (hint + tooltip semantics) — would need VoiceOver on a device; if true only low.
  - edge-case-hunter
    - `[medium]` `[patch]` non-FFI error from `bookmarks()` escapes (grouped with blind #3).
    - `[medium]` `[patch]` a failed read shows no reason (grouped with blind #3).
    - `[low]` `[patch]` anchor/box missing leaves a ghost open state (grouped with blind #2).
    - `[low]` `[patch]` layout turning null with a menu open unmounts the hosts with the key still set — a host mounting with a stale key clears it (grouped with blind #2).
    - `[false]` `[reject]` open switching from card A to B while A's menu is open — the open menu consumes outside presses (`consumeOutsideTaps`), so no right-click or ••• reaches card B until it closed.
    - `[low]` `[reject]` the menu box is not recomputed when a reload moves the card (grouped with blind #14).
    - `[low]` `[reject]` keyboard/scrollbar/programmatic scroll does not close (grouped with blind #14).
    - `[false]` `[reject]` Revert enabled when @ is outside the layout (same as blind #8).
    - `[false]` `[reject]` Revert enabled while content is unloaded — the epics' 2026-10-26 note: "until 10.11's content says empty, the row is on".
    - `[low]` `[reject]` indirect immutable parent (grouped with blind #9).
    - `[low]` `[reject]` sheet confirmed while blocked (grouped with blind #1).
    - `[low]` `[patch]` whitespace-only input (grouped with blind #7).
    - `[false]` `[reject]` ↩ and a click in one frame run twice — the first confirm runs and the second reaches `run` while the first holds the runner, which answers `GraphActionDisabled(busy)`.
  - verification-gap
    - `[low]` `[patch]` inactive window / resize close untested — two widget tests added.
    - `[low]` `[patch]` ProjectGraphHost's `inspectorModel` / `bookmarks` wiring untested — asserted on the mounted `GraphView`.
    - `[low]` `[patch]` the controller's mutual close (menu ↔ popover, select) untested — controller unit test extended.
    - `[low]` `[patch]` Copy › rows' clipboard text untested — clipboard mocked, full change id and description asserted, Description disabled without content.
    - `[low]` `[patch]` a menu whose change leaves the layout is not closed by a test — added when the scripted source allows it (see Verification Notes).
    - `[medium]` `[patch]` read failure handling (grouped with blind #3).
  - intent-alignment
    - `[false]` `[reject]` I2's "and the card menu where a remote bookmark sits" is not done — the epics' 2026-10-14 note (Ralph's design ruling) says "The card menu gets no bookmark rows"; Track/Untrack live in the popover, which opens from the card.
    - `[low]` `[defer]` the popover opens on a click, not on hover/focus — a focus-taking menu must not open on hover; mirrored to deferred-work.md.
    - `[low]` `[defer]` Immutable commits… is disabled instead of opening Settings — 11.7 is backlog; mirrored to deferred-work.md.
    - `[false]` `[reject]` the note row lacks "· <reason>" — already deferred to 11.7's producer (deferred-work.md, "11.7's cached producer lands; 10.8's flag and 10.15's menu read it").
    - `[false]` `[reject]` Revert's ancestry from layout edges instead of `revsetCounts` — for every card the view shows, indirect edges carry ancestry through hidden commits, so both give the same answer.
    - `[false]` `[reject]` I1 only proves parse/run, not effect parity — I1 asks exactly that ("parses / runs them, so a wrong flag or quoting fails"); effect parity of the verbs is the oracle's existing scenarios.
    - `[false]` `[reject]` Rename / Move to / Move existing here should wait for 9.19 — 9.19 shipped (`RepoHandle.bookmarkMove` / `bookmarkRename`, `GraphBookmarkMove/Rename` in 10.9, oracle scenarios `bookmark_move_*`, `bookmark_rename_*`).
    - `[false]` `[reject]` the name sheet is extra surface — Create needs "a name field" (item 3), and Rename/Move need the same input.
    - `[maybe-false]` `[reject]` witnesses not exercised (card mounted while scrolled away, submenu timing on the card menu) — a scroll now closes the menu; submenu timing is 11.11's tested Menu; would only be low.

## Auto Run Result

Status: done. Code commit `de471e9e2dc846a567f80f7126cfc1a5bf902a5b`.

**Summary.** A card's ••• and right-click open the card menu (11.11's Menu): New change on top, Insert after, Insert before · Edit, Describe…, Squash into parent, Copy › · Revert, Abandon, each with its full jj command on the short id; an immutable change gets the locked menu (New on top, Insert after unless a child is immutable, Revert, the Immutable note, Immutable commits…), the root only New on top. Reasons (Edit on @, Squash on a merge / immutable parent, Revert on @ / outside @'s history / empty, busy, stale) show as row tooltips. The menu closes on an outside press, Esc, a wheel, a resize, window blur, a selection and when its change leaves the layout. The bookmark control opens a thin popover (same material) with Rename… / Move to… / Delete per local ref, Track / Untrack per remote ref (from a live `bookmarks(allRemotes: true)` read), Create bookmark here… and Move existing here…, the four inputs through a name sheet. Every row runs through `GraphViewModel.run`.

**Files.**
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` (+ export, test): `ZsMenuNote`, `ZsMenuItem.tooltip`.
- `app/lib/src/features/graph/graph_card_menu.dart` (new): row builders, the two hosts, `GraphNameSheet`.
- `graph_card.dart`: anchors, `bookmarksOpen`, `closeMenus`; `graph_inspector.dart`: `graphShortId`, `graphBlockedReason` public; `graph_view.dart`: hosts + close triggers; `home/project_graph_host.dart`: inspector + bookmark read wiring; `l10n/app_en.arb` + generated localizations.
- `test-fixtures/commands/card-menu.txt` (new) and `crates/zanshin-parity/tests/oracle/card_menu_commands.rs` (new; `main.rs`, `git_scenarios.rs` `PUSHED` pub).
- Tests: `graph_card_menu_test.dart` (new, 21), `graph_card_test.dart`, `project_graph_host_test.dart`, `zs_menu_test.dart`.

**Review.** One pass, 44 findings: 4 medium, 26 low, 12 false, 2 maybe-false.
- Patched: the bookmark read failure (catch-all, visible reason; medium), the stale open state of a host (missing box / remount), trimmed sheet input, Copy not gated on busy/stale, and tests for inactive/resize close, the change leaving the layout, the controller's mutual close, the clipboard text and the host wiring.
- Deferred (mirrored to deferred-work.md): the click-opened popover (not hover), Immutable commits… until 11.7, the Marionette check.
- Rejected: every other finding, with its reason in the Review Triage Log.

**Follow-up review:** not recommended — no high patched; the patched entries are one medium root cause (the read failure) plus lows, all covered by the new tests. Patched by verdict: 1 medium entry, 7 low.

**Open items:**
- I1: fixed (`de471e9e2dc846a567f80f7126cfc1a5bf902a5b`). The commands the card menu, the popover and the name sheet show are in `test-fixtures/commands/card-menu.txt`; the app test asserts the UI's strings equal it line for line, and `cargo test -p zanshin-parity --test oracle card_menu` runs every line through `sh -c` with the pinned jj in a fresh repo (exit 0 required), so a wrong flag or quoting fails.
- I2: fixed (`de471e9e2dc846a567f80f7126cfc1a5bf902a5b`). The thin bookmark popover offers Track / Untrack for each remote bookmark on the card (`jj bookmark track|untrack <name>@<remote>`, 10.14's `GraphBookmarkTrack` / `GraphBookmarkUntrack`). The card menu itself gets no bookmark rows, by the epics' 2026-10-14 ruling ("The card menu gets no bookmark rows"); the popover opens from the same card.

**Residual risks:** no Marionette/visual check against the DS Menu card; the popover opens on click rather than hover; a menu stays at its opening position across a reload or keyboard scroll (it closes when its change leaves the layout).

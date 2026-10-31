---
title: 'Story 10.21 — Graph search: the field, the one menu, go-to and filters, suggestions, Recent, the default search'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: 'd634e8985ca698f04e463036ac67ff94f693a0b1'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The search field, its menu, suggestions and footer have not been compared against the DS search cards in the running catalogue; only widget tests check them.
    evidence: |-
      Unattended run: the Widgetbook catalogue cannot be run in the background, so the Marionette / Playwright check of the epic's definition of done was not done. Widget tests assert texts, widths, rows and semantics in app/test/features/graph/graph_search_field_test.dart.
    location: >-
      app/lib/src/features/graph/graph_search_field.dart
    severity: medium (unverified)
  - summary: >-
      The field is not a true combobox with a listbox and an active descendant (item 9); VoiceOver gets the keyboard row only as the field's hint, untested on device.
    evidence: |-
      Flutter's SemanticsRole.comboBox is unimplemented in this SDK (flutter/lib/src/semantics/semantics.dart:198, `_unimplemented`); the field's Semantics has textField plus the keyboard row's label as hint.
    location: >-
      app/lib/src/features/graph/graph_search_field.dart
    severity: low
  - summary: >-
      The search's production pieces (RepoGraphSearchSource, ProjectSearchStore, GraphSearchShortcuts, the logDefaults re-read on window focus) have no production caller until 10.12 mounts the graph in the project window.
    evidence: |-
      No file in app/lib builds GraphViewControls or RepoGraphSource; the only mount is app/widgetbook/folders/graph.dart. RepoGraphSearchSource.files (the FileEntry.path mapping) and user.email via configGet are untested for that reason.
    location: >-
      app/lib/src/features/graph/graph_ports.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The VIEW island has no search: the graph always shows `revsets.log` (10.7 left room for 10.21), there is no go-to-change affordance (10.6's design question (d)), and the revset text for structured filters has no owner. Four deferred items name 10.21: I1 go-to beyond the view, I2 the counts mitigation, I3 the calm hold for the search's surfaces, I4 UTF-8 span offsets.

**Approach:** Build epics.md Story 10.21 (incl. its design update 2026-10-16) on fake ports, as Epic 10 does until 10.12: a pure revset builder plus a UTF-8→UTF-16 span helper in `zanshin_core`; in the app a `GraphSearchSource` port (op-pinned counts, `findChanges`, `bookmarks`, `fileList` at @, `user.email`, content), a per-repository `GraphSearchStore` (shown view + Recent), a `GraphSearchController` that owns what the graph shows and drives `GraphViewModel`, and the `GraphSearchField` widget (well, pill, one menu, suggestions, footer) placed first in `GraphViewControls`, wired into the Widgetbook catalogue.

## Boundaries & Constraints

**Always:**
- The view state is one of: the default search (`jj log` = the effective `revsets.log`, read from `logDefaults()`; until 10.22 the default search is always `jj log`), the built-in `all()`, or a typed filter `{scope author|file|description, kind, value, ci}` (or "you" = `mine()`). `GraphRequest.revset` derives from it; the default sends `logDefaults().log` (the model's `null` revset), `all()` sends `all()`, a filter the builder's text, run in `all()`.
- `logDefaults()` is re-read with every layout request (a config edit writes no operation).
- The builder lives in `zanshin_core`, writes explicit pattern kinds (`substring:`, `exact:`, `glob:`, `regex:`, each with `-i` for case-insensitive; paths `cwd:"…"` prefix, `file:"…"`, `glob:"…"`), quotes text as a jj string literal (straight quotes; escapes as jj's `format_string`), and the UI shows and sends its output verbatim. Footer command = `jj log -r '<expr>'` shell-quoted as 10.9's `_jj` does.
- Go-to: the shown topology first (change-id / commit-id prefixes, refs, the content cache's subjects), then `findChanges` over `all()` pinned to the layout's operation (the input as a revset symbol, jj's ambiguous-prefix refusal shown verbatim as a row; `description(substring-i:…)` for text). A visible target → `GraphViewModel.goTo` (select, reveal, pulse; a folded member opens via keepOpenKeys). A hidden target → one request with `all()`, the target selected, revealed and pulsed when it lands; no later re-centre on @. The field then returns to what the graph shows. Bookmark go-tos and recent go-tos pulse too.
- Counts: every filter row shows "N changes" from `revsetCounts` (cap 10,000, "10,000+" when capped), batched per 150 ms typing pause, cached per (operation, expression), rows render before counts, a zero count dims the row. I2 mitigation: `files()` rows are counted only when they are the keyboard row (a single `files()` count diffs every commit without a changed-path index); author/description counts always.
- The menu and the suggestions are one field-attached list (`ZsFieldListController` + `ZsFieldListRow`): focus stays in the field, ↑↓ move the keyboard row, hover never moves it, a click runs the row, the shown row carries a check; Home/End move the menu's keyboard row and the caret in the suggestions. While either is open it holds the shell's calm (`ShellScope.maybeOf(context)?.openSurface()`, released on close) — I3.
- Revset errors (`model.revsetError`): jj's message in the popover footer with 9.25's span underlined, converted from UTF-8 bytes to UTF-16 by the shared `zanshin_core` helper — I4. With the default search failing, the `jj log` menu row is marked broken.
- Shown view and Recent persist per repository on `ProjectEntry` (like 10.17's stack toggles); Recent stores 10, shows 6, filtered per scope, has Clear; a go-to whose change is absent from a shown `all()` layout is hidden; a bookmark go-to keeps the bookmark's name.
- Stale working copy: the field is disabled with the reason. Inactive window: rest edge, no halo/caret, pill tint neutral (`ZsAppearance.inactive`).
- Strings through `app_en.arb`; jj words, revsets and commands are literals marked `// l10n-ignore:`. Controls from `zanshin_ui`; Material types only via `package:material_ui`.

**Never:**
- A free-text revset, Save, the variant segment, the save form; walking hits with Enter; minimap hits; writing `revsets.log`; the capsule/island/calm machinery itself; jj log Configurations (10.22: "Edit Configurations…" is shown disabled until 10.22 passes its callback); menu-bar items (11.13); mounting the graph in the production app (10.12).
- The UI composing revset text outside the builder (the go-to symbol uses the existing `jjRevsetSymbol`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Filter | `a:` then `lena`, Enter on "Lena König" | one request `author(exact:"Lena König")`; field shows Author · value; recent added | count error → row shows no count |
| Prefix keys | type `f: lib/` | scope File, value `lib/` | Backspace in empty field → Any |
| Go-to visible | `c: kx` matching a shown change | select + reveal + pulse, no request | — |
| Go-to hidden | id found only by `findChanges` | one request `all()`, target selected/revealed/pulsed on land | ambiguous prefix → refusal row, Enter does nothing |
| ✕ | typed filter shown | one request for the default (`revset == logDefaults().log`) | — |
| Revset error | `author(regex:"(")` | graph keeps last layout; footer shows jj's message, span underlined at UTF-16 offsets | non-ASCII before span converted |
| Stale | model.stale != null | field disabled with jj's reason | — |
| Esc | suggestions open | first Esc closes; second restores field and blurs | — |

</intent-contract>

## Code Map

- `packages/zanshin_core/lib/src/ffi/revset_search.dart` -- `RevsetSpan{offset,length}` in UTF-8 bytes (:102); `RevsetErrorDetail` (:118); counts/found models. I4 helper goes next to it.
- `packages/zanshin_core/lib/zanshin_core.dart` -- public `show` lists; add the builder, the span helper and `FileEntry` (not exported yet; `src/ffi/file.dart:140`).
- `packages/zanshin_core/lib/src/worker/handle.dart` -- `revsetCounts(op, exprs, cap:)` :476, `findChanges(op, expr, limit:, shortPrefixes:)` :501, `bookmarks()` :325, `fileList(revision:)` :1750, `logDefaults()` :416. `configGet` only on the worker (`isolate.dart:3470`), so the repo source takes a `userEmail` function.
- `packages/zanshin_core/test/worker/revset_search_test.dart` -- real-cdylib medium fixture pattern; add the builder parse witness here.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphRequest`, `GraphSource`, `RepoGraphSource` (:688, passes functions until 10.12), `_jj` shell quoting (:463).
- `app/lib/src/features/graph/graph_layout.dart` -- `jjRevsetSymbol` (:56); `indexOfKey`, `changeIdOf`, `commitIdOf`, `changeIdPrefixLengthOf`, `refsOf`, `isFolded`, `operationId`, `workingCopyIndex`.
- `app/lib/src/features/graph/graph_content.dart` -- `GraphContent.of(layout, node)` (subject, authorName, authorEmail).
- `app/lib/src/features/graph/graph_view_model.dart` -- `setRevset` (:399), `goTo` (:306), `_run` defaults read (:774), `_build` (:805), `_land` pulse-on-land (:843), `revsetError`, `stale`.
- `app/lib/src/features/graph/graph_controls.dart` -- `GraphViewControls` (:104) and the calm-hold pattern (`_opened`/`_closed` :184-201, `RawMenuAnchor` overlay).
- `app/lib/src/features/graph/graph_stack_store.dart` -- `ProjectStackStore`, the per-repo persistence pattern to mirror.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` -- `ProjectEntry` freezed fields (:62-66); add `graphView` and `recentSearches`, regenerate.
- `packages/zanshin_ui/lib/src/controls/zs_field_list.dart` -- `ZsFieldListController` (attach/next/previous/first/last/activate), `ZsFieldListRow` (active, shown check, icon).
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart` -- `ZsSearchField` (:600) look: `_WellPainter`, `ZsAppearance.inactive`, undecorated `TextField`; the graph well copies its look (pill + input + ✕ + ⌘F) in the app.
- `app/widgetbook/folders/graph.dart` -- the catalogue mount (`FakeGraphSource` :440, `GraphViewControls` :510-523); `app/widgetbook/graph/fake_graph_source.dart`.
- `app/test/helpers/scripted_graph_source.dart`, `app/test/features/graph/graph_harness.dart` (`handLayout`) -- test fakes.
- Design: `_bmad-output/implementation-artifacts/design/graph-search.jsx` (SR: scopes/prefixes :44-60, scoring `suggest` :117-169, `compose` :170-188, rows/footer :334-417), `design_system/components/search/search.css`, `revset-config-search.jsx:48-55` (rule shapes).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/src/revset_text.dart` (new, exported) -- `revsetStringLiteral`, `RevsetTextPattern` (substring/exact/glob/regex), `RevsetPathPattern` (prefix/file/glob), `authorRevset`, `descriptionRevset`, `filesRevset`, `mineRevset`, and `revsetSpanUtf16(String text, RevsetSpan span)` → `({int start, int end})` -- one owner of revset text (item 7) and of the byte→UTF-16 conversion (I4, shared with 10.22).
- `packages/zanshin_core/test/revset_text_test.dart` + a test in `test/worker/revset_search_test.dart` -- golden strings for every scope/mode; on the medium fixture every string counts without error.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` (+ generated) -- `String? graphView`, `List<String> recentSearches`.
- `app/lib/src/features/graph/graph_search_model.dart` (new) -- scopes + prefixes, `GraphFilter`, `GraphShownView` (default/all/filter, JSON), `GraphRecent` (go-to/filter, JSON), revset + command derivation.
- `app/lib/src/features/graph/graph_search_index.dart` (new) -- candidates from layout + content + bookmarks + paths + found changes; `suggest`/`compose` per SR (limits Any 3/2/2/3/1 + "N more", scope ≤ 8, Description + ≤6 changes, fallback note, empty).
- `app/lib/src/features/graph/graph_search_store.dart` (new) -- `GraphSearchStore` interface + `ProjectSearchStore` + in-memory.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphSearchSource` port + `RepoGraphSearchSource`.
- `app/lib/src/features/graph/graph_search_controller.dart` (new) -- view state, persistence, apply/goTo/clear/pickVariant, Recent, counts cache + batching, findChanges lookups, error text.
- `app/lib/src/features/graph/graph_view_model.dart` -- `setRevset(String?)` (null = the default), `goToHidden(key)` (all() + select + reveal + pulse on land), re-read `logDefaults()` per request.
- `app/lib/src/features/graph/graph_search_field.dart` (new) -- the well, pill, input, ✕, ⌘F hint, widths, keys, the overlay with menu or suggestions + footer + error, calm hold, semantics, `GraphSearchShortcuts` (⌘F, `/` outside a text field, not while a modal route covers it).
- `app/lib/src/features/graph/graph_controls.dart` -- `GraphViewControls(search:)` puts the field first.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- the strings.
- `app/widgetbook/...` -- a fake search source and the field in the floating graph.
- `app/test/features/graph/graph_search_*_test.dart` -- witnesses below.

**Acceptance Criteria:**
- Given the default search, when the field renders, then it is empty with the calm pill, the placeholder and the `⌘F` hint, and no ✕; given a typed filter it shows the scope label and value and a ✕ titled "Back to the default search — jj log"; given `all()` it shows `$` and `all()`.
- Given the menu open, then its rows are: `jj log` tagged Default, `all()`, Go to (Change `c:`, Bookmark `b:`), Filter by (Author `a:`, File `f:`, Description `d:`), Edit Configurations…; the shown row has a check; picking `jj log` sends exactly `logDefaults().log`, `all()` sends `all()`.
- Given a filter row is the keyboard row, when Enter, then exactly one request with the footer's expression is sent and a recent is stored for this repository.
- Given a visible go-to target, when picked, then it is selected, revealed and pulsed without a request; given a hidden one, then one request `all()` and the reveal land, and the selection is the target.
- Given suggestions on a fixture index, then the limits, "N more", the fallback note and the empty text appear; each count is requested once per (operation, expression); a zero count dims its row; a File row is counted only as the keyboard row.
- Given the menu or the suggestions open, then the shell's calm is held, and released when they close.
- Given a revset error with a span after a non-ASCII character, then the footer underlines the right UTF-16 range.
- Given ⌘F or `/` outside a text field, then the field takes focus with its text selected; `/` typed inside another text field types a slash.
- Given window widths on both sides of 1180, 1100 and 980, then the input is 320 above 1180 and 250 at ≤ 1180, the pill drops its label at ≤ 1100, and at ≤ 980 the input is 170 with no `⌘F` and the short placeholders.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 51 findings — high 0, medium 10, low 30, false 6, maybe-false 5
- findings:
  - Blind Hunter:
  - `[low]` `[patch]` caches keyed per (op, expression) never shrink — `_sync(op)` clears every cache and pending set when the shown operation changes.
  - `[low]` `[patch]` failures cached for the operation; `user.email` never retried — email is marked read only once a value came back; a lookup error stays cached (an ambiguity refusal is the answer; transient worker errors are rare).
  - `[false]` `[reject]` counts filled only up to `min(expressions, counts)` leave rows unanswered — Rust writes exactly one entry per expression (`revset_search.dart` decoder; 9.25 contract); `op == null` at flush cannot follow a non-null op at want time except across a reload, now handled by `_sync`.
  - `[low]` `[patch]` candidates stale while the field stays open across an operation — a model notify with a list open calls `prepare()` (op-guarded).
  - `[low]` `[patch]` the port doc claims every read is op-pinned — doc fixed: only counts, finds and content are pinned.
  - `[low]` `[patch]` the index is rebuilt per Recent row — built once per refresh and passed to the Recent rows.
  - `[low]` `[reject]` file suggestions scan @'s whole tree per keystroke — a substring scan over the path list is milliseconds even at tens of thousands of paths; the fix (an incremental index) adds complexity for a case not met in practice.
  - `[low]` `[reject]` highlights shift for characters whose lower case changes length (`İ`) and `ö` counts as a word break — rare in ids, paths and names; the fix needs a case-folding matcher.
  - `[low]` `[patch]` hard-coded `,` thousands separator — `NumberFormat.decimalPattern(localeName)` (intl already a dependency). `[low]` `[reject]` the lower-cased scope name in the fallback note and the name's first word — English-only today; the ARB carries the descriptions.
  - `[false]` `[reject]` the error footer has no text to underline when the default search fails — `GraphRequest.revset` is a required String built as `_revset ?? defaults.log` (graph_view_model.dart `_build`), never empty for the default.
  - `[low]` `[reject]` an error at the end of the input underlines nothing — the message still shows; a caret marker is a new visual the design does not have.
  - `[low]` `[reject]` `logDefaults()` read before every request costs a round trip — the story requires the re-read (item 1: a config edit writes no operation); one cheap FFI call per layout request.
  - `[medium]` `[patch]` `_revset == old → null` on every request turns `all()`/a filter equal to the old `revsets.log` into the default — now only when the re-read log changed.
  - `[medium]` `[patch]` the keyboard row is invisible to VoiceOver — field Semantics `textField: true` with the keyboard row's label as hint; the full combobox is deferred (Flutter's comboBox role is unimplemented). `[false]` `[reject]` Recent's Clear is not keyboard reachable — by design: Clear is no Tab stop (the epic's design update 2026-10-16).
  - `[low]` `[reject]` `ProjectSearchStore` swallows write errors — mirrors `ProjectStackStore` (10.17) exactly; a failed write keeps the session value in the store's memory.
  - `[low]` `[reject]` the store test does not await writes or reload from disk — the round trip through `SettingsStore`'s value is what the store reads back; disk persistence belongs to zanshin_settings' own tests.
  - `[medium]` `[patch]` no controller tests for caching — added op-change re-ask, Recent dedup, Recent hidden under all(), bookmarks/email through prepare (see the verification-gap rows).
  - `[low]` `[reject]` `finds()` tells the symbol lookup by `limit == 1` — no behaviour bug; a named field is cosmetic.
  - `[low]` `[reject]` a go-to is added to Recent before the hidden change landed — Recent then hides a go-to absent from a shown `all()` layout (tested).
  - `[low]` `[patch]` `_onChanged` refreshes twice per keystroke — the duplicate refresh removed.
  - Edge Case Hunter:
  - `[medium]` `[patch]` (same root cause as the `_revset == old` row) a shown revset equal to the old log silently follows config edits — fixed with it.
  - `[maybe-false]` `[reject]` a `goToHidden` key missing from the `all()` layout gives no feedback — the change was found at this operation, so absence after the switch needs a concurrent abandon; if true it would be low (selection cleared, nothing revealed).
  - `[medium]` `[patch]` a divergent change beyond the view is keyed by change id, but `all()` keys it by commit id — `goToHidden(key, commitId:)` falls back to the commit-id key when the landed layout lacks the change id; view-model test added.
  - `[low]` `[reject]` a non-ZanshinFfiException in `prepare()`'s reads escapes — a closed worker or a StateError is a programming error that should fail loudly (codebase rule: only jj's refusals are caught).
  - `[low]` `[reject]` a non-ZanshinFfiException in counts/finds escapes the unawaited flush — same reasoning.
  - `[false]` `[reject]` fewer count entries than expressions — see the Blind Hunter row: one entry per expression by contract.
  - `[low]` `[patch]` an op change inside the pause asks twice for the same pair — `_sync(op)` drops answers for an old operation and keys the asked set by the current one.
  - `[low]` `[patch]` per-op caches grow over a long session — `_sync(op)`.
  - `[low]` `[patch]` candidates stale while the field stays focused — `prepare()` on model notify (same root cause as the Blind Hunter row).
  - `[low]` `[patch]` a Recent bookmark go-to jumps to the old target after the bookmark moved — the name is resolved against the prepared bookmarks first; test added.
  - `[maybe-false]` `[reject]` the error span underlines the wrong text while a newer request is in flight — the error and `request` are both replaced when that request lands; if true it would be a transient low (one frame of a stale underline).
  - `[low]` `[reject]` two authors sharing a name with different emails mis-tag "you" — rare; the design keys authors by name.
  - `[low]` `[reject]` two hidden commits of one divergent change collide in the index — rare; one of them is still reachable.
  - `[low]` `[reject]` a failing view is persisted and reopens next launch — the field then shows the filter with its ✕ and jj's error; one click returns to the default search.
  - `[medium]` `[patch]` a transient `logDefaults()` failure now fails every reload (the cached defaults were dropped with `_rereadDefaults`) — the cached defaults are kept and the failure logged; test added.
  - `[low]` `[patch]` the "once per (operation, expression)" claim breaks across an op change in the pause — `_sync(op)` (same root cause as above).
  - `[medium]` `[patch]` the hidden go-to AC fails for a divergent change — same root cause as the divergent row; fixed with it.
  - Verification Gap:
  - `[medium]` `[patch]` bookmark and `user.email` candidates never go through the controller in a test — `b: ma` widget test (local, `name@remote`, null target skipped, Recent keeps the name), the "you · mine()" row through prepare, a `GraphSearchIndex.build` unit test.
  - `[medium]` `[patch]` Recent hiding a go-to absent from a shown `all()` layout is untested — test added.
  - `[low]` `[patch]` Recent moving a repeat to the front is untested — test added.
  - `[medium]` `[patch]` per-operation caching never exercised across an operation change — test re-asks counts, finds and bookmarks at op2.
  - `[low]` `[patch]` `GraphPreferences` revset pass-through unobserved — test added (filed as defer; a three-line test closes it here).
  - `[low]` `[defer]` `RepoGraphSearchSource.files` and the store have no production caller or test — deferred with the production wiring (10.12).
  - `[low]` `[patch]` (other finding) a failed `userEmail()` is never retried — same root cause as the Blind Hunter email row.
  - Intent Alignment:
  - `[maybe-false]` `[reject]` the Auto Run Result is missing from the diff — it is written at finalize (below); the diff excludes the spec by design.
  - `[maybe-false]` `[reject]` the builder witness checks selection through `revsetCounts(expr & commit) == 1`, not `graphTopology` — equivalent proof that each string parses, resolves and selects the expected commit at the same operation; `mine()` is checked for parse and resolve only, as the fixture's commits carry no user.email of the test.
  - `[false]` `[reject]` I1 runs both sources concurrently instead of view-first-then-backend — the view's matches render at once and rank first; `findChanges` only adds what lies beyond (the story's item 4 lists both candidate sources for the same list).
  - `[maybe-false]` `[reject]` I2 still issues one unbounded `files()` count for a highlighted File row — that is the chosen mitigation (one per pause, ~55 ms packed / ~2 ms with the changed-path index, ~2.4 s on the loose-object fixture), and recent File filters follow the same rule.
  - `[false]` `[reject]` I3 takes no hold outside a shell (`ShellScope.maybeOf`) — outside a shell there is no calm scrolling to hold; the same pattern as 10.7 and 11.5.

## Design Notes

- Default search = `jj log` until 10.22 adds configurations and a settable default; the controller's `GraphShownView.defaultSearch` is the seam.
- Go-to symbol beyond the view: `jjRevsetSymbol(input)` sent as the whole `findChanges` expression reproduces the CLI's `-r <input>` resolution (bookmark, tag, change/commit prefix, ambiguity refusal).
- Counts mitigation (I2): `files()` costs ~2.4 s loose / ~55 ms packed at 10k (9.25 bench), commit-loading ones ~1.2 s / ~33 ms; counting File rows only as the keyboard row bounds the worst case to one `files()` per pause.

## Verification

**Commands:**
- `cargo test`-free story (no Rust changes): none.
- `dart test packages/zanshin_core/test/revset_text_test.dart test/worker/revset_search_test.dart` (in packages/zanshin_core) -- pass.
- `flutter test` in `app` (graph tests) -- pass; `dart analyze --fatal-infos` and `dart format --set-exit-if-changed` for app, zanshin_core, zanshin_settings -- clean.

**Verification notes (run 2026-11-01, gate rule of the story loop: no full gate):**
- `dart test test/revset_text_test.dart test/worker/revset_search_test.dart` (packages/zanshin_core, real cdylib) -- 11 passed.
- `flutter test test/features/graph test/widgetbook test/l10n` (app) -- 846 passed (after the review patches; 838 before).
- `flutter test` (packages/zanshin_settings) -- 38 passed.
- `dart analyze --fatal-infos .` -- no issues in app (incl. widgetbook), packages/zanshin_core, packages/zanshin_settings.
- `dart format --set-exit-if-changed -o none .` -- 0 changed in app and packages/zanshin_core; zanshin_settings clean.
- Not run: cargo checks (no Rust changed), `cargo make codegen` (no FFI or schema change), the parity oracle (no jj verb changed), the full gate and coverage (the loop runs them once at its end), the Marionette visual check (deferred).
- Implementer's note: a whole-app `flutter test` fails 5 tests in `worker_project_repos_test.dart` with "XDG_CONFIG_HOME is not pinned — run via cargo make"; they need the gate's environment, and none of their code changed here.

## Auto Run Result

Status: done (commit 5258103515ecd3fc95111366d69c0dfef05d8e14; review patches included in it).

**Summary.** The VIEW island opens with the graph search on fake ports (the graph is mounted only in the catalogue until 10.12): the field (default / typed filter / `$ all()`, ✕ back to the default, prefixes, Esc and blur restore, widths), the one menu (`jj log` Default, `all()`, Go to, Filter by, Edit Configurations… disabled until 10.22), suggestions (design scoring and limits, "N more", fallback note, footer naming what Enter runs), Recent per repository, op-pinned capped counts, go-to in view and beyond, revset errors with the span, stale and inactive states, ⌘F and `/`. The revset text comes from one builder in `zanshin_core`.

**Files.**
- `packages/zanshin_core/lib/src/revset_text.dart` -- the revset builder and `revsetSpanUtf16`; exported with `FileEntry` (`lib/zanshin_core.dart`); tests `test/revset_text_test.dart`, `test/worker/revset_search_test.dart`.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` (+ generated, test) -- `graphView`, `recentSearches`.
- `app/lib/src/features/graph/graph_search_model.dart` -- scopes, filters, shown view, Recent, JSON.
- `app/lib/src/features/graph/graph_search_index.dart` -- candidates, `suggest`/`compose`.
- `app/lib/src/features/graph/graph_search_store.dart` -- per-repository store.
- `app/lib/src/features/graph/graph_search_controller.dart` -- view state, Recent, lookups, counts.
- `app/lib/src/features/graph/graph_search_field.dart` -- the field, lists, footer, shortcuts.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphSearchSource`, `RepoGraphSearchSource`, `jjLogCommand`.
- `app/lib/src/features/graph/graph_view_model.dart` -- `setRevset(null)`, `goToHidden(key, commitId:)`, `logDefaults()` per request with cached fallback, `init(revset:)`.
- `app/lib/src/features/graph/graph_preferences.dart`, `graph_controls.dart` -- revset pass-through; the field first in the island.
- `app/lib/l10n/app_en.arb` (+ generated) -- strings.
- `app/widgetbook/folders/graph.dart`, `app/widgetbook/graph/fake_graph_search_source.dart` -- the catalogue mount.
- `app/test/features/graph/graph_search_field_test.dart`, `graph_search_index_test.dart`, `graph_view_model_test.dart`, `app/test/helpers/fake_graph_search_source.dart`, `app/test/widgetbook/catalogue_smoke_test.dart` -- tests.

**Deferred work items given to this story.**
- **I1 — fixed (5258103515ecd3fc95111366d69c0dfef05d8e14).** Go-to resolves the input in the shown topology first (change-id and commit-id prefixes, refs, cached subjects; a visible target is selected, revealed and pulsed with no request), then through `findChanges` over `all()` pinned to the layout's operation: the input as a revset symbol (the CLI's `-r` resolution, jj's ambiguous-prefix refusal shown verbatim as a row) and `description(substring-i:…)`. A hidden target switches to `all()` in one request and lands selected, revealed and pulsed (a divergent one by its commit id). The builder writes the filter revsets.
- **I2 — fixed (5258103515ecd3fc95111366d69c0dfef05d8e14).** Mitigation chosen from the item's own options, no decision needed from Ralph: `files()` rows (suggestions and recent File filters) are counted only while they are the keyboard row, so at most one `files()` count runs per typing pause (~55 ms packed, ~2 ms with the changed-path index, ~2.4 s on the loose-object 10k fixture); author and description counts always run. All counts are capped at 10,000 ("10,000+"), batched per 150 ms pause, and cached per (operation, expression).
- **I3 — fixed (5258103515ecd3fc95111366d69c0dfef05d8e14).** The search's menu and suggestion list take `ShellScope.maybeOf(context)?.openSurface()` while either shows, and release it on close and dispose (tested against a real `ShellController`). 11.8 stays open, as the item says.
- **I4 — fixed (5258103515ecd3fc95111366d69c0dfef05d8e14).** `revsetSpanUtf16` in `zanshin_core` (exported, so 10.22 can use it too) converts jj's UTF-8 byte spans to UTF-16. The error footer uses it, tested with `author(exact:"Jörg König")`-style input and 4-byte runes.

**Review.** One pass, 51 findings: 0 high, 10 medium, 30 low, 6 false, 5 maybe-false. 25 rows were patched; the patched rows by verdict are 10 medium and 15 low:
- divergent hidden go-to by commit id;
- the shown revset reset only on a real `revsets.log` change;
- cached `logDefaults` on a transient failure;
- per-operation cache sync;
- the `user.email` retry;
- `prepare` on operation change;
- one index per refresh, no double refresh;
- a Recent bookmark go-to follows the bookmark;
- VoiceOver hint;
- locale number format;
- seven new tests.

One finding was deferred (production wiring). The rejected rows and their reasons are in the triage log.

**Follow-up review: recommended.** Ten medium rows were patched. The risk not yet verified: the reduced VoiceOver semantics (the keyboard row as the field's hint) has not been heard on a device, and the divergent go-to fallback is tested only on fake layouts.

**Residual risks.**
- No visual check against the DS search cards (deferred).
- No true combobox/listbox semantics (deferred).
- No production caller until 10.12 (deferred).
- The default search is always `jj log` until 10.22 adds configurations and a settable default.

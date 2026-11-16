---
title: 'Story 10.47 — Tags in the search and actions on search hits'
type: 'feature'
created: '2026-11-16'
status: 'done'
baseline_revision: '5c419d0b4ba5d90b817e99e8632ba079b69d40f1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The top graph search finds changes and bookmarks but no tags, and a bookmark hit can only be selected: "new change on this ref" or "track this remote ref" means leaving the search for the Bookmarks view. Untracked remote bookmarks are not even listed (the search reads `jj bookmark list` without `--all-remotes`).

**Approach:** Build section 8 of the approved `design/Refs Study.html`: a Tag scope (`t:`) and tag hits under Any (2 + "N more in Tag"); on the active row only (hovered, else the keyboard row) a bookmark or tag hit shows "New change here" (`jj new <name>`, also ⌘↩) and, on an untracked remote hit, "Track" (`jj bookmark|tag track <name>@<remote>`); the footer reads "↩ Select · ⌘↩ New change here". DS: the search rows with their actions and the footer, not published. DS synced through #26 plus the Refs Study.

## Boundaries & Constraints

**Always:**
- **Scope** (`graph_search_model.dart`): `GraphSearchScope.tag` after `bookmark`, prefix `t:` (long form `tag:`), `isGoTo` true. Every `switch` over the enum and every ARB `select` over the scope name gains `tag` (Tag / tags / Tags / "Tag name"); Any's placeholder names tags. The menu lists a Tag row after Bookmark under "Go to" (`ZI.tag`, detail `graphSearchTagDetail` "name", `ZsKbd('t:')`).
- **Index** (`graph_search_index.dart`): a `GraphSearchRef` (bare `name`, target `key`, `remote` or null, `tracked`; `display` = `name` or `name@remote`) replaces the `({name, key})` record; `GraphSearchIndex.bookmarks` and a new `tags` hold them. `build` takes `bookmarks` and `tags: List<Tag>`, skips rows without a target and rows of the remote `git`, de-duplicates by `display`. `graphSearchAnyLimits` gains `tag: 2` after bookmark; tag rows score and sort exactly as bookmark rows and are `GraphBookmarkRow`s with `tag: true`.
- **`GraphBookmarkRow`** gains `ref` (`GraphSearchRef?`, null for a Recent entry whose ref is gone) and `tag`. It answers `newAction` (with `ref`: `GraphNew(revsets: [symbol], revsetTarget: change?.key ?? key)`, `symbol` = `revsetSymbol(name)` or `remoteBookmarkSymbol(name, remote)`) and `trackAction` (an untracked remote ref: `GraphBookmarkTrack(name, remote)` / `GraphTagTrack(name, remote)`; else null).
- **Reads** (`GraphSearchSource`, `graph_ports.dart`): `bookmarks()` becomes `jj bookmark list --all-remotes` (`RepoGraphSearchSource` passes `allRemotes: true`); new `tags()` = `handle.tags()`. `GraphSearchController.prepare` reads both per operation (a failed read = empty, as today); `index` passes both.
- **Recent:** `GraphRecentGoTo` gains `tag` (JSON `"tag": true` only when set); `goTo(…, tag:)`; `recentFor`: Tag scope lists tag go-tos, Bookmark scope bookmark go-tos only, Any all. A Recent ref row resolves through `index.tags` / `index.bookmarks` by `display`.
- **Rows** (`graph_search_field.dart`): a tag hit has `ZI.tag`; a ref hit whose ref is an untracked remote shows the quiet tag "untracked" (`graphSearchUntracked`, the `_Tag` pill) after its name. The buttons sit in the meta column before the change id, on exactly one row: the hovered row while the pointer is over a row, else the keyboard row (a keyboard move ends the hover's claim). Track is a `ZsButton` "Track" (`bookmarksTrack`), New an sm `ZsIconButton` `ZI.plus` "New change here" (`refsNewHere`), each in a `ZsTooltip` with its command (`action.command`); identifiers `graph-search-track-<i>` / `graph-search-new-<i>`. While `model.actionsEnabled` is false both are disabled with `bookmarksBusy`.
- **Run:** a button or ⌘↩ (meta+Enter, key down) on the keyboard row runs the action through `model.run` (unawaited) and then closes, reverts and unfocuses like a pick; ⌘↩ on any other row, or while actions are disabled, does nothing and is handled. Plain ↩ is unchanged.
- **Footer:** on a ref row with `newAction`, after today's verb + ↵ a second key group "New change here ⌘↵" (`refsNewHere`, `ZsKbd('⌘↵')`).
- Strings in `app_en.arb` + `flutter gen-l10n` (output committed); jj's words and commands stay literals marked `// l10n-ignore`. Zs controls and DS tokens only; the architecture test stays green (`graph` imports nothing from `bookmarks`).
- **Catalogue:** the widgetbook `FakeGraphSearchSource` gains `tags()` (from `layout.tagsOf`) and lists the layout's remote refs as remote rows (untracked unless `synced`), so `b:` and `t:` show the actions.
- **DS** via `design-artifacts` (C + E, then F's sync line), no publish: `SearchPopover`'s `footer` gains `alt: { verb, key }` (a second `.zs-gs-ft-k`); `SearchRow`'s comment names actions in `meta` on the active row only; `.d.ts`, `.prompt.md` and the hand-edited `_ds_bundle.js` block follow; `search-suggestions.card.html` gains a third list "Bookmark · typing `rel`" (an untracked remote row with Track + New on the active row, the footer with `alt`); `readme.md` Sync line and dated entry; one line `- 2026-11-16 (Story 10.47) — …` at the end of `design/DESIGN-SYSTEM-SYNC.md`. Do not touch the study files.

**Never:**
- Other actions in the search (delete, rename, untrack); Rust, FFI or schema changes (verbs and reads exist).
- Moving the keyboard row on hover (the DS rule of `ZsFieldListRow`).
- Publishing the DS; the Marionette check against `design/Refs Study.html` section 8 (both for the console session).
- The full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Tag scope | `t:v1.`, tags `v1.4.2`, `v1.5.0-rc1` | Tag scope, both rows with `ZI.tag`, match underlined | no match → Any fallback, as today |
| Any | `v1`, 3 matching tags | "Tags" group: 2 rows + "1 more in Tag"; the more row narrows to Tag | — |
| Pick | ↩ on a tag hit | selects its change; Recent keeps it with `tag` | target beyond the view → `all()` go-to, as bookmarks |
| Active only | 3 bookmark hits, keyboard row 0, pointer over row 2 | buttons on row 2 only; pointer leaves → row 0 | — |
| New | ⌘↩ on `feature/auth-flow` | runs `GraphNew(revsets: ['feature/auth-flow'], revsetTarget: key)`, shown `jj new feature/auth-flow`; list closes | busy → nothing runs; jj refusal → the runner's toast |
| Remote New | `main@origin` row | `jj new main@origin` | — |
| Track | `b:rel`, untracked `release/1.4.x@origin` | "untracked" pill, Track + New; Track runs `jj bookmark track release/1.4.x@origin` | tracked or local row → no Track |
| Tag Track | untracked `v1.5.0@origin` | `jj tag track v1.5.0@origin` | — |
| `@git` | a `main@git` row in the read | not listed | — |
| Gone Recent | Recent `old-name` no longer listed | row goes to the recorded change; no buttons | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_search_model.dart:15-68` -- `GraphSearchScope` (`isGoTo` `:35`, `prefix` `:41`), `_prefix` regex `:52`, `parseGraphSearchPrefix` `:55`; `GraphRecent.decode` `:302`, `GraphRecentGoTo` `:323-342`.
- `app/lib/src/features/graph/graph_search_index.dart` -- `GraphSearchIndex` `:68-167` (`build` `:80`, bookmark records `:131-148`), `GraphBookmarkRow` `:239-254`, `graphSearchAnyLimits` `:331`, bookmark scoring `:415-430` (copy for tags), `_compose` `:514`.
- `app/lib/src/features/graph/graph_search_controller.dart` -- `goTo` `:204` (`tag`), `recentFor` `:255-271`, `prepare` `:282-303` (read tags), `index` `:319-329`.
- `app/lib/src/features/graph/graph_search_field.dart` -- `_MenuKind` / `_MenuRow.scopes` `:56-71`, `_recentRow` `:357-373`, `_activeChanged` `:385` (clear hover claim), `_pickMenu` `:477`, `_pick` `:520-537` (pass `tag`), `_goTo` `:539`, `_onKey` Enter `:597-608` (⌘↩), menu rows `:962-987`, `_suggestionRow` `:1179-1356` (bookmark case `:1246-1257`, `ZsFieldListRow` `:1346`), `_footer` `:1358-1399`, `_activeLabel` `:1479`, `_scopeIcon` `:1509`, `_Tag` `:1618`.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphNew` `:224-251`, `GraphBookmarkTrack` `:598`, `GraphTagTrack` `:702`, `remoteBookmarkSymbol`/`revsetSymbol` `:744-748`, `GraphSearchSource` `:1347-1370`, `RepoGraphSearchSource.bookmarks` `:1395`.
- `app/lib/src/features/graph/graph_view_model.dart:596` -- `actionsEnabled`; `run` `:729`.
- Reference patterns: `app/lib/src/features/bookmarks/bookmark_list_model.dart:199-209,449-458` (track/new actions of a row; `_gitRemote` `:20`, filter `:499`), `bookmark_list_view.dart:797-826` (buttons with tooltip `cmd`, disabled reason), `:557` (`_reason`).
- `packages/zanshin_core/lib/src/ffi/tags.dart:95-130` -- `Tag`, `LocalTag`, `RemoteTag(remoteName, tracked)`; `handle.tags()` `packages/zanshin_core/lib/src/worker/handle.dart:353`.
- `packages/zanshin_ui/lib/src/controls/zs_field_list.dart:130-265` -- `ZsFieldListRow` (hover is private; wrap rows in a `MouseRegion` in the field).
- `app/lib/l10n/app_en.arb:476-548` -- scope selects, `graphSearchBookmarkDetail`, footer strings; `refsNewHere` `:1492`, `bookmarksTrack` `:1460`, `bookmarksBusy` `:1464`.
- Tests: `app/test/features/graph/graph_search_field_test.dart` (rig `:57-126`: add `RecordingGraphActions` from `test/helpers/fake_bookmark_list.dart:163` via `model.init(…, actions:)`; bookmark tests `:542-578`), `graph_search_index_test.dart`, `graph_search_controller_test.dart`, `test/helpers/fake_graph_search_source.dart` (add `tagList`, `tags()`), `test/features/graph/repo_graph_source_test.dart:150`.
- Catalogue: `app/widgetbook/graph/fake_graph_search_source.dart:94-109`; `GraphLayout.tagsOf` `app/lib/src/features/graph/graph_layout.dart:285`, `GraphRef` `:63-75`.
- DS: `design_system/components/search/SearchPopover.jsx` (`footer` `:17-22`, `SearchRow` comment `:34-37`), `SearchPopover.d.ts:10`, `SearchPopover.prompt.md`, `search-suggestions.card.html`, `_ds_bundle.js` (the `components/search/SearchPopover.jsx` block), `search.css:72-75` (footer classes), `readme.md:22` and the dated list `:68-69`; `design/DESIGN-SYSTEM-SYNC.md` (append). Reference only: `design/refs-study.jsx:437-477`, `design/refs-study.css:123`.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_search_model.dart` -- Tag scope, prefix, Recent `tag` -- unit tests: `t:` / `tag:` parse, Recent JSON round trip with and without `tag`.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphSearchSource.tags()`, `--all-remotes` bookmarks.
- `app/lib/src/features/graph/graph_search_index.dart` -- `GraphSearchRef`, tags, `@git` skip, Any limit, row actions -- index tests: tag scope rows, Any "N more in Tag", `@git` left out, `newAction`/`trackAction` commands (local, remote, tag, tracked → none, gone ref → none).
- `app/lib/src/features/graph/graph_search_controller.dart` -- read tags, `goTo(tag:)`, `recentFor` -- controller tests: tags read once per operation; Recent per scope with a tag go-to.
- `app/lib/src/features/graph/graph_search_field.dart` -- menu row, icons, untracked pill, active-row buttons, ⌘↩, footer -- widget tests per matrix rows 1–7 and 9 (buttons only on the active row; hover claim; ⌘↩ runs `jj new feature/auth-flow` and closes; Track on `release/1.4.x@origin`; busy disables; the footer shows both keys; the Tag menu row picks the scope).
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n`; test and widgetbook fakes (`tags()`).
- DS: component, d.ts, prompt, bundle block, card, readme, DESIGN-SYSTEM-SYNC line.

**Acceptance Criteria:**
- Given tags `v1.4.2` and `v1.5.0-rc1`, when `t:v1.` is typed, then the Tag scope lists both; when `v1` is typed in Any with three matching tags, then the Tags group shows two and "1 more in Tag".
- Given `b:feat` with `feature/auth-flow` the keyboard row, then only that row shows New change here, and ⌘↩ runs `jj new feature/auth-flow` and closes the search.
- Given `b:rel` with `release/1.4.x@origin` untracked, when it is the active row, then it shows Track and New; Track runs `jj bookmark track release/1.4.x@origin`.
- Given an action is running, when the active ref row shows its buttons, then they are disabled with "Another action is running" and ⌘↩ runs nothing.
- Given the architecture test, when it runs, then `graph` still imports nothing from `bookmarks`.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 25 findings — high 0, medium 4, low 21, false 0, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind) With `--all-remotes` every pushed ref shows twice (`main` and a synced `main@origin` on the same change), filling Any's 2 rows — confirmed: the default list leaves out tracked remote rows that match the local ref (`handle.dart:299-302`); patched: `GraphSearchIndex.build` skips a remote row whose `synced` is true (bookmarks and tags), with an index test.
  - `[low]` `[reject]` (blind) "New change here" on a bookmark lands on a same-named tag (jj-lib resolves tags first) and `revsetTarget` points at the bookmark — exactly what the shown `jj new <name>` does in the CLI; same-named refs are rare; the 10.44 closing run rejected the same row; an unambiguous revset would no longer be `jj new <name>`.
  - `[low]` `[patch]` (blind) The hovered row goes stale when rows unmount under a still pointer (`MouseRegion.onExit` does not fire on unmount), so the keyboard row loses its buttons — patched: `_refresh` resets `_hoverRow` on a reset, off the suggestions, or past the rows; widget test added.
  - `[low]` `[reject]` (blind) ⌘↩ is handled (does nothing) outside a ref row, where it used to act like ↩ — the spec's deliberate rule: ⌘↩ on another row must not silently run that row's ↩ action (a filter or go-to); ⌘↩ was never a documented key there.
  - `[low]` `[patch]` (blind) The footer shows "New change here ⌘↵" while an action runs and the key does nothing — patched: the alt key group shows only while `actionsEnabled`; asserted in the busy test.
  - `[low]` `[reject]` (blind) Track has no keyboard path and the row's VoiceOver label does not say tag/untracked — the story defines only ⌘↩ (for New); Track is reachable on the active row's button (a semantics node) and in the Bookmarks/Tags views; a new shortcut is a design decision.
  - `[low]` `[patch]` (blind) Recent rows whose ref still exists gain actions, untested — same root as the verification row on Recent tags; patched there.
  - `[medium]` `[patch]` (blind) `RepoGraphSearchSource`'s `--all-remotes` read is not tested on a real repo — same root as the verification row; patched there.
  - `[low]` `[patch]` (blind) The Story 10.47 DS log entries omit the `_ds_manifest.json` edit (card viewport 700x900, subtitle) — patched: both entries name it.
  - `[low]` `[reject]` (blind) The catalogue fake treats `synced` as `tracked` — catalogue-only; `GraphRef` carries no tracking flag, so the fake cannot know; the app reads jj's real flag.
  - `[low]` `[reject]` (blind) The DS card shows no tag row or hover state — the card is a demo of the row and footer; the prompt documents the rule.
  - `[low]` `[reject]` (blind) The `@git` filter runs on tags too, though `handle.tags()` already drops it — harmless, keeps bookmarks and tags on one rule.
  - `[low]` `[reject]` (blind) Bookmark-named helpers and strings (`remoteBookmarkSymbol`, `bookmarksTrack`) serve tags — renaming touches existing callers for a name only; 10.44/10.45 use the same helpers for tags.
  - `[low]` `[patch]` (edge) Stale hover after unmount — same root as the blind row; patched there.
  - `[low]` `[reject]` (edge) ⌘↩ swallowed outside a ref row — same as the blind row; the spec's rule.
  - `[low]` `[reject]` (edge) A bookmark row whose name is also a tag resolves to the tag — same as the blind row.
  - `[low]` `[patch]` (edge) Footer advertises ⌘↵ while disabled — same root as the blind row; patched there.
  - `[low]` `[reject]` (edge) A local ref named `foo@origin` and the remote `foo` at origin collide in the display dedupe and the Recent lookup — such local names are rare (only quoted symbols reach them in jj); fixing needs a separate key and a Recent format change.
  - `[medium]` `[patch]` (verification) `RepoGraphSearchSource.bookmarks()` `allRemotes: true` is checked by no test — patched: a real-worker test builds `origin/<name>` and asserts the untracked remote row.
  - `[low]` `[patch]` (verification) A Recent tag go-to is never reopened — patched: a widget test reopens it (tag icon, New on the keyboard row, ↩ to the tag's current change, `tag: true` kept).
  - `[low]` `[patch]` (verification) No test taps a disabled ref button — patched: the busy test taps `graph-search-new-0` and asserts nothing happens.
  - `[low]` `[reject]` (intent) The footer reads "Select ↵ · New change here ⌘↵" (verb then key, no "·"), not the story's literal "↩ Select · ⌘↩ New change here" — follows the existing footer, the DS `SearchPopover` and the Refs Study (`Select ↩`, `New change here ⌘↩`).
  - `[low]` `[reject]` (intent) With the pointer on one row and the keyboard on another, the buttons follow the pointer while ⌘↩ and the footer follow the keyboard row — the DS rule "↩ and the footer stay with the keyboard row"; one visible button row.
  - `[medium]` `[patch]` (intent) The bookmark read widened to every remote row, beyond "add tags" — needed for Track; its real harm is the duplicate synced rows, patched with the first row.
  - `[low]` `[reject]` (intent) Track/New on remote tags are tested only as command strings — the verbs and symbols are tested end to end in earlier stories (9.59, 10.44 closing).

### 2026-11-16 — Review pass (follow-up)
- verdicts: 32 findings — high 0, medium 2, low 28, false 2, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification) An enabled New button is never clicked, least of all on a hovered row that is not the keyboard row; a miswired `onPressed` or a row mix-up would pass — patched: a widget test hovers row 2 of `b:feat`, taps `graph-search-new-2` and asserts the hovered row's `jj new` and `revsetTarget` ran and the list closed.
  - `[low]` `[patch]` (verification) `revsetTarget: change?.key ?? key` always equals `key` (`GraphSearchIndex.change` matches `c.key == key`), so the comment's divergent-change claim is false — patched: `revsetTarget: key` with a `shortcut:` comment naming the divergent-target limit and the Bookmarks view's layout lookup as the upgrade.
  - `[low]` `[reject]` (intent) The index drops synced remote rows, beyond the literal skip list — the previous pass's deliberate patch, mirroring plain `jj bookmark list`; a synced `main@origin` is the same commit as `main`, which stays listed.
  - `[low]` `[reject]` (intent) A Recent `name@remote` whose row turned synced no longer resolves — same root as the blind Recent row; rejected there.
  - `[low]` `[reject]` (intent) The catalogue never shows a tracked remote row — same root as the carried catalogue row: `GraphRef` has no tracking flag.
  - `[low]` `[reject]` (intent) The footer hides ⌘↵ while busy, unlike the literal "on a ref row with `newAction`" — carried: the previous pass's patch; the key does nothing while busy.
  - `[low]` `[reject]` (intent) ⌘↩ with the list closed no longer applies the text — carried: the ⌘↩-outside-a-ref-row row; the spec's rule.
  - `[low]` `[reject]` (intent) The jj commands are asserted as strings, never run through the real runner — carried: the remote-tag-actions row; verbs tested end to end in 9.59 / 10.44.
  - `[low]` `[reject]` (intent) `tags()` against a real repository only checks an empty list — `tags()` is `handle.tags()`, tested on real repositories in its own stories; the search adds no logic there.
  - `[low]` `[reject]` (intent) The visual surface (Refs Study section 8) is not checked — the intent's Never list moves the Marionette check to the console session.
  - `[low]` `[reject]` (intent) Tag "no match → Any fallback", "beyond the view → `all()`" and "refusal → toast" have no tag-specific test — the code paths are shared with bookmarks and the runner, which are tested.
  - `[low]` `[reject]` (blind) A bookmark row's New lands on a same-named tag — carried: the CLI's own resolution.
  - `[low]` `[reject]` (blind) New on an out-of-view hit has no `all()` rule and no test — the new change becomes @, which the view shows; the Bookmarks view's New on a dimmed row behaves the same; rare.
  - `[low]` `[reject]` (blind) Track has no keyboard or VoiceOver path — carried.
  - `[low]` `[reject]` (blind) ⌘↩ swallows a key that used to submit (popup closed, menu open) — carried: the spec's rule.
  - `[low]` `[reject]` (blind) ⌘↩ while busy gives no feedback — the visible buttons carry the disabled reason; the footer's key hides as the previous pass decided; adding a disabled footer state is new design.
  - `[low]` `[reject]` (blind) After Track, the Recent `name@remote` entry loses its ref (the synced row is dropped): no buttons, goes to the recorded change — confirmed (`graph_search_field.dart` `_recentRow` looks up by `display`); the recorded change id is the ref's change and the local ref is listed beside it, so only the buttons are lost; the fix needs a fallback lookup or synced rows kept for Recent (new branches/fields).
  - `[low]` `[reject]` (blind) The widgetbook fake conflates tracked with synced — carried.
  - `[false]` `[reject]` (blind) `t:` / `tag:` changes how existing input reads — that is the intent's Tag scope prefix, as `b:` before it.
  - `[medium]` `[patch]` (blind) No test clicks Track or New on a hovered non-keyboard row — same root as the verification row; patched there.
  - `[low]` `[reject]` (blind) No test of `prepare` when `tags()` fails — `tags()` goes through the same `_read` wrapper as `bookmarks()`, whose failure path predates this story.
  - `[low]` `[reject]` (blind) Recent JSON stores tag names under `"bookmark"` — the intent fixes the shape (`"tag": true` beside the existing field); a rename needs a stored-data migration.
  - `[false]` `[reject]` (blind) The port doc comments of `bookmarks()` and `tags()` disagree — each describes its own read correctly: the bookmark read returns every row, `handle.tags()` already drops `git`.
  - `[low]` `[reject]` (blind) Tag rows use `bookmarksTrack` / `bookmarksBusy` — carried: the bookmark-named helpers and strings row.
  - `[low]` `[reject]` (blind) The DS card lacks a tag row, a tracked remote row and the busy state — carried: the card is a demo; the prompt documents the rules.
  - `[low]` `[reject]` (edge) A bookmark named like a tag resolves to the tag — carried.
  - `[low]` `[reject]` (edge) A conflicted ref offers New and jj refuses — the matrix's "jj refusal → the runner's toast"; the Bookmarks view does the same.
  - `[low]` `[reject]` (edge) ⌘↩ swallowed in the menu or with the popup closed — carried.
  - `[low]` `[patch]` (edge) `onEnter` re-claims the hover when a keyboard move scrolls a row under a still pointer, so the buttons leave the keyboard row — confirmed (`_activeChanged` clears the claim, the scroll then fires `onEnter`); patched: only `onHover` (pointer motion) claims the row; the hover tests still pass.
  - `[low]` `[reject]` (edge) A local `a@b` and remote `a` at `b` collide in the dedupe — carried.
  - `[low]` `[reject]` (edge) A Recent `name@origin` that turned synced misses — same root as the blind Recent row; rejected there.
  - `[low]` `[reject]` (edge) The real-repo test's `git` inherits the global git config — the gate pins `GIT_CONFIG_GLOBAL` for `flutter test` (Makefile.toml), the commit passes `--no-gpg-sign`, and the sibling tests use the same pattern.

## Design Notes

- **`--all-remotes` in the search:** Track needs untracked remote hits, which plain `jj bookmark list` leaves out; `@git` rows are dropped as the Bookmarks view drops them. Tags come from `handle.tags()`, which already lists all remotes minus `git`.
- **One active row:** `ZsFieldListRow`'s rule is that hover never moves the keyboard row, so the field tracks the hovered row itself; the buttons follow whichever moved last (pointer or keys). ⌘↩ and the footer stay with the keyboard row.
- **After an action** the search closes like a pick; the action runner's pending card, toast and selection follow do the rest (New selects the new change).
- **Symbols:** `revsetSymbol` / `remoteBookmarkSymbol` quote as the CLI needs; a tag resolves through the same symbol (jj-lib resolves tags before bookmarks — a same-named tag shadows a bookmark, exactly as `jj new <name>` does).
- **Marionette and DS publish** against `design/Refs Study.html` section 8 are left to the console session.

## Verification

**Commands:**
- `flutter gen-l10n` (in `app/`) -- output committed.
- `flutter test test/features/graph test/features/bookmarks test/features/home test/architecture test/l10n test/widgetbook` in `app/` -- expected: pass.
- `dart analyze` and `dart format --set-exit-if-changed .` in `app/` -- expected: clean.
- `cargo test -p zanshin-parity --test oracle` only if a command fixture changes.
- `node --check _bmad-output/implementation-artifacts/design_system/_ds_bundle.js` after the bundle edit -- expected: no syntax error.

**Manual checks:**
- Marionette against `design/Refs Study.html` section 8 and the DS publish -- by the console session, not this run.

**Verification notes (2026-11-16, targeted checks per the story loop's gate rule):**
- `flutter gen-l10n` in `app/` — output committed.
- `flutter test test/features/graph test/features/bookmarks test/features/home test/architecture test/l10n test/widgetbook` in `app/` — 1753 pass before the review patches, 1756 after.
- `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed .` — 0 changed (`app/`).
- `flutter test test/design` in `packages/zanshin_ui` (DS parity over `design_system/`) — 76 pass.
- `node --check design_system/_ds_bundle.js` — no syntax error; the SearchPopover source hash in the bundle header matches `shasum -a 256` of the `.jsx` (first 12 hex).
- Not run: the parity oracle (no command fixture changed); `cargo make test` / `test-full` / `coverage` (gate rule). No Rust, FFI or schema change.
- Matrix audit: every row has a passing test (`graph_search_index_test`, `graph_search_field_test` Story 10.47 group, `graph_search_controller_test`, `repo_graph_source_test`).

**Verification notes (2026-11-16, follow-up review pass, targeted checks per the gate rule):**
- `flutter test test/features/graph test/features/bookmarks test/features/home test/architecture test/l10n test/widgetbook` in `app/` — 1757 pass (1756 + the new hovered-row New test).
- `dart analyze --fatal-infos --fatal-warnings` in `app/` — no issues; `dart format --set-exit-if-changed .` — 0 changed after formatting the new test.
- Not run: `cargo make test` / `test-full` / `coverage` (gate rule), the parity oracle and Rust checks (no Rust, FFI, schema or command change), `flutter gen-l10n` (no string change), the DS checks (no DS change).

## Auto Run Result

Status: done

**Summary.** The top graph search gains a Tag scope (`t:` / `tag:`, the tag glyph, a Tag row after Bookmark in the menu) and a Tags group in Any (2 rows + "N more in Tag"); a tag hit selects its change and Recent keeps it as a tag. Bookmarks are read with `--all-remotes` and tags with `handle.tags()`; the index drops `@git`, synced remote rows (as plain `jj bookmark list` does) and repeats, so untracked remote refs now appear, marked "untracked". On exactly one row — the hovered one, else the keyboard row — a ref hit shows Track (untracked remote refs: `jj bookmark|tag track <name>@<remote>`) and New change here (`jj new <name>` / `jj new <name>@<remote>` through `GraphNew(revsets:, revsetTarget:)`), each tooltip its command, disabled with "Another action is running" while one runs; ⌘↩ runs the keyboard row's New change here; an action closes the search like a pick. The footer adds "New change here ⌘↵" on a ref row while actions can run. DS: `SearchPopover` `footer.alt`, the `SearchRow` rule, the *Search suggestions* card's third list; not published.

**Files changed.**
- `app/lib/src/features/graph/graph_search_model.dart` — Tag scope and prefix; `GraphRecentGoTo.tag`.
- `app/lib/src/features/graph/graph_ports.dart` — `GraphSearchSource.tags()`; bookmarks with `allRemotes: true`.
- `app/lib/src/features/graph/graph_search_index.dart` — `GraphSearchRef`, tags, the row filters, Any limit, `newAction` / `trackAction`.
- `app/lib/src/features/graph/graph_search_controller.dart` — tags read per operation, `goTo(tag:)`, Recent per scope.
- `app/lib/src/features/graph/graph_search_field.dart` — Tag menu row, icons, "untracked" pill, active-row buttons with the hover claim, ⌘↩, the footer's second key.
- `app/lib/l10n/*` — scope selects with `tag`, `graphSearchTagDetail`, `graphSearchUntracked`, the Any placeholder.
- Tests: `graph_search_index_test`, `graph_search_controller_test`, `graph_search_field_test`, `repo_graph_source_test`; fakes `test/helpers/fake_graph_search_source.dart`, `widgetbook/graph/fake_graph_search_source.dart`.
- DS: `components/search/SearchPopover.{jsx,d.ts,prompt.md}`, `search-suggestions.card.html`, `_ds_bundle.js` (block + hash), `_ds_manifest.json` (card viewport and subtitle), `readme.md`; `design/DESIGN-SYSTEM-SYNC.md` line.

**Review.** 25 findings (high 0, medium 4, low 21). Patched (7 entries: 2 medium, 5 low): synced remote rows showed twice under `--all-remotes` (medium, with the intent row on the widened read); a real-worker test of the `--all-remotes` search read (medium); stale hover after rows unmount; the footer's ⌘↵ while busy; a Recent tag go-to test; a tap on a disabled button; the DS logs name the manifest edit. Deferred: none. Rejected: a same-named tag shadows a bookmark for `jj new` (low ×2, the CLI's own behavior, rare); ⌘↩ handled as a no-op outside ref rows (low ×2, the spec's rule); no keyboard path for Track and a thin VoiceOver label (low, the story defines only ⌘↩; the button is reachable); catalogue fake treats synced as tracked (low, catalogue-only); DS card without tag row/hover (low, demo); double `@git` filter (low, harmless); bookmark-named helpers for tags (low, rename only); `foo@origin` local vs remote collision (low, rare); footer wording order (low, follows the existing footer, DS and study); buttons follow the pointer while ⌘↩ follows the keyboard row (low, the DS rule); remote tag actions tested as strings (low, verbs tested in 9.59 / 10.44).

**Follow-up review:** recommended — two medium entries were patched (patched counts: high 0, medium 2, low 5). The unverified risk: the synced-row filter and the `--all-remotes` read change what the Bookmark scope lists in a real repository with tracked and untracked remotes; only fakes and one real-worker untracked row check it, not a repository where a tracked remote is ahead or behind.

**Follow-up review pass (2026-11-16).** 32 findings (high 0, medium 2, low 28, false 2). Patched (3 entries: 1 medium, 2 low): a widget test clicks New on a hovered row that is not the keyboard row (medium; the verification and blind rows); only pointer motion (`onHover`) claims the hovered row, so a keyboard move that scrolls a row under a still pointer keeps the buttons on the keyboard row (`graph_search_field.dart`); `revsetTarget: key` with a `shortcut:` comment in place of the no-op `change?.key ?? key` and its false divergent-change claim (`graph_search_index.dart`). Deferred: none. Rejected: the Recent `name@remote` entry that turns synced after Track loses its buttons (low ×3, the fix needs a fallback lookup or synced rows kept for Recent; the entry still goes to the ref's change); New on an out-of-view hit (low, the new @ is shown; as in the Bookmarks view); ⌘↩ busy feedback (low, the buttons carry the reason); conflicted ref offers New (low, the matrix's refusal toast); Recent JSON key name (low, intent fixes the shape); `tags()` failure test (low, shared wrapper); the real-repo test's git config (low, the gate pins it); the synced filter and the catalogue's tracked rows (low, the previous pass's decision / no tracking flag); real-repo tags, tag-specific matrix tests, visual check (low, shared paths / Never list); `t:` changes input meaning and the port doc comments (false); carried rejections of the first pass (same-named tag ×2, Track keyboard path, ⌘↩ outside a ref row ×4, catalogue fake, bookmark-named strings, DS card, `a@b` collision, footer busy, commands as strings). Follow-up review: not recommended — no high was patched (patched counts: high 0, medium 1, low 2).

**Residual risks.** No visual check against the Refs Study section 8 or the DS card (Marionette and the DS publish belong to the console session). ⌘↩ is tested with simulated key events only. The catalogue now hides synced remote refs and shows its unsynced ones as untracked. The full gate (incl. coverage) runs at the end of the story loop. A Recent `name@remote` entry whose remote row became synced shows no buttons (rejected low). A ref on a divergent change runs New with a change-id `revsetTarget` the layout does not key (the `shortcut:` comment).

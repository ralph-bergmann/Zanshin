---
title: 'Story 10.44 — The Bookmarks and Tags views: rail button, filter, tree, row buttons, delete dialog'
type: 'feature'
created: '2026-11-16'
status: 'done'
baseline_revision: '2718e379cb0c0dc4b906924e902a3471843259a0'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred:
  - summary: >-
      "New change here" on a bookmark or tag runs `jj new <target change id>`, not the CLI's `jj new <name>`,
      because the backend's `new_change` takes change ids only.
    evidence: |-
      `Repo::new_change(parents: &[ChangeId], …)` (crates/zanshin-jj/src/repo.rs:1596) and `RepoHandle.newChange`
      resolve change ids; the row button runs `GraphNew(parents: [row.bookmark.target])` and shows that command.
      It differs from the CLI for a divergent target (Zanshin refuses, the CLI resolves the ref) and a conflicted
      ref (Zanshin uses the first side, the CLI refuses), and the operation records the change id, not the name.
    location: >-
      app/lib/src/features/bookmarks/bookmark_list_model.dart (BookmarkListModel.newHere)
    severity: medium
    resolved: >-
      2026-11-16 — fixed (spec-10-44-closing-new-change-by-ref-name, commit 9ca6885a): new Repo::new_change_on(revsets)
      resolves parents like `jj new <REVSETS>`; the row runs and shows `jj new <name>` / `jj new <name>@<remote>`.
  - summary: >-
      No test checks that the Tags rail count updates when the tag list loads after the bookmark list.
    evidence: |-
      `HomePage` rebuilds on `Listenable.merge([scope?.bookmarks, scope?.tags])`; dropping `scope?.tags` fails no
      test, because `home_page_test.dart` checks only the rail ids. The Bookmarks count has the same gap, and the
      home test rig cannot order the two reads.
    location: >-
      app/lib/src/features/home/home_page.dart (rail ListenableBuilder); app/test/features/home/home_page_test.dart
    severity: low
    resolved: >-
      2026-11-16 — fixed (spec-10-44-closing-new-change-by-ref-name, commit 9ca6885a): the home test holds back each
      list read and asserts both rail counts; both listenables mutation-checked.
---

<intent-contract>

## Intent

**Problem:** Tags have no place in the app, and the Bookmarks rail view is a flat list whose Track/Untrack button appears below a row and makes the list jump; Delete of a bookmark never asks what should happen on its remote.

**Approach:** Build sections 2–5 of the approved `design/Refs Study.html`: a Tags rail button and view beside Bookmarks, both as a `/`-split tree with a filter, row buttons in place of the state, a right-click menu, and one delete flow (delete at once without a tracked remote; otherwise a sheet with three choices showing their commands) shared by the views and the card's bookmark popover. DS synced through #26 plus the Refs Study.

## Boundaries & Constraints

**Always:**
- **Tags rail item** (id `tags`, identifier `rail-tags`, icon new `ZI.tag`) right after Bookmarks; same preview (first 5 rows + "+N more", which pins) and pinned panel. Tag rows come from `RepoHandle.tags()` (9.59: `jj tag list --all-remotes`, no `git` remote). The tags model reuses `BookmarkListModel` (a `TagListModel` subclass with `kind: RefKind.tag`, so inject.dart sees two types); its source maps each `Tag` to a `Bookmark` row (`RemoteTag(r, tracked)` → `RemoteBookmark(r, tracked: …)` with no distances), so row state, targets, picking and dimming are shared. A tag row's state is therefore ✓ / deleted / conflict / `↕` (differs from its tracked remote) / none.
- **Tree** (both panels; the preview stays the flat first-5 list, tag preview glyph `ZI.tag`): names split at `/`; every segment but the last is a folder; a leaf shows its last segment (the whole name if that segment is empty). **Order: folders first (by name), then leaves in jj's list order** (the open design question's default; record it in Design Notes). A remote row sits in its name's folder beside the local row, its label `segment` + dim `@remote`, the text block at .6 when untracked. Folder rows: 28 high, `ZI.folderOpen`/`ZI.folder` in `textFaint`, mono 11.5 `textMuted`, name with a trailing `/`, indent 8 + 14·depth, no chevron, `Semantics(expanded:)`; click, ↩ and Space toggle (session-only collapsed set in the model, default open). Leaves: no leading icon, indent 8 + 14·depth + 20, min height 40, name (mono 12) over "id · subject" (today's `_sub`), state on the right; tooltip = full display name. Click / ↩ / Space pick, dimming outside the layout, and drag of local bookmarks (never tags) stay as today.
- **Filter** (`ZsSearchField`, placeholder/label "Filter bookmarks" / "Filter tags", clear button) on top of each panel, filtering only that tree: case-insensitive substring of the display name (`name@remote`); kept leaves plus every folder on their path, all shown open; the match is highlighted only inside a row's own text (weight 600 + underline in `accent`); no hit → "No bookmark matches “q”." / "No tag matches “q”.". The filter text lives in the model (session-only).
- **Row buttons** on the hovered or keyboard-focused leaf (focus-within), panel only, drawn in place of the state; the row's height never changes. Order and actions:
  - local with a target: New change here (`ZI.plus`, `jj new <name>`), Delete… (danger, item 4);
  - tracked remote: Untrack, New (`jj new <name>@<remote>`); untracked remote: Track, New. Track/Untrack = `jj bookmark|tag track|untrack <name>@<remote>`;
  - no target (deleted / not created): Track/Untrack only where they apply.
  Tooltips carry the command (`ZsTooltip cmd`); while the runner cannot run, buttons are disabled with today's reason (stale / busy). Identifiers `<kind>-row-<i>`, `<kind>-row-new-<i>`, `-delete-<i>`, `-track-<i>` (kind `bookmark` / `tag`; keep today's `bookmark-row-<i>`).
- **Right-click menu** on a leaf (`ZsMenuAnchor`, `onSecondaryTapUp`, as `projects_tree.dart`): the row's actions + "Rename…" (local bookmarks only; `GraphNameSheet` with `GraphBookmarkRename`) + "Copy name" (full display name; `Clipboard` + `announceCopied`).
- **Delete flow** (one shared implementation, `features/bookmarks/ref_delete.dart`), for every Delete of a bookmark or tag (row button, row menu, card bookmark popover; 10.45's tag popover reuses it):
  - "Has a remote" = a **tracked** remote row of that name (not `git`). None → run the delete at once through `GraphViewModel.run` (its toast offers Undo).
  - Otherwise a sheet (`ZsConfirmDialog`, destructive, title "Delete <name>?", body "The bookmark/tag is also on <remotes>. Where should it go?", confirm "Delete", ⌘↩) with a radio group (`ZsRadio` in a `RadioGroup`), default the middle choice, each choice showing label, its commands (mono, one per line) and note:
    1. "Only here — keep it on <remotes>": bookmark `jj bookmark forget <name>`; tag `jj tag untrack <name>@<r>` per remote, then `jj tag delete <name>`. Note "Undo works. <remotes> keeps it; the next fetch shows it again as untracked."
    2. "Here, and on <remotes> when you push the deletion" (marked default): `jj bookmark|tag delete <name>`. Note "Undo works until you push. A plain push skips deletions; the Push sheet offers to push them."
    3. "Here and on <remotes> now" (danger tone): the delete, then `jj git push --remote <r>… --bookmark|--tag <name>` (`PushRequest(mode: custom)`'s own command). Note "Can't be undone: <remotes> loses the bookmark/tag."
  - Several tracked remotes: every remote is named (comma-joined) in labels/notes, one untrack per remote, one push with each `--remote`.
  - Each choice runs exactly its shown commands, in order, each verb through `GraphViewModel.run` (names as exact patterns / `name@remote` symbols, as today's actions); a step that does not end `GraphActionDone` stops the rest; the push runs through a new `SyncModel.pushNow(PushRequest)` (syncing dot, `_pushed` toast with Undo when recorded, a failure toast with jj's text otherwise).
- **New verbs** in `graph_ports.dart` (sealed `GraphAction`, POSIX-quoted commands): `GraphBookmarkForget(name)` (`jj bookmark forget <exact>`), `GraphTagDelete(names)` (`jj tag delete <exact>…`), `GraphTagTrack(name, remote)`, `GraphTagUntrack(name, remote)` (`jj tag track|untrack <name>@<remote>`); a public `revsetSymbol(name)`; wired in `RepoGraphActions.run`, `graph_toasts.dart` `_text`, `AppMenuModel.actionName`.
- **Refusal text:** the graph's refusal toast shows a multi-line `error.context` (e.g. 9.59's caret diagram) in the mono `ZsType.id` style and appends the error's `hints`, one per line.
- Strings via `app_en.arb` + `flutter gen-l10n` (output committed); jj's words and commands stay literals marked `// l10n-ignore`. Zs controls and DS tokens only. Tests never touch Ralph's settings or jj config; jj only in temp dirs tests create.
- **DS** via `design-artifacts` (modes C/E, then F's sync line), no publish: the `tag` glyph in all five places (`Icon.jsx` `ZS_ICON_SET`, `assets/icons/ui/tag.svg` at the DS 1.5 stroke, `glyphs.json`, `Icon.d.ts` count, and the app's `packages/zanshin_ui/assets/icons/svg/tag.svg` + `ZI.tag` + `ZI.all`, equal after the stamp strip); the kit's rail gets Tags and its panel the tree rows (no leading icon, row buttons) with `SearchField` on top; `ConfirmDialog` gains a choice list (label, commands, note, default mark, danger) with `.d.ts` / `.prompt.md` (its one-command rule names the choice exception) / CSS / card; `_ds_bundle.js` blocks + `sourceHashes`; readme Sync line; one dated line `- 2026-11-16 (Story 10.44) — …` at the end of `design/DESIGN-SYSTEM-SYNC.md`. Do not touch the study files.

**Never:**
- The card legends, the tag popover, removing the card's ⋯ (10.45); the name-field rules and the move picker (10.46); the top search (10.47); a "+"/create action inside the views; dragging tags.
- Single-child folder joining, persisting the filter or the collapsed set.
- Publishing the DS, syncing a canvas, the Marionette check (the console session's).
- The full gate (`cargo make test` / `test-full` / `coverage`) — this run uses targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Tree order | `main`, `onboarding/step-1`, `onboarding/step-2@origin`, `feature/auth-flow` | folders `feature/`, `onboarding/` (open) then `main`; remote row under `onboarding/` labelled `step-2` + `@origin` | — |
| Filter | "onb" | only `onboarding/` and its matching leaves, open; "onb" highlighted in the folder row | no hit → "No bookmark matches “onb”." |
| Hover local / tracked / untracked | three leaves | New+Delete / Untrack+New / Track+New in place of the state; heights unchanged | stale → disabled with reason |
| New | New on `main` / on `x@origin` | `jj new main` / `jj new x@origin` | refusal → warn toast |
| Delete, no tracked remote | local `wip` (maybe an untracked `wip@origin`) | `jj bookmark delete wip` at once, toast with Undo | — |
| Delete, tracked remote | `feature/auth-flow` tracked on origin | sheet, middle choice selected; confirm runs exactly that choice's commands | a step refused → later steps skipped, refusal toast |
| Delete tag, two remotes | `v1.5.0-rc1` tracked on origin, upstream | choice 1: untrack both, then delete; choice 3: delete + `jj git push --remote origin --remote upstream --tag v1.5.0-rc1` | push failure → error toast, delete stays (Undo in its toast) |
| Card popover Delete | local bookmark on a card | same rule (read the `--all-remotes` rows if not yet read) | read failed → delete item disabled with the failure |
| Multi-line refusal | `error.context` with `\n`, hints | toast: context in mono, then hints | — |

</intent-contract>

## Code Map

- `app/lib/src/features/bookmarks/bookmark_list_model.dart` -- `BookmarkListSource` `:26`, `RepoBookmarkListSource` `:43`, `BookmarkRow` `:106` (`display`, `trackAction` `:162`), `BookmarkListModel` `:174` (read loop `:257-335`, `_build` `:337`), `bookmarkRowState` `:388`. Add `RefKind`, `kind`, `TagListModel`, `RepoTagListSource` (Tag→Bookmark), filter text, collapsed set, tree rows (pure, unit-tested), row actions (New/Delete/Track), delete entry point.
- `app/lib/src/features/bookmarks/bookmark_list_view.dart` -- `bookmarksRailId` `:19`, `bookmarksRailItem` `:28`, `BookmarkListPreview` `:40`, `BookmarkListPanel` `:103` (becomes filter + tree + delete/rename overlay), `BookmarkRowTile` `:201` (leading icon `:342` goes in the panel; `_trackButton` `:414` → row buttons in place of the state). Add `tagsRailItem` / tags id.
- `app/lib/src/features/bookmarks/ref_delete.dart` (new) -- `RefDeleteRequest`, choices → steps (actions + `PushRequest?`), runner, `RefDeleteSheet` widget.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphAction` `:171`, bookmark verbs `:494-627`, `remoteBookmarkSymbol` `:630`, helpers `:700-730` (`_revsetSymbol`, `exactNamePattern`), `RepoGraphActions.run` `:870`.
- `app/lib/src/features/graph/graph_toasts.dart` -- refusal toast `:145-157` (mono multi-line + hints), success texts `_text` `:257` (Delete `:314`, Untrack `:326`).
- `app/lib/src/app/menu/app_menu.dart:176-219` -- `actionName` switch.
- `app/lib/src/features/graph/graph_card_menu.dart` -- popover Delete item `:358-363`, `graphBookmarkMenuEntries` `:267`, `GraphBookmarkMenuHost` `:689` (OverlayPortal `:759-779` — host the delete sheet the same way; `_read` rows decide), `GraphNameSheet` `:807`.
- `app/lib/src/features/graph/graph_view.dart:53,68,400` -- pass a push callback to `GraphBookmarkMenuHost`.
- `app/lib/src/features/sync/sync_model.dart` -- add `pushNow` beside `openPush` `:292`, reuse `_pushed` `:309`, `_show`; `remote_sync.dart` `PushRequest` `:73` (`command` `:147`).
- `app/lib/src/features/home/project_scope.dart` -- `bookmarkList` provider `:201` (+ `SyncModel` for push), new `tagList` provider, `ProjectScope` field; `remoteBookmarks` `:286`; regenerate `app/lib/main.inject.dart`, `app/test/helpers/test_component.inject.dart` (build_runner).
- `app/lib/src/features/home/project_graph_host.dart:194` (GraphView push), `app/lib/src/features/home/home_page.dart:99-108` (rail items; merge the tags model into the `ListenableBuilder`).
- Reuse: `inspector_file_tree.dart:62` (folder split / folders-first pattern), `graph_inspector.dart:3486-3530` (folder row look), `projects_tree.dart:1000-1011` (right-click `ZsMenuAnchor`), `project_files.dart:44,226` (copy + `announceCopied`), `zs_text_field.dart:626` `ZsSearchField`, `zs_confirm_dialog.dart:40`, `zs_radio.dart` (`ZsRadio`, `RadioGroup`), `zs_button.dart:374` `ZsIconButton`.
- Icons: `packages/zanshin_ui/lib/src/icons/zanshin_icon.dart:149` (`ZI`, `ZI.all` `:214`), `packages/zanshin_ui/assets/icons/svg/`, parity test `packages/zanshin_ui/test/design/ds_parity_test.dart:83-107`.
- `app/lib/l10n/app_en.arb` -- `bookmarks*` keys; new Tags / filter / row / delete-sheet strings.
- Tests/fakes: `app/test/features/bookmarks/bookmark_list_{model,view}_test.dart`, `app/test/helpers/fake_bookmark_list.dart` (`FakeBookmarkListSource` `:19`, `BookmarkRig` `:123`, `RecordingGraphActions` `:147`), `test/helpers/shell_host.dart:53,61`, `test/features/graph/graph_card_menu_test.dart:439`, `graph_ports` command tests, `test/features/sync/` (SyncModel), widgetbook `app/widgetbook/folders/bookmarks.dart` (+ `shell.dart:97,105`).
- DS: `_bmad-output/implementation-artifacts/design_system/` -- `components/brand/Icon.{jsx,d.ts}`, `assets/icons/ui/`, `assets/icons/glyphs.json`, `ui_kits/desktop/{chrome.jsx,kit.css}` (`ZK_RAIL`, `ZKRailContent`, `.zk-bl-*`), `components/forms/SearchField.*`, `components/controls/ConfirmDialog.{jsx,d.ts,prompt.md}` + CSS + card, `_ds_bundle.js`, `readme.md:22,64-67`; `design/DESIGN-SYSTEM-SYNC.md` (append). Reference only: `design/refs-study.{jsx,css}` (rail J:168-195; tree J:198-288, C:44-75; delete sheet J:291-330, C:77-100).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_ports.dart` -- the four verbs, `revsetSymbol`, `RepoGraphActions.run`; `graph_toasts.dart` (texts + mono/hints refusal), `app_menu.dart` (names) -- unit tests for each command text.
- `app/lib/src/features/sync/sync_model.dart` -- `pushNow` -- test: success toast, failure toast, not while stale/busy.
- `app/lib/src/features/bookmarks/ref_delete.dart` -- tracked-remote rule, steps per choice and kind (incl. two remotes), runner stopping on a refusal, the sheet -- unit + widget tests.
- `app/lib/src/features/bookmarks/bookmark_list_model.dart` -- kind, tag source, tree rows, filter, collapsed set, row actions -- unit tests per matrix rows 1–2.
- `app/lib/src/features/bookmarks/bookmark_list_view.dart` -- rail item for tags, panel tree + filter + row buttons + menu + sheet overlay -- widget tests (witnesses).
- `app/lib/src/features/graph/graph_card_menu.dart`, `graph_view.dart` -- popover Delete through the delete flow -- test.
- `app/lib/src/features/home/{project_scope,project_graph_host,home_page}.dart` + build_runner outputs -- wiring.
- `packages/zanshin_ui` -- `tag.svg`, `ZI.tag`, `ZI.all`; parity test passes.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n`; widgetbook use cases: Tags preview/panel, tree with filter, a row with its buttons shown (hover-only surface), the delete sheet (bookmark, tag with two remotes).
- DS per Boundaries and the DESIGN-SYSTEM-SYNC line.

**Acceptance Criteria:**
- Given an open project, when the rail shows, then Tags sits below Bookmarks; hovering it shows the first 5 tags and "+N more"; a click pins the Tags view.
- Given the Bookmarks view, when "onb" is typed in its filter, then only matching names and their folders show, open, with the match highlighted.
- Given a local, a tracked and an untracked remote leaf, when each is hovered, then its buttons replace its state and no row changes height; New on a bookmark runs `jj new <name>`; Track and Untrack change the tracking state.
- Given a bookmark without a tracked remote, when Delete… is pressed, then it is deleted without a dialog and the toast's Undo restores it.
- Given `feature/auth-flow` tracked on origin, when Delete… is pressed (row, row menu or card popover), then the sheet offers the three choices with their commands, and confirming each choice runs exactly those commands in order.
- Given the Tags view, when a tag leaf is dragged or deleted, then nothing drags, and the delete runs the tag commands (`jj tag delete`, `jj tag untrack … + jj tag delete`, `--tag` push).

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 37 findings — high 0, medium 10, low 21, false 6, maybe-false 0
- findings:
  - `[medium]` `[patch]` (intent) New change here shows `jj new <name>` but runs `jj new <target change id>` — `RepoHandle.newChange` takes change ids only (`crates/zanshin-jj/src/repo.rs:1596`), so the name cannot be passed; patched the tooltip and menu command to the one that runs, and deferred the name-based `jj new` as a backend gap.
  - `[medium]` `[patch]` (intent) A local-only bookmark still shows the "local" mark — the story says it shows none; `bookmarkStateShort` now hides `local` and `remote` for both kinds (the untracked row is marked by its dim text).
  - `[false]` `[reject]` (intent) "With a remote" narrowed to tracked remotes — an untracked remote copy is untouched by delete, forget and push alike (`../jj` v0.47.0 cli/src/commands/git/push.rs:1424-1456), so no choice differs; recorded in Design Notes.
  - `[false]` `[reject]` (intent) Tag popover Delete not wired — the tag popover is Story 10.45 (story non-goal: "The cards (10.45)"); the flow is reusable.
  - `[low]` `[reject]` (intent) Mono only in the graph refusal toast — the list reads and `pushNow` take no name patterns, so the caret diagram cannot reach them; no everyday path.
  - `[false]` `[reject]` (intent) Leaves keep jj's order, the study sorts them — jj's list order is by name already (`ui.bookmark-list-sort-keys` default), and the spec records the order.
  - `[low]` `[patch]` (intent) "Exactly those commands" checked as strings only — covered by the real-repo forget test added below; the rest stays on recorder fakes like every graph verb test.
  - `[medium]` `[patch]` (verification) Production wiring of the delete flow and the tag list untested — added `project_graph_host_test.dart` asserts for `deleteBookmark`, `RefDeleteHost`, the shared flow, its push and `TagListModel`.
  - `[medium]` `[patch]` (verification) Popover Delete before the read lands untested — added the Completer-held read case and the failing-read case.
  - `[medium]` `[patch]` (verification) `pushNow`'s thrown path and `canPush` while pushing unasserted — added the tests.
  - `[medium]` `[patch]` (verification) Forget not told apart from delete in a real repo; tag track/untrack never dispatched — added the forget-with-tracked-remote case (tag track/untrack: see Auto Run Result).
  - `[low]` `[patch]` (verification) The tag row's hidden local/remote mark unasserted — asserted with the state change above.
  - `[low]` `[patch]` (verification) Delete… offered when the model has no delete flow (a no-op) — Delete is left out without `deletes`.
  - `[medium]` `[patch]` (verification) "Now" can delete locally and skip the push without feedback — `pushNow` now toasts why it did not push.
  - `[low]` `[patch]` (edge) Delete offered without `deletes` — same root as above.
  - `[medium]` `[patch]` (edge) `pushNow` skip is silent after the local delete — same root as above.
  - `[low]` `[patch]` (edge) `pushNow` lets a non-`ZanshinFfiException` escape the unawaited run — added an `on Object` catch with the failed toast.
  - `[low]` `[reject]` (edge) Tag "Only here" half-applied when a later untrack is refused — needs a refusal between two untracks of one tag; the refusal toast shows, and grouping or rolling back adds a mechanism.
  - `[low]` `[patch]` (edge) `_delete` notifies after the host unmounted — `if (!mounted) return` after the await.
  - `[low]` `[patch]` (edge) A failed read inside `_delete` does nothing visibly — it now marks the read failed, which disables Delete with the reason.
  - `[low]` `[reject]` (edge) `deleteBookmark` without `bookmarks` deletes without the sheet — production always passes both (`project_graph_host.dart`); only catalogue hosts omit `bookmarks`.
  - `[low]` `[patch]` (edge) The pinned panel keeps the old project's filter and rename sheet across a project switch — panel keyed by its model.
  - `[false]` `[reject]` (edge) New lands on a target read before the ref moved — the list re-reads on every operation change before its rows are used; the shown command (now the change id) is what runs.
  - `[low]` `[patch]` (blind) The bookmark "Only here" note says the copy shows again at the next fetch — `jj bookmark forget` untracks it at once (`cli/src/commands/bookmark/forget.rs` @ v0.47.0); note reworded.
  - `[low]` `[patch]` (blind) "Undo works" is not true for the tag "Only here" — the tag note now says Undo brings the tag back untracked.
  - `[low]` `[reject]` (blind) A partial run leaves no explanation — same as the half-applied tag case above.
  - `[medium]` `[patch]` (blind) `pushNow` skips silently — same root as above.
  - `[low]` `[patch]` (blind) Popover Delete fails silently on a read failure — patched above; the null-`bookmarks` part is rejected above.
  - `[low]` `[patch]` (blind) A Delete… that does nothing — same root as above.
  - `[low]` `[reject]` (blind) Tag rows use bookmark state wording and `↕` without distances — the spec chose the shared state (`↕` = differs from the tracked remote); cosmetic VoiceOver wording.
  - `[false]` `[reject]` (blind) Hover hides the state — the design puts the buttons in place of the state on hover (Refs Study `.rs-leaf:hover .rs-state{visibility:hidden}`); VoiceOver keeps the long state.
  - `[medium]` `[patch]` (blind) New tooltip shows a command the app does not run — same root as the first row.
  - `[low]` `[patch]` (blind) `RefDeleteHost` keeps a sheet when the flow changes — `didUpdateWidget` re-runs `_changed`.
  - `[low]` `[reject]` (blind) Folder sort by code unit vs `localeCompare`; no highlight across `/` — mixed-case folder names and `/`-spanning queries are rare; cosmetic.
  - `[low]` `[reject]` (blind) No context-menu key / Escape-to-clear in the views — not in the story (10.45 adds the card's ⇧F10); the row buttons are keyboard-reachable.
  - `[false]` `[reject]` (blind) The mono refusal format applies to every refusal — intended (spec Boundaries); a single-line text stays proportional, and `toastRevisionNotFound` holds no newline.
  - `[low]` `[patch]` (blind) Test gaps (Copy name clipboard text, plural "Deleted tag v1 and v2") — clipboard assert added; the plural part is rejected: every Delete in the app names one tag, so "Deleted tag <name>" never meets several names.

### 2026-11-16 — Review pass (follow-up)
- verdicts: 39 findings — high 0, medium 8, low 28, false 3, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) Hover hides the row state; the tree tooltip is only the display name — carried: the design puts the buttons in place of the state, and the spec sets tooltip = full display name.
  - `[medium]` `[patch]` (blind) New runs `jj new <change id>`, not `jj new <name>`; conflicted and divergent targets differ from the CLI — carried: command text made honest and the name-based `jj new` deferred (backend gap).
  - `[low]` `[reject]` (blind) `revsetSymbol` is dead and repeats `jjRevsetSymbol` — the intent's Boundaries require a public `revsetSymbol`; it is the hook for the deferred name-based `jj new`.
  - `[low]` `[patch]` (blind) The widgetbook "Row buttons" demo shows `main@origin@origin` — it passed the display name as the label; it now passes the name (`app/widgetbook/folders/bookmarks.dart`).
  - `[medium]` `[patch]` (blind) "Now" deletes before it knows it can push; a stale skip shows no toast — carried: `pushNow` toasts why it skipped (the stale branch shows `staleTitle`, `sync_model.dart:311-314`).
  - `[low]` `[reject]` (blind) A tag's "Only here" can stop halfway — carried: needs a refusal between two untracks; a fix adds a rollback mechanism.
  - `[low]` `[reject]` (blind) The sheet's Delete stays enabled when the runner turns busy or stale while it is open — `GraphViewModel.run` then returns `GraphActionDisabled` and nothing runs, while the graph shows its stale banner; a stale arriving during the open sheet is rare, and a fix adds a guarded state to the sheet.
  - `[low]` `[patch]` (blind) The popover's Delete reads as an immediate action — with the delete flow it now reads "Delete…" like the panel (`graph_card_menu.dart`); its command stays the default choice's.
  - `[low]` `[reject]` (blind) Rename… and Copy name only by right-click — carried: no context-menu key in the story; row buttons are keyboard-reachable.
  - `[low]` `[reject]` (blind) No tree arrow-key navigation or tree roles — not in the story; arrow-key traversal is a new mechanism.
  - `[low]` `[patch]` (blind) VoiceOver hears neither the commands nor the default mark of a delete choice — the choice's semantics label now reads label (+ ", default"), each command, then the note; widget test added.
  - `[low]` `[reject]` (blind) The DS `ConfirmDialog` gained choices but `ZsConfirmDialog` did not — the spec places the sheet in `ref_delete.dart`; moving it into `zanshin_ui` is a refactor no user meets.
  - `[low]` `[reject]` (blind) Folder sort and highlight differ from the kit — carried: rare names, cosmetic.
  - `[low]` `[reject]` (blind) The "now" note says "Can't be undone" while the push toast offers Undo — the push toast's Undo is the shared push-toast behavior (it undoes jj's push operation locally); hiding it for this push adds a parameter.
  - `[low]` `[reject]` (blind) The kit comment promises Untrack the kit cannot show — the kit's static data has no tracked remote row; any kit edit forces a `_ds_bundle.js` block and hash re-sync.
  - `[low]` `[patch]` (edge) A tracked remote "not created yet" makes the sheet claim the ref is on the remote — `RefDeleteRequest.of` now skips tracked remote rows without a target; unit test added.
  - `[low]` `[reject]` (edge) Sheet confirm while the runner is busy or stale does nothing — same as the sheet-Delete row above.
  - `[low]` `[reject]` (edge) Rename sheet confirmed while busy or stale does nothing — the card popover's `GraphNameSheet` behaves the same; rare, and a fix adds a guard.
  - `[false]` `[reject]` (edge) A name whose lower case changes length (U+0130) misaligns the highlight or throws — Dart's `toLowerCase` keeps the length (`'İstanbul'` → 8 code units, checked with `dart run`).
  - `[low]` `[reject]` (edge) A match across `/` or in `@remote` keeps a row without a highlight — carried: rare, cosmetic.
  - `[low]` `[reject]` (edge) A folder click while filtering folds it invisibly — the click records the user's fold, which shows once the filter clears; a guard adds a branch.
  - `[medium]` `[patch]` (edge) New on a divergent target fails where `jj new <name>` works — carried: deferred backend gap.
  - `[low]` `[reject]` (edge) Out-of-sync tags show the diverged mark — carried: the spec defines `↕` for a tag as "differs from its tracked remote".
  - `[low]` `[patch]` (edge) A read failing after Delete was chosen gives no visible feedback — carried: it marks the read failed, which disables Delete with the reason.
  - `[low]` `[reject]` (edge) `deleteBookmark` without a bookmark reader deletes without asking — carried: production always passes both.
  - `[low]` `[reject]` (edge) The kit's leaf React key can collide (`aborigin` vs `ab@origin`) — the kit's static data has no such pair; the edit needs a bundle re-sync.
  - `[medium]` `[patch]` (edge) The preview lost its local/remote short marks — carried: the earlier pass hid them for both kinds.
  - `[medium]` `[patch]` (edge) New shows and runs the change id, not the name — carried (deferred).
  - `[low]` `[reject]` (edge) `revsetSymbol` has no production caller — same as the blind row: the intent requires it.
  - `[low]` `[patch]` (verification) A tracked remote tag's Untrack label is untested — the tag panel test now hovers `v1.5.0@origin` (Untrack, `jj tag untrack`) and `nightly@origin` (Track, `jj tag track`).
  - `[low]` `[patch]` (verification) The popover's delete-flow Delete is never tested while blocked — the unit test now asserts it disabled with the `blocked` reason.
  - `[medium]` `[patch]` (verification) A project switch with the sheet open is untested — widget test added in `ref_delete_test.dart`; removing the post-frame `_changed()` makes it fail (mutation-checked).
  - `[low]` `[patch]` (verification) `pushNow`'s recorded-failure branch is untested — test added: returns false, the pushed toast keeps Undo.
  - `[low]` `[defer]` (verification) The Tags rail count rebuild is untested — the home rig cannot order the tag read after the bookmark read, and the Bookmarks count has the same gap; deferred.
  - `[medium]` `[patch]` (intent) New's command is the change id, not the name — carried (deferred).
  - `[medium]` `[patch]` (intent) "No mark" applied to local and untracked bookmark rows too — carried.
  - `[low]` `[reject]` (intent) The filter matches `name@remote` but highlights only the label — carried.
  - `[false]` `[reject]` (intent) Identifier mix (`<kind>-row-delete-<i>` vs `<kind>-track-<i>`) — the intent's "-delete-<i>, -track-<i>" admits both, and `-track-` keeps today's `bookmark-track-<i>`; ids are stable and tested.
  - `[low]` `[patch]` (intent) The "now" push and the two-remote tag run only on fakes — carried: real-repo forget and tag track/untrack were added; the rest stays on recorder fakes.

## Design Notes

- **Tree order (open design question):** folders first, as the inspector tree, so `main` sits below the folders — the story's named default. Leaves keep jj's order (name, then local before its remotes).
- **"Has a remote" means tracked:** only a tracked remote ref makes `delete` differ from `forget`, and only a tracked one gets its deletion pushed (`find_bookmarks_to_push` / `find_tags_to_push`, `../jj` v0.47.0 cli/src/commands/git/push.rs:1424-1456). An untracked remote copy is untouched by either, so such a delete needs no question.
- **Tag "Only here"** is two operations (`untrack` per remote, then `delete`; jj 0.47 has no `tag forget`); the toast's Undo undoes the delete only.
- **Tag rows reuse the bookmark row model**: a `Tag` maps to a `Bookmark` with no distances, so one model, tree and tile serve both kinds (`kind` picks the verbs, labels and drag).

## Verification

**Commands:**
- `flutter gen-l10n` (in `app/`) and `dart run build_runner build --delete-conflicting-outputs` (in `app/`) -- outputs committed.
- `flutter test` in `app/` (at least `test/features/bookmarks test/features/graph test/features/sync test/features/home test/app/menu`) and in `packages/zanshin_ui` -- expected: pass.
- `dart analyze` and `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_ui` -- expected: clean.
- No Rust, FFI or jj verb change: no cargo checks, codegen or parity oracle needed.

**Manual checks:**
- Marionette against `design/Refs Study.html` — by the console session, not this run.

**Verification notes (2026-11-16, targeted checks per the story loop's gate rule):**
- `flutter gen-l10n` and `dart run build_runner build --delete-conflicting-outputs` in `app/` — outputs committed.
- `flutter test test/features/bookmarks test/features/graph test/features/sync test/features/home test/app/menu test/architecture test/l10n` in `app/` — 1305 pass, 1 fails: `remote_sync_test.dart` "pushConfig reads git.sign-on-push", which refuses to run outside `cargo make test-app` ("XDG_CONFIG_HOME is not pinned"); untouched by this story. The implementer's earlier full `flutter test` in `app/`: 2485 pass, 6 fail, all six for the same unpinned-environment reason (`worker_project_repos_test`, `remote_sync_test`).
- `flutter test` in `packages/zanshin_ui` — 475 pass (the DS parity test with the 63rd glyph).
- `dart analyze` and `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_ui` — clean.
- `node --check _ds_bundle.js` — passes.
- Not run (gate rule): `cargo make test` / `test-full` / `coverage`. No Rust, FFI or jj verb changed, so no cargo checks, codegen or parity oracle.

**Verification notes (2026-11-16, follow-up review pass, targeted checks per the gate rule):**
- `flutter test test/features/bookmarks test/features/graph test/features/sync test/features/home test/app/menu test/architecture test/l10n` in `app/` — 1309 pass, 1 fails: the same env-pinned `remote_sync_test.dart` "pushConfig reads git.sign-on-push" (needs `cargo make test-app`); untouched here.
- `flutter test test/features/bookmarks/ref_delete_test.dart` (11 pass) and `test/features/sync/sync_model_test.dart` (26 pass) run alone — pass.
- Mutation check: without the post-frame `_changed()` in `RefDeleteHost.didUpdateWidget`, the new project-switch test fails; restored.
- `dart analyze` in `app/` — no issues; `dart format --set-exit-if-changed .` in `app/` — clean (after formatting `ref_delete.dart`).
- `dart run` probe: Dart's `toLowerCase` keeps the string length (`İstanbul` 8 → 8), refuting the highlight-crash finding.
- `packages/zanshin_ui` and the DS untouched in this pass; no Rust, FFI or jj verb change, so no cargo checks, codegen or parity oracle. Not run (gate rule): `cargo make test` / `test-full` / `coverage`.

## Auto Run Result

Status: done

**Summary.** The rail has a Tags item below Bookmarks. Both views are a `/`-split tree (folders first, then leaves in jj's order) with a filter, row buttons in place of the state, and a right-click menu (row actions, Rename… for bookmarks, Copy name). One delete flow (`ref_delete.dart`) serves the views and the card's bookmark popover: without a tracked remote it deletes at once (toast Undo); with one, a sheet offers "Only here", "on push" (default) and "now", each with its commands. New verbs: `jj bookmark forget`, `jj tag delete|track|untrack`; `SyncModel.pushNow` runs the "now" push. Multi-line refusals show in mono with jj's hints. DS: `tag` glyph, `ConfirmDialog` choices, the kit's tree and Tags rail (not published).

**Deviation.** `graph` may not import `bookmarks` (`test/architecture/layers_test.dart`), so the card popover gets a `deleteBookmark` callback (`GraphDeleteBookmark`) wired by `project_graph_host.dart` to the shared `RefDeleteFlow`, and `RefDeleteHost` wraps the graph. New change here runs and shows `jj new <target change id>` (backend gap, deferred).

**Files changed.**
- `app/lib/src/features/bookmarks/bookmark_list_model.dart` — `RefKind`, `RepoTagListSource`/`tagRow`, `TagListModel`, `refTree`, filter, folding, row verbs.
- `app/lib/src/features/bookmarks/bookmark_list_view.dart` — Tags rail item, filter + tree panel (keyed by model), folder rows, leaves with row buttons and menu.
- `app/lib/src/features/bookmarks/ref_delete.dart` — request, steps, runner, `RefDeleteFlow`, `RefDeleteHost`, `RefDeleteSheet`.
- `app/lib/src/features/graph/graph_ports.dart` — four verbs, `revsetSymbol`, dispatch.
- `app/lib/src/features/graph/graph_toasts.dart` — verb texts, mono multi-line refusal with hints.
- `app/lib/src/features/graph/graph_card_menu.dart`, `graph_view.dart` — popover Delete through the flow (reads first; a failed read disables it).
- `app/lib/src/features/sync/sync_model.dart` — `pushNow` with busy/failure toasts.
- `app/lib/src/app/menu/app_menu.dart` — Undo/Redo names.
- `app/lib/src/features/home/{project_scope,project_graph_host,home_page}.dart`, `app/lib/main.inject.dart`, `app/test/helpers/test_component.inject.dart` — wiring.
- `app/lib/l10n/*` — strings.
- `packages/zanshin_ui` — `tag.svg`, `ZI.tag`, parity count.
- `app/widgetbook/folders/{bookmarks,shell}.dart` — use cases incl. the hover-only buttons and both delete sheets.
- Tests: `bookmark_list_{model,view}_test.dart`, `ref_delete_test.dart`, `graph_{card_menu,ports,toasts}_test.dart`, `sync_model_test.dart`, `project_graph_host_test.dart`, `home_page_test.dart`, `app_menu_test.dart`, `fake_bookmark_list.dart`.
- DS (`design_system/`): Icon, ConfirmDialog (+ CSS, card), kit chrome/css, `_ds_bundle.js` + hashes, readme; `design/DESIGN-SYSTEM-SYNC.md` line.

**Review.** 37 findings: 21 patched (10 medium, 11 low — counted by row; entries: New command honesty, no local/remote mark, production-wiring tests, popover read-first path, `pushNow` feedback and error paths, real-repo forget and tag track/untrack, Delete without a flow, panel keyed by model, `RefDeleteHost` flow swap, "Only here" notes, Copy name clipboard test), 1 deferred (jj new by name needs `new_change` to take revsets — mirrored in deferred-work.md), rejected: tracked-only remote rule (false, jj semantics), tag popover (false, 10.45), mono on other surfaces (low, unreachable), leaf order (false), tag half-applied "Only here" (low, needs a refusal mid-run, fix adds a mechanism), null `bookmarks` (low, production passes it), stale target (false), tag state wording (low, cosmetic), hover hides state (false, by design), sort/highlight across `/` (low, rare), keyboard menu path (low, not in the story), mono for every refusal (false, intended), plural tag toast (low, one name per delete).

**Follow-up review:** recommended — two or more medium entries were patched (10 medium rows). Unverified risk: the patched `pushNow` skip/busy toasts and `RefDeleteHost`'s post-frame close on a flow swap are covered only by widget tests over fakes; nothing drove them in the running app.

**Residual risks.** Visual match with the Refs Study and the DS kit JSX are unchecked (Marionette and DS publish belong to the console session). The tag "Only here" is two or more operations; Undo restores the tag untracked (the note says so). The full gate (incl. coverage and the env-pinned app tests) runs at the end of the story loop.

### Follow-up review pass (2026-11-16)

**Summary.** A fresh four-layer review of the finished change (39 findings). Eight entries patched, one deferred, the rest carried or rejected. No high finding.

**Files changed.**
- `app/lib/src/features/bookmarks/ref_delete.dart` — a tracked remote without a target ("not created yet") no longer makes the sheet ask; each choice's semantics label carries the default mark and the commands.
- `app/lib/src/features/graph/graph_card_menu.dart` — the popover's delete-flow item reads "Delete…".
- `app/widgetbook/folders/bookmarks.dart` — the "Row buttons" demo passes the name as the label (no `@origin@origin`).
- Tests: `ref_delete_test.dart` (not-created remote, VoiceOver label, project switch with the sheet open), `bookmark_list_view_test.dart` (tag Track/Untrack labels and commands), `graph_card_menu_test.dart` (blocked delete-flow item, "Delete…"), `sync_model_test.dart` (`pushNow` recorded failure).

**Review.** Patched: 1 medium (project-switch sheet test), 7 low (widgetbook label, popover "Delete…", VoiceOver choice label, not-created remote, tag track label test, blocked popover Delete test, `pushNow` recorded-failure test). Deferred: 1 low (Tags rail count rebuild untested — mirrored in deferred-work.md). Carried from the first pass: 15 rows keep their verdicts (New by change id, `pushNow` skip toasts, preview marks, tag half-applied "Only here", keyboard menu path, sort/highlight, tag ↕ wording, read failure, null reader, test surfaces). Rejected new rows: `revsetSymbol` dead (low, the intent requires it), sheet/rename confirm while busy (low, rare, adds a guard), tree arrow keys (low, not in the story), `ZsConfirmDialog` choices (low, refactor), "now" note vs push-toast Undo (low, shared toast, adds a parameter), kit comment and React key (low, static kit data, needs a bundle re-sync), folder click while filtering (low, records the user's fold), U+0130 highlight (false, Dart keeps the length), identifier mix (false, both readings allowed).

**Follow-up review:** not recommended — this follow-up pass patched no high finding (patched: 0 high, 1 medium, 7 low).

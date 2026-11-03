---
title: 'Story 11.8 — Sync: Fetch, Push sheet, remote-change poll and badge, the clone form'
type: 'feature'
created: '2026-11-03'
status: 'done'
baseline_revision: '42dfdbe3bbb8a1eafa5ea6d5fbffe7abb436a22c'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/design_system/components/push/PushDialog.prompt.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The poll's real `remoteChanges('origin')` has not been run in the running app (Marionette), and the Sync island and Push sheet have not been compared with the DS cards there.
    evidence: |-
      Ralph's 2026-10-21 note asks for one live run because `dart test` reaps the poll's git child; every sync test uses FakeRemoteSync. The unattended run had no project with a moved remote bookmark at hand.
    location: >-
      app/lib/src/features/sync/sync_model.dart (poll), app/lib/src/features/sync/push_sheet.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The top bar's ACTION sync island holds only Reload: Fetch and Push are missing, nothing polls the remotes (the 11.7 interval is stored but unread), the menu bar's Change › Fetch / Push… are grey, and the clone form still runs the CLI's destination rules app-side with no progress or Cancel. Open deferrals I1–I5 name this story.

**Approach:** A `features/sync` slice over a small `RemoteSync` port (worker adapter + test fake): a per-repository `SyncModel` (fetch with the CLI's default remotes, progress, `syncing` dot, toasts with Retry, the read-only poll with badge, enable rules, stale) and a `PushSheetModel` + `PushSheet` (ZsSheet) built from `gitPush(dryRun: true)` plans. Fetch and Push join the sync island beside Reload, the menu items get handlers, and the clone form shows live progress and Cancel through the verb's own destination rules.

## Boundaries & Constraints

**Always:**
- CLI parity (decision 16.44, FR-JJ-17): fetch passes no remote (`DefaultFetchRemotes`, 9.30); the sheet's preselection is the bare `jj git push` dry-run, never derived app-side; every command string shown is a real v0.46.0 command, shell-quoted, `exact:` for hand-named refs; jj's messages, hints, action words ("move forward from … to …") and "Nothing changed." verbatim (`// l10n-ignore`).
- Hand-picked rows are tickable only when `explicitRefusal == null` on every chosen remote and every rejection reason is allowed; refused refs in the preselection/bulk show "skipped" with jj's reason + hint and never change the command. Allow chips map "has no description" → `--allow-empty-description`, "has conflicts" → `--allow-conflicts`, "is private" → `--allow-private`; "has no author and/or committer set" has no chip. Dry-runs run without allow flags (so reasons stay visible); a flag is written when ticked and a sent ref/the ticked change needs it, also on the bare command.
- Nothing pushes before the sheet's Push; while pushing Esc/Cancel are inert; a scrim click does nothing; the sheet holds the shell's calm while open (I1).
- The poll: interval from `ProjectEntry.remotePoll` (off · 5 · 15 min) plus once when Zanshin becomes the active app (`AppLifecycleListener.onResume`); polls each of `gitFetchRemotes()` via `remoteChanges`; read-only; no special auth environment; a failed tick is silent (no toast, badge unchanged) and the next tick retries; ticks never overlap; no poll and no badge while stale; badge = number of bookmark changes (tags excluded), tooltip names them per remote; a successful fetch clears it (I5).
- Stale working copy: Fetch and Push disabled with "Working copy is stale" (`staleTitle`).
- UI strings in `app_en.arb`; Zs controls only; tests use fake ports, never a real jj call.

**Never:** Pull; tracking verbs; credential prompts or `GIT_TERMINAL_PROMPT`/`BatchMode` handling; pushing remote by remote or any command sequence (I4 is a warning, the verb keeps the CLI's behaviour); `-r`/`-o` in the sheet; a timed fetch; Rust changes (all verbs shipped).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fetch ok | fetch remotes `[origin]`, result with 2 changed bookmarks | button busy (spinner, progress % in tooltip), dot `syncing`, then success toast "Fetched from origin · 2 bookmarks changed"; badge cleared; dot back to the reading | — |
| Fetch nothing | result `mutation`-only, no changes | toast jj's "Nothing changed." | — |
| Fetch fails | `jj.network_error` | error toast (alert, stays) with jj's text + Retry; badge kept; nothing else changes | Retry reruns fetch |
| No remote | `gitFetchRemotes()`/`remotes()` empty or `jj.not_a_git_repo` | Fetch / Push disabled | — |
| Poll tick | interval 5 min, `remoteChanges('origin')` → main moved, x created, tag v1 | badge 2, tooltip "main, x changed on origin" | tick error → silent, badge unchanged |
| Overlap | tick fires while one runs | second tick skipped | — |
| Push preselection | bare plan: `main` push, `wip` skip (no description) | `main` ticked, `wip` "skipped" + reason/hint; footer `jj git push` | — |
| Hand-pick refused | row with `explicitRefusal` | checkbox disabled with jj's reason | — |
| Allow | change @ rejected "has no description" | inline Allow; ticking change adds `--allow-empty-description` | — |
| Several remotes, one empty | origin has refs, upstream none | warn line naming upstream (I4) | Push stays enabled |
| Push result partial | origin pushed, upstream network error, recorded | per-remote lines, error names upstream and says origin got its refs; "recorded, Undo works" | Done closes; toast with Undo |
| Clone | url + empty/missing dest | progress bar + Cancel in the form; Cancel → `jj.cancelled` silently ends | `jj.destination_not_empty` → jj's refusal text |

</intent-contract>

## Code Map

- `packages/zanshin_core/lib/zanshin_core.dart:61` -- add `GitRefUpdate`, `GitRefUpdateKind` to git.dart's `show` (item 6). Push/fetch/remotes types are exported already.
- `packages/zanshin_core/lib/src/worker/handle.dart` -- `gitFetch` :807 (`NetworkOperation<GitFetchResult>`), `remoteChanges(String)` :842, `gitPush({remotes, bookmarks, tags, all, tracked, deleted, allowEmptyDescription, allowPrivate, allowConflicts, changes, named, dryRun})` :884, `gitFetchRemotes()` :397, `gitPushRemotes()` :374, `remotes()` :355. Read-only.
- `packages/zanshin_core/lib/src/ffi/push.dart` -- `GitPushResult` (remotes sorted, createdBookmarks, nothingChanged, recorded, description, newOpId, failure), `PushRemote` (refs, finished, error), `PushRef` (kind, name, action, path push/skip/abort, refusal, explicitRefusal, rejection.reasons, status, statusReason). Dry-run reports aborts as data; it never reports signing.
- `packages/zanshin_core/lib/src/worker/network_operation.dart` -- `NetworkOperation(result:, progress:, cancel:)`; fakes construct it.
- `packages/zanshin_ui/lib/src/controls/zs_button.dart:316` -- `ZsIconButton`: add `busy` (spinner in the icon slot, `ZsControlCore(busy:)`, as `ZsButton` :244).
- `packages/zanshin_ui/lib/src/materials/zs_sheet.dart:39` -- `ZsSheet(semanticLabel, onCancel, child, busy, closing, onClosed, initialFocus, width)`; shown via `OverlayPortal` like `GraphNameSheet` (`app/lib/src/features/graph/graph_card_menu.dart:726-917`).
- `packages/zanshin_ui/lib/src/controls/` -- `ZsCheckbox`, `ZsChip`, `ZsTextField(error:)`, `ZsButton(busy)`, `ZsProgressBar(value,label)`, `ZsTooltip(message, cmd)`, `ZsToast`/`ZsToastAction`.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart:125` -- `ProjectStatus`: add `syncing` (I2); `RemotePollSetting` :111. Regenerate `.g.dart` (build_runner) if the enum map is generated.
- `app/lib/src/features/projects/project_status_style.dart` -- map `syncing` → `colors.projSyncing` (exists, zs_colors.dart:966), label `statusSyncing`.
- `app/lib/src/features/projects/project_session.dart` -- `_clone` :361-397 (remove the destination port; keep `cloneDestinationNotEmpty` text, map `jj.destination_not_empty` → `ProjectRefused(cloneDestinationNotEmpty)`, `jj.cancelled` → `ProjectSwitchCancelled`); `refresh` :528, `_record` :508 (keep `syncing` while a sync runs); add `syncing(run)`.
- `app/lib/src/features/projects/project_repos.dart:28` / `worker_project_repos.dart:56` -- `clone` takes an optional `CloneTicket` (progress + cancel) wired to the `NetworkOperation`.
- `app/lib/src/features/projects/projects_window.dart:717-737, :950-1010` -- clone form: progress bar + Cancel while busy; Cancel calls the ticket.
- `app/test/helpers/fake_projects.dart` -- `FakeProjectRepos.clone` (cloneGate) follows the new signature.
- `app/lib/src/features/home/project_graph_host.dart` -- `_Graph` (per repo) creates the `SyncModel`; `ProjectGraphSlots.reload` becomes `sync` (Reload + Fetch + Push island); binding publishes sync to the menu; mounts the Push sheet host.
- `app/lib/src/features/graph/graph_controls.dart:436` -- `GraphReloadIsland`: becomes the island holding Reload plus the sync buttons (or a new `SyncIsland` in `features/sync`).
- `app/lib/src/features/home/home_page.dart:110` -- `syncGroup: graph.sync`.
- `app/lib/src/features/shell/app_menu.dart:50, :525-531` -- `GraphMenuBinding.sync`; Change › Fetch / Push… handlers; listen to the sync model.
- `app/lib/src/features/shell/shell_toast.dart` -- `ShellToastEntry`, `toastWithWarnings`; `graph_toasts.dart:96-115` (error + Retry pattern).
- `app/lib/src/features/graph/graph_view_model.dart` -- `stale`, `undoOperation(head, GraphLoggedOperation(id, description))` for the push toast's Undo (its outcome toast carries the undo-push warning and Redo); `actionTarget` (selection else @) for the sheet's change row; `AppMenuModel.targetName` for naming.
- `app/lib/src/features/shell/shell_controller.dart:276` -- `openSurface()` → `CalmHold` (release on close/dispose).
- `app/lib/src/features/projects/projects_environment.dart` -- `configList(name:, workspaceRoot:)` reads `git.sign-on-push` for the sheet's signing note.
- `app/lib/l10n/app_en.arb` -- new strings; `flutter gen-l10n` in `app/`.
- `app/widgetbook/folders/` -- a Sync island + Push sheet use case; `app/test/widgetbook/ds_manifest_parity_test.dart:84` drop `'PushDialog': '11.8'` and map it.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- export `GitRefUpdate`, `GitRefUpdateKind`.
- `packages/zanshin_ui/lib/src/controls/zs_button.dart` + test -- `ZsIconButton.busy`.
- `packages/zanshin_settings/.../projects_settings.dart` (+ generated) -- `ProjectStatus.syncing`; style + ARB label.
- `app/lib/src/features/sync/remote_sync.dart` -- `RemoteSync` port (`fetchRemotes`, `pushRemotes`, `remoteNames`, `fetch()`, `remoteChanges(remote)`, `push(PushRequest)`) and `RepoRemoteSync` over `RepoHandle`; `PushRequest` value (remotes?, mode, bookmarks, tags, changes, named, allow flags, dryRun) with `command` rendering.
- `app/lib/src/features/sync/sync_model.dart` -- `SyncModel` (fetch, busy/progress, badge, poll timer + resume poll, no overlap, silent failure, stale gating, enable rules, toasts, push sheet open state).
- `app/lib/src/features/sync/push_sheet_model.dart` -- plans, rows, selection, change row, allow flags, command, I4 warning, push run and done state.
- `app/lib/src/features/sync/sync_island.dart`, `push_sheet.dart` -- widgets; the sheet holds calm.
- `app/lib/src/features/home/project_graph_host.dart`, `home_page.dart`, `graph_controls.dart`, `shell/app_menu.dart` -- wiring.
- `app/lib/src/features/projects/{project_session,project_repos,worker_project_repos,projects_window}.dart`, `app/test/helpers/fake_projects.dart` -- clone form (I3).
- `app/test/features/sync/*_test.dart` + updates to existing tests -- the witnesses below with a `FakeRemoteSync`.
- `app/widgetbook/` + catalogue tests -- use cases; DS parity map.

**Acceptance Criteria:**
- Given a project with fetch remotes, when Fetch is pressed, then `fetch()` runs once with the default remotes, the button is busy and the dot reads `syncing` until the result, then the result toast shows; given a failure, then an error toast with Retry shows and nothing else changes.
- Given the poll at 5 min, when time passes, then `remoteChanges` runs per fetch remote, never a mutating call, and the badge shows the bookmark count; given Off, then no tick runs; given a stale working copy, then no tick runs and the badge hides; given a failing tick, then no toast shows and the next tick runs; given a running tick, then a new tick is skipped.
- Given Push pressed (button, menu ⇧⌘P), then the sheet opens and no non-dry-run push runs before its Push; the witnesses of epics.md 11.8 (preselection with skipped ref, refused hand-pick untickable, allow flag on the bare command, hand-pick deactivates "As jj git push", tag row, two remotes with per-remote lines, change row follows the selection, undescribed change with inline Allow, two reasons chip row, nothing-exported result shows no Undo sentence, network error on the second remote names it and the first's refs, Esc while pushing and a scrim click do nothing) pass.
- Given the sheet is open, then the shell's calm is held; when it closes or unmounts, then it is released (I1).
- Given the Fetch tooltip, then it shows no shortcut; given a stale working copy, then both buttons are disabled with "Working copy is stale".
- Given a clone, when it runs, then the form shows progress and Cancel; Cancel ends it with no failure notice; the session no longer creates or removes folders itself (I3).

## Spec Change Log

## Review Triage Log

### 2026-11-03 — Review pass
- verdicts: 41 findings — high 0, medium 9, low 21, false 6, maybe-false 5
- findings:
  - `[medium]` `[patch]` (blind) a poll started before a fetch writes pre-fetch changes back after it — poll drops its result when a fetch started since (serial), with a test.
  - `[low]` `[reject]` (blind) the poll runs while the Push sheet is open; the badge is not re-polled after a push — read-only calls overlap harmlessly; the next tick corrects the badge; guarding adds branches for a rare, self-healing state.
  - `[medium]` `[patch]` (blind) dispose() dismisses only the last toast, so an older Retry/Undo reaches a disposed model — fetch() and _undo() return when disposed.
  - `[low]` `[reject]` (blind) Fetch/Push disabled with no reason while the sheet is open or a fetch runs — the Push button shows active while its sheet is open and Fetch shows busy; a reason line would add branches for a momentary state.
  - `[low]` `[patch]` (blind) syncing() leaves the count raised when the first recordState throws — increment and first write moved inside the try.
  - `[false]` `[reject]` (blind) CloneTicket leaks its progress subscription — `NetworkOperation.progress` closes when the result completes (network_operation.dart doc), so the subscription ends with the call.
  - `[low]` `[patch]` (blind) Push sheet row identifiers collide for a bookmark and a tag of one name — identifiers carry the kind.
  - `[maybe-false]` `[reject]` (blind) the sheet sets the name controller's text during build — the EditableText below is built later in the same frame; widget tests pump it without an assertion; would only be low if real.
  - `[low]` `[reject]` (blind) every keystroke in the name field starts a dry run; `request` recomputed per build — dry runs are local (no network until the real push, push.rs:1920) and the serial drops stale ones; caching adds state for no observed cost.
  - `[low]` `[reject]` (blind) ticking the change row drops refs that cannot be named — CLI parity: `--change` is an explicit mode, the dropped rows untick visibly with jj's refusal.
  - `[medium]` `[patch]` (blind) a default push remote missing from the remotes is silently dropped, sending an explicit `--remote` list where the CLI refuses — load() keeps the defaults (remotes null) when one is missing, so jj's refusal shows; test added.
  - `[low]` `[reject]` (blind) the fetch toast counts only bookmarks; "Nothing changed." hard-coded — "Nothing changed." is jj's own text (cli_util.rs:2852); a tag-only fetch is rare and still says "Fetched from …".
  - `[low]` `[reject]` (blind) the Fetch tooltip has no length bound — rare (a long absence on a busy upstream); capping adds formatting branches.
  - `[maybe-false]` `[reject]` (blind) load/_replan catch only ZanshinFfiException, so a StateError leaves the sheet loading — a closed handle disposes the sheet with its graph set; would be low.
  - `[low]` `[patch]` (blind) missing tests (race, poll during sheet, toast cleanup, resume, same-name rows, recordState throw) — the race, resume and same-name cases are added with their patches; the rest belong to rejected rows.
  - `[medium]` `[patch]` (edge) poll/fetch race — same root cause as the blind row; same fix.
  - `[low]` `[patch]` (edge) badge stays while the poll is Off — `remoteChanges` empty while Off; test extended.
  - `[low]` `[patch]` (edge) recordState throw leaves the count raised — same as the blind row.
  - `[low]` `[reject]` (edge) a crash mid-sync persists `syncing` for that project — only the open project syncs and reopening it reads it again; a fix needs load-time mapping for a rare crash.
  - `[false]` `[reject]` (edge) two overlapping syncing() calls restore syncing — Fetch and Push exclude each other (`canFetch`/`canPush` check `_push`/`_fetching`), so one path never has two runs.
  - `[maybe-false]` `[reject]` (edge) PushSheetHost unmounts while a sheet is open and _push stays set — host and SyncModel share the graph set's lifetime (`_Graph`), so the model goes with the host; would be low.
  - `[low]` `[reject]` (edge) an Allow chip disappears once set, so it cannot be revoked — unticking the row stops the flag being written (flags are written only for sent refs); a revocable chip adds state.
  - `[low]` `[patch]` (edge) the clone form's Cancel stays enabled after Cancel — rebuilt on the ticket.
  - `[maybe-false]` `[reject]` (edge) a progress stream error is unhandled — the stream is the worker's event stream filtered by handle, which emits no errors; would be low.
  - `[medium]` `[patch]` (gap) `RepoRemoteSync` has no test — real-worker test added.
  - `[medium]` `[patch]` (gap) `WorkerProjectRepos.clone` never attaches the ticket in a test — real-worker clone-with-ticket test added.
  - `[medium]` `[patch]` (gap) host wiring of SyncModel (syncing dot, poll setting, resume poll, change target) untested — host tests added.
  - `[low]` `[patch]` (gap) switched-away-mid-sync branch untested — session test added.
  - `[low]` `[patch]` (gap) a failed composed dry run disabling Push untested — model test added.
  - `[medium]` `[patch]` (gap) push toast and its Undo barely checked — sync_model push group added.
  - `[low]` `[patch]` (gap) silent stale fetch refusal untested — test added.
  - `[medium]` `[defer]` (intent) the running-app witness of `remoteChanges('origin')` (Marionette) is not done — needs the app running with a remote; recorded in deferred.
  - `[false]` `[reject]` (intent) I1 tooltips take no calm hold — tooltips are hover surfaces that hide on pointer movement; the Fetch remote menu no longer exists (9.30, no remote passed); the sheet holds calm and is witnessed.
  - `[low]` `[patch]` (intent) the poll on activation is untested — the host's resume test covers it.
  - `[low]` `[patch]` (intent) "the change row follows the selection" not witnessed — host test covers it.
  - `[false]` `[reject]` (intent) undoing a push's warning and Redo not witnessed in sync — they come from `GraphViewModel.undoOperation`'s outcome toast (graph_toasts.dart, `toastWithWarnings`, tested there); the sync test now witnesses the call.
  - `[low]` `[patch]` (intent) keyboard rules not witnessed — focus on Push and ↩ (not from the name field) tests added; Tab trap, Esc and focus return come from ZsSheet's own tests.
  - `[false]` `[reject]` (intent) the inactive-window neutral badge and "Fetch, 3" label not in the diff — both come from `ZsIconButton`/`ZsBadge` (zs_button.dart:399, 11.11).
  - `[maybe-false]` `[reject]` (intent) Fetch tooltip reads "Fetch from origin" + cmd `jj git fetch` instead of "Fetch — jj git fetch · origin" — same content in the DS tooltip layout (message + mono cmd line, Tooltip.prompt.md); design is inspiration; low if real.
  - `[low]` `[reject]` (intent) Push tooltip "Choose what to push to origin" + `jj git push` — follows DS chrome.jsx:104 ("choose what jj git push sends"), which the story's DS round superseded the base wording with.
  - `[false]` `[reject]` (intent) the island keeps Reload beside Fetch and Push — 10.12 put Reload in this island and said "Fetch and Push join this island" (graph_controls.dart doc); the story removes nothing.

## Design Notes

- **Syncing dot** is transient: `ProjectSession.syncing(run)` records `syncing` for the open project and, while the run lasts, `_record` keeps it; the finishing `refresh()` writes the real reading back.
- **Push rows** = the union of the dry-runs bare, `--tracked`, `--all`, `--deleted` for the chosen remotes (open + on remote change), keyed by kind+name, in plan order. A bulk chip sets the mode (its plan is the backend's confirmation); a hand toggle switches to custom with the current checked set. Custom command names refs; a composed dry-run checks every custom/change command ("Checked with --dry-run"); its error disables Push.
- **I4:** the sheet warns, it does not split the push. **Push Undo** goes through `GraphViewModel.undoOperation` so the undo toast carries jj's warning and Redo (10.23, 9.39).
- Claude's proposals: Fetch's progress shows as the busy spinner and "Fetching… N%" in its tooltip; the fetch toast counts changed bookmarks; "Fetch" in the done state for a lease failure is left out (the toast's Fetch button covers it).

## Verification

**Commands:**
- `flutter test` in `app/`, `packages/zanshin_ui`, `packages/zanshin_settings`; `dart test` scope of zanshin_core unaffected beyond exports -- expected: pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed .` per touched package -- expected: clean.
- `flutter gen-l10n` in `app/` -- generated files committed.
- No full gate (`cargo make test`), per the story loop's rule.

**Manual checks:**
- The poll's `remoteChanges('origin')` in the running app via Marionette (dart test reaps the git child); the sheet and island against the DS cards.

**Verification notes (2026-11-03, story-loop gate rule: no `cargo make test`):**
- `dart analyze --fatal-infos --fatal-warnings`: clean in `app`, `packages/zanshin_ui`, `packages/zanshin_settings`, `packages/zanshin_core`.
- `dart format --set-exit-if-changed`: 0 changes in all four.
- `flutter test` in `packages/zanshin_ui`: 445 passed; `packages/zanshin_settings`: 43 passed.
- `flutter test` in `app` with `XDG_CONFIG_HOME=target/test-xdg-config` (needed by the real-worker suites): 1963 passed, 1 failed — `repo_graph_source_test.dart` "content maps every field…" expects a non-empty author, which the pinned XDG dir lacks outside cargo make; it passes unpinned (8/8) and the story touches no code it reads. `worker_project_repos_test.dart` (34) and the new `remote_sync_test.dart` pass pinned.
- Not run: the Marionette checks (deferred), the Rust suites and the parity oracle (no Rust or verb changed), `cargo make codegen` (no FFI or schema change).

## Auto Run Result

Status: done (commit `3516be53cfbaf698d92a4437eac3407c0fd0ad73`, code; this spec and the ledgers in the following commit).

**Summary.** A `features/sync` slice over a `RemoteSync` port: `SyncModel` (Fetch with the CLI's default remotes, busy/progress, `syncing` dot, result toast or error toast with Retry; the read-only poll at the project's interval and on app resume with the badge; enable rules and stale gating; the push toast with Undo through `GraphViewModel.undoOperation`), `PushSheetModel` + `PushSheet` (dry-run plans for bare/`--tracked`/`--all`/`--deleted`, skipped refs with jj's reasons, explicit refusals, Allow flags, the change row, a composed dry-run check, the I4 warning, signing note, per-remote results), `SyncIsland` (Reload, Fetch, Push…), the menu's Change › Fetch / Push… ⇧⌘P, `ProjectStatus.syncing`, `ZsIconButton.busy`, and the clone form's progress and Cancel through `CloneTicket` with the session's destination port removed.

**Files.**
- `app/lib/src/features/sync/{remote_sync,sync_model,push_sheet_model,push_sheet,sync_island}.dart` — the new slice.
- `app/lib/src/features/home/{project_graph_host,home_page}.dart` — per-repo `SyncModel`, resume poll, sheet host, `slots.sync`.
- `app/lib/src/features/graph/graph_controls.dart` — `GraphReloadIsland` removed (now in `SyncIsland`); `graph_ports.dart` — `jjCommand`/`exactNamePattern` public for the footer.
- `app/lib/src/features/shell/app_menu.dart` — `GraphMenuBinding.sync`, Fetch / Push… handlers.
- `app/lib/src/features/projects/{project_session,project_repos,worker_project_repos,projects_window,project_status_style}.dart` — `syncing()`, `CloneTicket`, clone form progress/Cancel, destination port removed, `syncing` style.
- `packages/zanshin_settings/.../projects_settings{,.g}.dart` — `ProjectStatus.syncing`; `packages/zanshin_ui/.../zs_button.dart` — `ZsIconButton.busy`; `packages/zanshin_core/lib/zanshin_core.dart` — `GitRefUpdate(Kind)` exported.
- `app/lib/l10n/*` — strings; `app/widgetbook/folders/sync.dart` + catalogue/parity tests — the Sync folder, PushDialog mapped; `app/integration_test/glass_profile.dart` — `SyncIsland`.
- Tests: `app/test/features/sync/*` (model, sheet, real-worker `remote_sync_test.dart`), host, session, window, menu, worker clone, settings and zs_button tests; `app/test/helpers/fake_remote_sync.dart`.

**Deferral items I1–I5.**
- I1 — fixed (`3516be53cfbaf698d92a4437eac3407c0fd0ad73`): the Push sheet holds the shell's calm while open and releases it on close and unmount (`PushSheetHost`, witnessed in `push_sheet_test`). With 9.30 Fetch passes no remote, so the Fetch remote menu no longer exists; tooltips are hover surfaces and take no hold; no slot needed `ZsSelect` callbacks.
- I2 — fixed (`3516be53cfbaf698d92a4437eac3407c0fd0ad73`): `ProjectStatus.syncing` with `--proj-syncing`; the dot reads syncing during a fetch or push (session and host tests).
- I3 — fixed (`3516be53cfbaf698d92a4437eac3407c0fd0ad73`): `ProjectSession.clone`'s destination port is gone (`jj.destination_not_empty` → jj's refusal text, `jj.cancelled` → no notice); the form shows live progress and Cancel. Ralph's confirmation of how Cancel identifies git stays his (not this story's).
- I4 — fixed (`3516be53cfbaf698d92a4437eac3407c0fd0ad73`): settled as a warning — with several chosen remotes the sheet names those that get nothing from the composed dry run and keeps Push enabled; the verb keeps the CLI's behaviour and no command is split.
- I5 — fixed (`3516be53cfbaf698d92a4437eac3407c0fd0ad73`): the poll uses no special auth environment; a failed tick is silent and leaves the badge, the next tick retries, ticks never overlap (witnessed in `sync_model_test`).

**Review.** 41 findings (high 0, medium 9, low 21, false 6, maybe-false 5): 20 rows patched in one round (poll/fetch race, disposed Retry/Undo, badge while Off, `syncing()` balance, row identifiers with kind, clone Cancel greying, missing default push remote → jj's refusal, plus tests: real-worker `RepoRemoteSync` and clone-with-ticket, host wiring incl. resume and change row, switched-away sync, failed dry-run check, push toast and Undo, stale fetch, keyboard); 1 deferred (running-app Marionette witness and DS comparison, medium); 20 rejected with reasons in the triage log.

**Follow-up review recommended: true.** Patched: 7 medium entries, 13 low. Unverified risk: the sheet's real `jj git push` (non-dry-run) path through `RepoRemoteSync` and the live poll are exercised only with fakes and dry runs; the Marionette check is deferred.

**Residual risks.** The Push sheet's look is not compared with the DS card; the change row's name field re-runs a local dry run per keystroke; a crash during a sync leaves that project's stored dot on syncing until it is next read.

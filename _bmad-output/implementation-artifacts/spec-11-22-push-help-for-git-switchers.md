---
title: 'Story 11.22 — Push help for Git switchers: fix-it actions, plain explanations, post-conversion tracking hint, refusals in every mode, change ids next to commit ids'
type: 'feature'
created: '2026-11-04'
status: 'done'
baseline_revision: '9d9b23d1cacc52079897eace2793f2187c72215f'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A new remote tag refused as "Refusing to create new remote tag X@R" gets no fix-it, though jj's hint names `jj tag track X@R`.
    evidence: |-
      Zanshin has no `jj tag track` verb (only `RepoHandle.bookmarkTrack`); `_fixIt` in push_sheet.dart offers Track for bookmarks only.
    location: >-
      app/lib/src/features/sync/push_sheet.dart (_fixIt); crates/zanshin-jj/src/push.rs (classify, NewRemote for tags)
    severity: low
  - summary: >-
      The Marionette check of the Push sheet's help lines, fix-its and the post-conversion toast against the DS cards was not done in this unattended run.
    evidence: |-
      The house rule (feedback-verify-ui-with-marionette) needs the running catalogue/app; this run allows only synchronous commands and widget tests cover the behavior only.
    location: >-
      app/widgetbook/folders/sync.dart ("Git switcher" use case); app/lib/src/features/home/home_page.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The Push sheet shows jj's refusals verbatim with no fix and no explanation (a Git switcher's `main` is skipped as "Non-tracking remote bookmark main@origin exists", @ is refused for "no description"); a row's explicit refusal is hidden outside the custom mode so warnings seem to jump; action texts name commits by commit id only; and Zanshin's conversion omits the CLI's post-`jj git init` list of untracked remote bookmarks.

**Approach:** The bridge sends a refusal kind (`PushRefusal.kind`), commit-check reason kinds and a working-copy flag (`PushCommitRejection`), the change ids + unique-prefix lengths of `before`/`after` (`PushRef`), and the conversion's trackable remote bookmarks (`CreationOutcome` → `RepoHandle` table). The sheet shows a plain explanation per kind under jj's text, a fix-it chip where jj's hint names a command (Track / Fetch / Push with --deleted), the explicit refusal in every mode plus a quieter skip line, and change ids before dimmed commit ids. The project window's "Opened" toast after a conversion names the untracked remote bookmarks with Track / Track all.

## Boundaries & Constraints

**Always:** jj's own text stays verbatim; explanations are keyed by the bridge's kinds, never by parsing jj's text (also replaces `PushAllow.of`'s string match); fix-its run existing verbs (9.11 `bookmarkTrack`, 11.8 `fetch`, the sheet's `--deleted` mode) and the sheet then re-plans; commands shown are real and shell-quoted (`jjCommand`); new wire fields are APPENDED to FlatBuffers tables (schema + `cargo make codegen`), docs/ffi-abi.md updated; the trackable list is computed exactly like the CLI's `print_trackable_remote_bookmarks` (`cli/src/commands/git/init.rs:391-421` @ v0.47.0: local-present bookmarks × untracked remote refs, view order, `RemoteRefSymbol` display) after the External arm completes, for both conversions and `Repo::init` over an existing `.git`; all user text through ARB.

**Never:** a jj tutorial or onboarding; changing auto-track defaults; explanations outside the Push sheet and the post-conversion toast; a third sheet; a tag-track verb (no `jj tag track` wrapper exists in Zanshin — tag refusals get an explanation, no fix-it); deriving ids from jj's strings.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Non-tracking remote | `main` local, `main@origin` untracked, bare mode | row shows jj's refusal + explanation + chip "Track main@origin" (tooltip `jj bookmark track main@origin`); press → `bookmarkTrack(['main@origin'])`, sheet re-plans | track error → jj's text as the row's error line, sheet stays ready |
| New local bookmark, bare mode | not tracked anywhere | quiet skip line "… — tick it to push it anyway" + Track chip; ticking it does not change other rows' lines | — |
| Explicit refusal in bare mode | row with non-tracking remote not in bare plan | its explicit refusal shows in bare mode already (I3) | — |
| @ no description | change row | jj's rejection + @ explanation (working copy) + Allow chip | — |
| Remote conflicted | `main@origin` conflicted | explanation + "Fetch" chip → `fetch()` then re-plan | — |
| Deleted bookmark, bare | skip "Refusing to push deleted bookmark" | explanation + "Push with --deleted" chip → mode `deleted` | — |
| Action ids | `add to 2d0dbb65bad8` | "add to " + change id (bold prefix) + dimmed `2d0dbb65bad8` | change id absent → text as is |
| Conversion | Git repo with `main` + untracked `origin/main` | `trackableRemoteBookmarks == ['main@origin']`; toast "… · main@origin isn't tracked" with Track | empty list → toast unchanged |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/push.rs` -- `PushRefusal` (:136), `classify` (:342, every refusal; add `kind`), `PushCommitRejection` (:146) + `CommitsValidator::validate` (:547, reasons at :559-576) + `Rejected::skipped/aborted`, `PushRef` (:182), `render_row` (:1799) / `render` (:1841, callers :1905/:1915/:1934 — pass `ctx.template_startup.id_prefix_context()` for prefix lengths; commit_meta.rs:217-222 shows the prefix calls). Working-copy commit: `repo.view().get_wc_commit_id(workspace_name)`.
- `crates/zanshin-jj/src/convert.rs` -- `ConversionReport` (:143), `into_outcome` (:158), `external_arm` (:662, compute the list at the end on success), `init_over_git_dir`/`OverGitDir` (:573) for `Repo::init`'s path (`creation.rs:263-271`).
- `crates/zanshin-jj/src/repo.rs:147` -- `CreationOutcome` gains `trackable_remote_bookmarks: Vec<String>`; constructors at repo.rs:4915, creation.rs:158/:333, zanshin-ffi repo.rs:2370/2399, api_stability.rs:2575.
- `crates/zanshin-jj/src/lib.rs` -- re-export new enums.
- `schemas/envelope.fbs` -- `PushRefusal` (:2340), `PushCommitRejection` (:2348), `PushRef` (:2362), new enums `PushRefusalKind`, `PushRejectReason`; `RepoHandle` (:1545) gains `trackable_remote_bookmarks: [string]`.
- `crates/zanshin-ffi/src/push.rs` -- serializes the push outcome; `crates/zanshin-ffi/src/envelope.rs:817` `ok_repo_handle` + `crates/zanshin-ffi/src/repo.rs:711` `creation_envelope_for`.
- `packages/zanshin_core/lib/src/ffi/push.dart` -- `PushRefusal`, `PushCommitRejection`, `PushRef` Dart types + decoders; `packages/zanshin_core/lib/src/ffi/precondition.dart:171` `decodeCreationReportInternal`; `packages/zanshin_core/lib/src/worker/handle.dart:2877` `CreatedRepoHandle`; `packages/zanshin_core/lib/zanshin_core.dart` export list.
- `app/lib/src/features/sync/remote_sync.dart` -- `RemoteSync` gains `track(List<String> symbols)`; `RepoRemoteSync` → `handle.bookmarkTrack`.
- `app/lib/src/features/sync/push_sheet_model.dart` -- `PushAllow.of` → by reason kind; `explicitRefusalOf` with its remote; new `track(symbol)`, `fetchAndReplan()`, fix-it busy/error state.
- `app/lib/src/features/sync/push_sheet.dart:351-397` -- `_row` (I3 at :364/:387), `_Sub`, `_RemoteLine` (ids), `_changeRow`; help + fix-it widgets.
- `app/lib/src/features/projects/{project_repos.dart,worker_project_repos.dart,project_session.dart}` -- carry the trackable list from `CreatedRepoHandle` through `ProjectCreation` → `ProjectOpenReport`.
- `app/lib/src/features/home/home_page.dart:164-220` -- `_OpenReportToast`: warn tone + Track / Track all when the list is non-empty; runs `bookmarkTrack` on the session's open handle.
- `app/lib/l10n/app_en.arb` -- new strings (`flutter gen-l10n`).
- `app/test/helpers/fake_remote_sync.dart`, `app/test/features/sync/push_sheet_test.dart`, `push_sheet_model_test.dart`, `app/widgetbook/folders/sync.dart` -- fakes and witnesses.
- Design (done in planning): DS `components/push/{PushDialog.jsx,push.css,PushDialog.prompt.md}`, prototype `design/{push.css,push-dialog.jsx}`, `design/DESIGN-SYSTEM-SYNC.md` #19.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/push.rs` -- add `PushRefusalKind {LocalConflicted, RemoteConflicted, RemoteUntracked, NewRemote, Deleted}` on `PushRefusal.kind`; `PushRejectReason {NoDescription, NoAuthor, Conflicts, Private}` as `PushCommitRejection.reason_kinds` (parallel to `reasons`) and `working_copy: bool` (the rejected commit is the workspace's @); `PushRef.{before,after}_change_id: Option<String>` + `{before,after}_change_prefix_len: u32`; inline unit tests for kinds -- bridge kinds, not text.
- `crates/zanshin-jj/src/convert.rs`, `repo.rs`, `creation.rs` -- `trackable_remote_bookmarks` on `CreationOutcome` (CLI order and filter), set on success of both conversions and init-over-`.git`; empty for clone/open/native init.
- `crates/zanshin-jj/tests/it/` -- push test: refusal kinds, reason kinds, change ids on a ref; convert test: Git repo with `main` + `origin/main` → `["main@origin"]`.
- `crates/zanshin-parity/tests/oracle/` -- compare the conversion's list with the CLI's hint lines (stderr of `jj git init --colocate`), if the oracle harness captures stderr; else a scenario asserting the list against the CLI-derived expectation.
- `schemas/envelope.fbs` + `crates/zanshin-ffi/src/{push.rs,envelope.rs,repo.rs}` -- append the fields/enums; `cargo make codegen`; envelope unit tests.
- `packages/zanshin_core/lib/src/ffi/push.dart`, `precondition.dart`, `worker/handle.dart`, `worker/isolate.dart`, `zanshin_core.dart` -- decode the new fields; `CreatedRepoHandle.trackableRemoteBookmarks`; tests in `packages/zanshin_core/test/ffi/push_test.dart`.
- `docs/ffi-abi.md` -- the new wire values/fields.
- `app/lib/src/features/sync/*` -- explanations per kind, fix-its (Track/Fetch/--deleted), explicit refusal in every mode + quiet skip line, change ids in action lines; `PushAllow` by kind.
- `app/lib/src/features/projects/*`, `home/home_page.dart` -- trackable list → toast with Track / Track all.
- `app/lib/l10n/app_en.arb` -- strings; `flutter gen-l10n`.
- `app/test/...` -- witnesses below; fakes updated; widgetbook use-case updated if it constructs the changed types.

**Acceptance Criteria:**
- Given a skipped `main` with a non-tracking `main@origin`, when the sheet shows, then the row shows jj's text, the explanation and "Track main@origin"; pressing it calls track with `main@origin` on the fake and the re-run dry run lists `main` with `move forward …`.
- Given every refusal kind and reason kind, when its row renders, then its explanation shows (one test per kind).
- Given Ralph's two rows in "As jj git push" (a new local bookmark the bare push skips, one with a non-tracking remote), when the sheet shows, then the second row's refusal is already visible; ticking the first leaves the second row's text unchanged.
- Given a ref with an action, when the row renders, then the change id appears before the dimmed commit id.
- Given a conversion of a Git repo with `main` and `origin/main`, when it completes, then the outcome reports `main@origin` and the project toast offers Track.

## Spec Change Log

## Review Triage Log

### 2026-11-05 — Review pass
- verdicts: 37 findings — high 0, medium 8, low 20, false 9, maybe-false 0 (the intent-alignment divergences are logged as findings)
- findings:
  - Blind Hunter
    - `[medium]` `[patch]` Toast Track reads the handle at press time → may track in another repo after a switch — `_report` now captures the repo; `ProjectRepo.trackBookmarks`.
    - `[low]` `[patch]` Toast Track: null handle / non-FFI error silent — `_track` catches every error and shows `project-toast-track-error`.
    - `[medium]` `[patch]` `_fix` leaves `_fixing` set on a non-FFI error → sheet busy for good — cleared in `finally`; test added.
    - `[low]` `[reject]` Fetch fix-it fetches the default remotes, not the conflicted one — it runs exactly the command jj's hint names (`jj git fetch`); a per-remote fetch would add a parameter beyond the hint.
    - `[low]` `[reject]` `reasonKinds` defaults to `[]` → allow-all for a hand-built rejection — the producer always writes the vector (Rust field is non-optional, FFI test); unlikely in use, fix touches every constructor.
    - `[false]` `[reject]` Absent `PushRefusal.kind` decodes as LocalConflicted — Rust's `kind` is non-optional and always written; FlatBuffers omits only the default value, which then reads back as that same value.
    - `[low]` `[patch]` Fixture `_skipNoDescription` pairs `newRemote` with a no-description skip — removed; the `wip` row keeps only its rejection.
    - `[low]` `[reject]` CLI hint text copied into Dart without an oracle check — jj's words verbatim at v0.47.0; the oracle checks the list; wording drift is a pin-bump re-check, not a defect now.
    - `[low]` `[patch]` Tooltip order differs from the CLI — reordered to the CLI's: other warnings, the hint, then the linked-worktree warning.
    - `[low]` `[reject]` DS help copy and app strings differ in wording; DS lacks tag/deleted variants — design is inspiration (small deviations expected); the DS prompt documents the deleted fix-it.
    - `[low]` `[patch]` Sync #19 promises readme › Push and Toast prompt edits not in the diff — added both (DS edited in place).
    - `[low]` `[reject]` "Push with --deleted" switches the mode and drops hand picks — `--deleted` is a bulk mode in the CLI; the chip's tooltip shows the command the sheet then shows; documented in the DS prompt.
    - `[medium]` `[patch]` Missing tests (toast Track press, fix-it disables Push while pending, before-side change ids with a bold prefix; tag rows) — added (a)–(c); tag rows: their explanations are covered by the per-kind tests.
    - `[false]` `[reject]` Comments cite v0.46.0 next to new code — those are pre-existing comments on unchanged lines.
    - `[false]` `[reject]` `change_of` turns a display lookup into a dry-run failure / adds I/O — `get_commit` of a ref target only fails on a corrupt store, which fails the plan earlier anyway; commits are cached by the store.
  - Edge Case Hunter
    - `[medium]` `[patch]` `_fix` non-FFI error leaves sheet busy — same fix as above.
    - `[low]` `[patch]` `bookmarkTrack` StateError on a closed handle escapes — caught by the `finally`/catch-all changes.
    - `[medium]` `[patch]` Toast Track after a project switch targets the wrong repo — captured repo.
    - `[low]` `[patch]` Unawaited `_track` non-FFI error — catch-all.
    - `[low]` `[reject]` Track success gives no confirmation — the toast dismisses and the graph reloads on the op-heads event; a second toast is polish.
    - `[low]` `[reject]` `reasonKinds` default `[]` → allow-all — as above.
    - `[false]` `[reject]` Decoder reads an absent `reason_kinds` as `[]` — no producer omits it; same as above.
    - `[low]` `[patch]` Stale fix-it error after a re-plan — `_replan` clears it; test added.
    - `[low]` `[reject]` Fetch not on the conflicted remote — as above.
    - `[false]` `[reject]` `change_of` failure fails the dry run — as above.
  - Verification Gap
    - `[medium]` `[patch]` Trackable list never checked across Rust → FFI → Dart handle — `creation_test.dart` converts a real `git clone` through the cdylib and asserts `['main@origin']`.
    - `[medium]` `[patch]` Toast Track action never pressed in a test — `home_page_test` presses Track all (one call, all symbols) and the error path.
    - `[low]` `[patch]` Push not checked disabled while a fix-it runs — Completer-gated model test.
    - `[low]` `[patch]` `_fix` non-FFI error (other finding) — fixed, test with a StateError fetch.
    - `[low]` `[patch]` `_track` narrow catch (other finding) — fixed.
  - Intent Alignment
    - `[medium]` `[patch]` `git.sign-on-push` notice has no explanation (item 3) — `pushHelpSigning` added to the signing note; widget test.
    - `[low]` `[reject]` Post-conversion toast offers Track / Track all, not Track per bookmark (item 4) — design-round decision (sync #19): a toast holds one action; per-bookmark Track is in the Bookmarks panel and the Push sheet.
    - `[low]` `[defer]` A new remote tag gets no fix-it though jj's hint names `jj tag track` — Zanshin has no tag-track verb; needs one (deferred).
    - `[false]` `[reject]` The change row's string refusal has no explanation — that path is an `--change` explicit refusal, which for a new `push-…` bookmark the CLI does not raise (allow_new); its commit check carries the explanation.
    - `[false]` `[reject]` Skip line is generic, not per case — it says when ticking still pushes ("tick it to push it anyway"), which is what item 5 asks.
    - `[false]` `[reject]` Commit ids inside rejection messages stay unchanged (item 6) — those are jj's verbatim messages; item 6 names the `action` texts.
    - `[false]` `[reject]` Prototype shows only the change row's help — the prototype is a click-dummy and the DS is the source of truth; small deviations are expected (design-is-inspiration rule).

## Design Notes

- **Ids in action lines:** jj's `action` text stays verbatim; the UI locates the 12-hex commit ids it already has from `before`/`after` (first 12 chars) inside it and inserts the change id span before each — no meaning is parsed.
- **Fix-it remote:** a row's refusal belongs to a `PushRef` inside a `PushRemote`; the model returns the refusal together with its remote name, and the Track symbol is `remoteBookmarkSymbol(name, remote)`.
- **Toast, not per-bookmark list:** a toast has room for one action (DS sync #19) — Track (one bookmark) or Track all (the CLI's single command); per-bookmark Track stays in the Bookmarks panel and the Push sheet.
- **Skip line wording:** shown quiet only when ticking would push (no explicit refusal and no blocking commit check); otherwise the explicit refusal is the warn line and an identical skip text is not repeated.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib push` / `--test it push` / `--test it convert` -- pass
- `cargo test -p zanshin-ffi` (envelope, push, repo modules) -- pass
- `cargo test -p zanshin-parity --test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed
- `flutter test` + `dart analyze` + `dart format --set-exit-if-changed` in `packages/zanshin_core` and `app` -- pass

**Verification notes (this run; no full gate per the loop's gate rule):**
- `cargo fmt --all --check` -- clean; `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --lib push` -- 8 passed; `cargo test -p zanshin-jj --test it -- push:: convert:: api_stability::` -- 120 passed.
- `cargo test -p zanshin-ffi` -- 239 + 406 passed.
- `cargo test -p zanshin-parity --test oracle` -- 508 passed (incl. `conversion_lists_the_cli_trackable_remote_bookmarks`).
- `cargo make codegen` -- re-run, working tree unchanged (generated files committed).
- `cargo make --allow-private test-core` (zanshin_core suite) -- 1201 passed (before the review patches); after them the implementer ran `creation_test.dart` (11 passed, incl. the real-convert trackable test).
- `cargo make --allow-private test-app` (app suite, pinned env) -- 2067 passed before, 2072 passed after the review patches.
- `dart analyze packages/zanshin_core app` -- no issues; `dart format --set-exit-if-changed` -- 0 changed.
- Not done: Marionette check in the running catalogue (deferred).

## Auto Run Result

Status: done. Blocking condition: none.

**Summary.** The bridge now carries why a ref is refused (`PushRefusal.kind`: LocalConflicted / RemoteConflicted / RemoteUntracked / NewRemote / Deleted), the commit-check reason kinds and whether the rejected commit is @ (`PushCommitRejection.reason_kinds`, `working_copy`), the change ids and unique-prefix lengths of `before`/`after` (`PushRef`), and the conversion's trackable remote bookmarks (`CreationOutcome.trackable_remote_bookmarks` → `RepoHandle.trackable_remote_bookmarks` → `CreatedRepoHandle.trackableRemoteBookmarks`), computed as the CLI's `print_trackable_remote_bookmarks` (`cli/src/commands/git/init.rs:391-421` @ v0.47.0) for both conversions and `Repo::init` over an existing `.git`. The Push sheet shows a plain explanation per kind under jj's verbatim text (the @ variant for an undescribed working copy, the `git.sign-on-push` note too), fix-it chips where jj's hint names a command (Track `name@remote`, Fetch, Push with --deleted) that run the verb and re-plan, the explicit refusal in every mode with the mode's skip as a quiet "tick it to push it anyway" line, and change ids (bold unique prefix) before dimmed commit ids in the action lines. `PushAllow` now keys on the reason kind instead of jj's text. After a conversion the project window's Opened toast (warn tone) names the untracked remote bookmarks with Track / Track all. Design round: DS `components/push/{PushDialog.jsx,push.css,PushDialog.prompt.md}`, `components/overlays/Toast.prompt.md`, `readme.md` › Push; prototype `design/{push.css,push-dialog.jsx}`; `DESIGN-SYSTEM-SYNC.md` #19.

**Files changed (commit 58509d308dd6eabdee152524420588bb944adc6d).**
- `crates/zanshin-jj/src/push.rs` -- refusal/reason kinds, working-copy flag, change ids in `PushRef`, unit tests.
- `crates/zanshin-jj/src/{convert.rs,creation.rs,repo.rs,lib.rs}` -- trackable remote bookmarks on `CreationOutcome`.
- `crates/zanshin-jj/tests/it/{push.rs,convert.rs,api_stability.rs}`, `crates/zanshin-parity/tests/oracle/hints.rs` -- tests; the oracle compares the list with the CLI's hint.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/{push.rs,envelope.rs,repo.rs}`, generated files, `docs/ffi-abi.md` -- wire.
- `packages/zanshin_core/lib/src/{ffi/push.dart,ffi/precondition.dart,worker/handle.dart,worker/isolate.dart}`, `zanshin_core.dart`, tests -- decode and expose.
- `app/lib/src/features/sync/{push_sheet.dart,push_sheet_model.dart,remote_sync.dart}` -- help, fix-its, every-mode refusals, ids.
- `app/lib/src/features/{home/home_page.dart,projects/*}` -- post-conversion toast with Track / Track all; `ProjectRepo.trackBookmarks`.
- `app/lib/l10n/*`, `app/widgetbook/*`, `app/test/**` -- strings, catalogue use case, fakes, witnesses.
- Design system + prototype files listed above.

**Review.** 37 findings (high 0, medium 8, low 20, false 9): 18 rows patched, 1 deferred (plus the Marionette check, deferred by the run itself), 18 rejected with reasons (see the triage log). Patched entries by verdict after grouping: medium 6 (busy sheet after a non-FFI error; toast Track on the wrong repo; missing end-to-end trackable test; missing toast-press test; missing signing explanation; missing tests group), low 5 (fixture kind, tooltip order, DS readme/Toast prompt, stale fix error, toast catch-all). Deferred: no fix-it for a new remote tag (Zanshin has no `jj tag track` verb); the Marionette check. Rejected: Fetch on the default remotes (it runs exactly jj's hint), `reasonKinds`/`kind` defaults (producer always writes them), hint text copied verbatim, DS/app wording deviations, `--deleted` as a mode switch, stale version citations on unchanged lines, `change_of` cost, Track-success feedback, per-bookmark Track in the toast (design decision sync #19), change-row string refusal, generic skip line, jj's verbatim rejection messages, prototype coverage.

**Follow-up review recommended: true.** Six medium entries were patched on this first pass; the specific unverified risk is the real UI: the help lines, fix-it chips and the warn toast were checked only in widget tests, never in the running catalogue against the DS cards (Marionette), and the toast's Track was never pressed against a real repository.

**Deferred-work items.**
- I1 (Push sheet shows refusals without fix or explanation) -- fixed (58509d308dd6eabdee152524420588bb944adc6d).
- I2 (conversion does not report untracked remote bookmarks) -- fixed (58509d308dd6eabdee152524420588bb944adc6d); the parity oracle compares the list with `jj git init --colocate`'s hint.
- I3 (refusal seems to jump rows when a row is ticked) -- fixed (58509d308dd6eabdee152524420588bb944adc6d): the explicit refusal shows in every mode; ticking another row leaves it unchanged (widget test).
- I4 (action texts name commits by commit id only) -- fixed (58509d308dd6eabdee152524420588bb944adc6d): change id first, commit id dimmed.

**Residual risks.** Explanation wording is Claude's (Ralph to review, especially the tag and new-remote texts); a new remote tag has no fix-it; the Track fix-it/ toast write an operation outside the graph's own undo toast (the Undo Timeline has it); the Marionette visual check is still owed.

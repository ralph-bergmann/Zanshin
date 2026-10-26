# Epic 9 Context: jj Operation Surface Build-Out (ADR-0003)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the jj CLI's meaningful operation set as typed, transaction-bounded verb calls in `zanshin-jj` — beyond Epic 6's minimal write set — each composed Rust-side over jj-lib and exposed through `zanshin-ffi` (MCP optional), and close the CLI-parity gaps around them (effective config stack, implicit snapshot/Git import, warnings and hints, no-op gate, undo/redo, templates, network progress/Cancel, creation-path failure contract, pin bumps), guarded by a differential parity oracle against the stock CLI. A user must be able to alternate between the jj CLI and Zanshin on one repo without noticing; the floating client (Epics 10/11) is the main consumer. Stories are backlog-granular; ACs/specs are written when scheduled.

## Stories

- Story 9.0: Bump jj-lib 0.41 → 0.42
- Story 9.0a: Bump jj-lib 0.42 → 0.44
- Story 9.1: Operation-support layer
- Story 9.2: `eval_revset` + `View` reads
- Story 9.3: `restore`, `absorb`
- Story 9.4: `file list`/`show`/`annotate`/`search`
- Story 9.5: `git import`/`export`, `git remote` config
- Story 9.6: `show`, `evolog`, `interdiff`
- Story 9.7: `workspace list`/`root`
- Story 9.8: `bookmark create`/`delete`
- Story 9.9: `metaedit`, `duplicate`, `fix`
- Story 9.10: `next`, `prev`
- Story 9.11: `bookmark set`/`forget`/`track`/`untrack`
- Story 9.12: `op restore`, `op revert`
- Story 9.13: `file chmod`; `workspace forget`/`rename`
- Story 9.14: `simplify-parents`
- Story 9.15: `squash`, `split`
- Story 9.16: `rebase`, `parallelize`, `arrange`
- Story 9.17: `resolve`, `diffedit`
- Story 9.18: `revert`
- Story 9.19: `bookmark move`/`advance`/`rename` + list filters
- Story 9.20: `git push`, `git clone`, `git init`
- Story 9.21: `op log`/`show`/`diff`/`abandon`, `redo`
- Story 9.22: `file track`/`untrack`
- Story 9.23: `workspace add`/`update-stale`
- Story 9.24: Remote-change poll
- Story 9.25: Graph search backend (counts, change search, revset errors)
- Story 9.26: Implicit snapshot + Git import before every verb
- Story 9.27: Open with the effective config stack
- Story 9.28: `config` surface
- Story 9.29: Bookmark tracking state
- Story 9.30: `git fetch` CLI parity
- Story 9.31: Drop-action capability query
- Story 9.32: Warning channel on every envelope
- Story 9.33: Creation paths report warnings
- Story 9.34: Snapshot knobs read after HEAD import
- Story 9.35: Dart keeps precondition/warnings on errors
- Story 9.36: Login-shell environment at Finder launch
- Story 9.37: Secure-config fix-ups at command start
- Story 9.38: `edit` of current `@` is a no-op
- Story 9.39: `undo` stack
- Story 9.40: No-change verbs write no operation
- Story 9.41: `--when.commands` scopes per verb
- Story 9.42: Graph walk like `jj log` @ v0.46
- Story 9.43: `converge` (decision pending)
- Story 9.44: `file edit`, `file delete`
- Story 9.45: `git colocation status`/`enable`/`disable`
- Story 9.46: v0.44 → v0.46 parity audit
- Story 9.47: Parity oracle in the gate
- Story 9.48: `new -A` / `-B`
- Story 9.49: `commit`
- Story 9.50: Hunk selection → selected tree
- Story 9.51: jj templates (`commit_trailers`, `draft_commit_description`, `git_push_bookmark`)
- Story 9.52: Network verbs on a helper — progress + Cancel
- Story 9.53: Parity clean-up after the 2026-10-19 loop
- Story 9.54: Edited editor text for `squash`/`split` + 9.51–9.53 follow-ups
- Story 9.55: One integration-test binary per crate
- Story 9.56: Hints on errors + three 9.24/9.30/9.31 loop follow-ups
- Story 9.57: `convert` leaves on disk what the CLI leaves (no own rollback)
- Story 9.58: Follow-ups of 9.57 — `init` reports what it left, `convert_import` creates one level, the CLI's `immutable_heads()` error text

## Requirements & Constraints

- **Spec = the CLI's observable behavior at v0.46.0** (`git -C ../jj show v0.46.0:<path>`; re-read even where a story cites v0.44.0): verbs, preconditions, refusals and their order, defaults, op descriptions byte-identical, every on-disk effect. Terminal UX (TUI, editor, pager, prompts, `ui.status` chatter) is replaced. When the CLI refuses, Zanshin refuses equivalently — no "nicer" outcome. A deliberate divergence is named in the story (e.g. 9.44: a `file_edit` path below an existing non-directory refuses `jj.invalid_input`).
- **Pass parameters through:** CLI/config defaults are editable pre-fills, never hidden Zanshin defaults; where the CLI prompts, return candidates or a plan. Absence is `null`. Zanshin path verbs take path prefixes, not filesets (ADR-0003); where the CLI opens an editor on content, the GUI supplies the new bytes.
- jj only via jj-lib in `zanshin-jj`; production code never shells out to `jj` or parses its text (only the oracle's tests run the pinned `jj`).
- A no-change verb writes no operation and returns the pre-call head op id ("already colocated" / "Nothing changed." are typed results with no op). A refused verb writes no operation unless the CLI's flow wrote one before refusing (e.g. a precondition's import). Writing a tree (`select_tree`) is not a mutation.
- **Done per verb:** `.fbs` edited in place → `zanshin-jj` → `extern "C"` + committed codegen → `WorkerCommand`/`RepoHandle` in `packages/zanshin_core` → optional MCP; `docs/ffi-abi.md`; a real-cdylib `zanshin_core` test per extern fn; 9.47 oracle scenarios for mutating verbs (they are the verb's acceptance criteria); `cargo make test` green incl. coverage ratchet (new files ≥ 80 %).
- Never regenerate fixtures (no remote bookmarks — build in-test, e.g. local bare remotes and force-pushes); pin `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*`/`XDG_CONFIG_HOME` via `pin_test_env`; tests never touch `~/.config/jj`.

## Technical Decisions

- **Verb granularity is forced:** borrowed handles and locks keep each transaction Rust-side; only ids, blobs and opaque handles cross FFI (FlatBuffers `Envelope { ok, error: FfiError, data: Payload, precondition, warnings }`, no JSON, no version field; WIP = breaking `.fbs` edits in place, new fields appended). Every jj call on a repo stays serialized.
- **Error taxonomy:** per-crate `thiserror` errors mapped at the FFI to `FfiError { code, context }`; code = `<domain>.<reason>` (domains `jj`, `diff`, `graph`, `ffi`, `watcher`, `mcp`, `internal`), never user data in the code (paths/ids go in `context`); reasons never renamed. Refusals reuse registry codes (`docs/rust-error-codes.md`, updated in the same change for any new code or emitter), CLI text verbatim in `context`; one code per remedy, a new code only where a story decides it (e.g. `jj.config_error`, `jj.invalid_input`, `jj.immutable`, `jj.not_a_git_repo`, `jj.stale_selection`).
- **Warnings channel:** every CLI `ui.warning_*` on a ported path → `Envelope.warnings: [{code, message}]` on ok AND error envelopes (empty list = clean success); codes in the registry's warning section; `message` verbatim, never parsed; structured detail stays in typed payloads. Status lines are typed facts, not warnings. Dart surfaces warnings and precondition on success and on `ZanshinFfiException` (handle-less commands included).
- **Hints:** a hint the UI shows verbatim travels as its verb's plan/result data (payload `hints: [string]`, e.g. fetch remotes, push result, colocation status). Errors carry the CLI's hint lines in `FfiError.hints: [string]` (absent = none, CLI order, verbatim), mirrored as `ZanshinFfiException.hints`; no in-band "Hint:" text; the registry notes which codes carry hints.
- **`op_support.rs`** ports CLI-only orchestration: rewritability/immutable-set guard, `-o`/`-A`/`-B` location + loop check, message combination/trailers, `SelectedTree`. Real algorithm ports: `revert`, `split`, `parallelize`, headless `arrange`.
- **Precondition = CLI start-up:** colocated → import HEAD → snapshot → import refs under jj's git import/export lock, each op only on change, knobs read where the CLI reads them; not for no-snapshot commands or creation paths. A broken start-up environment refuses every verb; a stale working copy refuses snapshotting calls until `update-stale` recovers it. A verb that moves the workspace's Git repo (colocation enable/disable) reloads the handle's workspace, also after a failure following the move.
- **Finish = CLI `tx.finish`:** the shared finish resolves the immutable set (rebasing mutable descendants) for every write with changes — creation paths' "import git head" finish included — so an unresolvable alias refuses `jj.config_error` with no operation, with the CLI's wording ("Invalid `revset-aliases.immutable_heads()`" + the jj-lib cause), produced in one place.
- **Creation paths own no rollback:** on any failure of `init`/`convert` the disk is what the CLI's `jj git init` leaves (only jj-lib's own cleanup; `clone` keeps removing what it created, as the CLI); the working copy and `.git/` are never touched. The error's `left_behind` (`FfiError.left_behind` → `ZanshinFfiException.leftBehind`) lists, outermost first, only what this call created — known from the creating call's own result, never a check before it. Destinations are created one level deep like `create_or_reuse_dir`; a missing parent refuses "Failed to create workspace: …". A `watcher.io_error` after a successful creation means the repo on disk is whole.
- **Settings = the CLI's full config stack**, resolved per verb's CLI command name (one table, `cli_command.rs`, canonical clap chains — a new verb adds its entry; creation paths resolve as `git init`/`git clone`, graph/search reads as `log`); the workspace reloads only when the stack fingerprint or per-command resolution differs. No hardcoded identity, no `.gitconfig`. Config writes share one `ConfigFile` helper and write no operation.
- **One pure `plan_*` fn per verb**, shared with `drop_actions` (advisory; the verb's refusal wins), so preview rows and execution agree; plans report what the CLI would ask. Where the CLI returns early without a transaction, the plan reports it after the rewritability guard and the verb returns the no-op result before calling jj-lib (menu/drop row `NoOp`) — e.g. `edit` of `@`. Argument parsing happens in the CLI's order before repo-dependent checks.
- **Interactive verbs (GUI diff-editor contract):** a separate `select_tree` call (op-pinned, no snapshot, no operation) builds the selected tree in the builtin editor's order from a revision, its `left` (parent tree hex ids from `show`'s `parent_tree_ids`) and per-path selections (whole file, hunk keys = 0-based old/new start + count, or mode + keys); it returns the tree's ids + conflict labels so a conflicted tree round-trips. `commit`/`split` take one `TreeSelection { tree, left }`, `squash` one per source; paths together with a tree refuse `jj.invalid_input` before the snapshot. A moved `left` or an unknown/whole-only key refuses `jj.stale_selection`; a later edit in `@` is not stale. The arm offers what the builtin editor offers (built 2026-10-24): a mode change is selectable apart from content hunks (`FileSelection.mode = true` with the section keys; whole + mode refuses `jj.invalid_input`), and a conflicted file's keys are cut over its materialized text (`ui.conflict-marker-style` + the tree's labels). Binaries, deletions and non-file entries are whole-only. An edited editor buffer is passed separately from `-m` (both refuse).
- **Staleness for `diffedit`/`resolve`:** both snapshot first, so an editor autosave can change the target inside the call. `diffedit` also takes the target's tree ids the GUI saw (`ShowEntry.tree_ids`); `resolve` with GUI files takes each file's term ids from `resolve_list` (absent term = deleted side). A mismatch refuses `jj.stale_selection` and writes nothing.
- **Revset reads:** never a second revset parser — Zanshin builds text, jj-lib parses it, with the effective `[revset-aliases]`, configured `user.email` for `mine()`, workspace root as cwd for `files()`, and `@` as the handle's workspace. `eval_revset` is a Rust-only visitor over a lazy revset; nothing streams across FFI — a read returns a bounded snapshot (limit/cap + `truncated`/`capped`). Never trust `count_estimate`; count by iterating. `jj.revset_parse_error` / `jj.revset_resolution_error` stay distinct; parse diagnostics are `jj.revset_diagnostic` warnings. An empty `short_prefixes` disables disambiguation; resolution failures there only warn and degrade.
- **Graph walk = `jj log` @ v0.46:** the log set is evaluated through jj-lib's `ResolvedRevset::evaluate` (index merged with every `at_operation()` operation); its `into_inner()` keeps the resolved expression for the topology's passes (against the merge only when there is one); prioritize = `prioritize ∩ revset.within_visibility(head)`. Open: `commit_contents` refuses ids of rows reached only through a non-head `at_operation()`.
- **Op-pinned reads:** load via `load_operation` + `load_at`, never `load_at_head`; no pre-verb snapshot, no operation, `lastPrecondition` unchanged, nothing retained on the handle. A gc'd operation refuses `jj.operation_not_found`. The UI passes the shown topology's `operationId`. The single worker cannot cancel, so expensive revset functions are batched or limited; debouncing is UI-side.
- **Templates:** the `jj-cli` library is used for its template engine only — never `CliRunner`/`Ui`/commands, no `jj_cli` type in a public position; pinned with `jj-lib`.
- **Network verbs** (fetch, clone, push) run on a once-per-call helper isolate with live progress; Cancel kills git's process group and refuses with a dedicated code.
- **Oracle** (`crates/zanshin-parity`): stock `jj-cli` pinned with `jj-lib`, compares repo state via jj-lib and counts `Warning:` lines; ledger fails on UNEXPECTED/CHANGED/STALE. Reads, codes, hints, network and interactive verbs need hand audit (interactive selections via a `--tool` script); a status read can be witnessed by the CLI reading Zanshin's result. Pin bumps move `jj-lib`, `jj-cli` and the `../jj` tag together.
- **Test layout:** `zanshin-jj`/`zanshin-ffi` integration tests live in one binary each (`tests/it/main.rs`, one module per file); env-mutating tests share the `test-helpers` lock or start with `own_process!`.

## UX & Interaction Patterns

- Drop menu: rebase forms (`-s`/`-r` onto, `-r -A`/`-B`), squash, merge `new`, `duplicate`, `bookmark move` (explicit `--allow-backwards`); refused/no-op rows hidden, the first refusal reason shown on the ghost.
- Composer runs `commit`/`split`/`squash -r`; the inspector selects (10.26) and drags (10.27) hunks — incl. a separate mode-change row and conflict sections — which become a `select_tree` call; push sheet uses a dry-run plan per remote and ref; the project dot's "ahead" counts only push-target remotes. Commit detail can edit/delete a file in any mutable revision without checking it out (9.44).
- Graph search shows "N changes" per suggestion/recent filter and "N of M match" in the Configurations window, offers go-to hits outside the view marked `not in view`, and points at a configuration's failing rule from a revset error's span — so revset errors carry kind + byte span (parse) or kind + symbol + similar names (resolution).
- The UI switches on warning/error codes and shows hints verbatim, never parsing messages. A stale-selection refusal makes the UI reload, re-map and ask again. Undo is off when the current op's parent is root; timers and debouncing are UI-side.

## Cross-Story Dependencies

- 9.1 blocks Tier C, 9.9, 9.31, 9.48; Tier A → B → C.
- 9.22 + 9.27 → 9.26 → 9.34; 9.27 → 9.28; 9.26–9.28 → 9.41.
- 9.32 → 9.33, 9.35; 9.36/9.37/9.39/9.53 emit warnings through it.
- 9.50 (on 5.1/5.6's keys and sections) → tree arms of 9.15/9.17/9.49; 9.17's staleness inputs come from 9.6's `show` (`tree_ids`) and its own `resolve_list`; a key read for mode + content together still waits on 5.1. 9.31 shares `plan_*` fns with the verbs it previews.
- 9.21's `redo` reuses 9.39's walk; 9.40's gate covers new verbs (9.38 adds the pre-jj-lib early return and 9.31's `NoOp` row); 9.30 shares 9.5's import-options helper.
- 9.51 builds on 9.15/9.20/9.23/9.49; 9.52 on 6.4a/9.20/9.30; 9.54 follows 9.51/9.53.
- 9.56 builds on 9.20, 9.30, 9.31 (plan fns/drop rows flip with the finish change) and 9.32/9.35; its hint field reaches every ported error path.
- 9.57 builds on 9.20, 9.33 and 9.56; 9.58 extends `left_behind` to `init`, reworks `convert_import`'s destination creation, and its `immutable_heads()` wording reaches every verb, `clone` and `convert_import`.
- 9.25 builds on 2.5, 4.9, 4.10–4.12, 9.2, 9.27; consumers 10.21 and 10.22; 9.28's `configSet` is the only `revsets.log` writer.
- From the 0.44 → 0.46 bump: 9.42 (done) on 4.12/9.41; 9.43 waits on Ralph's product decision (two-phase query + apply if taken); 9.44 (done) ends in 9.40's gate and reuses 9.4's reads and 9.17's conflict materialization; 9.45 (done) builds on the 0.46 workspace model (9.13/9.23) and the 2.12/2.13 conversions; 9.46 (done) audited the already-ported verbs at v0.46.0: two `git remote list` ports, all citations at v0.46.0.
- 9.55 restructured every verb story's tests; later stories add tests as `tests/it/` modules.
- Already covered outside Epic 9: reads `status`/`revset`/`change`/`op_log`/`bookmark list`/`remotes` (Epic 2), graph + `log` (Epic 4), `diff` (Epic 5); `describe`/`new`/`edit`/`abandon` (6.1), `undo` (6.2), `git fetch` (6.4a).
- UI consumers: 10.10 (drop menu) uses 9.31's `drop_actions`; 10.25 the edited-text field; 10.26/10.27 use 9.50's `select_tree` (mode/conflict arm built); 11.8 (Sync) uses 9.24's poll.

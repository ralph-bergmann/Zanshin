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
- Story 9.45: `git colocation`
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

- **Spec = the CLI's observable behavior at v0.46.0** (`git -C ../jj show v0.46.0:<path>`; re-read even where a story cites v0.44.0): verbs, preconditions, refusals and their order, defaults, op descriptions byte-identical, every on-disk effect. Terminal UX (TUI, editor, pager, prompts, `ui.status` chatter) is replaced. When the CLI refuses, Zanshin refuses equivalently — no "nicer" outcome. A deliberate divergence is named in the story.
- **Pass parameters through:** CLI/config defaults are editable pre-fills, never hidden Zanshin defaults; where the CLI prompts, return candidates or a plan. Absence is `null`.
- jj only via jj-lib in `zanshin-jj`; production code never shells out to `jj` or parses its text (only the oracle's tests run the pinned `jj`).
- A no-change verb writes no operation and returns the pre-call head op id. A refused verb writes no operation unless the CLI's flow wrote one before refusing (e.g. a precondition's import). Writing a tree (`select_tree`) is not a mutation.
- **Done per verb:** `.fbs` edited in place → `zanshin-jj` → `extern "C"` + committed codegen → `WorkerCommand`/`RepoHandle` in `packages/zanshin_core` → optional MCP; `docs/ffi-abi.md`; a real-cdylib `zanshin_core` test per extern fn; 9.47 oracle scenarios for mutating verbs (they are the verb's acceptance criteria); `cargo make test` green incl. coverage ratchet (new files ≥ 80 %).
- Never regenerate fixtures (no remote bookmarks — build in-test, e.g. local bare remotes and force-pushes); pin `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*`/`XDG_CONFIG_HOME` via `pin_test_env`; tests never touch `~/.config/jj`.

## Technical Decisions

- **Verb granularity is forced:** borrowed handles and locks keep each transaction Rust-side; only ids, blobs and opaque handles cross FFI (FlatBuffers `Envelope { ok, error: FfiError, data: Payload, precondition, warnings }`, no JSON, no version field; WIP = breaking `.fbs` edits in place, new fields appended). Every jj call on a repo stays serialized.
- **Error taxonomy:** per-crate `thiserror` errors mapped at the FFI to `FfiError { code, context }`; code = `<domain>.<reason>` (domains `jj`, `diff`, `graph`, `ffi`, `watcher`, `mcp`, `internal`), never user data in the code (paths/ids go in `context`); reasons never renamed. Refusals reuse registry codes (`docs/rust-error-codes.md`, updated in the same change for any new code or emitter), CLI text verbatim in `context`; one code per remedy, a new code only where a story decides it (e.g. `jj.config_error` for an unresolvable `immutable_heads()`, `jj.invalid_input`, `jj.immutable`, `jj.not_a_git_repo`, `jj.stale_selection`).
- **Warnings channel:** every CLI `ui.warning_*` on a ported path → `Envelope.warnings: [{code, message}]` on ok AND error envelopes (empty list = clean success, no "success" code); codes in the registry's warning section; `message` verbatim, log/tooltip only, never parsed; structured detail stays in typed payloads. Status lines ("Nothing changed.") are typed facts, not warnings. Dart surfaces warnings and precondition on success and on `ZanshinFfiException` (handle-less commands included).
- **Hints:** a hint the UI shows verbatim travels as its verb's plan/result data (payload `hints: [string]`, e.g. fetch remotes, push result). Errors carry the CLI's hint lines in an appended `FfiError.hints: [string]` (absent = none, CLI order, verbatim), mirrored as `ZanshinFfiException.hints`; the reason/context holds no in-band "Hint:" text; the registry notes which codes carry hints. Warnings keep code + message only.
- **`op_support.rs`** ports CLI-only orchestration: rewritability/immutable-set guard, `-o`/`-A`/`-B` location + loop check, message combination/trailers, `SelectedTree`. Real algorithm ports: `revert`, `split`, `parallelize`, headless `arrange`.
- **Precondition = CLI start-up:** colocated → import HEAD → snapshot → import refs under jj's git import/export lock, each op only on change, knobs read where the CLI reads them; not for no-snapshot commands or creation paths. A broken start-up environment refuses every verb; a stale working copy refuses snapshotting calls until `update-stale` recovers it.
- **Finish = CLI `tx.finish`:** the shared finish resolves the immutable set (rebasing mutable descendants) for every write with changes — creation paths' "import git head" finish included — so an unresolvable alias refuses `jj.config_error` with no operation, as the CLI does, with the CLI's wording ("Invalid `revset-aliases.immutable_heads()`" + the jj-lib cause), produced in one place.
- **Creation paths own no rollback:** on any failure of `init`/`convert` the disk is what the CLI's `jj git init` leaves (only jj-lib's own cleanup; `clone` keeps removing what it created, as the CLI); the working copy and `.git/` are never touched; the backend deletes nothing. The error result's `left_behind` (`FfiError.left_behind` → `ZanshinFfiException.leftBehind`) lists, outermost first, only what this call created — known from the creating call's own result (created vs. reused), never a check before it — so the UI offers the decision. Destinations are created one level deep like the CLI's `create_or_reuse_dir`; a missing parent refuses "Failed to create workspace: …". A `watcher.io_error` after a successful creation means the repo on disk is whole.
- **Settings = the CLI's full config stack**, resolved per verb's CLI command name; no hardcoded identity, no `.gitconfig`. Config writes share one `ConfigFile` helper and write no operation.
- **One pure `plan_*` fn per verb**, shared with `drop_actions` (advisory; the verb's refusal wins), so preview rows and execution agree; plans report what the CLI would ask (combined description, push dry-run per remote/ref). Argument parsing/expression building happens in the CLI's order before repo-dependent checks (e.g. remote patterns before listing remotes).
- **Interactive verbs (GUI diff-editor contract):** a separate `select_tree` call (op-pinned, no snapshot, no operation) builds the selected tree in the builtin editor's order from a revision, its `left` (the parent tree as hex tree ids, from `show`'s `parent_tree_ids`) and per-path whole-file or hunk-key selections (keys = 0-based old/new start + count, the diff's sections); it returns the tree's ids + conflict labels so a conflicted tree round-trips. `commit`/`split` take one `TreeSelection { tree, left }` in a tree arm, `squash` one per source (a source without one moves everything); paths together with a tree refuse `jj.invalid_input` before the snapshot. A moved `left` or an unknown/whole-only key refuses `jj.stale_selection`; a later edit in `@` is not stale. Binaries, deletions and non-file entries are whole-only. Decided 2026-10-24 (supersedes 9.50's shipped divergence): the backend arm offers what the CLI's builtin diff editor offers — a mode change is selectable on its own, apart from the file's content hunks, and a conflicted file's sections between its materialized conflict markers are selectable; both go through `select_tree` and must yield the builtin editor's tree. An edited editor buffer is passed separately from `-m` (both refuse).
- **Staleness for `diffedit`/`resolve` (decided 2026-10-25):** both snapshot first, so an editor autosave can change the target inside the call. `diffedit` also takes the target's tree ids the GUI saw (`ShowEntry.tree_ids`); `resolve` with GUI files takes each file's term ids from `resolve_list` (absent term = deleted side). A mismatch refuses `jj.stale_selection` and writes nothing; the UI reloads, re-maps the edit and asks again.
- **Templates:** the `jj-cli` library is used for its template engine only — never `CliRunner`/`Ui`/commands, no `jj_cli` type in a public position; pinned with `jj-lib`.
- **Network verbs** (fetch, clone, push) run on a once-per-call helper isolate with live progress; Cancel kills git's process group and refuses with a dedicated code.
- **Oracle** (`crates/zanshin-parity`): stock `jj-cli` pinned with `jj-lib`, compares repo state via jj-lib and counts `Warning:` lines; ledger fails on UNEXPECTED/CHANGED/STALE. Reads, codes, hints, network and interactive verbs need hand audit (interactive selections are driven via a `--tool` script). Pin bumps move `jj-lib`, `jj-cli` and the `../jj` tag together.
- **Test layout:** `zanshin-jj`/`zanshin-ffi` integration tests live in one binary each (`tests/it/main.rs`, one module per file); env-mutating tests share the `test-helpers` lock or start with `own_process!`.

## UX & Interaction Patterns

- Drop menu: rebase forms (`-s`/`-r` onto, `-r -A`/`-B`), squash, merge `new`, `duplicate`, `bookmark move` (explicit `--allow-backwards`); refused/no-op rows hidden, the first refusal reason shown on the ghost.
- Composer runs `commit`/`split`/`squash -r`; the inspector selects (10.26) and drags (10.27) hunks — including a separate mode-change row and conflict sections — which become a `select_tree` call; push sheet uses a dry-run plan per remote and ref; the project dot's "ahead" counts only push-target remotes.
- The UI switches on warning/error codes and shows hints verbatim, never parsing messages. Undo is off when the current op's parent is root; timers and debouncing are UI-side.

## Cross-Story Dependencies

- 9.1 blocks Tier C, 9.9, 9.31, 9.48; Tier A → B → C.
- 9.22 + 9.27 → 9.26 → 9.34; 9.27 → 9.28; 9.26–9.28 → 9.41.
- 9.32 → 9.33, 9.35; 9.36/9.37/9.39/9.53 emit warnings through it.
- 9.50 (on 5.1/5.6's keys and sections) → tree arms of 9.15/9.17/9.49; 9.17's staleness inputs come from 9.6's `show` (`tree_ids`) and its own `resolve_list`; 9.31 shares `plan_*` fns with the verbs it previews.
- 9.21's `redo` reuses 9.39's walk; 9.40's gate covers new verbs; 9.30 shares 9.5's import-options helper.
- 9.51 builds on 9.15/9.20/9.23/9.49; 9.52 on 6.4a/9.20/9.30; 9.54 follows 9.51/9.53.
- 9.56 builds on 9.20 (push remote resolution), 9.30 (fetch hints, `num_rewritten`), 9.31 (plan fns/drop rows must flip with the finish change) and 9.32/9.35 (envelope + Dart error result it extends); its hint field reaches every ported error path and the registry.
- 9.57 builds on 9.20 (`init_over_git_dir` already follows the CLI), 9.33 (creation-path reporting) and 9.56 (shared finish resolving the immutable set); its partial-state fact uses 9.32's envelope style. 9.58 extends 9.57's `left_behind` to `init` and reworks `convert_import`'s destination creation; its `immutable_heads()` wording reaches every verb, `clone` and `convert_import`.
- 9.55 restructured every verb story's tests; later stories add tests as `tests/it/` modules.
- Already covered outside Epic 9: reads `status`/`revset`/`change`/`op_log`/`bookmark list`/`remotes` (Epic 2), graph + `log` (Epic 4), `diff` (Epic 5); `describe`/`new`/`edit`/`abandon` (6.1), `undo` (6.2), `git fetch` (6.4a).
- UI consumers: 10.10 (drop menu) uses 9.31's `drop_actions`; 10.25 the edited-text field; 10.26/10.27 use 9.50's `select_tree` (10.26's 2026-10-24 decision reopens 9.50's mode-change/conflict arm, no story number yet); 11.8 (Sync) uses 9.24's poll.

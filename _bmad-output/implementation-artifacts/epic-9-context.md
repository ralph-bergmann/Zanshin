# Epic 9 Context: jj Operation Surface Build-Out (ADR-0003)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the jj CLI's meaningful operation set as typed, transaction-bounded verb calls in `zanshin-jj` — beyond Epic 6's minimal write set — each composed Rust-side over jj-lib and exposed through `zanshin-ffi` (MCP optional), and close the CLI-parity gaps around them (effective config stack, implicit snapshot/Git import, warnings, no-op gate, undo/redo, templates, network progress/Cancel, pin bumps), guarded by a differential parity oracle against the stock CLI. A user must be able to alternate between the jj CLI and Zanshin on one repo without noticing; the floating client (Epics 10/11) is the main consumer. Stories are backlog-granular; ACs/specs are written when scheduled.

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
- Story 9.13: `file chmod`; `workspace forget`/`rename`/`remove`
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

## Requirements & Constraints

- **Spec = the CLI's observable behavior at v0.46.0** (`git -C ../jj show v0.46.0:<path>`; re-read even where a story cites v0.44.0): verbs, preconditions, refusals and their order, defaults, op descriptions byte-identical, every on-disk effect. Terminal UX (TUI, editor, pager, prompts) is replaced.
- **Pass parameters through:** CLI/config defaults are editable pre-fills, never hidden Zanshin defaults; where the CLI prompts, return candidates or a plan. Absence is `null`.
- jj only via jj-lib in `zanshin-jj`; production code never shells out to `jj` or parses its text (only the oracle's tests run the pinned `jj`).
- A no-change verb writes no operation and returns the pre-call head op id.
- Refusals reuse `<domain>.<reason>` codes (`docs/rust-error-codes.md`), CLI text verbatim; a new code only where a story decides it. CLI warnings → `warnings: [{code, message}]` on ok and error envelopes; status lines ("Nothing changed.") are typed facts. Hints are not warnings: a hint the UI shows verbatim travels as that verb's plan/result data.
- **Done per verb:** `.fbs` edited in place → `zanshin-jj` → `extern "C"` + committed codegen → `WorkerCommand`/`RepoHandle` in `packages/zanshin_core` → optional MCP; `docs/ffi-abi.md`; a real-cdylib `zanshin_core` test per extern fn; 9.47 oracle scenarios for mutating verbs (they are the verb's acceptance criteria); `cargo make test` green incl. coverage ratchet (new files ≥ 80 %).
- Never regenerate fixtures (no remote bookmarks — build in-test); pin `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*`/`XDG_CONFIG_HOME` via the env guards; tests never touch `~/.config/jj`.

## Technical Decisions

- **Verb granularity is forced:** borrowed handles and locks keep each transaction Rust-side; only ids, blobs and opaque handles cross FFI (FlatBuffers `Envelope`, no JSON). Every jj call on a repo stays serialized.
- **`op_support.rs`** ports CLI-only orchestration: rewritability guard, `-o`/`-A`/`-B` location + loop check, message combination/trailers, `SelectedTree`. Real algorithm ports: `revert`, `split`, `parallelize`, headless `arrange`.
- **Precondition = CLI start-up:** colocated → import HEAD → snapshot → import refs under jj's git import/export lock, each op only on change; not for the CLI's no-snapshot commands or creation paths. A broken start-up environment refuses every verb. A stale working copy refuses every snapshotting call until `update-stale` (or `snapshot.auto-update-stale`) recovers it.
- **Settings = the CLI's full config stack**, resolved per verb's CLI command name; no hardcoded identity, no `.gitconfig`. Config writes share one `ConfigFile` helper and write no operation. Login-shell env passed as an explicit map, never `set_var`.
- **One pure `plan_*` fn per verb**, shared with `drop_actions` (advisory; the verb's refusal wins); plans report what the CLI would ask (combined description, push dry-run per remote/ref).
- **Interactive verbs** take a GUI tree from `select_tree` (9.50) plus `left`; stale selections refuse. An edited editor buffer is passed separately from `-m` and written as the CLI writes a saved buffer (no trailers; both together refuse).
- **Templates:** `zanshin-jj` uses the `jj-cli` library for its template engine only (`CommitTemplateLanguage`, `TemplateRenderer`, the builtin aliases/`templates.*` defaults) — never `CliRunner`/`Ui`/commands, no `jj_cli` type in a public position; pinned with `jj-lib`.
- **Network verbs** (fetch, clone, push) run on a once-per-call helper isolate so progress streams live; other calls on that handle queue behind. Cancel kills git's process group and refuses with a dedicated cancel code, with the CLI's failure-path clean-up.
- **Oracle** (`crates/zanshin-parity`): stock `jj-cli` pinned with `jj-lib`, compares repo state via jj-lib; ledger fails on UNEXPECTED/CHANGED/STALE. Reads, codes, network and interactive verbs need hand audit. Pin bumps move `jj-lib`, `jj-cli` and the `../jj` tag together and triage every oracle failure.

## UX & Interaction Patterns

- Drop menu: rebase forms (`-s`/`-r` onto, `-r -A`/`-B`), squash, merge `new`, `duplicate`, `bookmark move` (explicit `--allow-backwards`); refused/no-op rows hidden.
- Composer runs `commit`/`split`/`squash -r`; push sheet uses a dry-run plan per remote and ref; the project dot's "ahead" counts only push-target remotes.
- Undo is off when the current op's parent is root; ⌘Z undoes only Zanshin's own latest op; `update-stale` offers no Undo. Timers and debouncing are UI-side.

## Cross-Story Dependencies

- 9.1 blocks Tier C, 9.9, 9.31, 9.48; Tier A → B → C.
- 9.22 + 9.27 → 9.26 → 9.34; 9.27 → 9.28; 9.26–9.28 → 9.41.
- 9.32 → 9.33, 9.35; 9.36/9.37/9.39/9.53 emit warnings through it.
- 9.50 → tree arms of 9.15/9.17/9.49; 9.31 shares `plan_*` fns with the verbs it previews.
- 9.21's `redo` reuses 9.39's walk; 9.40's gate covers new verbs; 9.30 shares 9.5's import-options helper.
- 9.51 builds on 9.15/9.20/9.23/9.49; 9.52 on 6.4a/9.20 (and 9.30 if first); 9.54 follows 9.51/9.53 (uses 9.20's default-remote resolution; 10.25 consumes its edited-text field).

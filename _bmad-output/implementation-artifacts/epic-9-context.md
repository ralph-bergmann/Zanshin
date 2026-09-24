# Epic 9 Context: jj Operation Surface Build-Out (ADR-0003)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the jj CLI's operation set as typed verb-level calls in `zanshin-jj` — each a whole transaction composed Rust-side over jj-lib, lifted through `zanshin-ffi` (optionally MCP) — and close the CLI-parity gaps around them (config stack, implicit snapshot/Git import, warnings, no-op handling, undo stack), so a user can switch between the jj CLI and Zanshin on one repo without noticing. Stories are backlog-granular; ACs or a spec are authored when scheduled.

## Stories

- Story 9.0: Bump jj-lib to 0.42.0 (done)
- Story 9.0a: Bump jj-lib to 0.44.0
- Story 9.1: Operation-support layer
- Story 9.2: `eval_revset` + `View` read helpers
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
- Story 9.17: `commit`, `resolve`, `diffedit`
- Story 9.18: `revert`
- Story 9.19: `bookmark move`/`advance`/`rename` + list filters
- Story 9.20: `git push`, `git clone`, `git init`
- Story 9.21: `op log`/`show`/`diff`/`abandon`, `redo`
- Story 9.22: `file track`/`untrack`
- Story 9.23: `workspace add`/`update-stale`
- Story 9.24: Remote-change poll
- Story 9.25: Log revset input (needs refinement)
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
- Story 9.39: `undo` stack (v0.44.0)
- Story 9.40: No-change verbs write no operation
- Story 9.41: `--when.commands` scopes per verb

## Requirements & Constraints

- **CLI observable behaviour at the pinned tag is the spec:** verbs, preconditions, refusals and their order, defaults, op-log effect (descriptions byte-identical), every on-disk side effect. Terminal UX (TUI, `$EDITOR`, pager, prompts, text, hints) is not ported.
- **Backend exposes, UI decides:** pass parameters through, no hidden defaults (a CLI default may be an editable pre-fill), return candidates where the CLI would prompt. Absence is `null`.
- jj access only via jj-lib; never shell out to `jj` or parse its text.
- Pure reads write no operation beyond the shared snapshot precondition; a verb that changes nothing writes no operation and returns the pre-call head op id.
- Done per verb = `.fbs` (edited in place) → `zanshin-jj` → `extern "C"` + committed codegen → Dart worker command → optional MCP → Rust tests + a real-cdylib `zanshin_core` test per extern fn; `docs/ffi-abi.md` and error registry updated; `cargo make test` green incl. coverage ratchet.
- Never regenerate fixtures (no remote bookmarks — build that state in-test); pin `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*` in env guards.

## Technical Decisions

- **Verb granularity is forced:** borrowed jj-lib handles and on-disk locks prevent driving a transaction across FFI; only owned ids/blobs and opaque handles cross. One surface serves Flutter and MCP.
- **Operation-support layer** re-ports CLI-only orchestration: rewritability guard, `-o`/`-A`/`-B` location + loop check, message combination, selected-tree plumbing. Only `revert`/`split`/`arrange`/`parallelize` are real algorithm ports.
- **Reads:** named views + `eval_revset` (lazy, cancellable visitor; crate-only) + direct `View` reads; parse/resolution/evaluation errors stay distinct.
- **Per-verb precondition = CLI start-up:** colocated → import Git HEAD → snapshot → import refs, under jj's git import/export lock, each writing only on change. Not for the CLI's no-snapshot commands or detect/open/init/clone/convert; loop-free with the watcher.
- **Settings = the CLI's full config stack**, resolved with the verb's CLI command name; no hardcoded identity, no `.gitconfig`; reload on change. Config writes are file edits via one `ConfigFile` helper family, no operation.
- **Refusals** reuse `<domain>.<reason>` codes with the CLI message verbatim; **CLI warnings** become `warnings: [{code, message}]` on ok and error envelopes; status lines stay typed facts.
- **One pure `plan_*` fn per verb**, shared by the verb and the drop-action preview (advisory; the verb's refusal wins).
- Network verbs reuse the typed progress callback; the login-shell environment is resolved at start-up and passed as an explicit map (never `set_var`).

## UX & Interaction Patterns

- Interactive verbs take a GUI-supplied tree id (context + apply); no editor spawn; `arrange` is headless.
- Drag-and-drop: drop on a commit = onto, on an edge = after + before; menu shows available verbs, refused ones greyed with reason.
- Remote badge counts upstream-changed bookmarks, never commits; timers are UI-side. Warning codes let the UI offer remedies without parsing text.

## Cross-Story Dependencies

- 9.0/9.0a first (`../jj` reference tag moves with the pin); 9.1 blocks Tier C, 9.9 and 9.31; Tier A → B → C.
- 9.27 → 9.28; 9.22 + 9.27 → 9.26 → 9.34; 9.26–9.28 → 9.41; 9.37 uses 9.27's refresh; 9.25 writes via 9.28's helper.
- 9.32 → 9.33, 9.35; 9.36/9.37/9.39 emit through it.
- 9.31 shares plan fns with 9.3/9.6/9.9/9.15/9.16/9.18 — first to land creates them.
- 9.24 poll / 9.29 distances / 9.30 fetch (import-options helper shared with 9.5); 9.11/9.19 build on 9.8; 9.39 ↔ 9.21, 9.40.
- Interactive verbs can't be tested end-to-end here. MCP cross-cut open: which verbs first; raw `eval_revset` or named views.

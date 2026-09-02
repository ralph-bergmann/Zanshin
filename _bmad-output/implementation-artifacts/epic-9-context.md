# Epic 9 Context: jj Operation Surface Build-Out (ADR-0003)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the full jj operation surface as typed, verb-level operations in `zanshin-jj` — everything beyond the WIP-minimal write subset (`describe`/`new`/`edit`/`abandon`/`undo`/`git fetch`) that shipped earlier. Each verb is a whole transaction composed Rust-side against jj-lib and lifted through `zanshin-ffi` and (optionally) the MCP server, so a caller — the Dart worker or an AI agent — names the verb and never composes primitives. The outcome is operation parity with the jj CLI's meaningful verb set: 69 operations were mapped and feasibility-verified against the pinned jj release, tiered cheap → medium → thick. This epic supersedes the deferred advanced/rare mutation stubs (split/squash/rebase, bookmark CRUD) and picks up the deferred requirements for conflict ops, `git push`, op-restore/op-diff, and settings access. Until it lands, anything past the four essential mutations forces the user out to the jj CLI. Scheduling is the product owner's call; stories are at backlog granularity and full acceptance criteria are authored per story when one is scheduled.

## Stories

- Story 9.0: Bump `jj-lib` 0.41.0 → 0.42.0 (precursor, already executed)
- Story 9.0a: Bump `jj-lib` to latest (0.42.0 → 0.44.0) plus pins that track it (precursor)
- Story 9.1: Operation-support layer (`op_support.rs`)
- Story 9.2: `eval_revset` generic read primitive + direct `View` read helpers
- Story 9.3: Content ops — `restore`, `absorb`
- Story 9.4: File reads — `file list`, `show`, `annotate`, `search`
- Story 9.5: Git local sync + remote config — `git import`/`export`, `git remote add`/`remove`/`rename`/`set-url`
- Story 9.6: Read views — `show`, `evolog`, `interdiff`
- Story 9.7: Workspace reads — `workspace list`, `workspace root`
- Story 9.8: Bookmark CRUD (cheap) — `bookmark create`, `delete`
- Story 9.9: `metaedit`, `duplicate`, `fix`
- Story 9.10: Working-copy movement — `next`, `prev`
- Story 9.11: Bookmark tracking — `bookmark set`, `forget`, `track`, `untrack`
- Story 9.12: Operation edits — `op restore`, `op revert`
- Story 9.13: `file chmod`; `workspace forget`, `workspace rename`
- Story 9.14: `simplify-parents`
- Story 9.15: `squash`, `split` (partial-file)
- Story 9.16: `rebase`, `parallelize`, `arrange`
- Story 9.17: `commit`, `resolve`, `diffedit` (GUI-editor-backed conflict ops)
- Story 9.18: `revert`
- Story 9.19: Bookmark thick + `bookmark list` filters — `move`, `advance`, `rename`
- Story 9.20: `git push`, `git clone`, `git init`
- Story 9.21: Operation-log surface — `op log`, `op show`, `op diff`, `op abandon`, `redo`
- Story 9.22: `file track`, `file untrack` (locked-working-copy lifecycle)
- Story 9.23: `workspace add`, `workspace update-stale`

## Requirements & Constraints

- Functional coverage: advanced mutations (`split`/`squash`/`rebase`), rare mutations (`duplicate`/`restore`/`backout`), bookmark ops (create/move/delete/track/untrack/forget), conflict reporting + resolve-after-edit, `git push` with progress reporting, op-restore and op-diff, and settings access (user identity, signing key, defaults).
- Reliability invariants re-asserted **per verb**: no data loss; all jj access via `zanshin-jj` → jj-lib; never shell out to the `jj` binary; never parse its text output; every Zanshin-initiated mutation must be visible and reversible in the op log, indistinguishable from a CLI-initiated one.
- **The jj CLI's observable behavior is the semantic reference** — which verbs exist, their preconditions, refusal/error conditions, argument arity, op-log effect, default revset/config resolution. Read it as prior art from the local jj checkout at the pinned tag. Replicate *what* the CLI does, not *how*: the GUI/headless backend replaces the terminal UX entirely (no TUI, `$EDITOR`, pager, prompts, or templated stdout). When the CLI refuses, surface an equivalent error rather than inventing a friendlier outcome.
- **Pass user-facing parameters through; never decide for the user.** Where the CLI leaves a path, revset, destination, or flag to the user, the typed verb and its FFI/MCP surface pass it through so the UI can offer the choice. A default the CLI itself applies may be surfaced as an editable pre-fill — never as a silent, baked-in substitution.
- Definition of done per verb is the full surfacing chain: `.fbs` schema → typed `zanshin-jj` op (transaction Rust-side) → `zanshin-ffi` `extern "C"` + codegen → Dart worker command → optional MCP tool → tests. Tests mean a `zanshin-jj` integration test **plus** an FFI-path Dart test (needed for coverage attribution of each `extern "C"` fn), FlatBuffers verification, and a green coverage ratchet.
- Wire schemas are edited in place during WIP — no `_v2` tables, no in-wire schema version.
- Pin currency is a precondition: the jj-lib bump lands as its own reviewed change before any operation work, and the local jj reference tag used for CLI prior-art reading moves in lockstep.

## Technical Decisions

- **Verb-level granularity is forced, not stylistic.** Every jj write runs snapshot → start transaction → mutate a borrowed `MutableRepo` → rebase descendants → commit → finish. The load-bearing intermediates are borrowed handles or hold on-disk locks, and the write path panics if rewrites are outstanding — so a transaction cannot be driven step-by-step across FFI. Whole, curated, typed transactions are the only representable unit. Only owned id/value blobs and opaque registry handles cross the boundary.
- **One surface, two consumers.** The same typed operation is lifted to Flutter over FFI and called directly by the MCP server. Orchestration is written once; composition never moves into a consumer.
- **A shared operation-support layer** re-ports the orchestration that lives in the CLI binary and is absent from jj-lib: the immutable-heads / rewritability guard, insert-location resolution for `-A`/`-B`/`--onto`, description combination with trailers, and the selected-tree plumbing that replaces the CLI's interactive hunk selector. Bounded and shared, not a per-verb rewrite.
- **Read side** = named composed views + one generic `eval_revset` joker + direct `View` reads. The revset primitive stays lazy and streamed (never collected), cancellable mid-walk; bookmark/tag/head/working-copy listing reads straight off the view, which is cheaper than a revset. Short-prefix id resolution requires the id-prefix context wired into the symbol resolver.
- **Preserve the three-stage revset error taxonomy** (parse vs. resolution vs. evaluation) in the bridge error enum, mapped into the project's dotted `<domain>.<reason>` codes — so "unknown revision X, did you mean…" stays distinguishable from a syntax error.
- **Thickness is dominated by plumbing, not invention.** Only about four operations (`revert`, `split`, `arrange`, `parallelize`) have zero library helper and are genuine algorithm ports; several feared ops (`absorb`, `restore`, `fix`, `file annotate`) are cheap library wraps. Verbs that "feel" thick because of interactivity are backend-medium once the GUI supplies the selection.
- **Config-derived defaults come from the existing per-operation layered config loader**, rebuilt per call and never cached — default revsets and tool configuration resolve the way the CLI would, rather than from Rust constants.
- Some verbs perform writes **outside** the transaction (repo-config rewrites for remote remove/rename, workspace metadata) — follow the established remotes-story pattern rather than forcing them into the transaction.
- Networked / long-running verbs (`push`, `clone`, `fetch`) reuse the established typed progress-callback pattern.
- Verb granularity tracks the CLI verb set and is re-evaluated at each pin bump; new upstream verbs get added as they appear.

## UX & Interaction Patterns

- **Interactive verbs take a GUI-supplied selection.** `squash`, `split`, `commit`, `diffedit`, and `resolve` accept a caller-built selected tree id; the backend wraps it and never spawns an editor. Expose these as context+apply pairs so the UI can fetch what it needs to render the diff/merge view, then apply the user's selection.
- **Ambiguity is resolved by the UI, not by a prompt.** Where the CLI would prompt (e.g. multiple `next`/`prev` targets), the backend returns the candidate set and the GUI picks.
- `arrange` exposes only a headless apply-a-plan entry point; the CLI's terminal UI is replaced by the GUI's own interaction.
- Consistent posture: the backend classifies and offers; the UI decides.

## Cross-Story Dependencies

- The pin bumps (9.0, 9.0a) precede every operation story. 9.1 (operation-support layer) **blocks all of Tier C** and is also needed by `duplicate` (9.9) for location computation. Work proceeds Tier A → B → C by thickness.
- 9.2 extends the existing revset read work; the thick verbs' target/destination resolution builds on it.
- The epic reuses the established mutation module and FFI mutation-surface patterns from the earlier write-path epic rather than introducing new ones; it supersedes that epic's deferred split/squash/rebase and bookmark-CRUD stubs.
- Bookmark work is deliberately split across three tiers (create/delete → set/forget/track/untrack → move/advance/rename + list filters); later stories build on the earlier ones' target-setting helpers.
- The op-log stories extend past the existing single-step undo into full restore/revert/redo-stack semantics.
- Git interop stories build on the existing remotes-read work; remote config rewrites mirror its outside-the-transaction file-write pattern.
- **Interactive verbs cannot be validated end-to-end from this repo** — they need the Flutter diff/merge editor (out of scope here) to supply the selected tree id; the backend can only test the apply half.
- MCP exposure cross-cuts the MCP epic's write-tools story. Two open scoping questions to settle when scheduling: whether every mutation verb gets an MCP tool immediately or reads plus a core mutation subset ship first, and whether MCP gets the raw `eval_revset` primitive or only named views.

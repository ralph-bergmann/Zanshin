# Epic 6 Context: Write Path & `extern "C"` Mutation Exposure

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Add the mutating side of `zanshin-jj` — the P0 essentials (`describe`, `new`, `edit`, `abandon`) plus op-log `undo` and a progress-reporting `git fetch` — and expose them through `zanshin-ffi` so the Dart worker (and, separately, `zanshin-mcp` via direct `zanshin-jj` calls) can perform writes. The non-negotiable invariant is that every Zanshin-initiated mutation is visible and reversible in `jj op log`, indistinguishable from one the CLI made — because every write goes through jj-lib transactions only, never by shelling to the `jj` binary or parsing its text output. Conflict handling, `git push`, and the rest of the mutation surface (split/squash/rebase, bookmarks, settings, rare ops) are deliberately deferred stubs, picked up later by Epic 9's full operation-surface build-out.

## Stories

- Story 6.1: P0 essentials mutations (`mutate.rs`) — `describe`/`new`/`edit`/`abandon`; WIP-rework appended a two-thread concurrent-write smoke test exercising FR-MCP-9.
- Story 6.2: Op-log undo (P0) — shrunk (WIP-rework) to a thin single-step `jj op restore`-style wrapper; UI-facing undo-stack design and multi-step replay deferred.
- Story 6.3: Conflict ops (`conflict.rs`) — DELETED/deferred (WIP-rework); not on the WIP build/run path, added later as a linear extension of 6.5.
- Story 6.4a: Remote op — `git fetch` with progress callback (P0). `git push` dropped from WIP scope entirely, deferred.
- Story 6.5: FFI mutation surface (`zanshin-ffi/src/repo.rs` write extensions) — wraps 6.1/6.2/6.4a as `extern "C"` functions.
- Story 6.6: Wire-schema extension for mutation responses (`MutationResult`) — in-place `.fbs` edit, no versioning discipline.
- Story 6.7: Op-log visibility test (NFR-R-2) — DELETED (WIP-rework); treated as a design-enforced invariant instead of a dedicated test; returns in release-phase hardening.
- Stories 6.8–6.12: DELETED/deferred stubs (split/squash/rebase; bookmark CRUD; settings R/W; rare mutations duplicate/restore/backout; op-restore/op-diff) — no 0.1 implementation; superseded by Epic 9.

## Requirements & Constraints

- Essentials mutations (`describe`/`new`/`edit`/`abandon`) are P0 and must go through jj-lib only — no CLI shelling.
- Op-log `undo` is P0.
- `git fetch` with progress callbacks is P0 and is the real load-bearing consumer of the progress-callback contract (a long-running op accepts a `NativeCallable.listener` and emits `{operation, progress, message}` events); `git push` and conflict-resolve are deferred, linear add-ons later.
- Same-repo concurrency (GUI + MCP server + external CLI writing the same repo simultaneously) is P0/architectural: resolved purely via the filesystem (op-heads mutation is the notification channel), no IPC, no locking choreography. Exercised in this epic only via 6.1's concurrent-write smoke test; deeper validation is Epic 7's job.
- Reliability invariant (binding, review-gated in this epic): no data loss; all mutating operations route through jj-lib via `zanshin-jj`; no shelling to the `jj` CLI; no string-parsing of jj output; every Zanshin-initiated mutation must be visible and reversible in `jj op log`, indistinguishable from a CLI-initiated one.
- Rust panics never cross the FFI boundary — caught and converted to structured error codes.
- Deferred out of this epic's scope (picked up by Epic 9): conflict ops, `git push`, split/squash/rebase, bookmark CRUD, settings read/write, rare mutations (duplicate/restore/backout), op-restore/op-diff.

## Technical Decisions

- **Transport is FlatBuffers, not JSON** (supersedes the original story text's `args_json`/`*.schema.json` language). Faillible FFI functions return an owned `Envelope` buffer (`ok`, `FfiError`, `Payload` union) freed via `zanshin_buffer_free`; composite inputs cross as a per-call FlatBuffers request table or decompose to scalars + lone CStrings — never a JSON string. Malformed/missing input yields `ffi.invalid_argument` / `ffi.null_pointer` / `ffi.utf8_error`. `error.code` is always a dotted lowercase `<domain>.<reason>` string, registered centrally. `.fbs` schemas are edited in place (no `_v2`, no in-wire `schema_version`) and regenerated via `cargo make codegen`.
- **Operation-level (verb) FFI is a hard technical requirement, not a style choice.** jj-lib's mutation lifecycle (load → snapshot working copy → `start_transaction` → mutate the borrowed `MutableRepo` → mandatory `rebase_descendants` → two-phase commit → rebind the workspace) holds borrowed handles and on-disk locks that cannot cross an FFI boundary or pause mid-sequence. `zanshin-jj` must therefore expose whole, curated, typed transactions (`describe`, `new`, `edit`, `abandon`, `undo`, `git_fetch`, …) — never expose transaction primitives across FFI. This matches every prior-art library-linked jj GUI (gulbanana/gg, JayJay, VisualJJ) and is formalized as ADR-0003.
- Every mutation follows the same jj-lib transaction pattern: `start_transaction` → mutate via `tx.mut_repo()` → `tx.commit()`.
- `Repo::undo()` is deliberately a thin one-step walk-back, not a CLI-parity undo/redo stack — jj's stack semantics (description-prefix detection) are CLI-only orchestration with no jj-lib helper, so replicating them is explicitly out of scope; multi-step restore is the deferred op-restore work.
- Progress delivery for `git_fetch` reuses the watcher's backpressure design: a bounded channel (drop-oldest on full, logged) carries events to the Dart-supplied `NativeCallable.listener`; delivery is best-effort for intermediate events, but the final 100% event is always delivered because it rides the function's return.
- Concurrency model: single-threaded Rust-side access via the one worker isolate — no per-call locking (`Arc<Mutex<T>>`/`RwLock`) around handles. Cross-process same-repo concurrency (GUI/MCP/external jj) is resolved purely via the filesystem, not via any in-process coordination.
- Mutation `extern "C"` functions are `catch_unwind`-wrapped; panics are converted to structured error codes, never cross the boundary.
- Relevant file layout: `crates/zanshin-jj/src/mutate.rs` (essentials + deferred advanced/rare mutations), `.../conflict.rs` (deferred), `.../op_log.rs` (undo), `.../remotes.rs` (fetch/push); FFI additions in `crates/zanshin-ffi/src/repo.rs`; wire shapes in `schemas/*.fbs`.

## Cross-Story Dependencies

- Story 6.1's `MutationResult` shape is what 6.5 returns over FFI and what 6.6's `.fbs` tables encode; 6.5 depends on 6.1/6.2/6.4a's Rust APIs existing first, and on 6.6's schema extension for its typed return payloads.
- Story 6.1's concurrent-write smoke test is the only in-epic exercise of FR-MCP-9 same-repo concurrency; Epic 7 (`zanshin-mcp`) validates it further from the MCP-consumer side.
- Story 6.4a's progress-callback plumbing is the first real consumer of the `NativeCallable.listener` pattern established in Epic 3 — issues found here are likely bugs in that shared Epic 3 pattern, not local to fetch.
- **Epic 9 (`jj` Operation Surface Build-Out, ADR-0003) supersedes this epic's deleted/deferred stories 6.3 and 6.8–6.12.** It picks up conflict ops, `git push`, split/squash/rebase, bookmark CRUD, settings, rare mutations, and op-restore/op-diff as typed verbs, reusing this epic's `mutate.rs` (6.1) and FFI mutation-surface (6.5) patterns rather than introducing a new one. Interactive "thick" verbs there additionally need a GUI-supplied `TreeId` from the (out-of-scope) Flutter diff/merge editor.

---
id: SPEC-4-8-log-rows-cli-parity
companions:
  - 'cli-log-parity.md'
  - '../../project-context.md'
  - '../../implementation-artifacts/epic-4-context.md'
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Story 4.8: CLI-parity log rows — metadata-enriched, self-contained GraphSlice rows

## Why

Epic 4 delivered lane topology (`GraphRow { commit_id, lane, color_idx, edges }`) but no display metadata — the schema itself says "display metadata joins later". Later is now: rendering a log view today would take one `zanshin_graph_slice` call plus N per-commit `zanshin_change` calls, re-resolving head each time — slow, and racy against external `jj` mutations (Zanshin's core scenario), producing exactly the lane/commit mismatches Ralph wants impossible. The jj CLI is the architectural proof of path (a): jj-lib yields only `(commit, parent-edges)`; the CLI joins metadata and graph cell per row, in one loop, atomically (`cli/src/commands/log.rs` + renderdag). This story completes our rows the same way, with one extra goal: a Zanshin user must recognize `jj log` in our graph — same rows, same fields, same markers — so they learn nothing new (content parity, not colors/layout).

## Capabilities

- **CAP-1**
  - **intent:** One `zanshin_graph_slice` call returns rows that carry, alongside the existing lane data, everything the jj CLI's default `jj log` output shows per commit — ids with shortest-prefix lengths, author identity, committer timestamp, refs (bookmarks/tags/workspace markers), state flags (working-copy, immutable, conflict, empty, hidden, divergent, root), and the description's first line — per the field catalog in `cli-log-parity.md`.
  - **success:** Committed golden tests show row-by-row content equality with `jj log`'s v0.42.0 output on the fixtures, plus in-test constructed divergent/hidden/conflict/empty/ref cases; no second FFI call is needed to render the default log view.

- **CAP-2**
  - **intent:** Each row is self-contained renderable — it additionally lists the lanes passing through it (`active_lanes`, with edge kind), so a list cell paints its full graph cross-section without knowledge of neighbor rows, the renderdag row model.
  - **success:** Structural invariant tests over the medium fixture (incl. octopus merge) prove cross-row consistency: every routed edge's lane appears in the pass-through set of every row it crosses, and rendering any single row in isolation needs no other row.

- **CAP-3**
  - **intent:** Elided ancestry renders as synthetic "(elided revisions)" rows exactly as the CLI does by default (`ui.log-synthetic-elided-nodes = true`): each `Indirect` edge becomes a direct-linked elided row placed after its child, occupying a lane like a real row; a `synthetic_elided` pass-through (default true) restores today's Indirect-edge-only stream when off.
  - **success:** On an eliding revset the emitted row sequence (positions, links, lanes) matches the CLI's observable output; with the toggle off, output is bit-identical to today's.

- **CAP-4**
  - **intent:** The CLI's builtin revset aliases (`immutable_heads()`, `immutable()`, `mutable()`, `builtin_immutable_heads()`, `visible()`, `hidden()`; `trunk()` exists) are defined in `zanshin-jj`, so the CLI default log revset `present(@) | ancestors(immutable_heads().., 2) | trunk()` evaluates and the per-row `immutable` flag matches `immutable()` containment.
  - **success:** A walk over the CLI default log revset succeeds on the fixtures; root and trunk ancestry are flagged immutable, mutable commits are not.

- **CAP-5**
  - **intent:** The enriched rows and new parameters cross the existing FFI surface (extended `GraphSlice` payload through `zanshin_graph_slice`; schema edited in place) and `packages/zanshin_core` exposes typed Dart models plus editable-default pre-fills for every pass-through.
  - **success:** Real-cdylib Dart tests decode enriched rows including an elided row; the re-derive-after-external-op test extends to metadata (a description edited by an external op appears on the next call).

## Constraints

- **Atomicity by construction:** one call = one `load_at_head` snapshot (ADR-0002); metadata is extracted in the same single stream pass and emitted inside the same `Row` as its lane assignment. No parallel arrays, no join key across FFI, no second walk.
- **Performance:** per-call O(1) setup indexes only (View refs reverse index, immutable containment fn, `IdPrefixContext`), amortized O(1) per row, no per-row revset evaluation, no materialized cache (ADR-0002 AC-4 holds). Soft NFR < 1 s @ 10k incl. metadata; no perf gate while WIP.
- **Parity baseline is pinned:** jj v0.42.0 builtin templates and config defaults, read at the tag from `../jj` (catalog + file pointers in `cli-log-parity.md`). Parity covers observable content — fields, flags, row sequence, order — never terminal UX, colors, or layout (NFR-R-2). Re-verify the catalog at every jj-lib pin bump.
- **Semantic flags, not glyphs:** the backend ships flags (`working_copy`/`immutable`/`conflict`/`root`/elided); glyph choice is the UI's. The CLI's flag-priority order for its glyph decision is recorded as content in the companion.
- **Pass-throughs (FR-JJ-17):** `revset` + `prioritize` (existing), `synthetic_elided` (default true = CLI default), `short_prefixes` revset (default = CLI's `revsets.log` default expression). CLI-applied defaults are pre-filled and editable Dart-side, never silently applied Rust-side.
- **ACL unchanged (FR-JJ-16):** metadata extraction + aliases in `zanshin-jj` (sole `jj_lib` importer); elided splice, lane assignment, row model in `zanshin-graph` (stays `jj_lib`-free); the extern fn stays `zanshin_graph_slice` in `zanshin-ffi` — signature and `.fbs` change in place (WIP), all callers updated in the same change, codegen regenerated and committed.
- **Quality gates as ever:** `cargo make test` incl. coverage ratchet (extern-fn changes need `zanshin_core`-side cdylib coverage), error-code registry untouched unless a new code is genuinely needed, fixtures never regenerated (edge states constructed in-test).

## Non-goals

- Colors, glyph rendering, layout, themes — UI scope (Flutter is out of scope).
- Windowing/pagination and `--limit`/`--reversed` — deferral unchanged (Story 4.4 decision).
- Op-log graph parity; cryptographic-signature display (CLI default off).
- Full/multi-line descriptions — `get_change`'s job; the log row carries the first line only.
- Changes to `zanshin_change` or the MCP surface.
- Honoring user/repo jj-config overrides of aliases (Story 4.9, `../spec-4-9-config-revset-aliases/`) or templates (GUI replaces template UX). Build the builtin aliases as one table (`build_aliases_map`) so 4.9 layers config over it without rework.

## Success signal

A log view built on one `zanshin_graph_slice` call renders, for the same revset, the same rows in the same order with the same per-row content and markers a `jj log` user sees in their terminal — proven by committed golden parity tests plus self-containment invariants, with the whole payload derived from a single head-resolved snapshot.

## Assumptions

- Golden parity values are verified against real `jj` v0.42.0 output once at authoring time and committed; tests and production never shell to `jj` (NFR-R-1).
- Divergent/hidden/conflict/empty/ref edge states are constructed in-test via jj-lib write helpers (`test-helpers` precedent from Story 4.6); committed fixtures are never regenerated.
- The ~3 ms @ 10k topology-derive baseline leaves ample headroom for metadata enrichment within the soft NFR; measured at build time, not gated.
- Elided-row identity and duplicate-target sequencing replicate the CLI's observable output (`(commit_id, synthetic)` keying); exact corner behavior is verified against the CLI at build time.

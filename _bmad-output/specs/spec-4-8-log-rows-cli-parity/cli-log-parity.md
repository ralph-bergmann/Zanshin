# CLI log parity catalog (jj v0.42.0)

The content contract for Story 4.8's enriched rows. Every fact below was read from the jj monorepo **at the pinned tag** (`git -C ../jj show v0.42.0:<path>`); re-verify this catalog whenever the `jj-lib` pin moves.

Sources of record:

| Fact | File @ v0.42.0 |
| --- | --- |
| Render loop: per-commit `get_commit` → template → `graph.add_node` (stateful renderdag `next_row`, one output row per commit); elided-node splice | `cli/src/commands/log.rs` |
| Renderer adapter (`SaplingGraphLog`, `GraphEdge` → renderdag `Ancestor`) | `cli/src/graphlog.rs` |
| `builtin_log_compact`, `builtin_log_node`, helper templates | `cli/src/config/templates.toml` |
| `revsets.log` default, `log-graph-prioritize`, builtin `[revset-aliases]` | `cli/src/config/revsets.toml` |
| `ui.log-synthetic-elided-nodes = true` (default), `ui.graph.style = "curved"` | `cli/src/config/misc.toml` |
| Flag/prefix computations (hidden, divergent, `change_offset`, `shortest`, refs-per-commit indexes, working-copies guard) | `cli/src/commit_templater.rs` |

jj-lib building blocks (vendored `jj-lib-0.42.0`): `Revset::containing_fn` (immutable containment), `jj_lib::id_prefix::IdPrefixContext` (shortest prefixes), `View` ref maps (bookmarks/tags/wc commit ids), `Commit` accessors (`is_empty`-equivalent tree compare, conflict check).

## Row model

One `GraphRow` per emitted node, stream order (unchanged: `jj log` order via `TopoGroupedGraph` + prioritize). Existing fields stay: `commit_id`, `lane`, `color_idx`, `edges[] { target, target_lane, kind }`.

**Row kind.** `synthetic_elided: bool` distinguishes elided rows from commit rows. On elided rows all metadata below is absent (FlatBuffers absent → Dart `null`; null-for-absence rule) — `commit_id` holds the elided **target's** id, lane fields are real.

**New metadata fields (commit rows), mapped to `builtin_log_compact` content:**

| Field | CLI template source | Semantics |
| --- | --- | --- |
| `change_id` | `format_short_change_id_with_change_offset` | Full reverse-hex display form (rows stay keyed by commit id; divergent changes share a change id). |
| `change_id_prefix_len` | `id.shortest(8)` | Shortest-unique-prefix length (UI renders ≥ 8 chars, prefix highlighted). See "Shortest prefixes". |
| `commit_id_prefix_len` | `format_short_commit_id` | Same for the commit id. |
| `change_offset` | `format_change_offset` | Distinguishes copies of one change id; meaningful only when `hidden \|\| divergent` (CLI renders `/<offset>` there). Presence-by-flag pattern (like `target_lane`). |
| `author_name`, `author_email` | `format_short_signature(author)` | CLI compact shows the full author **email**; name rides along for the UI (detail beyond this stays `get_change`'s job). Empty string = unset (jj semantic); "(no email set)" placeholder is UI text. |
| `committer_timestamp` | `format_timestamp(commit_timestamp)` | `commit_timestamp` is the **committer** timestamp. Reuse the `Change` payload's existing timestamp wire pattern (millis + tz offset); local `%Y-%m-%d %H:%M:%S` formatting is UI's. |
| `bookmarks[]` | `commit.bookmarks()` | Structured refs: `{ name, remote?, synced, conflicted }`. Local entry renders `name`, `name*` (unsynced with a tracked remote), `name??` (conflicted); remote entry renders `name@remote`. Which remote refs the CLI shows per commit (untracked, or tracked-but-unsynced) — replicate the observable rule from `commit_templater.rs`, golden-tested. |
| `tags[]` | `commit.tags()` | Same ref shape (no remote part). |
| `working_copies[]` | `commit.working_copies()` | Other workspaces' wc markers (`name@`); the CLI shows them only in multi-workspace repos — replicate the observable guard from `commit_templater.rs`. |
| `working_copy` (flag) | `current_working_copy` | This workspace's `@`. |
| `immutable` (flag) | `immutable` | `immutable() = ::(immutable_heads() \| root())` containment via a per-call `containing_fn`. Needs CAP-4 aliases. |
| `conflict` (flag) | `conflict` | Commit tree has unresolved conflicts. |
| `empty` (flag) | `empty` | Tree equals merged parent trees ("(empty)" marker text is UI's). |
| `hidden` (flag) | `commit.hidden()` | Commit not visible (reachable only when the revset names hidden ids). |
| `divergent` (flag) | `commit.divergent()` | Change id resolves to > 1 visible commit. CLI label rule: hidden overrides divergent. |
| `root` (flag) | `commit.root()` | See "Root row". |
| `description_first_line` | `description.first_line()` | Empty string = no description (jj stores `""`); "(no description set)" placeholder is UI text. Full description stays in `get_change`. |

Excluded as content: cryptographic signature status (`ui.show-cryptographic-signatures` defaults to false) and anything the v0.42.0 log template does not show (e.g. no `git_head` element in 0.42 compact).

## Node-flag priority (CLI glyph decision — informative for the UI)

`builtin_log_node` (curved/square styles; ascii variants in parentheses):

1. elided row → `~`
2. `working_copy` → `@`
3. `immutable` → `◆` (`+`)
4. `conflict` → `×` (`x`)
5. otherwise → `○` (`o`)

First match wins — an immutable working copy renders `@`, an immutable conflict renders `◆`. The backend ships the flags; this table records the CLI's decision order so the UI can reproduce it.

## Root row

`format_root_commit` renders: short change id, `root()` label, short commit id, bookmarks — no author, no timestamp, no description, immutable styling. The payload stays uniform (all fields populated as they truly are); the `root` flag lets the UI reproduce the special rendering.

## Elided rows (CAP-3)

CLI mechanics with `ui.log-synthetic-elided-nodes = true` (default), from `cmd_log`:

- Per node, each `Indirect` edge is rewritten to a **Direct** edge targeting the elided identity `(target_commit_id, synthetic=true)`.
- After that node's row, one elided row per collected target is emitted, carrying a single Direct edge to `(target, synthetic=false)`.
- Elided rows pass through the lane assigner like real nodes: they occupy a row, get a lane + color, and route their edge. The splice happens in `zanshin-graph`'s stream layer (before the assigner), mirroring where the CLI does it (presentation side, not jj-lib).
- `Missing` edges are untouched (out-of-revset stubs, no lane — unchanged).
- `synthetic_elided = false` restores today's stream (plain `Indirect` edges; UI may draw dashed).
- Duplicate-target corners (two children eliding to the same target) must match the CLI's observable row sequence — verify against the CLI at build time, pin with a golden test.

"(elided revisions)" is UI text; the row ships only the elided flag + target id.

## `active_lanes` (CAP-2)

Per row: the pass-through set — every lane carrying a vertical segment **through** this row that neither starts nor ends at this row's node, as `(lane, kind)` pairs (`kind` from the occupying edge, so dash styling stays self-contained; color is derivable as `lane % PALETTE_SIZE`). The node's own lane and this row's edge routing stay in the existing fields.

Emitted from the `LaneAssigner`'s live-reservation state at row-emit time — no buffering, no second pass. Build-time must pin the exact boundary semantics (rows where an edge starts/lands) with the self-containment invariant: **for any edge routed on lane L from child row a to its landing row b, every row strictly between a and b lists L in `active_lanes`** — and a single row's fields suffice to paint its complete cross-section.

## Call surface

`zanshin_graph_slice(handle, revset, prioritize, synthetic_elided, short_prefixes)` — return-all semantics unchanged.

| Param | Default (pre-filled, editable Dart-side; FR-JJ-17) | Notes |
| --- | --- | --- |
| `revset` | UI passes explicitly; export the CLI default as a Dart constant: `present(@) \| ancestors(immutable_heads().., 2) \| trunk()` (`revsets.log`) | Now evaluates thanks to CAP-4 aliases. |
| `prioritize` | `present(@)` (existing `DEFAULT_GRAPH_PRIORITIZE`) | Unchanged; `none()` = no prioritization. |
| `synthetic_elided` | `true` (`ui.log-synthetic-elided-nodes` default) | CAP-3 toggle. |
| `short_prefixes` | Same expression as the `revsets.log` default (CLI: `revsets.short-prefixes` falls back to `revsets.log`) | Disambiguation set for shortest prefixes. Mirror the CLI's toggle semantic: **empty string = disabled** (full-index prefixes) — deliberately unlike `prioritize`, where blank is a parse error, because that is what the CLI does. |

Errors: reuse the existing taxonomy (`jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.jj_lib_error`, `graph.dangling_edge`, `ffi.*`); a new code only if a genuinely new failure class appears (registry updated in the same change).

## Shortest prefixes

CLI: `id.shortest(8)` renders at least 8 chars with the unique prefix highlighted; uniqueness is computed by `IdPrefixContext` scoped to the `short_prefixes` revset (shorter prefixes inside the set), falling back to the full index. We ship full ids + prefix **lengths**; the UI truncates/highlights. One `IdPrefixContext` per call (O(1) setup), never per row.

## Testing notes

- Golden parity: `insta` snapshots of decoded rows; values verified once against real `jj` v0.42.0 output at authoring time (documented in-test); tests never shell to `jj` (NFR-R-1).
- Edge states (divergent, hidden, conflict, empty, synced/unsynced/conflicted bookmarks, multi-workspace) are constructed in-test via jj-lib write helpers (`test-helpers`, Story 4.6 precedent — extend deliberately, reviewed). Fixtures are never regenerated; fixtures carry no remote bookmarks (construct via `set_remote_bookmark` in-test).
- Structural invariants (CAP-2) run on `medium-1k-commits` (octopus, multi-root) plus the ~100-commit algorithmic test from 4.1.
- FFI/Dart: real-cdylib decode tests in `packages/zanshin_core` (coverage attribution for the changed extern fn), elided-row decode, and the re-derive-after-external-op test extended to metadata (external `describe` visible on next call).
- Every buffer read goes through generated typed accessors + `Verifier` (no hand parsing).

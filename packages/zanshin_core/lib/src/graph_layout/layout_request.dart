// SPDX-License-Identifier: MIT

// The public vocabulary of a layout request (Story 4.11, docs/graph-layout.md §12–§13): the
// shipped modes and lane orders, their editable pre-fills, and the contract-violation error.

/// The vertical model of a layout (docs/graph-layout.md §0, §4.2). The names are the SPEC's wire
/// strings; [Enum.index] is the grid buffer's mode code.
enum LayoutMode {
  /// Longest-path depth: one row per generation (U = 1).
  compact,

  /// Continuous, compressed commit time: each child at least one pitch above its parents
  /// (U = 16). The default ([defaultLayoutMode]); needs the committer timestamps.
  free,
}

/// The lane → column order of a layout (docs/graph-layout.md §4.6, §4.7). The names are the SPEC's
/// wire strings; [Enum.index] is the grid buffer's order code.
enum LaneOrder {
  /// Greedy lane packing, column = lane.
  greedy,

  /// Greedy packing, then column exchanges inside time windows: fewer crossings, never wider than
  /// greedy. The default ([defaultLaneOrder]).
  compact,
}

/// The editable pre-fill for a layout request's mode (Ralph, 2026-09-27: `free`).
const LayoutMode defaultLayoutMode = LayoutMode.free;

/// The editable pre-fill for a layout request's lane order (Ralph, 2026-09-27: `compact`).
const LaneOrder defaultLaneOrder = LaneOrder.compact;

/// The editable pre-fill for a layout request's ordering budget (docs/graph-layout.md §4.7,
/// BUDGET): the work units the `compact` lane order may spend before it stops its search.
const defaultLayoutBudget = 2000000;

/// The layout engine's input broke a contract rule of docs/graph-layout.md §2 (V1–V4, and V5 for a
/// stack request).
///
/// Thrown before anything is laid out: there is never a partial or silently repaired layout.
final class LayoutContractException implements Exception {
  /// A violation of [rule] (`V1` … `V5`), described by [message].
  const LayoutContractException(this.rule, this.message);

  /// The violated rule: `V1` (a parent has a target iff it is not missing), `V2` (a target lies
  /// strictly between its child and n), `V3` (no repeated target per node), `V4` (value ranges:
  /// timestamps within ±2^53, 0 ≤ priority < 2^31, |utcOffsetMin| ≤ 1440) or, with a stack
  /// request (Story 4.13), `V5` (the stack facts: one entry per node, parent counts ≥ 0, a known
  /// working-copy code with at most one "this", every request node in [0, n)).
  final String rule;

  /// What violated [rule], naming the node.
  final String message;

  @override
  String toString() => 'LayoutContractException($rule: $message)';
}

---
title: 'Story 9.50 — Hunk selection → selected tree (the GUI diff-editor contract)'
type: 'feature'
created: '2026-10-23'
status: 'done'
baseline_revision: '5cbb777936d2cf0253ccda46e0c33f5f76a2e57a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
  - '{project-root}/docs/adr/0003-jj-operation-api-surface.md'
warnings: ['oversized']
deferred:
  - summary: >-
      No read yields a file's sections and HunkKeys yet, so only the whole-file half of the select_tree contract is usable end to end.
    evidence: |-
      select_tree::sections is pub(crate) and no read calls it; the tests hard-code keys. Story 5.1 (backlog) is the read that must emit keys from select_tree::sections with the 0-based start + count convention.
    location: >-
      crates/zanshin-jj/src/select_tree.rs (sections)
    severity: medium
  - summary: >-
      The builtin diff editor offers a mode change as a separate toggle and sections conflicted files over their materialized markers; Zanshin keeps both whole-only.
    evidence: |-
      cli/src/merge_tools/builtin.rs:296-301 (Section::FileMode) and :423-445 (conflicts::update_from_content) @ v0.46.0; epics.md Story 9.50 chose whole-only on the premise that the builtin editor does too. Documented as a divergence; needs an inspector (10.26) design decision before a FileChoice arm for the mode and conflict sectioning are built.
    location: >-
      crates/zanshin-jj/src/select_tree.rs (module doc, select_sections)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The CLI's interactive verbs (`split`, `squash`, `commit` with `-i`/`--tool`) select hunks in a diff editor; Zanshin has no way for the GUI to hand such a selection to the backend. `SelectedTree::from_tree_id` (`op_support.rs`) is unwired, `split` without paths refuses, and ADR-0003's open question "Interactive-verb contract" is unanswered. Deferred items I1–I3 (deferred-work.md) all wait on this story.

**Approach:** Contract B (epics.md Story 9.50, decision (g)): a separate read `Repo::select_tree(revision, left, files)` builds the selected tree exactly as the CLI's builtin diff editor applies a choice (`cli/src/merge_tools/builtin.rs:405-545` @ v0.46.0), writes it to the store (no operation) and returns its id; `commit`, `split` and `squash` gain a tree arm that takes that id plus `left` and refuse a stale `left` with a new code `jj.stale_selection`. `show` exposes each revision's `left` (`parent_tree_ids`) so the GUI has it.

## Boundaries & Constraints

**Always:**
- **Sections = the builtin editor's** `make_diff_sections` (`builtin.rs:225-271`): `jj_lib::diff::ContentDiff::by_line([left, right])`, one section per `DiffHunkKind::Different` hunk. **Key** = `HunkKey { old_start, old_count, new_start, new_count }` (u32): `*_start` = 0-based index of the section's first line on that side (= number of lines before it), `*_count` = its lines on that side, lines split like `split_inclusive('\n')` (a last line without `\n` counts). This is the key Story 5.1 must emit for the same hunks — the key/section helper is `pub(crate)` in one place so 5.1 reuses it.
- **Sectionable file** = both sides a resolved `TreeValue::File`, same `executable`, both contents valid UTF-8 with no NUL byte. Everything else in the diff — added/deleted files, mode changes, binary, symlinks, submodules, conflicts (either side unresolved), type changes — is **whole only** (keys for it are stale).
- **Build order = `apply_diff_builtin`** (`builtin.rs:405-465`): `MergedTreeBuilder::new(right)`; every path in `left.diff_stream(right, &EverythingMatcher)` (no copy records, as builtin) reset to left's value; then each selected file: whole → right's value; keys → content = matching text + right side of selected sections + left side of the others, written with `store.write_file`, value `Merge::normal(TreeValue::File { id, executable, copy_id })` with `copy_id` = left value's resolved copy id or `CopyId::placeholder()` (`resolve_file_copy_id`, `builtin.rs:395-403`); `write_tree()`; return its tree ids AND labels.
- **left / right:** right = the revision's tree; left = `revision.parent_tree(repo)` — exactly what `split.rs:567`, `squash.rs:495`, `commit.rs:103` diff against. `left` on the wire is that `MergedTree`'s tree ids (`tree_ids().iter()` order, hex). A selected tree on the wire is `{tree_ids, labels}` (labels empty = unlabeled) so a conflicted result round-trips byte-identically.
- **Staleness (I1, Claude's proposal confirmed):** stale = the revision's current parent tree ids ≠ `left` (a rebase / parent rewrite), or a key not among the file's current section keys (incl. keys on a whole-only or unchanged path). A change to the revision's OWN content is NOT stale by itself (every verb snapshots first, 9.26; the tree is absolute, the rest stays in @). `select_tree` checks both; the tree arms check `left` against the source commit's parent tree inside their transaction, at the point the CLI runs `diff_selector.select`. Refusal: `MutateError::StaleSelection { reason }` → `jj.stale_selection` (new code; one code per remedy — the UI re-maps and retries).
- `select_tree` runs through `Repo::with_verb` (pre-verb snapshot like `show`); it writes NO operation of its own (only store objects).
- Tree arms: `paths` and a tree together refuse `jj.invalid_input` before the snapshot (`check_*_args`, `with_checked_verb`) — the tree already embodies the selection. `split` with neither still refuses `jj.invalid_input` (the CLI's no-paths default is its editor, whose GUI replacement is the tree arm) — message names the tree arm. `squash` takes one tree per source (`squash.rs:484-533` runs the editor once per source); a source without an entry gets the editor-saved-unchanged result = everything; an entry naming no source, or two entries for one source, refuse `jj.invalid_input`. Unmatched-path warnings stay paths-only; split's all/none-selected warnings apply to both arms (`select_diff`, `split.rs:582-596`).
- Every chain step per epic rules: `.fbs` edited in place (append fields / union members / `RequestKind`), `zanshin-jj` → `extern "C" zanshin_select_tree` + committed `cargo make codegen` output → `WorkerCommand` + `RepoHandle.selectTree` (and the `tree`/`trees` params on commit/split/squash/squashPlan) → `docs/ffi-abi.md` (+ export count) → `docs/rust-error-codes.md` (`jj.stale_selection`) → real-cdylib `zanshin_core` test for the extern fn.

**Never:**
- Lines inside a section (non-goal); `diffedit`/`resolve` (9.17); editing content; MCP tools; regenerating fixtures; shelling out to jj outside the oracle tests; changing the `from_paths` arms' behavior.
- Porting "Empty diff - won't run diff editor." (`cli_util.rs:3620-3622`) — it reports the terminal editor not being launched; the GUI shows the diff itself (documented divergence).
- Running the full gate (`cargo make test` / `test-full` / `coverage`) in this run — targeted checks only (loop gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Sections 1+3 | file with 3 changed sections; keys of 1 and 3, current `left` | tree where the file = right in 1 and 3, left in 2; other changed files at left | — |
| Whole files | `[{a, whole}, {b, whole}]` | same tree ids as `SelectedTree::from_paths` with paths `a`,`b` | — |
| Nothing selected | `files: []` | left-equal content tree (no change) | — |
| Binary / mode change / add / delete / conflict | keys given | — | `jj.stale_selection` |
| Same, whole | `whole` | right's value at that path | — |
| Rebased left | `left` = old parent tree ids | — | `jj.stale_selection`, no op written |
| Unknown key | key not in current sections | — | `jj.stale_selection` |
| @ edited elsewhere after select_tree | commit with tree + same `left` | commits the selected tree; new @ holds the rest incl. the edit | — |
| Bad input | malformed hex in `left`/tree ids; even/zero tree-id count; labels count ≠ ids; invalid/duplicate path; whole with hunks (FFI) | — | `jj.invalid_input` |
| Verb with paths + tree | commit/split/squash | — | `jj.invalid_input` before snapshot |
| squash tree for a non-source | `trees: [{source: X}]`, X not a source | — | `jj.invalid_input` |
| Unknown tree id | verb tree arm | — | existing `from_tree_id` refusal (backend) |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/op_support.rs:521-604` -- §4 `SelectedTree`; `from_tree_id` (L578, `allow(dead_code)` + WHY naming 9.50) gets wired: take `&SelectedTreeId` (ids + labels, `Merge::from_vec` / `ConflictLabels::from_vec`), validate count odd & labels len, drop the allow; module doc L30-36.
- NEW `crates/zanshin-jj/src/select_tree.rs` -- the verb: options/result types, section+key helper (`pub(crate)`), stale check helper shared with the tree arms (`check_left(commit_parent_tree, left)`), build per Always; inline unit tests for keys/sections/content assembly.
- `crates/zanshin-jj/src/commit.rs:136-171` -- tree arm at the `SelectedTree::from_paths` site (L164); `CommitOptions` (L48) gains `tree: Option<TreeSelection>`; module doc divergence L20-21 rewritten.
- `crates/zanshin-jj/src/squash_split.rs` -- `SquashOptions` (L82) gains `trees: Vec<SourceTree>`; `SplitOptions` (L127) gains `tree: Option<TreeSelection>`; `check_squash_args` L227 / `check_split_args` L594 refuse paths+tree; `plan_squash` selection loop L282-291; `prepare_split` L667-678 (no-paths refusal message, tree arm); module doc L33-36.
- `crates/zanshin-jj/src/repo.rs` -- `commit` L3116 → `with_checked_verb(check_commit_args…)`; `squash` L2664, `squash_plan` L2689, `split` L2817 docs; new `pub fn select_tree` next to them via `with_verb` (pattern: `show` L1951).
- `crates/zanshin-jj/src/mutate.rs:127-404` -- add `StaleSelection { reason }` variant (+ `hints()` arm if exhaustive).
- `crates/zanshin-jj/src/commit_views.rs:94-100,435` -- `ShowEntry` gains `parent_tree_ids: Vec<String>` from the `before` tree already computed at L435.
- `crates/zanshin-jj/src/lib.rs:80,118` -- re-export the new public types.
- `crates/zanshin-jj/tests/it/api_stability.rs:1180,1196,1460-1476` -- pin new fields/types; NEW `tests/it/select_tree.rs` + `mod` line in `tests/it/main.rs` (pattern: `tests/it/commit.rs` `base_with` L125).
- `schemas/envelope.fbs` -- `RequestKind` append `SelectTree` (after L144); new `HunkKey`, `FileSelection { path; whole: bool; hunks: [HunkKey] }`, `SelectTreeRequest { kind; revision; left: [string]; files }`, `TreeSelection { tree_ids; labels; left }`, `SourceTree { source; tree: TreeSelection }` (declared before use); append `tree` to `CommitRequest` L372 / `SplitRequest` L250, `trees` to `SquashRequest` L216; payload `SelectedTree { tree_ids; labels }` appended to `union Payload` L2275; `ShowEntry.parent_tree_ids` appended.
- `crates/zanshin-ffi/src/envelope.rs` -- `pub const JJ_STALE_SELECTION`; `ok_*` builder for the payload; `crates/zanshin-ffi/src/repo.rs:167` `map_mutate_err` arm + unit test; NEW `crates/zanshin-ffi/src/select_tree.rs` (pattern `commit.rs` L34/L90); readers in `commit.rs`/`squash_split.rs` read the new fields; show builder writes `parent_tree_ids`; `tests/it/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS` 84→85; FFI it-tests.
- `packages/zanshin_core` -- `lib/src/ffi/` new adapter + commit/squash/split adapters gain the tree fields; `lib/src/worker/commands.dart` (`CommitCommand` L1745 pattern), `isolate.dart` (client ~L1605, dispatcher ~L3568), `handle.dart` (`RepoHandle.commit` L1168); show model gains `parentTreeIds`; real-cdylib `test/worker/select_tree_test.dart` (pattern `test/worker/commit_test.dart`).
- `docs/ffi-abi.md` (index L538ff, counts L287/L540), `docs/rust-error-codes.md` (table L35ff, adding L210), `docs/adr/0003-jj-operation-api-surface.md:141-142` (open question → implementation note).
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` `parity!` list -- scenarios driving the CLI's `--tool` via repo config `merge-tools.zs.program = "sh"` / `merge-tools.zs.edit-args = ["-c", "<printf the expected content> > \"$1/<file>\"", "sh", "$right"]` set with `Step::Jj(&["config","set","--repo",…])` (precedent: `EDITOR_STEP` L315); Zanshin side reads `left` from `repo.show`.
- Read-only references: `../jj` v0.46.0 `cli/src/merge_tools/builtin.rs:225-545`, `cli/src/cli_util.rs:3592-3638` (`DiffSelector::select`), `cli/src/commands/{split.rs:201-257,546-598, squash.rs:484-533, commit.rs:83-196}`; jj-lib 0.46 `merged_tree_builder.rs:60-80` (labels kept when side count matches).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/select_tree.rs` (+ `lib.rs`, `repo.rs`, `mutate.rs`) -- implement types, sections/keys, staleness, build, `Repo::select_tree`; unit tests for keys (insert-only, delete-only, last line without `\n`, three sections) and content assembly.
- `crates/zanshin-jj/src/op_support.rs` -- wire `from_tree_id(&SelectedTreeId)`, remove `allow(dead_code)`, update docs/tests.
- `crates/zanshin-jj/src/commit.rs`, `squash_split.rs`, `repo.rs` -- tree arms + arg checks per Always; docs' divergence lists updated.
- `crates/zanshin-jj/src/commit_views.rs` -- `ShowEntry.parent_tree_ids`.
- `crates/zanshin-jj/tests/it/select_tree.rs` (+ `main.rs`, `api_stability.rs`, existing commit/squash/split/show tests compile) -- every matrix row; `select_tree` writes no op when @ is unchanged; tree arms of all three verbs incl. squash multi-source and the I1 case.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/**`, `cargo make codegen` -- wire + regenerate; FFI unit/it tests incl. request-kind mismatch and `map_mutate_err` for `StaleSelection`.
- `packages/zanshin_core/**` -- Dart surface + real-cdylib test: select sections 1+3 of a three-section file, commit with that tree → hunk 2 stays in the new @; a stale `left` refuses with `jj.stale_selection`.
- `crates/zanshin-parity/tests/oracle/{scenarios.rs,main.rs}` -- `split_tool_sections_1_3`, `commit_tool_sections_1_3`, `squash_tool_sections_1_3` matching the stock CLI with no ledger entry.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `docs/adr/0003-…md` -- symbol row/section, export count, new code, ADR note closing the open question.
- `_bmad-output/implementation-artifacts/deferred-work.md`, `sprint-status.yaml` -- I1–I3 marked resolved with commit refs; 9-50 status.

**Acceptance Criteria:**
- Given a revision whose file has three changed sections, when the GUI calls `select_tree` with sections 1 and 3 and then `split`/`commit`/`squash` with that tree, then the resulting repo state equals the stock CLI's `--tool` run making the same choice (oracle, no ledger entry).
- Given a selection made before the revision's parent was rewritten, when `select_tree` or a verb's tree arm runs with the old `left`, then it refuses `jj.stale_selection` and no operation is written.
- Given @ was edited in another file after `select_tree`, when `commit` runs with the tree and the same `left`, then it succeeds and the new @ holds the edit and the unselected section.
- Given `select_tree` on an unchanged @, when it returns, then the op-log head is unchanged.
- Given the Dart `RepoHandle`, when `selectTree` then `commit(tree:)` run through the real cdylib, then hunk 2 remains in the new @.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 31 findings — high 0, medium 6, low 17, false 8, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) Conflict labels never round-trip end to end; every select_tree result in the tests is resolved/unlabeled — added `select_tree::a_conflicted_trees_labels_round_trip_through_select_tree_and_commit` (merge @ with a conflicted file; returned labels = revision tree's, committed @ keeps ids + labels).
  - `[false]` `[reject]` (edge) Whole on a path absent from the diff silently selects nothing — Whole means "the revision's value at that path"; at an unchanged path that value is already the left/right value, so the result is exactly what was asked (absolute-tree semantics of the intent).
  - `[low]` `[patch]` (edge) select_tree validates `left`/paths after the pre-verb snapshot — added `check_select_tree_args`, `Repo::select_tree` goes through `with_checked_verb`; test `malformed_input_refuses_before_the_snapshot` (dirty @: no precondition, no op); docs + codegen updated.
  - `[false]` `[reject]` (edge) Source content changed after select_tree, only `left` rechecked (split remainder "reverts", squash may conflict) — split's remaining commit holds the target's full current tree, so nothing reverts; a squash 3-way conflict on overlapping later edits is the intent's explicit rule ("a change to @'s own content … is not stale", epics item 3).
  - `[low]` `[reject]` (edge) FFI SourceTree with absent `source` becomes `ChangeId("")` → `jj.change_not_found` — the Dart surface always sets it; the fix adds a guard for a hand-built buffer only.
  - `[low]` `[reject]` (edge) Dart HunkKey ints not range-checked before `setUint32` — keys come from the backend's own read; a wrapped value can only miss (→ stale) or hit a real key the caller named; adding guards for a non-reachable input.
  - `[false]` `[reject]` (edge) Whole uses the right value's copy_id where the CLI's write_file uses the left's — on the git backend (the only one) copy ids are always the placeholder, so tree ids are identical; the oracle scenarios match the CLI.
  - `[false]` `[reject]` (edge) A stale refusal with a dirty @ still advances the op log — the snapshot op is the CLI's own start-up op (epic rule: a refused verb writes no op unless the CLI's flow wrote one before refusing); select_tree/the arms write none themselves.
  - `[false]` `[reject]` (edge) source_trees: an unresolvable source id yields `jj.change_not_found`, not `jj.invalid_input` — an unknown change is `change_not_found` in every verb; `invalid_input` is for a resolvable revision that is not a source, which is what the code does.
  - `[medium]` `[defer]` (blind) No read yields section keys; 5.1 must emit them from `select_tree::sections` — deferred (frontmatter + deferred-work.md "Surfaced in Story 9.50"), Story 5.1 is backlog.
  - `[medium]` `[patch]` (blind) Dart barrel exports none of the new types — `packages/zanshin_core/lib/zanshin_core.dart` now exports `FileSelection`, `HunkKey`, `SelectedTree`, `SourceTree`, `TreeSelection`.
  - `[low]` `[reject]` (blind) A key cannot detect changed text under unchanged line ranges — the intent defines staleness as `left` moved or a key vanished; an edit inside a section of the revision's own content is by rule not stale.
  - `[low]` `[patch]` (blind) select_tree checks input after the snapshot — same fix as the edge row above.
  - `[medium]` `[patch]` (blind) Divergences from the builtin editor (mode toggle, conflict sections) not recorded — added to `select_tree.rs`' divergence list and the ADR-0003 note.
  - `[low]` `[reject]` (blind) The oracle covers one shape only — every I/O-matrix row is covered by `tests/it/select_tree.rs`; the epics witness asks for the three-section `--tool` case, which all three verbs have.
  - `[low]` `[patch]` (blind) squash_plan with trees untested — added `squash_plan_and_squash_agree_on_a_partly_selected_source`.
  - `[false]` `[reject]` (blind) Whole not checked like hunks — see the first edge row: no bad outcome.
  - `[low]` `[patch]` (blind) Stale reason misleading for whole-only files — distinct reasons "<path> can only be selected whole" / "<path> has no changes, so it has no sections" (same code); tests assert them.
  - `[low]` `[reject]` (blind) HunkKey a table, not a struct — a key missing fields reads `{0,0,0,0}`, which is never a real section key (a Different hunk has a non-empty side), so it is refused stale; house style uses tables.
  - `[low]` `[reject]` (blind) Dart HunkKey range check — duplicate of the edge row.
  - `[low]` `[patch]` (blind) epics.md still describes `-> TreeId` — dated 2026-10-23 reconciliation note appended to Story 9.50.
  - `[low]` `[patch]` (blind) deferred-work cites a placeholder instead of a commit — replaced by `90612be` in all three entries.
  - `[low]` `[reject]` (blind) commit.rs computes labels on the tree path — one cheap read, no behavioral effect.
  - `[low]` `[reject]` (blind) Dart models lack `==`/`hashCode`; absent `parent_tree_ids` maps to `[]` — Rust always writes the field; no consumer compares the models yet.
  - `[low]` `[reject]` (blind) Two doc lines overshoot the paragraph width — cosmetic.
  - `[false]` `[reject]` (intent) The oracle never compares section cutting with the CLI (the script writes fixed content) — the epics witness is the CLI's `--tool` run; Zanshin's tree comes from its own cutting of keys 1+3, and tree equality with the CLI's tree checks exactly that cutting.
  - `[medium]` `[defer]` (intent) Whole-only for mode changes / conflicts departs from builtin.rs — deferred as a design decision (frontmatter + deferred-work.md); the divergence is documented.
  - `[medium]` `[defer]` (intent) No read produces keys — grouped with the blind 5.1 row.
  - `[false]` `[reject]` (intent) Op log: only "no op of its own" is tested — same as the edge op-log row; the snapshot op is the CLI's start-up op, and `sections_one_and_three_keep_section_two_and_every_other_file_on_the_left` asserts no op with @ unchanged.
  - `[low]` `[reject]` (intent) I1 witness edits a different file — tree arms check `left` only by the intent's rule; a same-file edit is "own content" and not stale.
  - `[low]` `[patch]` (intent) Process items (Auto Run Result, hashes, verification record) — written in this finalize; `packages/zanshin_core` is a pure Dart package, `dart test` is its runner.

### 2026-10-23 — Review pass
- verdicts: 25 findings — high 0, medium 4, low 15, false 6, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) Conflict labels and multi-id trees never cross the FFI or Dart layers in a test — added `select_tree_ffi::a_conflicted_trees_ids_and_labels_round_trip_through_the_wire` (merge @ with a conflicted file: `zanshin_select_tree` returns 3 ids + 3 labels, `zanshin_commit`'s tree arm stores them, read back by a whole-file selection on the committed revision; a mutation dropping `labels` in the FFI reader fails it) and the Dart mirror `a_conflicted_trees_ids_and_labels_survive_select_tree_and_commit`.
  - `[medium]` `[patch]` (verification-gap) The Dart squash tree arm can be dropped without a test noticing — added `a_partial_squash_tree_leaves_the_unselected_section_in_the_source` (squash @'s sections 1+3 into its parent: parent = 1+3, @ keeps section 2, nothing abandoned); a mutation dropping `trees:` at `SquashCommand` fails it.
  - `[low]` `[reject]` (intent) carried — builtin-editor equivalence is shown against the CLI for one shape only — same claim as the logged "The oracle covers one shape only" row; every matrix row is covered in `tests/it/select_tree.rs`.
  - `[medium]` `[defer]` (intent) carried — no read emits keys; tests fabricate them — the logged 5.1 deferral; not re-added.
  - `[low]` `[reject]` (intent) `jj.stale_selection` for split/squash untested at the FFI and Dart layers — each arm's refusal is asserted at the jj level, and the code travels the one `map_mutate_err` arm (unit-tested) shared by every verb; per-layer copies add nothing.
  - `[false]` `[reject]` (intent) "Nothing selected" with a conflicted left: tree-id equality untested — the intent and the matrix claim content equality only ("left-equal content tree"); nothing claims ids.
  - `[false]` `[reject]` (intent) carried — an unresolvable squash source gives `jj.change_not_found` — logged row: an unknown change is `change_not_found` in every verb.
  - `[low]` `[reject]` (edge) carried — a key cannot see changed text under unchanged line ranges — logged row; the intent's staleness rule.
  - `[false]` `[reject]` (edge) carried — `Whole` on a path absent from the diff selects nothing — logged row; absolute-tree semantics.
  - `[medium]` `[defer]` (edge) carried — no read exposes `sections()` — the logged 5.1 deferral; not re-added.
  - `[low]` `[reject]` (edge) carried — Dart `HunkKey` ints not range-checked — logged row.
  - `[low]` `[reject]` (edge) A tree arm accepts a tree selected in another revision — real only when the caller misroutes a tree between revisions sharing a parent tree; binding the revision is new public surface on the `{tree, left}` contract the intent fixed, and the GUI only passes what `select_tree` returned for that revision.
  - `[false]` `[reject]` (edge) carried — a stale refusal with a dirty @ still writes the snapshot op — logged row; the CLI's own start-up op.
  - `[false]` `[reject]` (blind) carried — content removed from the revision after select_tree still lands in the selected commit (add-then-revert in history) — logged "Source content changed after select_tree" row; the intent makes the tree absolute and own-content edits not stale (I1 as confirmed).
  - `[low]` `[reject]` (blind) A selected tree is not tied to its revision — grouped with the edge provenance row above, same reason.
  - `[low]` `[patch]` (blind) Squash's "a source without a tree moves everything (the editor saved unchanged)" rationale is wrong for the builtin editor, whose lines start unchecked (`builtin.rs:211-222` @ v0.46.0, verified) — `squash_split.rs` module doc and `SquashOptions.trees` now name an external `--tool` saved unchanged and note the builtin editor starts with nothing checked; the behavior is the intent's.
  - `[low]` `[patch]` (blind) Two builtin-editor divergences unrecorded: line sections for added/deleted text files (`builtin.rs:326-345`, verified) and per-line checks inside a section — added to `select_tree.rs`' divergence list and the ADR-0003 note.
  - `[low]` `[reject]` (blind) `Whole` on a directory or vanished path is a silent no-op — the GUI's paths come from `show`'s file changes (files); refusing would add a branch for an input the surface does not produce.
  - `[low]` `[reject]` (blind) A pruned selected tree surfaces as `jj.jj_lib_error`, not stale — needs a gc pruning objects written seconds earlier (git's default prune expiry is two weeks); a mapping branch for a case nobody meets.
  - `[low]` `[reject]` (blind) The "as clap refuses them" lists include the paths+tree refusal, which is Zanshin's own — the phrase marks the timing (before the snapshot) for the whole list, which already held a non-clap item (`edited_description`); rewording six doc blocks plus regenerated bindings for no behavioral effect.
  - `[false]` `[reject]` (blind) Keys go stale on any edit above them — that refusal is the intent's rule ("a key not among the file's current section keys"), with the remedy "the UI re-maps and retries"; the inside-edit half is the carried key-text row.
  - `[low]` `[patch]` (blind) No test for split's none-selected warning on the tree arm — `split_takes_the_tree_as_the_selected_commit` now also splits with an empty selection and asserts `[SplitNoneSelected]`.
  - `[low]` `[reject]` (blind) carried — the oracle covers one shape — logged row.
  - `[low]` `[reject]` (blind) A `SourceTree` without `tree` gets a "left needs an odd number" message; `whole=false` with no hunks selects nothing — hand-built buffers only (the Dart surface always sets both); empty hunks is a legitimate "nothing from this file"; guards for unreachable input.
  - `[low]` `[patch]` (blind) sprint-status 9-50 note still said "Review + closing run pending" — now records both reviews done, closing run pending.

## Design Notes

- Why `left` is ids, not one id: `parent_tree` of a merge can be a conflicted `MergedTree` (several tree ids); a single id would misreport it. Why labels travel: `MergedTreeBuilder::write_tree` keeps the right tree's labels when the side count matches (jj-lib `merged_tree_builder.rs:60-80`); rebuilding them from ids alone would change a conflicted commit's stored labels.
- Why `show` carries `left`: Stories 5.1/5.6 (the inspector's hunk read) are still backlog; without `left` on some read the contract is unusable. `show`'s `file_changes` already diff against exactly that tree (`commit_views.rs:435`); 5.6 extends the same payload.
- Example: left `a\nb\nc\nd\ne\n`, right `A\nb\nC\nd\nE\n` → keys `{0,1,0,1}`, `{2,1,2,1}`, `{4,1,4,1}`; selecting the 1st and 3rd → `A\nb\nc\nd\nE\n`.

## Verification

**Commands:**
- `cargo test -p zanshin-jj` -- all green (incl. `--test it select_tree::`)
- `cargo test -p zanshin-ffi` -- all green (incl. `ffi_abi_doc_sync`)
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo fmt --all --check` -- clean
- `cargo make codegen` -- regenerated files committed, no further diff
- `cargo test -p zanshin-parity --test oracle` -- green, new scenarios pass with no ledger entry
- `cd packages/zanshin_core && dart analyze && dart format --set-exit-if-changed . && dart test` -- green (`flutter test` where the package uses it)

**Verification notes (this run; full gate deliberately NOT run — story-loop gate rule):**
- `cargo fmt --all --check` -- clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj` -- 346 lib + 1156 integration (1 pre-existing `#[ignore]` perf benchmark in `revset.rs`) passed; doctests passed.
- `cargo test -p zanshin-ffi` -- 209 lib + 334 integration passed (incl. `ffi_abi_doc_sync`, `select_tree_ffi`).
- `cargo make codegen` -- exit 0, no drift against the committed generated files (checked after the review patches too).
- `cargo test -p zanshin-parity --test oracle` -- 303 passed (incl. `split_tool_sections_1_3`, `commit_tool_sections_1_3`, `squash_tool_sections_1_3`; no ledger entry).
- `packages/zanshin_core`: `dart analyze --fatal-infos` clean, `dart format --set-exit-if-changed` clean, `dart test test/worker/select_tree_test.dart test/worker/commit_test.dart test/worker/squash_split_test.dart test/worker/commit_views_test.dart test/ffi` -- 525 passed (real cdylib).
- `dart analyze app` -- clean.
- Coverage not measured (loop gate runs it); the new files `crates/zanshin-jj/src/select_tree.rs` and `crates/zanshin-ffi/src/select_tree.rs` have dedicated unit + integration + real-cdylib tests.

**Verification notes (follow-up review pass, 2026-10-23; full gate deliberately NOT run — story-loop gate rule):**
- `cargo fmt --all --check` -- clean (after `cargo fmt --all` reflowed one new test struct literal).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- exit 0.
- `cargo test -p zanshin-jj --test it select_tree::` -- 19 passed; `cargo test -p zanshin-jj --lib` -- 346 passed; `--doc` -- passed.
- `cargo test -p zanshin-ffi --test it select_tree_ffi::` -- 5 passed (incl. the new label round trip); mutation check: `labels` dropped in `crates/zanshin-ffi/src/select_tree.rs`' reader makes it fail (reverted).
- `packages/zanshin_core`: `dart test test/worker/select_tree_test.dart` (Makefile `test-core` env) -- 8 passed; mutation check: `trees:` dropped at `SquashCommand` in `isolate.dart` makes the new partial-squash test fail (reverted); `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed` -- 0 changed.
- No FFI/schema change (no `cargo make codegen`), no jj verb change (no parity oracle run).

## Auto Run Result

Status: done

**Summary.** Story 9.50's contract B is built: `Repo::select_tree(revision, left, files)` cuts each changed file into the builtin diff editor's sections (`ContentDiff::by_line`), keys them as `HunkKey { old_start, old_count, new_start, new_count }` (0-based line ranges per side), builds the tree in `apply_diff_builtin`'s order (start from the revision's tree, reset every changed path to the left, apply whole files / selected sections), writes it to the store with no operation and returns `{tree_ids, labels}`. Added/deleted, mode-changed, binary, symlink, submodule and conflicted files are whole-only (documented divergence for mode toggle and conflict sections). `ShowEntry.parent_tree_ids` is the `left`. `commit`/`split` take a `TreeSelection`, `squash` one `SourceTree` per source; a stale `left` or an unknown key refuses the new `jj.stale_selection`; paths + tree refuse `jj.invalid_input` before the snapshot. FFI `zanshin_select_tree` (85 exports), Dart `RepoHandle.selectTree` + `tree`/`trees` params, three oracle `--tool` scenarios, ADR-0003's open question closed.

**Items.**
- I1 (staleness under constant snapshots) — fixed, commit 90612be: stale = the revision's parent tree ids ≠ `left`, or a key not among the current sections; an edit to the revision's own content is not stale (`tests/it/select_tree.rs::commit_takes_the_tree_and_leaves_the_rest_and_a_later_edit_in_the_new_at`).
- I2 (tree arm of squash/split) — fixed, commit 90612be: `SplitOptions.tree`, `SquashOptions.trees` (per source; a source without one moves everything); split with neither paths nor a tree still refuses `jj.invalid_input` — the CLI's no-paths default is its diff editor, whose GUI replacement is the tree arm; oracle `split_tool_sections_1_3`, `squash_tool_sections_1_3`.
- I3 (GUI-tree arm of commit) — fixed, commit 90612be: `CommitOptions.tree`, refused `jj.stale_selection` when `@`'s parent tree moved; oracle `commit_tool_sections_1_3`.

**Files changed (main).**
- `crates/zanshin-jj/src/select_tree.rs` (new) -- types, sections/keys, staleness, build, arg checks.
- `crates/zanshin-jj/src/{commit,squash_split,op_support,repo,mutate,commit_views,lib}.rs` -- tree arms, `from_tree_id` wired (ids + labels), `StaleSelection`, `parent_tree_ids`, re-exports.
- `crates/zanshin-jj/tests/it/select_tree.rs` (new) + `api_stability.rs` etc. -- every matrix row, labels round trip, squash plan.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/{select_tree (new),commit,squash_split,commit_views,envelope,repo,lib}.rs`, generated header/bindings/accessors -- wire + extern fn.
- `crates/zanshin-ffi/tests/it/select_tree_ffi.rs` (new), `ffi_abi_doc_sync.rs` -- FFI tests, 85 exports.
- `packages/zanshin_core/lib/src/{ffi/select_tree.dart (new),ffi/commit.dart,ffi/squash_split.dart,ffi/commit_views.dart,worker/*}`, `lib/zanshin_core.dart`, `test/worker/select_tree_test.dart` (new) -- Dart surface + real-cdylib test.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- three `--tool` scenarios.
- `docs/{ffi-abi.md,rust-error-codes.md,adr/0003-jj-operation-api-surface.md}`, `_bmad-output/planning-artifacts/epics.md` (dated reconciliation note).

**Review.** 31 findings: 9 patch entries applied (1 medium labels test, 1 medium barrel export, 1 medium divergence doc, 6 low: pre-snapshot checks ×2 rows, squash_plan test, stale reasons, epics note, ledger hash, process), 2 deferred entries (the 5.1 key read; mode toggle + conflict sections — both mirrored into deferred-work.md "Surfaced in Story 9.50"), the rest rejected with reasons in the triage log.

**Follow-up review recommended: true.** Patched at entry verdict: high 0, medium 3, low 6. Unverified risk: the post-review rework of `Repo::select_tree`'s argument path (`with_checked_verb`) and the new label round trip are covered only by targeted tests, and per-file coverage of the two new `select_tree.rs` files is not measured until the loop's final gate.

**Residual risks.** Coverage unmeasured in this run; stale-reason texts are Zanshin's own (no CLI counterpart); a whole-file pick on an unchanged path is a no-op by design.

**Commits.** 90612be (code, docs, schema, generated files, epics note); the spec/ledger/sprint-status commit follows.

### Follow-up review pass (2026-10-23)

**Summary.** Fresh four-layer review of the change since `5cbb777`; no code behavior changed. Tests added where the wire and Dart layers were unverified, docs corrected where they misstated the builtin editor.

**Files changed.**
- `crates/zanshin-ffi/tests/it/select_tree_ffi.rs` -- conflicted tree ids + labels round trip through `zanshin_select_tree` and `zanshin_commit`.
- `packages/zanshin_core/test/worker/select_tree_test.dart` -- partial squash via `trees`; conflicted ids + labels through `selectTree` and `commit(tree:)`.
- `crates/zanshin-jj/tests/it/select_tree.rs` -- split's none-selected warning on the tree arm.
- `crates/zanshin-jj/src/squash_split.rs` -- "moves everything" rationale names an external `--tool` (builtin starts unchecked).
- `crates/zanshin-jj/src/select_tree.rs`, `docs/adr/0003-jj-operation-api-surface.md` -- divergences: added/deleted text files and per-line checks are whole-only here.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- 9-50 note no longer says the review is pending.

**Review.** 25 findings (high 0, medium 4, low 15, false 6). Patched: 2 medium (FFI/Dart label round trip, Dart partial squash), 4 low (squash rationale doc, divergence docs, none-selected test, sprint-status note). Deferred: none new (the two medium rows are the carried 5.1 key-read deferral). Rejected with reasons in the triage log: the carried rows (oracle shape, key text, Whole on absent path, Dart range checks, snapshot op, own-content edits, unresolvable source), tree provenance, stale codes per layer, conflicted-left id equality, directory/vanished `Whole`, pruned trees, clap wording, keys shifting, hand-built FFI buffers.

**Follow-up review recommended: false.** Follow-up pass with no `high` patched (patched at entry verdict: high 0, medium 2, low 4) — converged.

**Residual risks.** Coverage still unmeasured until the loop's final gate; the parity oracle still covers one section shape (accepted).

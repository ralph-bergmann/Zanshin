---
title: 'Story 9.31 — Drop-action capability query (drop_actions + change_actions)'
type: 'feature'
created: '2026-10-21'
status: 'done'
baseline_revision: 'b182577cd1a25a259b1d5134b1f981957524f61f'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      A rebase row's no-op check applies jj-lib's whole move on a dropped transaction, so a hover pays the tree merges of every descendant it would rebase.
    evidence: |-
      rebase_is_no_op runs compute_move_commits + apply (exact by construction); a long stack under the dragged change makes drop_actions as slow as the rebase.
    location: >-
      crates/zanshin-jj/src/rebase.rs rebase_is_no_op
    severity: low
  - summary: >-
      The preview rows stop at the verbs' plan phase, so a template fault the verb hits afterwards still reads Available.
    evidence: |-
      describe/new/squash/split render their templates after the plan fn, and duplicate parses templates.duplicate_description after the location; a malformed template refuses the verb jj.config_error while its row said Available.
    location: >-
      crates/zanshin-jj/src/mutate.rs describe/new_change; squash_split.rs squashed_description/describe_split
    severity: low
  - summary: >-
      edit of the current @ previews Available (Story 9.38 owns the CLI's "Already editing that commit." no-op).
    evidence: |-
      plan_edit has no @ check; the edit verb writes an operation today, so preview and execution agree until 9.38 lands.
    location: >-
      crates/zanshin-jj/src/mutate.rs plan_edit
    severity: low
    resolved: >-
      2026-10-25 — fixed (spec-9-38-edit-current-at-is-noop, commit 5b71805): the card's `edit` row takes `no_op` from `plan_edit`, which reports "already `@`" after the rewritability check.
  - summary: >-
      The rebase dry run still writes git commit objects, refs/jj/keep refs and extra-metadata entries for every commit it rebases, on every hover (signing is dropped).
    evidence: |-
      apply writes through CommitBuilder::write -> GitBackend::write_commit, which keeps a no-gc ref per commit (jj-lib 0.46 git_backend.rs ~:1467); the transaction is dropped, the objects and refs stay until jj util gc.
    location: >-
      crates/zanshin-jj/src/rebase.rs rebase_is_no_op
    severity: low
  - summary: >-
      The bookmark row's "any side of a conflict" fast-forward rule is untested.
    evidence: |-
      is_fast_forward loops over present_adds; the tests use non-conflicted bookmarks only, so an "all sides" regression would pass.
    location: >-
      crates/zanshin-jj/src/bookmark_ops.rs is_fast_forward
    severity: low
    resolved: >-
      2026-10-21 — fixed (spec-9-31-closing-conflicted-bookmark-fast-forward, commit 6691ae0): drop_actions tests with a conflicted bookmark (two sides, and one side deleted) pin the "any side" rule.
  - summary: >-
      The original matrix rows rebase -b, revert, restore, absorb and interdiff are not built (Claude's proposal in the 2026-10-14 design update adopted).
    evidence: |-
      epics.md Story 9.31 design update: "(Claude's proposal) The matrix shrinks to these rows, because nothing consumes the others"; whether Ralph wants them is his decision.
    location: >-
      crates/zanshin-jj/src/drop_actions.rs location_rows
    severity: low
    resolved: >-
      2026-10-21 — fixed (spec-9-31-matrix-rows-rebase-b-revert-restore-absorb-interdiff, commit ad64376): Ralph wanted the rows; rebase -b, revert, restore, absorb and interdiff rows answer from their own plan fns.
---

<intent-contract>

## Intent

**Problem:** The commit graph's drag-and-drop (10.10) and card menu (10.15) need to know, before anything runs, which jj verbs are possible for a dragged change, selection or bookmark at a target, and why not, with the CLI's own refusal. Writing those rules in Dart would copy the verbs' preconditions and drift from them. Four open items name this story: I1 (one shared `plan_*` fn per verb), I2 (no target-less query), I3 (the squash row must say whether a combined description is needed) and I4 (the `new` rows at `-A`/`-B` must use 9.48's precondition).

**Approach:** Two read-only queries in `zanshin-jj`, run behind the same pre-verb snapshot as the verbs and writing no operation of their own. `Repo::drop_actions(source, locations)` returns one row per (verb, location); `Repo::change_actions(change)` returns the 10.15 card-menu rows for one change. Every row is answered by the verb's own pure precondition fn: the existing ones (`plan_new`, `plan_squash`, `prepare_split`), new ones extracted from `edit`/`describe`/`abandon`, and new ports of the CLI's plan phase for `rebase`, `duplicate` and `bookmark move`. The queries are surfaced through FFI and Dart.

## Boundaries & Constraints

**Always:**
- `DropSource` has three variants, `Change(S)`, `Selection { change: S, paths }` and `Bookmark(name)`. `DropLocation { onto, insert_after, insert_before: Vec<ChangeId> }` is the CLI's `-o`/`-A`/`-B` passed through. `locations` is a list, and each row's `location` is an index into it.
- The rows emitted per location are the design's rows, in this fixed order:
  - Change source at an `onto` location: `RebaseSource` (`rebase -s S -o T…`), `RebaseRevisions` (`-r S -o T…`), `Squash` (`--from S --into T`, only when `onto` has exactly one id), `NewMerge` (`new T… S`) and `Duplicate` (`duplicate S -o T…`).
  - Change source at an `-A`/`-B` location: `RebaseRevisions` only.
  - Selection source at an `onto` location with one id: `Squash` with the paths.
  - Selection source at an `-A`/`-B` location: `Split` (`split -r S <paths> -A/-B …`).
  - Bookmark source at an `onto` location with one id: `BookmarkMove` (`bookmark move N --to T`). No other rows for a bookmark source.
- A location that is all-empty, or that combines `onto` with `-A`/`-B`, fails the whole query with `MutateError::InvalidInput`, using `compute_commit_location`'s two messages. This check runs before anything resolves, as clap's would.
- A row's outcome is `ActionOutcome { status: Available | NoOp | Refused, refusal: Option<MutateError>, combined_description_needed: bool, allow_backwards_needed: bool }`.
  - `Refused` carries exactly the `MutateError` the verb would return: the same variant and the same text. Any `MutateError` from a row's plan becomes that row's refusal, except `Backend` and `Precondition`, which fail the whole query.
  - `NoOp` means the verb would write no operation:
    - rebase: when jj-lib's `compute_move_commits` + `find_duplicate_divergent_commits` + `apply` on a transaction that is then dropped leaves `!has_changes()` (the CLI's "Nothing changed." guard).
    - squash: when `plan_squash` plans nothing (`squashed: None`).
    - bookmark move: when the bookmark already points at T, or no local bookmark has that exact name.
    - No other verb ever reports `NoOp`.
- Each row's plan runs on its own transaction from ONE `load_at_head`, and the transaction is dropped. The warnings a row's plan pushes are discarded. The call's warnings are the precondition's only.
- Rebase plan ports (`git -C ../jj show v0.46.0:cli/src/commands/rebase.rs:431-599`):
  - `plan_rebase_revisions`: rewritable targets, then `compute_commit_location(.., "rebased commits")`, then with `-o` the refusal `Cannot rebase <12hex> onto itself`.
  - `plan_rebase_source`: rewritable sources, then the location, then with `-o` `check_rebase_destinations` (`onto itself` / `Cannot rebase <12hex> onto descendant <12hex>`). All of these are `InvalidInput`.
- `plan_duplicate` (`duplicate.rs` @ v0.46.0):
  - root → `InvalidInput "Cannot duplicate the root commit"`;
  - then the location (`"duplicated commits"`), resolving the immutable set only for `-A`/`-B`.
- `plan_bookmark_move`:
  - exact-name local bookmark; already at T → NoOp;
  - otherwise not a fast-forward (the CLI's `is_fast_forward`: some present add of the old target is an ancestor of T; an absent target counts as a fast-forward) → Available with `allow_backwards_needed`;
  - otherwise Available.
- The squash rows' `combined_description_needed` uses ONE rule shared with `squashed_description`: Combine mode, and `try_combine_messages` returns `None`.
- `plan_new` gains the Git backend's root-merge refusal up front, for 2+ parents including the root on a Git-backed store: `InvalidInput` with the backend's text verbatim, "The Git backend does not support creating merge commits with the root commit as one of the parents.". `new_change` and the `NewMerge` row agree.
- `change_actions(X)` → `ChangeActions` with seven named outcomes:
  - `new_onto` (`plan_new([X])`), `new_insert_after` (`-A X`) and `new_insert_before` (`-B X`);
  - `edit`, `describe`, `squash_into_parent` (`squash -r X`, carrying the flag) and `abandon`, each from its verb's newly extracted plan fn. `edit`, `describe` and `abandon` call the same fn.
- An id that does not resolve, whether S, a target or X, refuses each affected row with `ChangeNotFound`. It never fails the query.
- FFI:
  - `DropActionsRequest`, with a new `RequestKind::DropActions` appended, is read by `zanshin_drop_actions`. `zanshin_change_actions` takes a C string like `zanshin_edit`.
  - The payloads `DropActions` and `ChangeActions` are appended to `Payload`. The row refusal is an `FfiError`, mapped through `map_mutate_err`.
  - Dart gets `RepoHandle.dropActions(source, locations)` and `RepoHandle.changeActions(changeId)`.
  - Docs: `docs/ffi-abi.md` and `docs/rust-error-codes.md` ("also emitted" clauses only, no new code).

**Never:** a new error code; a new verb or any execution; UI code; MCP; hunk selections (9.50); `rebase -b`, `revert`, `restore`, `absorb` or `interdiff` rows; `-s` at `-A`/`-B`; `duplicate` at `-A`/`-B`; Zanshin-only refusals the CLI does not make (`new T S` with T == S stays Available: the CLI's dedup); hand-copied verb rules in the query module; `cargo make test`/`test-full`/`coverage` (run gate rule).

## I/O & Edge-Case Matrix

The fixture is a Git-backed repo: root → A → B → C, with D a second child of A. Descriptions are non-empty, and `immutable_heads()` is configurable per test. "imm(x)" means `Immutable { commit_id: x hex }`.

| Scenario | Input | Expected rows |
|---|---|---|
| Onto parent | Change B, onto [A] | -s NoOp; -r Available (C moves); Squash Available + combined_description_needed; NewMerge Available; Duplicate Available |
| Onto descendant | Change B, onto [C] | -s Refused "Cannot rebase <B> onto descendant <C>"; -r Available; Squash Available |
| Onto itself | Change B, onto [B] | -s / -r Refused "Cannot rebase <B> onto itself"; Squash NoOp; NewMerge Available; Duplicate Available |
| Onto root | Change B, onto [root] | -s/-r Available; Squash Refused imm(root); NewMerge Refused (Git root-merge text); Duplicate Available |
| Immutable source | Change A ∈ immutable, onto [D] | -s/-r/Squash Refused imm(A); NewMerge, Duplicate Available |
| Root source | Change root, onto [A] | Duplicate Refused "Cannot duplicate the root commit"; rebase rows Refused imm(root) |
| Insert locations | Change C, -A [A] / -B [B] / -A [A] -B [B] | one RebaseRevisions row each; an immutable child of the `-A` target → imm; a loop location → the CLI loop text |
| Unknown id | Change "zzzz…", onto [A] | every row Refused ChangeNotFound |
| Bad location | onto [A] + -A [A], or all empty | query Err InvalidInput |
| Selection | Selection{B, ["f"]}, onto [A] / -A [A] | Squash row / Split row; Selection{B, []} at -A → Split Refused (split's no-paths text) |
| Bookmark | bookmark on B; onto [C] / [D] / [B] / unknown name | Available / Available + allow_backwards_needed / NoOp / NoOp |
| change_actions | X = B; X = root | B: all Available, squash_into_parent with the flag; root: edit imm(root), describe / abandon InvalidInput root texts, new_onto Available, new_insert_before Refused imm(root), squash_into_parent Refused (squash's text) |
| Agreement | each SHIPPED verb row (Squash, NewMerge, Split, every change_actions row) | running the verb on a fresh fixture: Available ⇒ Ok with a new op; NoOp ⇒ Ok, head op unchanged; Refused ⇒ Err with the same variant and text |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs`:
  - `:854-934` — `NewLocation`, `plan_new`, `given`. Add the root-merge refusal after the dedup resolution, only for the positional-parents path: `-A`/`-B` can never yield root plus another parent, because `-B root` refuses as immutable.
  - `:809-849` `describe`, `:1060-1077` `edit`, `:1097-1178` `abandon` — extract `plan_describe` / `plan_edit` / `plan_abandon` (resolve + root guard + `guard_rewritable`, in today's order). The verbs then call them and their behaviour stays byte-identical.
  - `:533` — `guard_rewritable`.
- `crates/zanshin-jj/src/squash_split.rs`:
  - `:234` — `plan_squash`, whose `squashed: Option<SquashDecision>` is the NoOp signal.
  - `:499-542` — `squashed_description`. Extract `fn single_description(decision, destination) -> Option<String>`; the flag is `matches!(mode, Combine) && single.is_none()`.
  - `:563` — `prepare_split` (with `paths`, `insert_after`/`insert_before` as `Some(vec)`).
- `crates/zanshin-jj/src/op_support.rs`:
  - `:110` `check_rewritable`, `:172` `compute_commit_location`, `:85` `resolve_immutable`;
  - `:582` `resolve_ordered`, `:553` `resolve_commit`, `:807` `start_repo_transaction`.
  - The 12-hex form is `format!("{id:.12}")` (see `:256`).
- jj-lib 0.46.0 `rewrite.rs`:
  - `:667` `compute_move_commits`, `:635` `record_to_abandon`, `:639` `apply`, `:1484` `find_duplicate_divergent_commits`;
  - `MoveCommitsLocation`/`MoveCommitsTarget` at `:594-608`;
  - `repo.rs:1074` `has_changes`.
  - The CLI's rebase options: `EmptyBehavior::Keep`, `delete_abandoned_bookmarks: false`, `simplify_ancestor_merge: false`.
- CLI prior art (`git -C ../jj show v0.46.0:<path>`):
  - `cli/src/commands/rebase.rs:369-599`;
  - `cli/src/commands/duplicate.rs` (`cmd_duplicate`);
  - `cli/src/commands/bookmark/move.rs` (exclusion of no-op matches, `allow_backwards`);
  - `cli/src/commands/bookmark/mod.rs:165-182` (`is_fast_forward`);
  - `cli/src/commands/squash.rs:363-396`.
  - jj-lib `git_backend.rs:1345-1355` (the root-merge text).
- `crates/zanshin-jj/src/bookmark_ops.rs` — home of `plan_bookmark_move`, for 9.19 to reuse.
- `crates/zanshin-jj/src/repo.rs`:
  - `:378` `with_verb`;
  - `:2362` `squash_plan` (the template for a read query: `repo.workspace()`, "Writes NO operation of its own");
  - `:1132` `new_change`.
- `crates/zanshin-jj/src/lib.rs:56,101` — module declarations + re-exports.
- `crates/zanshin-jj/tests/it/`:
  - `api_stability.rs:1085-1147` — the per-story surface test pattern;
  - `squash_split.rs:112,157` and `new_insert.rs:114,189` — `base()` fixture, `assert_refused_without_an_operation`, `head_op`;
  - `main.rs` — module list.
- `schemas/envelope.fbs`:
  - `:75-114` `RequestKind` (APPEND `DropActions`; update the "other 34 tables" count in `:51-73`);
  - `:26` `FfiError`;
  - `:185` `SquashRequest` (request-table template);
  - `:1261` `SquashPlan`;
  - `:1934-1980` `Payload` (APPEND).
- `crates/zanshin-ffi/src/`:
  - `squash_split.rs:51,199-210` — reader + extern template;
  - `repo.rs:146` `map_mutate_err`, `:1187` `zanshin_edit` (C-string template);
  - `envelope.rs:516,540,552,580,628,787,866,985` — `precondition_envelope`, `reject_null_request`, `invalid_request`, `expect_request_kind`, `session_from_handle`, the `ok_squash_plan` template, `finish_envelope`, `catch`.
- `crates/zanshin-ffi/tests/it/`:
  - `ffi_abi_doc_sync.rs:37` — `EXPECTED_EXPORTS` 73 → 75;
  - `squash_split_ffi.rs` (template), `main.rs`.
- Codegen outputs (committed):
  - `crates/zanshin-ffi/src/envelope_generated.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`;
  - `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `packages/zanshin_core/lib/src/ffi/bindings.dart`.
- Dart `packages/zanshin_core`:
  - `lib/src/ffi/squash_split.dart:101-121,177,225-228` — adapter, model and decode templates;
  - `lib/zanshin_core.dart:64` — exports;
  - `lib/src/worker/commands.dart:1475` (`SquashPlanCommand`, sealed `WorkerCommand`);
  - `lib/src/worker/isolate.dart:1411-1436,2911-2939`;
  - `lib/src/worker/handle.dart:778-800`;
  - tests in `test/ffi/squash_split_test.dart` (decode) and `test/worker/squash_split_test.dart` (real cdylib + closed handle).
- Docs:
  - `docs/ffi-abi.md:221,388-395,468,521,1204` — counts, symbol index, payload sections;
  - `docs/rust-error-codes.md:34+` — the `jj.invalid_input` row's "also emitted" for `zanshin_new_change`'s root merge.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- add the `plan_new` root-merge refusal (Git backend only, detected through the store's backend name); extract `plan_describe`/`plan_edit`/`plan_abandon` and call them from the verbs -- shared preconditions (I1).
- `crates/zanshin-jj/src/squash_split.rs` -- `single_description` helper shared by `squashed_description` and a `pub(crate) fn combined_description_needed(&PlannedSquash) -> bool` -- I3 without duplicating the rule.
- `crates/zanshin-jj/src/rebase.rs` (new) -- `plan_rebase_revisions`, `plan_rebase_source`, `check_rebase_destinations` (pure, return `MoveCommitsLocation`) plus `rebase_is_no_op(tx, &loc)` (dropped-tx apply) -- for 9.16 to reuse.
- `crates/zanshin-jj/src/duplicate.rs` (new) -- `plan_duplicate` -- for 9.9 to reuse.
- `crates/zanshin-jj/src/bookmark_ops.rs` -- `plan_bookmark_move(repo, name, target) -> BookmarkMovePlan { NoOp | FastForward | Backwards }` -- for 9.19 to reuse.
- `crates/zanshin-jj/src/drop_actions.rs` (new) -- public types (`DropSource`, `DropLocation`, `DropVerb`, `ActionStatus`, `ActionOutcome`, `DropAction`, `DropActions`, `ChangeActions`) and `drop_actions`/`change_actions` composing the plan fns per the row rules. Inline unit tests for location validation and outcome mapping.
- `crates/zanshin-jj/src/lib.rs`, `repo.rs` -- module and re-exports; `Repo::drop_actions(&DropSource, &[DropLocation])` and `Repo::change_actions(&ChangeId)` via `with_verb`, with full `# Errors` docs.
- `crates/zanshin-jj/tests/it/drop_actions.rs` (+ `main.rs`) -- the I/O matrix as tests, plus the agreement tests for every shipped-verb row; `api_stability.rs` gains the surface section; `new_insert.rs` gains a root-merge refusal test for `new_change`.
- `schemas/envelope.fbs` then `cargo make codegen` -- `DropLocation`, `DropSourceKind`, `DropActionsRequest`, the enums `DropVerb` and `ActionStatus`, the tables `ActionOutcome`, `DropAction`, `DropActions` and `ChangeActions`; append to `RequestKind` and `Payload`; commit the generated files.
- `crates/zanshin-ffi/src/drop_actions.rs` (new, + `lib.rs`), `envelope.rs` -- the request reader, the two externs with `# Errors`, `ok_drop_actions`/`ok_change_actions` plus unit tests; `tests/it/drop_actions_ffi.rs` (kind refusal, null buffer, round trip); `EXPECTED_EXPORTS` → 75.
- `packages/zanshin_core` -- `lib/src/ffi/drop_actions.dart` (request build, models, decode), commands, isolate, handle, exports; `test/ffi/drop_actions_test.dart` (decode contract) and `test/worker/drop_actions_test.dart` (real cdylib, both calls, closed handle).
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- symbol rows, counts, a "## `DropActions` / `ChangeActions` payloads" section, also-emitted clauses.
- `_bmad-output/implementation-artifacts/deferred-work.md`, `sprint-status.yaml` -- dated resolution notes on I1–I4. The 9-9/9-16/9-19 notes name the created plan fns. The 9-31 entry → done.

**Acceptance Criteria:**
- Given any drop, when `Repo::drop_actions` returns, then the head operation is unchanged apart from the pre-verb snapshot, and no row text differs from the error the corresponding verb returns (agreement tests).
- Given `RepoHandle.dropActions` / `changeActions` in Dart against the real cdylib, when called on a fixture, then the decoded rows carry the verb, location index, status, refusal code/context and both flags as the Rust query produced them.
- Given `new_change([T, root])` on a Git-backed repo, when it runs, then it refuses `jj.invalid_input` with the Git backend's text before any write, matching the `NewMerge` row.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 34 findings — high 3, medium 7, low 17, false 7, maybe-false 0
- findings:
  - `[medium]` `[patch]` (edge-case) a rebase row at `onto [root, X]` makes the dry-run `apply` hit the Git backend's `Unsupported`, which fails the whole query — verified: `rebase.rs::rebase_is_no_op` → `be` → `MutateError::Backend` → `outcome()` Err. Fix: `Unsupported(message)` becomes an `InvalidInput` row refusal with the backend's text; test at `onto [root, D]`.
  - `[medium]` `[patch]` (edge-case) the same `Unsupported` for `-r S` where S's parent is the root and S has a merge child — same root cause and fix as the row above.
  - `[low]` `[patch]` (edge-case) the Duplicate row at `onto [root, X]` says Available, but the duplicate would fail at its write — verified: `plan_duplicate` has no root-merge check. Fix: `refuse_git_root_merge` on its location parents.
  - `[medium]` `[patch]` (edge-case) `plan_new`'s `-A`/`-B` branch can yield root + another parent (`-B` takes the targets' parents), still failing at the write as `jj.jj_lib_error` while the doc calls it unreachable — same root cause as the Duplicate row. Fix: `refuse_git_root_merge` on the computed parents; doc corrected; `new_insert` test.
  - `[low]` `[patch]` (edge-case) the Selection doc says "empty = every path", but the split row refuses empty paths — true for squash only; the behaviour is the verb's (agreement). Docs corrected in Rust and Dart.
  - `[low]` `[defer]` (edge-case) `change_actions.edit` on the current `@` says Available, while the CLI says "Already editing that commit." — pre-existing in the verb (Story 9.38); preview ⇔ execution agree today. Already in deferred-work's 9.31 section.
  - `[low]` `[reject]` (edge-case) the Dart `_outcome` does not enforce refusal ⇔ Refused — the only producer is the Rust `outcome()`, which pairs them by construction; a guard adds a branch for a buffer no caller builds.
  - `[high]` `[patch]` (edge-case) the dry-run `apply` writes commits through `CommitBuilder::write`, which signs them under `signing.behavior` own/keep/force — verified in jj-lib 0.46 `commit_builder.rs:473` (`should_sign` from the repo settings): a hover could prompt the signer (e.g. 1Password). Fix: the dry run loads the head with `signing.behavior = "drop"`. The remaining store writes (git objects, `refs/jj/keep/*`, extra metadata) are deferred, Low.
  - `[medium]` `[patch]` (verification-gap) nothing proves that row plan warnings are discarded, or that the precondition's are kept — fixtures push no row warning. Fix: a test with squash's unmatched-paths warning and split's all-selected warning, asserting the query reports none and the verbs record them.
  - `[low]` `[defer]` (verification-gap) the conflicted-bookmark "any side" fast-forward rule is untested — conflicted local bookmarks are rare, and 9.19's move verb will need the same test.
  - `[high]` `[patch]` (verification-gap, other) `rebase_is_no_op` has lasting effects (objects, keep refs, signing) — same root cause as the signing row above; same fix plus the same deferral.
  - `[medium]` `[patch]` (verification-gap, other) `onto [root, X]` fails the whole `drop_actions` call — same as the first row.
  - `[medium]` `[patch]` (verification-gap, other) the root-merge refusal covers positional parents only — same as the `plan_new` `-A`/`-B` row.
  - `[medium]` `[patch]` (blind) several `onto` targets including the root break the rebase rows and mislead the duplicate row — the same two root causes; fixed by both patches above.
  - `[high]` `[patch]` (blind) "writes NO operation" hides real writes to the store on every hover — the same root cause as the signing row; signing fixed, store writes deferred Low.
  - `[low]` `[reject]` (blind) `DropSourceKind` / `ActionStatus` have no `Unspecified = 0` — harm only for a producer that omits the field, and both are only built by this diff's own builder and encoder; the fix adds an enum member and a validation branch.
  - `[low]` `[reject]` (blind) the Dart decoder does not check refusal ⇔ Refused, and throws `StateError` on an unknown enum value — the same producer argument as the edge-case row; the enums are append-only, with the Dart side regenerated in the same commit.
  - `[false]` `[reject]` (blind) `outcome()` deny-lists only Backend/Precondition, so other variants would become row refusals — no row plan can return them: every row passes an explicit revision or `from`/`into` (no `resolve_or_wc(None)` → `NoWorkingCopy`), and no plan locks a working copy or touches the network.
  - `[low]` `[patch]` (blind) sprint-status 9-9/9-16/9-19 notes say "the verb calls it" for verbs that do not exist — reworded to "is meant to call (Story 9.x)".
  - `[low]` `[patch]` (blind) `new_change`'s new root-merge refusal has no parity-oracle scenario — added `new_change([B, root])` vs `jj new B root()`.
  - `[low]` `[patch]` (blind) `change_actions` is never run on a non-root immutable change — added the B-immutable test. (Merge, `@`, divergent: same plan fns, pinned by the verbs' own tests.)
  - `[low]` `[reject]` (blind) no repo test for a row's `jj.config_error`, a kept precondition warning, or a dirty working copy — the config refusal lives in the shared plan fns, already pinned by the verbs' tests; the warning restore is covered by the new warning test; the snapshot path is `with_verb`'s, shared with every verb.
  - `[low]` `[patch]` (blind) the deferred template-fault entry misses `duplicate` (`templates.duplicate_description` is parsed after the location in `cmd_duplicate`) — added. Not acted on: the discarded "Duplicating … as a descendant/ancestor of itself" warnings, which the contract discards on purpose.
  - `[low]` `[reject]` (blind) the NewMerge row does not say when T == S dedups to a plain `new S` — CLI parity, kept on purpose (spec Never); the caller knows S and T.
  - `[low]` `[reject]` (blind) each row re-resolves the immutable set — a few revset evaluations per hover; caching would add shared state across plan fns, which the design keeps independent.
  - `[false]` `[reject]` (blind) `zanshin_change_actions` borrows the handle before reading `change_id`, unlike `zanshin_drop_actions` — it mirrors `zanshin_edit` (`crates/zanshin-ffi/src/repo.rs:1187-1197`), the established order of the C-string wrappers.
  - `[low]` `[patch]` (intent) agreement covers only shipped verbs, while I1 is struck as resolved and the sprint notes speak in present tense — the wording is fixed with the sprint-status row above; the verbs' own call sites are 9.9/9.16/9.19's.
  - `[false]` `[reject]` (intent) I4 is answered on `change_actions`, not `drop_actions`, and its `-A`/`-B` refusals are not exercised — the design has no `new` row at `-A`/`-B` in the drop menu (the "+" chip is the card menu's), and `plan_new`'s `-A`/`-B` refusals are pinned in `new_insert.rs`; the row calls that same fn.
  - `[false]` `[reject]` (intent) settling I2 here is the less conservative reading — the intent says "settle it here if the story's text supports it", and the text says "lives here or in its own story".
  - `[false]` `[reject]` (intent) I3's flag is on every squash row, not only the selection's — a superset of what was asked; the rule is the one `squashed_description` uses, so the extra rows cannot disagree.
  - `[false]` `[reject]` (intent) a shipped verb's behaviour changes (`new_change`'s up-front root-merge refusal) — sanctioned by the story ("the Git backend's refusal reproduced up front") and tested; the oracle scenario is added above.
  - `[low]` `[defer]` (intent) the original matrix rows (`rebase -b`, `revert`, `restore`, `absorb`, `interdiff`) are not built — this adopts Claude's proposal in the 2026-10-14 update; whether Ralph wants them is his decision.
  - `[low]` `[reject]` (intent) the fixture matrix is sampled, not a full verb × relation × location cross — every relation the plan fns branch on is covered (parent, descendant, itself, root, immutable source/target/child, loop, unknown, two targets); the remaining cells add no branch.
  - `[false]` `[reject]` (intent) no `## Auto Run Result` yet — it is written at finalize, after the review.

### 2026-10-21 — Review pass (follow-up)
- verdicts: 33 findings — high 0, medium 1, low 28, false 4, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) `change_actions.new_onto` reads Available while `new_change` refuses a malformed `experimental-advance-branches` (parsed after `plan_new`, `mutate.rs:1035-1036`; the CLI reads it before its transaction) — verified; a malformed experimental key is rare, and the fix threads the config into `plan_new`. Same class as the deferred template-fault entry; the verb's refusal stays authoritative.
  - `[low]` `[reject]` (blind) the new enums have no `Unspecified = 0` — carried: the logged reject (only this diff's builder and encoder produce them); `DropVerb` is the same argument.
  - `[low]` `[reject]` (blind) nothing enforces refusal ⇔ Refused in the Rust obj or the Dart decoder — carried: the logged reject (one producer, `outcome()`, pairs them by construction).
  - `[low]` `[patch]` (blind) `zanshin_new_change`'s FFI rustdoc and Dart `RepoHandle.newChange` do not name the up-front root-merge `jj.invalid_input` — verified (`crates/zanshin-ffi/src/repo.rs` `jj.invalid_input` bullet; `handle.dart` newChange). Fixed: both docs name it.
  - `[low]` `[patch]` (blind) `rebase_is_no_op` builds a `RepoLoader` and loads the operation again for every rebase row — verified: twice per `-o` location. Fixed: `rebase::load_dry_run_head` loads the head ONCE per call with signing dropped, in `with_rows`; every row's transaction starts from it, and `rebase_is_no_op(tx, loc)` applies on the row's own transaction (the spec's "ONE `load_at_head`").
  - `[low]` `[patch]` (blind) test gaps: no `RebaseRevisions` NoOp witness, no empty-paths Selection squash row, no divergent-duplicate move — verified. Fixed: `a_leaf_dropped_onto_its_parent_is_a_no_op_for_both_rebase_rows` (D onto A) and the empty-paths Squash row in the selection test. Not added: the divergent path, which needs a divergent fixture for a branch that is jj-lib's own `find_duplicate_divergent_commits` passed through.
  - `[low]` `[reject]` (blind) the hand-ported refusal texts have no parity-oracle scenario — verified true; the texts were checked verbatim against `git -C ../jj show v0.46.0:cli/src/commands/{rebase,duplicate}.rs` (`:462`, `:586`, `:592`, `:124`, "rebased commits"/"duplicated commits") in this pass. An oracle scenario needs an executing Zanshin verb, which 9.16 / 9.9 / 9.19 add with their own scenarios.
  - `[low]` `[patch]` (blind) stale planning notes: the 9-18 sprint-status NOTE still says 9.31 previews revert; the deferred-work `rebase -s/-b` with `-A`/`-B` entry still asks 9.31 to mirror the verb — verified. Fixed: dated notes on both (9-18 moot, the corner sidestepped by offering no `-s` at `-A`/`-B`, 9.16 still owes its test). The RESOLVED I1/I2 lines keep their original text after the resolution by the ledger's convention — not changed.
  - `[low]` `[reject]` (blind) `read_drop_actions_request` ignores fields foreign to the source kind, and an absent `paths` reads as every path — the only producer is the Dart builder this diff ships, tested by its decode contract; refusing foreign fields adds validation branches for buffers no caller builds.
  - `[low]` `[reject]` (blind) the bookmark row's NoOp covers both "already there" and "no such bookmark" — the intent-contract fixes exactly that (NoOp "when the bookmark already points at T, or no local bookmark has that exact name"); changing it edits the spec.
  - `[false]` `[reject]` (blind) `ChangeActionsObj`'s positional `[ActionOutcomeObj; 7]` can swap rows silently — the envelope unit test (`crates/zanshin-ffi/src/envelope.rs` ~:1680-1720) builds seven DISTINCT outcomes and checks each named field, so any order mismatch between `From` and `ok_change_actions` fails it.
  - `[low]` `[reject]` (blind) `#[allow(dead_code)]` on `DuplicatePlan` should be `#[expect(dead_code)]` — the workspace has no `#[expect(` anywhere; `#[allow]` + a WHY comment is the established style.
  - `[low]` `[patch]` (blind) `Repo::new_change` and `plan_new` rustdocs were edited without reflowing — verified. Fixed: reflowed.
  - `[low]` `[reject]` (edge-case) the Split row at an `-A`/`-B` location whose parents include the root and another commit reads Available while `split` fails at its write — verified (`prepare_split` has no `refuse_git_root_merge`); needs two `-A`/`-B` targets, which no single drop gap produces, and the fix adds a guard to the shipped split verb (changing its error code).
  - `[low]` `[defer]` (edge-case) every rebase hover writes git commits / keep refs — carried: deferred (Surfaced in Story 9.31).
  - `[low]` `[defer]` (edge-case) `edit` of the current `@` reads Available — carried: deferred (Story 9.38).
  - `[low]` `[defer]` (edge-case) the Duplicate row misses a malformed `templates.duplicate_description` — carried: the deferred template-fault entry names `duplicate`.
  - `[low]` `[reject]` (edge-case) `DropSourceKind` has no `Unspecified` — carried: the logged reject.
  - `[low]` `[reject]` (edge-case) the Dart decoder accepts a status/refusal mismatch — carried: the logged reject.
  - `[low]` `[reject]` (edge-case) AC claim: the Split row at `-A root -A X` disagrees with the verb — same root cause and reason as the Split row above.
  - `[low]` `[patch]` (verification-gap) the precondition's warnings are never shown to survive the query — verified: every test asserts an empty list. Fixed: `the_preconditions_warnings_are_the_queries_warnings` (a bad `revset-aliases` entry: `drop_actions` and `change_actions` each return exactly `status`'s `[ConfigAliasInvalid]`); it fails when `with_rows` drops them (checked by mutation).
  - `[medium]` `[patch]` (verification-gap) nothing runs the rebase dry run with signing configured — verified. Fixed: `the_rebase_dry_run_never_invokes_the_signer` (`signing.behavior = "force"`, ssh backend with `program = "false"`): the rebase rows answer, and `new_change` on the same repo fails, proving the config is live; it fails when `with_rows` loads the plain head (checked by mutation).
  - `[low]` `[patch]` (verification-gap) swapping `-A` and `-B` in the FFI reader passes every test — verified. Fixed: `selection_and_bookmark_sources_round_trip` sends `-A root` (Available) and `-B root` (Refused `jj.immutable`); it fails with the reader's two lists swapped (checked by mutation).
  - `[low]` `[patch]` (intent) the rebase no-op runs on a second, re-loaded transaction, not the row's own one from ONE `load_at_head` — same root cause and fix as the per-row reload above.
  - `[low]` `[defer]` (intent) the queries are read-only only at the op-log level; the dry run writes store objects — carried: deferred.
  - `[low]` `[reject]` (intent) the unshipped rows' texts are checked against hand-written strings, not the stock CLI — same as the oracle row above.
  - `[low]` `[patch]` (intent) I1's "the verb calls the same fn" is unverifiable for the unshipped verbs — carried: the wording was fixed in the first pass; no further action.
  - `[false]` `[reject]` (intent) the root-merge refusal reaches `plan_duplicate` and the rebase rows beyond the intent's `plan_new` — the CLI refuses those with the same backend text at the write, so they are not Zanshin-only refusals; the first pass's patch, tested.
  - `[low]` `[reject]` (intent) the location check runs after the pre-verb snapshot, not before it as clap's does — every Zanshin verb's argument checks run inside `with_verb` after its snapshot; the spec promises only "before anything resolves", which `a_malformed_location_fails_the_whole_query_before_resolving` pins.
  - `[low]` `[patch]` (intent) "the call's warnings are the precondition's only" was tested only with none — same root cause and fix as the precondition-warnings row above.
  - `[low]` `[defer]` (intent) the conflicted-bookmark fast-forward rule is untested — carried: deferred (Story 9.19).
  - `[false]` `[reject]` (intent) the FFI refuses a missing `change_id` / `bookmark` (`jj.invalid_input`) and an unknown kind (`ffi.invalid_argument`) without the intent saying so — both are existing codes used as every request reader uses them; no defect.
  - `[false]` `[reject]` (intent) the tests assert rows the matrix leaves unspecified — additions on the same surface that contradict nothing; no defect.

## Design Notes

- **Rows = the design's rows (decision (a4); Claude's proposal adopted).** Nothing consumes `rebase -b`, `revert`, `restore`, `absorb` or `interdiff`. I1's extraction duty therefore covers only the shipped verbs whose rows this story answers: `new`, `squash`, `split`, `edit`, `describe` and `abandon`.
- **Several locations per call (the update's proposal):** one card hover asks for `[onto T, -A T, -B T]` in one call.
- **I2 lives here.** The story text allows "here or in its own story". The target-less query reuses the same plan fns and outcome type, and 10.15 needs it now.
- **NoOp exactness for rebase.** "Parents already equal" is wrong for `-r` when S has children: they are rebased onto S's parents, so the repo changes. The only exact answer is jj-lib's own move applied on a dropped transaction, which is what the verb will run. Its cost (tree merges for every rebased descendant) is accepted and deferred as Low.
- **Row refusal = the verb's `MutateError`.** The FFI maps it through `map_mutate_err`, so preview and execution share code and context by construction. A broken `immutable_heads()` alias is the verb's `Config` refusal on the rows that resolve it. Row-plan warnings are discarded because the verb reports its own when it runs.
- **The squash flag (I3) is a bool.** The UI then calls `squash_plan` for the text, as 10.25/10.27 already plan to.
- `edit` of the current `@` stays Available until 9.38 makes `plan_edit` report it. That keeps preview ⇔ execution in agreement today.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it drop_actions::` / `new_insert::` / `squash_split::` / `mutate::` / `content_ops::` / `api_stability::` -- expected: pass
- `cargo test -p zanshin-jj --lib` and `cargo test -p zanshin-ffi` -- expected: pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean
- `cargo make codegen` -- expected: generated files committed, no diff afterwards
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (`plan_new` changed)
- In `packages/zanshin_core`: `flutter test` (or `dart test`), `dart analyze`, `dart format --set-exit-if-changed .` -- expected: pass/clean

**Verification notes (run gate rule: targeted checks only, no `cargo make test` / `test-full` / `coverage`), all on the final tree:**
- `cargo test -p zanshin-jj` — lib 291 passed; `it` 976 passed, 1 ignored (the pre-existing `revset.rs` 10k benchmark).
- `cargo test -p zanshin-ffi` — 192 unit + 306 `it` passed (`ffi_abi_doc_sync` at 75 exports included).
- `cargo test -p zanshin-parity --test oracle` — 191 passed (182 scenarios, `new_merge_with_root` new).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — run after the last schema edit; a second run changed nothing.
- `packages/zanshin_core`: `cargo make --allow-private test-core` (`dart test`, gate env) — 926 passed; `test-core-analyze` — no issues; `test-core-format` — 0 changed. `dart analyze` in `app/` — no issues.
- Matrix audit: every I/O-matrix row has a passing test in `crates/zanshin-jj/tests/it/drop_actions.rs` (plus `new_insert.rs::a_merge_with_the_root_is_refused_with_the_git_backend_text`).
- Coverage not measured (run rule). `duplicate.rs`'s no-location branch is reached by no row.

**Verification notes, follow-up review pass (2026-10-21, same run gate rule), all on the final tree:**
- `cargo test -p zanshin-jj` — lib 291 passed; `it` 979 passed, 1 ignored (3 new `drop_actions` tests).
- `cargo test -p zanshin-ffi` — 192 unit + 306 `it` passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — exit 0.
- Mutation checks (each reverted afterwards): `with_rows` on the plain head fails `the_rebase_dry_run_never_invokes_the_signer`; dropping the precondition warnings fails `the_preconditions_warnings_are_the_queries_warnings`; swapping the FFI reader's `insert_after`/`insert_before` fails `selection_and_bookmark_sources_round_trip`.
- `packages/zanshin_core`: `cargo make --allow-private test-core` — 926 passed; `test-core-analyze` — no issues; `test-core-format` — 0 changed (only a doc comment changed there).
- Not run: `cargo make codegen` (no schema/FFI surface change), the parity oracle (no verb changed), `cargo make test` / `test-full` / `coverage` (run gate rule).

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** `Repo::drop_actions(source, locations)` and `Repo::change_actions(change)` are two read-only queries; neither writes an operation of its own. Each row is answered by the verb's own plan fn, on a transaction that is then dropped:
- Status is Available, NoOp or Refused. A Refused row carries the verb's own `MutateError`.
- Squash rows carry `combined_description_needed`. The bookmark row carries `allow_backwards_needed`.
- Both queries are surfaced end to end: FFI `zanshin_drop_actions` / `zanshin_change_actions`, the FlatBuffers request and payloads, and Dart `RepoHandle.dropActions` / `changeActions`.

Code commit: `708deda60e17ed67d1a68e48ef00e572f2fbf301`.

**Deferred-work items:**
- **I1 — fixed** (`708deda60e17ed67d1a68e48ef00e572f2fbf301`). Every row calls the verb's own plan fn; none duplicates a rule.
  - Extracted from the shipped verbs, which now call them: `plan_edit`, `plan_describe`, `plan_abandon`.
  - Reused: `plan_new` (9.48), `plan_squash` and `prepare_split` (9.15).
  - Created for the verbs still to come: `rebase::plan_rebase_*` and `rebase_is_no_op` (9.16), `duplicate::plan_duplicate` (9.9), `bookmark_ops::plan_bookmark_move` (9.19). Calling them from those verbs is those stories' work, recorded in their sprint-status notes.
- **I2 — fixed** (`708deda60e17ed67d1a68e48ef00e572f2fbf301`). Settled here, as the story text allows ("lives here or in its own story"). `change_actions` answers 10.15's seven card-menu rows.
- **I3 — fixed** (`708deda60e17ed67d1a68e48ef00e572f2fbf301`). Every squash row carries `combined_description_needed`: the selection source, the change source, and `change_actions`' `squash_into_parent`. The flag comes from one rule, `squash_split::single_description`, shared with `squashed_description`.
- **I4 — fixed** (`708deda60e17ed67d1a68e48ef00e572f2fbf301`). `change_actions`' `new_insert_after` / `new_insert_before` rows call 9.48's `plan_new` with `-A X` / `-B X`, the same fn `new_change` runs. The drop menu has no `new` row at `-A`/`-B`; the card's "+" chip lives in the card menu.

**Files changed:**
- `crates/zanshin-jj/src/`:
  - `drop_actions.rs` (new): the query types and the two queries.
  - `rebase.rs` (new): rebase plan fns and the dry-run no-op check (signing dropped).
  - `duplicate.rs` (new): `plan_duplicate`.
  - `bookmark_ops.rs`: `plan_bookmark_move` and `is_fast_forward`.
  - `mutate.rs`: the extracted plan fns, and the Git root-merge refusal in `plan_new` for positional and `-A`/`-B` parents.
  - `squash_split.rs`: the shared description rule and the flag.
  - `op_support.rs`: `LocationArgs`, `resolve_commit_location` and the shared texts.
  - `repo.rs` and `lib.rs`: the public methods and re-exports.
- `crates/zanshin-jj/tests/it/`:
  - `drop_actions.rs` (new): the matrix, the agreement tests, the warnings and the immutable card.
  - `new_insert.rs`: the root-merge tests.
  - `api_stability.rs`: the new surface.
- `schemas/envelope.fbs` and the committed codegen (Rust, C header, Dart flatbuffers, ffigen bindings).
- `crates/zanshin-ffi/src/drop_actions.rs` (new): the two externs.
- `crates/zanshin-ffi/src/envelope.rs`: the encoders.
- `crates/zanshin-ffi/tests/it/drop_actions_ffi.rs` (new): the FFI tests.
- `packages/zanshin_core`:
  - `lib/src/ffi/drop_actions.dart` (new).
  - The worker commands, isolate dispatch, handle methods and exports.
  - `test/ffi/drop_actions_test.dart` and `test/worker/drop_actions_test.dart`.
- `crates/zanshin-parity/tests/oracle/`: the `new_merge_with_root` scenario.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`.
- `_bmad-output/implementation-artifacts/deferred-work.md`: I1–I4 notes and the "Surfaced in Story 9.31" section. `sprint-status.yaml`: 9-31 is done, and the 9-9 / 9-16 / 9-19 notes are updated.

**Review:** 34 findings: high 3, medium 7, low 17, false 7.
- **Patched:** every high entry (the dry run signing commits) and every medium entry:
  - a root merge in the rebase dry run failed the whole query;
  - the root merge was not refused for the computed `-A`/`-B` and duplicate parents;
  - nothing tested that the rows' warnings are discarded.
- Also patched, low: the Selection docs, the sprint-status and I1 wording, the `duplicate` template note, the oracle scenario, and the immutable-card test.
- **Deferred (6, all low, mirrored in deferred-work.md):**
  - the cost of the rebase dry run;
  - template faults after the plan phase;
  - `edit @` (Story 9.38);
  - the store writes the dry run leaves behind;
  - no test for a conflicted bookmark;
  - the matrix-row shrink, which is Ralph's decision.
- **Rejected:** each with its reason in the Review Triage Log:
  - the Dart decoder guards;
  - the missing `Unspecified` enum member;
  - the deny-list (false);
  - the sampled cross-matrix;
  - the NewMerge T == S hint;
  - the immutable-set caching;
  - the FFI argument order (false);
  - five intent-alignment readings (false).

**Follow-up review recommended: true.** One patched entry was high: the signing in the dry run. Its fix loads the head again through `RepoLoader::new`, with settings where `signing.behavior` is `drop`.
- What is verified: a unit test on the settings object.
- What is not verified: no test runs the dry run with a real signing backend configured. So it is unverified that the signer is never invoked, or that the extra load stays cheap per hover.
- Patched counts by verdict: high 1, medium 3, low 6.

**Residual risks:**
- Coverage was not measured (run rule). New files must reach 80% at the loop's final gate.
- The rebase dry run re-loads the head for every rebase row.
- The rebase, duplicate and bookmark-move rows have no executing verb to agree with until 9.16 / 9.9 / 9.19.

### Follow-up review pass (2026-10-21)

Status: done. Blocking condition: none.

**Summary.** A fresh review of the whole story (four layers) found 33 findings: medium 1, low 28, false 4, no high. Patched:
- The rebase dry run no longer re-loads the head per row: `rebase::load_dry_run_head` loads it ONCE per call with `signing.behavior = "drop"` (in `with_rows`), and `rebase_is_no_op` applies on the row's own transaction — the spec's "ONE `load_at_head`".
- The signing fix is now proven: an integration test with a signer that always fails (`signing.behavior = "force"`).
- New tests: the precondition's warnings survive both queries; `rebase -r` NoOp (a leaf onto its parent); the empty-paths Selection squash row; the FFI `-A`/`-B` lists cannot be swapped.
- Docs: `zanshin_new_change` / `RepoHandle.newChange` name the root-merge `jj.invalid_input`; two rustdocs reflowed.
- Ledger: the 9-18 sprint-status NOTE (no revert row) and the deferred-work `rebase -s/-b` with `-A`/`-B` entry (sidestepped, 9.16 still owes its test).

**Files changed:**
- `crates/zanshin-jj/src/rebase.rs` — `load_dry_run_head`; `rebase_is_no_op(tx, loc)`.
- `crates/zanshin-jj/src/drop_actions.rs` — `with_rows` loads the dry-run head once.
- `crates/zanshin-jj/src/repo.rs`, `mutate.rs` — rustdoc reflow.
- `crates/zanshin-jj/tests/it/drop_actions.rs` — four new witnesses (three tests plus a row).
- `crates/zanshin-ffi/src/repo.rs` — `zanshin_new_change` errors doc.
- `crates/zanshin-ffi/tests/it/drop_actions_ffi.rs` — the `-A`/`-B` wire test.
- `packages/zanshin_core/lib/src/worker/handle.dart` — `newChange` errors doc.
- `_bmad-output/implementation-artifacts/sprint-status.yaml`, `deferred-work.md` — the two dated notes.

**Review:** patched 1 medium + 7 low entries; deferred nothing new (four carried deferrals unchanged); rejected, each with its reason in the Review Triage Log: the advance-branches parse after `plan_new`, the oracle for hand-ported texts, foreign request fields, the bookmark NoOp's two meanings (intent-mandated), the positional `ChangeActionsObj` (false), `#[expect]`, the split root merge at two `-A`/`-B` targets, the location check's timing, and the carried enum/decoder rejects.

**Follow-up review recommended: false.** This follow-up pass patched no high entry. Patched counts by verdict: medium 1, low 7.

**Residual risks:** coverage not measured (run rule); the dry run's store writes and per-hover cost stay deferred; the split row at two `-A`/`-B` targets including the root reads Available while the split verb fails at its write (rejected as unreachable from one drop gap).

---
title: 'Story 9.1: Operation-support layer (zanshin-jj/src/op_support.rs)'
type: 'feature'
created: '2026-09-02'
status: 'in-progress'
baseline_revision: 'a35f15846761e4ca430876102ee5671dba79f5a8'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Every thick jj verb (Tier C: squash/split/rebase/duplicate/revert/…) needs four pieces of orchestration that live in jj-cli's `cli_util` and are absent from jj-lib: the immutable-heads rewritability guard, insert-location resolution for `-A`/`-B`/`--onto`, description combination with trailers, and the selected-tree plumbing that the CLI drives from an interactive hunk selector. Without a shared layer each verb would re-port them, and today the shipped mutations (`describe`/`edit`/`abandon`) rewrite immutable commits where jj refuses — the parity gap Story 9.0a deferred here.

**Approach:** Add `crates/zanshin-jj/src/op_support.rs`, an entirely `pub(crate)` layer re-porting those four pieces at v0.44.0 CLI parity, reusing jj-lib wherever it already exposes the primitive (`restore_tree`, `CommitWithSelection`, `trailer::*`, `rebase_descendants_with_options`). Wire only the guard into the three existing rewriting verbs, which closes the 9.0a gap and gives the layer a real consumer; the other three helpers ship tested-but-unwired because their consumers are Tier C by design.

## Boundaries & Constraints

**Always:**
- CLI **observable behavior** at tag `v0.44.0` is the oracle (NFR-R-2): same preconditions, same refusals, same op-log effect. Read prior art with `git -C ../jj show v0.44.0:<path>`.
- `op_support` is `pub(crate)`. No `jj_lib` type may appear in a public position (`lib.rs:17-28`, enforced by `tests/api_stability.rs` + the `test-jj-adapter-hygiene` gate). Nothing new is re-exported from `lib.rs`.
- Every `pub`/`pub(crate)` item needs a doc comment — `#![deny(missing_docs)]` at `lib.rs:3`.
- No `panic!` on a caller-reachable path: the CLI's two `panic!`s in `compute_commit_location` become `Result` errors.
- The full gate is the definition of done: `cargo make test` green (clippy pedantic `-D warnings`, rustfmt, `cargo deny`, coverage ratchet). `op_support.rs` is a NEW file → must clear the 80.00 % `new_file_floor_pct`.
- Commit on `main` with `--no-gpg-sign`; never edit git config.

**Block If:**
- A new `extern "C"` signature turns out to be required (it should not be — a new error *code* is a string, not a signature change). That would pull `cargo make codegen` + `bindings.dart` into scope.
- The coverage ratchet regresses on a file this story did not touch and the drop is not recoverable by testing code this story added.

**Never:**
- Do not port the CLI's terminal UX: no `$EDITOR` buffer (`combine_messages_for_editing`'s `JJ: `-comment scratch text), no `DiffEditor`/`MergeEditor` subprocess spawning, no `Ui` warnings/prompts. Interactive verbs take a GUI-supplied tree id (ADR-0003).
- Do not port jj's **template engine**. `templates.commit_trailers` rendering is out of scope; the trailer helper takes already-materialized `Trailer` values. Do not add `templates.commit_trailers` to `BUILTIN_CONFIG_TOML` — `config.rs:71-73` forbids advertising a default we do not honour.
- Do not implement any Tier C verb, and do not add an `--ignore-immutable` parameter to any verb's public signature.
- Do not lower `coverage-baseline.txt` or add an `exclude_prefix`.
- Do not reorder the existing root-commit guards in `mutate.rs` (see Design Notes).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Guard passes | `check_rewritable` over commits disjoint from `::(immutable_heads() \| root())` | `Ok(())` | No error expected |
| Guard refuses | a target inside the immutable set | Refusal naming the **first** offender only (CLI takes `try_next`, never a list) | `MutateError::Immutable { commit_id }` → `jj.immutable` |
| Verb refuses | `Repo::describe`/`edit`/`abandon` on a tagged (∴ immutable) commit | No mutation, **no op-log entry** | `MutateError::Immutable` |
| Root commit | `describe`/`abandon` on root | Refused as today — `InvalidInput`, message unchanged | `jj.invalid_input` (pre-existing) |
| Location `-A` only | `insert_after = [a]` | parents `[a]`, children = all direct children of `a` | — |
| Location `-B` only | `insert_before = [b]` | parents = `b`'s parents, order-preserving + deduped; children `[b]` | — |
| Location `-A` + `-B` | both given | parents `a`, children `b` — taken verbatim, no revset evaluation | — |
| Location `--onto` | `destination = [d]` | parents `[d]`, children `[]` | — |
| Location conflict | `destination` together with `-A`/`-B` | Refusal (CLI `panic!`s; a library must not) | `MutateError::InvalidInput` |
| Location empty | none of the three given | Refusal | `MutateError::InvalidInput` |
| Location loop | children would be ancestors of parents | `Refusing to create a loop: commit <hash> would be both an ancestor and a descendant of the <commit_type>` | `MutateError::InvalidInput` |
| No parents | resolved parent set is empty | `No revisions found to use as parent` | `MutateError::InvalidInput` |
| Combine, one non-empty | sources `["", "x"]`, dest `""` | `Some("x")` | No error expected |
| Combine, none non-empty | all empty | `Some("")` | No error expected |
| Combine, ambiguous | ≥ 2 non-empty descriptions | `None` — caller/GUI must decide | No error expected |
| Trailers onto prose | description without a trailer block | one blank line opens a new paragraph, then `key: value` lines | — |
| Trailers onto trailers | description already ending in a trailer block | appended directly, **no** blank line inserted | — |
| Trailer dedup | new trailer equal (key **and** value) to an existing one | skipped | — |
| Selected tree, paths | `before`/`after` trees + a matcher | jj-lib `restore_tree` result — the CLI's `DiffSelector::NonInteractive` behavior exactly | Backend error → `MutateError::Backend` |
| Selected tree, GUI id | a hex tree id supplied by the caller | re-hydrated `MergedTree` via `MergedTree::new(store, Merge::resolved(id), ConflictLabels::unlabeled())` | malformed/unknown id → `MutateError::InvalidInput` / `Backend` |

</intent-contract>

## Code Map

Everything below was verified against jj-cli at `v0.44.0` and the vendored `jj-lib-0.44.0`.

**New file**
- `crates/zanshin-jj/src/op_support.rs` -- the whole layer, `pub(crate)`. Four sections; inline `#[cfg(test)] mod tests` is **mandatory** for the three unwired helpers, because `pub(crate)` items are invisible to `tests/` (integration tests link the crate as an external lib). `test-helpers` is a dev-dependency (`Cargo.toml:23`), so inline tests may extract fixtures.

**Prior art (read-only, at the tag)**
- `cli/src/cli_util.rs:2002` `check_rewritable` → `:2011` `check_rewritable_expr` (the ~35-line body is the thing to port); `:1118` `resolve_immutable_expression`; `:2927` `rebase_mutable_descendants`; `:3551` `compute_commit_location`; `:3641` `ensure_no_commit_loop`; `:3494`/`:3508` `DiffSelector` + `select`.
- `cli/src/description_util.rs:299` `try_combine_messages`; `:392` `add_trailers_with_template` (the append/dedup rule at `:396-416`).
- `cli/src/revset_util.rs:194` `parse_immutable_heads_expression` — already mirrored by us.

**Already present — reuse, do not rebuild**
- `crates/zanshin-jj/src/revset.rs:288-294` `immutable_expression(repo, aliases_map)` → `::(immutable_heads() | root())`. **Half the guard already exists**; it is currently used only by `graph.rs`.
- `crates/zanshin-jj/src/revset.rs:195-207` `evaluate_revset(&dyn Repo, expr)`. `MutableRepo` implements `jj_lib::repo::Repo` (`jj-lib-0.44.0/src/repo.rs:2108`), so it already works mid-transaction. It *discards* the resolved expression — extract a `resolve_expression` helper here (see Execution) rather than duplicating three lines in `op_support`.
- `crates/zanshin-jj/src/config.rs:99` — `immutable_heads()`, `builtin_immutable_heads()`, `immutable()`, `mutable()` are all in `BUILTIN_CONFIG_TOML`, layered so user/repo/workspace config overrides by (name, arity). **No new config plumbing.**
- `crates/zanshin-jj/src/graph.rs:169-176` — the canonical per-operation idiom: `config::load(repo)` → `build_aliases_map` → `immutable_expression`. Copy it.
- jj-lib: `rewrite::restore_tree` (`rewrite.rs:133`), `rewrite::CommitWithSelection` (`:1259`), `merge::Diff::new`, `merged_tree::MergedTree::new` (`merged_tree.rs:90`), `conflict_labels::ConflictLabels::unlabeled` (`conflict_labels.rs:31`), `trailer::{Trailer, parse_description_trailers, parse_trailers}`.

**Wiring targets**
- `crates/zanshin-jj/src/mutate.rs:184` `describe`, `:298` `edit`, `:337` `abandon` -- take the immutable expression as a new parameter and run the guard. `:379-385` is the `RevsetExpression::none()` placeholder its own `// WHY:` names as the pre-0.44-preserving stand-in — replace it with the resolved set (CLI `rebase_mutable_descendants`).
- `crates/zanshin-jj/src/mutate.rs:53-100` `MutateError` -- new `Immutable { commit_id: String }` variant.
- `crates/zanshin-jj/src/repo.rs:282/316/334` `Repo::describe`/`edit`/`abandon` -- build the expression from `&self` **before** `self.workspace_mut()`; `immutable_expression` returns an owned `Arc`, so the `&self` borrow ends cleanly. `Repo::new_change` (`:300`) is deliberately **not** wired.
- `crates/zanshin-ffi/src/envelope.rs` + `crates/zanshin-ffi/src/repo.rs:77-100` `map_mutate_err` -- new arm; `:922-963` shows the per-variant inline mapper test to match.
- `docs/rust-error-codes.md:58` region -- add the `jj.immutable` row in the established 4-column format.
- `coverage-baseline.txt` -- commit the auto-raise if it rises.

**Tests**
- `crates/zanshin-jj/tests/op_support.rs` (new) -- guard behavior **through the public verbs**. `crates/zanshin-jj/tests/mutate.rs:17-24` is the model for `pin_env()` and `:50-100` for the `oracle_layout()` by-description commit discovery.
- **Fixture caveat:** `tiny-3-commits` has no remote bookmarks and no tags, so `trunk()` degenerates to `root()` and the immutable set is exactly `::root()`. A non-root immutable commit must be constructed in-test — `test_helpers::set_tag` is the lever (`tags()` is a term of `builtin_immutable_heads()`). Never regenerate fixtures. Do **not** repoint `JJ_CONFIG`; `tests/config_user_layer.rs` is the only file allowed to.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` -- extract `pub(crate) fn resolve_expression(&dyn Repo, &Arc<UserRevsetExpression>) -> Result<Arc<ResolvedRevsetExpression>, RevsetError>` from `evaluate_revset`'s body and have `evaluate_revset` call it -- the guard needs the *resolved* expression (that is what `rebase_descendants_with_options` takes); extracting keeps the file DRY and every line stays exercised, so its 100.00 % baseline holds.
- `crates/zanshin-jj/src/op_support.rs` -- **§1 guard:** `resolve_immutable(repo_dyn, aliases-derived expr)` mirroring `cli_util.rs:1118`, plus `check_rewritable(repo_dyn, &immutable, &[CommitId])` mirroring `:2011` — intersect, evaluate, take the first offender, refuse -- this is the piece 9.0a deferred to this story.
- `crates/zanshin-jj/src/op_support.rs` -- **§2 location:** `compute_commit_location(repo_dyn, destination, insert_after, insert_before, commit_type)` over already-resolved `CommitId` slices, returning `(parents, children)`, with the CLI's post-checks (`check_rewritable` on children, loop check, empty-parents refusal) -- callers resolve their own revsets, keeping this layer free of parse concerns and unit-testable.
- `crates/zanshin-jj/src/op_support.rs` -- **§3 descriptions:** `try_combine_messages(sources: &[&str], destination: &str) -> Option<String>` and `apply_trailers(description, &[Trailer]) -> String` -- pure string functions, so they carry the file's coverage cheaply and need no repo.
- `crates/zanshin-jj/src/op_support.rs` -- **§4 selection:** a `SelectedTree` wrapper with a path/matcher constructor (over jj-lib `restore_tree`) and a GUI-tree-id constructor, plus assembly into jj-lib's `CommitWithSelection` -- the seam that replaces `DiffSelector`, whose downstream consumers (`squash_commits`) already exist in jj-lib.
- `crates/zanshin-jj/src/mutate.rs` -- add the `Immutable` variant; thread the immutable expression into `describe`/`edit`/`abandon`; run the guard after the existing root check; replace the `none()` placeholder at `:384` -- closes the CLI-parity gap on the shipped verbs.
- `crates/zanshin-jj/src/repo.rs` -- build the expression before `workspace_mut()` in the three facades -- the borrow split is the one real design constraint here.
- `crates/zanshin-ffi/src/{envelope.rs,repo.rs}` -- register `jj.immutable` and map the new variant, with the matching inline mapper unit test -- an unmapped variant would not compile, and an untested arm would drop `repo.rs` coverage.
- `docs/rust-error-codes.md` -- add the `jj.immutable` row -- mandatory for any new code.
- `crates/zanshin-jj/src/op_support.rs` (inline `#[cfg(test)]`) and `crates/zanshin-jj/tests/op_support.rs` -- cover the I/O matrix; inline for the three `pub(crate)`-only helpers, integration for the guard via the public verbs.

**Acceptance Criteria:**
- Given the workspace after this change, when `cargo make test` runs, then it passes end to end with no baseline lowered and no `exclude_prefix` added, and `crates/zanshin-jj/src/op_support.rs` reports ≥ 80.00 % line coverage.
- Given a fixture repo with a tag placed on a non-root commit, when `Repo::describe`, `Repo::edit`, or `Repo::abandon` targets that commit, then the call returns `MutateError::Immutable` naming it, and `jj op log` shows no new operation.
- Given the same repo, when those verbs target a commit outside the immutable set, then they succeed exactly as before this story.
- Given a repo whose config overrides `revset-aliases."immutable_heads()"`, when the guard runs, then the override decides the immutable set (the builtin is replaced, not merged) — proving the guard reads the effective config rather than a Rust constant.
- Given `zanshin-jj`'s public API, when compared against the pre-change surface, then only `MutateError` gained a variant: `tests/api_stability.rs` compiles untouched and no `jj_lib` type appears in any public position.
- Given no `extern "C"` signature changed, when the FFI surface is checked, then `zanshin_ffi.h` and `bindings.dart` need no regeneration.
- Given `docs/rust-error-codes.md`, when it is read, then `jj.immutable` is registered with its emission site, and the entry for `jj.invalid_input` still describes the root-commit refusal it continues to serve.

## Spec Change Log

## Review Triage Log

## Design Notes

**Immutability is ancestor-closed, and that changes what the wiring is for.** The set is `::(immutable_heads() | root())` — closed under ancestors by construction. So if a target is *mutable*, none of its descendants can be immutable (an immutable descendant would drag the target into the set). Consequence: once `check_rewritable` passes on the targets, swapping `RevsetExpression::none()` for the real set at `mutate.rs:384` cannot change the outcome of that rebase. The substantive fix for the 9.0a gap is therefore the **target guard**, not the rebase argument; the rebase argument is still changed for CLI parity and because the CLI's own comment names a case the algebra does not cover (`jj git fetch` updating immutable commits between base and tip — which is why `rebase_mutable_descendants` resolves against `tx.base_repo()`, not `tx.repo()`; mirror that).

**Guard placement: after the root check, not before.** The CLI checks rewritability before `start_transaction()` and reports root as *immutable*. We keep our existing explicit root guards first. Two reasons: they exist to pre-empt jj-lib's internal `assert!` (a process crash, not an error), and moving the guard ahead of them would make those lines unreachable — dropping `mutate.rs` below its 96.04 % baseline while also changing a shipped error code. Net effect: root still refuses via `jj.invalid_input`, non-root immutable commits refuse via `jj.immutable`. Both refuse, neither writes an op-log entry, so observable behavior matches the CLI; only the code differs for root. Record that as a deferred nit rather than "fixing" it here.

**Running the guard inside the transaction is equivalent.** The CLI runs it against the read-only repo before opening a transaction; our mutations already hold a transaction when they resolve targets. Evaluating against `tx.repo()` *before any mutation* sees identical content, and dropping the transaction on refusal writes nothing. This keeps the change surgical instead of restructuring `resolve_commit`.

**`try_combine_messages` returning `None` is a feature, not a gap.** The CLI's fallback for the ambiguous case is `combine_messages_for_editing` — a `JJ: `-commented `$EDITOR` buffer. That is exactly the terminal UX ADR-0003 replaces. Return `None` and let the caller (ultimately the GUI) decide; "the backend classifies and offers, the UI decides."

**Trailer blank-line rule (port verbatim, `description_util.rs:396-416`):** insert the paragraph break *only* when the existing description has no trailer block and the new trailer list is non-empty; dedup by full `Trailer` equality against `parse_description_trailers` of the existing description. Note the two jj-lib parsers differ on purpose — `parse_description_trailers` is lenient over a whole message, `parse_trailers` is strict over a trailer-only paragraph.

**`compute_commit_location`'s `-B` parent computation must preserve order.** The CLI deliberately avoids `RevsetExpression::parents` and instead unions `parent_ids()` with a dedup, "to persist the order of parents specified in `before_commits`". Reproduce that; do not substitute the revset form.

## Verification

**Commands:**
- `cargo make test` -- expected: green end to end (tests + clippy `-D warnings` + rustfmt + `cargo deny` + coverage ratchet). This is the single gate; run it unpiped and capture the exit code.
- `git -C ../jj show v0.44.0:cli/src/cli_util.rs` -- expected: the prior art the port is checked against; confirm line anchors before trusting them.
- `git status --porcelain` -- expected: after the run, only intended files; `coverage-baseline.txt` appears only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: confirm `MutateError` is the only public item that changed and that no `jj_lib` type leaked into a public signature.

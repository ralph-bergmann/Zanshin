---
title: 'Epic 9 follow-up E: three shipped-payload widenings — Remote.push_url, FileSearch.skipped, git_fetch import stats'
type: 'feature'
created: '2026-09-05'
status: 'done'
baseline_revision: 'a829d8068dccd0234e73d1473902494e06e118b7'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      A git remote configured with only a `pushurl` and no `url` is dropped from `list_remotes`
      entirely, where `jj git remote list` prints it with a `"<no URL>"` sentinel.
    evidence: |-
      `remote_urls` ends its fetch read with `let fetch = render(Direction::Fetch)?;`, so a
      remote whose `[remote "x"]` section carries a `pushurl` but no `url` yields `None` and is
      skipped by the build loop — its push URL is never reported even though gix resolves
      `url(Direction::Push)` for it fine. The CLI does the opposite: `get_url` returns an
      `Option` and the row is still printed, with `"<no URL>"` standing in for the missing
      direction (`cli/src/commands/git/remote/list.rs:60-65` @ v0.44.0) — a citation this
      spec's own Code Map carries as read evidence. Pre-existing since Story 2.9 (the helper's
      doc calls it "the same skip condition the fetch-only predecessor had"), and NOT worsened
      by this change: such a remote was invisible before too. Deferred rather than fixed
      because closing it is a product decision, not a mechanical edit — `Remote.url` is a
      non-optional `String` at both the Rust and the wire layer, so reporting the row needs
      either a sentinel value (matching the CLI's rendered text but inventing data) or a fourth
      payload widening to `Option<String>`, and that choice belongs with the UI that would
      render it.
    location: >-
      crates/zanshin-jj/src/remotes.rs (remote_urls / list_remotes)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Three shipped read/remote payloads under-report facts the caller already paid for.
(1) A push URL can be SET through `Repo::git_remote_add` / `git_remote_set_url` (Story 9.5) but never
READ back — `zanshin_jj::Remote` is `{ name, url }` (Story 2.9) and so is `schemas/envelope.fbs::Remote`,
so the 9.5 tests fell back to a raw `git config --get remote.<n>.pushurl` oracle and `list_remotes`
diverges from `jj git remote list`, which prints `(push: <url>)`. (2) `file_search` silently drops
`MaterializedTreeValue::AccessDenied` where the CLI warns, and `FileSearch` has no `skipped` channel,
so a GUI cannot tell "no match" from "blob unreadable" — `FileContents` has had exactly that vector
since 9.4. (3) `remotes.rs::git_fetch` hardcodes `new_change_ids`/`abandoned_change_ids` as
`Vec::new()`, so the abandoning that `git.abandon-unreachable-commits` now controls (follow-up C) is
invisible in the returned `MutationResult`; the follow-up-C pruning tests had to observe it through
`resolve_revset(&repo, "all()")`.

**Approach:** Widen all three payloads in place — `.fbs` edited in place per WIP rules, ONE
`cargo make codegen`, generated outputs committed — and pin each new fact with a witness at the layer
that owns it, then retire the raw `git config … pushurl` oracle at both layers that used it. This is a
CLOSING run for the three named ledger entries; nothing else is in scope.

## Boundaries & Constraints

**Always:**
- **`Remote.push_url` is the CLI's own difference test, not gix's raw field.** gix
  `Remote::url(Direction::Push)` FALLS BACK to the fetch URL (`gix-0.85.0/src/remote/access.rs:38-47`),
  so it can never distinguish "no pushurl configured" from "pushurl equals url", and gix exposes no
  public raw `push_url()` accessor. `cli/src/commands/git/remote/list.rs:49-55` @ v0.44.0 reads both
  directions through one `get_url` and prints the `(push: …)` suffix ONLY when the two differ.
  Zanshin therefore emits `push_url = Some(p)` iff `p != fetch`, and `None` otherwise — absent means
  "pushes to its fetch URL". Null-for-absence: never `Some("")`, never a coalesce to `''` on the Dart
  side (unlike the sibling `name`/`url`, which keep their `?? ''`).
- Both URLs are read `to_bstring()`, never `Display`/`to_string()` — `gix_url`'s `Display` REDACTS the
  password. Same rule the existing `fetch_url` helper (`crates/zanshin-jj/src/remotes.rs:60-66`)
  already carries, and the same the CLI's `get_url` uses.
- **`FileSearch.skipped` carries ONLY `AccessDenied`.** `jj file search` warns on AccessDenied alone
  (`cli/src/commands/file/search.rs:109-115`); Symlink, GitSubmodule and OtherConflict are skipped
  SILENTLY there (`:134`, `:159-160`) — the exact opposite of `jj file show`, which warns on
  Symlink/GitSubmodule. The remaining five variants keep their silent catch-all arm.
- **The reason string is `file search`'s own sentence**, not `file show`'s:
  `Skipping '<path>' due to permission error: {e}`. `SkippedPath.reason` is documented as "the CLI's /
  jj-lib's own message, forwarded unchanged" and `file.rs:336-337` commits to CLI-verbatim wording;
  reusing `render_entry`'s `Path '…' exists but access is denied: …` would ship the wrong verb's text.
- **`git_fetch`'s projection is `git_import`'s, factored into one helper.** `GitImportStats` has no
  minted-change concept, so `new_change_ids` stays `Vec::new()` for fetch exactly as it is for import;
  only `abandoned_commits` → `abandoned_change_ids` moves. Both call sites must go through the same
  `pub(crate)` helper so they cannot drift.
- **Every doc that claims those vectors are always empty for `git_fetch` is now wrong and must be
  corrected** at every layer (Rust field docs, the `Repo`/`extern "C"` facade docs, the Dart field
  docs). Grep for `git_fetch`/`gitFetch` near "empty" and fix each hit.
- One `cargo make codegen` run; commit `envelope_generated.rs` + `envelope_zanshin.ffi_generated.dart`.
  No `extern "C"` SIGNATURE changes, so `zanshin_ffi.h` / `bindings.dart` must stay byte-identical.
- `#![deny(missing_docs)]` stays satisfied; no `jj_lib`/`gix` type appears in any public signature.
- The coverage ratchet must not drop. Today: `crates/zanshin-jj/src/remotes.rs = 100.00`,
  `crates/zanshin-ffi/src/remotes.rs = 100.00`, `crates/zanshin-jj/src/file.rs = 98.15`,
  `crates/zanshin-ffi/src/file.rs = 100.00`, `crates/zanshin-jj/src/git.rs = 99.55`,
  `crates/zanshin-ffi/src/git.rs = 100.00`, with `epsilon_pct = 0.10`. Both new `push_url` arms
  (present and absent) and the new `AccessDenied` arm need a test that EXECUTES them.
- Every touched `extern "C"` fn keeps its `packages/zanshin_core` cdylib test (none is added or
  removed here; `zanshin_remotes`, `zanshin_file_search` and `zanshin_git_fetch` already have one).

**Block If:**
- The `SecretBackend` route to a real `MaterializedTreeValue::AccessDenied` does not work (the
  `testing` feature cannot be enabled dev-only, the backend factory cannot be registered, or the
  refusal does not surface as `AccessDenied`), AND no other construction is found, so the new arm ships
  uncovered and the ratchet drops: HALT `blocked`, blocking condition
  `no witness for the file_search access-denied arm`.
- The ratchet can only be made green by lowering a baseline entry or adding an `exclude_prefix`: HALT
  `blocked`, blocking condition `coverage ratchet regression`.

**Never:**
- No `_v2` tables, no in-wire `schema_version`, no second payload alongside the widened one.
- No production change to make the secret backend loadable — `Repo::open` keeps
  `default_backend_factories()`. The witness reaches `file_search` directly, inline, because
  `file_search` is `pub(crate)`.
- No fixture regeneration (`tiny-3-commits` is built on in-test, never rebuilt).
- No new `error.code`, no `docs/rust-error-codes.md` row: an unreadable blob is still not an error, a
  missing push URL is still not an error, and fetch's error surface is untouched.
- Do not touch `file show`'s skip set, its wording, or `render_entry`.
- Do not touch `git_try` at `crates/zanshin-jj/tests/git_remotes.rs:50-59` itself — its fourth call
  site (`:595`, `remote.origin.url`) is in a test that deliberately destroys `.jj/working_copy`, so no
  `Repo` handle loads and `list_remotes` is structurally unavailable there. Only the three `pushurl`
  call sites retire.
- No `remote_auto_track_bookmarks` work, no `.jj/repo/config.toml` writer, no MCP surface.
- No unrelated cleanup in the touched functions or files.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| remote with a distinct push URL | `git_remote_add("origin", url, Some(push))`, then `list_remotes()` | one row, `url == url`, `push_url == Some(push)` | No error expected |
| remote with no push URL | `git_remote_add("origin", url, None)`, then `list_remotes()` | `url == url`, `push_url == None` | No error expected |
| push URL added later | `git_remote_set_url("origin", None, Some(push))`, then `list_remotes()` | `push_url == Some(push)`, `url` unchanged | No error expected |
| push URL equal to fetch URL | a remote whose `pushurl` is byte-identical to `url` | `push_url == None` — CLI parity: the `(push: …)` suffix is printed only on a difference | No error expected |
| credentials in the push URL | push URL containing `user:s3cr3t@` | `push_url` carries them VERBATIM (`to_bstring`, not `Display`) | No error expected |
| native backend / no remotes | `Repo::init(tmp, None)`, `list_remotes()` | `Ok(vec![])`, unchanged | No error expected |
| search hits an unreadable blob | `file_search` over a tree whose blob the backend refuses to read | `matches` unchanged; `skipped` has one entry, `path` = the repo-relative internal path, `reason` = `Skipping '<path>' due to permission error: …` | No error — the call SUCCEEDS |
| search hits a symlink / submodule / non-file conflict | the existing `mixed_tree` fixture's `link` entry | `skipped` stays EMPTY — silent, CLI parity | No error expected |
| search with no match at all | pattern matching nothing | `matches` empty AND `skipped` empty — the two are now distinguishable | No error expected |
| pruning fetch, default config | the follow-up-C prune fixture, `git.abandon-unreachable-commits` at its jj-lib default | `MutationResult.abandoned_change_ids` contains the now-unreachable change; `new_change_ids` empty | No error expected |
| pruning fetch, `abandon-unreachable-commits = false` | same fixture, key set to `false` | `abandoned_change_ids` EMPTY — the projection reads jj-lib's stats, it is not hardcoded either way | No error expected |

</intent-contract>

## Code Map

Zanshin anchors read against the working tree at baseline `a829d80`; jj CLI anchors at tag `v0.44.0`
(`git -C ../jj show v0.44.0:<path>`); jj-lib and gix anchor in the vendored
`~/.cargo/registry/src/index.crates.io-*/{jj-lib-0.44.0,gix-0.85.0}`.

**Read-only evidence (do not edit)**
- `gix-0.85.0/src/remote/access.rs:38-47` — `url(Push)` = `push_url_alias.or(push_url).or_else(|| url(Fetch))`.
  The fallback is why `push_url` must be a DIFFERENCE, and why no raw-presence read exists (the two
  `push_url*` fields are private with no public accessor).
- `cli/src/commands/git/remote/list.rs:49-55, 60-65` @ v0.44.0 — one `get_url` per direction,
  `to_bstring()`, `(push: …)` only when `fetch_url != push_url`; `"<no URL>"` sentinel.
- `cli/src/commands/file/search.rs:107-115` (AccessDenied → `Skipping '{ui_path}' due to permission
  error: {error}`), `:134`, `:159-161` (Symlink / OtherConflict / GitSubmodule silent, Tree/Absent
  `panic!`). Compare `cli/src/commands/file/show.rs:164-170, 191-197` — DIFFERENT wording, different
  skip set.
- `jj-lib-0.44.0/src/conflicts.rs:207-219` — `materialize_tree_value` converts
  `BackendError::ReadAccessDenied` into `MaterializedTreeValue::AccessDenied`; `:229-241` shows the
  plain-file path calls `store.read_file`, which is where the refusal happens.
- `jj-lib-0.44.0/src/secret_backend.rs:53-85, 118-133` — `SecretBackend` (`pub`, gated
  `#[cfg(feature = "testing")]` at `lib.rs:95-96`) refuses `read_file` for any path containing
  `secret`; `adopt_git_repo(workspace_path)` flips `.jj/repo/store/type`. This is jj's own mechanism
  (`cli/tests/test_acls.rs:39`) and the ONLY way to construct `AccessDenied`.
- `jj-lib-0.44.0/src/repo.rs:401-402, 482-484` — `StoreFactories::add_backend(name, factory)`;
  `BackendFactory = Box<dyn Fn(&UserSettings, &Path) -> Result<Box<dyn Backend>, BackendLoadError>>`.
- `jj-lib-0.44.0/src/git.rs:3157` — `GitFetch::import_refs()` returns `GitImportStats`; today
  `remotes.rs:261` throws it away.
- `crates/zanshin-jj/src/repo.rs:702-708, 1383-1389` — `Workspace::load` with
  `default_backend_factories()`; that is why a secret-backend repo cannot be reached through `Repo`.

**Item 1 — `Remote.push_url`**
- `crates/zanshin-jj/src/remotes.rs:33-42` `Remote` struct; `:58-66` `fetch_url` helper (the
  `to_bstring` WHY block lives here); `:94-104` the `list_remotes` build loop; `:3-9` module doc says
  "and their fetch URLs".
- `schemas/envelope.fbs:387-393` `table Remote`; `:395-397` `Remotes`. Convention exemplars:
  `:130-145` `GitRemoteAddRequest.push_url` (already null-for-absence, same field name and meaning),
  `:470-475` `GraphCommitRef.remote`, `:600-609` `AbsorbResult.source_change_id`. **Counter-example not
  to copy:** `:370-379` `Bookmark.remote_name` uses empty-string-for-absence.
- `crates/zanshin-ffi/src/remotes.rs:31-59` `remotes_to_envelope` (`:34-45` is the per-`Remote` write;
  `:29-30`'s "a `Remote` is just two plain strings" goes stale); `:76-86` `zanshin_remotes`;
  `:97-145` the in-file unit tests, which build `Remote { name, url }` struct literals at `:100-109`.
  Mirror `crates/zanshin-ffi/src/graph.rs:76-82` for the one-line `Option` write.
- `packages/zanshin_core/lib/src/ffi/remotes.dart:24-36` model, `:66-69` `_mapRemote` (the `?? ''`
  coalesce), `:45-64` the decode seams. `worker/handle.dart:13, 168-177`; `worker/isolate.dart:593-606,
  1457-1466` (the isolate arm forwards raw bytes — no change).
- Generated: `crates/zanshin-ffi/src/envelope_generated.rs:5118-5215` (`Remote`/`RemoteArgs`/builder),
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart:3056-3136`.
- Tests: `crates/zanshin-jj/tests/remotes.rs:63-74` `add_remotes` helper (passes `None` for push),
  `:109-138` sorted-list row, `:142-167` credentials row, `:171-203` ssh row.
  `crates/zanshin-ffi/tests/remotes_ffi.rs:92-155` (all three rows assert an EMPTY list — a populated
  row is missing at this layer). `packages/zanshin_core/test/ffi/remotes_test.dart:75-107` (per-field
  equality against `fbs.RemoteObjectBuilder`). `crates/zanshin-jj/tests/api_stability.rs:57` pins the
  type name only — there is no `sample_remote()` yet, unlike every other payload struct.
- **Oracles to retire:** `crates/zanshin-jj/tests/git_remotes.rs:141` (in `:131-144`), `:413` (in
  `:393-415`, a NEGATIVE assertion), `:435` (in `:420-443`) — all three read
  `remote.origin.pushurl` through `git_try` (`:50-59`); each test's doc comment names
  "`list_remotes` only reports the FETCH url" as the reason and must be rewritten.
  `crates/zanshin-ffi/tests/git_ffi.rs:340-349` (in `:311-352`) and `:582-591` (in `:568-608`) are
  inline `Command::new("git")` copies; both tests ALREADY read the `Remotes` payload right beside the
  oracle (`:594-605`). `packages/zanshin_core/test/worker/git_test.dart:111-128` documents the gap in
  prose at `:111-114` and asserts only `.url` at `:125`.
  KEEP `git_try` and its fourth call site `git_remotes.rs:595` (`remote.origin.url`, WHY at `:592-594`).

**Item 2 — `FileSearch.skipped`**
- `crates/zanshin-jj/src/file.rs:580-645` `file_search` — `:604` returns `Vec<SearchMatch>`;
  `:634-641` the catch-all that swallows `AccessDenied` (its `:634-635` comment and the fn doc
  `:583-585` both admit the divergence and must be rewritten); `:614` already computes `display`.
- `crates/zanshin-jj/src/file.rs:102-114` `FileContents` — the struct to mirror; `:321-365`
  `render_entry` (show-only, `:338-341` skip factory, `:355-357` the AccessDenied arm with SHOW's
  wording); `:411-418` show's push site; `:647-...` the existing inline `#[cfg(test)] mod tests`
  (where the new witness belongs).
- `crates/zanshin-jj/src/mutate.rs:288-303` `SkippedPath` (re-exported at `lib.rs:61`) — reused, not
  duplicated; its doc lists the payloads that carry it and gains a third.
- `schemas/envelope.fbs:580-592` `SkippedPath` + doc, `:658-666` `FileContents`, `:703-706`
  `FileSearch`. Append `skipped` after `matches` (vtable slot 6, same as `FileContents`).
- `crates/zanshin-ffi/src/file.rs:209-231` the `FileContents` skipped loop to mirror; `:261-287`
  `file_search_to_envelope` (takes `&[SearchMatch]` — signature changes); `:450-...`
  `zanshin_file_search`; `:586-616` the in-file writer unit test for `FileContents.skipped` — the
  pattern for the new `FileSearch` writer test; `crates/zanshin-ffi/src/envelope.rs:349-384` is a
  second copy of the same `SkippedPath` loop (`AbsorbResult`).
- `packages/zanshin_core/lib/src/ffi/file.dart:10` (`SkippedPath` import), `:166-178` `FileContents`
  model, `:208-230` `SearchMatch`, `:275-289` FileContents decode (`:287` is the skipped mapper),
  `:326-350` the FileSearch decode seams returning a bare list.
  `worker/isolate.dart:918-935` `fileSearch`, `:1639-1660` the isolate arm (forwards bytes — no
  change), `worker/commands.dart:482-483`, `worker/handle.dart` (`fileSearch`, near `:404`).
- Tests: `crates/zanshin-jj/tests/file_reads.rs:122-147` `mixed_tree` (the symlink fixture),
  `:374-388` the `FileContents.skipped` symlink witness, `:607-794` the eight `file_search` rows
  (`:607-632` is the natural host for the "skipped stays empty" assertion; its `:628` message already
  claims symlink-silence). `crates/zanshin-ffi/tests/file_ffi.rs:339-368` (show skipped round-trip),
  `:614-780` the three search rows. `packages/zanshin_core/test/ffi/file_test.dart:108-146` (synthetic
  `SkippedPathObjectBuilder` buffer + the absent-vector row), `:203-255` the search decode group.
  `packages/zanshin_core/test/worker/file_test.dart:116-204`.
- `crates/zanshin-jj/tests/api_stability.rs:196-208` `sample_file_contents` (with the "`skipped`
  deliberately reuses `SkippedPath`" contract comment), `:222-229` `sample_search_match`, `:523-525`
  the call site list, `:84-93` the type-alias list.
- `crates/zanshin-jj/Cargo.toml:21-23` `[dev-dependencies]` — where `jj-lib = { workspace = true,
  features = ["testing"] }` goes. `crates/test-helpers/src/lib.rs:41` `extract_fixture`,
  `:114-129` the private `load` (the shape to mirror in the test), `:140-147` `Entry`, `:236`
  `add_commit_with_entries`.

**Item 3 — fetch import stats**
- `crates/zanshin-jj/src/remotes.rs:261` the discarded `import_refs()`; `:288-293` the
  `MutationResult` literal with the two `Vec::new()`; `:179-203` `git_fetch`'s doc block.
- `crates/zanshin-jj/src/git.rs:322-338` `git_import`'s result build — `:325-329` is the
  `abandoned_commits` → `ChangeId` mapping to extract; `:99-131` `GitImportResult` doc (`:103-106`
  describes IMPORT's own empty mutation vectors and contrasts them with its `abandoned_change_ids`).
- `crates/zanshin-jj/src/mutate.rs:50-58` and `:59-67` — the two `MutationResult` field docs that
  currently assert both vectors are always empty for `git_fetch`.
- `packages/zanshin_core/lib/src/ffi/mutate.dart:155-165` — the Dart field docs with the same claim
  ("for `undo` and `git_fetch`").
- Writers that already carry both vectors, so NO wire change is needed:
  `crates/zanshin-ffi/src/envelope.rs:306-317`, its unit test `:570-608`.
- Witnesses: `crates/zanshin-jj/tests/remotes_write.rs:464-483`
  `git_fetch_with_the_default_config_abandons_unreachable_commits` (result currently discarded at
  `:470-471`; `fx.b_change` is the oracle) and its sibling
  `git_fetch_honours_abandon_unreachable_commits_false` (the negative control).

**Gates / bookkeeping**
- `coverage-baseline.txt:8-11` knobs (`epsilon_pct = 0.10`, `new_file_floor_pct = 80.00`,
  `exclude_prefix = crates/xtask/`, `exclude_prefix = crates/test-helpers/`); entries at `:22, :23,
  :30, :47, :48, :53`.
- `Makefile.toml:289-329` `codegen` → `codegen-flatc-rust` / `codegen-flatc-dart`;
  `:331-344` cbindgen/ffigen (must produce NO diff); `:348-441` `verify-codegen`.
- `_bmad-output/implementation-artifacts/deferred-work.md:204` (push_url), `:228` (FileSearch
  skipped), `:246` (fetch stats) — the three bullets to strike through.
- `spec-9-5-git-local-sync-remote-config.md`, `spec-9-4-file-reads-list-show-annotate-search.md`,
  `spec-epic-9-followup-c-git-sync-must-haves.md` — the matching `deferred:` items get a
  `resolved: >-` block scalar.

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- add `push_url: string;` to `table Remote` with a null-for-absence trailing
  comment and a doc sentence naming the CLI's difference rule; append `skipped: [SkippedPath];` to
  `table FileSearch` with a doc sentence naming AccessDenied-only; extend `SkippedPath`'s doc block to
  name the third carrier. -- One in-place edit of the wire contract, per WIP rules; both fields follow
  the `GitRemoteAddRequest.push_url` / `FileContents.skipped` precedents already in this file.
- run `cargo make codegen` ONCE and commit `crates/zanshin-ffi/src/envelope_generated.rs` +
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`. -- Generated code is
  committed and the build never regenerates; `zanshin_ffi.h` and `bindings.dart` must come out
  byte-identical because no `extern "C"` signature moves.
- `crates/zanshin-jj/src/remotes.rs` -- add `pub push_url: Option<String>` to `Remote` with a doc
  stating the difference rule and the verbatim/credential guarantee; generalise `fetch_url` into a
  helper that reads both directions once (keeping the `to_bstring` WHY) and returns the pair; build the
  `push_url` in `list_remotes` as `Some(push)` iff it differs from the fetch URL; refresh the module
  doc's "and their fetch URLs". -- gix's `url(Push)` falls back to fetch, so a difference test is the
  only faithful reading AND is exactly what `jj git remote list` does.
- `crates/zanshin-ffi/src/remotes.rs` -- write `push_url` as
  `r.push_url.as_deref().map(|s| b.create_string(s))` on ONE line into `RemoteArgs`, fix the
  "just two plain strings" comment, and extend the two in-file round-trip tests so one entry has a
  push URL and one does not. -- A one-line `Option` map keeps both arms on a covered line (the
  `graph.rs:76-82` precedent) and `crates/zanshin-ffi/src/remotes.rs` sits at 100.00.
- `packages/zanshin_core/lib/src/ffi/remotes.dart` -- add `final String? pushUrl;` to the `Remote`
  model with a doc naming null-for-absence, and map it as `pushUrl: r.pushUrl` with NO `?? ''`. --
  Coalescing would destroy the absent/present distinction the whole change exists to carry.
- `crates/zanshin-jj/tests/remotes.rs` -- seed push URLs through the SHIPPED verbs
  (`Repo::git_remote_add(name, url, Some(push))` and `Repo::git_remote_set_url(name, None, Some(push))`),
  and add rows for: a remote with a distinct push URL, a remote without one (`push_url.is_none()`), a
  push URL added later, a push URL equal to the fetch URL (`None`, CLI parity), and credentials
  surviving verbatim in a push URL. -- These are the first five I/O rows; using the real verbs instead
  of raw `git config` is the point of the change.
- `crates/zanshin-jj/tests/git_remotes.rs` -- replace the three `git_try(&["config", "--get",
  "remote.origin.pushurl"], …)` oracles at `:141`, `:413` and `:435` with assertions on
  `list_remotes()`' `push_url` (the third's negative assertion becomes `push_url.is_none()`), add a
  `remote_push_url(&repo, name)` helper beside the existing `remote_url`, and rewrite the three doc
  comments that justify the raw oracle with "`list_remotes` only reports the FETCH url". -- The oracle
  WAS the tell the ledger recorded; leaving the stale justifications would re-teach the wrong thing.
  `git_try` and its `remote.origin.url` call site at `:595` stay.
- `crates/zanshin-ffi/tests/git_ffi.rs` -- delete the two inline `git config --get …pushurl` blocks at
  `:340-349` and `:582-591` and assert `push_url()` on the `Remotes` payload both tests already decode.
  -- This turns the FFI layer's existing populated-remote reads into the push-URL witness, which
  `remotes_ffi.rs` (all-empty lists) cannot provide.
- `packages/zanshin_core/test/ffi/remotes_test.dart` + `test/worker/git_test.dart` -- extend the
  per-field decode test with a `pushUrl:`-carrying builder entry AND one without (expect `null`), and
  in the worker test assert `.pushUrl` beside `.url`, deleting the prose caveat at `:111-114`. -- The
  worker test is the end-to-end witness through the real cdylib.
- `crates/zanshin-jj/src/file.rs` -- introduce `pub struct FileSearch { matches: Vec<SearchMatch>,
  skipped: Vec<SkippedPath> }` mirroring `FileContents`, change `file_search` to return it, give
  `AccessDenied` its own match arm that pushes a `SkippedPath` with the CLI's SEARCH wording
  (`Skipping '<path>' due to permission error: {e}`), leave the other five variants silent, and
  rewrite the fn doc `:583-585` and the arm comment `:634-635`. -- Only AccessDenied warns in
  `jj file search`; the show verb's wording and skip set are a different contract.
- `crates/zanshin-jj/src/lib.rs` + `crates/zanshin-jj/src/repo.rs` -- re-export `FileSearch` and change
  the `Repo::file_search` facade's return type and doc. -- The facade is the rustdoc a consumer reads.
- `crates/zanshin-jj/Cargo.toml` -- add `jj-lib = { workspace = true, features = ["testing"] }` to
  `[dev-dependencies]` with a `# WHY:` comment naming `SecretBackend` as the only constructor of
  `MaterializedTreeValue::AccessDenied`. -- Dev-only, so `cargo build`/the shipped cdylib never enable
  it; putting it in `[dependencies]` (or in `test-helpers`, a workspace member) would enable it for
  `cargo build --workspace` too.
- `crates/zanshin-jj/src/file.rs` (inline `#[cfg(test)] mod tests`) -- add the access-denied witness:
  extract `tiny-3-commits`, `add_commit_with_entries` a tree holding a normal file and one whose path
  contains `secret`, `SecretBackend::adopt_git_repo`, load a `Workspace` with
  `default_backend_factories()` plus an `add_backend(SecretBackend::name(), …)` factory, call
  `file_search` on that commit and assert the normal file still matches while `skipped` holds exactly
  the secret path with the CLI's sentence. -- Must be INLINE: `file_search` is `pub(crate)` and
  `Repo::open` uses `default_backend_factories()`, so a secret-backend repo is unreachable through the
  public API. This is also what keeps the new arm covered and the ratchet green.
- `crates/zanshin-jj/tests/file_reads.rs` -- update the eight `file_search` rows for the new return
  type and assert `skipped.is_empty()` where the symlink/no-match rows run. -- The silent-skip parity
  claim at `:628` only becomes checkable once `skipped` exists.
- `crates/zanshin-ffi/src/file.rs` -- change `file_search_to_envelope` to take the `FileSearch` struct,
  mirror the `FileContents` skipped loop verbatim into it, update `zanshin_file_search` and its doc,
  and add an in-file writer round-trip test carrying one match and one skipped path. -- The writer unit
  test is the pattern `file_contents_to_envelope_carries_bytes_and_skipped_paths` already establishes.
- `packages/zanshin_core/lib/src/ffi/file.dart` + `worker/isolate.dart` + `worker/handle.dart` -- add a
  `FileSearch` model mirroring `FileContents`, return it from the decode seams, and thread the new
  return type through `ZanshinWorker.fileSearch` and `RepoHandle.fileSearch`. -- The isolate command
  arm forwards raw bytes and needs no change.
- `packages/zanshin_core/test/ffi/file_test.dart` + `test/worker/file_test.dart` -- extend the search
  decode group with a synthetic buffer carrying a `SkippedPathObjectBuilder` entry and with the
  absent-vector row (`skipped` decodes to empty), and update the worker rows for the new type. --
  Mirrors the two `FileContents` rows at `:108-146` exactly.
- `crates/zanshin-jj/src/git.rs` -- extract the `GitImportStats.abandoned_commits` → `Vec<ChangeId>`
  mapping into a `pub(crate)` helper and call it from `git_import`. -- One helper so the two verbs
  cannot drift, which is what the ledger asks for.
- `crates/zanshin-jj/src/remotes.rs` -- bind `import_refs()`'s `GitImportStats` and fill
  `abandoned_change_ids` from that helper, leaving `new_change_ids` as `Vec::new()` with a WHY naming
  `GitImportStats`' lack of a minted-change concept; update `git_fetch`'s doc block. -- The stats were
  already computed and thrown away one line later.
- `crates/zanshin-jj/src/mutate.rs` + `packages/zanshin_core/lib/src/ffi/mutate.dart` (+ any other hit
  of the claim) -- correct every doc saying both vectors are always empty for `git_fetch`, and say what
  `abandoned_change_ids` now means there (jj-lib's OWN abandonments, not a caller echo). -- The field's
  documented contract ("the ids `abandon`'s caller passed in") is widened by this change; leaving it
  would make the doc lie.
- `crates/zanshin-jj/tests/remotes_write.rs` -- bind the result in
  `git_fetch_with_the_default_config_abandons_unreachable_commits` and assert `abandoned_change_ids`
  contains the pruned change and `new_change_ids` is empty; add the negative control on the
  `abandon-unreachable-commits = false` sibling (`abandoned_change_ids` empty). -- Two rows of the
  matrix and the proof the projection reads stats rather than being hardcoded either way.
- `crates/zanshin-jj/tests/api_stability.rs` -- add `sample_remote()` and `sample_file_search()`, the
  `FileSearch` type alias, and their call sites. -- Every payload struct in this file has a field-level
  sample; the two new public shapes must be pinned there too.
- `_bmad-output/implementation-artifacts/deferred-work.md` + the three originating specs -- strike the
  three ledger bullets in the house convention (`~~bold title~~` + ` — RESOLVED 2026-09-05
  (spec-epic-9-followup-e-payload-widenings, commit <short hash>): …`) and add a `resolved: >-` block
  scalar to each matching `deferred:` item, keeping the YAML valid. -- The ledger must end this run
  three items smaller than it started.

**Acceptance Criteria:**
- Given a `git stash` of only the `crates/zanshin-jj/src` and `crates/zanshin-ffi/src` changes, when
  the new tests run, then each of the three items' witnesses FAILS — every new fact is pinned by a test
  that observes it, not by construction.
- Given `cargo make codegen` is run exactly once, when `git status --porcelain` is inspected, then
  the two flatc outputs show a diff, and `crates/zanshin-ffi/include/zanshin_ffi.h` +
  `packages/zanshin_core/lib/src/ffi/bindings.dart` show NO SIGNATURE change — their only diff is
  the doc-comment text cbindgen/ffigen lift from the `extern "C"` rustdoc that the intent-contract
  separately REQUIRES be corrected. (Amended 2026-09-06 — see the Spec Change Log; as originally
  written this criterion was unsatisfiable together with the contract's doc-correction mandate.)
- Given the whole test suite, when it runs, then no test reads `remote.<name>.pushurl` through raw
  `git config` any more, while `git_remotes.rs`'s `remote.<name>.url` oracle at `:595` still does.
- Given `cargo make test`, when it completes, then it exits 0 with no per-file coverage regression and
  no edit to `coverage-baseline.txt` other than ratchet-raised values.
- Given `deferred-work.md` after the run, when its three targeted bullets are read, then each is struck
  through with a resolution sentence naming this spec and the commit, and no new bullet was added.

## Spec Change Log

### 2026-09-06 — Generated-artifact byte-identity criterion reconciled

**Triggering finding (review pass 1, `patch`, low):** three of the four review layers reported that
Acceptance Criterion #2 ("`zanshin_ffi.h` and `bindings.dart` show NO diff") cannot hold at the same
time as the intent-contract's **Always** mandate to correct "every doc that claims those vectors are
always empty for `git_fetch` … at every layer (Rust field docs, the `Repo`/`extern "C"` facade docs,
the Dart field docs)". `zanshin_file_search`'s doc is likewise now wrong about what it skips. cbindgen
and ffigen lift rustdoc verbatim, so correcting an `extern "C"` doc necessarily moves both generated
files.

**What was amended:** Acceptance Criterion #2 and the matching `## Verification` command — both
OUTSIDE `<intent-contract>`, which was not touched. They now require *no signature change* and
expect a doc-comment-only diff.

**Known-bad state avoided:** the alternative reading — revert the two `extern "C"` doc corrections to
keep the generated files byte-identical — would have shipped a header and a `bindings.dart` that
actively lie about `git_fetch`'s `abandoned_change_ids` and `file_search`'s skip set, and would have
left `cargo make verify-codegen` in permanent drift against the sources. The contract's own **Always**
clause forbids it directly. The contract's byte-identity sentence is phrased as an *inference* from
"no signature change"; the premise holds, the inference about cbindgen's output does not.

**KEEP:** the doc corrections at all four layers, and the regenerated `zanshin_ffi.h` /
`bindings.dart` committed alongside them. Do not hand-edit either generated file.

## Review Triage Log

### 2026-09-06 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 2, low 5)
- defer: 1: (high 0, medium 0, low 1)
- reject: 18: (high 0, medium 0, low 18)
- addressed_findings:
  - `[medium]` `[patch]` Retiring the negative `git config --get remote.origin.pushurl` oracle cost
    real detection strength: `push_url` is a DIFFERENCE, so a `set_url` regression that copied its
    `url` argument into the push slot would write `pushurl == url`, `list_remotes` would still report
    `None`, and the replacement assertion would pass where the deleted oracle failed — and a stray
    `pushurl` key makes jj-lib's `remove_remote_git_config_sections` refuse, i.e. the remote becomes
    unremovable. Fixed by chaining the fetch-only set-url into `git_remote_remove` in
    `crates/zanshin-jj/tests/git_remotes.rs`, which is a key-ABSENCE witness through a shipped verb
    rather than a reinstated shell-out.
  - `[medium]` `[patch]` No test pinned a push URL to its OWN remote: all five new rows hold a single
    remote, so a build loop pairing remote *n*'s push URL with *n+1* would have passed everything.
    Added `remotes_pair_each_push_url_with_its_own_remote` in `crates/zanshin-jj/tests/remotes.rs` —
    three remotes whose sorted order reverses their insertion order, outer two with distinct push
    URLs, middle one with none, asserted as one exact row list.
  - `[low]` `[patch]` Two assertions claimed more than they checked: `payload.skipped().map_or(0, |s|
    s.len()) == 0` collapses ABSENT and present-empty, while both messages asserted the vector is
    "still WRITTEN" / "present and EMPTY". Replaced with an `expect()` on presence followed by the
    length check, in `crates/zanshin-ffi/src/file.rs` and `crates/zanshin-ffi/tests/file_ffi.rs`;
    both still pass, so the writer really does emit a present empty vector.
  - `[low]` `[patch]` `sample_remote()` in `crates/zanshin-jj/tests/api_stability.rs` constructed
    `push_url: Some(String::new())` — literally the one shape the contract says the producer never
    emits — in the file a reader consults for the type's contract. Now carries a non-empty URL.
  - `[low]` `[patch]` The fetch-abandonment witness used `contains`, which a projection echoing every
    commit would also satisfy. Tightened to an exact-set assertion (the fixture makes exactly one
    commit unreachable) in `crates/zanshin-jj/tests/remotes_write.rs`.
  - `[low]` `[patch]` The difference rule makes `push_url` non-round-trippable — re-applying a read
    remote's config through `git_remote_set_url` would DELETE a `pushurl` that happened to equal the
    fetch URL. The docs explained the read side thoroughly and never warned the write side; added
    that warning to the Rust field doc and the Dart model doc (neither is generated, so no codegen).
  - `[low]` `[patch]` Acceptance Criterion #2 and its `## Verification` command were unsatisfiable
    together with the intent-contract's doc-correction mandate, since cbindgen/ffigen lift rustdoc.
    Amended outside `<intent-contract>` and recorded in the Spec Change Log.

## Design Notes

**Two premises of the dispatched intent are false; both were resolved from the ledger and the source,
not by picking a reading.** (a) The intent says the sibling `git::git_import` "projects real stats from
the same `import_refs` call" INTO `MutationResult`. It does not: `git_import` leaves
`mutation.new_change_ids`/`abandoned_change_ids` empty (`crates/zanshin-jj/src/git.rs:103-106`) and
puts the abandonments in its OWN `GitImportResult.abandoned_change_ids` (`:325-329`). Fetch has no
second result struct, and the ledger bullet itself prescribes the target precisely — "the same
`GitImportStats` → `abandoned_change_ids` mapping" (`deferred-work.md:246`) — so the stats land in
`MutationResult.abandoned_change_ids`, which widens that field's documented meaning for this one verb
(jj-lib's own abandonments, not a caller echo) and is why the doc-correction task exists. (b) The
intent says to construct an access-denied blob "the way the existing `FileContents.skipped` witness
does". That witness uses a SYMLINK (`crates/zanshin-jj/tests/file_reads.rs:374-388`); no test anywhere
in the repo constructs an access-denied blob and `crates/test-helpers`' `Entry` enum cannot express
one. The conditional in the intent ("if that witness constructs it in-test, reuse its helper") is
therefore not satisfied, and the `SecretBackend` route below is the substitute — no fixture is
regenerated either way, which is the constraint the intent actually cared about.

**Why `push_url` is a difference and not a raw read.** gix resolves `url(Push)` as
`push_url_alias.or(push_url).or_else(|| url(Fetch))` (`gix-0.85.0/src/remote/access.rs:38-47`) and
exposes neither `push_url` field publicly, so "was a `pushurl` configured?" is not answerable through
the API Zanshin already uses. The jj CLI does not ask that question either: it compares the two
rendered URLs and suffixes `(push: …)` only when they differ. Emitting `None` for a `pushurl` that
happens to equal `url` is therefore CLI parity, not information loss — and it keeps the field's meaning
("this remote pushes somewhere else") the one a UI actually wants.

```rust
// crates/zanshin-jj/src/remotes.rs — shape only; keep the existing to_bstring WHY block
let fetch = remote.url(Direction::Fetch).map(|u| u.to_bstring().to_string());
let push = remote.url(Direction::Push).map(|u| u.to_bstring().to_string());
let push_url = push.filter(|p| Some(p) != fetch.as_ref());
```

**Why the access-denied witness needs `SecretBackend`.** `MaterializedTreeValue::AccessDenied` is
produced at exactly one place in jj-lib (`conflicts.rs:213-216`) from exactly one error
(`BackendError::ReadAccessDenied`), which exactly one backend raises — the `testing`-gated
`SecretBackend`, which refuses any path containing `secret`. Corrupting or chmod-ing a git object does
NOT produce it (that is a different `BackendError`, which surfaces as `FileError::Backend`). jj's own
CLI tests use the same mechanism (`cli/tests/test_acls.rs`). The repo cannot be opened through
`Repo::open`, which hardcodes `default_backend_factories()`, so the witness constructs the `Workspace`
itself and calls the `pub(crate)` `file_search` directly — which is why it is an inline `src/` test and
not an integration test, and why it also carries the coverage for the new arm.

**Why `new_change_ids` stays empty for fetch.** `GitImportStats` reports abandonments, changed remote
refs, rewritten commit ids and failed ref names — nothing that corresponds to "a change this operation
minted". `git_import` leaves the same field empty for the same reason. When `@` itself is abandoned,
jj-lib replaces it and the replacement is already reported through `working_copy_change_id`.

## Verification

**Commands:**
- `cargo make codegen` -- run ONCE; expected: only the two flatc outputs change.
- `git diff -- crates/zanshin-ffi/include packages/zanshin_core/lib/src/ffi/bindings.dart`
  -- expected: doc-comment hunks only (the corrected `zanshin_file_search` / `zanshin_git_fetch`
  rustdoc, lifted by cbindgen/ffigen); no `extern "C"` signature line moves.
- `cargo test -p zanshin-jj --lib` -- expected: all pass, including the new inline access-denied
  witness in `src/file.rs`.
- `cargo test -p zanshin-jj --test remotes --test git_remotes --test remotes_write --test file_reads --test api_stability`
  -- expected: all pass; no `pushurl` shell-out remains.
- `cargo test -p zanshin-ffi --test remotes_ffi --test git_ffi --test file_ffi` -- expected: all pass.
- `cd packages/zanshin_core && dart test test/ffi/remotes_test.dart test/ffi/file_test.dart test/worker/git_test.dart test/worker/file_test.dart`
  -- expected: all pass. (Requires a current cdylib — `cargo make test` builds it.)
- Mutation probe: `git stash push -- crates/zanshin-jj/src crates/zanshin-ffi/src`, then re-run the
  three suites above -- expected: the push_url rows, the access-denied witness and the fetch
  `abandoned_change_ids` assertion FAIL; `git stash pop`.
- `cargo make test` -- expected: exit 0. Run unpiped and synchronously, allow ~15 minutes. The single
  gate; it ends with the coverage ratchet.
- `git status --porcelain` -- expected: clean after the final commit.

## Auto Run Result

Status: done
Blocking condition: none

### Summary

Three shipped payloads were widened in place so they report facts the caller had already paid for.
`Remote` gains `push_url: Option<String>`, computed as the jj CLI's own DIFFERENCE between the two
gix directions (gix's `url(Push)` falls back to the fetch URL and exposes no raw accessor, so a
difference test is the only faithful reading — and it is exactly what `jj git remote list` prints).
`file_search` now returns `FileSearch { matches, skipped }`, mirroring `FileContents` and reusing
`SkippedPath`, carrying ONLY `AccessDenied` with `jj file search`'s own wording. `git_fetch` binds the
`GitImportStats` that `import_refs()` already returned and threw away, filling
`MutationResult.abandoned_change_ids` through the same `pub(crate) project_abandoned` helper
`git_import` uses. One `schemas/envelope.fbs` edit, one `cargo make codegen`, generated outputs
committed. All three raw `git config --get remote.<n>.pushurl` oracles retired at both layers.

This run RESUMED an interrupted predecessor: the working tree at baseline `a829d80` already carried
that attempt's partial work, which was reconciled against this spec rather than discarded.

### Files changed

- `schemas/envelope.fbs` — `Remote.push_url`, `FileSearch.skipped`, `SkippedPath`'s third carrier.
- `crates/zanshin-ffi/src/envelope_generated.rs`,
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — flatc output.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` —
  cbindgen/ffigen output; DOC-COMMENT ONLY, no signature moved (see the Spec Change Log).
- `crates/zanshin-jj/src/remotes.rs` — `Remote.push_url`; `fetch_url` generalised into `remote_urls`
  reading both directions through one renderer; `git_fetch` projects the import stats.
- `crates/zanshin-jj/src/file.rs` — `FileSearch` struct, `file_search`'s new `AccessDenied` arm, and
  the inline `SecretBackend` witness.
- `crates/zanshin-jj/src/git.rs` — `project_abandoned` helper, shared with `git_import`.
- `crates/zanshin-jj/src/{lib,repo,mutate}.rs` — re-export, facade signature/doc, corrected
  `MutationResult` field docs.
- `crates/zanshin-jj/Cargo.toml` — `jj-lib` with `features = ["testing"]` as a DEV-dependency only.
- `crates/zanshin-ffi/src/{remotes,file,repo}.rs` — the two payload writers and the corrected
  `extern "C"` docs.
- `packages/zanshin_core/lib/src/ffi/{remotes,file,mutate}.dart`,
  `lib/src/worker/{handle,isolate}.dart` — Dart models, decode seams and the threaded return type.
- Tests: `crates/zanshin-jj/tests/{remotes,git_remotes,remotes_write,file_reads,api_stability}.rs`,
  `crates/zanshin-ffi/tests/{git_ffi,file_ffi}.rs`,
  `packages/zanshin_core/test/{ffi/remotes_test,ffi/file_test,worker/git_test,worker/file_test}.dart`.
- Bookkeeping: `deferred-work.md` plus the three originating specs.

### Review findings

7 patches applied (0 high, 2 medium, 5 low) — see the Review Triage Log. 1 item deferred (low): a
remote configured with only a `pushurl` and no `url` is dropped from `list_remotes` where the CLI
prints it with a `"<no URL>"` sentinel — pre-existing since Story 2.9, and closing it needs a product
decision because `Remote.url` is non-optional at both layers. 18 findings rejected, all either
pre-existing patterns the spec deliberately mirrored, defensive code for impossible states, or
scoped out by the intent contract itself (notably: no end-to-end populated `skipped` witness is
POSSIBLE, because the contract forbids widening `Repo::open`'s backend factories).

Follow-up review recommended: **true** — patched severities high 0, medium 2, low 5; score
`3 × 2 + 1 × 5 = 11`, which is ≥ 5.

### Verification

- `cargo check --all-targets` and `cargo clippy --all-targets --all-features -- -D warnings` — clean.
- `cargo make codegen` run once; re-running produced NO further diff in either flatc output.
- `cargo make test` — **exit 0**, run unpiped and synchronously (612 s). Coverage held at 99.21%
  (8465/8532 lines over 46 files), no per-file regression, `coverage-baseline.txt` UNTOUCHED,
  `extern-coverage: OK`.
- Matrix audit: all eleven I/O rows have a named covering test, and each was observed running and
  passing — the five `push_url` rows plus `remotes_on_native_backend_returns_empty` in
  `tests/remotes.rs`, `file_search_reports_an_unreadable_blob_as_skipped` inline in `src/file.rs`,
  the two `skipped.is_empty()` rows in `tests/file_reads.rs`, and the two `git_fetch` prune rows in
  `tests/remotes_write.rs`.
- Mutation probe (by the implementation pass, each mutation reverted afterwards): forcing
  `push_url` to `None` failed 5 tests; silencing the `AccessDenied` arm failed the inline witness;
  hardcoding `abandoned_change_ids` to `Vec::new()` failed the default-config row while its
  `abandon-unreachable-commits = false` negative control still passed.
- No `git config --get …pushurl` shell-out remains anywhere; the permitted `remote.origin.url`
  oracle survives at `crates/zanshin-jj/tests/git_remotes.rs:616`, as does `git_try`.

### Residual risks

- `MutationResult.abandoned_change_ids` now means two different things depending on the verb — a
  caller echo for `abandon`, jj-lib's OWN abandonments for `git_fetch`. The wire carries no
  discriminator; the distinction lives in five doc blocks. This is forced by the contract's "no
  second payload alongside the widened one", and is recorded rather than hidden.
- `FileSearch.skipped`'s POPULATED arm never crosses the FFI boundary in a test, because
  `MaterializedTreeValue::AccessDenied` has exactly one producer (`SecretBackend`) and the contract
  forbids making it loadable through `Repo::open`. The three layers above the producer are witnessed
  with hand-constructed inputs and with the empty case end-to-end.
- `Repo::file_search` and the Dart `fileSearch` seams are source-breaking signature changes. Checked:
  `app/lib` has no call sites, so the break is contained to `packages/zanshin_core`.

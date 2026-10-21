---
title: 'Story 9.30 — `git fetch` CLI parity: default remotes (`git.fetch`), `--remote`/`--all-remotes`, `--branch`/`--tag`/`--tracked`, per-remote fetch settings, one transaction, typed payload; the poll filtered like the fetch'
type: 'feature'
created: '2026-10-21'
status: 'done'
baseline_revision: '91f3575ad8b208ea344e83b36c2cc758c40f11ee'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/epics.md#Story 9.30'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** `Repo::git_fetch(remote_name, ..)` fetches ONE explicit remote with `glob("*")` bookmarks and tags. The front half of `cmd_git_fetch` is missing: default remotes, `--remote`/`--all-remotes`, `--branch`/`--tag`/`--tracked`, per-remote `fetch-bookmarks`/`fetch-tags`, the git-config refspec default, one transaction over many remotes, the `No git remotes to fetch from` refusal, and the CLI's warnings and hint. The op description does not quote remote names with `as_symbol()` (I2). The failed ref names have no typed payload (I3). The remote-change poll ignores the per-remote filters (I4). So the GUI Fetch button cannot do what `jj git fetch` does.

**Approach:** Port `cli/src/commands/git/fetch.rs` @ v0.46.0 into `zanshin-jj` with a typed args struct and an outcome struct. Reuse push's remote resolution (Story 9.20/9.54), parameterized. Add `Repo::git_fetch_remotes()`, the Fetch button's enable rule, mirroring `git_push_remotes`. Share the per-remote default ref filter with the poll. Carry everything through `.fbs` → FFI → Dart in place.

## Boundaries & Constraints

**Always:**
- Reference: `git -C ../jj show v0.46.0:cli/src/commands/git/fetch.rs`, plus `revset_util.rs:364-528` (`parse_union_name_patterns`, `parse_remote_fetch_bookmarks/tags`, `parse_remote_string_expression`), `git_util.rs:204-213`, and `commands/git/mod.rs:125-131` (`get_single_remote`).
- Rust args, a typed either/or (the CLI's clap `conflicts_with`, so nothing to refuse):
  - `GitFetchArgs { remotes: FetchRemotes, refs: FetchRefs }`.
  - `FetchRemotes::{Default, Named(Vec<String>), All}`.
  - `FetchRefs::{Default, Patterns { branches: Vec<String>, tags: Vec<String> }, Tracked}`.
  - `Patterns` IS the CLI's "specific" group: an empty list is `StringExpression::none()`.
  - All derive `Default`; the default is `Default`/`Default`.
  - Names are patterns parsed by `bookmark_ops::union_expression` (a bare word is a glob).
- Remote resolution:
  - `Default` = `git.fetch` (a list or a string) → else the single remote → else `origin`. When the single remote is not `origin`, the outcome carries the hint `Fetching from the only existing remote: <as_symbol>`. `Named` = the union of its patterns. `All` = every remote.
  - Matching runs against `get_all_remote_names`, in its order.
  - An exact name no remote carries warns `jj.fetch_remotes_unmatched`: `No matching remotes for names: a, b` (as_symbol, `", "`). This also covers the implicit `origin`.
  - No match refuses `MutateError::InvalidInput { "No git remotes to fetch from" }` before any transaction (no operation).
  - A native backend refuses `NotAGitRepo`.
- Per-remote refs:
  - `Tracked`: the exact-name union of the remote's tracked bookmarks and tags (`view.local_remote_bookmarks/tags(remote)` filtered by `remote_ref.is_tracked()`).
  - `Patterns`: the given unions.
  - `Default`, bookmarks: `remotes.<r>.fetch-bookmarks`, else `jj_lib::git::load_default_fetch_bookmarks(remote, git_repo)`. Each `IgnoredRefspec` warns `jj.fetch_refspec_ignored`: ``Ignored refspec `<refspec>` from `<as_symbol>`: <reason>``.
  - `Default`, tags: `remotes.<r>.fetch-tags`, else `all()`.
  - A malformed value is `MutateError::Config` with the CLI's ``Invalid `remotes.<r>.<field>`: …``.
  - An `expand_fetch_refspecs` error is `InvalidInput` (its Display).
- One transaction, in CLI order:
  - Fetch remote by remote; the progress callback is `"fetch"`, and Story 9.52's cancel checkpoints sit before each fetch and after the last.
  - Then ONE `import_refs`. `jj.git_import_failed` and `failed_ref_names` come from its stats.
  - With `Patterns` only, `warn_if_branches_not_found` warns `jj.fetch_branches_unmatched`: `No matching branches found on any specified/configured remote: a, b`. It names the exact names the matcher accepts that are absent as `<name>@<r>` for every matched remote, in both the tx view and the base view.
  - Then today's descendant rebase and `finish_verb`.
  - The description is `fetch from git remote(s) <as_symbol joined ",">`.
- `GitFetchOutcome { mutation: MutationResult, remotes: Vec<String>, hints: Vec<String>, failed_ref_names: Vec<String> }`:
  - `mutation` is exactly today's, including the abandonments.
  - `remotes` = the matched names.
  - `failed_ref_names` = lossy UTF-8, in `project_import`'s order.
- `Repo::git_fetch_remotes() -> Result<Vec<String>, MutateError>`: the `Default` resolution only. It warns as the fetch does, returns `[]` for no match or a native backend, writes no operation of its own, and drops the hint (as `git_push_remotes`).
- Poll (`remote_changes`):
  - Per remote, the `Default` bookmark/tag expressions above (ignored refspecs dropped silently: the poll is no CLI verb).
  - Both the advertised names and the view names are filtered through their matchers before the diff.
  - Its FFI/Dart surface is unchanged.
- Wire:
  - `GitFetchRequest { kind (RequestKind::GitFetch, appended); remotes_mode: FetchRemotesMode {Default, Named, All}; remotes: [string]; refs_mode: FetchRefsMode {Default, Patterns, Tracked}; branches: [string]; tags: [string]; cancel_token: uint64 }`.
  - `zanshin_git_fetch(handle, data, len)` replaces `(handle, remote_name, cancel_token)` in place, as `zanshin_git_push` does.
  - Payloads `GitFetchResult { mutation; remotes; hints; failed_ref_names }` and `GitFetchRemotes { names }` are appended to `Payload`.
  - New symbol `zanshin_git_fetch_remotes(handle)`.
  - Generated code comes from `cargo make codegen` and is committed.
- Dart (`packages/zanshin_core`):
  - `RepoHandle.gitFetch({FetchRemotes remotes = const DefaultFetchRemotes(), FetchRefs refs = const DefaultFetchRefs()})` → `NetworkOperation<GitFetchResult>` (sealed `FetchRemotes`/`FetchRefs` mirroring Rust).
  - `RepoHandle.gitFetchRemotes()` → `Future<WarnedList<String>>`.
  - Three warning-code consts; the exports.
- Witness the new warning kinds the way every kind is witnessed: `api_stability.rs` + `envelope.rs` mapping + `docs/rust-error-codes.md` + `warning.dart`.

**Never:**
- No `--no-integrate-operation`, and no no-change gate: a no-change fetch still writes an op (Story 9.40's).
- No push, clone or MCP changes.
- No UI code.
- Don't regenerate fixtures; never shell to `jj` in production.
- `jj.remote_not_found` stays only on the (unreachable) `GitFetchError::NoSuchRemote` arm. A `--remote` that names nothing is CLI parity: a warning plus `jj.invalid_input`. This is a deliberate observable change; record it in the registry.

## I/O & Edge-Case Matrix

Bare remotes are built in-test (`git init --bare` + `jj_lib::git::add_remote` / `git remote add`, as `tests/it/remotes_write.rs` does). Config is set through the repo layer, as existing fetch tests do.

| Scenario | State / args | Expected | Error |
|---|---|---|---|
| Default, one remote `origin` | upstream `main` | `remotes=[origin]`, no hint, `main@origin` imported, desc `fetch from git remote(s) origin` | — |
| Default, only remote `up` | | `remotes=[up]`, hint `Fetching from the only existing remote: up` | — |
| Default, `origin` + `up` | | origin only | — |
| Default, `up` + `up2` (no origin) | | warning `No matching remotes for names: origin`; no op | `InvalidInput "No git remotes to fetch from"` |
| `git.fetch = ["up","origin"]` / `"up"` | two remotes | both / up; desc `fetch from git remote(s) origin,up` (remote order) | — |
| `Named(["origin","nope"])` | | fetch origin + warning `…names: nope` | — |
| `Named(["nope"])` | | warning; no op | `InvalidInput` |
| `All` | two remotes | both in ONE op | — |
| `Patterns{branches:["feat*"], tags:[]}` | upstream `feat1`, `main`, tag `v1` | only `feat1@origin`; no tag | — |
| `Patterns{branches:["nope"]}` | | warning `No matching branches found on any specified/configured remote: nope` | — |
| `Tracked` | `a@origin` tracked, `b@origin` untracked, both moved upstream | only `a` moves | — |
| `remotes.origin.fetch-bookmarks = "main"` | upstream `main`, `other` | only `main` | — |
| `remotes.origin.fetch-tags = "v*"` | tags `v1`, `x1` | only `v1` | — |
| Ignored refspec | git `remote.origin.fetch` adds a refspec jj ignores (e.g. `refs/pull/*:refs/remotes/origin/pr/*`) | warning `Ignored refspec … from \`origin\`: …`; fetch proceeds | — |
| Malformed `fetch-bookmarks = "glob:("` | | — | `Config` (`Invalid \`remotes.origin.fetch-bookmarks\``) |
| Native backend | | — | `NotAGitRepo` |
| Remote name `as_symbol` ≠ `as_str` | pure description fn | quoted name in desc | — |
| `git_fetch_remotes` | each Default row above | same remote list / `[]` + same warnings; no op | — |
| Poll | `fetch-bookmarks = "main"`, upstream new `other` | `other` not reported; `main` still is | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/remotes.rs:219-352` — today's `git_fetch`. Rework it here and keep `ProgressCallback`. The `:327-331` warning/abandon handling and the `:339-346` rebase+finish stay.
- `crates/zanshin-jj/src/repo.rs:1252-1305` — `Repo::git_fetch` doc + signature (`with_verb`). `:575-594` is `git_push_remotes`, the template for `git_fetch_remotes`. `:1307+` is `remote_changes` (doc gains the filter).
- `crates/zanshin-jj/src/push.rs:783-878` — `resolve_remotes` / `default_push_remotes` / `matching_remotes` / `git_push_remotes`. Parameterize the last three (config texts, hint verb, `WarningKind`) and share them with fetch; push behaviour must stay byte-identical (its `tests/it/push*.rs` + oracle push scenarios).
- `crates/zanshin-jj/src/bookmark_ops.rs:129` — `union_expression` (pattern parse → `InvalidInput`); `:151` — `join_symbols` (op descriptions quote via `as_symbol`).
- `crates/zanshin-jj/src/config.rs`:
  - `:1605` `git_push_remotes`: add a twin `git_fetch_remotes` for `git.fetch`.
  - `:1625` `remote_settings(config, remote)`: reads every entry.
  - `:1430` `parse_remote_string_expression` (private): reuse for `fetch-bookmarks`/`fetch-tags`.
  - `:1334` `git_import_options`: unchanged; auto-track already ported, see I5.
  - Inline tests sit near `:3767`.
- `crates/zanshin-jj/src/remote_changes.rs:86-129` (`remote_changes`), `:222-257` (`diff_against_view`): filter names via matchers; add inline unit tests for the filtering.
- `crates/zanshin-jj/src/warning.rs:28-171` (`WarningKind`, append three variants after `PushRemotesUnmatched`/`CloneBranchesUnmatched` style docs) and `:403` (`git_import_failed`).
- `crates/zanshin-jj/src/git.rs:390-402` — `project_import`'s `failed_ref_names` projection (reuse or extract).
- `crates/zanshin-jj/src/lib.rs` — re-export the new public types.
- `crates/zanshin-jj/src/mutate.rs:72-90,187-240` — `MutationResult` / `MutateError` docs that name `git_fetch` (RemoteNotFound now unreachable from a `--remote` miss).
- Tests: `crates/zanshin-jj/tests/it/main.rs` (declare a new `git_fetch_parity` module for the matrix).
  - `remotes_write.rs` holds the existing fetch tests and the bare-remote fixture helpers (`:47-180`). Update the callers there (`:354` nonexistent → InvalidInput + warning, `:791` reserved `git` → InvalidInput) and the callers in `remote_changes.rs`, `op_workspace_name.rs`, `config_identity.rs`, `snapshot_colocated.rs`, `network_cancel.rs`, `login_shell_environment.rs` and `api_stability.rs:89,435-438,524,1400,1472`.
  - Most callers become `&GitFetchArgs::default()` and read `.mutation`.
- `crates/zanshin-ffi/src/repo.rs:1345-1400` — `zanshin_git_fetch`. Mirror `crates/zanshin-ffi/src/push.rs:332` (request decode, `expect_request_kind`, cancel token from the request). `crates/zanshin-ffi/src/remotes.rs:104,139` (`push_remotes_to_envelope`, `zanshin_git_push_remotes`) are the template for `zanshin_git_fetch_remotes`. `crates/zanshin-ffi/src/envelope.rs:317,339,386,1230,1290` handle the warning-code consts, the mapping and its exhaustiveness test.
  - Tests: `tests/it/repo_write_ffi.rs:718-970,1449,1586` (fetch rows; the null-remote test becomes a null-buffer test), plus a fetch-remotes row.
  - Grep for the exported-symbol count (`EXPECTED_EXPORTS` or similar) and `tests/it/ffi_abi_doc_sync.rs`.
- `schemas/envelope.fbs:75-114` (`RequestKind`, APPEND), `:258` (`GitPushRequest`, the template), `:949` (`GitPushRemotes`, the template), `:1142` (`MutationResult`), `:1879-1925` (`Payload`, APPEND).
- Dart:
  - `packages/zanshin_core/lib/src/ffi/mutate.dart:116-130` (fetch adapter → request bytes via `request_bytes.dart`); `ffi/push.dart` (request build + `decode…EnvelopeInternal` template); `ffi/remotes.dart` (push-remotes decode template).
  - `worker/isolate.dart:1157-1167` (`gitFetch`; `GitFetchCommand` + its helper-isolate arm near `:2765`/`:3526`), `:954` (`gitPushRemotes` template); `worker/handle.dart:309,487-491`.
  - `ffi/warning.dart:176,209`; `lib/zanshin_core.dart` exports.
  - Tests: `test/worker/mutate_test.dart:221-245,375-385`, `test/worker/network_operation_test.dart` (callers), `test/ffi/warning_test.dart:415`, plus a synthetic `GitFetchResult` decode test and a real-cdylib `gitFetchRemotes` test (no git child).
- Parity oracle: `crates/zanshin-parity/tests/oracle/git_scenarios.rs:210-280` (push's `REMOTE`/`PUSHED`/`push_read_back`/`push()` template); `tests/oracle/main.rs:38+` (`parity!` id list); `ledger.rs`.
- Docs: `docs/ffi-abi.md:528` (fetch row → request table), the symbol index (new row), `:855,924`; `docs/rust-error-codes.md:157,168` (warning rows) + the `jj.remote_not_found` / `jj.invalid_input` rows for fetch.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/push.rs`, `config.rs` -- share the default-remote resolution between push and fetch: parameterize `default_push_remotes`/`matching_remotes` by config texts, hint text and `WarningKind`. Add `config::git_fetch_remotes` and a `pub(crate)` per-remote `fetch-bookmarks`/`fetch-tags` expression reader on `remote_settings` + `parse_remote_string_expression`, with inline tests.
- `crates/zanshin-jj/src/remotes.rs` -- `GitFetchArgs`/`FetchRemotes`/`FetchRefs`/`GitFetchOutcome`. Rework `git_fetch` per the Always rules. Add a pure `fetch_description(&[RemoteNameBuf])` with an inline test for a quoted name. Add a `pub(crate)` default per-remote ref-expression helper shared with the poll, and `git_fetch_remotes`.
- `crates/zanshin-jj/src/warning.rs`, `lib.rs`, `repo.rs`, `mutate.rs` -- three `WarningKind`s; re-exports; `Repo::git_fetch(&GitFetchArgs, ..) -> GitFetchOutcome`; `Repo::git_fetch_remotes()`; docs (`# Errors` lists).
- `crates/zanshin-jj/src/remote_changes.rs` -- filter advertised and view names with the shared default expressions; update the doc; inline tests for the filter.
- `crates/zanshin-jj/tests/it/git_fetch_parity.rs` (+ `main.rs`) -- one test per matrix row. Assert the op description, imported refs (`list_bookmarks`), warnings (`take_warnings`), hints, `remotes`, and the no-op op id on refusals. Add one `failed_ref_names` row if a failing ref is constructible (else record why not), plus the poll row. Update every other caller and `api_stability.rs`.
- `schemas/envelope.fbs`, then `cargo make codegen` -- the request table, the two enums, the two payload tables, the `RequestKind`/`Payload` appends; commit the regenerated Rust/Dart/C header/bindings.
- `crates/zanshin-ffi/src/{repo.rs,remotes.rs,envelope.rs}` + `tests/it/*` -- `zanshin_git_fetch` request-buffer form (all `# Errors` codes), `zanshin_git_fetch_remotes`, the warning codes; FFI tests for encode/decode of every field, a happy-path fetch with `remotes`/`hints`, invalid input + warning on a miss, the null/invalid buffer, and the fetch-remotes query; the export count.
- `packages/zanshin_core/...` -- sealed args, `GitFetchResult`, `gitFetch`/`gitFetchRemotes` through the worker, the warning consts, exports, tests; `dart format` the package.
- `crates/zanshin-parity/tests/oracle/git_scenarios.rs`, `main.rs`, `ledger.rs` -- fetch scenarios against bare remotes. Each scenario brings something new upstream (e.g. `git --git-dir ../remote.git branch n-mark b-mark` after a push), so no 9.40 no-change divergence arises. Cover: default, only remote `up`, no remote (refusal), unmatched name, `All` over two remotes, `-b` pattern, `--tracked`, `git.fetch` set via `jj config set --repo`, and `remotes.origin.fetch-bookmarks`. Ledger only true, referenced divergences.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows, request table, warning codes, the `jj.remote_not_found` → `jj.invalid_input` change for fetch misses.

**Acceptance Criteria:**
- Given a repo with only remote `up`, when `RepoHandle.gitFetch()` runs with no arguments through the real worker, then the fetch imports from `up`, the result has `remotes == ['up']` and the CLI's only-remote hint, and the op description is `fetch from git remote(s) up`. The Rust and FFI tests witness this (a Dart git child is reaped, as `mutate_test.dart` notes; Dart witnesses the refusal path and the decode).
- Given remotes `a` and `b` and no `origin` and no `git.fetch`, when `gitFetchRemotes()` is called, then it returns `[]` with warning `jj.fetch_remotes_unmatched`, and `gitFetch()` refuses `jj.invalid_input` "No git remotes to fetch from" with the same warning and no new operation. This is the Fetch button's enable rule.
- Given every fetch scenario, when the oracle runs, then Zanshin and `jj git fetch` @ v0.46.0 agree on the repo state, the op description, refusal and warning count (or a ledgered, referenced divergence).
- Given `remotes.origin.fetch-bookmarks = "main"`, when the poll runs against an upstream with a new `other`, then `other` is not reported (I4).
- All the targeted checks under Verification pass.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 36 findings — high 0, medium 7, low 21, false 8, maybe-false 0 (the 8 intent-alignment rows are its descriptive divergences)
- findings:
  - (blind-hunter) `[low]` `[reject]` Cancel token never attached when a verified buffer has a wrong kind/unknown mode — real only for a buffer the generated Dart adapter never builds; identical to `zanshin_git_push` (`push.rs:335-336`); the fix reorders the decode (more than a direct correction) for a path no caller reaches.
  - (blind-hunter) `[low]` `[patch]` Ignored-refspec warnings dropped when `fetch-tags` is malformed (CLI prints them first) — patched: the fetch warns the collected refspecs before propagating `remote_fetch_refs`' error.
  - (blind-hunter) `[low]` `[reject]` Native backend + bad `--remote` pattern / malformed `git.fetch` reports `jj.not_a_git_repo` where the CLI reports the pattern/config error — reachable only on a native-backend repo with a broken pattern; push has the same order; the fix restructures the shared resolution.
  - (blind-hunter) `[low]` `[reject]` `Patterns{[],[]}` / `Named([])` are constructible fetch-nothing / refuse-everything requests the CLI cannot express — the spec defines an empty list as `StringExpression::none()` (the CLI's `specific` group semantics); a caller builds it only deliberately, and `Named([])` refuses like any miss.
  - (blind-hunter) `[low]` `[reject]` cbindgen drops four same-named `*_VT_*` defines from `zanshin_ffi.h` — a generator per-name dedup quirk; no consumer of any `VT_*` macro exists (grep); the wire is described by `envelope.fbs`, not the header.
  - (blind-hunter) `[low]` `[reject]` The only-remote hint is lost on a failing fetch — a hint (not a warning) the CLI prints; carrying it on error envelopes adds new envelope surface for a cosmetic line.
  - (blind-hunter) `[medium]` `[patch]` Test gaps: tags-only `Patterns`, `Tracked` tags, malformed `remotes.*` refusing `--tracked` (+ malformed `fetch-tags`, unparseable pattern, expand failure) — grouped with the verification-gap rows below; patched: tags-only, tracked-tags and tracked-with-malformed-entry rows added. The unparseable-pattern path is `bookmark_ops::union_expression`, shared with and witnessed by push; the parse of a malformed `fetch-tags` is the same `parse_remote_string_expression` call as the witnessed `fetch-bookmarks` one.
  - (blind-hunter) `[medium]` `[patch]` The poll's common filters (git refspec default, `fetch-tags`) and its new error paths untested — grouped with verification-gap #4; patched: `fetch-tags` poll row and malformed-config poll row.
  - (blind-hunter) `[low]` `[reject]` No multi-remote cancel test — the final checkpoint before `import_refs` still guarantees a cancelled fetch records nothing even if a per-remote checkpoint misbehaved; a two-remote cancel harness is more than a direct correction.
  - (blind-hunter) `[medium]` `[patch]` Dart request-encoding test cannot catch swapped fields — grouped with verification-gap #1; patched (wire-shape test).
  - (blind-hunter) `[low]` `[reject]` Redundant `remotes.*` re-reads per remote — a few in-memory config lookups per fetch, no observable effect.
  - (blind-hunter) `[low]` `[patch]` Dart `gitFetch` docs omit `jj.remote_not_found` / `internal.dispatch_error` — patched: both doc lists completed.
  - (blind-hunter) `[low]` `[patch]` Reserved-name fetch test asserts only `InvalidInput { .. }` — patched: the reason and the `FetchRemotesUnmatched` warning naming `git` are asserted.
  - (blind-hunter) `[low]` `[reject]` `git_fetch_remotes` runs the pre-verb snapshot — the `git_push_remotes` precedent (Story 9.54); the CLI's fetch snapshots too; UI caching is a UI decision.
  - (blind-hunter) `[low]` `[patch]` Two overlong edited comment lines (`mutate.rs`, `zanshin-ffi/src/remotes.rs`) — patched: rewrapped.
  - (edge-case-hunter) `[low]` `[reject]` Same as the first blind-hunter row (token not attached on a wrong-kind buffer) — same refutation-of-worth.
  - (edge-case-hunter) `[low]` `[reject]` Dart `_rejectInteriorNuls` throws before Rust, so the allocated token is never ended — pre-existing: the old `gitFetch(String)` adapter rejected a NUL remote name before the FFI call the same way; one registry entry per refused NUL call, which a GUI never sends.
  - (edge-case-hunter) `[low]` `[patch]` Ignored-refspec warnings lost on a malformed `fetch-tags` — same root cause as blind-hunter row 2; patched there.
  - (edge-case-hunter) `[low]` `[reject]` `Patterns{[],[]}` fetches nothing yet writes an op — same as blind-hunter row 4.
  - (edge-case-hunter) `[low]` `[patch]` The poll accepts a filter `expand_fetch_refspecs` refuses (e.g. a `?` glob), so it reports refs the fetch then refuses — patched: the poll runs `expand_fetch_refspecs` on its filters and refuses `jj.invalid_input` like the fetch.
  - (edge-case-hunter) `[low]` `[reject]` Hint lost on the error path — same as blind-hunter row 6.
  - (edge-case-hunter) `[low]` `[reject]` Header lost four `VT_*` defines — same as blind-hunter row 5.
  - (verification-gap) `[medium]` `[patch]` Dart `gitFetch` never shows `All`/`Patterns`/`Tracked` reach Rust correctly — patched: request building factored into a `@visibleForTesting` builder; a wire-shape test decodes it with `fbs.GitFetchRequest` for all five variants.
  - (verification-gap) `[medium]` `[patch]` `-t` patterns and the tag half of `--tracked` have no test — patched: two rows in `git_fetch_parity.rs`.
  - (verification-gap) `[medium]` `[patch]` The read-and-discard `every_remote_settings` refusal has no test — patched: `Tracked` + malformed `remotes.origin` → `Config`, head op unchanged.
  - (verification-gap) `[medium]` `[patch]` The poll's tag filter and new error paths unreached — patched: `fetch-tags` and malformed-config poll rows.
  - (verification-gap other) `[low]` `[reject]` Token not attached before the kind check — same as blind-hunter row 1 (push-consistent).
  - (verification-gap other) `[low]` `[reject]` Header `VT_*` defines dropped — same as blind-hunter row 5.
  - (intent-alignment) `[false]` `[reject]` Unmatched names / ignored refspecs / branches-not-found ride the warning channel, not typed lists — the Story 9.32 convention (CLI `ui.warning_*` → coded warnings, epic context "Requirements"); I3's typed payload is specific to failed refs and is delivered.
  - (intent-alignment) `[false]` `[reject]` Result wrapped and the C ABI of `zanshin_git_fetch` replaced instead of "optional fields in place" — the payload facts ride beside the unchanged `MutationResult` (Design Notes); FlatBuffers request buffers are the house pattern for composite inputs (`zanshin_git_push`).
  - (intent-alignment) `[false]` `[reject]` Happy-path fetch through Dart witnessed only in Rust/FFI — the Dart VM reaps jj-lib's git child (documented limit, deferred-work.md "No Dart witness of a SUCCESSFUL remote-change poll"); the AC states this split.
  - (intent-alignment) `[false]` `[reject]` I2 quoting witnessed only by the pure description test — the description is built solely by `fetch_description`, called once in `git_fetch`; the rendering is jj-lib's `as_symbol`, the same call the CLI uses.
  - (intent-alignment) `[false]` `[reject]` Oracle thinner than the matrix — every matrix row has a Rust test; the oracle covers the nine CLI-observable shapes the spec named; the extra rows are covered by the patched tests above.
  - (intent-alignment) `[false]` `[reject]` Poll filters view names too / adds error causes — the spec's Always rule filters both sides deliberately (a filtered-out ref must not read "deleted" either); the error causes are documented.
  - (intent-alignment) `[false]` `[reject]` I5 adds no new witness — the existing `git_fetch_honours_remote_auto_track_bookmarks` already pins it through `list_bookmarks`.
  - (intent-alignment) `[false]` `[reject]` No numbered `## Auto Run Result` / commits yet — written at finalization (this step), not part of the reviewed diff.

## Design Notes

- **Typed either/or, not refusals:** the epic asks for `--tracked` vs patterns as "a typed either/or". `FetchRemotes`/`FetchRefs` make the clap conflicts unrepresentable on every layer, wire enums included. Push's bool style (refusing the conflicts) is not repeated.
- **`InvalidInput` for "No git remotes to fetch from":** this matches push's "No git remotes to push to". The CLI emits it for any miss, explicit or default, so the old per-name `jj.remote_not_found` cannot stay without diverging.
- **Outcome shape:** a wrapper around the unchanged `MutationResult` (the `GitImportResult` precedent). The epic's "`MutationResult` unchanged apart from the payload facts" is read as: the payload facts ride beside it, not inside it.
- **I5** (`remotes.<name>.auto-track-bookmarks` at the three import sites) appears already done by Story 9.26 (`config.rs:1320-1365`; witness `tests/it/remotes_write.rs:256-300` `git_fetch_honours_remote_auto_track_bookmarks`; clone `tests/it/creation_warnings.rs:425`). Verify that `git_import` reads the same options (`git.rs:323`), then report it as rejected (no longer applies), unless a site is found missing.

## Verification

Gate rule (Ralph, 2026-10-20): no `cargo make test`/`test-full`/`coverage`.

**Commands:**
- `cargo make codegen` -- regenerates; the diff is committed.
- `cargo test -p zanshin-jj --test it git_fetch_parity::` and `cargo test -p zanshin-jj` -- green.
- `cargo test -p zanshin-ffi` -- green.
- `cargo test -p zanshin-parity --test oracle` -- green (fetch + push scenarios).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean.
- In `packages/zanshin_core`: `flutter test` (or `dart test`), `dart analyze`, `dart format --set-exit-if-changed .` -- clean.
- Record every check and outcome below.

**Results (2026-10-21, implementation run):**
- `cargo make codegen` — regenerated `envelope_generated.rs`, `zanshin_ffi.h`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart` (run twice: the second after the `zanshin_git_remote_changes` rustdoc gained `jj.invalid_input`).
- `cargo test -p zanshin-jj --test it git_fetch_parity::` — 19 passed. `cargo test -p zanshin-jj` — 286 unit + 941 integration passed (1 pre-existing ignore).
- `cargo test -p zanshin-ffi` — 190 unit + 300 integration passed (`EXPECTED_EXPORTS` 72 → 73; the doc-sync guards green).
- `cargo test -p zanshin-parity --test oracle` — 190 passed, 9 new fetch scenarios (`SCENARIO_IDS` 172 → 181), no ledger entry. Sensitivity checked once by hand: a deliberately wrong CLI side (`-b x*`) failed with UNEXPECTED extra / git refs / warnings, then reverted.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean. `cargo fmt --all --check` — clean.
- `packages/zanshin_core`: `cargo make --allow-private test-core` (the pinned-env `dart test`) — 908 passed; `dart analyze` — no issues; `dart format --set-exit-if-changed .` — clean. `app/`: `dart analyze` — no issues.
- I5 — rejected (no longer applies): `remotes.<name>.auto-track-bookmarks` already reaches every import site through `config::git_import_options` (fetch, `git_import`, clone's `fetch_new_remote`, the conversion's `init_git_refs`, the pre-verb `import_git_refs`).
- `failed_ref_names` row — constructible: a ref in jj's reserved `refs/remotes/git/` namespace of the backing Git repo (`git_fetch_parity::a_ref_the_import_cannot_read_is_reported`).
- Not run, per the gate rule: `cargo make test` / `test-full` / `coverage` (the coverage ratchet is unverified for the new lines).
- Review pass re-verification (2026-10-21, after the seven patches): `cargo fmt --all --check` clean; `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` clean; `cargo test -p zanshin-jj` 286 unit + 946 integration passed (1 pre-existing ignore); `cargo test -p zanshin-ffi` 190 + 300 passed; `cargo test -p zanshin-parity --test oracle` 190 passed; `cargo make codegen` re-run, no further diff; `cargo make --allow-private test-core` 909 passed; `dart analyze` (zanshin_core, app) no issues; `dart format --set-exit-if-changed` clean. Matrix audit: every I/O-matrix row has a passing test (`tests/it/git_fetch_parity.rs`, 24 tests; the `as_symbol` row is `remotes.rs`' inline `the_fetch_description_quotes_each_remote_as_a_symbol`).

## Auto Run Result

Status: done

**Summary.** `jj git fetch` @ v0.46.0 is ported: `Repo::git_fetch(&GitFetchArgs) -> GitFetchOutcome` (typed `FetchRemotes::{Default, Named, All}` / `FetchRefs::{Default, Patterns, Tracked}`), default remotes `git.fetch` → the only remote (with the CLI hint) → `origin` (shared with push via `push::RemoteDefaults`), one transaction and one import over all matched remotes, per-remote `fetch-bookmarks`/`fetch-tags` else the git refspecs, `--tracked`, the `as_symbol` op description, the "No git remotes to fetch from" refusal (`jj.invalid_input`, no op), warnings `jj.fetch_remotes_unmatched` / `jj.fetch_refspec_ignored` / `jj.fetch_branches_unmatched`, and a typed `failed_ref_names`. `Repo::git_fetch_remotes()` is the Fetch button's enable rule. The remote-change poll filters advertised and view names with the bare fetch's per-remote filters and refuses what the fetch refuses. Wire: `GitFetchRequest` (+ two mode enums), `GitFetchResult`, `GitFetchRemotes`, `zanshin_git_fetch(handle, data, len)`, new `zanshin_git_fetch_remotes`; Dart `RepoHandle.gitFetch({remotes, refs})` / `gitFetchRemotes()`. Nine parity-oracle fetch scenarios, no ledger entry.

**Commits:** `7e51a50934c25a9e6252603d6106c0bdb7ba865a` (code, tests, codegen, docs); the spec/sprint-status commit follows it.

**Deferred items (I1–I5):**
- I1 — fixed (7e51a50934c25a9e6252603d6106c0bdb7ba865a): default-remote resolution, `--remote`/`--all-remotes`/`--tracked`/`--branch`/`--tag`, per-remote `fetch-bookmarks`/`fetch-tags` + git refspecs, one multi-remote transaction, the refusal and `Repo::git_fetch_remotes` (enable rule). `remotes.<name>.auto-track-bookmarks` see I5. The no-change op stays Story 9.40's.
- I2 — fixed (7e51a50934c25a9e6252603d6106c0bdb7ba865a): `fetch_description` renders every remote with `as_symbol()`, joined by `","`.
- I3 — fixed (7e51a50934c25a9e6252603d6106c0bdb7ba865a): `GitFetchOutcome.failed_ref_names` / `GitFetchResult.failed_ref_names` (Rust, FFI, Dart), witnessed by `git_fetch_parity::a_ref_the_import_cannot_read_is_reported`.
- I4 — fixed (7e51a50934c25a9e6252603d6106c0bdb7ba865a): `remote_changes` filters with `remotes::remote_fetch_refs` (+ `expand_fetch_refspecs`), witnessed by the poll rows in `git_fetch_parity.rs`.
- I5 — rejected (no longer applies): Story 9.26 already ported it — `config::git_import_options` builds `remote_auto_track_bookmarks` from `remotes.<name>.auto-track-bookmarks` and every import site (fetch, `git_import`, clone, convert, the pre-verb import) reads it; pinned by `tests/it/remotes_write.rs::git_fetch_honours_remote_auto_track_bookmarks` via `list_bookmarks`.

**Files changed (main):**
- `crates/zanshin-jj/src/remotes.rs` — the fetch port, args/outcome types, shared per-remote ref filter.
- `crates/zanshin-jj/src/push.rs` — default-remote resolution parameterized for push and fetch.
- `crates/zanshin-jj/src/config.rs` — `git.fetch` reader, `remote_fetch_expression`.
- `crates/zanshin-jj/src/remote_changes.rs` — poll filter.
- `crates/zanshin-jj/src/{repo,warning,git,mutate,lib}.rs` — facade, warning kinds, shared projection, docs, re-exports.
- `crates/zanshin-jj/tests/it/git_fetch_parity.rs` (new) + caller updates in other `tests/it/*`.
- `schemas/envelope.fbs` + regenerated Rust/Dart/C/ffigen outputs.
- `crates/zanshin-ffi/src/{repo,remotes,envelope}.rs` + `tests/it/*` — request-buffer fetch, fetch-remotes symbol, warning codes.
- `packages/zanshin_core/lib/src/ffi/fetch.dart` (new), `worker/{commands,handle,isolate}.dart`, `ffi/{mutate,remotes,warning}.dart`, exports + tests.
- `crates/zanshin-parity/tests/oracle/{git_scenarios,main,scenarios}.rs` — nine fetch scenarios.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`.

**Review findings:** 36 rows (high 0, medium 7, low 21, false 8). Patched: 4 medium entries (Dart request wire-shape test; `-t`/tracked-tag rows; `--tracked` + malformed `remotes.*` row; poll `fetch-tags` + refusal rows) and 5 low entries (ignored-refspec warning order, poll `expand_fetch_refspecs` refusal, Dart doc error lists, reserved-name test assertions, comment wrapping). Deferred: none. Rejected: token not attached on a wrong-kind buffer (push-consistent, unreachable from the Dart adapter); Dart NUL guard before the token is attached (pre-existing); native-backend error order (rare, push-consistent); `Patterns{[],[]}`/`Named([])` (spec semantics); cbindgen `VT_*` dedup (no consumer); hint lost on failure (cosmetic, new surface); no multi-remote cancel test (final checkpoint bounds it); redundant config reads (no effect); `git_fetch_remotes` snapshots (push precedent); and the eight intent-alignment divergences, each refuted in the triage log.

**Follow-up review recommended: true** — four medium entries were patched on this first pass (patched counts: high 0, medium 4, low 5). Named unverified risk: the ignored-refspec warning-order fix in `remotes.rs::git_fetch` has no witness, and the new rare error branches (refspec-expansion failure in the fetch, unreadable git remote config, a matched remote vanishing before its fetch) are untested — the coverage ratchet (not run under the gate rule) may flag them at the loop's final gate.

**Residual risks:** the coverage ratchet has not measured the new lines (gate rule); the Dart happy-path fetch is witnessed only in Rust/FFI (Dart VM reaps the git child, pre-existing limit).


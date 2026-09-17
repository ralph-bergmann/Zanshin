---
title: 'Story 9.28: Config surface — `config list`/`get`/`path`/`set`/`unset`/`edit` for user, repo and workspace scope'
type: 'feature'
created: '2026-09-17'
status: 'draft'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Zanshin reads a handful of named config values and rewrites the repo-level file privately for two remote verbs and the `trunk()` alias, but it has no general config surface. A user cannot see where a value comes from, cannot set `user.name`/`user.email` (Story 9.27's `identity_missing` prompt has no target), cannot change `revsets.log` (Story 9.25) or `snapshot.auto-track` without leaving the app. SourceTree-style repository and global settings need exactly the verbs `jj config` offers, at the CLI's scopes, with the CLI's file-selection and refusal rules — so that a value set in Zanshin is the value the CLI reads next, and vice versa.

**Approach:** Port the `jj config` group @ v0.44.0 (`cli/src/commands/config/{list,get,path,set,unset,edit}.rs`) as typed reads and writes over the effective stack Story 9.27 opens the repo with, for all three CLI scopes (`--user`, `--repo`, `--workspace`). `edit` becomes a validated raw-file round trip because the GUI replaces `$EDITOR`. One `ConfigFile` writer family serves the new verbs and the existing private writers.

## Boundaries & Constraints

**Always:**
- **`list`**: port `resolved_config_values` (`cli/src/config.rs:148` ff.) → rows `{ name (dotted), value (TOML text, whitespace-trimmed), source (Default | System | EnvBase | User | Repo | Workspace | EnvOverrides), path?, overridden }`; filters exactly as `cmd_config_list`: optional name prefix, scope (keep `source == scope`), `include_defaults` (only without a scope), `include_overridden`. An empty result is a result, not an error — the CLI's "No config to list." / "No matching config key" are stderr notes.
- **`get NAME`**: `settings.get_value(name)`; a string comes back unquoted, every other type in TOML syntax (`cmd_config_get`). `NotFound` and a table at the path → typed refusals.
- **`path SCOPE`**: user → every candidate path in the CLI's order, existing or not (`user_config_paths()`); repo / workspace → the secure path, CREATING the config directory and id file when missing — the CLI's documented side effect (`config path --repo`), which `config.rs::new_repo_config_file` already implements; add the workspace twin. No determinable path → typed refusal (`No user config path found` etc.).
- **`set SCOPE NAME VALUE [path]`**: the file is chosen as `edit_config_file` does (`config/mod.rs`): the existing layers of that scope, else a new file at the CLI's default (`config_files_for` `:693-708`; user → the first candidate of `user_config_paths()`; repo / workspace → the secure file). More than one existing file → the CLI prompts; Zanshin returns the candidates as a typed refusal and accepts an explicit `path` that must be one of them (FR-JJ-17). `VALUE` is parsed with `parse_value_or_bare_string` (`:64-79`: TOML expression, bare-string fallback). `ConfigFile::set_value` errors (`WouldOverwriteValue`, `WouldOverwriteTable`, `lib/src/config.rs:102-122`) → typed refusals, nothing written. Setting `user.name` / `user.email`: the CLI's `check_wc_author` → fact `working_copy_author { name, email }` when `@`'s author differs from the new value (the "only impacts future commits … use `jj metaedit --update-author`" warning). Save = `ConfigFile::save` — `toml_edit` round trip, comments and formatting preserved.
- **`unset SCOPE NAME [path]`**: same file selection; `delete_value`; `None` → refusal `"<name>" doesn't exist`; `WouldDeleteTable` → refusal.
- **`edit SCOPE [path]`** → two GUI halves: `config_file_read(scope, path?)` returns `{ path, text }`, creating an empty file when absent (the CLI saves before opening the editor); `config_file_write(path, text)` validates the text as a `ConfigLayer` of that source BEFORE writing and refuses with jj-lib's parse error (message + span) otherwise — the CLI's re-edit loop, with the UI holding the buffer. Writes only to a path `path SCOPE` would return.
- **After every write** the Story 9.27 reload runs, so the next verb sees the new settings; **no operation is written** — config files are not repo state (`jj config set` writes no op).
- **One writer family.** `remove_remote_from_repo_config`, `rename_remote_in_repo_config`, `set_trunk_alias` and Story 9.25's `revsets.log` writer move onto the same `ConfigFile` helpers and the same file-selection rule.
- Surface: `.fbs` request/response tables; extern fns `zanshin_config_list` / `_get` / `_path` / `_set` / `_unset` / `_file_read` / `_file_write`; `WorkerCommand`s; `docs/ffi-abi.md` + `docs/rust-error-codes.md` rows; coverage ratchet; MCP optional (Epic 7).

**Ask First:**
- Error-code granularity: separate codes (`jj.config_not_found`, `jj.config_type`, `jj.config_would_overwrite`, `jj.config_ambiguous_file`, `jj.config_parse_error`) vs. `jj.config_error` with a `kind` in `context`.
- Whether `config gc` (the group's seventh verb: prunes stale secure config dirs) rides along or gets its own line.
- Whether `set` additionally accepts a pre-typed value from the UI (string / bool / integer) besides the TOML text.

**Never:**
- No catalogue of "known" keys, no key validation, no schema: the CLI sets any key (Story 9.25's revset completion is the one deliberate exception, for revsets only).
- No `.gitconfig` reading or writing, no `$EDITOR`, no operation-log entry for config writes.
- No lowering of `coverage-baseline.txt`, no `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| list, no filters | user + repo files present | rows for User/Repo/EnvBase/EnvOverrides values; defaults excluded; overridden excluded | N/A |
| list, `include_defaults` | no scope | Default rows included | N/A |
| list, scope repo | repo file present | only `source == Repo` rows | N/A |
| list, overridden | `user.email` in user AND repo file | repo row; user row only with `include_overridden` (`overridden = true`) | N/A |
| list, prefix | `revsets` | only keys under `revsets.` | N/A |
| get string | `user.name = "A B"` | `A B` (unquoted) | N/A |
| get non-string | `snapshot.max-new-file-size = "1MiB"` vs `ui.log-synthetic-elided-nodes = true` | string unquoted; bool as `true` | N/A |
| get missing / table | `nope.key` / `revset-aliases` | refusal | not-found / type refusal |
| path user | discovery on | all candidates in CLI order | N/A |
| path repo, first time | no `config-id` yet | secure dir + id file created; path returned | N/A |
| set user, no file yet | no user config | file created at the CLI's default candidate; value written | N/A |
| set user, two files exist | `config.toml` + `conf.d/x.toml` | refusal listing both; retry with `path` succeeds | ambiguous-file refusal |
| set, bare string | `user.name`, `Ralph Bergmann` | stored as TOML string | N/A |
| set, TOML expr | `snapshot.auto-track`, `'glob:**/*.rs'` | stored as string without outer quotes; invalid TOML → refusal | parse refusal |
| set over a table | `revset-aliases`, `"x"` | refusal, file unchanged | `WouldOverwriteTable` |
| set `user.email`, `@` author differs | `@` authored by old identity | written; `working_copy_author` fact returned | N/A |
| unset present / missing | `user.name` / `nope` | removed / refusal | not-found refusal |
| unset table | `revset-aliases` | refusal | `WouldDeleteTable` |
| file_read, absent | scope workspace, no file | empty file created; `{ path, "" }` | N/A |
| file_write, invalid TOML | `[user\nname = ` | nothing written | parse refusal with span |
| file_write, valid | edited text | written; next verb reflects it | N/A |
| repo scope, native backend | `init_simple` repo | works the same (scope is jj's, not git's) | N/A |

</frozen-after-approval>

## Code Map

- `crates/zanshin-jj/src/config.rs` -- `ConfigEnv` (`:240`), `user_config_paths` (`:301`), `secure_config_path` (`:335`), `load_with` (`:398`), `existing_repo_config_file` (`:620`), `new_repo_config_file` (`:686`), `set_trunk_alias` (`:709`), `remove_remote_from_repo_config` (`:755`), `rename_remote_in_repo_config` (`:793`) -- the existing path logic and private writers to generalise
- `crates/zanshin-jj/src/repo.rs` -- public verbs; Story 9.27's settings reload hook
- `crates/zanshin-ffi/src/` -- new `config.rs` wrapper module; `envelope.fbs` tables; `envelope_generated.rs`, `include/zanshin_ffi.h`
- `packages/zanshin_core` -- `WorkerCommand`s + cdylib witnesses
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`
- `crates/zanshin-jj/tests/config_user_layer.rs`, `tests/clone_config.rs` -- the `JJ_CONFIG` single-binary pattern for user-scope tests
- `../jj` @ v0.44.0 -- `cli/src/commands/config/{mod,list,get,path,set,unset,edit}.rs`; `cli/src/config.rs:64-79` (`parse_value_or_bare_string`), `:109-123` (`AnnotatedValue`), `:148-200` (`resolved_config_values`), `:472-579` (`ConfigEnv` paths and files), `:693-708` (`config_files_for`); `lib/src/config.rs:102-122`, `:282-300`, `:425-480`, `:552-634`

## Tasks & Acceptance

**Execution:**
- [ ] `crates/zanshin-jj/src/config.rs` -- `config_files_for`-style selection per scope (existing layers → new default file), workspace twin of `new_repo_config_file`, `resolved_config_values` port, `parse_value_or_bare_string` port -- the shared machinery
- [ ] `crates/zanshin-jj/src/config.rs` -- move the three private writers + 9.25's onto the shared `ConfigFile` helpers -- one writer family
- [ ] `crates/zanshin-jj/src/repo.rs`, `lib.rs` -- `config_list` / `config_get` / `config_path` / `config_set` / `config_unset` / `config_file_read` / `config_file_write`, typed results and refusals; reload after writes -- public surface
- [ ] `schemas/envelope.fbs` + `cargo make codegen` -- request/response tables, `ConfigSource` enum -- wire contract
- [ ] `crates/zanshin-ffi/src/config.rs` -- seven wrappers -- FFI
- [ ] `packages/zanshin_core` -- `WorkerCommand`s + witnesses -- bridge
- [ ] `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows, new codes -- record
- [ ] `crates/zanshin-jj/tests/` -- a witness per matrix row; user-scope rows in the single-binary `JJ_CONFIG` pattern; a CLI round-trip witness (value set by Zanshin is read back by `config::load`, value written by hand in the file is listed with the right source) -- gate
- [ ] `coverage-baseline.txt` -- commit the auto-raised baseline -- ratchet

**Acceptance Criteria:**
- Given a value set through Zanshin at any scope, when the same key is read through `jj config get`/`list` on the same repo, then value, file and source match; and the reverse for a value set through the CLI.
- Given two existing user config files, when `set` is called without `path`, then nothing is written and the refusal names both files; with one of them as `path`, the write lands there only.
- Given `user.email` is set while `@` was authored by another identity, then the write succeeds and the result carries the working-copy author fact.
- Given invalid TOML text, when `config_file_write` is called, then the file is unchanged and the refusal carries jj-lib's parse error and span.
- Given every write, then `jj op log` is unchanged and the next Zanshin verb runs on the new settings.
- Given `cargo make test`, then it is green including the coverage ratchet.

## Design Notes

- `resolved_config_values` is CLI code, not jj-lib: it walks `StackedConfig::layers()` in reverse and marks shadowing by upper layers. Port it verbatim; it is the only non-trivial algorithm in the story.
- The "which user file" question is the CLI's `pick_one` prompt. A GUI cannot prompt from the backend, so the refusal carries the candidates and the UI re-issues the call with `path` — the same shape as Story 9.24's "offer the real fetch" pattern.
- Write path for secure scopes already exists (`new_repo_config_file` / `set_trunk_alias` from follow-up K); this story generalises rather than re-implements it.

## Verification

**Commands:**
- `cargo make test` -- expected: green, coverage ≥ baseline
- `cargo make codegen` then `git status` -- expected: generated outputs committed, tree clean

**Manual checks (if no CLI):**
- Set `user.name` at user scope through Zanshin, run `jj config list user` in a terminal: same value, same file path; edit the file by hand, re-list in Zanshin: the new value with `source = User` and the path.

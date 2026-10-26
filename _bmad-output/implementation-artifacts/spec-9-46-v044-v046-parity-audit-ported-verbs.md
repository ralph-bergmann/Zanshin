---
title: 'Story 9.46 — v0.44 → v0.46 parity audit of the already-ported verbs'
type: 'chore'
created: '2026-10-26'
status: 'done'
baseline_revision: '27514177fbf32c13c4784c337c592c7fdaca367c'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      On a non-Git (native) backend `list_remotes` returns an empty list, where `jj git remote list` refuses (`git::get_git_repo(..)?`).
    evidence: |-
      `cli/src/commands/git/remote/list.rs:37` @ v0.46.0 (the same line at v0.44.0) propagates `UnexpectedGitBackendError`; `crates/zanshin-jj/src/remotes.rs` `list_remotes` maps it to `Ok(vec![])` via `get_all_remote_names(store).unwrap_or_default()`, as FR-JJ-9's native-backend AC (Story 3.4b) requires. Pre-existing at both tags; refusing needs a new `RemoteError` variant (public surface) mapped to `jj.not_a_git_repo`, and the FR-JJ-9 AC reworded.
    location: >-
      crates/zanshin-jj/src/remotes.rs list_remotes
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-a-prefix-gitconfig-root-native, commit b46a030): `RemoteError::NotAGitRepo` → `jj.not_a_git_repo`; FR-JJ-9 and the Story 2.9 ACs reworded.
---

<intent-contract>

## Intent

**Problem:** The pin moved to jj v0.46.0, but the bump only covered what the compiler and the gate surfaced. Nobody has checked the CLI hunks between the tags behind verbs Zanshin already ships, and about 130 source comments still cite the CLI `@ v0.44.0` (deferred-work I1, I2). I3 asks to replace the in-verb `load_at_head` calls with `snapshot::load_head`.

**Approach:** Classify every v0.44.0 → v0.46.0 hunk of the CLI sources behind shipped verbs, plus the shared helpers they call. Port the divergences found: both are in `jj git remote list`, are small, and the CLI defines the answer. Re-point every `@ v0.44.0` citation to verified v0.46.0 lines. Record the per-verb result table here (scope item 4).

## Boundaries & Constraints

**Always:**
- Match the CLI's observable behavior at v0.46.0 (`git -C ../jj show v0.46.0:<path>`).
- Use null for absence.
- Edit the `.fbs` in place and regenerate with `cargo make codegen`; never hand-edit generated files.
- Every citation number is verified against the v0.46.0 file (the same code, not just the same number).
- Comments that are historical on purpose stay, for example `tests/it/graph.rs:867`'s `v0.42.0 → v0.44.0` diff argument.

**Never:**
- Re-audit what is out of scope per epics.md 9.46:
  - `undo`, `workspace list`/`root`, the `config/mod.rs` file targets, the worktree warning, the bump's own ports;
  - 9.42 `at_operation`, 9.40;
  - unported verbs, new verbs 9.43–9.45.
- Run the full gate.
- Change anything in behavior beyond the two remote-list ports.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Push-only remote | `[remote "p"] pushurl = <u>`, no `url` | listed: `name "p"`, `url` null, `push_url` `<u>` (CLI: `p <no URL> (push: <u>)`) | — |
| Fetch == push | `url = <u>` | `url` `<u>`, `push_url` null (unchanged) | — |
| Remote fails to load | a remote section gix cannot load (e.g. an invalid `fetch` refspec) | refusal, nothing listed (CLI `try_find_active_remote(..)?` → `user_error` "Unexpected Git error when managing remotes") | `RemoteError::Backend(flatten_chain)` → `jj.jj_lib_error`, chain in `context`, the same mapping as `map_remote_mgmt_err`'s `InternalGitError` |
| Empty section | `[remote "e"]` with no URLs | skipped (unchanged) | — |

</intent-contract>

## Code Map

**The audit (result table, scope items 1 and 4).** Classes:
- **(a)** terminal UX, refactor or CLI-internal only;
- **(b)** observable change, already matched;
- **(c)** divergence.

| CLI source (v0.44.0 → v0.46.0) | Hunks / result | Zanshin |
|---|---|---|
| `describe.rs`, `description_util.rs` | (a): editor `$path`/`$line`, bulk-edit validation moved with byte-identical texts. Trailer/combination fns unchanged. **no change** | `mutate.rs` describe, `op_support.rs:361-476`, `template.rs` |
| `restore.rs`, `absorb.rs`, `interdiff.rs` | (b) unmatched paths `.await?` (error, not panic), `rebase_or_reparent_descendants`. **no change** | `warning.rs:752-767`, `mutate.rs:1939-1943`, `commit_views.rs:612-618` |
| `status.rs`, `show.rs`, `evolog.rs` | (a) help text, `has_conflict` → `!is_resolved` (same predicate). **no change** | `status.rs`, `commit_views.rs` |
| `log.rs` | prioritize ∩ `within_visibility` (b, 9.42). The rest (a). **no change** | `graph.rs:256,271` |
| `file/{show,list,annotate,search,track,untrack,chmod}.rs` | (a) imports/docs; (b) async unmatched paths; (b) untrack's `update_intent_to_add(workspace_root)`. **no change** | `file.rs`, `wc_ops.rs:514-521` |
| `bookmark/{list,mod,move,advance,track}.rs` | `added_ids` → `present_adds` and `has_conflict` → `!is_resolved` (same semantics, jj-core `merge.rs:321,654-661`); `new_string_node` (same node). **no change** | `bookmark_ops.rs`, `bookmarks.rs` |
| `git/init.rs` | worktree refusal removed / warning added (b, out of scope); fallible `is_colocated_git_workspace`; `import_head_commit` (b). **no change** | `convert.rs:644-710` |
| `git/clone.rs`, `git/import.rs`, `git/remote/add.rs` | doc anchor (a); `import_head` dropped (b, out of scope); item type (a). **no change** | `git.rs` |
| `git/remote/list.rs` | non-UTF-8 skip (b); `try_find_active_remote` (b for the empty filter). **(c) a remote that fails to load is skipped, the CLI refuses** (both tags). **(c) a push-only remote is missing, the CLI lists `<no URL> (push: …)`** (both tags). **ported (this story)** | `remotes.rs:97-146` |
| `operation/{log,show,diff,mod}.rs` | help text, a resolve refactor, renames (a); `git_heads` (b, out of scope). **no change** | `op_log.rs:353` |
| `config/{set,unset,edit,list,mod}.rs` | `target` (b, out of scope); `get_wc_commit` skip-on-failure (a). **no change** | `config_cmd.rs` |
| `util/snapshot.rs` | doc examples (a). **no change** | `snapshot.rs` |
| `cli_util.rs` (+289) | 23 hunks. Stale recovery, per-workspace HEAD, `prepare_working_copy_mutation`: (a)/(b, out of scope). `excludesFile` home_dir, `UserSettings::from_config_and_home_dir`, async unmatched paths, `try_reset_git_head`/`update_intent_to_add` params: (b). Alias `enabled = false` / alias warnings: (a), no argv in Zanshin. **no change** | `snapshot.rs`, `stale.rs`, `wc_ops.rs:253-266`, `config.rs:1233`, `mutate.rs` |
| `git_util.rs` | fallible `is_colocated_git_workspace` (b); `unlink_git_worktree` warning (b). **no change** | `wc_ops.rs:361-370`, `workspace_ops.rs:95-115` |
| shared `config.rs` (+273) | migration `fix.tools.*.line-range-arg` (b), `interpolate_variables` OsString (b), `resolve_file_to_edit` (b, out of scope). **no change** | `config.rs:1045-1110`, `fix.rs:155-209` |
| `command_error.rs` | `ConvergeError` (a, verb not ported); `GitCreateWorktreeError` → `user_error` (b). **no change** | `mutate.rs:400-405` |
| `revset_util.rs`, `commit_ref_list.rs`, hand-ported `commit_templater.rs` | `resolve_revset`/`ResolvedRevset` (b, 9.42), `RevsetEvaluationSizeError` (a). The squash `--revision` multi-hint is unreachable (Zanshin takes a `ChangeId`; `resolve_commit` never sees a multi-commit revset). Renames (a); `WorkspaceRef.root` unchecked (b). **no change** | `revset.rs`, `push.rs:1009-1024`, `bookmarks.rs`, `workspace.rs:154-158` |
| `diff_util.rs` (+436) | materialize options built once (a), description-diff header, color-words/git source-symbol headers (a: Zanshin renders no text diff yet); `diff_status_inner` unchanged. **no change** | `commit_views.rs:351-388` |
| unchanged at CLI level | `abandon`, `new`, `edit`, `git fetch`, `git remote remove/rename/set-url`, `git/{mod,export}.rs`, `bookmark/{create,delete}.rs`, `config/gc.rs`: only the citation tag changes | — |

**Port anchors:**
- `crates/zanshin-jj/src/remotes.rs:35-146`: `Remote`, `remote_urls`, `list_remotes`. Use `jj_lib::git::try_find_active_remote(&git_repo, RemoteName::new(name))` (jj-lib 0.46 `git.rs:2583`); `crate::mutate::flatten_chain` (`mutate.rs:1574`).
- `crates/zanshin-ffi/src/remotes.rs:46-70`: `remotes_to_envelope`.
- `schemas/envelope.fbs:1809-1813`: `table Remote`.
- `packages/zanshin_core/lib/src/ffi/remotes.dart:56-78,172-176`: Dart `Remote`, `_mapRemote` (`url: r.url ?? ''` → `r.url`).
- `docs/ffi-abi.md`: the Remote section.

Callers of `Remote.url` to adapt:
- `crates/zanshin-jj/tests/it/{remotes,git_remotes,api_stability}.rs`
- `crates/zanshin-ffi/tests/it/git_ffi.rs`
- `crates/zanshin-jj/src/repo.rs` (docs)
- `packages/zanshin_core/test/ffi/remotes_test.dart`
- `packages/zanshin_core/test/worker/{git,push}_test.dart`

The app (`app/lib`) and `zanshin-mcp` have no consumer.

**I3 evidence:** commit `2b7076d7f28743f95f5020c87a91145cf260dd96` moved every production head load onto `snapshot::reload_head` with reconcile witnesses. `snapshot.rs:1150-1180` `no_production_code_calls_load_at_head` scans `src/` and stays green. The remaining `.load_at_head()` hits are inside `#[cfg(test)]`.

**Citation re-pointing (scope item 3, I2).** These are verified v0.44 → v0.46 mappings. Files unchanged between the tags only get the tag bumped: `git/{mod,export,fetch,import(:46-50)}.rs`, `remote/add.rs:75-119`, `bookmark/{create,delete}.rs`, `abandon.rs`, `config/gc.rs`, `commit_ref_list.rs:89-91`, `tests/common/test_environment.rs`, `debug/index_changed_paths.rs`, jj-lib `op_walk.rs:79-81`, `clone.rs:384-389`, `test_bookmark_command.rs:122-141`, `test_file_track_untrack_commands.rs`, and the file-level citations of `file/*.rs`, `show/evolog/interdiff.rs`, `absorb.rs`, `export.rs`.

Renumbered sites (`v0.44 → v0.46`), `zanshin-jj/src` unless a path says otherwise.

`cli_util.rs`:
- `config.rs:1262` 4543-4627 → 4663-4750
- `config.rs:1295` 372-388 → 373-389
- `config.rs:2075` 1618-1623 → 1649-1654
- `revset.rs:393` 3415-3423 → 3508-3516
- `revset.rs:435` 1851 → 1884
- `bookmark_ops.rs:20` 3385-3393 → 3478-3486
- `convert.rs:465` 1331-1342 → 1359-1370
- `wc_ops.rs:199` 1604-1611 → 1635-1642
- `wc_ops.rs:236` 1660-1667 → 1692-1699
- `wc_ops.rs:274` 1642-1685 → 1673-1717
- `wc_ops.rs:322` 1613-1631 → 1644-1662
- `wc_ops.rs:461` 3323-3347 → 3382-3413
- `git.rs:18` 2790-2806 → 2849-2865
- `mutate.rs:366` 1486-1490 → 1513-1515
- `mutate.rs:372` 1501-1505 → 1523-1527
- `mutate.rs:814` and `snapshot.rs:116` 2300-2417 → 2347-2472
- `mutate.rs:1698` 1482-1507 → 1511-1529
- `snapshot.rs:272` 981-996 → 1011-1026
- `snapshot.rs:560` 1298-1326 → 1326-1354
- `snapshot.rs:815` 1428-1460 → 1457-1489
- `op_support.rs:869` 2883-2894 → 2942-2953; the same block's 2896 → 2955, 2286-2298 → 2333-2345, 2099 → 2132
- `op_support.rs` header: `check_rewritable` 2002 → 2035, `check_rewritable_expr` 2011 → 2044, `resolve_immutable_expression` 1118 → 1146, `DiffSelector` 3494 → 3587, `start_repo_transaction` 2883 → 2942, `rebase_mutable_descendants` 2927 → 2986
- `warning.rs` untagged: 2387-2415 → 2442-2470, 2123-2127 → 2156-2160, 2338-2342 → 2385-2389, 2206-2210 → 2253-2257, 2688-2691 → 2747-2750, 3183-3203 → 3242-3262, 3207-3228 → 3266-3287, 3230-3249 → 3289-3308, 3303-3309 → 3362-3368, 3329-3333 → 3388-3399, 3335-3344 → 3401-3410, 934-966 → 959-991

`git_util.rs`:
- `schemas/envelope.fbs:2455` 418-425 → 417-424
- `config.rs:1542` `load_git_import_options`: tag only

`util/snapshot.rs`: `repo.rs:624`, `snapshot.rs:80`: tag only.

Shared `config.rs`:
- `config.rs:6` 713-730 → 806-823
- `:29` 447-469 / 585-593 / 653-665 → 455-477 / 593-601 / 661-673
- `:103` 736-819 → 829-912
- `:371` 366-419 → 370-423
- `:390` 389-396 → 393-400
- `:399` 386 → 390
- `:511` 334-345 → 338-349
- `:531` 289-332 → 293-336
- `:594` 262-273 → 266-277
- `:635` 736-765 → 829-858
- `:654` 789-819 → 882-912
- `:779` 545-549 / 616-625 → 553-557 / 624-633
- `:799` and `repo.rs:4647` 447-469 → 455-477
- `:844` 411-417 → 415-421
- `:880` 713-730 → 806-823
- `:997` 669-679 → 746-756
- `:2241` 573-579 → 581-587
- `config_cmd.rs:606` 64-70 → 66-72
- `config_cmd.rs:641` 148-204 → 152-208
- `config_cmd.rs:1316` 1111-1145 → 1291-1325
- `revset.rs:980` 1009-1032 → 1184-1207
- `fix.rs:196` 1226-1242 → 1224-1240

`command_error.rs` (`warning.rs`):
- `:71` 1105-1119 → 1136-1150
- `:414` 1037-1053 → 1068-1084
- `:435` 1112-1114 → 1143-1145

`revset_util.rs`:
- `revset.rs:410` and `warning.rs:69` 154-180 → 168-194
- `config.rs:1556` 378-391,457-470 → 425-438,504-517
- `revset.rs:1047` 193-203 → 206-218

`commit_templater.rs`:
- `graph.rs:125` 2203-2216 → 2280-2293
- `warning.rs:73` 2208-2215 → 2285-2292
- `commit_meta.rs:32` 1543 → 1625
- `commit_meta.rs:324` 2013-2053 → 2063-2084 + `collect_distinct_refs` 2097-2103
- `file.rs:48` and `envelope.fbs:2351` `describe_file_type`: tag only

Commands:
- `show.rs` `cmd_show` 72-114 → 73-115
- `commit_views.rs:470` 109 → 110
- `interdiff.rs` 83-125 → 83-126
- `commit_views.rs:571` 99-110 → 99-111
- `commit_views.rs:632` `diff_util.rs:650` → 628
- `diff_util.rs` (`commit_views.rs:12,350`): tag only
- `revset.rs:299` `log.rs:341` → 360
- `commit_content.rs:6` `log.rs:275` → 298
- `config.rs:1490` `log.rs:148/197` → 144/202
- `restore.rs` (`mutate.rs:1869`, `repo.rs:3327`) 119-137 → 120-138
- `mutate.rs:1882` 181 → 183
- `mutate.rs:1890` 174-179 → 175-181
- `mutate.rs:1826` 138 → 139
- `mutate.rs:1797` 119-185 → 121-183
- `absorb.rs` (`repo.rs:3456`) 64 → 65
- `mutate.rs:2016` and `repo.rs:3418` 160-162 → 161-163
- `repo.rs:3418` 154-158 → 155-159
- `mutate.rs:2049` 102-107 → 102-108 and 155-158 → 156-159
- `warning.rs:122` 155-158 → 156-159
- `describe.rs` (`mutate.rs:1072`) 151-163 → 151-165
- `untrack.rs`: `wc_ops.rs:468` 62-111 → 63-119; `mutate.rs:377` 84-104 → 85-105
- `file/show.rs` (`warning.rs:124,126`) 164-170 / 191-197 → 163-169 / 190-196
- `git/init.rs`: `convert.rs:40` 244-272 → 249-282; `:404` 285-320 → 295-330; `:514` 324-364 → 334-374; `:610` External branch → 212-221 + 249-282; `:861` 252-253 → 257-259
- `config/set.rs`: `config_cmd.rs:947` 120-127 → 110-117; `:992` 94-113 → 84-103
- `git/remote/list.rs` (`remotes.rs:54,92`) 49-55 → 45-59, `get_url` 64-69
- `git/import.rs` (`git.rs:303`) 60 → 57
- `workspace/list.rs` (`view.rs:158`) 74: tag only
- `workspace/root.rs` (`rust-error-codes.md:78`) 73-76 → 69-72

Docs:
- `ffi-abi.md:1429` 334-345 → 338-349
- `:1434` 789-819 → 882-912
- `:1511` 1000-1007 → 1175-1182
- `:1515` 1009-1032 → 1184-1207
- `rust-error-codes.md:58`: 1000-1007 → 1175-1182, 1009-1032 → 1184-1207, cu 962/1074 → 987/1102, cu 1604-1631 → 1635-1662
- `:48` cu 1486-1490 → 1513-1515
- `:67` cu 2011 → 2044
- `:85` cu 1497-1507 → 1518-1529
- `:138` revset_util 172-176 → 186-190
- `:140` commit_templater 2210 → 2287
- the `cu:` numbers of the warning table under `:121`, verified one by one

Tests (`zanshin-jj/tests/it`):
- `commit_views.rs:510` jj-lib `revset.rs:2827` → 2940
- `warnings.rs:246` config 1018-1024 → 1193-1199
- `warnings.rs:606` cu 939 / 2068-2070 → 964 / 2101-2103
- `snapshot_colocated.rs:12` 1298-1326 → 1326-1354
- `:404` 2065-2070 → 2098-2103
- `:479` 2065-2067 → 2098-2100
- `:506` 938 → 963
- `:541` 477 → 478
- `:581` 1434-1437 → 1463-1466
- `file_track_home_git_ignore.rs:4` 1660-1667 → 1692-1699
- `snapshot_precondition.rs:511` 2065-2079 → 2098-2112
- `config_identity.rs:97` 2397-2401 → 2452-2456
- `config_identity.rs:530` 4543-4627 → 4663-4750
- `view.rs:97`, `creation_warnings.rs:4`, `file_track_untrack.rs:5,1015`, `warnings.rs:7`, `mutate.rs:461`, `remotes_write.rs:492`, `bookmark_ops.rs:207`, `clone_config.rs:23`: tag only

Stale claims to correct in the same pass:
- `git.rs:51-60` "Deliberate divergences": the duplicate-URL warning IS ported (`git.rs:500-536`, `jj.remote_url_duplicate`); its hint (`add.rs:111-115`) is dropped. The heading becomes "at v0.46.0".
- `warning.rs:751` "the CLI unwraps there": at v0.46 the CLI propagates the error too.
- `op_support.rs:890` "a second caller": at v0.46 there are other callers, `cli_util.rs:691` included.
- module headers "parity at tag v0.44.0" (`commit_views.rs:12`, `file.rs:12`, `op_support.rs:6`, `config.rs:6`, `config_cmd.rs:3`, `warning.rs:29`, `ffi-abi.md:156,1229,1423`, `rust-error-codes.md:100,121`) → v0.46.0. This story audited them.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/remotes.rs` -- `Remote.url: Option<String>` (null = no fetch URL); `remote_urls` → `Result<Option<..>, RemoteError>` over `git::try_find_active_remote` (Err → `Backend(flatten_chain)`, `None` → skip); push differs-test against an absent fetch URL; docs and citations at v0.46.0; inline tests for both I/O rows -- the two ported divergences.
- `crates/zanshin-jj/src/repo.rs`, `tests/it/{remotes,git_remotes,api_stability}.rs`, `crates/zanshin-ffi/src/remotes.rs`, `crates/zanshin-ffi/tests/it/git_ffi.rs` -- adapt to `Option<String>`; the FFI writes `url` only when present; an integration witness for a push-only remote and a load failure through `Repo::list_remotes` / `zanshin_remotes` -- surface-anchored.
- `schemas/envelope.fbs` (+ `cargo make codegen`, commit outputs) -- `Remote.url` comment: null when only a push URL exists -- wire doc.
- `packages/zanshin_core/lib/src/ffi/remotes.dart` and its tests -- `String? url`, mapped from `r.url` without `?? ''`; a decode test for an absent url -- Dart bridge.
- `docs/ffi-abi.md` -- the Remote/`zanshin_remotes` contract (absent url, load-failure refusal).
- Every file in the Code Map's citation list -- re-point the citations and correct the stale claims -- scope item 3 / I2.

**Acceptance Criteria:**
- Given a repo with a push-only remote, when `zanshin_remotes` (and Dart `RepoHandle.remotes`) is called, then it lists that remote with `url` absent/null and `push_url` set.
- Given a remote gix fails to load, when the list is read, then it refuses `jj.jj_lib_error` with jj-lib's chain in `context` and lists nothing.
- Given the sources after this story, when grepping `crates/*/src crates/*/tests schemas docs` for `@ v0.44.0`, then only deliberately historical references remain (each named in the Auto Run Result).
- Given `snapshot.rs`'s `no_production_code_calls_load_at_head`, when it runs, then it passes (I3).

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 18 findings — high 0, medium 0, low 13, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` Blind: untagged `cli_util.rs` numbers still at v0.44 in `mutate.rs` (2011, 1139, 2927, 2324-2329, 2387-2415, 2792-2795), `git.rs:294`, `config.rs:2092,2770`, in files whose headers now claim v0.46 — re-pointed after verifying each at v0.46.0.
  - `[low]` `[patch]` Blind: `bookmark_ops.rs:125,128` still give 3385-3393 / 3372-3381, against the header's 3478-3486 — re-pointed to 3478-3486 / 3465-3474.
  - `[low]` `[patch]` Blind: the `snapshot.rs` module header and `repo.rs:395-403` give cli_util 477 / 2065-2070 / 1434-1437 / 2105-2108 (v0.44), unlike `tests/it/snapshot_colocated.rs` — re-pointed to 478 / 2098-2103 / 1463-1466 / 2138-2141.
  - `[low]` `[patch]` Blind: `warning.rs` `print_invalid_utf8_paths` was only half updated (:3207-3228) — re-pointed to 3266-3287.
  - `[low]` `[patch]` Blind: `wc_ops.rs` `fileset_parse_context_for_config` still :1007-1018 — re-pointed to :1037-1048.
  - `[low]` `[patch]` Blind: "nothing is listed, as in `jj git remote list`" is inaccurate; the CLI prints the remotes sorted before the broken one, then fails — reworded at every site: refuses as the CLI does, and an error envelope carries no payload.
  - `[low]` `[defer]` Blind: on a non-Git backend the CLI refuses (`list.rs:37`), Zanshin lists nothing — pre-existing at both tags and required by FR-JJ-9's native-backend AC; the fix adds a public `RemoteError` variant. Deferred (spec `deferred`, deferred-work.md).
  - `[low]` `[patch]` Blind: `docs/rust-error-codes.md`'s `jj.jj_lib_error` row lacks the new `zanshin_remotes` emission site (the registry rule wants every emitter) — added.
  - `[low]` `[patch]` Blind: the Dart `Remote.pushUrl` doc does not cover push-only remotes (`url` null) or the round-trip caveat for a null `url` — doc extended.
  - `[low]` `[patch]` Blind: `tests/it/remotes.rs` comments still say `list_remotes()` calls `load_at_head()` — reworded to the head load (`snapshot::reload_head`).
  - `[low]` `[patch]` Blind: the `tests/it/git_remotes.rs` `remote_url` doc does not mention that `None` now also means push-only — both `None` cases spelled out.
  - `[low]` `[patch]` Blind: the load-failure witnesses check only the context prefix, not the jj-lib cause — the inline test also asserts the cause after the prefix. The rest is rejected:
    - the v0.46 CLI does not name the remote either ("Unexpected Git error when managing remotes" plus its chain);
    - the Dart surface decodes `jj.jj_lib_error` generically, as every other refusal.
  - `[low]` `[patch]` Edge: "nothing is listed" vs the CLI's partial stdout. Same root cause as the Blind wording finding above, grouped with it; the same rewording fixes both.
  - `[false]` `[reject]` Intent: the Auto Run Result, the per-verb table and the deferred-work markers are missing — finalize writes them; the table is in this spec's Code Map.
  - `[false]` `[reject]` Intent: the public-API change shipped without a Ralph decision — the dispatch intent says matching the CLI's observable behavior "is never a decision for Ralph", and null-for-absence is the standing convention.
  - `[false]` `[reject]` Intent: no oracle scenario for the remote list — the oracle compares repo state of mutating verbs; reads are hand-audited (epic context, "Oracle"), done here against `list.rs` @ v0.46.0.
  - `[false]` `[reject]` Intent: a remote with neither URL is untested and the CLI prints `<name> <no URL>` — false: `try_find_active_remote` (jj-lib 0.46 `git.rs:2583-2606`) returns `None` for it and the CLI `continue`s; `tests/it/remotes.rs` pins the skip with an empty `[remote "e"]`.
  - `[false]` `[reject]` Intent: I3 used `snapshot::reload_head`, not `snapshot::load_head`, and has no per-site witnesses in this diff — the CLI-style head load was renamed in `2b7076d7f28743f95f5020c87a91145cf260dd96`, which carries the reconcile witnesses (`snapshot.rs` tests, reconcile-op `workspace_name` asserted per path family) and the `no_production_code_calls_load_at_head` guard; nothing is left for this story.

## Verification

**Commands:** gate rule of this run, no full gate.
- `cargo test -p zanshin-jj --lib remotes` -- expected: pass.
- `cargo test -p zanshin-jj --test it -- remotes:: git_remotes:: api_stability::` -- expected: pass.
- `cargo test -p zanshin-jj --lib snapshot::tests::no_production_code_calls_load_at_head` -- expected: pass.
- `cargo test -p zanshin-ffi --test it -- git_ffi::` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` and `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen`, then `git status` shows only the expected generated diffs.
- `flutter test` / `dart analyze` / `dart format --set-exit-if-changed .` in `packages/zanshin_core` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (no mutating verb changed; a safety run).

**Verification notes (recorded):** the full gate was not run, per this run's gate rule.
- `cargo test -p zanshin-jj --lib remotes`: 15 passed (before and after the review patches).
- `cargo test -p zanshin-jj --lib snapshot::tests::no_production_code_calls_load_at_head`: 1 passed.
- `cargo test -p zanshin-jj --test it -- remotes:: git_remotes:: api_stability::`: 90 passed.
- `cargo test -p zanshin-ffi --test it -- git_ffi:: ffi_abi_doc_sync`: 41 passed.
- `cargo test -p zanshin-ffi --lib remotes`: 5 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`: clean. `cargo fmt --all --check`: clean. The implementer's workspace-wide `cargo check --workspace --all-targets`: clean.
- `cargo make codegen`: exit 0. Re-running it changes nothing; only comment diffs in the generated Rust/Dart, `zanshin_ffi.h` and `bindings.dart`.
- `packages/zanshin_core`:
  - `dart analyze --fatal-infos`: no issues. `dart format --set-exit-if-changed`: 0 changed.
  - `flutter test` with the gate's env (`JJ_CONFIG=""`, `XDG_CONFIG_HOME=target/test-xdg-config`, …): 1115 passed. Bare `flutter test` fails 13 real-cdylib setUpAlls with "XDG_CONFIG_HOME is not pinned — run via cargo make", the suite's own guard.
- `cargo test -p zanshin-parity --test oracle`: 491 passed (implementer's run, before the comment/test-only review patches).

## Auto Run Result

Status: done.

**Summary.**
- The v0.44.0 → v0.46.0 audit classified every hunk of the CLI sources behind shipped verbs and of the shared helpers they call. The per-verb result table is in the Code Map: every verb is "no change" except `git remote list`, "ported (e565857de6d13466ac7b00631955c4b60c93610a)".
- Ported in `jj git remote list`:
  - A push-only remote is listed with `url` null: `Remote.url` is `Option<String>` / Dart `String?`.
  - A remote gix cannot load refuses the list with `jj.jj_lib_error`.
- Every `@ v0.44.0` citation, and the untagged v0.44 numbers in the same functions, now cites verified v0.46.0 lines. Three stale claims were corrected.

**Items.**
- **I1:** fixed in e565857de6d13466ac7b00631955c4b60c93610a. The audit is done and the two divergences are ported. The pre-existing native-backend divergence is deferred: it needs public surface and a reworded FR-JJ-9 AC.
- **I2:** fixed in e565857de6d13466ac7b00631955c4b60c93610a. The only remaining `v0.44.0` text is `crates/zanshin-jj/tests/it/graph.rs:867`, the deliberately historical `v0.42.0 → v0.44.0` diff argument.
- **I3:** rejected, already done. Commit 2b7076d7f28743f95f5020c87a91145cf260dd96 moved every production head load onto `snapshot::reload_head`, with reconcile witnesses. `no_production_code_calls_load_at_head` passes.

**Files changed (e565857).**
- `crates/zanshin-jj/src/remotes.rs`: `find_remote` over `try_find_active_remote`, `url: Option`, inline witnesses.
- `crates/zanshin-ffi/src/remotes.rs`: an absent `url` on the wire, witnesses.
- `schemas/envelope.fbs` + generated: the `Remote.url` doc.
- `packages/zanshin_core/lib/src/ffi/remotes.dart`: `String? url`, `pushUrl` doc.
- Tests:
  - `crates/zanshin-jj/tests/it/{remotes,git_remotes,api_stability}.rs`
  - `crates/zanshin-ffi/tests/it/git_ffi.rs`
  - `packages/zanshin_core/test/{ffi/remotes_test,worker/git_test}.dart`
- `docs/ffi-abi.md`: the Remotes payload section.
- `docs/rust-error-codes.md`: the `jj.jj_lib_error` emitter and v0.46 citations.
- About 35 further source/test files: citation re-pointing only.

**Review.** 18 findings: 13 low, 5 false.
- 12 patched (all low, comments, docs and one test assertion), in the same commit.
- 1 deferred: the native-backend list, Low, mirrored into deferred-work.md.
- 5 rejected as false, reasons in the Review Triage Log.
- Patched by verdict: high 0, medium 0, low 12. Follow-up review recommended: false.

**Residual risks.**
- The coverage ratchet was not run (the loop runs it once at the end). The new lines in both `remotes.rs` files are hit by inline tests.
- Line numbers in older untagged citations from tags before v0.44 (e.g. some in `config.rs`) were left as they were.

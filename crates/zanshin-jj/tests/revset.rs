// SPDX-License-Identifier: MIT

use std::collections::HashSet;
use std::env;
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::LazyLock;

use jj_lib::backend::CommitId;
use jj_lib::default_backend_factories::default_working_copy_factories;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use test_helpers::{add_commit_off_root, extract_fixture, set_local_bookmark};
use zanshin_jj::{resolve_revset, Change, Repo, RevsetError};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string pins jj-lib/git off the developer's globals for reproducibility.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// Returns `(working_copy_change_id, parent_change_id)` in reverse-hex form,
/// computed directly via jj-lib — an independent oracle for AC-2.
fn wc_and_parent_change_ids(workspace_root: &Path) -> (String, String) {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let wc_id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .unwrap()
        .clone();
    let wc_commit = repo.store().get_commit(&wc_id).unwrap();
    let wc_change = wc_commit.change_id().reverse_hex();
    let parent_change = if let Some(pid) = wc_commit.parent_ids().first() {
        repo.store().get_commit(pid).unwrap().change_id().reverse_hex()
    } else {
        let root_id = repo.store().root_commit_id().clone();
        repo.store().get_commit(&root_id).unwrap().change_id().reverse_hex()
    };
    (wc_change, parent_change)
}

/// Returns the set of distinct change ids (reverse-hex) reachable from local
/// bookmark targets — an independent oracle for AC-4.
fn local_bookmark_change_ids(workspace_root: &Path) -> HashSet<String> {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let mut out = HashSet::new();
    for (_name, target) in repo.view().local_bookmarks() {
        for commit_id in target.added_ids() {
            let commit = repo.store().get_commit(commit_id).unwrap();
            out.insert(commit.change_id().reverse_hex());
        }
    }
    out
}

/// The change id (reverse-hex) of the commit whose hex commit id is `commit_hex`.
fn change_id_of(workspace_root: &Path, commit_hex: &str) -> String {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let commit_id = CommitId::try_from_hex(commit_hex).expect("valid commit hex");
    repo.store().get_commit(&commit_id).unwrap().change_id().reverse_hex()
}

// ── AC-2: `@` resolves to working-copy change id ────────────────────────────

#[test]
fn revset_on_at_returns_working_copy_change() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "@").unwrap();
    let (expected_wc, _) = wc_and_parent_change_ids(&fx.path);
    assert_eq!(result.len(), 1, "@ must resolve to exactly one change id");
    assert_eq!(
        result[0].0, expected_wc,
        "@ change id must equal working-copy change id"
    );
}

// ── AC-2: `@-` resolves to parent change id ─────────────────────────────────

#[test]
fn revset_on_at_minus_returns_parent_change() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "@-").unwrap();
    let (_, expected_parent) = wc_and_parent_change_ids(&fx.path);
    assert_eq!(result.len(), 1, "@- must resolve to exactly one change id");
    assert_eq!(result[0].0, expected_parent, "@- change id must equal parent change id");
}

// ── AC-3: `all()` on tiny includes root + fixture commits + working copy ────

#[test]
fn revset_on_all_tiny_includes_root_commits_and_wc() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "all()").unwrap();
    // 3 fixture commits + the virtual root commit + the working-copy `@` = 5.
    // AC-3 says "do not hard-pin to a single number", so allow a +/-1 band (4..=5)
    // tolerant of jj-lib counting the root differently across patch releases.
    assert!(
        (4..=5).contains(&result.len()),
        "all() on tiny-3-commits expected 4-5 (root + 3 commits + @), got {}",
        result.len()
    );
}

// ── AC-4: `bookmarks()` on medium equals oracle ──────────────────────────────

#[test]
fn revset_on_bookmarks_medium_equals_oracle() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "bookmarks()").unwrap();
    assert!(!result.is_empty(), "medium-1k-commits must have bookmarks");
    let result_set: HashSet<String> = result.iter().map(|id| id.0.clone()).collect();
    let oracle = local_bookmark_change_ids(&fx.path);
    assert_eq!(
        result_set, oracle,
        "bookmarks() change ids must match local bookmark targets"
    );
}

// ── Story 9.0a: bare pattern args are glob (=exact), not substring ───────────

/// Pins the user-visible revset-language change the jj-lib 0.42 → 0.44 bump brought in:
/// `RevsetParseContext::use_glob_by_default` is gone, so a bare/quoted pattern argument is now
/// parsed as a glob — and a glob with no metacharacter is an EXACT match, where 0.42 defaulted
/// to SUBSTRING.
///
/// The flip was invisible to the gate before this test. Other suites DO pass bare pattern
/// arguments — `description("Commit N")` in `zanshin-graph`'s `stream.rs`/`slice.rs`, this
/// crate's `graph.rs`, and `zanshin-ffi`'s `graph_ffi.rs` — but the tiny fixture's descriptions
/// are exactly `Commit {n}`, so substring and exact agree there and every one of them passes
/// under BOTH semantics. This test is the only place the two readings are made to disagree.
/// See the `// WHY:` block in `parse_revset_with` (src/revset.rs) for why the new behaviour is
/// the CLI-correct one.
#[test]
fn revset_bare_pattern_arg_is_exact_not_substring() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();

    // Two bookmark names that strictly nest: "release" is a substring of "release-candidate"
    // but not equal to it. tiny-3-commits ships no bookmarks, so these two are the whole
    // bookmark space and the assertions below can be exact sets.
    let exact_commit = add_commit_off_root(&fx.path, "9.0a: release");
    let longer_commit = add_commit_off_root(&fx.path, "9.0a: release-candidate");
    set_local_bookmark(&fx.path, "release", &[&exact_commit]);
    set_local_bookmark(&fx.path, "release-candidate", &[&longer_commit]);

    let exact_change = change_id_of(&fx.path, &exact_commit);
    let longer_change = change_id_of(&fx.path, &longer_commit);
    let repo = Repo::open(&fx.path).unwrap();

    // NEW (0.44): bare argument → glob → exact, so "release-candidate" is NOT selected.
    // Under 0.42's substring default this returned BOTH bookmarks.
    let bare: HashSet<String> = resolve_revset(&repo, "bookmarks(release)")
        .unwrap()
        .iter()
        .map(|id| id.0.clone())
        .collect();
    assert_eq!(
        bare,
        HashSet::from([exact_change.clone()]),
        "a bare pattern argument must match exactly, not as a substring"
    );

    // …and the default kind is genuinely GLOB, not merely "exact": a metacharacter is honoured.
    // This is the sharper discriminator of the two semantics — under 0.42's substring default
    // `"release*"` matched NEITHER bookmark (no name contains a literal `*`), under 0.44 it
    // matches BOTH.
    let glob: HashSet<String> = resolve_revset(&repo, r#"bookmarks("release*")"#)
        .unwrap()
        .iter()
        .map(|id| id.0.clone())
        .collect();
    assert_eq!(
        glob,
        HashSet::from([exact_change.clone(), longer_change.clone()]),
        "a bare pattern argument must honour glob metacharacters"
    );

    // The explicit kinds are untouched by the default change: `substring:` still matches both.
    let substring: HashSet<String> = resolve_revset(&repo, r#"bookmarks(substring:"release")"#)
        .unwrap()
        .iter()
        .map(|id| id.0.clone())
        .collect();
    assert_eq!(
        substring,
        HashSet::from([exact_change, longer_change]),
        "an explicit substring: kind must still match both nested bookmark names"
    );
}

// ── AC-11: `heads(all())` is non-empty ──────────────────────────────────────

#[test]
fn revset_on_heads_all_is_non_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "heads(all())").unwrap();
    assert!(!result.is_empty(), "heads(all()) must be non-empty");
}

// ── AC-11: `trunk()..@` resolves (trunk() alias present) ────────────────────

#[test]
fn revset_on_trunk_range_resolves_ok() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    // The fixture has no remote bookmarks → trunk() → root(), so trunk()..@ is valid.
    let result = resolve_revset(&repo, "trunk()..@");
    assert!(result.is_ok(), "trunk()..@ must resolve without error, got: {result:?}");
}

/// Every builtin alias must actually EXPAND, not merely be declared.
///
/// `RevsetAliasesMap::insert` does not check the definition — jj-lib documents that a bad
/// `defn` is only reported when the alias is substituted (`dsl_util.rs`: "The `defn` part
/// isn't checked"). So `build_aliases_map()` returning `Ok` proves nothing about the table;
/// a typo in any definition would first surface in the user's revset box. Naming each alias
/// here is what pins the whole v0.42.0 builtin table.
#[test]
fn every_builtin_revset_alias_expands_and_resolves() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    for alias in [
        "trunk()",
        "builtin_immutable_heads()",
        "immutable_heads()",
        "immutable()",
        "mutable()",
        "visible()",
        "hidden()",
    ] {
        let result = resolve_revset(&repo, alias);
        assert!(result.is_ok(), "builtin alias {alias} must expand, got: {result:?}");
    }
}

/// `mutable()` is `~immutable()`, so the two must partition `all()` — a semantic pin that a
/// merely-parseable definition would not survive.
#[test]
fn mutable_and_immutable_partition_all() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let ids = |expr: &str| -> HashSet<String> {
        resolve_revset(&repo, expr)
            .unwrap()
            .iter()
            .map(|id| id.0.clone())
            .collect()
    };
    let all = ids("all()");
    let immutable = ids("immutable()");
    let mutable = ids("mutable()");

    assert!(
        immutable.is_disjoint(&mutable),
        "immutable() and mutable() must not overlap"
    );
    let union: HashSet<String> = immutable.union(&mutable).cloned().collect();
    assert_eq!(union, all, "immutable() | mutable() must cover all()");
}

// ── AC-6: `none()` returns empty Vec ────────────────────────────────────────

#[test]
fn revset_on_none_returns_empty_vec() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "none()").unwrap();
    assert!(result.is_empty(), "none() must return empty Vec");
}

// ── AC-6: `~all()` also returns empty Vec ───────────────────────────────────

#[test]
fn revset_on_complement_all_returns_empty_vec() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "~all()").unwrap();
    assert!(result.is_empty(), "~all() must return empty Vec");
}

// ── AC-10: complex revset returns deduplicated Vec ───────────────────────────

#[test]
fn revset_complex_expression_returns_deduplicated() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "(trunk()..@) | (visible_heads() & ~::trunk())").unwrap();
    let ids: Vec<&str> = result.iter().map(|id| id.0.as_str()).collect();
    let unique: HashSet<&str> = ids.iter().copied().collect();
    assert_eq!(
        ids.len(),
        unique.len(),
        "complex revset result must contain no duplicate change ids"
    );
}

// ── AC-5: invalid expression → ParseError, no panic ─────────────────────────

#[test]
fn revset_bogus_function_returns_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "bogus_function()");
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "bogus_function() must return ParseError, got: {result:?}"
    );
}

// ── AC-7: non-existent bookmark → ResolutionError ───────────────────────────

#[test]
fn revset_nonexistent_branch_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "nonexistent-branch");
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "nonexistent-branch must return ResolutionError, got: {result:?}"
    );
}

// ── AC-13: malformed change-id literal → ResolutionError ────────────────────

#[test]
fn revset_malformed_change_id_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "xyz123notarealid");
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "xyz123notarealid must return ResolutionError, got: {result:?}"
    );
}

// ── AC-12: large fixture benchmark (soft target, #[ignore]) ─────────────────

#[test]
#[ignore = "soft performance target (< 200 ms); requires large-10k-commits fixture; run with --ignored --nocapture"]
fn revset_large_fixture_fully_materialized() {
    pin_env();
    let fx = extract_fixture("large-10k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let t = std::time::Instant::now();
    let result = resolve_revset(&repo, "all()").unwrap();
    let elapsed = t.elapsed();
    eprintln!(
        "[bench] all() on large-10k-commits: {} change ids in {:?}",
        result.len(),
        elapsed
    );
    assert!(!result.is_empty(), "large fixture must produce results");
}

// ── AC-10 helper: construct a genuine divergent change ──────────────────────

/// Creates a genuine divergent change in the repo at `workspace_root`: writes two
/// distinct visible commits that share one change id (via `set_change_id`), then
/// returns that change id in reverse-hex form. Divergence is the only state in which
/// `commit_change_ids()` yields the same change id twice, so this is what makes
/// `resolve_revset`'s dedup branch actually do work (AC-10).
fn make_divergent_change(workspace_root: &Path) -> String {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();

    let root_commit = repo.store().root_commit();
    let root_id = root_commit.id().clone();

    let mut tx = repo.start_transaction();
    // First commit off root; capture its randomly generated change id.
    let commit_a = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id.clone()], root_commit.tree())
            .set_description("divergent a")
            .write(),
    )
    .unwrap();
    let shared_change = commit_a.change_id().clone();
    // Second commit off root forced onto the SAME change id (different description =>
    // different commit id) => the change id now belongs to two distinct commits.
    let commit_b = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id], root_commit.tree())
            .set_change_id(shared_change)
            .set_description("divergent b")
            .write(),
    )
    .unwrap();
    assert_ne!(
        commit_a.id(),
        commit_b.id(),
        "the two commits must have distinct commit ids"
    );
    assert_eq!(
        commit_a.change_id(),
        commit_b.change_id(),
        "both commits must share one change id (divergence)"
    );
    // Make both visible heads so `all()` returns both.
    pollster::block_on(tx.repo_mut().add_head(&commit_a)).unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit_b)).unwrap();
    pollster::block_on(tx.commit("create divergent change for AC-10 dedup test")).unwrap();

    commit_a.change_id().reverse_hex()
}

/// Removes the working-copy commit, leaving the workspace with no `@`.
///
/// TEST SETUP ONLY — drives the `@`-with-no-working-copy resolution path.
fn remove_working_copy(workspace_root: &Path) {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let workspace_name = workspace.workspace_name().to_owned();

    let mut tx = repo.start_transaction();
    pollster::block_on(tx.repo_mut().remove_wc_commit(&workspace_name)).unwrap();
    // remove_wc_commit rewrites the abandoned @; jj requires descendants rebased
    // before the transaction can commit (mirrors tests/status.rs).
    pollster::block_on(tx.repo_mut().rebase_descendants()).unwrap();
    pollster::block_on(tx.commit("test: remove working-copy commit")).unwrap();
}

// ── AC-10: dedup is genuinely exercised against a real divergent change ──────

#[test]
fn revset_dedups_divergent_change_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // One change id now belongs to two distinct visible commits.
    let div_change = make_divergent_change(&fx.path);

    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "all()").unwrap();

    // The divergent change id appears exactly once — this fails (count == 2) if
    // resolve_revset's `seen` HashSet dedup were removed.
    let occurrences = result.iter().filter(|id| id.0 == div_change).count();
    assert_eq!(
        occurrences, 1,
        "divergent change id {div_change} must be deduplicated to exactly one entry"
    );
    assert!(!result.is_empty(), "all() must be non-empty");

    // The whole result stays duplicate-free.
    let ids: Vec<&str> = result.iter().map(|id| id.0.as_str()).collect();
    let unique: HashSet<&str> = ids.iter().copied().collect();
    assert_eq!(ids.len(), unique.len(), "result must contain no duplicate change ids");
}

// ── AC-7: `@` with no working-copy commit → ResolutionError ──────────────────

#[test]
fn revset_on_at_without_working_copy_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    remove_working_copy(&fx.path);

    let repo = Repo::open(&fx.path).unwrap();
    let result = resolve_revset(&repo, "@");
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "@ with no working-copy commit must return ResolutionError, got: {result:?}"
    );
}

// ── Story 4.9: the repo config layer feeds the alias map ─────────────────────

/// Writes the legacy repo-config file of an extracted fixture (`.jj/repo/config.toml`).
///
/// Extracted fixtures carry no `config-id`, so this legacy path IS the repo layer — and
/// writing it needs no environment variable, which is why the repo-layer rows carry the
/// bulk of the config coverage (`JJ_CONFIG` is process-global; see
/// `tests/config_user_layer.rs`).
fn write_repo_config(workspace_root: &Path, toml: &str) {
    std::fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).unwrap();
}

/// Hex commit id of the single commit `expr` resolves to — through the public API only.
fn commit_id_of(repo: &mut Repo, expr: &str) -> String {
    let ids = resolve_revset(repo, expr).unwrap();
    assert_eq!(ids.len(), 1, "{expr} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

/// A repo-config `[revset-aliases]` entry overrides the builtin of the same name+arity —
/// the CLI's layered-insert semantics (`cli/src/config.rs:930-981`).
#[test]
fn repo_config_override_of_trunk_replaces_the_builtin_definition() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&mut repo, "root()");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    // The fixture has no remote bookmarks, so the builtin trunk() degenerates to root().
    assert_eq!(commit_id_of(&mut repo, "trunk()"), root);

    write_repo_config(&fx.path, "[revset-aliases]\n'trunk()' = 'description(\"Commit 3\")'\n");
    assert_eq!(
        commit_id_of(&mut repo, "trunk()"),
        c3,
        "the repo layer must override the builtin trunk()"
    );
}

/// A user-defined alias that no builtin declares evaluates instead of erroring — before
/// Story 4.9 this was a `RevsetError::ParseError` (unknown function).
#[test]
fn repo_config_custom_alias_resolves_instead_of_failing_to_parse() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    assert!(
        matches!(resolve_revset(&repo, "wip()"), Err(RevsetError::ParseError { .. })),
        "an undefined alias is an unknown function"
    );

    write_repo_config(&fx.path, "[revset-aliases]\n'wip()' = 'description(\"Commit 2\")'\n");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    assert_eq!(commit_id_of(&mut repo, "wip()"), c2, "wip() must evaluate");
}

/// Config is re-read per operation — the SAME handle sees an externally edited config file
/// on its next call. Nothing is cached (the op-heads watcher does not cover config files).
#[test]
fn config_is_re_read_on_every_call_so_an_edit_needs_no_reopen() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");

    write_repo_config(&fx.path, "[revset-aliases]\n'trunk()' = 'description(\"Commit 1\")'\n");
    assert_eq!(commit_id_of(&mut repo, "trunk()"), c1);

    write_repo_config(&fx.path, "[revset-aliases]\n'trunk()' = 'description(\"Commit 2\")'\n");
    assert_eq!(
        commit_id_of(&mut repo, "trunk()"),
        c2,
        "the second call must reflect the new config without reopening the handle"
    );
}

/// A malformed config file is an ERROR, never a silent fall-back to the builtin layer —
/// and the context names the offending file.
#[test]
fn malformed_repo_config_is_an_error_naming_the_file() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "not = = toml");
    let result = resolve_revset(&repo, "all()");
    let Err(RevsetError::Config(err)) = result else {
        panic!("a malformed config must yield RevsetError::Config, got: {result:?}");
    };
    assert!(
        err.to_string().contains("config.toml"),
        "the context must name the file, got: {err}"
    );
}

/// A non-string alias value only WARNS and is skipped (CLI parity,
/// `cli/src/config.rs:964-977`); every other alias in the same table still works and the
/// call succeeds.
#[test]
fn non_string_alias_value_is_skipped_and_the_call_succeeds() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");

    write_repo_config(
        &fx.path,
        "[revset-aliases]\n'foo()' = 42\n'bar()' = 'description(\"Commit 1\")'\n",
    );

    assert!(
        matches!(resolve_revset(&repo, "foo()"), Err(RevsetError::ParseError { .. })),
        "the skipped alias stays undefined"
    );
    assert_eq!(commit_id_of(&mut repo, "bar()"), c1, "the sibling alias still loads");
    assert!(
        resolve_revset(&repo, "all()").is_ok(),
        "one bad entry must not fail the call"
    );
}

/// A `revset-aliases` key that is not a TABLE at all is a HARD ERROR, not a skipped layer.
///
/// The CLI's two failure levels differ and must not be conflated: the TABLE level returns
/// `ConfigGetError::Type` (`cli/src/config.rs:943-953`), while only the per-ENTRY level
/// warns and continues (`:964-977`). Skipping the layer here would silently fall back to
/// the builtin aliases — the exact behaviour this story exists to prevent.
#[test]
fn a_non_table_revset_aliases_key_is_a_config_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "revset-aliases = 42\n");
    let result = resolve_revset(&repo, "all()");
    let Err(RevsetError::Config(err)) = result else {
        panic!("a non-table `revset-aliases` must yield RevsetError::Config, got: {result:?}");
    };
    let reason = err.to_string();
    assert!(
        reason.contains("config.toml") && reason.contains("revset-aliases"),
        "the context must name the file and the key, got: {reason}"
    );
}

/// A bad alias DECLARATION only warns and is skipped — jj-lib's declaration parser is the
/// gate, and the CLI keeps going.
#[test]
fn bad_alias_declaration_is_skipped_and_the_call_succeeds() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");

    write_repo_config(
        &fx.path,
        "[revset-aliases]\n'not a decl' = 'root()'\n'ok_alias()' = 'description(\"Commit 1\")'\n",
    );
    assert_eq!(commit_id_of(&mut repo, "ok_alias()"), c1);
    assert!(resolve_revset(&repo, "all()").is_ok());
}

/// A table with a `definition` string key is a valid alias value (the CLI accepts both
/// shapes; the `doc` key is help text and has no effect on resolution).
#[test]
fn table_shaped_alias_with_a_definition_key_is_accepted() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");

    write_repo_config(
        &fx.path,
        "[revset-aliases]\n'wip()' = { definition = 'description(\"Commit 1\")', doc = 'work in progress' }\n",
    );
    assert_eq!(commit_id_of(&mut repo, "wip()"), c1);
}

/// jj-lib does not check an alias DEFINITION at insert time ("The `defn` part isn't
/// checked", `dsl_util.rs:594-597`), so a malformed definition surfaces only when the alias
/// is substituted — a revset that does not use it is unaffected.
#[test]
fn malformed_alias_definition_fails_only_where_the_alias_is_used() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "[revset-aliases]\n'wip()' = '('\n");
    assert!(
        resolve_revset(&repo, "all()").is_ok(),
        "a revset that does not use wip() is unaffected"
    );
    assert!(
        matches!(resolve_revset(&repo, "wip()"), Err(RevsetError::ParseError { .. })),
        "using the alias surfaces the bad definition as a parse error"
    );
}

/// A user's overload at a DIFFERENT arity adds to the builtin rather than replacing it —
/// jj-lib keys alias insertion by (name, arity) (`dsl_util.rs:614-619`).
#[test]
fn an_alias_overload_at_another_arity_leaves_the_builtin_alone() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&mut repo, "root()");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    write_repo_config(&fx.path, "[revset-aliases]\n'trunk(x)' = 'x'\n");
    assert_eq!(
        commit_id_of(&mut repo, "trunk()"),
        root,
        "the zero-arg builtin trunk() must survive a trunk(x) overload"
    );
    assert_eq!(
        commit_id_of(&mut repo, "trunk(description(\"Commit 3\"))"),
        c3,
        "the added overload must be callable"
    );
}

// ── Internal jj-lib failure → JjLibError ─────────────────────────────────────

#[test]
fn revset_on_corrupt_repo_returns_jj_lib_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // Corrupt AFTER open: resolve_revset re-resolves to head on every call (ADR-0002), so
    // removing op_heads makes load_at_head() fail → RevsetError::JjLibError (the internal
    // jj-lib-failure arm, distinct from the Parse/Resolution arms exercised above).
    let op_heads = fx.path.join(".jj").join("repo").join("op_heads");
    std::fs::remove_dir_all(&op_heads).unwrap();

    let result = resolve_revset(&repo, "all()");
    assert!(
        matches!(result, Err(RevsetError::JjLibError(_))),
        "corrupt op_heads must yield RevsetError::JjLibError, got: {result:?}"
    );
}

// ── Story 9.2: `eval_revset` — the lazy, cancellable read primitive ──────────
//
// `Repo::eval_revset` is a method generic over its visitor, so `tests/api_stability.rs`
// cannot fn-pointer-pin it (same as `Repo::walk_graph`); these fixture tests are its pin.

/// Drives the whole stream into a Vec (the stream must be exhausted → `Continue`).
fn collect_changes(repo: &mut Repo, revset: &str) -> Vec<Change> {
    let mut out = Vec::new();
    let flow = collect_changes_with(repo, revset, &mut out, usize::MAX);
    assert_eq!(flow, ControlFlow::Continue(()), "an unbroken walk must report Continue");
    out
}

/// Drives at most `max` items into `out`, breaking on the one after — the `ControlFlow` half of
/// the contract (mirrors `tests/graph.rs`'s `collect_nodes_with`).
fn collect_changes_with(repo: &mut Repo, revset: &str, out: &mut Vec<Change>, max: usize) -> ControlFlow<()> {
    repo.eval_revset(revset, |change| {
        out.push(change);
        if out.len() >= max {
            ControlFlow::Break(())
        } else {
            ControlFlow::Continue(())
        }
    })
    .unwrap()
}

/// `all()` yields one row per commit, in `Revset::stream()`'s topological order — children
/// before parents — and the row set equals `resolve_revset`'s.
#[test]
fn eval_revset_all_yields_one_row_per_commit_children_before_parents() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let changes = collect_changes(&mut repo, "all()");

    let ids: Vec<&str> = changes.iter().map(|c| c.id.0.as_str()).collect();
    let walked: HashSet<String> = ids.iter().map(|id| (*id).to_owned()).collect();
    assert_eq!(
        ids.len(),
        walked.len(),
        "no change appears twice in a non-divergent repo"
    );
    let materialized: HashSet<String> = resolve_revset(&repo, "all()")
        .unwrap()
        .iter()
        .map(|id| id.0.clone())
        .collect();
    assert_eq!(
        walked, materialized,
        "the walk must denote exactly the set `resolve_revset` materializes"
    );

    // Children before parents: every parent that is itself in the set arrives LATER.
    let position = |id: &str| ids.iter().position(|seen| *seen == id);
    for (i, change) in changes.iter().enumerate() {
        for parent in &change.parents {
            if let Some(j) = position(&parent.0) {
                assert!(
                    j > i,
                    "parent {} of {} must arrive after it (got #{j} vs #{i})",
                    parent.0,
                    change.id.0
                );
            }
        }
    }
    assert!(
        changes.iter().any(|c| c.parents.is_empty()),
        "the root change has no parents"
    );
}

/// The observable proof that the walk is per-item and the set is never materialized: breaking on
/// the first item over a 1k-commit fixture constructs exactly ONE `Change`.
#[test]
fn eval_revset_break_on_the_first_item_constructs_exactly_one_change() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let mut out = Vec::new();
    let flow = collect_changes_with(&mut repo, "all()", &mut out, 1);

    assert_eq!(flow, ControlFlow::Break(()), "an early stop must report Break");
    assert_eq!(out.len(), 1, "exactly one Change may be constructed");
    // Sanity: the fixture really is large, so "one" is not an artifact of a tiny set.
    assert!(
        resolve_revset(&repo, "all()").unwrap().len() > 100,
        "the fixture must hold far more commits than the one row we took"
    );
}

/// The ordinary GUI paging shape: take some rows, then stop. `Break` after N > 1 items stops
/// exactly there — the first-item case alone would not show that `Continue` really continues.
#[test]
fn eval_revset_break_after_several_items_stops_exactly_there() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let mut out = Vec::new();
    let flow = collect_changes_with(&mut repo, "all()", &mut out, 3);

    assert_eq!(flow, ControlFlow::Break(()), "a mid-stream stop must report Break");
    assert_eq!(out.len(), 3, "exactly the three rows taken; got {}", out.len());
    let distinct: HashSet<&str> = out.iter().map(|c| c.commit_id.0.as_str()).collect();
    assert_eq!(distinct.len(), 3, "the three rows are distinct commits");
}

/// An empty revset string is a caller pass-through like any other, so it fails at stage 1 rather
/// than being special-cased into an empty walk — the same way `Repo::walk_graph` treats it.
#[test]
fn eval_revset_empty_expression_is_a_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let mut calls = 0_usize;
    let result = repo.eval_revset("", |_| {
        calls += 1;
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "an empty revset must be a ParseError, got: {result:?}"
    );
    assert_eq!(calls, 0, "a failed parse must not walk");
}

/// An empty set never calls the visitor and still reports `Continue`.
#[test]
fn eval_revset_none_never_calls_the_visitor() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let mut calls = 0_usize;
    let flow = repo
        .eval_revset("none()", |_| {
            calls += 1;
            ControlFlow::Continue(())
        })
        .unwrap();

    assert_eq!(calls, 0, "none() must not call the visitor");
    assert_eq!(flow, ControlFlow::Continue(()), "an exhausted stream reports Continue");
}

/// Each visible commit of a divergent change is its own row, and every such row carries
/// `divergent == true` (Decision D4).
#[test]
fn eval_revset_divergent_change_yields_one_flagged_row_per_visible_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let div_change = make_divergent_change(&fx.path);

    let mut repo = Repo::open(&fx.path).unwrap();
    let changes = collect_changes(&mut repo, "all()");

    let rows: Vec<&Change> = changes.iter().filter(|c| c.id.0 == div_change).collect();
    assert_eq!(
        rows.len(),
        2,
        "both visible commits of the change get a row; got {rows:?}"
    );
    assert_ne!(
        rows[0].commit_id.0, rows[1].commit_id.0,
        "the two rows are distinct COMMITS of one change"
    );
    assert!(rows.iter().all(|c| c.divergent), "every divergent row must be flagged");
    assert!(
        changes.iter().filter(|c| c.id.0 != div_change).all(|c| !c.divergent),
        "no other row may be flagged divergent"
    );
}

/// A row carries the same metadata `Repo::get_change` reports for the same change.
///
/// What this pins is that `eval_revset` selects the right commit and routes it through the SHARED
/// `change_from_commit` constructor — not that the field derivations themselves are correct: both
/// sides run that one constructor, so a regression inside it moves both sides together. The
/// derivations are pinned independently against jj-lib oracles in `tests/change.rs`.
#[test]
fn eval_revset_row_matches_get_change_for_the_same_change() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let changes = collect_changes(&mut repo, "description(\"Commit 3\")");
    assert_eq!(changes.len(), 1, "exactly one commit is described 'Commit 3'");
    let row = &changes[0];
    let direct = repo.get_change(&row.id).unwrap();

    assert_eq!(row.commit_id.0, direct.commit_id.0);
    assert_eq!(row.description, direct.description);
    assert_eq!(row.parents.len(), direct.parents.len());
    assert_eq!(row.author.email, direct.author.email);
    assert_eq!(row.timestamps.committed_at, direct.timestamps.committed_at);
    assert_eq!(row.is_anonymous, direct.is_anonymous);
    assert_eq!(row.divergent, direct.divergent);
    assert_eq!(row.conflict, direct.conflict);
}

/// The pre-verb snapshot runs BEFORE the revset is even parsed (Story 9.26), exactly as the
/// CLI's `workspace_helper` loads the head and snapshots before `jj log -r` parses anything: with
/// `op_heads` gone, a syntax error and a well-formed expression fail alike, as the snapshot's
/// backend failure.
#[test]
fn eval_revset_on_a_broken_repo_fails_in_the_pre_verb_snapshot_before_parsing() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    std::fs::remove_dir_all(fx.path.join(".jj").join("repo").join("op_heads")).unwrap();

    for revset in ["bogus_function()", "all()"] {
        let result = repo.eval_revset(revset, |_| ControlFlow::Continue(()));
        assert!(
            matches!(
                result,
                Err(RevsetError::Precondition(zanshin_jj::PreconditionError::Backend(_)))
            ),
            "{revset}: the snapshot's failure must win, got: {result:?}"
        );
    }
}

/// Stage 2 (symbol resolution) is distinguishable from the other two fault classes.
#[test]
fn eval_revset_nonexistent_bookmark_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let mut calls = 0_usize;
    let result = repo.eval_revset("nonexistent-bookmark", |_| {
        calls += 1;
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "an unresolvable symbol must yield ResolutionError, got: {result:?}"
    );
    assert_eq!(calls, 0, "a failed resolution must not walk");
}

/// A malformed repo config is an ERROR, never a silent fall-back to the builtin aliases.
#[test]
fn eval_revset_malformed_repo_config_is_a_config_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    write_repo_config(&fx.path, "not = = toml");
    let result = repo.eval_revset("all()", |_| ControlFlow::Continue(()));
    // The pre-verb snapshot reads the stack first (Story 9.26), so it is the one that refuses.
    let Err(RevsetError::Precondition(err @ zanshin_jj::PreconditionError::Config { .. })) = result else {
        panic!("a malformed config must yield a config error, got: {result:?}");
    };
    assert!(
        err.to_string().contains("config.toml"),
        "the context must name the file, got: {err}"
    );
}

/// The repo's EFFECTIVE config decides the denoted set — a `revset-aliases."trunk()"` override
/// moves the walk, proving aliases are read from config rather than from Rust constants.
#[test]
fn eval_revset_honours_a_repo_config_alias_override() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&mut repo, "root()");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    // The fixture has no remote bookmarks, so the builtin trunk() degenerates to root().
    let before = collect_changes(&mut repo, "trunk()");
    assert_eq!(before.len(), 1);
    assert_eq!(before[0].commit_id.0, root);

    write_repo_config(&fx.path, "[revset-aliases]\n'trunk()' = 'description(\"Commit 3\")'\n");
    let after = collect_changes(&mut repo, "trunk()");
    assert_eq!(after.len(), 1);
    assert_eq!(
        after[0].commit_id.0, c3,
        "the repo layer's override must decide the denoted set"
    );
}

/// A per-item store failure surfaces as `JjLibError` only AFTER the rows the walk had already
/// handed over — partial output is not retracted (the contract `walk_graph` carries too, see
/// `tests/graph.rs::walk_graph_mid_stream_store_failure_returns_jj_lib_error`, which pins the
/// N = 0 shape by removing the whole object store).
#[test]
fn eval_revset_mid_walk_store_failure_keeps_the_rows_already_visited() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();

    // Read the id through a handle that is then DROPPED: the store caches every commit it
    // loads, so the handle that walks must never have seen the one removed below.
    let oldest = {
        let mut probe = Repo::open(&fx.path).unwrap();
        commit_id_of(&mut probe, "description(\"Commit 1\")")
    };

    // Remove exactly ONE loose object. The fixture is a linear chain (root → Commit 1 → 2 → 3,
    // `xtask::gen_fixture`), so `Commit 1` is the deepest non-root commit and every row before
    // it loads fine. Its CHILD is what fails first: a `Change` carries its parents' change ids,
    // so building `Commit 2`'s row already reads the missing parent. jj-lib 0.44.0 internals —
    // a pin bump may move where the failure surfaces; re-verify this test then.
    let object = fx
        .path
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("objects")
        .join(&oldest[..2])
        .join(&oldest[2..]);
    std::fs::remove_file(&object).unwrap();

    let mut repo = Repo::open(&fx.path).unwrap();
    let mut visited: Vec<String> = Vec::new();
    let result = repo.eval_revset("all()", |change| {
        visited.push(change.commit_id.0.clone());
        ControlFlow::Continue(())
    });

    assert!(
        matches!(result, Err(RevsetError::JjLibError(_))),
        "a commit read failing mid-walk must yield JjLibError, got: {result:?}"
    );
    assert!(
        !visited.is_empty(),
        "the rows handed to the visitor before the failure are not retracted; got none"
    );
    assert!(
        !visited.contains(&oldest),
        "the unreadable commit itself can never have been visited, got: {visited:?}"
    );
}

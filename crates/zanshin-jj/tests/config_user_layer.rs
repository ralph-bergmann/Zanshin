// SPDX-License-Identifier: MIT

//! The USER config layer (Story 4.9) — the one place in the suite that points `JJ_CONFIG`
//! at something other than `""`.
//!
//! # Why one test in its own binary
//!
//! `JJ_CONFIG` is process-global and `cargo test` threads a test binary, so a test that
//! CHANGES it would race every other test in the same binary. This file therefore holds
//! exactly ONE `#[test]`, which walks the whole user-layer matrix in sequence (file form,
//! directory form, a missing entry, and user-vs-repo precedence).
//!
//! # The rule this file must never break
//!
//! `JJ_CONFIG` may be repointed but is **never unset**: unset means the CLI's platform
//! discovery kicks in and the developer's real `~/.config/jj/config.toml` would load,
//! which would make the whole suite machine-dependent. Every path set below is inside a
//! temp dir owned by this test.

use std::env;
use std::fs;
use std::sync::LazyLock;

use test_helpers::extract_fixture;
use zanshin_jj::{resolve_revset, Repo, RevsetError};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: GIT_CONFIG_GLOBAL="" isolates the gix git backend. JJ_CONFIG starts pinned to
    // "" (discovery disabled) and is repointed inside the test — never unset.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
    }
});

/// Repoints `JJ_CONFIG` at a path owned by this test. Never called with an empty
/// or absent value that would re-enable platform discovery.
fn set_jj_config(path: &std::path::Path) {
    // SAFETY: single-threaded — this binary contains exactly one #[test].
    unsafe { env::set_var("JJ_CONFIG", path) };
}

/// Hex commit id of the single commit `expr` resolves to — through the public API only.
fn commit_id_of(repo: &Repo, expr: &str) -> String {
    let ids = resolve_revset(repo, expr).unwrap();
    assert_eq!(ids.len(), 1, "{expr} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

fn alias_toml(description: &str) -> String {
    format!("[revset-aliases]\n'trunk()' = 'description(\"{description}\")'\n")
}

#[test]
fn jj_config_user_layer_handles_files_dirs_missing_entries_and_repo_precedence() {
    LazyLock::force(&ENV_GUARD);
    let tmp = tempfile::tempdir().unwrap();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let root = commit_id_of(&repo, "root()");
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");
    let c2 = commit_id_of(&repo, "description(\"Commit 2\")");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    assert_eq!(
        commit_id_of(&repo, "trunk()"),
        root,
        "baseline: with JJ_CONFIG=\"\" only the builtin layer applies"
    );

    // ── A JJ_CONFIG entry may be a FILE ───────────────────────────────────────
    let user_file = tmp.path().join("user.toml");
    fs::write(&user_file, alias_toml("Commit 1")).unwrap();
    set_jj_config(&user_file);
    assert_eq!(
        commit_id_of(&repo, "trunk()"),
        c1,
        "the user file must override the builtin"
    );

    // ── …or a DIRECTORY: every *.toml loads, lexicographic order, later wins ──
    let user_dir = tmp.path().join("conf.d");
    fs::create_dir(&user_dir).unwrap();
    fs::write(user_dir.join("10-first.toml"), alias_toml("Commit 1")).unwrap();
    fs::write(user_dir.join("20-second.toml"), alias_toml("Commit 2")).unwrap();
    fs::write(user_dir.join("ignored.txt"), alias_toml("Commit 3")).unwrap();
    set_jj_config(&user_dir);
    assert_eq!(
        commit_id_of(&repo, "trunk()"),
        c2,
        "20-second.toml sorts after 10-first.toml and wins; the non-.toml file is ignored"
    );

    // ── A missing entry is silently skipped — no layer, no error ─────────────
    set_jj_config(&tmp.path().join("does-not-exist.toml"));
    assert_eq!(
        commit_id_of(&repo, "trunk()"),
        root,
        "a non-existent JJ_CONFIG entry contributes nothing and is not an error"
    );

    // ── A malformed USER file errors, naming that file ───────────────────────
    // Every other malformed-file assertion in the suite runs against the repo layer, so
    // this is the only coverage of `add_user_layers`' error path — the one place a
    // `ConfigSource::User` path can reach an error context.
    let broken = tmp.path().join("broken.toml");
    fs::write(&broken, "not = = toml").unwrap();
    set_jj_config(&broken);
    let result = resolve_revset(&repo, "all()");
    let Err(RevsetError::Config(err)) = result else {
        panic!("a malformed user config must yield RevsetError::Config, got: {result:?}");
    };
    assert!(
        err.to_string().contains("broken.toml"),
        "the context must name the user file, got: {err}"
    );

    // ── The REPO layer sits above the USER layer ─────────────────────────────
    set_jj_config(&user_file); // user says Commit 1
    fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        alias_toml("Commit 3"),
    )
    .unwrap();
    assert_eq!(
        commit_id_of(&repo, "trunk()"),
        c3,
        "the repo layer must win over the user layer"
    );
}

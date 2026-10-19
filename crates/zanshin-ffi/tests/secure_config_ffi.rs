// SPDX-License-Identifier: MIT

//! Story 9.37's wire contract: the jj CLI's start-up secure-config fix-up reaches Dart as
//! `Envelope.warnings` — on `zanshin_repo_open`'s ok `RepoHandle` envelope AND its refusal, on
//! every root-taking config wrapper's ok envelope and on its error envelope, and on a
//! handle-scoped snapshotting symbol's envelope. The jj-level behaviour is pinned in
//! `crates/zanshin-jj/tests/secure_config_fixups.rs`. Every buffer is read through the generated
//! typed accessors and the Verifier.

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::{root as fb_root, FlatBufferBuilder};
use tempfile::TempDir;
use zanshin_ffi::config::{
    zanshin_config_file_read, zanshin_config_file_write, zanshin_config_get, zanshin_config_list, zanshin_config_path,
    zanshin_config_set, zanshin_config_unset,
};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_ffi::snapshot::zanshin_snapshot;
use zanshin_ffi::{JJ_CONFIG_ERROR, JJ_CONFIG_MIGRATED, JJ_CONFIG_NOT_FOUND, JJ_CONFIG_REGENERATED};
use zanshin_jj::Repo;

/// The shared test env plus a leaked `$XDG_CONFIG_HOME`: the migrated configs land there.
static ENV_GUARD: LazyLock<PathBuf> = LazyLock::new(|| {
    let xdg = test_helpers::leaked_xdg_config_home();
    // SAFETY: every test calls `workspace()` first; the `LazyLock` blocks them until this returns.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", &xdg);
    }
    xdg
});

const LEGACY: &str = "[test]\nmarker = \"legacy\"\n";

/// A fresh native-backend workspace (no `config-id`); returns `(tempdir, canonical root)`.
fn workspace() -> (TempDir, PathBuf) {
    LazyLock::force(&ENV_GUARD);
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("ws");
    fs::create_dir(&root).unwrap();
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(&root),
        ..Default::default()
    })
    .result
    .expect("init");
    let root = fs::canonicalize(&root).unwrap();
    (tmp, root)
}

fn write_legacy(root: &Path, body: &str) {
    fs::write(root.join(".jj").join("repo").join("config.toml"), body).unwrap();
}

/// [`workspace`] with a LEGACY `.jj/repo/config.toml` holding `body`.
fn legacy_repo(body: &str) -> (TempDir, PathBuf) {
    let (tmp, root) = workspace();
    write_legacy(&root, body);
    (tmp, root)
}

fn utf8(root: &Path) -> &str {
    root.to_str().expect("utf-8 path")
}

/// Frees `token` after copying its bytes out.
fn take(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null());
    // SAFETY: fresh, non-null token, freed exactly once.
    let out = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    // SAFETY: as above.
    unsafe { zanshin_buffer_free_token(token) };
    out
}

fn open(root: &Path) -> Vec<u8> {
    let path = CString::new(utf8(root)).unwrap();
    // SAFETY: a valid NUL-terminated C string alive for the call.
    take(unsafe { zanshin_repo_open(path.as_ptr()) })
}

fn close(handle: u64) {
    // SAFETY: `handle` came from an open and is closed exactly once.
    let closed = take(unsafe { zanshin_repo_close(handle) });
    assert!(envelope(&closed).ok());
}

type Wrapper = unsafe extern "C" fn(*const u8, usize) -> *mut ZanshinBuf;

/// Builds a wrapper's request for the workspace root it is given.
type Request = fn(&str) -> Vec<u8>;

fn call(wrapper: Wrapper, req: &[u8]) -> Vec<u8> {
    // SAFETY: `req` points to `req.len()` live bytes for the call.
    take(unsafe { wrapper(req.as_ptr(), req.len()) })
}

fn envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("a verified Envelope")
}

/// `(code, message)` of every `Envelope.warnings` entry, in wire order.
fn warnings(env: &fbs::Envelope<'_>) -> Vec<(String, String)> {
    env.warnings()
        .into_iter()
        .flatten()
        .map(|w| {
            (
                w.code().unwrap_or_default().to_owned(),
                w.message().unwrap_or_default().to_owned(),
            )
        })
        .collect()
}

fn codes(env: &fbs::Envelope<'_>) -> Vec<String> {
    warnings(env).into_iter().map(|(code, _)| code).collect()
}

fn error_code(env: &fbs::Envelope<'_>) -> String {
    assert!(!env.ok(), "expected an error envelope");
    env.error().and_then(|e| e.code()).unwrap_or_default().to_owned()
}

fn assert_ok(env: &fbs::Envelope<'_>, what: &str) {
    assert!(
        env.ok(),
        "{what}: {:?} {:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
}

// ── Request builders (repo scope, `workspace_root` always set) ─────────────────

fn list_req(root: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = Some(b.create_string(root));
    let r = fbs::ConfigListRequest::create(
        &mut b,
        &fbs::ConfigListRequestArgs {
            kind: fbs::RequestKind::ConfigList,
            workspace_root,
            ..Default::default()
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn get_req(root: &str, name: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = Some(b.create_string(root));
    let name = Some(b.create_string(name));
    let r = fbs::ConfigGetRequest::create(
        &mut b,
        &fbs::ConfigGetRequestArgs {
            kind: fbs::RequestKind::ConfigGet,
            workspace_root,
            name,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn path_req(root: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = Some(b.create_string(root));
    let r = fbs::ConfigPathRequest::create(
        &mut b,
        &fbs::ConfigPathRequestArgs {
            kind: fbs::RequestKind::ConfigPath,
            workspace_root,
            scope: fbs::ConfigScope::Repo,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn set_req(root: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = Some(b.create_string(root));
    let name = Some(b.create_string("test.other"));
    let value = Some(b.create_string("1"));
    let r = fbs::ConfigSetRequest::create(
        &mut b,
        &fbs::ConfigSetRequestArgs {
            kind: fbs::RequestKind::ConfigSet,
            workspace_root,
            scope: fbs::ConfigScope::Repo,
            name,
            value,
            path: None,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn unset_req(root: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = Some(b.create_string(root));
    let name = Some(b.create_string("test.marker"));
    let r = fbs::ConfigUnsetRequest::create(
        &mut b,
        &fbs::ConfigUnsetRequestArgs {
            kind: fbs::RequestKind::ConfigUnset,
            workspace_root,
            scope: fbs::ConfigScope::Repo,
            name,
            path: None,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn file_read_req(root: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = Some(b.create_string(root));
    let r = fbs::ConfigFileReadRequest::create(
        &mut b,
        &fbs::ConfigFileReadRequestArgs {
            kind: fbs::RequestKind::ConfigFileRead,
            workspace_root,
            scope: fbs::ConfigScope::Repo,
            path: None,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn file_write_req(root: &str, path: &str, text: &str) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = Some(b.create_string(root));
    let path = Some(b.create_string(path));
    let text = Some(b.create_string(text));
    let r = fbs::ConfigFileWriteRequest::create(
        &mut b,
        &fbs::ConfigFileWriteRequestArgs {
            kind: fbs::RequestKind::ConfigFileWrite,
            workspace_root,
            path,
            text,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

// ── Rows ───────────────────────────────────────────────────────────────────────

#[test]
fn repo_open_carries_the_migration_on_its_repo_handle_envelope() {
    let (_tmp, root) = legacy_repo(LEGACY);
    let bytes = open(&root);
    let env = envelope(&bytes);
    assert_ok(&env, "open");
    let got = warnings(&env);
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0].0, JJ_CONFIG_MIGRATED);
    assert!(
        got[0].1.starts_with("Your config file has been migrated from "),
        "{}",
        got[0].1
    );
    assert!(env.precondition().is_none(), "opening runs no snapshot");
    close(env.data_as_repo_handle().expect("RepoHandle").handle());
}

#[test]
fn a_refused_repo_open_still_carries_the_migration() {
    let (_tmp, root) = legacy_repo("not toml [");
    let bytes = open(&root);
    let env = envelope(&bytes);
    assert_eq!(error_code(&env), JJ_CONFIG_ERROR);
    assert_eq!(codes(&env), [JJ_CONFIG_MIGRATED]);
}

#[test]
fn a_refused_config_get_still_carries_the_migration() {
    let (_tmp, root) = legacy_repo(LEGACY);
    let bytes = call(zanshin_config_get, &get_req(utf8(&root), "no.such"));
    let env = envelope(&bytes);
    assert_eq!(error_code(&env), JJ_CONFIG_NOT_FOUND);
    assert_eq!(codes(&env), [JJ_CONFIG_MIGRATED]);
}

/// Every root-taking wrapper's SUCCESS envelope carries the migration first — one fresh legacy
/// repo per wrapper, since the fix-up is one-shot.
#[test]
fn every_config_wrappers_ok_envelope_carries_the_migration_first() {
    let rows: [(&str, Wrapper, Request); 6] = [
        ("zanshin_config_list", zanshin_config_list, list_req),
        ("zanshin_config_get", zanshin_config_get, |root| {
            get_req(root, "test.marker")
        }),
        ("zanshin_config_path", zanshin_config_path, path_req),
        ("zanshin_config_set", zanshin_config_set, set_req),
        ("zanshin_config_unset", zanshin_config_unset, unset_req),
        ("zanshin_config_file_read", zanshin_config_file_read, file_read_req),
    ];
    for (name, wrapper, req) in rows {
        let (_tmp, root) = legacy_repo(LEGACY);
        let bytes = call(wrapper, &req(utf8(&root)));
        let env = envelope(&bytes);
        assert_ok(&env, name);
        assert_eq!(
            codes(&env).first().map(String::as_str),
            Some(JJ_CONFIG_MIGRATED),
            "{name}"
        );
    }
}

/// `zanshin_config_file_write`'s payload-less ok envelope carries the fix-up's notice too — via the
/// regenerate route: the secure dir `config path` created is deleted, and the write's own fix-up
/// brings it back before the file is written.
#[test]
fn the_file_write_ok_envelope_carries_the_regeneration() {
    let (_tmp, root) = workspace();
    let bytes = call(zanshin_config_path, &path_req(utf8(&root)));
    let env = envelope(&bytes);
    assert_ok(&env, "path");
    let file = env
        .data_as_config_path_result()
        .and_then(|r| r.paths())
        .expect("paths")
        .get(0)
        .to_owned();
    fs::remove_dir_all(Path::new(&file).parent().expect("the secure dir")).unwrap();

    let bytes = call(
        zanshin_config_file_write,
        &file_write_req(utf8(&root), &file, "a = 1\n"),
    );
    let env = envelope(&bytes);
    assert_ok(&env, "file_write");
    assert_eq!(env.data_type(), fbs::Payload::NONE);
    assert_eq!(codes(&env).first().map(String::as_str), Some(JJ_CONFIG_REGENERATED));
    assert_eq!(fs::read_to_string(&file).unwrap(), "a = 1\n");
}

/// A handle-scoped snapshotting symbol: a legacy repo config written after the open is migrated
/// by the verb's own start-up fix-up, whose notice is the envelope's first warning.
#[test]
fn a_snapshotting_handle_symbol_carries_its_own_migration_first() {
    let (_tmp, root) = workspace();
    let bytes = open(&root);
    let env = envelope(&bytes);
    assert_ok(&env, "open");
    assert!(env.warnings().is_none(), "nothing to fix at open");
    let handle = env.data_as_repo_handle().expect("RepoHandle").handle();
    write_legacy(&root, LEGACY);

    // SAFETY: `handle` is live — opened above, closed below.
    let bytes = take(unsafe { zanshin_snapshot(handle) });
    let env = envelope(&bytes);
    assert_ok(&env, "snapshot");
    assert_eq!(codes(&env).first().map(String::as_str), Some(JJ_CONFIG_MIGRATED));
    close(handle);
}

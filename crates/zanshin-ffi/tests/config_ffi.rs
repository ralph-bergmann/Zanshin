// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.28's nine config-surface wrappers (`zanshin_config_*`).
//!
//! The jj-level BEHAVIOUR is pinned in `crates/zanshin-jj/tests/config_cmd*.rs`; what is tested
//! here is the wire contract: the handle-less refusal ladder (null → verify → kind → required
//! fields), one happy path per wrapper at repo scope, and `zanshin_config_set`'s precondition.
//! Every buffer is read through the generated typed accessors and the Verifier.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use flatbuffers::{root as fb_root, FlatBufferBuilder};
use tempfile::TempDir;
use zanshin_ffi::config::{
    zanshin_config_file_read, zanshin_config_file_write, zanshin_config_gc_delete, zanshin_config_gc_list,
    zanshin_config_get, zanshin_config_list, zanshin_config_path, zanshin_config_set, zanshin_config_unset,
};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    FFI_INVALID_ARGUMENT, FFI_NULL_POINTER, JJ_CONFIG_NOT_FOUND, JJ_CONFIG_PARSE_ERROR, JJ_CONFIG_PATH_NOT_FOUND,
    JJ_CONFIG_UNRECOGNIZED_FILE, JJ_INVALID_INPUT, JJ_PATH_NOT_FOUND, JJ_REPO_NOT_FOUND,
};
use zanshin_jj::Repo;

/// The shared test env plus a leaked `$XDG_CONFIG_HOME`, so the secure repo config lands in a
/// temp dir, never under the developer's real `~/.config/jj`.
static ENV_GUARD: LazyLock<PathBuf> = LazyLock::new(|| {
    let xdg = TempDir::new().expect("xdg tempdir").keep();
    // SAFETY: every test calls `xdg()` first; the `LazyLock` blocks them until this returns.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", &xdg);
    }
    xdg
});

fn xdg() -> &'static Path {
    &ENV_GUARD
}

type Wrapper = unsafe extern "C" fn(*const u8, usize) -> *mut ZanshinBuf;

/// Calls `f` with `bytes` (or a null pointer for `None`) and returns the envelope bytes.
fn call(f: Wrapper, bytes: Option<&[u8]>) -> Vec<u8> {
    let (ptr, len) = bytes.map_or((std::ptr::null(), 0), |b| (b.as_ptr(), b.len()));
    // SAFETY: `ptr` is null or points to `len` live bytes for the call.
    let token = unsafe { f(ptr, len) };
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

fn envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("a verified Envelope")
}

fn error_code(bytes: &[u8]) -> String {
    let env = envelope(bytes);
    assert!(!env.ok(), "expected an error envelope");
    env.error().and_then(|e| e.code()).unwrap_or_default().to_owned()
}

fn ok(bytes: &[u8]) -> fbs::Envelope<'_> {
    let env = envelope(bytes);
    assert!(
        env.ok(),
        "expected ok, got {:?}: {:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
    env
}

/// A fresh native-backend workspace; returns `(tempdir, root as a string)`.
fn workspace() -> (TempDir, String) {
    xdg();
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("ws");
    fs::create_dir(&root).unwrap();
    Repo::init(&root, None).result.expect("init");
    let root = fs::canonicalize(&root).unwrap().to_str().unwrap().to_owned();
    (tmp, root)
}

// ── Request builders (None = the field genuinely ABSENT) ─────────────────────

struct Fields<'a> {
    kind: fbs::RequestKind,
    root: Option<&'a str>,
    scope: fbs::ConfigScope,
    name: Option<&'a str>,
    value: Option<&'a str>,
    path: Option<&'a str>,
}

fn fields(kind: fbs::RequestKind, root: Option<&str>) -> Fields<'_> {
    Fields {
        kind,
        root,
        scope: fbs::ConfigScope::Repo,
        name: None,
        value: None,
        path: None,
    }
}

fn list_req(f: &Fields<'_>, include_defaults: bool) -> Vec<u8> {
    list_req_with(f, include_defaults, true)
}

fn list_req_with(f: &Fields<'_>, include_defaults: bool, include_overridden: bool) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = f.root.map(|s| b.create_string(s));
    let name = f.name.map(|s| b.create_string(s));
    let r = fbs::ConfigListRequest::create(
        &mut b,
        &fbs::ConfigListRequestArgs {
            kind: f.kind,
            workspace_root,
            name,
            scope: f.scope,
            include_defaults,
            include_overridden,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn get_req(f: &Fields<'_>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = f.root.map(|s| b.create_string(s));
    let name = f.name.map(|s| b.create_string(s));
    let r = fbs::ConfigGetRequest::create(
        &mut b,
        &fbs::ConfigGetRequestArgs {
            kind: f.kind,
            workspace_root,
            name,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn path_req(f: &Fields<'_>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = f.root.map(|s| b.create_string(s));
    let r = fbs::ConfigPathRequest::create(
        &mut b,
        &fbs::ConfigPathRequestArgs {
            kind: f.kind,
            workspace_root,
            scope: f.scope,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn set_req(f: &Fields<'_>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = f.root.map(|s| b.create_string(s));
    let name = f.name.map(|s| b.create_string(s));
    let value = f.value.map(|s| b.create_string(s));
    let path = f.path.map(|s| b.create_string(s));
    let r = fbs::ConfigSetRequest::create(
        &mut b,
        &fbs::ConfigSetRequestArgs {
            kind: f.kind,
            workspace_root,
            scope: f.scope,
            name,
            value,
            path,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn unset_req(f: &Fields<'_>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = f.root.map(|s| b.create_string(s));
    let name = f.name.map(|s| b.create_string(s));
    let path = f.path.map(|s| b.create_string(s));
    let r = fbs::ConfigUnsetRequest::create(
        &mut b,
        &fbs::ConfigUnsetRequestArgs {
            kind: f.kind,
            workspace_root,
            scope: f.scope,
            name,
            path,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn file_read_req(f: &Fields<'_>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = f.root.map(|s| b.create_string(s));
    let path = f.path.map(|s| b.create_string(s));
    let r = fbs::ConfigFileReadRequest::create(
        &mut b,
        &fbs::ConfigFileReadRequestArgs {
            kind: f.kind,
            workspace_root,
            scope: f.scope,
            path,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn file_write_req(f: &Fields<'_>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let workspace_root = f.root.map(|s| b.create_string(s));
    let path = f.path.map(|s| b.create_string(s));
    let text = f.value.map(|s| b.create_string(s));
    let r = fbs::ConfigFileWriteRequest::create(
        &mut b,
        &fbs::ConfigFileWriteRequestArgs {
            kind: f.kind,
            workspace_root,
            path,
            text,
        },
    );
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn gc_list_req(kind: fbs::RequestKind) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let r = fbs::ConfigGcListRequest::create(&mut b, &fbs::ConfigGcListRequestArgs { kind });
    b.finish(r, None);
    b.finished_data().to_vec()
}

fn gc_delete_req(kind: fbs::RequestKind, dirs: Option<&[&str]>) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let config_dirs = dirs.map(|ds| {
        let offsets: Vec<_> = ds.iter().map(|d| b.create_string(d)).collect();
        b.create_vector(&offsets)
    });
    let r = fbs::ConfigGcDeleteRequest::create(&mut b, &fbs::ConfigGcDeleteRequestArgs { kind, config_dirs });
    b.finish(r, None);
    b.finished_data().to_vec()
}

// ── The ladder ────────────────────────────────────────────────────────────────

#[test]
fn every_wrapper_refuses_null_garbage_and_a_mis_routed_buffer() {
    xdg();
    let wrong = gc_list_req(fbs::RequestKind::FileTrack);
    for f in [
        zanshin_config_list as Wrapper,
        zanshin_config_get,
        zanshin_config_path,
        zanshin_config_set,
        zanshin_config_unset,
        zanshin_config_file_read,
        zanshin_config_file_write,
        zanshin_config_gc_list,
        zanshin_config_gc_delete,
    ] {
        assert_eq!(error_code(&call(f, None)), FFI_NULL_POINTER);
        assert_eq!(error_code(&call(f, Some(&[1, 2, 3]))), FFI_INVALID_ARGUMENT);
        assert_eq!(error_code(&call(f, Some(&wrong))), FFI_INVALID_ARGUMENT);
    }
}

#[test]
fn missing_required_fields_are_invalid_input() {
    use fbs::RequestKind as K;
    xdg();
    let unspecified = |kind| Fields {
        scope: fbs::ConfigScope::Unspecified,
        ..fields(kind, None)
    };
    for (f, bytes) in [
        (zanshin_config_get as Wrapper, get_req(&fields(K::ConfigGet, None))),
        (zanshin_config_path, path_req(&unspecified(K::ConfigPath))),
        (zanshin_config_set, set_req(&unspecified(K::ConfigSet))),
        (zanshin_config_set, set_req(&fields(K::ConfigSet, None))),
        (
            zanshin_config_set,
            set_req(&Fields {
                name: Some("a"),
                ..fields(K::ConfigSet, None)
            }),
        ),
        (zanshin_config_unset, unset_req(&fields(K::ConfigUnset, None))),
        (zanshin_config_unset, unset_req(&unspecified(K::ConfigUnset))),
        (zanshin_config_file_read, file_read_req(&unspecified(K::ConfigFileRead))),
        (
            zanshin_config_file_write,
            file_write_req(&fields(K::ConfigFileWrite, None)),
        ),
        (
            zanshin_config_file_write,
            file_write_req(&Fields {
                path: Some("/x"),
                ..fields(K::ConfigFileWrite, None)
            }),
        ),
        (zanshin_config_list, list_req(&fields(K::ConfigList, None), true)),
    ] {
        assert_eq!(error_code(&call(f, Some(&bytes))), JJ_INVALID_INPUT);
    }
}

// ── Happy paths ───────────────────────────────────────────────────────────────

#[test]
fn every_wrapper_works_at_repo_scope() {
    use fbs::RequestKind as K;
    let (tmp, root) = workspace();
    let at = |kind| fields(kind, Some(root.as_str()));

    let env_bytes = call(zanshin_config_path, Some(&path_req(&at(K::ConfigPath))));
    let file = ok(&env_bytes)
        .data_as_config_path_result()
        .unwrap()
        .paths()
        .unwrap()
        .get(0)
        .to_owned();
    assert!(Path::new(&file).starts_with(xdg().join("jj").join("repos")));

    let set = set_req(&Fields {
        name: Some("user.email"),
        value: Some("other@example.com"),
        ..at(K::ConfigSet)
    });
    let set_bytes = call(zanshin_config_set, Some(&set));
    let env = ok(&set_bytes);
    assert!(env.precondition().is_some(), "the identity check ran the snapshot");
    let result = env.data_as_config_set_result().unwrap();
    assert_eq!(result.path(), Some(file.as_str()));
    let author = result
        .working_copy_author()
        .expect("@ is authored by the pinned identity");
    assert_eq!(author.email(), Some("zanshin@localhost"));

    let get = get_req(&Fields {
        name: Some("user.email"),
        ..at(K::ConfigGet)
    });
    let get_bytes = call(zanshin_config_get, Some(&get));
    assert_eq!(
        ok(&get_bytes).data_as_config_get_result().unwrap().value(),
        Some("zanshin@localhost"),
        "JJ_EMAIL (EnvOverrides) still wins over the repo file"
    );

    let list_bytes = call(zanshin_config_list, Some(&list_req(&at(K::ConfigList), false)));
    let entries = ok(&list_bytes).data_as_config_list_result().unwrap().entries().unwrap();
    let repo_row = entries.iter().next().expect("the repo row");
    assert_eq!(repo_row.source(), fbs::ConfigValueSource::Repo);
    assert_eq!(repo_row.path(), Some(file.as_str()));
    assert!(repo_row.overridden());

    let unset = unset_req(&Fields {
        name: Some("user.email"),
        ..at(K::ConfigUnset)
    });
    let unset_bytes = call(zanshin_config_unset, Some(&unset));
    assert_eq!(
        ok(&unset_bytes).data_as_config_unset_result().unwrap().path(),
        Some(file.as_str())
    );
    assert_eq!(
        error_code(&call(zanshin_config_unset, Some(&unset))),
        JJ_CONFIG_NOT_FOUND
    );

    let read_bytes = call(zanshin_config_file_read, Some(&file_read_req(&at(K::ConfigFileRead))));
    let text = ok(&read_bytes).data_as_config_file_text().unwrap();
    assert_eq!(text.path(), Some(file.as_str()));

    let write = |value| {
        file_write_req(&Fields {
            path: Some(file.as_str()),
            value: Some(value),
            ..at(K::ConfigFileWrite)
        })
    };
    let bad = call(zanshin_config_file_write, Some(&write("[user\nname = ")));
    assert_eq!(error_code(&bad), JJ_CONFIG_PARSE_ERROR);
    let context = envelope(&bad).error().unwrap().context().unwrap().to_owned();
    assert!(context.contains(".."), "span first: {context}");
    let good = call(zanshin_config_file_write, Some(&write("revsets.log = '@'\n")));
    assert_eq!(ok(&good).data_type(), fbs::Payload::NONE);
    let stray = file_write_req(&Fields {
        path: Some("/nope.toml"),
        value: Some(""),
        ..at(K::ConfigFileWrite)
    });
    assert_eq!(
        error_code(&call(zanshin_config_file_write, Some(&stray))),
        JJ_CONFIG_UNRECOGNIZED_FILE
    );

    // gc: the repo goes away, its config dir is listed, then deleted.
    let dir = Path::new(&file).parent().unwrap().to_str().unwrap().to_owned();
    fs::remove_dir_all(tmp.path().join("ws")).unwrap();
    let list_bytes = call(zanshin_config_gc_list, Some(&gc_list_req(K::ConfigGcList)));
    let missing = ok(&list_bytes).data_as_config_gc_list().unwrap().missing().unwrap();
    assert!(missing.iter().any(|m| m.config_dir() == Some(dir.as_str())));
    let delete = gc_delete_req(K::ConfigGcDelete, Some(&[dir.as_str(), "/not-missing"]));
    let delete_bytes = call(zanshin_config_gc_delete, Some(&delete));
    let result = ok(&delete_bytes).data_as_config_gc_result().unwrap();
    assert_eq!(result.deleted().unwrap().get(0), dir);
    assert_eq!(result.failed().unwrap().get(0).config_dir(), Some("/not-missing"));
    let empty = call(zanshin_config_gc_delete, Some(&gc_delete_req(K::ConfigGcDelete, None)));
    assert!(ok(&empty)
        .data_as_config_gc_result()
        .unwrap()
        .deleted()
        .unwrap()
        .is_empty());
}

/// A missing repo config directory that cannot be deleted (it holds a file jj did not write)
/// is a `failed` entry AND the CLI's "Failed to delete …" warning on the envelope (Story 9.32).
#[test]
fn gc_delete_warns_about_a_directory_it_cannot_delete() {
    use fbs::RequestKind as K;
    let (tmp, root) = workspace();
    let path_bytes = call(
        zanshin_config_path,
        Some(&path_req(&fields(K::ConfigPath, Some(root.as_str())))),
    );
    let file = ok(&path_bytes)
        .data_as_config_path_result()
        .unwrap()
        .paths()
        .unwrap()
        .get(0)
        .to_owned();
    let dir = Path::new(&file).parent().unwrap().to_str().unwrap().to_owned();
    fs::remove_dir_all(tmp.path().join("ws")).unwrap();
    fs::write(Path::new(&dir).join("user-note.txt"), "keep me").unwrap();

    let bytes = call(
        zanshin_config_gc_delete,
        Some(&gc_delete_req(K::ConfigGcDelete, Some(&[dir.as_str()]))),
    );

    let env = ok(&bytes);
    let failed = env.data_as_config_gc_result().unwrap().failed().unwrap();
    assert_eq!(failed.len(), 1);
    assert_eq!(failed.get(0).config_dir(), Some(dir.as_str()));
    let reason = failed.get(0).reason().unwrap();
    let warnings: Vec<(&str, &str)> = env
        .warnings()
        .expect("the warning rides the envelope")
        .iter()
        .map(|w| (w.code().unwrap(), w.message().unwrap()))
        .collect();
    assert_eq!(
        warnings,
        [(
            "jj.config_gc_delete_failed",
            format!("Failed to delete {dir}: {reason}").as_str()
        )]
    );
    assert!(Path::new(&dir).exists());
}

#[test]
fn verb_refusals_carry_their_codes() {
    use fbs::RequestKind as K;
    let (tmp, root) = workspace();
    let missing = tmp.path().join("nope").to_str().unwrap().to_owned();
    let get = |root: &str, name| {
        get_req(&Fields {
            name: Some(name),
            ..fields(K::ConfigGet, Some(root))
        })
    };
    assert_eq!(
        error_code(&call(zanshin_config_get, Some(&get(&missing, "a")))),
        JJ_PATH_NOT_FOUND
    );
    let not_a_repo = tmp.path().to_str().unwrap();
    assert_eq!(
        error_code(&call(zanshin_config_get, Some(&get(not_a_repo, "a")))),
        JJ_REPO_NOT_FOUND
    );
    assert_eq!(
        error_code(&call(zanshin_config_get, Some(&get(&root, "a..b")))),
        JJ_CONFIG_PARSE_ERROR
    );
    assert_eq!(
        error_code(&call(zanshin_config_get, Some(&get(&root, "nope")))),
        JJ_CONFIG_NOT_FOUND
    );
    let user_path = path_req(&Fields {
        scope: fbs::ConfigScope::User,
        ..fields(K::ConfigPath, None)
    });
    assert_eq!(
        error_code(&call(zanshin_config_path, Some(&user_path))),
        JJ_CONFIG_PATH_NOT_FOUND
    );

    // A non-identity key over a table fails without any snapshot, so without a precondition.
    let table = set_req(&Fields {
        name: Some("user"),
        value: Some("x"),
        ..fields(K::ConfigSet, Some(root.as_str()))
    });
    let set = set_req(&Fields {
        name: Some("user.name"),
        value: Some("x"),
        ..fields(K::ConfigSet, Some(root.as_str()))
    });
    assert!(ok(&call(zanshin_config_set, Some(&set))).precondition().is_some());
    let bytes = call(zanshin_config_set, Some(&table));
    assert_eq!(error_code(&bytes), "jj.config_would_overwrite");
    assert!(
        envelope(&bytes).precondition().is_none(),
        "`user` is not an identity key"
    );
    let name_over_table = set_req(&Fields {
        name: Some("user.name.x"),
        value: Some("1"),
        ..fields(K::ConfigSet, Some(root.as_str()))
    });
    let bytes = call(zanshin_config_set, Some(&name_over_table));
    assert_eq!(error_code(&bytes), "jj.config_would_overwrite");
    let unset_table = unset_req(&Fields {
        name: Some("user"),
        ..fields(K::ConfigUnset, Some(root.as_str()))
    });
    assert_eq!(
        error_code(&call(zanshin_config_unset, Some(&unset_table))),
        "jj.config_would_delete_table"
    );

    // A failing IDENTITY set carries its precondition: the check's snapshot ran, then the write
    // failed. `user.name` is a TABLE in the repo file (the pinned `JJ_USER` keeps the start-up
    // stack valid), so the write is `WouldOverwriteTable`.
    let read_bytes = call(
        zanshin_config_file_read,
        Some(&file_read_req(&fields(K::ConfigFileRead, Some(root.as_str())))),
    );
    let file = ok(&read_bytes)
        .data_as_config_file_text()
        .unwrap()
        .path()
        .unwrap()
        .to_owned();
    let table_file = file_write_req(&Fields {
        path: Some(file.as_str()),
        value: Some("[user.name]\nx = 1\n"),
        ..fields(K::ConfigFileWrite, Some(root.as_str()))
    });
    ok(&call(zanshin_config_file_write, Some(&table_file)));
    let bytes = call(zanshin_config_set, Some(&set));
    assert_eq!(error_code(&bytes), "jj.config_would_overwrite");
    assert!(
        envelope(&bytes).precondition().is_some(),
        "the identity check ran before the write failed"
    );
    // …and so did its author note (Story 9.32): the CLI prints it before `set_value` fails.
    let codes: Vec<&str> = envelope(&bytes)
        .warnings()
        .expect("the error arm carries the check's warnings")
        .iter()
        .map(|w| w.code().unwrap())
        .collect();
    assert_eq!(codes, ["jj.config_working_copy_author"]);
}

#[test]
fn list_refuses_an_out_of_range_scope() {
    use fbs::RequestKind as K;
    xdg();
    let bad = list_req(
        &Fields {
            scope: fbs::ConfigScope(42),
            ..fields(K::ConfigList, None)
        },
        false,
    );
    assert_eq!(error_code(&call(zanshin_config_list, Some(&bad))), JJ_INVALID_INPUT);
}

/// The two scope arms the repo-scope round trip does not reach: `Unspecified` on `list` is "no
/// scope flag" (so `include_defaults` is allowed), and `Workspace` is a required scope.
#[test]
fn list_without_a_scope_and_the_workspace_scope_are_accepted() {
    use fbs::RequestKind as K;
    let (_tmp, root) = workspace();
    let unscoped = list_req(
        &Fields {
            scope: fbs::ConfigScope::Unspecified,
            ..fields(K::ConfigList, Some(&root))
        },
        true,
    );
    let listed = call(zanshin_config_list, Some(&unscoped));
    let entries = ok(&listed)
        .data_as_config_list_result()
        .expect("list")
        .entries()
        .expect("entries");
    assert!(
        entries.iter().any(|e| e.source() == fbs::ConfigValueSource::Default),
        "no scope + include_defaults lists the default layer"
    );

    let ws = path_req(&Fields {
        scope: fbs::ConfigScope::Workspace,
        ..fields(K::ConfigPath, Some(&root))
    });
    let answered = call(zanshin_config_path, Some(&ws));
    let paths = ok(&answered)
        .data_as_config_path_result()
        .expect("path")
        .paths()
        .expect("paths");
    assert!(paths
        .get(0)
        .starts_with(xdg().join("jj").join("workspaces").to_str().unwrap()));
}

/// The `path` of `set` / `unset` / `file_read` is the CLI's `--file` (jj 0.45), sent INSTEAD of a
/// scope: a location jj does not recognize is `jj.config_unrecognized_file` with nothing written,
/// the scope's own file is accepted, and a scope together with a path is `jj.invalid_input`.
#[test]
fn the_path_is_the_file_target() {
    use fbs::RequestKind as K;
    let (_tmp, root) = workspace();
    let at = |kind| Fields {
        scope: fbs::ConfigScope::Unspecified,
        ..fields(kind, Some(root.as_str()))
    };
    let path_bytes = call(
        zanshin_config_path,
        Some(&path_req(&fields(K::ConfigPath, Some(root.as_str())))),
    );
    let file = ok(&path_bytes)
        .data_as_config_path_result()
        .unwrap()
        .paths()
        .unwrap()
        .get(0)
        .to_owned();

    let set = |path| {
        set_req(&Fields {
            name: Some("revsets.log"),
            value: Some("@"),
            path: Some(path),
            ..at(K::ConfigSet)
        })
    };
    let unset = |path| {
        unset_req(&Fields {
            name: Some("revsets.log"),
            path: Some(path),
            ..at(K::ConfigUnset)
        })
    };
    let read = |path| {
        file_read_req(&Fields {
            path: Some(path),
            ..at(K::ConfigFileRead)
        })
    };
    for (f, stray) in [
        (zanshin_config_set as Wrapper, set("/stray.toml")),
        (zanshin_config_unset, unset("/stray.toml")),
        (zanshin_config_file_read, read("/stray.toml")),
    ] {
        let bytes = call(f, Some(&stray));
        assert_eq!(error_code(&bytes), JJ_CONFIG_UNRECOGNIZED_FILE);
        let context = envelope(&bytes).error().unwrap().context().unwrap().to_owned();
        assert_eq!(context, "/stray.toml", "the refused path");
    }
    assert!(!Path::new(&file).exists(), "nothing written");
    let both = set_req(&Fields {
        name: Some("revsets.log"),
        value: Some("@"),
        path: Some(file.as_str()),
        ..fields(K::ConfigSet, Some(root.as_str()))
    });
    assert_eq!(error_code(&call(zanshin_config_set, Some(&both))), JJ_INVALID_INPUT);

    let set_bytes = call(zanshin_config_set, Some(&set(file.as_str())));
    assert_eq!(
        ok(&set_bytes).data_as_config_set_result().unwrap().path(),
        Some(file.as_str())
    );
    let read_bytes = call(zanshin_config_file_read, Some(&read(file.as_str())));
    let text = ok(&read_bytes).data_as_config_file_text().unwrap();
    assert!(text.text().unwrap().contains("revsets"), "{:?}", text.text());
    let unset_bytes = call(zanshin_config_unset, Some(&unset(file.as_str())));
    assert_eq!(
        ok(&unset_bytes).data_as_config_unset_result().unwrap().path(),
        Some(file.as_str())
    );
}

/// `list`'s `name` prefix and `include_overridden = false` cross the wire: only the prefix's
/// keys, and a value shadowed by `JJ_EMAIL` (`EnvOverrides`) only on request.
#[test]
fn the_list_filters_cross_the_wire() {
    use fbs::RequestKind as K;
    let (_tmp, root) = workspace();
    let at = |kind| fields(kind, Some(root.as_str()));
    for (name, value) in [("revsets.log", "@"), ("user.email", "shadowed@example.com")] {
        let set = set_req(&Fields {
            name: Some(name),
            value: Some(value),
            ..at(K::ConfigSet)
        });
        ok(&call(zanshin_config_set, Some(&set)));
    }
    let names = |bytes: &[u8]| -> Vec<String> {
        ok(bytes)
            .data_as_config_list_result()
            .unwrap()
            .entries()
            .unwrap()
            .iter()
            .map(|e| e.name().unwrap().to_owned())
            .collect()
    };

    let prefixed = list_req_with(
        &Fields {
            name: Some("revsets"),
            ..at(K::ConfigList)
        },
        false,
        false,
    );
    assert_eq!(names(&call(zanshin_config_list, Some(&prefixed))), ["revsets.log"]);

    let effective = list_req_with(&at(K::ConfigList), false, false);
    assert!(!names(&call(zanshin_config_list, Some(&effective))).contains(&"user.email".to_owned()));
    let all = list_req_with(&at(K::ConfigList), false, true);
    assert!(names(&call(zanshin_config_list, Some(&all))).contains(&"user.email".to_owned()));
}

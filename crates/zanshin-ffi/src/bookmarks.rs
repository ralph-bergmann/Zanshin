// SPDX-License-Identifier: MIT

//! `zanshin_bookmarks` — bookmark-list read FFI wrapper (Story 3.4b, bookmarks slice; the
//! CLI's list arguments since Story 9.19).
//!
//! Reads a `BookmarkListRequest` buffer, calls `zanshin_jj::Repo::list_bookmarks` and
//! serialises the result into a `FlatBuffers` `Envelope` carrying a `Bookmarks` payload. The
//! handle is borrowed (not consumed).

use flatbuffers::{FlatBufferBuilder, VerifierOptions, WIPOffset};
use tracing::debug;
use zanshin_jj::{
    Bookmark, BookmarkError, BookmarkKind, BookmarkListOptions, BookmarkSortKey, ConfigError, RefDistance,
};

use crate::bookmark_ops::strings;
use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, map_precondition_err, precondition_envelope,
    reject_null_request, session_from_handle, FfiErrorObj, FFI_INVALID_ARGUMENT, JJ_CONFIG_ERROR, JJ_INVALID_INPUT,
    JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

/// Maps a [`BookmarkError`] onto its registered code, the reason in `context`; a failed pre-verb
/// snapshot goes through the shared [`map_precondition_err`]. Story 9.19 adds the four arms of
/// the list arguments, all onto codes `map_mutate_err` / `map_topology_err` already emit.
fn map_bookmarks_err(e: BookmarkError) -> FfiErrorObj {
    let (code, reason, hints) = match e {
        BookmarkError::Precondition(e) => return map_precondition_err(e),
        BookmarkError::InvalidInput { reason } => (JJ_INVALID_INPUT, reason, Vec::new()),
        BookmarkError::RevsetParseError { reason, hints } => (JJ_REVSET_PARSE_ERROR, reason, hints),
        BookmarkError::RevsetResolutionError { reason, hints } => (JJ_REVSET_RESOLUTION_ERROR, reason, hints),
        BookmarkError::Config(ConfigError::Load { reason }) => (JJ_CONFIG_ERROR, reason, Vec::new()),
        BookmarkError::Backend(reason) => (JJ_JJ_LIB_ERROR, reason, Vec::new()),
    };
    FfiErrorObj {
        report: None,
        hints,
        code: code.to_owned(),
        context: Some(reason),
    }
}

/// The wire sort key as the jj-level one; `Unspecified` (an unset element) and a byte outside
/// the enum are refused.
///
/// # Errors
/// - `ffi.invalid_argument` — `key` names no sort key.
fn sort_key(key: fbs::BookmarkSortKey) -> Result<BookmarkSortKey, FfiErrorObj> {
    use fbs::BookmarkSortKey as W;
    use BookmarkSortKey as K;
    Ok(match key {
        W::Name => K::Name,
        W::NameDesc => K::NameDesc,
        W::AuthorName => K::AuthorName,
        W::AuthorNameDesc => K::AuthorNameDesc,
        W::AuthorEmail => K::AuthorEmail,
        W::AuthorEmailDesc => K::AuthorEmailDesc,
        W::AuthorDate => K::AuthorDate,
        W::AuthorDateDesc => K::AuthorDateDesc,
        W::CommitterName => K::CommitterName,
        W::CommitterNameDesc => K::CommitterNameDesc,
        W::CommitterEmail => K::CommitterEmail,
        W::CommitterEmailDesc => K::CommitterEmailDesc,
        W::CommitterDate => K::CommitterDate,
        W::CommitterDateDesc => K::CommitterDateDesc,
        other => {
            return Err(FfiErrorObj {
                report: None,
                hints: Vec::new(),
                code: FFI_INVALID_ARGUMENT.to_owned(),
                context: Some(format!("invalid bookmark sort key: {other:?}")),
            })
        }
    })
}

/// Parse a `BookmarkListRequest` buffer into owned [`BookmarkListOptions`]. Absent vectors are
/// empty — the CLI without that argument.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkListRequest` buffer, its `kind`
///   is not `BookmarkList`, or a `sort` element is `Unspecified` or unknown.
fn read_bookmark_list_request(data: *const u8, len: usize) -> Result<BookmarkListOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (the readers' discipline, `repo.rs`).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::BookmarkListRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::BookmarkList)?;
    Ok(BookmarkListOptions {
        names: strings(req.names()),
        revisions: strings(req.revisions()),
        remotes: strings(req.remotes()),
        all_remotes: req.all_remotes(),
        tracked: req.tracked(),
        conflicted: req.conflicted(),
        sort: req
            .sort()
            .into_iter()
            .flatten()
            .map(sort_key)
            .collect::<Result<_, _>>()?,
    })
}

/// Builds one `RefDistance` table; `upper: None` is the presence pair's `has_upper = false`.
fn distance_to_fbs<'a>(b: &mut FlatBufferBuilder<'a>, distance: &RefDistance) -> WIPOffset<fbs::RefDistance<'a>> {
    fbs::RefDistance::create(
        b,
        &fbs::RefDistanceArgs {
            lower: distance.lower,
            upper: distance.upper.unwrap_or(0),
            has_upper: distance.upper.is_some(),
        },
    )
}

/// Serialise `&[Bookmark]` into a finished `Envelope<Bookmarks>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): for each `Bookmark`, its
/// strings and distance tables are built before its table; the `bookmarks` vector and
/// `Bookmarks` table come after the loop. `target` is absent when the row's target is
/// absent; `remote_name`, `tracked` and the distances are only written for `Remote` rows,
/// the distances only when computed.
fn bookmarks_to_envelope(bookmarks: &[Bookmark], report: &crate::envelope::CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(bookmarks.len());
    for bm in bookmarks {
        let name_off = b.create_string(&bm.name);
        let target_off = bm.target.as_ref().map(|target| b.create_string(&target.0));
        let mut args = fbs::BookmarkArgs {
            name: Some(name_off),
            target: target_off,
            kind: fbs::BookmarkKind::Local,
            remote_name: None,
            conflicted: bm.conflicted,
            synced: bm.synced,
            tracked: false,
            ahead: None,
            behind: None,
        };
        if let BookmarkKind::Remote {
            remote_name,
            tracked,
            ahead,
            behind,
        } = &bm.kind
        {
            args.kind = fbs::BookmarkKind::Remote;
            args.remote_name = Some(b.create_string(remote_name));
            args.tracked = *tracked;
            args.ahead = ahead.as_ref().map(|d| distance_to_fbs(&mut b, d));
            args.behind = behind.as_ref().map(|d| distance_to_fbs(&mut b, d));
        }
        offsets.push(fbs::Bookmark::create(&mut b, &args));
    }
    let vec = b.create_vector(&offsets);
    let bms_off = fbs::Bookmarks::create(&mut b, &fbs::BookmarksArgs { bookmarks: Some(vec) });
    finish_envelope(b, fbs::Payload::Bookmarks, Some(bms_off.as_union_value()), report)
}

/// List the bookmarks of the repo identified by `handle` — the rows `jj bookmark list` prints for
/// the request's arguments, in its order, with their tracking facts (Stories 9.29 and 9.19).
///
/// The arguments cross as a `BookmarkListRequest` `FlatBuffers` request buffer: `names` (string
/// PATTERNS, a bare one a GLOB) OR-ed with `revisions` (revsets on LOCAL targets), `remotes`
/// (remote-name patterns), `all_remotes`, `tracked`, `conflicted` and `sort` (empty applies
/// `ui.bookmark-list-sort-keys`). An all-default buffer lists the CLI's default rows;
/// `all_remotes` its `--all-remotes` set. Rows: each local row, then its tracked remote rows,
/// then the name's untracked remote rows, in name order, then re-sorted by the sort keys. An
/// exact name that matches no local or remote bookmark warns `jj.bookmark_names_unmatched`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Bookmarks` payload on success.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `BookmarkListRequest` buffer, its `kind`
///   is not `BookmarkList`, or a `sort` element is `Unspecified` or unknown.
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.invalid_input` — `all_remotes` with `remotes`, `tracked` or `conflicted` (clap's
///   conflict, refused before the snapshot), or a name or remote pattern does not parse.
/// - `jj.revset_parse_error` / `jj.revset_resolution_error` — a `revisions` text.
/// - `jj.config_error` — the pre-verb snapshot (Story 9.26) found the effective jj config
///   unreadable or a knob it reads wrongly typed (the key in `context`). Operations the snapshot
///   committed before the fault stay, as in the CLI (colocated: `import git head`); the partial
///   `precondition` says which. Or `ui.bookmark-list-sort-keys` is not an array of the CLI's key
///   names, or the revset aliases do not load.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.jj_lib_error` — an unclassified jj-lib error (incl. a failed ahead/behind revset);
///   detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` that has not been closed.
/// `0` is detected and returned as `ffi.invalid_handle`.
/// A stale non-zero handle is undefined behaviour; the Dart worker's Model-A
/// handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed
/// by Dart (`fbs.BookmarkListRequestObjectBuilder(...).toBytes()`); Rust only borrows it for
/// the duration of the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_bookmarks(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmarks", handle);
    let buf = catch(|| {
        let options = read_bookmark_list_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let bms = session.repo.list_bookmarks(&options);
        precondition_envelope(&mut session.repo, bms, map_bookmarks_err, |bms, p| {
            bookmarks_to_envelope(bms, p)
        })
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_jj::{Bookmark, BookmarkError, BookmarkKind, ConfigError, RefDistance};

    use super::{bookmarks_to_envelope, map_bookmarks_err, sort_key};
    use crate::fbs;
    use crate::{
        FFI_INVALID_ARGUMENT, JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR,
        JJ_REVSET_RESOLUTION_ERROR,
    };

    fn make_bookmark(name: &str, target: Option<&str>, kind: BookmarkKind) -> Bookmark {
        Bookmark {
            name: name.to_owned(),
            target: target.map(|t| zanshin_jj::ChangeId(t.to_owned())),
            conflicted: false,
            synced: false,
            kind,
        }
    }

    fn bookmarks_of(buf: &[u8]) -> flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<fbs::Bookmark<'_>>> {
        let env = fb_root::<fbs::Envelope>(buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok(), "envelope must be ok");
        assert_eq!(env.data_type(), fbs::Payload::Bookmarks, "data_type must be Bookmarks");
        let payload = env.data_as_bookmarks().expect("data_as_bookmarks must succeed");
        payload.bookmarks().expect("bookmarks must be present")
    }

    #[test]
    fn bookmarks_to_envelope_roundtrips_both_kinds() {
        let mut local = make_bookmark("main", Some("zxqpvuts"), BookmarkKind::Local);
        local.synced = true;
        let mut remote = make_bookmark(
            "feature",
            Some("qpmxrolk"),
            BookmarkKind::Remote {
                remote_name: "origin".to_owned(),
                tracked: true,
                ahead: Some(RefDistance {
                    lower: 3,
                    upper: Some(3),
                }),
                behind: Some(RefDistance { lower: 10, upper: None }),
            },
        );
        remote.conflicted = true;

        let buf = bookmarks_to_envelope(
            &[local.clone(), remote.clone()],
            &crate::envelope::CallReport::default(),
        );
        let fbs_bms = bookmarks_of(&buf);
        assert_eq!(fbs_bms.len(), 2, "must have 2 bookmark entries");

        // Local entry — distinct name/target/flags from the Remote entry, so a
        // cross-wired offset-vector bug would fail this test.
        let fbs_local = fbs_bms.get(0);
        assert_eq!(fbs_local.name(), Some("main"), "local name");
        assert_eq!(fbs_local.target(), Some("zxqpvuts"), "local target");
        assert_eq!(fbs_local.kind(), fbs::BookmarkKind::Local, "local kind");
        assert_eq!(
            fbs_local.remote_name(),
            None,
            "local remote_name must be absent (never serialized for Local)"
        );
        assert!(fbs_local.synced() && !fbs_local.conflicted() && !fbs_local.tracked());
        assert!(fbs_local.ahead().is_none() && fbs_local.behind().is_none());

        // Remote entry
        let fbs_remote = fbs_bms.get(1);
        assert_eq!(fbs_remote.name(), Some("feature"), "remote name");
        assert_eq!(fbs_remote.target(), Some("qpmxrolk"), "remote target");
        assert_eq!(fbs_remote.kind(), fbs::BookmarkKind::Remote, "remote kind");
        assert_eq!(fbs_remote.remote_name(), Some("origin"), "remote_name must be 'origin'");
        assert!(!fbs_remote.synced() && fbs_remote.conflicted() && fbs_remote.tracked());
        let ahead = fbs_remote.ahead().expect("ahead present");
        assert_eq!((ahead.lower(), ahead.upper(), ahead.has_upper()), (3, 3, true));
        let behind = fbs_remote.behind().expect("behind present");
        assert_eq!((behind.lower(), behind.has_upper()), (10, false), "an open upper bound");
    }

    #[test]
    fn bookmarks_to_envelope_leaves_absent_target_and_uncomputed_distances_absent() {
        let deleted = make_bookmark("gone", None, BookmarkKind::Local);
        let untracked = make_bookmark(
            "gone",
            Some("qpmxrolk"),
            BookmarkKind::Remote {
                remote_name: "origin".to_owned(),
                tracked: false,
                ahead: None,
                behind: None,
            },
        );

        let buf = bookmarks_to_envelope(&[deleted, untracked], &crate::envelope::CallReport::default());
        let fbs_bms = bookmarks_of(&buf);

        assert_eq!(fbs_bms.get(0).target(), None, "an absent target is not written");
        let remote = fbs_bms.get(1);
        assert!(!remote.tracked());
        assert!(remote.ahead().is_none() && remote.behind().is_none());
    }

    #[test]
    fn bookmarks_to_envelope_empty_roundtrips() {
        let buf = bookmarks_to_envelope(&[], &crate::envelope::CallReport::default());
        let env = fb_root::<fbs::Envelope>(&buf).expect("verifier must pass");
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Bookmarks);
        let payload = env.data_as_bookmarks().expect("data_as_bookmarks");
        assert_eq!(payload.bookmarks().map_or(0, |b| b.len()), 0, "empty bookmarks list");
    }

    #[test]
    fn map_bookmarks_err_backend_maps_to_jj_lib_error() {
        let obj = map_bookmarks_err(BookmarkError::Backend("boom".into()));
        assert_eq!(obj.code, JJ_JJ_LIB_ERROR, "code must be jj.jj_lib_error");
        assert_eq!(obj.context, Some("boom".to_owned()), "context must be forwarded");
    }

    /// Story 9.19: the four list-argument arms map onto the registered codes, reason in context;
    /// the revset arms carry their CLI hints (Story 9.25 closing run).
    #[test]
    fn map_bookmarks_err_maps_the_list_argument_refusals() {
        let hints = || vec!["Did you mean `description`?".to_owned()];
        for (e, code, expected_hints) in [
            (
                BookmarkError::InvalidInput { reason: "r".into() },
                JJ_INVALID_INPUT,
                vec![],
            ),
            (
                BookmarkError::RevsetParseError {
                    reason: "r".into(),
                    hints: hints(),
                },
                JJ_REVSET_PARSE_ERROR,
                hints(),
            ),
            (
                BookmarkError::RevsetResolutionError {
                    reason: "r".into(),
                    hints: hints(),
                },
                JJ_REVSET_RESOLUTION_ERROR,
                hints(),
            ),
            (
                BookmarkError::Config(ConfigError::Load { reason: "r".into() }),
                JJ_CONFIG_ERROR,
                vec![],
            ),
        ] {
            let obj = map_bookmarks_err(e);
            assert_eq!((obj.code.as_str(), obj.context.as_deref()), (code, Some("r")));
            assert_eq!(obj.hints, expected_hints);
        }
    }

    /// Every wire key maps to its jj-level key; `Unspecified` and an unknown byte are refused.
    #[test]
    fn sort_key_maps_every_key_and_refuses_unspecified() {
        use fbs::BookmarkSortKey as W;
        use zanshin_jj::BookmarkSortKey as K;
        let pairs = [
            (W::Name, K::Name),
            (W::NameDesc, K::NameDesc),
            (W::AuthorName, K::AuthorName),
            (W::AuthorNameDesc, K::AuthorNameDesc),
            (W::AuthorEmail, K::AuthorEmail),
            (W::AuthorEmailDesc, K::AuthorEmailDesc),
            (W::AuthorDate, K::AuthorDate),
            (W::AuthorDateDesc, K::AuthorDateDesc),
            (W::CommitterName, K::CommitterName),
            (W::CommitterNameDesc, K::CommitterNameDesc),
            (W::CommitterEmail, K::CommitterEmail),
            (W::CommitterEmailDesc, K::CommitterEmailDesc),
            (W::CommitterDate, K::CommitterDate),
            (W::CommitterDateDesc, K::CommitterDateDesc),
        ];
        for (wire, key) in pairs {
            assert_eq!(sort_key(wire).expect("a key"), key);
        }
        for bad in [W::Unspecified, W(200)] {
            let err = sort_key(bad).expect_err("refused");
            assert_eq!(err.code, FFI_INVALID_ARGUMENT);
        }
    }
}

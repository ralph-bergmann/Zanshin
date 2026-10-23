// SPDX-License-Identifier: MIT

//! `zanshin_git_push` — the CLI's `jj git push` (Story 9.20, FR-JJ-13b).
//!
//! Calls `zanshin_jj::Repo::git_push` and serialises its outcome into a `FlatBuffers` `Envelope`
//! carrying a `GitPushResult`. The arguments cross as a `GitPushRequest` request buffer (ADR-0001
//! composite-input pattern); the handle is borrowed, never consumed. The push runs the pre-verb
//! snapshot (Story 9.26), so every envelope carries the precondition report and the call's
//! warnings. Once the push loop has started, its outcome — a lease failure, a rejection, an
//! unreachable remote — is DATA on an ok envelope (`GitPushResult.failure`); only a refusal
//! before the network is an error envelope.

use flatbuffers::{FlatBufferBuilder, ForwardsUOffset, Vector, VerifierOptions, WIPOffset};
use tracing::debug;
use zanshin_jj::{
    GitPushArgs, GitPushOutcome, PushFailureKind, PushPath, PushRef, PushRefKind, PushRefStatus, PushRefusal,
};

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, precondition_envelope, reject_null_request,
    session_from_handle, CallReport, FfiErrorObj,
};
use crate::events;
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;

// ── Request reader ───────────────────────────────────────────────────────────────

/// A string vector as owned strings; ABSENT is `None`, distinct from present-empty. Shared by
/// the request readers (`repo.rs`'s `RepoCloneRequest` one too).
pub(crate) fn strings(v: Option<Vector<'_, ForwardsUOffset<&str>>>) -> Option<Vec<String>> {
    v.map(|v| v.iter().map(ToOwned::to_owned).collect())
}

/// Parse a `GitPushRequest` buffer into owned [`GitPushArgs`] and its `cancel_token` (Story 9.52,
/// `0` = none). `remotes` stays `None` when ABSENT (`--remote` not given); every other vector
/// treats absence as not given.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GitPushRequest`, or its `kind` is not
///   `GitPush`.
fn read_push_request(data: *const u8, len: usize) -> Result<(GitPushArgs, u64), FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only — the same discipline as `repo.rs`'s
    // readers: the slice is a local binding and only OWNED values leave this function.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::GitPushRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::GitPush)?;
    let args = GitPushArgs {
        remotes: strings(req.remotes()),
        bookmarks: strings(req.bookmarks()).unwrap_or_default(),
        tags: strings(req.tags()).unwrap_or_default(),
        all: req.all(),
        tracked: req.tracked(),
        deleted: req.deleted(),
        allow_empty_description: req.allow_empty_description(),
        allow_private: req.allow_private(),
        allow_conflicts: req.allow_conflicts(),
        revisions: strings(req.revisions()).unwrap_or_default(),
        changes: strings(req.changes()).unwrap_or_default(),
        named: strings(req.named()).unwrap_or_default(),
        dry_run: req.dry_run(),
        options: strings(req.options()).unwrap_or_default(),
    };
    Ok((args, req.cancel_token()))
}

// ── Payload builder ──────────────────────────────────────────────────────────────

fn kind_of(kind: PushRefKind) -> fbs::PushRefKind {
    match kind {
        PushRefKind::Bookmark => fbs::PushRefKind::Bookmark,
        PushRefKind::Tag => fbs::PushRefKind::Tag,
    }
}

fn path_of(path: PushPath) -> fbs::PushPath {
    match path {
        PushPath::Push => fbs::PushPath::Push,
        PushPath::Skip => fbs::PushPath::Skip,
        PushPath::Abort => fbs::PushPath::Abort,
    }
}

fn status_of(status: Option<PushRefStatus>) -> fbs::PushRefStatus {
    match status {
        None => fbs::PushRefStatus::NotReached,
        Some(PushRefStatus::Pushed) => fbs::PushRefStatus::Pushed,
        Some(PushRefStatus::LeaseRejected) => fbs::PushRefStatus::LeaseRejected,
        Some(PushRefStatus::RemoteRejected) => fbs::PushRefStatus::RemoteRejected,
        Some(PushRefStatus::Unexported) => fbs::PushRefStatus::Unexported,
    }
}

fn failure_kind_of(kind: PushFailureKind) -> fbs::PushFailureKind {
    match kind {
        PushFailureKind::RefRefused => fbs::PushFailureKind::RefRefused,
        PushFailureKind::CommitRejected => fbs::PushFailureKind::CommitRejected,
        PushFailureKind::SomeRefsFailed => fbs::PushFailureKind::SomeRefsFailed,
        PushFailureKind::PushError => fbs::PushFailureKind::PushError,
        PushFailureKind::Cancelled => fbs::PushFailureKind::Cancelled,
    }
}

/// A `count` as the wire's `uint`, saturating (a progress figure, never a decision key).
fn saturate(count: usize) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

fn string_vector<'b>(
    b: &mut FlatBufferBuilder<'b>,
    items: &[String],
) -> WIPOffset<Vector<'b, ForwardsUOffset<&'b str>>> {
    let offsets: Vec<_> = items.iter().map(|item| b.create_string(item)).collect();
    b.create_vector(&offsets)
}

fn build_refusal<'b>(b: &mut FlatBufferBuilder<'b>, refusal: &PushRefusal) -> WIPOffset<fbs::PushRefusal<'b>> {
    let message = b.create_string(&refusal.message);
    let hint = refusal.hint.as_deref().map(|hint| b.create_string(hint));
    fbs::PushRefusal::create(
        b,
        &fbs::PushRefusalArgs {
            message: Some(message),
            hint,
        },
    )
}

fn build_ref<'b>(b: &mut FlatBufferBuilder<'b>, row: &PushRef) -> WIPOffset<fbs::PushRef<'b>> {
    let name = b.create_string(&row.name);
    let before = row.before.as_deref().map(|id| b.create_string(id));
    let after = row.after.as_deref().map(|id| b.create_string(id));
    let action = row.action.as_deref().map(|text| b.create_string(text));
    let refusal = row.refusal.as_ref().map(|r| build_refusal(b, r));
    let explicit_refusal = row.explicit_refusal.as_ref().map(|r| build_refusal(b, r));
    let rejection = row.rejection.as_ref().map(|rejection| {
        let commit_id = b.create_string(&rejection.commit_id);
        let reasons = string_vector(b, &rejection.reasons);
        let message = b.create_string(&rejection.message);
        let hints = string_vector(b, &rejection.hints);
        fbs::PushCommitRejection::create(
            b,
            &fbs::PushCommitRejectionArgs {
                commit_id: Some(commit_id),
                reasons: Some(reasons),
                message: Some(message),
                hints: Some(hints),
            },
        )
    });
    let status_reason = row.status_reason.as_deref().map(|reason| b.create_string(reason));
    fbs::PushRef::create(
        b,
        &fbs::PushRefArgs {
            kind: kind_of(row.kind),
            name: Some(name),
            before,
            after,
            action,
            path: path_of(row.path),
            refusal,
            explicit_refusal,
            rejection,
            status: status_of(row.status),
            status_reason,
        },
    )
}

/// Build a success `Envelope` with a `GitPushResult` payload (Story 9.20): every child table is
/// completed before the table that holds it opens. Absent optional values stay ABSENT on the
/// wire (null-for-absence).
#[must_use]
pub fn ok_git_push_result(outcome: &GitPushOutcome, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let remotes: Vec<_> = outcome
        .remotes
        .iter()
        .map(|remote| {
            let name = b.create_string(&remote.name);
            let refs: Vec<_> = remote.refs.iter().map(|row| build_ref(&mut b, row)).collect();
            let refs = b.create_vector(&refs);
            let matches: Vec<_> = remote
                .already_matches
                .iter()
                .map(|matched| {
                    let name = b.create_string(&matched.name);
                    fbs::PushRefName::create(
                        &mut b,
                        &fbs::PushRefNameArgs {
                            kind: kind_of(matched.kind),
                            name: Some(name),
                        },
                    )
                })
                .collect();
            let already_matches = b.create_vector(&matches);
            let error = remote.error.as_deref().map(|e| b.create_string(e));
            fbs::PushRemote::create(
                &mut b,
                &fbs::PushRemoteArgs {
                    name: Some(name),
                    refs: Some(refs),
                    already_matches: Some(already_matches),
                    finished: remote.finished,
                    error,
                },
            )
        })
        .collect();
    let remotes = b.create_vector(&remotes);
    let created: Vec<_> = outcome
        .created_bookmarks
        .iter()
        .map(|created| {
            let name = b.create_string(&created.name);
            let change_id = b.create_string(&created.change_id);
            fbs::PushCreatedBookmark::create(
                &mut b,
                &fbs::PushCreatedBookmarkArgs {
                    name: Some(name),
                    change_id: Some(change_id),
                },
            )
        })
        .collect();
    let created = b.create_vector(&created);
    let hints = string_vector(&mut b, &outcome.hints);
    let signing = outcome.signing.map(|signing| {
        fbs::PushSigning::create(
            &mut b,
            &fbs::PushSigningArgs {
                updated_signatures: saturate(signing.updated_signatures),
                rebased_descendants: saturate(signing.rebased_descendants),
            },
        )
    });
    let description = outcome.description.as_deref().map(|text| b.create_string(text));
    let new_op_id = b.create_string(&outcome.new_op_id);
    let failure = outcome.failure.as_ref().map(|failure| {
        let message = b.create_string(&failure.message);
        let hint = failure.hint.as_deref().map(|hint| b.create_string(hint));
        fbs::PushFailure::create(
            &mut b,
            &fbs::PushFailureArgs {
                kind: failure_kind_of(failure.kind),
                message: Some(message),
                hint,
            },
        )
    });
    let result = fbs::GitPushResult::create(
        &mut b,
        &fbs::GitPushResultArgs {
            remotes: Some(remotes),
            created_bookmarks: Some(created),
            hints: Some(hints),
            signing,
            nothing_changed: outcome.nothing_changed,
            dry_run: outcome.dry_run,
            recorded: outcome.recorded,
            description,
            new_op_id: Some(new_op_id),
            failure,
        },
    );
    finish_envelope(b, fbs::Payload::GitPushResult, Some(result.as_union_value()), report)
}

// ── extern "C" ───────────────────────────────────────────────────────────────────

/// Push bookmarks and tags to git remotes, in the repo identified by `handle` — the CLI's
/// `jj git push` (Story 9.20), every parameter passed through.
///
/// The arguments cross as a `GitPushRequest` `FlatBuffers` request buffer, one field per CLI flag
/// (`remotes` — ABSENT = `--remote` not given: `git.push`, else the only remote, else `origin`;
/// `bookmarks`, `tags`, `all`, `tracked`, `deleted`, the three `allow_*`, `revisions`, `changes`,
/// `named`, `dry_run`, `options`). The working copy is snapshotted first (Story 9.26); then ONE
/// transaction: the remotes resolve, `--change` / `--named` bookmarks are created, each remote's
/// refs are classified — the bare push / `-r` / `--all` / `--tracked` / `--deleted` skip a refused
/// ref or a rejected commit with a warning, explicitly named refs refuse the whole push — and a
/// real push signs (`git.sign-on-push`), pushes remote by remote and records the operation when
/// every ref succeeded or at least one was exported. A dry run returns the plan and writes nothing
/// beyond the snapshot's operation.
///
/// Progress is dispatched over the process-global event sink as `Progress` events with
/// `operation = "push"`, tagged with the session's `session_id` (push progress arrives mostly as
/// sideband text, so there may be none).
///
/// `cancel_token` (Story 9.52) is `0` (not cancellable) or a token from `zanshin_network_token`;
/// `zanshin_network_cancel` stops the push before the next remote's git push (and kills a running
/// one). Once every remote's git push has run, the push finishes normally.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `GitPushResult` payload on success — also when the
/// push failed after it started (`GitPushResult.failure`: a lease failure, a remote rejection, an
/// unreachable remote, a cancel — kind `Cancelled`, nothing recorded, the per-remote data saying
/// which remotes already got their refs; `recorded` says whether Undo applies).
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GitPushRequest` buffer, or its `kind`
///   is not `GitPush`.
/// - `jj.invalid_input` — conflicting flags (before the snapshot, as clap refuses them: nothing
///   written, no `precondition`), a pattern that does not parse, "No git remotes to push to", a
///   malformed `--named`, an empty `--change` set; the CLI's text in `context`.
/// - `jj.bookmark_exists` / `jj.bookmark_tracked_remote_exists` — a `--change` / `--named` name is
///   taken; the name in `context`.
/// - `jj.push_ref_refused` / `jj.push_commit_rejected` — an explicitly named ref is refused, or
///   would push a commit that is not ready (a real push); the CLI's text in `context`.
/// - `jj.revset_parse_error` / `jj.revset_resolution_error` — a revision does not parse or resolve.
/// - `jj.config_error` — a key the push reads is malformed, or `immutable_heads()` does not
///   resolve; or (`--change`, Story 9.51) `templates.git_push_bookmark` does not parse or renders a
///   name that is not UTF-8 or is empty — the CLI's text ("Failed to parse template: …", "Invalid
///   character in bookmark name", "Empty bookmark name generated") in `context`.
/// - `jj.not_a_git_repo` — the workspace has no git backend.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — any other underlying jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.GitPushRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_git_push(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_git_push", handle);
    let buf = catch(|| {
        let (args, cancel_token) = read_push_request(data, len)?;
        let cancel = zanshin_jj::cancel::attach(cancel_token);
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let session_id = session.session_id;
        let progress = move |e: zanshin_jj::ProgressEvent| {
            events::dispatch(events::progress_to_envelope(
                session_id,
                &e.operation,
                e.progress,
                &e.message,
            ));
        };
        let result = session.repo.git_push(&args, &progress, cancel.as_ref());
        precondition_envelope(&mut session.repo, result, map_mutate_err, ok_git_push_result)
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outcome() -> GitPushOutcome {
        GitPushOutcome {
            remotes: vec![zanshin_jj::PushRemote {
                name: "origin".to_owned(),
                refs: vec![PushRef {
                    kind: PushRefKind::Tag,
                    name: "v1".to_owned(),
                    before: None,
                    after: Some("ab".repeat(20)),
                    action: Some("add to abababababab".to_owned()),
                    path: PushPath::Skip,
                    refusal: Some(PushRefusal {
                        message: "Refusing to create new remote tag v1@origin".to_owned(),
                        hint: Some("Run `jj tag track v1@origin` and try again.".to_owned()),
                    }),
                    explicit_refusal: None,
                    rejection: Some(zanshin_jj::PushCommitRejection {
                        commit_id: "ab".repeat(20),
                        reasons: vec!["is private".to_owned()],
                        message: "Won't push tag v1: commit abababababab is private".to_owned(),
                        hints: vec!["Configured git.private-commits: 'all()'".to_owned()],
                    }),
                    status: Some(PushRefStatus::Unexported),
                    status_reason: Some("why".to_owned()),
                }],
                already_matches: vec![zanshin_jj::PushRefName {
                    kind: PushRefKind::Bookmark,
                    name: "main".to_owned(),
                }],
                finished: true,
                error: Some("boom".to_owned()),
            }],
            created_bookmarks: vec![zanshin_jj::PushCreatedBookmark {
                name: "push-abc".to_owned(),
                change_id: "zzzz".to_owned(),
            }],
            hints: vec!["hint".to_owned()],
            signing: Some(zanshin_jj::PushSigning {
                updated_signatures: 2,
                rebased_descendants: 1,
            }),
            nothing_changed: false,
            dry_run: true,
            recorded: false,
            description: Some("push tag v1 to git remote origin".to_owned()),
            new_op_id: "op".to_owned(),
            failure: Some(zanshin_jj::PushFailure {
                kind: PushFailureKind::CommitRejected,
                message: "Won't push".to_owned(),
                hint: None,
            }),
        }
    }

    /// Every field of the outcome reaches the wire, read back through the typed accessors.
    #[test]
    fn a_push_outcome_round_trips_through_the_wire() {
        let bytes = ok_git_push_result(&outcome(), &CallReport::default());
        let envelope = fbs::root_as_envelope(&bytes).expect("verifies");
        let result = envelope.data_as_git_push_result().expect("GitPushResult");
        assert!(result.dry_run() && !result.recorded() && !result.nothing_changed());
        assert_eq!(result.description(), Some("push tag v1 to git remote origin"));
        assert_eq!(result.new_op_id(), Some("op"));
        let signing = result.signing().expect("signing");
        assert_eq!((signing.updated_signatures(), signing.rebased_descendants()), (2, 1));
        let failure = result.failure().expect("failure");
        assert_eq!(failure.kind(), fbs::PushFailureKind::CommitRejected);
        assert!(failure.hint().is_none());
        let created = result.created_bookmarks().expect("created");
        assert_eq!(created.get(0).name(), Some("push-abc"));
        assert_eq!(result.hints().expect("hints").get(0), "hint");
        let remote = result.remotes().expect("remotes").get(0);
        assert_eq!(
            (remote.name(), remote.finished(), remote.error()),
            (Some("origin"), true, Some("boom"))
        );
        assert_eq!(
            remote.already_matches().expect("matches").get(0).kind(),
            fbs::PushRefKind::Bookmark
        );
        let row = remote.refs().expect("refs").get(0);
        assert_eq!(
            (row.kind(), row.path(), row.status()),
            (
                fbs::PushRefKind::Tag,
                fbs::PushPath::Skip,
                fbs::PushRefStatus::Unexported
            )
        );
        assert!(row.before().is_none() && row.explicit_refusal().is_none());
        assert_eq!(
            row.refusal().expect("refusal").hint(),
            Some("Run `jj tag track v1@origin` and try again.")
        );
        let rejection = row.rejection().expect("rejection");
        assert_eq!(rejection.reasons().expect("reasons").get(0), "is private");
        assert_eq!(row.status_reason(), Some("why"));
    }

    /// The enum mappings are total and one-to-one.
    #[test]
    fn every_push_enum_maps_to_its_wire_value() {
        assert_eq!(status_of(None), fbs::PushRefStatus::NotReached);
        assert_eq!(status_of(Some(PushRefStatus::Pushed)), fbs::PushRefStatus::Pushed);
        assert_eq!(
            status_of(Some(PushRefStatus::LeaseRejected)),
            fbs::PushRefStatus::LeaseRejected
        );
        assert_eq!(
            status_of(Some(PushRefStatus::RemoteRejected)),
            fbs::PushRefStatus::RemoteRejected
        );
        assert_eq!(path_of(PushPath::Push), fbs::PushPath::Push);
        assert_eq!(path_of(PushPath::Abort), fbs::PushPath::Abort);
        for (kind, wire) in [
            (PushFailureKind::RefRefused, fbs::PushFailureKind::RefRefused),
            (PushFailureKind::CommitRejected, fbs::PushFailureKind::CommitRejected),
            (PushFailureKind::SomeRefsFailed, fbs::PushFailureKind::SomeRefsFailed),
            (PushFailureKind::PushError, fbs::PushFailureKind::PushError),
            (PushFailureKind::Cancelled, fbs::PushFailureKind::Cancelled),
        ] {
            assert_eq!(failure_kind_of(kind), wire);
        }
        assert_eq!(saturate(usize::MAX), u32::MAX);
    }

    /// Every `GitPushRequest` field reaches its own `GitPushArgs` field: each list holds a
    /// distinct value, and each flag is checked set alone against all others unset.
    #[test]
    fn read_push_request_maps_every_field() {
        fn request(flag: Option<&str>) -> Vec<u8> {
            let mut b = FlatBufferBuilder::new();
            let mut list = |s: &str| {
                let item = b.create_string(s);
                b.create_vector(&[item])
            };
            let (remotes, bookmarks, tags) = (list("r"), list("b"), list("t"));
            let (revisions, changes, named, options) = (list("rev"), list("c"), list("n=@"), list("o"));
            let on = |name: &str| flag == Some(name);
            let req = fbs::GitPushRequest::create(
                &mut b,
                &fbs::GitPushRequestArgs {
                    kind: fbs::RequestKind::GitPush,
                    remotes: Some(remotes),
                    bookmarks: Some(bookmarks),
                    tags: Some(tags),
                    all: on("all"),
                    tracked: on("tracked"),
                    deleted: on("deleted"),
                    allow_empty_description: on("allow_empty_description"),
                    allow_private: on("allow_private"),
                    allow_conflicts: on("allow_conflicts"),
                    revisions: Some(revisions),
                    changes: Some(changes),
                    named: Some(named),
                    dry_run: on("dry_run"),
                    options: Some(options),
                    cancel_token: 42,
                },
            );
            b.finish(req, None);
            b.finished_data().to_vec()
        }
        let read = |flag| {
            let bytes = request(flag);
            let (args, cancel_token) = read_push_request(bytes.as_ptr(), bytes.len()).expect("valid request");
            assert_eq!(cancel_token, 42);
            args
        };
        let lists = GitPushArgs {
            remotes: Some(vec!["r".to_owned()]),
            bookmarks: vec!["b".to_owned()],
            tags: vec!["t".to_owned()],
            revisions: vec!["rev".to_owned()],
            changes: vec!["c".to_owned()],
            named: vec!["n=@".to_owned()],
            options: vec!["o".to_owned()],
            ..GitPushArgs::default()
        };
        assert_eq!(read(None), lists);
        for name in [
            "all",
            "tracked",
            "deleted",
            "allow_empty_description",
            "allow_private",
            "allow_conflicts",
            "dry_run",
        ] {
            let mut expected = lists.clone();
            *match name {
                "all" => &mut expected.all,
                "tracked" => &mut expected.tracked,
                "deleted" => &mut expected.deleted,
                "allow_empty_description" => &mut expected.allow_empty_description,
                "allow_private" => &mut expected.allow_private,
                "allow_conflicts" => &mut expected.allow_conflicts,
                _ => &mut expected.dry_run,
            } = true;
            assert_eq!(read(Some(name)), expected, "flag {name}");
        }
    }
}

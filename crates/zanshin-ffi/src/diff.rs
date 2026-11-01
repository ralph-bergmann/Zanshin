// SPDX-License-Identifier: MIT

//! The line-level `Diff` payload (Story 5.5): `zanshin_jj::Repo::diff`'s files, hunks, lines,
//! section keys and pins (Story 5.6) on the FFI wire, and `zanshin_diff` (Story 5.8), `jj diff` as
//! data. Its arguments cross as a `DiffRequest` request BUFFER (ADR-0001 composite-input pattern);
//! the handle is borrowed, never consumed; the call runs the pre-verb snapshot (Story 9.26), so
//! every envelope carries the precondition report and the call's warnings.

use flatbuffers::{FlatBufferBuilder, ForwardsUOffset, Vector, VerifierOptions, WIPOffset};
use tracing::debug;
use zanshin_jj::{
    DiffOptions, DiffRevisions, FileDiff, Hunk, HunkKey, HunkLine, MutateError, RevisionDiff, Whitespace,
};

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, precondition_envelope, reject_null_request,
    session_from_handle, CallReport, FfiErrorObj, FFI_INVALID_ARGUMENT,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::repo::map_mutate_err;
use crate::select_tree::strings;
use crate::status::change_kind_offset;

/// Parse a `DiffRequest` buffer into owned [`DiffOptions`], each revision as its revset text:
/// `from` or `to` present is the `--from` / `--to` form (an absent side `@`), else the `-r` form
/// (absent: `@`); absent vectors are empty, an absent `context` is the effective
/// `diff.git.context`.
///
/// `data`/`len` describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for
/// the call only. The byte slice lives in this function's scope and the result is OWNED, so the
/// unbounded lifetime `std::slice::from_raw_parts` produces cannot outlive the call.
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DiffRequest` buffer, its `kind` is not
///   `Diff`, or its `whitespace` is outside the enum.
/// - `jj.invalid_input` — `revision` together with `from` or `to` (the CLI's `-r` vs
///   `--from`/`--to` conflict).
fn read_diff_request(data: *const u8, len: usize) -> Result<DiffOptions, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::DiffRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::Diff)?;
    let text = |s: Option<&str>| s.map(str::to_owned);
    let revisions = match (text(req.revision()), text(req.from()), text(req.to())) {
        (Some(_), from, to) if from.is_some() || to.is_some() => {
            return Err(map_mutate_err(MutateError::invalid(
                "revision cannot be used with from or to",
            )))
        }
        (revision, None, None) => DiffRevisions::Revision(revision),
        (_, from, to) => DiffRevisions::FromTo { from, to },
    };
    Ok(DiffOptions {
        revisions,
        paths: strings(req.paths()),
        context: req.context().map(|c| c.value() as usize),
        whitespace: diff_whitespace(req.whitespace())?,
        summary: req.summary(),
    })
}

/// A wire `DiffWhitespace`.
///
/// # Errors
/// - `ffi.invalid_argument` — a value outside the enum (a newer writer).
fn diff_whitespace(whitespace: fbs::DiffWhitespace) -> Result<Whitespace, FfiErrorObj> {
    match whitespace {
        fbs::DiffWhitespace::Exact => Ok(Whitespace::Exact),
        fbs::DiffWhitespace::IgnoreAllSpace => Ok(Whitespace::IgnoreAllSpace),
        fbs::DiffWhitespace::IgnoreSpaceChange => Ok(Whitespace::IgnoreSpaceChange),
        other => Err(FfiErrorObj {
            report: None,
            hints: Vec::new(),
            code: FFI_INVALID_ARGUMENT.to_owned(),
            context: Some(format!("unknown diff whitespace: {other:?}")),
        }),
    }
}

/// `jj diff` as data in the repo identified by `handle` (Story 5.8) — `zanshin_jj::Repo::diff`:
/// per changed file its kind, flags, section keys (the `HunkKey`s `zanshin_select_tree` takes),
/// hunks, counts and fingerprint, pinned to the operation and commit(s) it was read at.
///
/// The arguments cross as a `DiffRequest` `FlatBuffers` request buffer: `revision` (`-r`, against
/// its merged parents; absent: `@`) or `from` / `to` (`--from` / `--to`; either present selects
/// that form, an absent side `@`) — each a revset that must resolve to exactly one commit (a
/// commit id reaches a hidden commit; the CLI's multi-revision `-r`, a range diffed as one, is
/// not ported; parse diagnostics land on the call's warnings) — `paths` (repo-relative prefixes;
/// empty: every path; one that matches nothing is a `jj.paths_unmatched` warning), `context`
/// (absent: the effective `diff.git.context`), `whitespace` (`-w` / `-b`) and `summary` (no
/// hunks). No caching. Writes NO operation beyond the pre-verb snapshot's (Story 9.26).
///
/// Returns a `FlatBuffers` `Envelope` carrying a `Diff` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `DiffRequest` buffer, its `kind` is not
///   `Diff`, or its `whitespace` is outside the enum.
/// - `jj.invalid_input` — `revision` together with `from` or `to` (before the snapshot: nothing
///   written, no `precondition`), or a `paths` entry that is not a valid repo path or leaves the
///   repository; detail in `context`.
/// - `jj.revset_parse_error` — a revision is not a valid revset expression.
/// - `jj.revset_resolution_error` — a revision resolves to no commit or more than one (an unknown
///   symbol, an ambiguous prefix, a divergent change; the CLI's hints in `hints`), a failing
///   `revsets.short-prefixes`, or `@` in a workspace with no working-copy commit.
/// - `jj.config_error` — `diff.git.context`, `ui.conflict-marker-style` or the revset aliases are
///   malformed.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26).
/// - `jj.jj_lib_error` — a side cannot be read, or another jj-lib failure; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.DiffRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the duration of
/// the call.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_diff(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_diff", handle);
    let buf = catch(|| {
        let options = read_diff_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session.repo.diff(&options);
        precondition_envelope(&mut session.repo, result, map_mutate_err, diff_to_envelope)
    });
    vec_into_token(buf)
}

/// Build a success `Envelope` with a `Diff` payload and return the finished buffer: the files
/// exactly as `diff` returned them, in order, every vector written (empty, not absent), a `None`
/// symbol, `from_path` or `from_commit_id` absent. `report` rides as on every envelope.
#[must_use]
pub fn diff_to_envelope(diff: &RevisionDiff, report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let files: Vec<_> = diff.files.iter().map(|f| file_offset(&mut b, f)).collect();
    let files = b.create_vector(&files);
    let operation_id = b.create_string(&diff.operation_id.0);
    let commit_id = b.create_string(&diff.commit_id.0);
    let from_commit_id = diff.from_commit_id.as_ref().map(|id| b.create_string(&id.0));
    let diff = fbs::Diff::create(
        &mut b,
        &fbs::DiffArgs {
            files: Some(files),
            operation_id: Some(operation_id),
            commit_id: Some(commit_id),
            from_commit_id,
        },
    );
    finish_envelope(b, fbs::Payload::Diff, Some(diff.as_union_value()), report)
}

fn file_offset<'b>(b: &mut FlatBufferBuilder<'b>, f: &FileDiff) -> WIPOffset<fbs::FileDiff<'b>> {
    let path = b.create_string(&f.path);
    let sections = keys_vector(b, &f.sections);
    let hunks: Vec<_> = f.hunks.iter().map(|h| hunk_offset(b, h)).collect();
    let hunks = b.create_vector(&hunks);
    let (kind, from_path) = change_kind_offset(b, &f.kind);
    let fingerprint = b.create_string(&f.fingerprint);
    fbs::FileDiff::create(
        b,
        &fbs::FileDiffArgs {
            path: Some(path),
            binary: f.binary,
            mode_change: f.mode_change,
            sections: Some(sections),
            hunks: Some(hunks),
            kind,
            from_path,
            removed: f.removed,
            added: f.added,
            fingerprint: Some(fingerprint),
        },
    )
}

fn hunk_offset<'b>(b: &mut FlatBufferBuilder<'b>, h: &Hunk) -> WIPOffset<fbs::Hunk<'b>> {
    let symbol = h.symbol.as_deref().map(|s| b.create_string(s));
    let sections = keys_vector(b, &h.sections);
    let lines: Vec<_> = h.lines.iter().map(|l| line_offset(b, l)).collect();
    let lines = b.create_vector(&lines);
    fbs::Hunk::create(
        b,
        &fbs::HunkArgs {
            before_start: h.before_range.start,
            before_end: h.before_range.end,
            after_start: h.after_range.start,
            after_end: h.after_range.end,
            symbol,
            sections: Some(sections),
            removed: h.removed,
            added: h.added,
            lines: Some(lines),
        },
    )
}

fn line_offset<'b>(b: &mut FlatBufferBuilder<'b>, line: &HunkLine) -> WIPOffset<fbs::HunkLine<'b>> {
    let (kind, text) = match line {
        HunkLine::Context(text) => (fbs::HunkLineKind::Context, text),
        HunkLine::Removed(text) => (fbs::HunkLineKind::Removed, text),
        HunkLine::Added(text) => (fbs::HunkLineKind::Added, text),
    };
    let text = b.create_string(text);
    fbs::HunkLine::create(b, &fbs::HunkLineArgs { kind, text: Some(text) })
}

fn keys_vector<'b>(
    b: &mut FlatBufferBuilder<'b>,
    keys: &[HunkKey],
) -> WIPOffset<Vector<'b, ForwardsUOffset<fbs::HunkKey<'b>>>> {
    let keys: Vec<_> = keys
        .iter()
        .map(|k| {
            fbs::HunkKey::create(
                b,
                &fbs::HunkKeyArgs {
                    old_start: k.old_start,
                    old_count: k.old_count,
                    new_start: k.new_start,
                    new_count: k.new_count,
                },
            )
        })
        .collect();
    b.create_vector(&keys)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use flatbuffers::VerifierOptions;
    use zanshin_jj::{ChangeKind, CommitId, FileDiff, Hunk, HunkKey, HunkLine, OperationId, RevisionDiff};

    use super::diff_to_envelope;
    use crate::envelope::CallReport;
    use crate::fbs;

    fn verified_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
        flatbuffers::root_with_opts::<fbs::Envelope>(&VerifierOptions::default(), bytes)
            .expect("FlatBuffers Verifier must pass for a well-formed Envelope buffer")
    }

    fn key(old_start: u32, old_count: u32, new_start: u32, new_count: u32) -> HunkKey {
        HunkKey {
            old_start,
            old_count,
            new_start,
            new_count,
        }
    }

    fn keys_from_wire(
        keys: Option<flatbuffers::Vector<'_, flatbuffers::ForwardsUOffset<fbs::HunkKey<'_>>>>,
    ) -> Vec<HunkKey> {
        keys.expect("sections always present")
            .iter()
            .map(|k| key(k.old_start(), k.old_count(), k.new_start(), k.new_count()))
            .collect()
    }

    fn line_from_wire(line: fbs::HunkLine<'_>) -> HunkLine {
        let ctors: [fn(String) -> HunkLine; 3] = [HunkLine::Context, HunkLine::Removed, HunkLine::Added];
        ctors[usize::from(line.kind().0)](line.text().expect("text present").to_owned())
    }

    fn hunk_from_wire(h: fbs::Hunk<'_>) -> Hunk {
        Hunk {
            before_range: h.before_start()..h.before_end(),
            after_range: h.after_start()..h.after_end(),
            symbol: h.symbol().map(ToOwned::to_owned),
            sections: keys_from_wire(h.sections()),
            removed: h.removed(),
            added: h.added(),
            lines: h
                .lines()
                .expect("lines always present")
                .iter()
                .map(line_from_wire)
                .collect(),
        }
    }

    fn kind_from_wire(kind: fbs::ChangeKind, from_path: Option<&str>) -> ChangeKind {
        let from = || PathBuf::from(from_path.expect("from_path present for a copy"));
        match kind {
            fbs::ChangeKind::Added => ChangeKind::Added,
            fbs::ChangeKind::Modified => ChangeKind::Modified,
            fbs::ChangeKind::Removed => ChangeKind::Removed,
            fbs::ChangeKind::Renamed => ChangeKind::Renamed { from: from() },
            _ => ChangeKind::Copied { from: from() },
        }
    }

    /// Map a `Diff` envelope back into the `diff` shape, through the generated accessors.
    fn diff_from_wire(bytes: &[u8]) -> RevisionDiff {
        let env = verified_envelope(bytes);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Diff);
        let diff = env.data_as_diff().expect("Diff payload");
        let files = diff
            .files()
            .expect("files always present")
            .iter()
            .map(|f| {
                let kind = kind_from_wire(f.kind(), f.from_path());
                if matches!(kind, ChangeKind::Added | ChangeKind::Modified | ChangeKind::Removed) {
                    assert_eq!(f.from_path(), None, "from_path only for a copy");
                }
                FileDiff {
                    path: f.path().expect("path present").to_owned(),
                    kind,
                    binary: f.binary(),
                    mode_change: f.mode_change(),
                    sections: keys_from_wire(f.sections()),
                    hunks: f
                        .hunks()
                        .expect("hunks always present")
                        .iter()
                        .map(hunk_from_wire)
                        .collect(),
                    removed: f.removed(),
                    added: f.added(),
                    fingerprint: f.fingerprint().expect("fingerprint present").to_owned(),
                }
            })
            .collect();
        RevisionDiff {
            operation_id: OperationId(diff.operation_id().expect("operation_id present").to_owned()),
            commit_id: CommitId(diff.commit_id().expect("commit_id present").to_owned()),
            from_commit_id: diff.from_commit_id().map(|id| CommitId(id.to_owned())),
            files,
        }
    }

    fn pinned(files: Vec<FileDiff>) -> RevisionDiff {
        RevisionDiff {
            operation_id: OperationId("aa".repeat(64)),
            commit_id: CommitId("cc".repeat(20)),
            from_commit_id: None,
            files,
        }
    }

    fn file(path: &str, kind: ChangeKind) -> FileDiff {
        FileDiff {
            path: path.into(),
            kind,
            binary: false,
            mode_change: false,
            sections: vec![],
            hunks: vec![],
            removed: 0,
            added: 0,
            fingerprint: "f0".into(),
        }
    }

    fn sample() -> RevisionDiff {
        pinned(vec![
            FileDiff {
                path: "src/a.rs".into(),
                kind: ChangeKind::Modified,
                removed: 3,
                added: 7,
                fingerprint: "0123abcd".into(),
                binary: false,
                mode_change: false,
                sections: vec![key(1, 2, 1, 3), key(9, 1, 10, 0), key(20, 0, 20, 4)],
                hunks: vec![
                    Hunk {
                        before_range: 0..5,
                        after_range: 0..6,
                        symbol: Some("fn main() {".into()),
                        sections: vec![key(1, 2, 1, 3)],
                        removed: 2,
                        added: 3,
                        lines: vec![
                            HunkLine::Context("fn main() {\n".into()),
                            HunkLine::Removed("    a();\n".into()),
                            HunkLine::Removed("    b();\n".into()),
                            HunkLine::Added("    c();\n".into()),
                            HunkLine::Added("    d();\n".into()),
                            HunkLine::Added("    e();\n".into()),
                            HunkLine::Context("}\n".into()),
                        ],
                    },
                    Hunk {
                        before_range: 7..12,
                        after_range: 8..24,
                        symbol: None,
                        sections: vec![key(9, 1, 10, 0), key(20, 0, 20, 4)],
                        removed: 1,
                        added: 4,
                        lines: vec![
                            HunkLine::Context("x\n".into()),
                            HunkLine::Removed("y\n".into()),
                            HunkLine::Added("z1\n".into()),
                            HunkLine::Added("z2\n".into()),
                            HunkLine::Added("z3\n".into()),
                            HunkLine::Added("no newline".into()),
                        ],
                    },
                ],
            },
            FileDiff {
                binary: true,
                ..file("bin.dat", ChangeKind::Added)
            },
            FileDiff {
                mode_change: true,
                ..file("run.sh", ChangeKind::Removed)
            },
            file(
                "new.txt",
                ChangeKind::Renamed {
                    from: PathBuf::from("old.txt"),
                },
            ),
            file(
                "copy.txt",
                ChangeKind::Copied {
                    from: PathBuf::from("src.txt"),
                },
            ),
        ])
    }

    #[test]
    fn a_diff_round_trips_through_the_generated_accessors() {
        let diff = sample();
        let bytes = diff_to_envelope(&diff, &CallReport::default());
        assert_eq!(diff_from_wire(&bytes), diff);
        let env = verified_envelope(&bytes);
        assert!(env.warnings().is_none());
        assert!(env.precondition().is_none());
        assert_eq!(env.data_as_diff().expect("Diff payload").from_commit_id(), None);
        let from_to = RevisionDiff {
            from_commit_id: Some(CommitId("dd".repeat(20))),
            ..sample()
        };
        assert_eq!(
            diff_from_wire(&diff_to_envelope(&from_to, &CallReport::default())),
            from_to
        );
    }

    #[test]
    fn an_empty_diff_writes_an_empty_files_vector() {
        let bytes = diff_to_envelope(&pinned(vec![]), &CallReport::default());
        let env = verified_envelope(&bytes);
        assert!(env.ok());
        let files = env
            .data_as_diff()
            .expect("Diff payload")
            .files()
            .expect("files present");
        assert!(files.is_empty());
    }

    #[test]
    fn the_call_report_rides_the_diff_envelope() {
        let bytes = diff_to_envelope(
            &sample(),
            &CallReport::warnings(vec![zanshin_jj::Warning {
                kind: zanshin_jj::WarningKind::ConfigDeprecated,
                message: "Deprecated user-level config: d".into(),
            }]),
        );
        let env = verified_envelope(&bytes);
        let warning = env.warnings().expect("warnings present").get(0);
        assert_eq!(
            (warning.code(), warning.message()),
            (Some("jj.config_deprecated"), Some("Deprecated user-level config: d"))
        );
        assert_eq!(diff_from_wire(&bytes), sample());
    }

    /// One `DiffRequest`: `kind`, `revision`, `from`, `to`, `paths`, `context`, `whitespace`,
    /// `summary`.
    struct Request<'a> {
        kind: fbs::RequestKind,
        revision: Option<&'a str>,
        from: Option<&'a str>,
        to: Option<&'a str>,
        paths: Option<&'a [&'a str]>,
        context: Option<u32>,
        whitespace: fbs::DiffWhitespace,
        summary: bool,
    }

    impl Default for Request<'_> {
        fn default() -> Self {
            Self {
                kind: fbs::RequestKind::Diff,
                revision: None,
                from: None,
                to: None,
                paths: None,
                context: None,
                whitespace: fbs::DiffWhitespace::Exact,
                summary: false,
            }
        }
    }

    fn read(r: &Request<'_>) -> Result<zanshin_jj::DiffOptions, crate::envelope::FfiErrorObj> {
        let mut b = flatbuffers::FlatBufferBuilder::with_capacity(256);
        let paths = r.paths.map(|paths| {
            let paths: Vec<_> = paths.iter().map(|p| b.create_string(p)).collect();
            b.create_vector(&paths)
        });
        let revision = r.revision.map(|s| b.create_string(s));
        let from = r.from.map(|s| b.create_string(s));
        let to = r.to.map(|s| b.create_string(s));
        let context = r.context.map(fbs::DiffContext::new);
        let req = fbs::DiffRequest::create(
            &mut b,
            &fbs::DiffRequestArgs {
                kind: r.kind,
                revision,
                from,
                to,
                paths,
                context: context.as_ref(),
                whitespace: r.whitespace,
                summary: r.summary,
            },
        );
        b.finish(req, None);
        let bytes = b.finished_data();
        super::read_diff_request(bytes.as_ptr(), bytes.len())
    }

    fn rev(text: &str) -> String {
        text.to_owned()
    }

    /// An empty request is `DiffOptions::default()`; every field reaches its option.
    #[test]
    fn the_reader_reads_every_field() {
        use zanshin_jj::{DiffOptions, DiffRevisions, Whitespace};
        assert_eq!(read(&Request::default()).expect("valid"), DiffOptions::default());
        let options = read(&Request {
            revision: Some("rev"),
            paths: Some(&["a", "b/c"]),
            context: Some(0),
            whitespace: fbs::DiffWhitespace::IgnoreAllSpace,
            summary: true,
            ..Request::default()
        })
        .expect("valid");
        assert_eq!(
            options,
            DiffOptions {
                revisions: DiffRevisions::Revision(Some(rev("rev"))),
                paths: vec!["a".into(), "b/c".into()],
                context: Some(0),
                whitespace: Whitespace::IgnoreAllSpace,
                summary: true,
            }
        );
        let ws = |whitespace| {
            read(&Request {
                whitespace,
                ..Request::default()
            })
            .map(|o| o.whitespace)
        };
        assert_eq!(ws(fbs::DiffWhitespace::Exact).expect("valid"), Whitespace::Exact);
        assert_eq!(
            ws(fbs::DiffWhitespace::IgnoreSpaceChange).expect("valid"),
            Whitespace::IgnoreSpaceChange
        );
    }

    /// `from` or `to` selects the from/to form, the absent side `@`.
    #[test]
    fn from_or_to_selects_the_from_to_form() {
        use zanshin_jj::DiffRevisions;
        let revisions = |from, to| {
            read(&Request {
                from,
                to,
                ..Request::default()
            })
            .expect("valid")
            .revisions
        };
        assert_eq!(
            revisions(Some("a"), Some("c")),
            DiffRevisions::FromTo {
                from: Some(rev("a")),
                to: Some(rev("c")),
            }
        );
        assert_eq!(
            revisions(None, Some("c")),
            DiffRevisions::FromTo {
                from: None,
                to: Some(rev("c")),
            }
        );
        assert_eq!(
            revisions(Some("a"), None),
            DiffRevisions::FromTo {
                from: Some(rev("a")),
                to: None,
            }
        );
    }

    /// `revision` with `from` or `to` refuses `jj.invalid_input`; another kind and an unknown
    /// whitespace `ffi.invalid_argument`.
    #[test]
    fn the_reader_refuses_conflicts_another_kind_and_an_unknown_whitespace() {
        use crate::envelope::{FFI_INVALID_ARGUMENT, JJ_INVALID_INPUT};
        for (from, to) in [(Some("a"), None), (None, Some("c"))] {
            let err = read(&Request {
                revision: Some("r"),
                from,
                to,
                ..Request::default()
            })
            .expect_err("conflict");
            assert_eq!(err.code, JJ_INVALID_INPUT);
        }
        let err = read(&Request {
            kind: fbs::RequestKind::SelectTree,
            ..Request::default()
        })
        .expect_err("wrong kind");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
        let err = read(&Request {
            whitespace: fbs::DiffWhitespace(200),
            ..Request::default()
        })
        .expect_err("unknown whitespace");
        assert_eq!(err.code, FFI_INVALID_ARGUMENT);
    }
}

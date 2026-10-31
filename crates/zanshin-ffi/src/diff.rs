// SPDX-License-Identifier: MIT

//! The line-level `Diff` payload (Story 5.5): `zanshin_jj::Repo::diff`'s files, hunks, lines,
//! section keys and pins (Story 5.6) on the FFI wire. Story 5.8 adds this noun's `zanshin_diff_*`
//! externs.

use flatbuffers::{FlatBufferBuilder, ForwardsUOffset, Vector, WIPOffset};
use zanshin_jj::{FileDiff, Hunk, HunkKey, HunkLine, RevisionDiff};

use crate::envelope::{finish_envelope, CallReport};
use crate::fbs;
use crate::status::change_kind_offset;

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
}

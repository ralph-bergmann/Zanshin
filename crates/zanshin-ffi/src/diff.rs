// SPDX-License-Identifier: MIT

//! The line-level `Diff` payload (Story 5.5): `zanshin_jj::Repo::compute_hunks`' files, hunks,
//! lines and section keys on the FFI wire. Story 5.8 adds this noun's `zanshin_diff_*` externs.

use flatbuffers::{FlatBufferBuilder, ForwardsUOffset, Vector, WIPOffset};
use zanshin_jj::{FileDiff, Hunk, HunkKey, HunkLine};

use crate::envelope::{finish_envelope, CallReport};
use crate::fbs;

/// Build a success `Envelope` with a `Diff` payload and return the finished buffer: the files
/// exactly as `compute_hunks` returned them, in order, every vector written (empty, not absent),
/// a `None` symbol absent. `report` rides as on every envelope.
#[must_use]
pub fn diff_to_envelope(files: &[FileDiff], report: &CallReport) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let files: Vec<_> = files.iter().map(|f| file_offset(&mut b, f)).collect();
    let files = b.create_vector(&files);
    let diff = fbs::Diff::create(&mut b, &fbs::DiffArgs { files: Some(files) });
    finish_envelope(b, fbs::Payload::Diff, Some(diff.as_union_value()), report)
}

fn file_offset<'b>(b: &mut FlatBufferBuilder<'b>, f: &FileDiff) -> WIPOffset<fbs::FileDiff<'b>> {
    let path = b.create_string(&f.path);
    let sections = keys_vector(b, &f.sections);
    let hunks: Vec<_> = f.hunks.iter().map(|h| hunk_offset(b, h)).collect();
    let hunks = b.create_vector(&hunks);
    fbs::FileDiff::create(
        b,
        &fbs::FileDiffArgs {
            path: Some(path),
            binary: f.binary,
            mode_change: f.mode_change,
            sections: Some(sections),
            hunks: Some(hunks),
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
    use flatbuffers::VerifierOptions;
    use zanshin_jj::{FileDiff, Hunk, HunkKey, HunkLine};

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

    /// Map a `Diff` envelope back into the `compute_hunks` shape, through the generated accessors.
    fn files_from_wire(bytes: &[u8]) -> Vec<FileDiff> {
        let env = verified_envelope(bytes);
        assert!(env.ok());
        assert_eq!(env.data_type(), fbs::Payload::Diff);
        env.data_as_diff()
            .expect("Diff payload")
            .files()
            .expect("files always present")
            .iter()
            .map(|f| FileDiff {
                path: f.path().expect("path present").to_owned(),
                binary: f.binary(),
                mode_change: f.mode_change(),
                sections: keys_from_wire(f.sections()),
                hunks: f
                    .hunks()
                    .expect("hunks always present")
                    .iter()
                    .map(hunk_from_wire)
                    .collect(),
            })
            .collect()
    }

    fn sample() -> Vec<FileDiff> {
        vec![
            FileDiff {
                path: "src/a.rs".into(),
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
                path: "bin.dat".into(),
                binary: true,
                mode_change: false,
                sections: vec![],
                hunks: vec![],
            },
            FileDiff {
                path: "run.sh".into(),
                binary: false,
                mode_change: true,
                sections: vec![],
                hunks: vec![],
            },
        ]
    }

    #[test]
    fn a_diff_round_trips_through_the_generated_accessors() {
        let files = sample();
        let bytes = diff_to_envelope(&files, &CallReport::default());
        assert_eq!(files_from_wire(&bytes), files);
        let env = verified_envelope(&bytes);
        assert!(env.warnings().is_none());
        assert!(env.precondition().is_none());
    }

    #[test]
    fn an_empty_diff_writes_an_empty_files_vector() {
        let bytes = diff_to_envelope(&[], &CallReport::default());
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
        assert_eq!(files_from_wire(&bytes), sample());
    }
}

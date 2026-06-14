// SPDX-License-Identifier: Apache-2.0
//
// FlatBuffers serialization of the synthetic models — the candidate transport.
// Children (strings, scalar vectors, nested tables) are built first, then their
// offsets are collected into the parent vector, matching FlatBuffers' bottom-up
// build order.

use crate::generated::zanshin::bench as fbs;
use crate::model::{Diff, GraphSlice};
use flatbuffers::FlatBufferBuilder;

#[must_use]
pub fn to_fb_graph(model: &GraphSlice) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1 << 20);

    let node_offsets: Vec<_> = model
        .nodes
        .iter()
        .map(|n| {
            let change_id = b.create_string(&n.change_id);
            let commit_id = b.create_string(&n.commit_id);
            let summary = b.create_string(&n.summary);
            let parents = b.create_vector(&n.parents);
            fbs::GraphNode::create(
                &mut b,
                &fbs::GraphNodeArgs {
                    row: n.row,
                    lane: n.lane,
                    color: n.color,
                    change_id: Some(change_id),
                    commit_id: Some(commit_id),
                    parents: Some(parents),
                    is_working_copy: n.is_working_copy,
                    is_immutable: n.is_immutable,
                    summary: Some(summary),
                },
            )
        })
        .collect();

    let nodes = b.create_vector(&node_offsets);
    let slice = fbs::GraphSlice::create(&mut b, &fbs::GraphSliceArgs { nodes: Some(nodes) });
    b.finish(slice, None);
    b.finished_data().to_vec()
}

#[must_use]
pub fn to_fb_diff(model: &Diff) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1 << 20);

    let file_offsets: Vec<_> = model
        .files
        .iter()
        .map(|f| {
            let hunk_offsets: Vec<_> = f
                .hunks
                .iter()
                .map(|h| {
                    let line_offsets: Vec<_> = h
                        .lines
                        .iter()
                        .map(|l| {
                            let content = b.create_string(&l.content);
                            fbs::DiffLine::create(
                                &mut b,
                                &fbs::DiffLineArgs {
                                    origin: fbs::LineOrigin(l.origin as i8),
                                    old_lineno: l.old_lineno,
                                    new_lineno: l.new_lineno,
                                    content: Some(content),
                                },
                            )
                        })
                        .collect();
                    let lines = b.create_vector(&line_offsets);
                    let header = b.create_string(&h.header);
                    fbs::DiffHunk::create(
                        &mut b,
                        &fbs::DiffHunkArgs {
                            old_start: h.old_start,
                            old_lines: h.old_lines,
                            new_start: h.new_start,
                            new_lines: h.new_lines,
                            header: Some(header),
                            lines: Some(lines),
                        },
                    )
                })
                .collect();
            let hunks = b.create_vector(&hunk_offsets);
            let path = b.create_string(&f.path);
            let old_path = b.create_string(&f.old_path);
            fbs::DiffFile::create(
                &mut b,
                &fbs::DiffFileArgs {
                    path: Some(path),
                    old_path: Some(old_path),
                    status: fbs::FileStatus(f.status as i8),
                    hunks: Some(hunks),
                },
            )
        })
        .collect();

    let files = b.create_vector(&file_offsets);
    let diff = fbs::Diff::create(&mut b, &fbs::DiffArgs { files: Some(files) });
    b.finish(diff, None);
    b.finished_data().to_vec()
}

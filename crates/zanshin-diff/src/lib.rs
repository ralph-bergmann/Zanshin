// SPDX-License-Identifier: MIT

//! Enrichment of `zanshin-jj`'s line-level diff (Epic 5): pure text algorithms over its lines, with
//! no jj-lib and no `extern "C"`. Story 5.2 adds the word-level segments of every diff line.

mod word_diff;

pub use word_diff::{compute_word_diff, line_segments, Segment, SegmentKind};

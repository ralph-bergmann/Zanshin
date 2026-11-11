// SPDX-License-Identifier: MIT

//! Enrichment of `zanshin-jj`'s line-level diff (Epic 5): pure text algorithms over its lines, with
//! no jj-lib and no `extern "C"`. Story 5.2 adds the word-level segments of every diff line, Story
//! 5.3 their syntax classes, and Story 5.4 the grammars and the language detection behind them.

mod grammars;
mod highlight;
mod word_diff;

pub use grammars::{detect_language, Language};
pub use highlight::{highlight_line, merge_highlight, HighlightedSegment, HighlightedToken, SyntaxClass};
pub use word_diff::{compute_word_diff, line_segments, Segment, SegmentKind};

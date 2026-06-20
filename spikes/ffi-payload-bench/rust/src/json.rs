// SPDX-License-Identifier: MIT
//
// JSON serialization of the synthetic models — the current AD-1 transport.

use crate::model::{Diff, GraphSlice};

#[must_use]
pub fn to_json_graph(model: &GraphSlice) -> Vec<u8> {
    serde_json::to_vec(model).expect("graph model serializes to JSON")
}

#[must_use]
pub fn to_json_diff(model: &Diff) -> Vec<u8> {
    serde_json::to_vec(model).expect("diff model serializes to JSON")
}

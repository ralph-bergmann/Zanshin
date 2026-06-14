// SPDX-License-Identifier: Apache-2.0

//! `zanshin-jj` — anti-corruption layer over `jj-lib`.
//!
//! Exposes a stable, `jj_lib`-type-free API for opening, initialising, and
//! cloning jj workspaces.  All `jj_lib` types are absorbed inside this crate;
//! none appear in any public signature (FR-JJ-16).

mod repo;

pub use repo::{Backend, Repo, RepoError};

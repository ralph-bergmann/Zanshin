// SPDX-License-Identifier: MIT

//! `zanshin-jj` — anti-corruption layer over `jj-lib`.
//!
//! Exposes a stable, `jj_lib`-type-free API for opening, initialising, and
//! cloning jj workspaces.  All `jj_lib` types are absorbed inside this crate;
//! none appear in any public signature (FR-JJ-16).

mod repo;
pub(crate) mod status;

pub use repo::{Backend, Repo, RepoError};
pub use status::{ChangeId, ChangeKind, FileChange, Status, StatusError};

// SPDX-License-Identifier: MIT

//! `zanshin-jj` — anti-corruption layer over `jj-lib`.
//!
//! Exposes a stable, `jj_lib`-type-free API for opening, initialising, and
//! cloning jj workspaces.  All `jj_lib` types are absorbed inside this crate;
//! none appear in any public signature (FR-JJ-16).

pub(crate) mod change;
mod repo;
pub(crate) mod revset;
pub(crate) mod status;

pub use change::{Change, ChangeError, CommitId, ConflictState, Signature, Timestamp, Timestamps};
pub use repo::{Backend, Repo, RepoError};
pub use revset::{resolve_revset, RevsetError};
pub use status::{ChangeId, ChangeKind, FileChange, Status, StatusError};

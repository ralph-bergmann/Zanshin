// SPDX-License-Identifier: MIT

//! `jj log`-parity display metadata for one commit row (Story 4.8).
//!
//! [`LogMetaIndex`] is built ONCE per graph walk from the head-resolved repo (the refs
//! reverse indexes, the working-copy map, the shortest-prefix index and the immutable
//! containment closure) and then answers [`LogMetaIndex::extract`] per node in amortized
//! O(1) — no revset is ever evaluated per row. Field semantics mirror
//! `cli/src/commit_templater.rs` at v0.42.0 (NFR-R-2): content parity only, never the
//! CLI's glyphs, colors or layout.
//!
//! Since Story 4.10 the extraction is split along "index/View-derived" vs "object-derived":
//! [`LogMetaIndex::view_half`] needs no commit object (the topology call's
//! [`crate::TopologyMeta`]), [`object_half`] needs the loaded commit (the content call's
//! [`crate::CommitContent`]), and [`LogMetaIndex::extract`] composes both into `walk_graph`'s
//! [`CommitMeta`] — one extraction path per half.

use std::collections::HashMap;

use jj_lib::backend::{ChangeId as JjChangeId, CommitId as JjCommitId};
use jj_lib::commit::Commit;
use jj_lib::id_prefix::IdPrefixIndex;
use jj_lib::object_id::ObjectId;
use jj_lib::op_store::LocalRemoteRefTarget;
use jj_lib::ref_name::{RefName, WorkspaceName};
use jj_lib::revset::RevsetContainingFn;

use crate::{CommitContent, CommitId, RevsetError, Timestamp, TopologyMeta};

/// One bookmark or tag entry attached to a commit row.
///
/// Mirrors the CLI's `CommitRef` template type (`cli/src/commit_templater.rs:1543`)
/// reduced to the fields the log row renders: the CLI writes `name`, then `@remote` for a
/// remote entry, then `??` when `conflicted` or `*` when a local entry is not `synced`.
/// Which glyph (if any) is drawn stays the UI's decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitRef {
    /// Bookmark or tag name (UTF-8).
    pub name: String,
    /// The remote this entry belongs to, or `None` for the local entry.
    pub remote: Option<String>,
    /// Local entry: every tracking remote agrees with the local target. Remote entry:
    /// the remote is tracked AND agrees with the local target.
    pub synced: bool,
    /// This entry's ref target is a conflict (more than one added commit).
    pub conflicted: bool,
}

/// `jj log`-parity display metadata for one commit (Story 4.8).
///
/// Extracted inside the same head-resolved snapshot as the graph row it travels with
/// (ADR-0002) — the whole row is one atomic view of the repo. Ids are full;
/// `*_prefix_len` are the shortest-unique-prefix lengths the UI highlights. *(2026-10-01,
/// Story 4.12: it travelled with the lane crate's rows on the removed slice wire; it is
/// [`crate::Repo::walk_graph`]'s row metadata.)*
// WHY(clippy::struct_excessive_bools): the flags are the CLI's template keywords —
// independent predicates that are simultaneously true or false for one commit (an
// immutable working copy is both), mapped 1:1 onto the `jj log` row's fields. The
// lint's remedies (a state machine, two-variant enums) can only express one-of-N, so
// applying them would lose information the UI needs; grouping them into sub-structs would
// re-trip the same lint one level down while adding nesting to every consumer.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitMeta {
    /// Change id in jj reverse-hex display form (divergent changes share it, which is
    /// why rows stay keyed by commit id).
    pub change_id: String,
    /// Shortest unique prefix length of [`Self::change_id`], within the
    /// `short_prefixes` disambiguation set (or the full index when disabled).
    pub change_id_prefix_len: u32,
    /// Shortest unique prefix length of the row's commit id, same scoping.
    pub commit_id_prefix_len: u32,
    /// Index of this commit among the commits sharing its change id, when jj-lib yields
    /// one. The CLI renders it (`/<offset>`) only for hidden/divergent commits — that is
    /// a UI decision reproducible from the flags below.
    pub change_offset: Option<u32>,
    /// Author name; may be empty (jj allows it).
    pub author_name: String,
    /// Author email; may be empty (jj allows it).
    pub author_email: String,
    /// The **committer** timestamp — what `jj log`'s compact template shows.
    pub committer_timestamp: Timestamp,
    /// Bookmarks pointing at this commit, CLI-filtered (see [`CommitRef`]).
    pub bookmarks: Vec<CommitRef>,
    /// Tags pointing at this commit, same shape and filter.
    pub tags: Vec<CommitRef>,
    /// Names of the workspaces whose working-copy commit this is. Always empty in a
    /// single-workspace repo (the CLI's guard), including for this workspace's own `@`.
    pub working_copies: Vec<String>,
    /// This workspace's `@`.
    pub working_copy: bool,
    /// Contained in `::(immutable_heads() | root())`.
    pub immutable: bool,
    /// The commit's tree has unresolved conflicts.
    pub conflict: bool,
    /// The tree equals the merged parent trees (description is not considered).
    pub empty: bool,
    /// The commit is not visible (reachable only when the revset names hidden ids).
    pub hidden: bool,
    /// The change id resolves to more than one visible commit.
    pub divergent: bool,
    /// The repository's root commit.
    pub root: bool,
    /// First line of the description; `""` when the description is empty (jj stores
    /// `""` — the "(no description set)" placeholder is UI text).
    pub description_first_line: String,
}

/// Converts any jj-lib error to [`RevsetError::JjLibError`].
fn jj<E: std::fmt::Display>(e: E) -> RevsetError {
    RevsetError::JjLibError(e.to_string())
}

/// Commit-id hex → the refs pointing at it.
type RefsByCommit = HashMap<String, Vec<CommitRef>>;

/// Per-walk index bundle: everything [`LogMetaIndex::extract`] needs that would otherwise
/// cost a repo scan per row.
pub(crate) struct LogMetaIndex<'a> {
    bookmarks: RefsByCommit,
    tags: RefsByCommit,
    /// Only populated in a multi-workspace repo (the CLI's `extract_working_copies` guard).
    working_copies: HashMap<String, Vec<String>>,
    current_wc_commit: Option<String>,
    root_commit_id: String,
    prefixes: IdPrefixIndex<'a>,
    immutable: Box<RevsetContainingFn<'a>>,
}

impl<'a> LogMetaIndex<'a> {
    /// Builds the per-walk indexes from the head-resolved `repo_dyn`.
    ///
    /// `prefixes` and `immutable` are built by the caller because both borrow locals that
    /// must outlive this index (the `IdPrefixContext` and the immutable revset).
    pub(crate) fn new(
        repo_dyn: &dyn jj_lib::repo::Repo,
        workspace_name: &WorkspaceName,
        prefixes: IdPrefixIndex<'a>,
        immutable: Box<RevsetContainingFn<'a>>,
    ) -> Self {
        let view = repo_dyn.view();
        let wc_commit_ids = view.wc_commit_ids();
        // The CLI hides workspace markers entirely in a single-workspace repo.
        let working_copies = if wc_commit_ids.len() > 1 {
            let mut map: HashMap<String, Vec<String>> = HashMap::new();
            for (name, commit_id) in wc_commit_ids {
                map.entry(commit_id.hex()).or_default().push(name.as_str().to_owned());
            }
            map
        } else {
            HashMap::new()
        };
        Self {
            bookmarks: build_refs_index(view.bookmarks()),
            tags: build_refs_index(view.tags()),
            working_copies,
            current_wc_commit: view.get_wc_commit_id(workspace_name).map(ObjectId::hex),
            root_commit_id: repo_dyn.store().root_commit_id().hex(),
            prefixes,
            immutable,
        }
    }

    /// Extracts one commit's `jj log`-parity metadata: [`Self::view_half`] and
    /// [`object_half`] composed (Story 4.10 — one extraction path per half).
    ///
    /// # Errors
    ///
    /// - [`RevsetError::JjLibError`] — a change-id resolution, prefix lookup, immutable
    ///   containment check, or emptiness check failed in jj-lib.
    pub(crate) fn extract(
        &self,
        repo_dyn: &dyn jj_lib::repo::Repo,
        commit: &Commit,
    ) -> Result<CommitMeta, RevsetError> {
        let parent_count = u32::try_from(commit.parent_ids().len()).unwrap_or(u32::MAX);
        let view = self.view_half(repo_dyn, commit.id(), commit.change_id(), parent_count)?;
        let object = object_half(repo_dyn, commit).map_err(jj)?;
        Ok(CommitMeta::from_halves(view, object))
    }

    /// Extracts the VIEW half of one commit's metadata (Story 4.10): everything the index and
    /// the operation's View answer, so no commit object is needed. `parent_count` is the
    /// caller's, since the index-only way to learn it is a per-call filter pass
    /// ([`crate::topology`]).
    ///
    /// # Errors
    ///
    /// - [`RevsetError::JjLibError`] — a change-id resolution, prefix lookup or immutable
    ///   containment check failed in jj-lib.
    pub(crate) fn view_half(
        &self,
        repo_dyn: &dyn jj_lib::repo::Repo,
        commit_id: &JjCommitId,
        change_id: &JjChangeId,
        parent_count: u32,
    ) -> Result<TopologyMeta, RevsetError> {
        let id_hex = commit_id.hex();

        // One resolve_change_id for all three change-identity facts (the CLI computes
        // them in three separate template keywords; one lookup is the same answer).
        let targets = pollster::block_on(repo_dyn.resolve_change_id(change_id)).map_err(jj)?;
        let hidden = targets.as_ref().is_none_or(|t| !t.has_visible(commit_id));
        let divergent = targets
            .as_ref()
            .is_some_and(jj_lib::index::ResolvedChangeTargets::is_divergent);
        let change_offset = targets
            .as_ref()
            .and_then(|t| t.find_offset(commit_id))
            .and_then(|offset| u32::try_from(offset).ok());
        // jj 0.46 made the change-id half of the prefix lookup async (the commit-id half is not).
        let change_prefix_len = pollster::block_on(self.prefixes.shortest_change_prefix_len(repo_dyn, change_id));

        Ok(TopologyMeta {
            change_id: change_id.reverse_hex(),
            change_id_prefix_len: prefix_len(change_prefix_len)?,
            commit_id_prefix_len: prefix_len(self.prefixes.shortest_commit_prefix_len(repo_dyn, commit_id))?,
            change_offset,
            bookmarks: self.bookmarks.get(&id_hex).cloned().unwrap_or_default(),
            tags: self.tags.get(&id_hex).cloned().unwrap_or_default(),
            working_copies: self.working_copies.get(&id_hex).cloned().unwrap_or_default(),
            working_copy: self.current_wc_commit.as_deref() == Some(id_hex.as_str()),
            // WHY: jj 0.44 made `RevsetContainingFn` async (it returns a `LocalBoxFuture`);
            // pollster drives it here exactly as `is_empty` in `object_half`, keeping the
            // crate's public API sync (project-context § zanshin-jj).
            immutable: pollster::block_on((self.immutable)(commit_id)).map_err(jj)?,
            hidden,
            divergent,
            root: id_hex == self.root_commit_id,
            parent_count,
        })
    }
}

/// Extracts the OBJECT half of one commit's metadata (Story 4.10): what only the loaded commit
/// answers — author, committer timestamp, full description, conflict and emptiness. `empty` is
/// the one field that may load more (`Commit::is_empty` asks the changed-path index first, and
/// otherwise loads the parents and merges their trees).
///
/// # Errors
///
/// - The jj-lib backend error of the emptiness check (a parent that cannot be loaded).
pub(crate) fn object_half(
    repo_dyn: &dyn jj_lib::repo::Repo,
    commit: &Commit,
) -> jj_lib::backend::BackendResult<CommitContent> {
    let author = commit.author();
    let committer = commit.committer();
    Ok(CommitContent {
        commit_id: CommitId(commit.id().hex()),
        author_name: author.name.clone(),
        author_email: author.email.clone(),
        committer_timestamp: Timestamp {
            millis_since_epoch: committer.timestamp.timestamp.0,
            tz_offset_minutes: committer.timestamp.tz_offset,
        },
        description: commit.description().to_owned(),
        conflict: commit.has_conflict(),
        // WHY: `Commit::is_empty` is jj-lib's only emptiness check and it is async;
        // pollster drives it here exactly as the rest of this crate drives jj-lib's
        // futures (the crate's public API stays sync — project-context § zanshin-jj).
        empty: pollster::block_on(commit.is_empty(repo_dyn))?,
    })
}

impl CommitMeta {
    /// Composes the `jj log` row from its two halves; `description_first_line` is the first
    /// line of the full description (`""` when it is empty), and the view half's
    /// `parent_count` is not part of the row.
    fn from_halves(view: TopologyMeta, object: CommitContent) -> Self {
        let description_first_line = object.description.lines().next().unwrap_or_default().to_owned();
        Self {
            change_id: view.change_id,
            change_id_prefix_len: view.change_id_prefix_len,
            commit_id_prefix_len: view.commit_id_prefix_len,
            change_offset: view.change_offset,
            author_name: object.author_name,
            author_email: object.author_email,
            committer_timestamp: object.committer_timestamp,
            bookmarks: view.bookmarks,
            tags: view.tags,
            working_copies: view.working_copies,
            working_copy: view.working_copy,
            immutable: view.immutable,
            conflict: object.conflict,
            empty: object.empty,
            hidden: view.hidden,
            divergent: view.divergent,
            root: view.root,
            description_first_line,
        }
    }
}

/// Narrows a jj-lib prefix length to the wire's `u32`.
pub(crate) fn prefix_len<E: std::fmt::Display>(len: Result<usize, E>) -> Result<u32, RevsetError> {
    let len = len.map_err(jj)?;
    // A hex id is at most 64 chars, so this conversion cannot fail in practice; a
    // saturating fallback keeps the row renderable instead of failing the whole call.
    Ok(u32::try_from(len).unwrap_or(u32::MAX))
}

/// Builds a commit-id → refs reverse index from `view.bookmarks()` / `view.tags()`.
///
/// Mirrors `build_local_remote_refs_index` + `collect_distinct_refs`
/// (`cli/src/commit_templater.rs:2013-2053`): the local entry is always kept, a remote
/// entry only when it is NOT synced — a tracked-and-synced remote bookmark is simply not
/// part of a `jj log` row (content parity; the unfiltered view is `list_bookmarks`' job).
fn build_refs_index<'v>(refs: impl Iterator<Item = (&'v RefName, LocalRemoteRefTarget<'v>)>) -> RefsByCommit {
    let mut index: RefsByCommit = HashMap::new();
    for (name, target) in refs {
        let local_target = target.local_target;
        if local_target.is_present() {
            let entry = CommitRef {
                name: name.as_str().to_owned(),
                remote: None,
                synced: target
                    .remote_refs
                    .iter()
                    .all(|&(_, remote_ref)| !remote_ref.is_tracked() || remote_ref.target == *local_target),
                conflicted: !local_target.is_resolved(),
            };
            insert_at(&mut index, local_target.present_adds(), &entry);
        }
        for &(remote_name, remote_ref) in &target.remote_refs {
            let synced = remote_ref.is_tracked() && remote_ref.target == *local_target;
            if synced {
                continue; // collect_distinct_refs: `is_local() || !synced`
            }
            let entry = CommitRef {
                name: name.as_str().to_owned(),
                remote: Some(remote_name.as_str().to_owned()),
                synced,
                conflicted: !remote_ref.target.is_resolved(),
            };
            insert_at(&mut index, remote_ref.target.present_adds(), &entry);
        }
    }
    index
}

/// Records `entry` under every commit id the ref target adds (a conflicted target adds
/// more than one).
fn insert_at<'i>(
    index: &mut RefsByCommit,
    ids: impl Iterator<Item = &'i jj_lib::backend::CommitId>,
    entry: &CommitRef,
) {
    for id in ids {
        index.entry(id.hex()).or_default().push(entry.clone());
    }
}

#[cfg(test)]
mod tests {
    use jj_lib::backend::CommitId as JjCommitId;

    use super::{insert_at, prefix_len, CommitRef, RefsByCommit};

    fn entry(name: &str, remote: Option<&str>) -> CommitRef {
        CommitRef {
            name: name.to_owned(),
            remote: remote.map(ToOwned::to_owned),
            synced: false,
            conflicted: false,
        }
    }

    #[test]
    fn insert_at_records_a_conflicted_target_under_every_added_id() {
        let mut index: RefsByCommit = RefsByCommit::new();
        let ids = [JjCommitId::from_hex("aa"), JjCommitId::from_hex("bb")];
        insert_at(&mut index, ids.iter(), &entry("feature", None));
        assert_eq!(index.get("aa").map(Vec::len), Some(1));
        assert_eq!(index.get("bb").map(Vec::len), Some(1));
    }

    #[test]
    fn insert_at_appends_a_second_ref_for_the_same_commit() {
        let mut index: RefsByCommit = RefsByCommit::new();
        let id = [JjCommitId::from_hex("aa")];
        insert_at(&mut index, id.iter(), &entry("feature", None));
        insert_at(&mut index, id.iter(), &entry("feature", Some("origin")));
        let refs = index.get("aa").expect("both entries land on the same commit");
        assert_eq!(refs.len(), 2);
        assert_eq!(refs[0].remote, None);
        assert_eq!(refs[1].remote.as_deref(), Some("origin"));
    }

    #[test]
    fn prefix_len_forwards_a_jj_lib_failure_as_a_jj_lib_error() {
        let err = prefix_len::<&str>(Err("index unreadable"));
        assert!(
            matches!(err, Err(crate::RevsetError::JjLibError(ref reason)) if reason == "index unreadable"),
            "got: {err:?}"
        );
        assert_eq!(prefix_len::<&str>(Ok(3)).ok(), Some(3));
    }
}

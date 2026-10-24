// SPDX-License-Identifier: MIT

//! `arrange.rs` — `jj arrange` without its terminal UI (Story 9.16), ported from `cmd_arrange`
//! (`cli/src/commands/arrange.rs:90-170` @ v0.46.0), its `State` (`:186-413`) and
//! `RewritePlan::execute` (`:431-471`).
//!
//! The CLI opens a ratatui TUI on the target set; the user moves a cursor, swaps the selected
//! commit with its parent or child, marks commits to abandon or keep, and confirms. Here the GUI
//! sends the TUI's own key actions — [`ArrangeAction`] — and they are replayed on a port of the
//! CLI's `State`, so exactly the graphs the TUI can reach are reachable, and nothing else.
//!
//! Divergences, all deliberate:
//!
//! - no TUI: no rendering, no `templates.arrange`, no cursor, scroll or commit order; an action
//!   names its commit by change id instead of by cursor position;
//! - an action naming a change outside the target set refuses [`MutateError::InvalidInput`] — the
//!   TUI's cursor cannot reach one;
//! - "Canceled by user" (`q`) is not ported: the GUI simply does not call.
//!
//! A swap the TUI ignores (not exactly one parent/child, or that one is outside the set) is
//! ignored here too; a call whose actions change nothing writes no operation.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::dag_walk;
use jj_lib::repo::{MutableRepo, Repo as _};
use jj_lib::revset::{ResolvedRevsetExpression, RevsetExpression};
use jj_lib::rewrite::CommitRewriter;
use jj_lib::store::Store;
use jj_lib::transaction::Transaction;
use jj_lib::workspace::Workspace;

use crate::mutate::{
    be, cfg, finish_verb, guard_rewritable, mutation_result, no_op_result, resolve_commit, rev, MutateError,
    MutationResult,
};
use crate::op_support::{resolve_ordered, start_repo_transaction};
use crate::snapshot::VerbContext;
use crate::ChangeId;

/// [`crate::Repo::arrange`]'s arguments (Story 9.16): the CLI's `jj arrange [REVSETS]` and the
/// TUI session the user would have had.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ArrangeOptions {
    /// The revisions to arrange. Empty is the CLI's default, the `revsets.arrange` setting
    /// (jj's default `reachable(@, mutable())`).
    pub revisions: Vec<ChangeId>,
    /// The TUI's key actions, replayed in order on the target set; empty changes nothing.
    pub actions: Vec<ArrangeAction>,
}

/// One of the arrange TUI's key actions (`handle_key_event`, `arrange.rs:555-582` @ v0.46.0),
/// on the commit the cursor would be on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArrangeAction {
    /// `⇧↓`/`J`: swap the commit with its parent — ignored unless it has exactly one parent and
    /// that parent is in the target set.
    SwapDown(ChangeId),
    /// `⇧↑`/`K`: swap the commit with its child — ignored unless it has exactly one child and
    /// that child is in the target set.
    SwapUp(ChangeId),
    /// `a`: abandon the commit.
    Abandon(ChangeId),
    /// `p`: keep the commit (undoes an `Abandon`).
    Keep(ChangeId),
}

/// What happens to a commit when the plan runs — the CLI's `UiAction` / `RewriteAction`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Fate {
    Keep,
    Abandon,
}

/// One commit of the arrangement — the CLI's `CommitState`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct CommitState {
    commit: Commit,
    fate: Fate,
    parents: Vec<CommitId>,
}

/// The CLI's `State` without its UI fields (`current_order`, `current_selection`, `head_order`,
/// `scroll_top`, which only order and scroll the rendering).
#[derive(Debug, Clone, PartialEq, Eq)]
struct State {
    /// The targets, their external children and their external parents.
    commits: HashMap<CommitId, CommitState>,
    external_children: HashSet<CommitId>,
    external_parents: HashSet<CommitId>,
}

impl State {
    /// `State::new` (`arrange.rs:211-271`): every commit keeps its parents; the targets'
    /// parents outside the set are loaded as external parents. `commits` must have no gaps.
    fn new(store: &Arc<Store>, commits: Vec<Commit>, external_children: Vec<Commit>) -> Result<Self, MutateError> {
        let commit_set: HashSet<&CommitId> = commits.iter().map(Commit::id).collect();
        let mut external_parents = HashSet::new();
        for commit in &commits {
            for parent_id in commit.parent_ids() {
                if !commit_set.contains(parent_id) {
                    external_parents.insert(parent_id.clone());
                }
            }
        }
        let external_parent_commits: Vec<Commit> = external_parents
            .iter()
            .map(|id| store.get_commit(id).map_err(be))
            .collect::<Result<_, _>>()?;
        let external_children_ids = external_children.iter().map(|c| c.id().clone()).collect();
        let commits = commits
            .into_iter()
            .chain(external_children)
            .chain(external_parent_commits)
            .map(|commit| {
                let parents = commit.parent_ids().to_vec();
                let state = CommitState {
                    commit,
                    fate: Fate::Keep,
                    parents,
                };
                (state.commit.id().clone(), state)
            })
            .collect();
        Ok(Self {
            commits,
            external_children: external_children_ids,
            external_parents,
        })
    }

    /// `swap_commits` (`arrange.rs:295-339`): `a` and `b` trade places — every reference to one
    /// becomes the other, and they trade their parent lists.
    fn swap_commits(&mut self, a_id: &CommitId, b_id: &CommitId) {
        if a_id == b_id {
            return;
        }
        for commit_state in self.commits.values_mut() {
            for id in &mut commit_state.parents {
                if id == a_id {
                    id.clone_from(b_id);
                } else if id == b_id {
                    id.clone_from(a_id);
                }
            }
        }
        if let [Some(a_state), Some(b_state)] = self.commits.get_disjoint_mut([a_id, b_id]) {
            std::mem::swap(&mut a_state.parents, &mut b_state.parents);
        }
    }

    /// `swap_selection_down` (`arrange.rs:363-376`): swap `id` with its parent; nothing unless it
    /// has exactly one parent and that parent is not external.
    fn swap_down(&mut self, id: &CommitId) {
        let [parent] = self.commits[id].parents.as_slice() else {
            return;
        };
        if self.external_parents.contains(parent) {
            return;
        }
        let parent = parent.clone();
        self.swap_commits(id, &parent);
    }

    /// `swap_selection_up` (`arrange.rs:400-412`): swap `id` with its child; nothing unless it has
    /// exactly one child and that child is not external.
    fn swap_up(&mut self, id: &CommitId) {
        let children: Vec<CommitId> = self
            .commits
            .iter()
            .filter(|(_, state)| state.parents.contains(id))
            .map(|(child, _)| child.clone())
            .collect();
        let [child] = children.as_slice() else {
            return;
        };
        if self.external_children.contains(child) {
            return;
        }
        self.swap_commits(id, child);
    }

    /// The `a` / `p` keys (`arrange.rs:565-572`): `id`'s fate.
    fn set_fate(&mut self, id: &CommitId, fate: Fate) {
        if let Some(state) = self.commits.get_mut(id) {
            state.fate = fate;
        }
    }

    /// `to_rewrite_plan` (`arrange.rs:341-361`): every commit but the external parents, with its
    /// new parents and fate.
    fn to_rewrite_plan(&self) -> RewritePlan {
        let rewrites = self
            .commits
            .iter()
            .filter(|(id, _)| !self.external_parents.contains(*id))
            .map(|(id, state)| {
                let rewrite = Rewrite {
                    old_commit: state.commit.clone(),
                    new_parents: state.parents.clone(),
                    fate: state.fate,
                };
                (id.clone(), rewrite)
            })
            .collect();
        RewritePlan { rewrites }
    }
}

/// One commit's rewrite — the CLI's `Rewrite`.
struct Rewrite {
    old_commit: Commit,
    new_parents: Vec<CommitId>,
    fate: Fate,
}

/// The CLI's `RewritePlan`.
struct RewritePlan {
    rewrites: HashMap<CommitId, Rewrite>,
}

impl RewritePlan {
    /// `RewritePlan::execute` (`arrange.rs:431-471`): the commits in the order their NEW parents
    /// give, each abandoned or — when its parents changed — rebased. Returns the rewritten
    /// commits by old id.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Backend`] — a jj-lib failure, or a cycle in the new parents (the CLI
    ///   panics there; the TUI's swaps cannot create one).
    async fn execute(mut self, mut_repo: &mut MutableRepo) -> Result<HashMap<CommitId, Commit>, MutateError> {
        let ordered = dag_walk::topo_order_forward(
            self.rewrites.keys().cloned(),
            Clone::clone,
            |id| {
                self.rewrites[id]
                    .new_parents
                    .iter()
                    .filter(|parent| self.rewrites.contains_key(parent))
                    .cloned()
                    .collect::<Vec<_>>()
            },
            |_| MutateError::Backend("cycle detected".to_owned()),
        )?;
        let ordered: Vec<(CommitId, Rewrite)> = ordered
            .into_iter()
            .filter_map(|id| self.rewrites.remove_entry(&id))
            .collect();
        let mut rewritten = HashMap::new();
        for (id, rewrite) in ordered {
            let new_parents = mut_repo.new_parents(&rewrite.new_parents);
            let rewriter = CommitRewriter::new(mut_repo, rewrite.old_commit, new_parents);
            match rewrite.fate {
                Fate::Abandon => rewriter.abandon(),
                Fate::Keep if rewriter.parents_changed() => {
                    let new_commit = rewriter.rebase().await.map_err(be)?.write().await.map_err(be)?;
                    rewritten.insert(id, new_commit);
                }
                Fate::Keep => {}
            }
        }
        Ok(rewritten)
    }
}

/// A verb's target set: `revisions`, or — when empty — the revset the config `key` holds,
/// parsed "In revset expression" like a user revset: `revsets.arrange` (`arrange.rs:96-104`),
/// `revsets.fix` (`fix.rs` `cmd_fix` @ v0.46.0, Story 9.9).
///
/// # Errors
///
/// - [`MutateError::ChangeNotFound`] — a revision does not resolve.
/// - [`MutateError::Config`] — `key` is not a string, or the alias tables do not read.
/// - [`MutateError::RevsetParseError`] / [`MutateError::RevsetResolutionError`] — the
///   config's revset does not parse or resolve.
pub(crate) fn target_expression(
    tx: &Transaction,
    workspace: &Workspace,
    ctx: &mut VerbContext,
    revisions: &[ChangeId],
    key: &'static str,
) -> Result<Arc<ResolvedRevsetExpression>, MutateError> {
    if !revisions.is_empty() {
        let ids = resolve_ordered(tx, Some(revisions))?.unwrap_or_default();
        return Ok(RevsetExpression::commits(ids));
    }
    let text: String = ctx.config.get(key).map_err(|e| cfg(crate::config::value_error(&e)))?;
    let parse_config = crate::revset::revset_config(&ctx.config, &mut ctx.warnings).map_err(cfg)?;
    let expression = crate::revset::parse_diagnosed(
        workspace,
        &parse_config,
        (&text, crate::revset::IN_REVSET_EXPRESSION),
        &mut ctx.warnings,
    )
    .map_err(rev)?;
    crate::revset::resolve_expression(tx.base_repo().as_ref(), &expression).map_err(rev)
}

/// The commits `expression` holds in `repo`, in revset order.
pub(crate) fn commits_of(
    repo: &dyn jj_lib::repo::Repo,
    expression: &Arc<ResolvedRevsetExpression>,
) -> Result<Vec<Commit>, MutateError> {
    let set = expression.clone().evaluate(repo).map_err(be)?;
    let ids: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    ids.iter().map(|id| repo.store().get_commit(id).map_err(be)).collect()
}

/// The target commit `change` names — refused when it is not one of them, as the TUI's cursor
/// can reach only the targets.
fn target_of(tx: &Transaction, state: &State, change: &ChangeId) -> Result<CommitId, MutateError> {
    let id = resolve_commit(tx.repo(), change)?.id().clone();
    let is_target = state.commits.contains_key(&id)
        && !state.external_children.contains(&id)
        && !state.external_parents.contains(&id);
    if is_target {
        Ok(id)
    } else {
        Err(MutateError::invalid(format!(
            "{} is not among the revisions to arrange",
            change.0
        )))
    }
}

/// `jj arrange` (Story 9.16) — see [`crate::Repo::arrange`].
///
/// # Errors
///
/// See [`crate::Repo::arrange`].
pub(crate) fn arrange(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &ArrangeOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let old_wc_id = readonly.view().get_wc_commit_id(&workspace_name).cloned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let repo = readonly.as_ref();

    let target = target_expression(&tx, workspace, ctx, &options.revisions, "revsets.arrange")?;
    let commits = commits_of(repo, &target)?;
    let ids: Vec<CommitId> = commits.iter().map(|c| c.id().clone()).collect();
    guard_rewritable(&tx, &ctx.templates(workspace), &ids)?;

    // `arrange.rs:109-120`: the set must have no gaps.
    let gaps = target.connected().minus(&target).evaluate(repo).map_err(be)?;
    if let Some(gap) = pollster::block_on(gaps.stream().next()) {
        let gap = gap.map_err(be)?;
        return Err(MutateError::invalid_hinted(
            "Cannot arrange revset with gaps in.",
            format!("Revision {gap:.12} would need to be in the set."),
        ));
    }
    let external_children = commits_of(repo, &target.children().minus(&target))?;
    // "No revisions to arrange." (`arrange.rs:134-137`).
    if commits.is_empty() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }

    let mut state = State::new(readonly.store(), commits.clone(), external_children)?;
    for action in &options.actions {
        let (ArrangeAction::SwapDown(change)
        | ArrangeAction::SwapUp(change)
        | ArrangeAction::Abandon(change)
        | ArrangeAction::Keep(change)) = action;
        let id = target_of(&tx, &state, change)?;
        match action {
            ArrangeAction::SwapDown(_) => state.swap_down(&id),
            ArrangeAction::SwapUp(_) => state.swap_up(&id),
            ArrangeAction::Abandon(_) => state.set_fate(&id, Fate::Abandon),
            ArrangeAction::Keep(_) => state.set_fate(&id, Fate::Keep),
        }
    }
    let abandoned: Vec<&Commit> = commits
        .iter()
        .filter(|commit| state.commits[commit.id()].fate == Fate::Abandon)
        .collect();
    let abandoned_change_ids: Vec<ChangeId> = abandoned
        .iter()
        .map(|c| ChangeId(c.change_id().reverse_hex()))
        .collect();
    let wc_abandoned = old_wc_id
        .as_ref()
        .is_some_and(|id| abandoned.iter().any(|c| c.id() == id));

    pollster::block_on(state.to_rewrite_plan().execute(tx.repo_mut()))?;
    // `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard (`cli_util.rs:2852`).
    if !tx.repo().has_changes() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }
    let finish = finish_verb(workspace, tx, "arrange revisions", ctx)?;
    let new_change_ids = match (&finish.wc_commit, wc_abandoned) {
        (Some(new_wc_commit), true) => vec![ChangeId(new_wc_commit.change_id().reverse_hex())],
        _ => Vec::new(),
    };
    Ok(mutation_result(&finish, new_change_ids, abandoned_change_ids))
}

#[cfg(test)]
mod tests {
    //! The CLI's own `State` / `RewritePlan` tests (`arrange.rs:699-1298` @ v0.46.0), minus the
    //! UI order, selection and scroll they also check.

    use std::collections::{HashMap, HashSet};
    use std::sync::Arc;

    use jj_lib::backend::CommitId;
    use jj_lib::commit::Commit;
    use jj_lib::repo::{ReadonlyRepo, Repo as _};
    use jj_lib::transaction::Transaction;

    use super::{Fate, Rewrite, RewritePlan, State};

    /// A fresh repo's head.
    fn repo() -> (tempfile::TempDir, Arc<ReadonlyRepo>) {
        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let repo = crate::Repo::init(&crate::InitOptions {
            path: tmp.path().to_owned(),
            ..Default::default()
        })
        .result
        .expect("init");
        let head = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        (tmp, head)
    }

    fn tx(head: &Arc<ReadonlyRepo>) -> Transaction {
        crate::op_support::start_repo_transaction(head, jj_lib::ref_name::WorkspaceName::DEFAULT)
    }

    /// An empty commit on `parents`.
    fn commit(tx: &mut Transaction, parents: &[&Commit]) -> Commit {
        let tree = tx.repo().store().empty_merged_tree();
        let parents = parents.iter().map(|cc| cc.id().clone()).collect();
        pollster::block_on(tx.repo_mut().new_commit(parents, tree).write()).expect("write")
    }

    /// `root → A → {B, C}`, `D = merge(B, C)`, `e` on C and `f` on D; lowercase is outside the
    /// set — the CLI tests' graph (`ca` … `cf` here).
    fn swap_graph(tx: &mut Transaction) -> [Commit; 7] {
        let root = tx.repo().store().root_commit();
        let ca = commit(tx, &[&root]);
        let cb = commit(tx, &[&ca]);
        let cc = commit(tx, &[&ca]);
        let cd = commit(tx, &[&cb, &cc]);
        let ce = commit(tx, &[&cc]);
        let cf = commit(tx, &[&cd]);
        [root, ca, cb, cc, cd, ce, cf]
    }

    fn swap_state(tx: &Transaction, [_, ca, cb, cc, cd, ce, cf]: &[Commit; 7]) -> State {
        State::new(
            tx.repo().store(),
            vec![cd.clone(), cc.clone(), cb.clone(), ca.clone()],
            vec![ce.clone(), cf.clone()],
        )
        .expect("state")
    }

    fn parents(state: &State, commit: &Commit) -> Vec<CommitId> {
        state.commits[commit.id()].parents.clone()
    }

    fn ids(commits: &[&Commit]) -> Vec<CommitId> {
        commits.iter().map(|cc| cc.id().clone()).collect()
    }

    #[test]
    fn swap_commits_trades_places_and_references() {
        let (_tmp, head) = repo();
        let mut tx = tx(&head);
        let graph = swap_graph(&mut tx);
        let [_, ca, cb, cc, cd, ce, cf] = &graph;
        let mut state = swap_state(&tx, &graph);

        // D and C: C takes D's place, D takes C's.
        state.swap_commits(cd.id(), cc.id());
        assert_eq!(parents(&state, cc), ids(&[cb, cd]));
        assert_eq!(parents(&state, cd), ids(&[ca]));
        assert_eq!(parents(&state, ce), ids(&[cd]));
        assert_eq!(parents(&state, cf), ids(&[cc]));

        // B and D.
        state.swap_commits(cb.id(), cd.id());
        assert_eq!(parents(&state, cc), ids(&[cd, cb]));
        assert_eq!(parents(&state, cd), ids(&[ca]));
        assert_eq!(parents(&state, cb), ids(&[ca]));
        assert_eq!(parents(&state, ce), ids(&[cb]));

        // A and C.
        state.swap_commits(ca.id(), cc.id());
        assert_eq!(parents(&state, ca), ids(&[cd, cb]));
        assert_eq!(parents(&state, cd), ids(&[cc]));
        assert_eq!(parents(&state, cb), ids(&[cc]));
        assert_eq!(parents(&state, cf), ids(&[ca]));

        // A with itself: nothing.
        let before = state.clone();
        state.swap_commits(ca.id(), ca.id());
        assert_eq!(state, before);
    }

    #[test]
    fn swap_down_swaps_with_the_one_parent_inside_the_set() {
        let (_tmp, head) = repo();
        let mut tx = tx(&head);
        let graph = swap_graph(&mut tx);
        let [root, ca, cb, cc, cd, _, _] = &graph;
        let mut state = swap_state(&tx, &graph);

        // D has two parents: nothing.
        let before = state.clone();
        state.swap_down(cd.id());
        assert_eq!(state, before);

        // B down: A and B trade places.
        state.swap_down(cb.id());
        assert_eq!(parents(&state, cb), ids(&[root]));
        assert_eq!(parents(&state, ca), ids(&[cb]));
        assert_eq!(parents(&state, cc), ids(&[cb]));
        assert_eq!(parents(&state, cd), ids(&[ca, cc]));

        // C down: C and B trade places.
        state.swap_down(cc.id());
        assert_eq!(parents(&state, cc), ids(&[root]));
        assert_eq!(parents(&state, cb), ids(&[cc]));
        assert_eq!(parents(&state, ca), ids(&[cc]));

        // C's parent is outside the set now: nothing.
        let before = state.clone();
        state.swap_down(cc.id());
        assert_eq!(state, before);
    }

    #[test]
    fn swap_up_swaps_with_the_one_child_inside_the_set() {
        let (_tmp, head) = repo();
        let mut tx = tx(&head);
        let graph = swap_graph(&mut tx);
        let [_, ca, cb, cc, cd, _, cf] = &graph;
        let mut state = swap_state(&tx, &graph);

        // A has two children, and so has C (one outside the set): nothing.
        let before = state.clone();
        state.swap_up(ca.id());
        state.swap_up(cc.id());
        assert_eq!(state, before);

        // B up: B and D trade places.
        state.swap_up(cb.id());
        assert_eq!(parents(&state, cb), ids(&[cd, cc]));
        assert_eq!(parents(&state, cd), ids(&[ca]));
        assert_eq!(parents(&state, cf), ids(&[cb]));

        // B's one child is outside the set now: nothing.
        let before = state.clone();
        state.swap_up(cb.id());
        assert_eq!(state, before);
    }

    fn no_op_plan(commits: &[&Commit]) -> RewritePlan {
        let rewrites: HashMap<CommitId, Rewrite> = commits
            .iter()
            .map(|commit| {
                let rewrite = Rewrite {
                    old_commit: (*commit).clone(),
                    new_parents: commit.parent_ids().to_vec(),
                    fate: Fate::Keep,
                };
                (commit.id().clone(), rewrite)
            })
            .collect();
        RewritePlan { rewrites }
    }

    #[test]
    fn execute_reorders_by_the_new_parents() {
        let (_tmp, head) = repo();
        let mut tx = tx(&head);
        // A moves between C and F; E follows A:  B → {C → F, D}, A → E  ⇒  B → {C → A → {E, F}, D}.
        let root = tx.repo().store().root_commit();
        let ca = commit(&mut tx, &[&root]);
        let cb = commit(&mut tx, &[&ca]);
        let cc = commit(&mut tx, &[&cb]);
        let cd = commit(&mut tx, &[&cb]);
        let ce = commit(&mut tx, &[&ca]);
        let cf = commit(&mut tx, &[&cc]);
        let mut plan = no_op_plan(&[&ca, &cb, &cc, &cd, &ce, &cf]);
        plan.rewrites.get_mut(ca.id()).expect("a").new_parents = ids(&[&cc]);
        plan.rewrites.get_mut(cb.id()).expect("b").new_parents = ids(&[&root]);
        plan.rewrites.get_mut(cf.id()).expect("f").new_parents = ids(&[&ca]);

        let rewritten = pollster::block_on(plan.execute(tx.repo_mut())).expect("execute");
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        assert_eq!(
            rewritten.keys().collect::<HashSet<_>>(),
            [&ca, &cb, &cc, &cd, &ce, &cf]
                .iter()
                .map(|cc| cc.id())
                .collect::<HashSet<_>>()
        );
        let new = |commit: &Commit| rewritten[commit.id()].clone();
        assert_eq!(new(&cb).parent_ids(), ids(&[&root]));
        assert_eq!(new(&cc).parent_ids(), ids(&[&new(&cb)]));
        assert_eq!(new(&ca).parent_ids(), ids(&[&new(&cc)]));
        assert_eq!(new(&cd).parent_ids(), ids(&[&new(&cb)]));
        assert_eq!(new(&ce).parent_ids(), ids(&[&new(&ca)]));
        assert_eq!(new(&cf).parent_ids(), ids(&[&new(&ca)]));
    }

    #[test]
    fn execute_abandons_and_its_descendants_follow() {
        let (_tmp, head) = repo();
        let mut tx = tx(&head);
        // C moves onto A and is abandoned: D lands on A.
        let root = tx.repo().store().root_commit();
        let ca = commit(&mut tx, &[&root]);
        let cb = commit(&mut tx, &[&ca]);
        let cc = commit(&mut tx, &[&cb]);
        let cd = commit(&mut tx, &[&cc]);
        let mut plan = no_op_plan(&[&ca, &cb, &cc, &cd]);
        let c_rewrite = plan.rewrites.get_mut(cc.id()).expect("c");
        c_rewrite.new_parents = ids(&[&ca]);
        c_rewrite.fate = Fate::Abandon;

        let rewritten = pollster::block_on(plan.execute(tx.repo_mut())).expect("execute");
        pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
        assert_eq!(rewritten.keys().collect::<Vec<_>>(), [cd.id()]);
        let new_d = &rewritten[cd.id()];
        assert_eq!(new_d.parent_ids(), ids(&[&ca]));
        // The fresh repo's own heads (its empty `@`) besides B and the new D.
        let mut expected = head.view().heads().clone();
        expected.extend([cb.id().clone(), new_d.id().clone()]);
        assert_eq!(*tx.repo().view().heads(), expected);
    }

    #[test]
    fn execute_refuses_a_cycle_in_the_new_parents() {
        let (_tmp, head) = repo();
        let mut tx = tx(&head);
        // A and B name each other as parents — a plan the TUI's swaps cannot build; the CLI
        // panics on it, Zanshin refuses.
        let root = tx.repo().store().root_commit();
        let ca = commit(&mut tx, &[&root]);
        let cb = commit(&mut tx, &[&ca]);
        let mut plan = no_op_plan(&[&ca, &cb]);
        plan.rewrites.get_mut(ca.id()).expect("a").new_parents = ids(&[&cb]);

        let err = pollster::block_on(plan.execute(tx.repo_mut())).expect_err("a cycle refuses");
        assert!(
            matches!(&err, crate::MutateError::Backend(reason) if reason == "cycle detected"),
            "{err:?}"
        );
    }
}

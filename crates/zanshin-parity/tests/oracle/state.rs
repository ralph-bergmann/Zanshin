// SPDX-License-Identifier: MIT

//! One repo's state as named aspects, every id replaced by a label.
//!
//! Both repos of a scenario are built by the same CLI steps, so they hold the same files and the
//! same history shape, but different commit, change and operation ids (timestamps, random change
//! ids). Ids are therefore never compared:
//! - a commit is labelled by its description's first line (`#<index>` on a clash);
//! - commits are ordered topologically, ties broken on (description, tree);
//! - ids inside operation text and inside conflict-marker labels are rewritten to labels.
//!
//! Tree ids ARE compared raw: the Git backend's tree id is the Git tree hash, so equal contents
//! give equal ids in both repos.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::default_backend_factories::default_backend_factories;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::operation::Operation;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::ReadonlyRepo;
use jj_lib::repo::Repo as _;
use jj_lib::repo::RepoLoader;
use jj_lib::store::Store;

/// Every aspect [`capture`] produces.
///
/// The operation `args` attribute (the CLI's argv) is deliberately NOT one of them: Zanshin has
/// no argv and records none (ADR-0003), so it would differ in every mutating scenario. It is
/// excluded here, once, instead of being ledgered per scenario (Story 9.47).
pub const STATE_ASPECTS: &[&str] = &[
    "graph (label<-parents)",
    "descriptions",
    "trees",
    "author/committer",
    "conflicts",
    "empty commits",
    "change ids (rewrite vs new)",
    "working copy @",
    "working copies (all workspaces)",
    "working-copy files on disk",
    "local bookmarks",
    "git HEAD (jj view)",
    "git refs (jj view)",
    "git HEAD (.git on disk)",
    "colocated (.git dir)",
    "ops written",
    "op descriptions",
    "op attributes (except args)",
    "op is_snapshot/workspace_name",
];

/// One repo's labelled state.
pub struct State {
    pub aspects: BTreeMap<&'static str, String>,
    labels: Labels,
    /// The operation head (hex): the operations after it are the ones a scenario wrote.
    op_head: String,
    /// The first-parent operation chain from the head down (hex), to name old ops in text.
    op_chain: Vec<String>,
}

impl State {
    /// The change id of the commit labelled `label` (`"@"` = the working-copy commit,
    /// `"root"` = the root commit), for a scenario's Zanshin call.
    pub fn change(&self, label: &str) -> zanshin_jj::ChangeId {
        let label = if label == "@" {
            self.aspects["working copy @"].as_str()
        } else {
            label
        };
        let change = self
            .labels
            .of_change
            .iter()
            .find(|(_, candidate)| candidate.as_str() == label)
            .map_or_else(|| panic!("no commit labelled {label:?}"), |(change, _)| change.clone());
        zanshin_jj::ChangeId(change)
    }

    /// The same change id as a CLI revision argument.
    pub fn change_arg(&self, label: &str) -> String {
        self.change(label).0
    }
}

/// The state of the repo at `root`. With `before`, the operation aspects cover only the
/// operations written since `before` was captured, and rewritten commits keep their old names.
pub fn capture(root: &Path, before: Option<&State>) -> State {
    pollster::block_on(capture_async(root, before))
}

async fn capture_async(root: &Path, before: Option<&State>) -> State {
    let repo = RepoLoader::init_from_file_system(
        &test_helpers::test_settings(),
        &root.join(".jj").join("repo"),
        &default_backend_factories(),
    )
    .expect("repo loader")
    .load_at_head()
    .await
    .expect("load the repo at its operation head");
    let commits = visible_commits(&repo).await;
    let order = topological_order(repo.store().root_commit_id(), &commits);
    let labels = Labels::new(repo.store().root_commit_id(), &order, &commits);

    let mut aspects = commit_aspects(&repo, &order, &commits, &labels, before).await;
    aspects.extend(view_aspects(root, &repo, &labels));
    let operations = operation_aspects(&repo, &labels, before).await;
    aspects.extend(operations.aspects);
    State {
        aspects,
        labels,
        op_head: operations.head,
        op_chain: operations.chain,
    }
}

/// Ids → labels for one repo's visible commits.
struct Labels {
    /// commit id (hex) → label
    of_commit: HashMap<String, String>,
    /// change id (reverse hex) → label
    of_change: HashMap<String, String>,
}

impl Labels {
    /// One label per commit in `order`: `root`, else the description's first line (`(empty)`
    /// without one), with `#<index>` appended when two commits would share a label.
    fn new(root: &CommitId, order: &[CommitId], commits: &HashMap<CommitId, Commit>) -> Self {
        let mut labels: Vec<String> = order
            .iter()
            .map(|id| {
                if id == root {
                    "root".to_owned()
                } else {
                    first_line(commits[id].description())
                }
            })
            .collect();
        let mut seen: HashMap<String, usize> = HashMap::new();
        for label in &labels {
            *seen.entry(label.clone()).or_default() += 1;
        }
        for (index, label) in labels.iter_mut().enumerate() {
            if seen[label.as_str()] > 1 {
                *label = format!("{label}#{index}");
            }
        }
        Self {
            of_commit: order
                .iter()
                .zip(&labels)
                .map(|(id, label)| (id.hex(), label.clone()))
                .collect(),
            of_change: order
                .iter()
                .zip(&labels)
                .map(|(id, label)| (commits[id].change_id().reverse_hex(), label.clone()))
                .collect(),
        }
    }

    fn commit(&self, id: &CommitId) -> String {
        self.of_commit
            .get(&id.hex())
            .cloned()
            .unwrap_or_else(|| "<not visible>".to_owned())
    }
}

/// The visible commits: the ancestors of the view's heads, the root commit included.
async fn visible_commits(repo: &ReadonlyRepo) -> HashMap<CommitId, Commit> {
    let mut commits = HashMap::new();
    let mut stack: Vec<CommitId> = repo.view().heads().iter().cloned().collect();
    while let Some(id) = stack.pop() {
        if commits.contains_key(&id) {
            continue;
        }
        let commit = repo.store().get_commit_async(&id).await.expect("read a visible commit");
        stack.extend(commit.parent_ids().iter().cloned());
        commits.insert(id, commit);
    }
    commits
}

/// Root first. Among the commits whose parents are all placed, (description, tree) decides, so
/// two repos with the same content produce the same order.
fn topological_order(root: &CommitId, commits: &HashMap<CommitId, Commit>) -> Vec<CommitId> {
    let mut children: HashMap<&CommitId, Vec<&CommitId>> = HashMap::new();
    let mut waiting: HashMap<&CommitId, usize> = HashMap::new();
    for (id, commit) in commits {
        waiting.insert(id, commit.parent_ids().len());
        for parent in commit.parent_ids() {
            children.entry(parent).or_default().push(id);
        }
    }
    let key = |id: &CommitId| (commits[id].description().to_owned(), tree_text(&commits[id]));
    let mut ready = vec![root];
    let mut order = Vec::new();
    while !ready.is_empty() {
        ready.sort_by_key(|id| std::cmp::Reverse(key(id)));
        let id = ready.pop().expect("non-empty");
        for child in children.get(id).into_iter().flatten() {
            let count = waiting.get_mut(*child).expect("a child is a visible commit");
            *count -= 1;
            if *count == 0 {
                ready.push(child);
            }
        }
        order.push(id.clone());
    }
    assert_eq!(
        order.len(),
        commits.len(),
        "the visible commits form a DAG under the root"
    );
    order
}

async fn commit_aspects(
    repo: &ReadonlyRepo,
    order: &[CommitId],
    commits: &HashMap<CommitId, Commit>,
    labels: &Labels,
    before: Option<&State>,
) -> BTreeMap<&'static str, String> {
    let root = repo.store().root_commit_id();
    let non_root: Vec<&Commit> = order.iter().filter(|id| *id != root).map(|id| &commits[id]).collect();
    let each = |value: &dyn Fn(&Commit) -> String| {
        non_root
            .iter()
            .map(|commit| format!("{}={}", labels.commit(commit.id()), value(commit)))
            .collect::<Vec<_>>()
            .join("  ")
    };
    let mut aspects = BTreeMap::new();
    let graph = order.iter().map(|id| {
        let parents: Vec<String> = commits[id].parent_ids().iter().map(|p| labels.commit(p)).collect();
        format!("{}<-[{}]", labels.commit(id), parents.join(","))
    });
    aspects.insert("graph (label<-parents)", graph.collect::<Vec<_>>().join("  "));
    aspects.insert("descriptions", each(&|commit| format!("{:?}", commit.description())));
    aspects.insert("trees", each(&tree_text));
    aspects.insert(
        "author/committer",
        each(&|commit| {
            let (author, committer) = (commit.author(), commit.committer());
            format!(
                "{} <{}>/{} <{}>",
                author.name, author.email, committer.name, committer.email
            )
        }),
    );
    let conflicted: Vec<String> = non_root
        .iter()
        .filter(|commit| commit.has_conflict())
        .map(|commit| labels.commit(commit.id()))
        .collect();
    aspects.insert("conflicts", list_or_none(&conflicted));
    let mut empties = Vec::new();
    for commit in &non_root {
        if commit.is_empty(repo).await.expect("emptiness of a commit") {
            empties.push(labels.commit(commit.id()));
        }
    }
    aspects.insert("empty commits", list_or_none(&empties));
    aspects.insert(
        "change ids (rewrite vs new)",
        each(&|commit| match before {
            None => "-".to_owned(),
            Some(before) => before
                .labels
                .of_change
                .get(&commit.change_id().reverse_hex())
                .map_or_else(|| "new".to_owned(), |label| format!("kept {label}")),
        }),
    );
    aspects
}

fn view_aspects(root: &Path, repo: &ReadonlyRepo, labels: &Labels) -> BTreeMap<&'static str, String> {
    let view = repo.view();
    let named = |name: &str, target: &RefTarget| format!("{name}={}", target_labels(target, labels));
    let mut aspects = BTreeMap::new();
    aspects.insert(
        "working copy @",
        view.get_wc_commit_id(WorkspaceName::DEFAULT)
            .map_or_else(|| "<none>".to_owned(), |id| labels.commit(id)),
    );
    let working_copies: Vec<String> = view
        .wc_commit_ids()
        .iter()
        .map(|(name, id)| format!("{}={}", name.as_str(), labels.commit(id)))
        .collect();
    aspects.insert("working copies (all workspaces)", list_or_none(&working_copies));
    aspects.insert(
        "working-copy files on disk",
        normalize_short_ids(&disk_files(root), labels),
    );
    let bookmarks: Vec<String> = view
        .local_bookmarks()
        .map(|(name, target)| named(name.as_str(), target))
        .collect();
    aspects.insert("local bookmarks", list_or_none(&bookmarks));
    aspects.insert(
        "git HEAD (jj view)",
        target_labels(view.git_head(WorkspaceName::DEFAULT), labels),
    );
    let git_refs: Vec<String> = view
        .git_refs()
        .iter()
        .map(|(name, target)| named(name.as_str(), target))
        .collect();
    aspects.insert("git refs (jj view)", list_or_none(&git_refs));
    aspects.insert("git HEAD (.git on disk)", disk_git_head(repo, labels));
    aspects.insert("colocated (.git dir)", root.join(".git").is_dir().to_string());
    aspects
}

/// The Git repo's own HEAD (as opposed to the HEAD jj's view records).
fn disk_git_head(repo: &ReadonlyRepo, labels: &Labels) -> String {
    jj_lib::git::get_git_repo(repo.store())
        .ok()
        .and_then(|git| git.head_id().ok().map(|id| id.detach().to_string()))
        .map_or_else(
            || "<unborn or no git>".to_owned(),
            |hex| {
                labels
                    .of_commit
                    .get(&hex)
                    .cloned()
                    .unwrap_or_else(|| "<not visible>".to_owned())
            },
        )
}

struct OperationAspects {
    aspects: BTreeMap<&'static str, String>,
    head: String,
    chain: Vec<String>,
}

async fn operation_aspects(repo: &ReadonlyRepo, labels: &Labels, before: Option<&State>) -> OperationAspects {
    let head = repo.operation().clone();
    let new_ops = operations_since(&head, before.map(|state| state.op_head.as_str())).await;
    let names = id_names(labels, before, &new_ops);
    let store = repo.store();
    let mut descriptions = Vec::new();
    let mut attributes = Vec::new();
    let mut metadata = Vec::new();
    for op in &new_ops {
        let meta = op.metadata();
        descriptions.push(normalize(&meta.description, &names, store).await);
        let mut attrs = Vec::new();
        for (key, value) in &meta.attributes {
            // The CLI's argv — excluded on purpose, see `STATE_ASPECTS`.
            if key != "args" {
                attrs.push(format!("{key}={:?}", normalize(value, &names, store).await));
            }
        }
        attributes.push(format!("{{{}}}", attrs.join(", ")));
        metadata.push(format!(
            "snapshot={} workspace={}",
            meta.is_snapshot,
            meta.workspace_name.as_ref().map_or("<none>", |name| name.as_str())
        ));
    }
    let mut aspects = BTreeMap::new();
    aspects.insert("ops written", new_ops.len().to_string());
    aspects.insert("op descriptions", list_or_none(&descriptions));
    aspects.insert("op attributes (except args)", list_or_none(&attributes));
    aspects.insert("op is_snapshot/workspace_name", list_or_none(&metadata));
    OperationAspects {
        aspects,
        head: head.id().hex(),
        chain: first_parent_chain(&head).await,
    }
}

/// The operations after `stop` (or after the root operation), oldest first.
async fn operations_since(head: &Operation, stop: Option<&str>) -> Vec<Operation> {
    let mut found = Vec::new();
    let mut queue = vec![head.clone()];
    while let Some(op) = queue.pop() {
        if Some(op.id().hex().as_str()) == stop || op.parent_ids().is_empty() {
            continue;
        }
        queue.extend(op.parents().await.expect("operation parents"));
        found.push(op);
    }
    found.reverse();
    found
}

async fn first_parent_chain(head: &Operation) -> Vec<String> {
    let mut chain = Vec::new();
    let mut cursor = Some(head.clone());
    while let Some(op) = cursor {
        chain.push(op.id().hex());
        cursor = op.parents().await.expect("operation parents").into_iter().next();
    }
    chain
}

/// Names for the ids that appear in operation text. The state before the operation comes first,
/// so a rewritten commit keeps the name it had; then this state; then the new operations.
fn id_names(labels: &Labels, before: Option<&State>, new_ops: &[Operation]) -> HashMap<String, String> {
    let mut names = HashMap::new();
    if let Some(before) = before {
        for (hex, label) in &before.labels.of_commit {
            names.insert(hex.clone(), format!("commit:{label}"));
        }
        for (change, label) in &before.labels.of_change {
            names.insert(change.clone(), format!("change:{label}"));
        }
        for (index, hex) in before.op_chain.iter().enumerate() {
            names.insert(hex.clone(), format!("op:before~{index}"));
        }
    }
    for (hex, label) in &labels.of_commit {
        names.entry(hex.clone()).or_insert_with(|| format!("commit:{label}"));
    }
    for (change, label) in &labels.of_change {
        names.entry(change.clone()).or_insert_with(|| format!("change:{label}"));
    }
    for (index, op) in new_ops.iter().enumerate() {
        names.insert(op.id().hex(), format!("op:new{}", index + 1));
    }
    names
}

/// Rewrites every id token in `text`: a 40-hex commit id, a 128-hex operation id or a 32-char
/// reverse-hex change id becomes its name. A commit that is in neither state (created and
/// rewritten inside the range, e.g. by the snapshot step) is named by its content.
async fn normalize(text: &str, names: &HashMap<String, String>, store: &Arc<Store>) -> String {
    let mut out = String::new();
    for token in tokens(text) {
        let is_hex = !token.is_empty() && token.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c));
        let is_reverse_hex = token.len() == 32 && token.chars().all(|c| ('k'..='z').contains(&c));
        if let Some(name) = names.get(&token) {
            out.push_str(name);
        } else if is_hex && token.len() == 40 {
            let name = unlabelled_commit_name(&token, store).await;
            out.push_str(&name);
        } else if is_hex && token.len() == 128 {
            out.push_str("op:?");
        } else if is_reverse_hex {
            out.push_str("change:?");
        } else {
            out.push_str(&token);
        }
    }
    out
}

/// A commit by content (first description line + tree), for an id no label covers.
async fn unlabelled_commit_name(hex: &str, store: &Arc<Store>) -> String {
    let Some(id) = CommitId::try_from_hex(hex) else {
        return "commit:?".to_owned();
    };
    match store.get_commit_async(&id).await {
        Ok(commit) => format!("commit:~{}/{}", first_line(commit.description()), tree_text(&commit)),
        Err(_) => "commit:?".to_owned(),
    }
}

/// `text` split into runs of `[a-z0-9]` and single other characters, in order.
fn tokens(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut token = String::new();
    for ch in text.chars() {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
            token.push(ch);
        } else {
            tokens.push(std::mem::take(&mut token));
            tokens.push(ch.to_string());
        }
    }
    tokens.push(token);
    tokens
}

/// Replaces short commit or change id prefixes (8+ characters, as in conflict-marker labels)
/// with the labels of the commits they prefix.
fn normalize_short_ids(text: &str, labels: &Labels) -> String {
    let prefix_of = |token: &str, map: &HashMap<String, String>| {
        map.iter()
            .find(|(id, _)| token.len() >= 8 && token.len() < id.len() && id.starts_with(token))
            .map(|(_, label)| label.clone())
    };
    tokens(text)
        .into_iter()
        .map(|token| {
            if let Some(label) = prefix_of(&token, &labels.of_commit) {
                format!("commit:{label}")
            } else if let Some(label) = prefix_of(&token, &labels.of_change) {
                format!("change:{label}")
            } else {
                token
            }
        })
        .collect()
}

fn target_labels(target: &RefTarget, labels: &Labels) -> String {
    if target.is_absent() {
        return "<absent>".to_owned();
    }
    let adds: Vec<String> = target.present_adds().map(|id| labels.commit(id)).collect();
    if target.as_normal().is_some() {
        adds.join(",")
    } else {
        format!("<conflict {}>", adds.join(","))
    }
}

/// Every file under `root` except `.jj/` and `.git/`, with its text: the checked-out working copy.
fn disk_files(root: &Path) -> String {
    let mut files = Vec::new();
    let mut dirs = vec![root.to_owned()];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).expect("read a working-copy dir") {
            let path = entry.expect("a dir entry").path();
            if dir == root && (path.ends_with(".jj") || path.ends_with(".git")) {
                continue;
            }
            if path.is_dir() {
                dirs.push(path);
            } else {
                let relative = path.strip_prefix(root).expect("under the root").display().to_string();
                let text = std::fs::read_to_string(&path).unwrap_or_else(|err| format!("<{err}>"));
                files.push(format!("{relative}={text:?}"));
            }
        }
    }
    files.sort();
    list_or_none(&files)
}

fn first_line(description: &str) -> String {
    let line = description.lines().next().unwrap_or("").trim_end();
    if line.is_empty() {
        "(empty)".to_owned()
    } else {
        line.to_owned()
    }
}

fn tree_text(commit: &Commit) -> String {
    commit
        .tree_ids()
        .iter()
        .map(|id| id.hex()[..12].to_owned())
        .collect::<Vec<_>>()
        .join("|")
}

fn list_or_none(items: &[String]) -> String {
    if items.is_empty() {
        "<none>".to_owned()
    } else {
        items.join("  ")
    }
}

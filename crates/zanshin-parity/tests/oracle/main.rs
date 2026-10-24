// SPDX-License-Identifier: MIT

//! The differential parity oracle (Story 9.47): the same operation through `zanshin-jj`
//! (repo A) and through the stock jj CLI at the pin (repo B), compared by meaning.
//!
//! Every scenario is its own test. It fails when the two repos differ in an aspect the ledger
//! (`ledger.rs`) does not list for it, or when a ledgered divergence no longer happens.

use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::path::Path;

mod compare;
mod driver;
mod git_scenarios;
mod harness;
mod hints;
mod ledger;
mod prompt;
mod scenarios;
mod state;

/// One `#[test]` per scenario id, so they run in parallel and fail individually. The same id
/// lists also yield `SCENARIO_IDS`, so a table entry without a test cannot slip through.
///
/// The ids after `own_process:` change the process environment (a creation scenario's user
/// config, Story 9.57), so each runs as the only test of a child process of this binary
/// (`test_helpers::reran_in_own_process` — `own_process!` takes a literal, not `stringify!`).
macro_rules! parity {
    ($($id:ident),* $(,)?; own_process: $($own:ident),* $(,)?) => {
        const SCENARIO_IDS: &[&str] = &[$(stringify!($id),)* $(stringify!($own)),*];
        $(
            #[test]
            fn $id() {
                test_helpers::pin_test_env();
                let found = harness::run(stringify!($id));
                ledger::assert_matches_ledger(stringify!($id), &found);
            }
        )*
        $(
            #[test]
            fn $own() {
                if test_helpers::reran_in_own_process(module_path!(), stringify!($own)) {
                    return;
                }
                test_helpers::pin_test_env();
                let found = harness::run(stringify!($own));
                ledger::assert_matches_ledger(stringify!($own), &found);
            }
        )*
    };
}

parity!(
    describe_gui_text,
    describe_cli_text,
    new_on_wc,
    new_merge,
    new_conflicting_merge,
    abandon_middle,
    abandon_wc,
    edit_parent,
    edit_conflicted_merge,
    describe_conflicted_at,
    bookmark_create_on_conflicted_at,
    undo_after_describe,
    bookmark_create,
    bookmark_create_existing,
    bookmark_delete,
    config_set_repo,
    config_set_with_dirty_wc,
    snapshot_modified_file,
    snapshot_then_describe,
    describe_immutable,
    new_unresolvable_immutable,
    bookmark_create_unresolvable_immutable,
    undo_unresolvable_immutable,
    new_unresolvable_trunk,
    bookmark_create_unresolvable_trunk,
    describe_root,
    describe_no_change,
    undo_no_change,
    describe_commit_trailers,
    restore_from,
    restore_no_args,
    absorb,
    undo_cross_workspace,
    redo_after_undo,
    redo_nothing,
    redo_stack,
    redo_cross_workspace,
    redo_of_a_redo,
    op_abandon_single,
    op_abandon_nothing,
    op_abandon_range,
    op_abandon_current_refused,
    op_abandon_root_refused,
    redo_cross_workspace_allowed,
    op_abandon_bounded,
    op_abandon_merge_refused,
    op_abandon_working_copy_not_updated,
    op_restore_earlier,
    op_restore_current,
    op_restore_root,
    op_restore_what_repo,
    op_restore_what_remote_tracking,
    op_restore_not_found,
    op_revert_default,
    op_revert_rebases_descendants,
    op_revert_twice,
    op_revert_root_refused,
    op_revert_merge_refused,
    op_revert_what_remote_tracking,
    op_integrate_in_log,
    init_colocated,
    init_no_colocate,
    workspace_add_default,
    workspace_add_name_revisions_message,
    workspace_add_sparse_empty,
    workspace_add_colocated,
    workspace_add_no_colocate,
    update_stale_clean,
    update_stale_not_stale,
    update_stale_dirty,
    update_stale_colocated,
    auto_update_stale_snapshot,
    squash_wc_into_parent,
    squash_revision,
    squash_merge_refused,
    squash_from_into,
    squash_into_wc_noop,
    squash_path_with_revision,
    squash_keep_emptied,
    squash_use_destination_message,
    squash_message,
    squash_plan_as_message,
    split_paths_message,
    split_paths_editor,
    split_all_selected,
    split_none_selected,
    split_parallel,
    split_insert_after,
    split_insert_before,
    split_onto,
    split_legacy_bookmarks_off,
    squash_from_into_descendant,
    squash_from_two_into,
    squash_from_into_path,
    split_parallel_bookmark,
    split_parallel_bookmark_legacy_off,
    commit_everything,
    commit_two_of_three_paths,
    commit_empty_wc_empty_message,
    commit_unmatched_path,
    commit_unchanged_path,
    commit_bookmark_on_wc,
    commit_advance_bookmarks,
    commit_advance_bookmarks_disabled,
    commit_wc_with_child,
    commit_two_workspaces_on_wc,
    commit_without_working_copy,
    commit_trailers,
    commit_advance_merge_parents,
    commit_immutable_wc_with_child,
    commit_path_outside_repo,
    commit_advance_bad_pattern,
    commit_advance_not_a_list,
    new_advance_bookmarks,
    new_advance_bookmarks_disabled,
    new_advance_interior,
    new_merge_advance_none,
    new_advance_bad_pattern,
    new_merge_ignores_bad_pattern,
    commit_path_escapes_repo,
    split_tool_sections_1_3,
    split_tool_mode_only,
    split_tool_sections_no_mode,
    split_tool_mode_and_sections,
    commit_tool_sections_1_3,
    squash_tool_sections_1_3,
    restore_path_escapes_repo,
    squash_path_escapes_repo,
    split_path_escapes_repo,
    absorb_path_escapes_repo,
    commit_path_dot_components,
    new_insert_after_two_children,
    new_insert_before,
    new_insert_before_empty_wc,
    new_insert_after_and_before,
    new_insert_after_immutable_child,
    new_insert_after_no_advance,
    new_insert_loop,
    new_merge_with_root,
    new_duplicate_parents,
    init_missing_destination,
    init_over_git_colocate,
    init_over_git_no_colocate,
    clone_default,
    clone_no_colocate,
    clone_remote_name,
    clone_branch,
    clone_empty_source,
    clone_non_empty_destination,
    push_bare,
    push_bookmark,
    push_all,
    push_tracked,
    push_deleted,
    push_change,
    push_named,
    push_dry_run,
    push_nothing_changed,
    push_unmatched_remote,
    push_no_matching_remote,
    push_skip_undescribed,
    push_abort_undescribed,
    push_tag,
    push_two_remotes,
    push_bare_skip_undescribed,
    push_bare_new_tag,
    push_revision,
    push_all_two_remotes_one_refuses,
    push_all_one_remote_left_empty,
    push_all_with_bookmark_refused,
    push_all_with_bookmark_refused_dirty_wc,
    describe_empty_trailers,
    describe_broken_template,
    new_description,
    new_description_trailers,
    workspace_add_trailers,
    squash_message_trailers,
    squash_editor_trailers,
    squash_custom_draft,
    squash_plan_custom_draft_as_message,
    split_message_trailers,
    split_editor_trailers,
    split_editor_default_description,
    push_change_custom_template,
    push_change_empty_template,
    squash_use_destination_trailers,
    squash_single_description_trailers,
    split_editor_undescribed_trailers,
    split_parallel_editor_trailers,
    commit_empty_message_trailers,
    workspace_add_no_message_trailers,
    describe_environment_trailers,
    squash_broken_draft_template,
    push_change_shortest_template,
    push_change_broken_template,
    abandon_broken_template_aliases,
    abandon_broken_short_prefixes,
    abandon_bad_template_alias_entry,
    abandon_diagnosed_short_prefixes,
    squash_plan_edited_trailer_deleted,
    squash_plan_edited_unchanged,
    split_edited_trailer_deleted,
    split_edited_unchanged,
    new_description_config_ui_color,
    workspace_add_bad_template_alias,
    workspace_add_diagnosed_short_prefixes,
    squash_use_destination_edited,
    squash_undescribed_edited,
    workspace_add_immutable_at,
    bookmark_create_auto_track_created,
    bookmark_create_auto_track_existing,
    bookmark_create_auto_track_broken,
    bookmark_create_auto_track_union,
    bookmark_move_forward,
    bookmark_move_backwards_refused,
    bookmark_move_backwards_allowed,
    bookmark_move_from,
    bookmark_move_names_and_from,
    bookmark_move_conflicted_to_descendant,
    bookmark_advance_from_config,
    bookmark_move_noop,
    bookmark_move_unknown_name,
    bookmark_move_empty_target,
    bookmark_advance_default,
    bookmark_advance_named,
    bookmark_advance_backwards_refused,
    bookmark_rename,
    bookmark_rename_onto_existing_refused,
    bookmark_rename_overwrite,
    bookmark_rename_missing,
    bookmark_rename_same_refused,
    bookmark_rename_same_overwrite,
    bookmark_rename_tracked_pushed,
    bookmark_set_new,
    bookmark_set_noop,
    bookmark_set_backwards_refused,
    bookmark_set_backwards_allowed,
    bookmark_set_empty_target,
    bookmark_set_empty_name_dirty_wc,
    bookmark_forget_local,
    bookmark_forget_nothing,
    bookmark_track_mixed_dirty_wc,
    bookmark_untrack_remote_with_symbol,
    bookmark_track_bad_pattern,
    bookmark_set_auto_track_created,
    bookmark_set_resurrect_tracked,
    bookmark_forget_tracked_pushed,
    bookmark_forget_include_remotes,
    bookmark_forget_untracked_remote_only,
    bookmark_track_symbol,
    bookmark_track_pattern_absent,
    bookmark_track_already_tracked,
    bookmark_track_remote_unmatched,
    bookmark_untrack_symbol,
    bookmark_untrack_pattern,
    bookmark_untrack_not_tracked_and_git,
    bookmark_untrack_remote_git,
    file_chmod_x,
    file_chmod_n,
    file_chmod_revision,
    file_chmod_unmatched,
    file_chmod_immutable_root,
    file_chmod_symlink_refused,
    file_chmod_no_paths_dirty_wc,
    workspace_forget_other,
    workspace_forget_current,
    workspace_forget_two,
    workspace_forget_unknown,
    workspace_forget_colocated_worktree,
    workspace_rename_new,
    workspace_rename_same,
    workspace_rename_existing_refused,
    workspace_rename_empty_dirty_wc,
    workspace_remove_dirty,
    workspace_remove_colocated_worktree,
    workspace_remove_two,
    workspace_remove_unknown,
    workspace_remove_default_refused,
    workspace_remove_deleted_dir_refused,
    workspace_remove_no_names_dirty_wc,
    fetch_default,
    fetch_only_remote,
    fetch_no_remote,
    fetch_unmatched_remote,
    fetch_all_remotes,
    fetch_branch_pattern,
    fetch_tracked,
    fetch_git_fetch_config,
    fetch_remote_fetch_bookmarks,
    fetch_nothing_new,
    convert_colocated_default,
    convert_import_default,
    convert_import_invalid_source,
    convert_import_missing_parent,
    rebase_source_onto,
    rebase_revision_onto_root,
    rebase_revision_onto_descendant,
    rebase_revision_insert_after,
    rebase_revision_insert_before,
    rebase_default_branch,
    rebase_default_branch_moves,
    rebase_branch_noop,
    rebase_source_onto_descendant_refused,
    rebase_revision_onto_itself_refused,
    rebase_skip_emptied,
    rebase_simplify_parents,
    rebase_i1_source_insert_after,
    rebase_i1_source_insert_before,
    parallelize_two,
    parallelize_one_noop,
    rebase_i1_source_insert_after_merge,
    rebase_i1_branch_insert_after,
    rebase_i1_branch_insert_before,
    rebase_immutable_refused,
    parallelize_child_becomes_a_merge,
    parallelize_merge_child_keeps_outside_parent,
    simplify_parents_revisions,
    simplify_parents_source,
    simplify_parents_multiple_with_descendants,
    simplify_parents_default,
    simplify_parents_custom_setting,
    simplify_parents_linear_noop,
    simplify_parents_diamond_noop,
    simplify_parents_empty_setting_noop,
    simplify_parents_root_refused,
    simplify_parents_immutable_refused,
    simplify_parents_source_two_merges,
    simplify_parents_source_and_revisions,
    simplify_parents_non_target_redundant_descendant,
    simplify_parents_bad_setting_refused,
    simplify_parents_deprecated_setting_warns,
    rebase_i1_source_insert_before_merge,
    rebase_source_onto_itself_refused,
    rebase_several_revisions,
    rebase_several_sources,
    rebase_onto_two_parents,
    rebase_insert_loop_refused,
    rebase_clap_conflict_dirty_wc,
    squash_clap_conflict_dirty_wc,
    split_clap_conflict_dirty_wc,
    new_clap_conflict_dirty_wc,
    restore_clap_conflict_dirty_wc,
    metaedit_message,
    metaedit_revision_message,
    metaedit_empty_message,
    metaedit_update_change_id,
    metaedit_two_revisions_message,
    metaedit_two_paragraphs,
    metaedit_update_author_timestamp,
    metaedit_author,
    metaedit_author_timestamp,
    metaedit_update_author_noop,
    metaedit_force_rewrite,
    metaedit_root_refused,
    metaedit_unchanged_message_noop,
    metaedit_clap_conflict_dirty_wc,
    duplicate_default,
    duplicate_revision,
    duplicate_onto_root,
    duplicate_insert_after,
    duplicate_insert_before,
    duplicate_onto_two_parents,
    duplicate_as_own_descendant,
    duplicate_as_own_ancestor,
    duplicate_two_revisions,
    duplicate_root_refused,
    duplicate_description_template,
    fix_default,
    fix_source,
    fix_path,
    fix_include_unchanged_files,
    fix_tool_timeout_key,
    fix_nothing_to_fix,
    fix_failing_tool,
    fix_no_tools_refused,
    fix_deprecated_line_range_arg,
    snapshot_deprecated_line_range_arg,
    next_default,
    next_edit,
    next_two,
    next_edit_two,
    next_conflict,
    prev_default,
    prev_edit,
    prev_two,
    prev_conflict,
    prev_zero_edit_noop,
    next_ui_movement_edit,
    next_no_edit_overrides_ui_movement_edit,
    next_children_refused,
    next_nothing_found_refused,
    prev_nothing_found_refused,
    prev_edit_root_refused,
    next_ambiguous_refused,
    prev_offset_too_large_refused,
    next_edit_no_edit_clap_dirty_wc,
    next_conflict_offset_clap_dirty_wc;
    own_process:
    convert_import_unresolvable_immutable,
    convert_colocated_unresolvable_immutable,
    convert_import_refs_step_config_fault,
    convert_colocated_refs_step_config_fault,
    clone_unresolvable_immutable,
);

/// Every scenario id the table and the creation list define.
fn defined_ids() -> BTreeSet<&'static str> {
    scenarios::scenarios()
        .iter()
        .map(|scenario| scenario.id)
        .chain(git_scenarios::CREATION_SCENARIOS.iter().map(|creation| creation.id))
        .collect()
}

#[test]
fn every_scenario_has_a_test() {
    assert_eq!(SCENARIO_IDS.iter().copied().collect::<BTreeSet<_>>(), defined_ids());
    assert_eq!(SCENARIO_IDS.len(), 402);
}

#[test]
fn ledger_names_only_known_scenarios_and_aspects() {
    let ids = defined_ids();
    let aspects: BTreeSet<&str> = state::STATE_ASPECTS
        .iter()
        .chain(compare::OUTCOME_ASPECTS)
        .copied()
        .collect();
    for expected in ledger::LEDGER {
        assert!(
            ids.contains(expected.scenario),
            "ledger names unknown scenario {}",
            expected.scenario
        );
        assert!(
            aspects.contains(expected.aspect),
            "ledger names unknown aspect {}",
            expected.aspect
        );
    }
}

/// A ledgered aspect that still diverges, but with other values than the ledger pins, must
/// fail: otherwise a wrong fix or a fresh regression in that aspect would pass as "expected".
#[test]
#[should_panic(expected = "CHANGED descriptions")]
fn a_ledgered_aspect_with_other_values_fails() {
    let found = [compare::Divergence {
        aspect: "descriptions".to_owned(),
        zanshin: "a different Zanshin value".to_owned(),
        cli: "a different CLI value".to_owned(),
    }];
    ledger::assert_matches_ledger("describe_gui_text", &found);
}

#[test]
fn identical_cli_built_repos_capture_equal() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let (_b, b) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let found = compare::compare(&state::capture(&a, None).aspects, &state::capture(&b, None).aspects);
    assert!(
        found.is_empty(),
        "{:?}",
        found.iter().map(|d| &d.aspect).collect::<Vec<_>>()
    );
}

#[test]
fn a_description_difference_shows_in_descriptions_without_ids() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let (_b, b) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let before_a = state::capture(&a, None);
    let before_b = state::capture(&b, None);
    driver::jj(&a, &["describe", "-m", "C one"]).ok();
    driver::jj(&b, &["describe", "-m", "C two"]).ok();
    let found = compare::compare(
        &state::capture(&a, Some(&before_a)).aspects,
        &state::capture(&b, Some(&before_b)).aspects,
    );
    // The label is the description's first line, so other aspects differ by label text too;
    // what matters is that `descriptions` is among them and no aspect leaks a commit id.
    assert!(found.iter().any(|d| d.aspect == "descriptions"));
    let has_commit_id = |s: &str| s.split(|c: char| !c.is_ascii_hexdigit()).any(|t| t.len() == 40);
    assert!(found
        .iter()
        .all(|d| !has_commit_id(&d.zanshin) && !has_commit_id(&d.cli)));
}

#[test]
fn every_captured_aspect_is_listed() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let keys: BTreeSet<_> = state::capture(&a, None).aspects.into_keys().collect();
    assert_eq!(keys, state::STATE_ASPECTS.iter().copied().collect());
}

#[test]
fn pinned_jj_builds_a_repo_zanshin_opens() {
    test_helpers::pin_test_env();
    let (_dir, root) = driver::fresh_repo(&["git", "init"], &[]);
    zanshin_jj::Repo::open(&root).expect("Zanshin opens a repo the pinned jj created");
}

#[test]
fn pinned_jj_keeps_its_secure_config_in_the_test_xdg_dir() {
    test_helpers::pin_test_env();
    // WHY the config write: a plain `jj git init` without a remote writes no repo config, so it
    // creates no secure config entry at all; the first `config set --repo` does.
    let (_dir, root) = driver::fresh_repo(
        &["git", "init"],
        &[&[driver::Step::Jj(&[
            "config",
            "set",
            "--repo",
            "ui.conflict-marker-style",
            "git",
        ])]],
    );
    let id = std::fs::read_to_string(root.join(".jj/repo/config-id")).expect("config-id");
    let xdg = std::env::var_os("XDG_CONFIG_HOME").expect("pinned by pin_test_env");
    assert!(
        Path::new(&xdg).join("jj/repos").join(id.trim()).is_dir(),
        "the CLI's secure per-repo config must land in the test's XDG_CONFIG_HOME"
    );
}

#[test]
fn pinned_jj_command_carries_the_hermetic_env() {
    test_helpers::pin_test_env();
    let command = driver::command(Path::new("/"), &["log"]);
    let envs: BTreeMap<_, _> = command.get_envs().collect();
    let get = |name: &str| envs.get(OsStr::new(name)).copied().flatten();
    assert_eq!(get("LLVM_PROFILE_FILE"), Some(OsStr::new("/dev/null")));
    assert_eq!(get("XDG_CONFIG_HOME"), std::env::var_os("XDG_CONFIG_HOME").as_deref());
    for (name, value) in test_helpers::TEST_ENV {
        assert_eq!(get(name), Some(OsStr::new(value)), "{name}");
    }
}

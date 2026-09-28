// Commit DAG for the graph view. `inDefault` = part of the default `jj log` revset
// (present(@) | ancestors(immutable_heads().., 2) | trunk()). Everything else only shows with all().
(function () {
  const C = (o) => Object.assign({
    parents: [], bookmarks: [], files: [], description: "", author: "Ralph Stein",
    priority: 0, immutable: false, inDefault: true, isEmpty: false, isWorkingCopy: false,
    hasConflict: false, stats: { added: 0, removed: 0, files: 0 },
  }, o);
  const list = [
    C({ id: "zzzzzzzz", commitId: "00000000", subject: "root()", author: "", date: "", isRoot: true, immutable: true, inDefault: false }),
    C({ id: "qpvuntsm", commitId: "a1b2c3d4", parents: ["zzzzzzzz"], subject: "Initial commit", author: "Alice", date: "Sep 1", ts: "2026-09-01T10:00", immutable: true, inDefault: false, stats: { added: 1240, removed: 0, files: 32 } }),
    C({ id: "rlvkpnrz", commitId: "b2c3d4e5", parents: ["qpvuntsm"], subject: "Add authentication module", author: "Bob", date: "Sep 4", ts: "2026-09-04T11:00", immutable: true, inDefault: false, stats: { added: 412, removed: 18, files: 11 } }),
    C({ id: "sqpuoqvx", commitId: "c3d4e5f6", parents: ["rlvkpnrz"], subject: "Update user interface components", author: "Alice", date: "Sep 8", ts: "2026-09-08T10:00", immutable: true, inDefault: false, stats: { added: 188, removed: 92, files: 9 } }),
    C({ id: "mzvwutvl", commitId: "e5f6a7b8", parents: ["rlvkpnrz"], subject: "feat(api): endpoints for data sync", author: "Bob", date: "Sep 8", ts: "2026-09-08T15:00", priority: 1, immutable: true, inDefault: false, stats: { added: 322, removed: 14, files: 12 } }),
    C({ id: "zsuskuln", commitId: "f6a7b8c9", parents: ["mzvwutvl"], subject: "feat(api): conflict resolution for offline edits", author: "Bob", date: "Sep 10", ts: "2026-09-10T12:00", priority: 1, immutable: true, inDefault: false, stats: { added: 141, removed: 22, files: 5 } }),
    C({ id: "ttnlkwrs", commitId: "a7b8c9d0", parents: ["sqpuoqvx", "zsuskuln"], subject: "Merge api-sync into main", author: "Alice", date: "Sep 12", ts: "2026-09-12T09:30", immutable: true, inDefault: false }),
    C({ id: "nvkqlxsp", commitId: "b1c9d0e1", parents: ["ttnlkwrs"], subject: "fix: memory leak in image cache", author: "Bob", date: "Sep 13", ts: "2026-09-13T10:00", immutable: true, inDefault: false, stats: { added: 18, removed: 9, files: 2 } }),
    C({ id: "rtmswzvk", commitId: "b2c9d0e1", parents: ["nvkqlxsp"], subject: "perf: lazy-load heavy screens", author: "Alice", date: "Sep 14", ts: "2026-09-14T15:00", immutable: true, inDefault: false, stats: { added: 72, removed: 40, files: 7 } }),
    C({ id: "wqnwkozp", commitId: "b8c9d0e1", parents: ["rtmswzvk"], subject: "chore(deps): update dependencies", author: "Charlie Davis", date: "Sep 15", ts: "2026-09-15T16:00", immutable: true, stats: { added: 84, removed: 81, files: 4 } }),
    C({ id: "vruxwmqv", commitId: "c9d0e1f2", parents: ["wqnwkozp"], subject: "Release v1.0.0", author: "Alice", date: "Sep 19", ts: "2026-09-19T11:00", immutable: true,
        bookmarks: [{ name: "main", state: "synced" }], stats: { added: 4, removed: 4, files: 2 } }),
    C({ id: "yostqsxw", commitId: "d0e1f2a3", parents: ["wqnwkozp"], subject: "fix: backport startup crash fix to 1.5.x", author: "Charlie Davis", date: "Sep 17", ts: "2026-09-17T14:00", priority: 5, immutable: true, inDefault: false,
        bookmarks: [{ name: "release/1.5.x@origin", state: "remote" }], stats: { added: 12, removed: 3, files: 1 } }),

    // feature/new onboarding stack
    C({ id: "kkmpptxz", commitId: "1f2e3d4c", parents: ["vruxwmqv"], subject: "feat(onboarding): scaffold 4-page flow", author: "Lena König", date: "3d", ts: "2026-09-22T10:00", priority: 2, stats: { added: 184, removed: 0, files: 6 } }),
    C({ id: "nlrtpsqy", commitId: "2e3d4c5b", parents: ["kkmpptxz"], subject: "feat(onboarding): hero illustrations + lottie loader", author: "Lena König", date: "2d", ts: "2026-09-23T15:00", priority: 2,
        bookmarks: [{ name: "feature/ZAN-415_hero-assets", state: "synced" }], stats: { added: 218, removed: 4, files: 8 } }),
    C({ id: "xyzrmwpo", commitId: "3d4c5b6a", parents: ["nlrtpsqy"], subject: "feat(onboarding): animated page indicator", author: "Ralph Stein", date: "5h", ts: "2026-09-25T09:00", priority: 2, hasConflict: true, stats: { added: 64, removed: 12, files: 3 } }),
    C({ id: "plkmnvxo", commitId: "4c5b6a79", parents: ["xyzrmwpo"], subject: "feat(onboarding): swipe gestures + haptic feedback", author: "Ralph Stein", date: "3h", ts: "2026-09-25T11:00", priority: 2,
        description: "Pages can now be swiped; each page change triggers a light haptic tick.\nIndicator follows the drag offset instead of snapping.",
        bookmarks: [{ name: "feature/ZAN-412_onboarding-swipe-gestures", state: "ahead", ahead: 1 }, { name: "review/ZAN-412-v2", state: "local" }],
        stats: { added: 142, removed: 18, files: 4 },
        files: [
          { path: "lib/features/onboarding/onboarding_screen.dart", added: 72, removed: 14, status: "M" },
          { path: "lib/features/onboarding/widgets/onboarding_page.dart", added: 48, removed: 0, status: "A" },
          { path: "lib/features/onboarding/widgets/page_indicator.dart", added: 18, removed: 4, status: "M" },
          { path: "lib/core/haptics.dart", added: 4, removed: 0, status: "A" },
        ] }),
    C({ id: "ovknlmro", commitId: "5b6a7988", parents: ["plkmnvxo"], subject: "(no description set)", author: "Ralph Stein", date: "now", ts: "2026-09-25T14:00", priority: 2, isEmpty: true, isWorkingCopy: true }),

    // experiment on top of the onboarding stack
    C({ id: "uwqmpnrk", commitId: "6a798897", parents: ["xyzrmwpo"], subject: "exp: migrate providers to riverpod 3 codegen", author: "Ralph Stein", date: "1h", ts: "2026-09-25T13:00", priority: 3, stats: { added: 310, removed: 244, files: 17 } }),
    C({ id: "kzrmqvnt", commitId: "7a8897a6", parents: ["uwqmpnrk"], subject: "exp: generate providers for settings + auth", author: "Ralph Stein", date: "50m", ts: "2026-09-25T13:10", priority: 3, stats: { added: 88, removed: 61, files: 6 } }),
    C({ id: "tnrkslqw", commitId: "798897a6", parents: ["kzrmqvnt"], subject: "exp: drop legacy ChangeNotifier wrappers", author: "Ralph Stein", date: "40m", ts: "2026-09-25T13:20", priority: 3,
        bookmarks: [{ name: "exp/riverpod-3", state: "local" }], stats: { added: 12, removed: 196, files: 9 } }),

    // iOS fix
    C({ id: "lpmxnvqr", commitId: "8897a6b5", parents: ["vruxwmqv"], subject: "fix(ios): keyboard avoidance on iPad split view", author: "Lena König", date: "5h", ts: "2026-09-25T09:10", priority: 4, stats: { added: 38, removed: 11, files: 3 } }),
    C({ id: "vtxnbqrs", commitId: "97a6b5c4", parents: ["lpmxnvqr"], subject: "fix(ios): account for safe area when keyboard opens", author: "Ralph Stein", date: "1h", ts: "2026-09-25T12:55", priority: 4,
        bookmarks: [{ name: "fix/ZAN-398_ios-keyboard-safe-area", state: "synced" }], stats: { added: 22, removed: 6, files: 2 } }),

    // develop
    C({ id: "mwoqxlpn", commitId: "a6b5c4d3", parents: ["vruxwmqv"], subject: "feat(api): paginated responses for /events", author: "Bob", date: "1d", ts: "2026-09-24T11:00", priority: 4.5, stats: { added: 96, removed: 14, files: 4 } }),
    C({ id: "rsyntlvq", commitId: "b5c4d3e2", parents: ["mwoqxlpn"], subject: "refactor(api): extract response middleware", author: "Bob", date: "20h", ts: "2026-09-24T18:00", priority: 4.5, stats: { added: 64, removed: 42, files: 6 } }),
    C({ id: "hvsmqplk", commitId: "b6c4d3e2", parents: ["rsyntlvq"], subject: "test(api): contract tests for pagination", author: "Bob", date: "10h", ts: "2026-09-25T04:00", priority: 4.5, stats: { added: 146, removed: 0, files: 3 } }),
    C({ id: "jqntwrpx", commitId: "b7c4d3e2", parents: ["hvsmqplk"], subject: "perf(api): cache page cursors", author: "Charlie Davis", date: "3h", ts: "2026-09-25T11:10", priority: 4.5, stats: { added: 41, removed: 12, files: 2 } }),
    C({ id: "kxwsnptm", commitId: "c4d3e2f1", parents: ["jqntwrpx", "vtxnbqrs"], subject: "merge: bring iOS keyboard fix into develop", author: "Bob", date: "30m", ts: "2026-09-25T13:30", priority: 4.5,
        bookmarks: [{ name: "develop", state: "ahead", ahead: 2 }] }),

    // settings redesign stack
    C({ id: "qmsvtlkr", commitId: "d1e2f3a4", parents: ["vruxwmqv"], subject: "feat(settings): section-based layout", author: "Lena König", date: "2d", ts: "2026-09-23T10:00", priority: 6, stats: { added: 204, removed: 38, files: 7 } }),
    C({ id: "wrnxqpsz", commitId: "d2e2f3a4", parents: ["qmsvtlkr"], subject: "feat(settings): theme picker with live preview", author: "Lena König", date: "2d", ts: "2026-09-23T14:30", priority: 6, stats: { added: 118, removed: 6, files: 4 } }),
    C({ id: "ynkplrtv", commitId: "d3e2f3a4", parents: ["wrnxqpsz"], subject: "refactor(settings): move prefs to typed store", author: "Ralph Stein", date: "1d", ts: "2026-09-24T10:00", priority: 6, stats: { added: 96, removed: 132, files: 9 } }),
    C({ id: "sxmtvqno", commitId: "d4e2f3a4", parents: ["ynkplrtv"], subject: "test(settings): golden tests for all sections", author: "Lena König", date: "20h", ts: "2026-09-24T18:10", priority: 6, stats: { added: 310, removed: 0, files: 12 } }),
    C({ id: "lvqrnkmw", commitId: "d5e2f3a4", parents: ["sxmtvqno"], subject: "fix(settings): dark-mode contrast in toggles", author: "Lena König", date: "8h", ts: "2026-09-25T06:30", priority: 6, stats: { added: 14, removed: 9, files: 2 } }),
    C({ id: "potwkszn", commitId: "d6e2f3a4", parents: ["lvqrnkmw"], subject: "feat(settings): account & sign-out section", author: "Lena König", date: "4h", ts: "2026-09-25T10:00", priority: 6,
        bookmarks: [{ name: "feature/ZAN-430_settings-redesign", state: "ahead", ahead: 2 }], stats: { added: 87, removed: 5, files: 3 } }),

    // docs
    C({ id: "nqxwrptl", commitId: "e1f2a3b4", parents: ["vruxwmqv"], subject: "docs: API reference skeleton", author: "Charlie Davis", date: "1d", ts: "2026-09-24T09:00", priority: 7, stats: { added: 160, removed: 0, files: 5 } }),
    C({ id: "tzkvmrls", commitId: "e2f2a3b4", parents: ["nqxwrptl"], subject: "docs: document pagination params", author: "Charlie Davis", date: "1d", ts: "2026-09-24T12:00", priority: 7, stats: { added: 44, removed: 2, files: 1 } }),
    C({ id: "mrplxqwv", commitId: "e3f2a3b4", parents: ["tzkvmrls"], subject: "docs: auth flow sequence diagrams", author: "Charlie Davis", date: "12h", ts: "2026-09-25T02:00", priority: 7,
        bookmarks: [{ name: "docs/api-reference", state: "local" }], stats: { added: 58, removed: 4, files: 3 } }),
  ];
  list.forEach(c => { c.changeId = c.id; c.isMerge = c.parents.length > 1; });
  window.GRAPH_COMMITS = list;
  window.GRAPH_NOW = "2026-09-25T14:00";
})();

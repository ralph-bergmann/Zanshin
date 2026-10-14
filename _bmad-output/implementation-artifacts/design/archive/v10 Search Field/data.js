// Mock data for the jj desktop client demo (Flutter app repo)

window.PROJECTS = [
  { id: "flutter-app", name: "MyApp",  color: "#3b82f6" },
  { id: "rust-cli",    name: "ripjj",  color: "#22c55e" },
  { id: "docs",        name: "Docs",   color: "#a855f7" },
  { id: "design",      name: "Design", color: "#f59e0b" },
];

// Branch colors per the screenshot palette
window.BRANCH_COLORS = {
  "main":             "#3b82f6", // blue
  "develop":          "#22c55e", // green
  "feature/new-ui":   "#a855f7", // purple
  "feat/onboarding":  "#a855f7",
  "fix/ios-keyboard": "#f59e0b", // amber
  "exp/riverpod-3":   "#ec4899", // pink
};

// Commit type → color (used for the type pill on each card)
window.TYPE_COLORS = {
  feat:     { bg: "#0f2e1a", fg: "#4ade80", border: "#22c55e44" },
  fix:      { bg: "#2e1212", fg: "#f87171", border: "#ef444444" },
  chore:    { bg: "#2a2310", fg: "#facc15", border: "#eab30844" },
  test:     { bg: "#0f1f2e", fg: "#60a5fa", border: "#3b82f644" },
  refactor: { bg: "#221a2e", fg: "#c084fc", border: "#a855f744" },
  release:  { bg: "#2a1810", fg: "#fb923c", border: "#f9731644" },
  merge:    { bg: "#1f1f1f", fg: "#a1a1aa", border: "#52525244" },
};

window.BOOKMARKS = [
  { name: "main",            ahead: 0, behind: 0, current: false, head: "a7c8d9e", remote: "origin/main" },
  { name: "develop",         ahead: 2, behind: 0, current: false, head: "b3f8a21", remote: "origin/develop" },
  { name: "feature/new-ui",  ahead: 6, behind: 0, current: true,  head: "kpwzlmq", remote: "origin/feature/new-ui" },
  { name: "fix/ios-keyboard", ahead: 2, behind: 1, current: false, head: "vtxnbqr", remote: "origin/fix/ios-keyboard" },
  { name: "exp/riverpod-3",  ahead: 7, behind: 12, current: false, head: "mqlbxzn", remote: null },
];

window.REMOTE_BRANCHES = [
  { name: "origin/main",             head: "a7c8d9e", trackedBy: "main" },
  { name: "origin/develop",          head: "94e3c12", trackedBy: "develop", aheadOfLocal: 0, behindLocal: 2 },
  { name: "origin/feature/new-ui",   head: "5c1a8f3", trackedBy: "feature/new-ui", aheadOfLocal: 0, behindLocal: 6 },
  { name: "origin/fix/ios-keyboard", head: "31b7d24", trackedBy: "fix/ios-keyboard", aheadOfLocal: 1, behindLocal: 2 },
  { name: "origin/main-rc",          head: "8f2e9a1", trackedBy: null },
  { name: "origin/release/1.5.x",    head: "4a8c2d9", trackedBy: null },
];

window.OPEN_COLUMNS = ["main", "develop", "feature/new-ui"];

function c(opts) {
  return {
    changeId: opts.changeId,
    commitShort: opts.commitShort,
    type: opts.type || null,
    version: opts.version || null,
    subject: opts.subject,
    description: opts.description || "",
    author: opts.author || "Alice",
    email: opts.email || (opts.author || "alice").toLowerCase().split(" ")[0] + "@dasralph.de",
    date: opts.date,
    isWorkingCopy: !!opts.isWorkingCopy,
    isEmpty: !!opts.isEmpty,
    isMerge: !!opts.isMerge,
    hasConflict: !!opts.hasConflict,
    bookmarks: opts.bookmarks || [],
    parents: opts.parents || [],
    files: opts.files || [],
    stats: opts.stats || { added: 0, removed: 0, files: 0 },
  };
}

// Shared commits used across branches (same change-id appears in multiple branches in jj)
const C = {
  initial: c({
    changeId: "a1b2c3d",  commitShort: "a1b2c3d", type: "feat",
    subject: "Initial commit", author: "Alice", date: "Dec 1",
    stats: { added: 1240, removed: 0, files: 32 },
  }),
  authModule: c({
    changeId: "b2c3d4e", commitShort: "b2c3d4e", type: "feat", version: "v0.1.0",
    subject: "Add authentication module", author: "Bob", date: "Dec 2",
    stats: { added: 412, removed: 18, files: 11 },
  }),
  uiComponents: c({
    changeId: "c3d4e5f", commitShort: "c3d4e5f", type: "fix",
    subject: "Update user interface components", author: "Alice", date: "Dec 3",
    stats: { added: 188, removed: 92, files: 9 },
  }),
  navbugSidebar: c({
    changeId: "d4e5f6g", commitShort: "d4e5f6g", type: "fix",
    subject: "Navigation bug in sidebar", author: "Charlie Davis", date: "Dec 4",
    description: "The Branches link was triggering on hover instead of click.\nDebounced the pointer events and added a focus ring.",
    parents: ["c3d4e5f"],
    stats: { added: 76, removed: 24, files: 5 },
    files: [
      { path: "src/components/BranchColumn.tsx", added: 45, removed: 12, status: "M" },
      { path: "src/components/CommitDetails.tsx", added: 23, removed: 8,  status: "M" },
      { path: "src/types/index.ts",                added: 15, removed: 0,  status: "M" },
      { path: "src/utils/legacy.ts",               added: 0,  removed: 32, status: "D" },
      { path: "src/hooks/useCommits.ts",           added: 8,  removed: 3,  status: "M" },
    ],
  }),
  apiSync: c({
    changeId: "e5f6g7h", commitShort: "e5f6g7h", type: "feat",
    subject: "Add API endpoints for data sync", author: "Bob", date: "Dec 3",
    stats: { added: 322, removed: 14, files: 12 },
  }),
  mergeApiSync: c({
    changeId: "f6g7h8i", commitShort: "f6g7h8i", type: "merge",
    subject: "Merge feature/api-sync into main", author: "Alice", date: "Dec 5",
    isMerge: true,
    stats: { added: 0, removed: 0, files: 0 },
  }),
  updateDeps: c({
    changeId: "g7h8i9j", commitShort: "g7h8i9j", type: "chore",
    subject: "Update dependencies", author: "Charlie Davis", date: "Dec 6",
    stats: { added: 84, removed: 81, files: 4 },
  }),
  testAuth: c({
    changeId: "h8i9j0k", commitShort: "h8i9j0k", type: "test",
    subject: "Add unit tests for auth module", author: "Bob", date: "Dec 7",
    stats: { added: 212, removed: 0, files: 6 },
  }),
  improveErrors: c({
    changeId: "i9j0k1l", commitShort: "i9j0k1l", type: "refactor",
    subject: "Improve error handling", author: "Alice", date: "Dec 8",
    stats: { added: 156, removed: 88, files: 8 },
  }),
  release100: c({
    changeId: "j0k1l2m", commitShort: "j0k1l2m", type: "release", version: "v1.0.0",
    subject: "Release v1.0.0", author: "Alice", date: "Dec 9",
    stats: { added: 4, removed: 4, files: 2 },
  }),
};

// Feature/new-ui specific commits (Flutter app context)
const FU = {
  wc: c({
    changeId: "kpwzlmq", commitShort: "kpwzlmq", type: null,
    subject: "(no description set)", author: "Ralph Stein", date: "now",
    isWorkingCopy: true, isEmpty: true,
    stats: { added: 0, removed: 0, files: 0 },
  }),
  swipe: c({
    changeId: "mxqlbnv", commitShort: "mxqlbnv", type: "feat",
    subject: "feat(onboarding): swipe gestures + haptic feedback", author: "Ralph Stein", date: "3h",
    stats: { added: 142, removed: 18, files: 5 },
    files: [
      { path: "lib/features/onboarding/onboarding_screen.dart", added: 72, removed: 14, status: "M" },
      { path: "lib/features/onboarding/widgets/onboarding_page.dart", added: 48, removed: 0, status: "A" },
      { path: "lib/features/onboarding/widgets/page_indicator.dart", added: 18, removed: 4, status: "M" },
      { path: "lib/core/haptics.dart", added: 4, removed: 0, status: "A" },
    ],
  }),
  indicator: c({
    changeId: "zpnlxbq", commitShort: "zpnlxbq", type: "feat",
    subject: "feat(onboarding): animated page indicator", author: "Ralph Stein", date: "5h",
    hasConflict: true,
    stats: { added: 64, removed: 12, files: 3 },
  }),
  hero: c({
    changeId: "wxklmnp", commitShort: "wxklmnp", type: "feat",
    subject: "feat(onboarding): hero illustrations + lottie loader", author: "Lena König", date: "yesterday",
    stats: { added: 218, removed: 4, files: 8 },
  }),
  scaffold: c({
    changeId: "qvtxnml", commitShort: "qvtxnml", type: "feat",
    subject: "feat(onboarding): scaffold 4-page flow", author: "Lena König", date: "yesterday",
    stats: { added: 184, removed: 0, files: 6 },
  }),
};

window.COMMITS_BY_BRANCH = {
  // main = the trunk; carries the shared history
  main: [
    C.release100, C.improveErrors, C.testAuth, C.updateDeps,
    C.mergeApiSync, C.apiSync, C.navbugSidebar, C.uiComponents,
    C.authModule, C.initial,
  ],
  // develop = a couple of unique WIP commits ahead of main
  develop: [
    c({ changeId: "d1v1abc", commitShort: "d1v1abc", type: "feat",
        subject: "feat(api): paginated responses for /events",
        author: "Bob", date: "2h", stats: { added: 96, removed: 14, files: 4 }}),
    c({ changeId: "d2v2def", commitShort: "d2v2def", type: "refactor",
        subject: "refactor(api): extract response middleware",
        author: "Bob", date: "yesterday", stats: { added: 64, removed: 42, files: 6 }}),
  ],
  // feature/new-ui = the onboarding stack, unique to this branch (long list to demo scrolling)
  "feature/new-ui": [
    FU.wc, FU.swipe, FU.indicator, FU.hero, FU.scaffold,
    c({ changeId: "nbmlpqv", commitShort: "nbmlpqv", type: "feat",
        subject: "feat(onboarding): permission prompt copy + iconography",
        author: "Ralph Stein", date: "2d", stats: { added: 88, removed: 12, files: 4 }}),
    c({ changeId: "trxqvln", commitShort: "trxqvln", type: "feat",
        subject: "feat(onboarding): animated progress dots — final easing",
        author: "Lena König", date: "2d", stats: { added: 42, removed: 18, files: 2 }}),
    c({ changeId: "ksmpqlw", commitShort: "ksmpqlw", type: "fix",
        subject: "fix(onboarding): crash when locale switched mid-flow",
        author: "Ralph Stein", date: "3d", hasConflict: false,
        stats: { added: 16, removed: 4, files: 1 }}),
    c({ changeId: "wnplqbr", commitShort: "wnplqbr", type: "refactor",
        subject: "refactor(onboarding): extract OnboardingController",
        author: "Ralph Stein", date: "3d", stats: { added: 124, removed: 96, files: 5 }}),
    c({ changeId: "vbqlnxr", commitShort: "vbqlnxr", type: "feat",
        subject: "feat(onboarding): theme-aware illustrations (light + dark)",
        author: "Lena König", date: "4d", stats: { added: 312, removed: 4, files: 14 }}),
    c({ changeId: "pmwlnqx", commitShort: "pmwlnqx", type: "chore",
        subject: "chore(deps): bump lottie_flutter to 3.0.2",
        author: "Lena König", date: "4d", stats: { added: 2, removed: 2, files: 1 }}),
    c({ changeId: "rxnlqbm", commitShort: "rxnlqbm", type: "feat",
        subject: "feat(onboarding): track screen-view analytics events",
        author: "Bob", date: "5d", stats: { added: 64, removed: 0, files: 3 }}),
    c({ changeId: "qbnlpmw", commitShort: "qbnlpmw", type: "test",
        subject: "test(onboarding): widget tests for swipe gestures",
        author: "Ralph Stein", date: "5d", stats: { added: 186, removed: 0, files: 4 }}),
    c({ changeId: "mlpwbqr", commitShort: "mlpwbqr", type: "feat",
        subject: "feat(onboarding): copy review pass with marketing",
        author: "Charlie Davis", date: "1w", stats: { added: 48, removed: 36, files: 6 }}),
    c({ changeId: "xnlrqpm", commitShort: "xnlrqpm", type: "fix",
        subject: "fix(onboarding): keyboard pushes hero off-screen on small devices",
        author: "Ralph Stein", date: "1w", stats: { added: 22, removed: 8, files: 2 }}),
    c({ changeId: "blnpqwm", commitShort: "blnpqwm", type: "refactor",
        subject: "refactor(onboarding): split widgets into smaller files",
        author: "Lena König", date: "1w", stats: { added: 240, removed: 220, files: 11 }}),
    c({ changeId: "wqlbnpm", commitShort: "wqlbnpm", type: "feat",
        subject: "feat(onboarding): skip button + telemetry",
        author: "Bob", date: "1w", stats: { added: 56, removed: 4, files: 3 }}),
    c({ changeId: "pnwlbqr", commitShort: "pnwlbqr", type: "feat",
        subject: "feat(onboarding): personalization step (interests picker)",
        author: "Lena König", date: "10d", stats: { added: 412, removed: 0, files: 9 }}),
    c({ changeId: "lqnbpwm", commitShort: "lqnbpwm", type: "feat",
        subject: "feat(onboarding): minimum viable shell + scaffolding",
        author: "Ralph Stein", date: "10d", stats: { added: 318, removed: 0, files: 8 }}),
  ],
  // fix/ios-keyboard = two iOS fixes, unique to this branch
  "fix/ios-keyboard": [
    c({ changeId: "vtxnbqr", commitShort: "vtxnbqr", type: "fix",
        subject: "fix(ios): account for safe area when keyboard opens",
        author: "Ralph Stein", date: "1h", stats: { added: 22, removed: 6, files: 2 }}),
    c({ changeId: "lpmxnvq", commitShort: "lpmxnvq", type: "fix",
        subject: "fix(ios): keyboard avoidance on iPad split view",
        author: "Lena König", date: "3h", stats: { added: 38, removed: 11, files: 3 }}),
  ],
};

window.SAMPLE_DIFF = {
  default: [
    { type: "context", text: "diff --git a/src/components/BranchColumn.tsx b/src/components/BranchColumn.tsx" },
    { type: "context", text: "index a1b2c3d..e5f6g7h 100644" },
    { type: "hunk", text: "@@ -12,7 +12,10 @@ export function BranchColumn() {" },
    { type: "context", text: "return (" },
    { type: "context", text: "  <div className=\"branch-column\">" },
    { type: "remove",  text: "    <h2>Branch</h2>" },
    { type: "add",     text: "    <h2 className=\"branch-header\">" },
    { type: "add",     text: "      {branch.name}" },
    { type: "add",     text: "    </h2>" },
    { type: "context", text: "    <CommitList commits={commits} />" },
    { type: "context", text: "  </div>" },
    { type: "context", text: ");" },
  ],
};

// ============================================================
// GLOBAL HISTORY — the unified jj log graph (newest first)
// Each row knows which lanes are active (drawn as vertical lines)
// and at which lane the commit's node sits.
// Lanes: 0=main(blue), 1=develop(green), 2=feature/new-ui(purple)
// ============================================================
window.LANES = [
  { name: "main",           color: "#3b82f6" },
  { name: "develop",        color: "#22c55e" },
  { name: "feature/new-ui", color: "#a855f7" },
];

// `lanes`: which lanes have a vertical line passing THROUGH this row
// `node`:  which lane has the actual commit node
// `head`:  bookmark label to render at this row (branch tip)
window.HISTORY = [
  { commit: FU.wc,           lanes: [0,1,2], node: 2, head: "feat/new-ui @" },
  { commit: FU.swipe,        lanes: [0,1,2], node: 2 },
  { commit: FU.indicator,    lanes: [0,1,2], node: 2 },
  { commit: FU.hero,         lanes: [0,1,2], node: 2 },
  { commit: FU.scaffold,     lanes: [0,1,2], node: 2 },
  { commit: C.release100,    lanes: [0,1,2], node: 0, head: "main" },
  { commit: C.improveErrors, lanes: [0,1,2], node: 0 },
  { commit: C.testAuth,      lanes: [0,1,2], node: 1, head: "develop" },
  { commit: C.updateDeps,    lanes: [0,1,2], node: 1 },
  { commit: C.mergeApiSync,  lanes: [0,1,2], node: 0 },
  { commit: C.apiSync,       lanes: [0,1,2], node: 0 },
  // navbug is the branch point for feature/new-ui (lane 2 branches off here)
  { commit: C.navbugSidebar, lanes: [0,1,2], node: 0, branchOff: 2 },
  { commit: C.uiComponents,  lanes: [0,1],   node: 0 },
  { commit: C.authModule,    lanes: [0,1],   node: 0 },
  { commit: C.initial,       lanes: [0,1],   node: 0, root: true },
];


// ============================================================
// HOME / PROJECT MANAGER
// Tree of user-managed jj repos. Groups are user-defined virtual
// folders (NOT mirroring the filesystem) used purely for organization.
// ============================================================
// status: "clean" | "dirty" | "ahead" | "behind" | "diverged" | "conflict" | "missing" | "syncing"
window.HOME_TREE = [
  {
    id: "g_work", kind: "group", name: "Work", expanded: true, children: [
      {
        id: "g_mobile", kind: "group", name: "Mobile", expanded: true, children: [
          { id: "p_myapp",   kind: "project", name: "MyApp",          path: "~/code/work/mobile/myapp",         status: "dirty",    branch: "feature/new-ui",  ahead: 6, behind: 0, lastOpened: "now" },
          { id: "p_myapp_ios", kind: "project", name: "myapp-ios",    path: "~/code/work/mobile/myapp-ios",      status: "clean",    branch: "main",            ahead: 0, behind: 0, lastOpened: "2d ago" },
          { id: "p_design_kit", kind: "project", name: "design-kit",  path: "~/code/work/mobile/design-kit",     status: "behind",   branch: "main",            ahead: 0, behind: 3, lastOpened: "5d ago" },
        ]
      },
      {
        id: "g_backend", kind: "group", name: "Backend", expanded: true, children: [
          { id: "p_api",     kind: "project", name: "api-server",     path: "~/code/work/backend/api-server",    status: "ahead",    branch: "develop",         ahead: 2, behind: 0, lastOpened: "1h ago" },
          { id: "p_workers", kind: "project", name: "workers",        path: "~/code/work/backend/workers",       status: "conflict", branch: "fix/queue",       ahead: 1, behind: 2, lastOpened: "yesterday" },
        ]
      },
      { id: "p_infra", kind: "project", name: "infra",                path: "~/code/work/infra",                 status: "clean",    branch: "main",            ahead: 0, behind: 0, lastOpened: "1w ago" },
    ]
  },
  {
    id: "g_oss", kind: "group", name: "Open source", expanded: false, children: [
      { id: "p_ripjj",   kind: "project", name: "ripjj",              path: "~/code/oss/ripjj",                  status: "clean",    branch: "main",            ahead: 0, behind: 0, lastOpened: "3w ago" },
      { id: "p_jj",      kind: "project", name: "jj",                 path: "~/code/oss/jj",                     status: "behind",   branch: "main",            ahead: 0, behind: 42, lastOpened: "1mo ago" },
    ]
  },
  {
    id: "g_play", kind: "group", name: "Playground", expanded: true, children: [
      { id: "p_scratch", kind: "project", name: "scratch",            path: "~/code/play/scratch",               status: "dirty",    branch: "main",            ahead: 0, behind: 0, lastOpened: "yesterday" },
      { id: "p_missing", kind: "project", name: "old-experiment",     path: "~/code/play/old-experiment",        status: "missing",  branch: "—",               ahead: 0, behind: 0, lastOpened: "6mo ago" },
    ]
  },
  // standalone (no group)
  { id: "p_dotfiles", kind: "project", name: "dotfiles",              path: "~/dotfiles",                        status: "clean",    branch: "main",            ahead: 0, behind: 0, lastOpened: "today" },
];

// Currently opened project (matches the existing UI's repo: "myapp")
window.ACTIVE_PROJECT_ID = "p_myapp";

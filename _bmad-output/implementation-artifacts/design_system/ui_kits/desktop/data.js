// Sample repository for the Zanshin desktop UI kit — taken from the floating client's default `jj log` view (graph-data.js, data.js).
// One Flutter app ("MyApp"), trunk at Release v1.0.0, @ on top of the onboarding feature, six side lines of work.
(() => {
  const C = (o) => Object.assign({ parents: [], gapParents: [], bookmarks: [], author: "Ralph Stein", description: "", files: null }, o);
  const changes = [
    C({ id: "wqnwkozp", commit: "b8c9d0e1", subject: "chore(deps): update dependencies", author: "Charlie Davis", date: "Sep 15", t: 14400, lane: 0, immutable: true, endBelow: true, stat: [["M", "pubspec.yaml", 22, 21], ["M", "pubspec.lock", 58, 56], ["M", "ios/Podfile.lock", 3, 3], ["M", "android/build.gradle", 1, 1]] }),
    C({ id: "vruxwmqv", commit: "c9d0e1f2", parents: ["wqnwkozp"], subject: "Release v1.0.0", author: "Alice", date: "Sep 19", t: 8640, lane: 0, immutable: true, bookmarks: [{ name: "main", state: "synced" }], stat: [["M", "pubspec.yaml", 1, 1], ["M", "CHANGELOG.md", 3, 3]] }),

    C({ id: "kkmpptxz", commit: "1f2e3d4c", parents: ["vruxwmqv"], subject: "feat(onboarding): scaffold 4-page flow", author: "Lena König", date: "3d", t: 4320, lane: 0, stat: [["A", "lib/features/onboarding/onboarding_flow.dart", 64, 0], ["A", "lib/features/onboarding/onboarding_page.dart", 48, 0], ["A", "lib/features/onboarding/pages.dart", 40, 0], ["M", "lib/app/router.dart", 12, 0], ["A", "test/features/onboarding/flow_test.dart", 20, 0]] }),
    C({ id: "nlrtpsqy", commit: "2a3b4c5d", parents: ["kkmpptxz"], subject: "feat(onboarding): hero illustrations + lottie loader", author: "Lena König", date: "2d", t: 2880, lane: 0, bookmarks: [{ name: "feature/ZAN-415_hero-assets", state: "synced" }], stat: [["A", "assets/onboarding/hero_1.svg", 1, 0], ["A", "assets/lottie/nami_loader.json", 1, 0], ["M", "pubspec.yaml", 4, 1], ["A", "lib/features/onboarding/hero.dart", 52, 0], ["M", "lib/features/onboarding/onboarding_page.dart", 18, 3]] }),
    C({ id: "xyzrmwpo", commit: "3b4c5d6e", parents: ["nlrtpsqy"], subject: "feat(onboarding): animated page indicator", date: "5h", t: 300, lane: 0, conflict: true, stat: [["A", "lib/features/onboarding/page_indicator.dart", 46, 0], ["M", "lib/features/onboarding/onboarding_flow.dart", 14, 9], ["M", "lib/theme/tokens.dart", 4, 3]] }),
    C({ id: "plkmnvxo", commit: "3c4d5e6f", parents: ["xyzrmwpo"], subject: "feat(onboarding): swipe gestures + haptic feedback", date: "3h", t: 180, lane: 0,
      description: "Pages can now be swiped; each page change triggers a light haptic.\nRespects the system setting for reduced haptics.",
      bookmarks: [{ name: "feature/ZAN-412_onboarding-swipe-gestures", state: "ahead", ahead: 1 }, { name: "review/ZAN-412-v2", state: "local" }],
      files: [
        { path: "lib/features/onboarding/swipe_controller.dart", status: "M", hunks: [
          { oldStart: 12, newStart: 12, ctx: "class SwipeController", lines: ["   final double threshold;", "   final Duration settle;", "-  void onEnd() {", "-    _reset();", "+  void onEnd(DragEndDetails d) {", "+    final v = d.primaryVelocity ?? 0;", "+    if (v.abs() > threshold) {", "+      _commit(v < 0);", "+      Haptics.light();", "+      return;", "+    }", "+    _reset();", "   }"] },
          { oldStart: 40, newStart: 46, ctx: "class SwipeController", lines: ["-  static const _kSettle = 220;", "+  static const _kSettle = 260;", "   static const _kCurve = Curves.easeOutCubic;"] },
        ] },
        { path: "lib/features/onboarding/onboarding_page.dart", status: "M", hunks: [
          { oldStart: 22, newStart: 22, ctx: "Widget build(BuildContext context)", lines: ["     return GestureDetector(", "-      onTap: _next,", "+      onHorizontalDragUpdate: _swipe.onUpdate,", "+      onHorizontalDragEnd: _swipe.onEnd,", "       child: PageView(", "-        physics: const NeverScrollableScrollPhysics(),", "+        controller: _swipe.pages,"] },
        ] },
        { path: "lib/platform/haptics.dart", status: "A", hunks: [
          { oldStart: 0, newStart: 1, ctx: "", lines: ["+import 'package:flutter/services.dart';", "+", "+/// Light feedback for page changes. Silent when the user reduced haptics.", "+abstract final class Haptics {", "+  static bool enabled = true;", "+  static Future<void> light() async {", "+    if (!enabled) return;", "+    await HapticFeedback.lightImpact();", "+  }", "+}"] },
        ] },
        { path: "test/features/onboarding/swipe_controller_test.dart", status: "A", hunks: [
          { oldStart: 0, newStart: 1, ctx: "", lines: ["+void main() {", "+  test('fast swipe commits', () {", "+    final c = SwipeController(threshold: 400);", "+    c.onEnd(DragEndDetails(primaryVelocity: -900));", "+    expect(c.page, 1);", "+  });", "+}"] },
        ] },
      ] }),
    C({ id: "ovknlmro", commit: "4d5e6f70", parents: ["plkmnvxo"], subject: "", date: "now", t: 0, lane: 0, files: [] }),

    C({ id: "uwqmpnrk", commit: "5e6f7081", parents: ["xyzrmwpo"], subject: "exp: migrate providers to riverpod 3 codegen", date: "1h", t: 60, lane: 1, stat: [["M", "pubspec.yaml", 3, 2], ["M", "lib/state/providers.dart", 40, 62], ["M", "lib/state/auth_state.dart", 22, 30], ["A", "build.yaml", 8, 0]] }),
    C({ id: "kzrmqvnt", commit: "6f708192", parents: ["uwqmpnrk"], subject: "exp: generate providers for settings + auth", date: "50m", t: 50, lane: 1, stat: [["A", "lib/state/settings_provider.g.dart", 30, 0], ["M", "lib/state/auth_state.dart", 9, 14]] }),
    C({ id: "tnrkslqw", commit: "708192a3", parents: ["kzrmqvnt"], subject: "exp: drop legacy ChangeNotifier wrappers", date: "40m", t: 40, lane: 1, bookmarks: [{ name: "exp/riverpod-3", state: "local" }], stat: [["D", "lib/state/settings_notifier.dart", 0, 64], ["M", "lib/settings/settings_page.dart", 12, 18]] }),

    C({ id: "lpmxnvqr", commit: "8192a3b4", parents: ["vruxwmqv"], subject: "fix(ios): keyboard avoidance on iPad split view", author: "Lena König", date: "5h", t: 300, lane: 2, stat: [["M", "lib/widgets/keyboard_inset.dart", 26, 9], ["M", "ios/Runner/Info.plist", 2, 0]] }),
    C({ id: "vtxnbqrs", commit: "92a3b4c5", parents: ["lpmxnvqr"], subject: "fix(ios): account for safe area when keyboard opens", date: "1h", t: 60, lane: 2, bookmarks: [{ name: "fix/ZAN-398_ios-keyboard-safe-area", state: "synced" }], stat: [["M", "lib/widgets/keyboard_inset.dart", 16, 5], ["M", "test/widgets/keyboard_inset_test.dart", 6, 1]] }),

    C({ id: "mwoqxlpn", commit: "a3b4c5d6", parents: ["vruxwmqv"], subject: "feat(api): paginated responses for /events", author: "Bob", date: "1d", t: 1440, lane: 3, stat: [["M", "lib/api/events_client.dart", 38, 9], ["A", "lib/api/page.dart", 30, 0]] }),
    C({ id: "rsyntlvq", commit: "b4c5d6e7", parents: ["mwoqxlpn"], subject: "refactor(api): extract response middleware", author: "Bob", date: "20h", t: 1200, lane: 3, stat: [["A", "lib/api/middleware.dart", 34, 0], ["M", "lib/api/events_client.dart", 12, 30]] }),
    C({ id: "hvsmqplk", commit: "c5d6e7f8", parents: ["rsyntlvq"], subject: "test(api): contract tests for pagination", author: "Bob", date: "10h", t: 600, lane: 3, stat: [["A", "test/api/pagination_contract_test.dart", 48, 0]] }),
    C({ id: "jqntwrpx", commit: "d6e7f809", parents: ["hvsmqplk"], subject: "perf(api): cache page cursors", author: "Charlie Davis", date: "3h", t: 180, lane: 3, stat: [["M", "lib/api/page.dart", 21, 6], ["M", "lib/api/events_client.dart", 9, 4]] }),
    C({ id: "kxwsnptm", commit: "e7f8091a", parents: ["jqntwrpx", "vtxnbqrs"], subject: "merge: bring iOS keyboard fix into develop", author: "Bob", date: "30m", t: 30, lane: 3, merge: true, bookmarks: [{ name: "develop", state: "ahead", ahead: 2 }], files: [] }),
    C({ id: "srkvzmop", commit: "0aa3b3c4", gapParents: ["kxwsnptm", "potwkszn"], subject: "release: bump to 1.1.0-rc1", author: "Bob", date: "1h", t: 60, lane: 3, bookmarks: [{ name: "release/1.1.0-rc1", state: "local" }], stat: [["M", "pubspec.yaml", 1, 1], ["M", "CHANGELOG.md", 14, 0]] }),

    C({ id: "qmsvtlkr", commit: "f8091a2b", parents: ["vruxwmqv"], subject: "feat(settings): section-based layout", author: "Lena König", date: "2d", t: 2880, lane: 4, stat: [["M", "lib/settings/settings_page.dart", 44, 30], ["A", "lib/settings/section.dart", 36, 0]] }),
    C({ id: "wrnxqpsz", commit: "091a2b3c", parents: ["qmsvtlkr"], subject: "feat(settings): theme picker with live preview", author: "Lena König", date: "2d", t: 2860, lane: 4, stat: [["A", "lib/settings/theme_picker.dart", 52, 0], ["M", "lib/theme/theme.dart", 10, 6]] }),
    C({ id: "ynkplrtv", commit: "1a2b3c4d", parents: ["wrnxqpsz"], subject: "refactor(settings): move prefs to typed store", date: "1d", t: 1440, lane: 4, stat: [["A", "lib/settings/prefs_store.dart", 40, 0], ["D", "lib/settings/prefs.dart", 0, 58]] }),
    C({ id: "sxmtvqno", commit: "2b3c4d5e", parents: ["ynkplrtv"], subject: "test(settings): golden tests for all sections", author: "Lena König", date: "20h", t: 1200, lane: 4, stat: [["A", "test/settings/golden_test.dart", 60, 0]] }),
    C({ id: "lvqrnkmw", commit: "3c4d5e6a", parents: ["sxmtvqno"], subject: "fix(settings): dark-mode contrast in toggles", author: "Lena König", date: "8h", t: 480, lane: 4, stat: [["M", "lib/settings/toggle_row.dart", 8, 6], ["M", "lib/theme/tokens.dart", 6, 3]] }),
    C({ id: "potwkszn", commit: "4d5e6f7b", parents: ["lvqrnkmw"], subject: "feat(settings): account & sign-out section", author: "Lena König", date: "4h", t: 240, lane: 4, bookmarks: [{ name: "feature/ZAN-430_settings-redesign", state: "ahead", ahead: 3 }], stat: [["A", "lib/settings/account_section.dart", 58, 0], ["M", "lib/settings/settings_page.dart", 6, 5]] }),

    C({ id: "nqxwrptl", commit: "5e6f7a8c", parents: ["vruxwmqv"], subject: "docs: API reference skeleton", author: "Charlie Davis", date: "1d", t: 1440, lane: 5, stat: [["A", "docs/api/README.md", 40, 0], ["A", "docs/api/events.md", 28, 0]] }),
    C({ id: "tzkvmrls", commit: "6f7a8b9d", parents: ["nqxwrptl"], subject: "docs: document pagination params", author: "Charlie Davis", date: "1d", t: 1400, lane: 5, stat: [["M", "docs/api/events.md", 24, 2]] }),
    C({ id: "mrplxqwv", commit: "7a8b9cae", parents: ["tzkvmrls"], subject: "docs: auth flow sequence diagrams", author: "Charlie Davis", date: "12h", t: 720, lane: 5, bookmarks: [{ name: "docs/api-reference", state: "local" }], stat: [["A", "docs/api/auth.md", 36, 0], ["M", "docs/api/README.md", 4, 4]] }),

    C({ id: "pnwqxrtk", commit: "8b9cadbf", parents: ["vruxwmqv"], subject: "feat(cache): offline store schema", author: "Lena König", date: "3d", t: 4320, lane: 6, stat: [["A", "lib/cache/schema.dart", 56, 0], ["M", "pubspec.yaml", 2, 0]] }),
    C({ id: "qrvtmkxl", commit: "9cadbec0", parents: ["pnwqxrtk"], subject: "feat(cache): write-through repository", author: "Lena König", date: "3d", t: 4300, lane: 6, stat: [["A", "lib/cache/repository.dart", 48, 0], ["M", "lib/cache/schema.dart", 6, 12]] }),
    C({ id: "vkxnrslp", commit: "adbecfd1", gapParents: ["qrvtmkxl"], subject: "feat(cache): sync queue with retry", date: "1d", t: 1440, lane: 6, stat: [["A", "lib/cache/sync_queue.dart", 62, 0], ["M", "lib/cache/repository.dart", 9, 9]] }),
    C({ id: "tqwmlnxz", commit: "becfd0e2", parents: ["vkxnrslp"], subject: "feat(cache): conflict banner in list views", date: "20h", t: 1200, lane: 6, stat: [["A", "lib/cache/conflict_banner.dart", 40, 0], ["M", "lib/features/list/list_page.dart", 8, 7]] }),
    C({ id: "xrlpkvqm", commit: "cfd0e1f3", parents: ["tqwmlnxz"], subject: "test(cache): queue replay integration tests", date: "9h", t: 540, lane: 6, stat: [["A", "integration_test/queue_replay_test.dart", 64, 0]] }),
    C({ id: "mxnztwqp", commit: "d0e1f2a4", parents: ["xrlpkvqm"], subject: "feat(cache): settings toggle for offline mode", date: "2h", t: 120, lane: 6, bookmarks: [{ name: "feature/ZAN-440_offline-cache", state: "ahead", ahead: 2 }], stat: [["M", "lib/settings/settings_page.dart", 14, 3], ["M", "lib/cache/config.dart", 8, 0]] }),
  ];

  // Projects tree — exactly the client's HOME_TREE
  const HOME_TREE = [
    { id: "g_work", kind: "group", name: "Work", expanded: true, children: [
      { id: "g_mobile", kind: "group", name: "Mobile", expanded: true, children: [
        { id: "p_myapp", kind: "project", name: "MyApp", path: "~/code/work/mobile/myapp", status: "dirty", branch: "feature/new-ui", ahead: 6, behind: 0, lastOpened: "now" },
        { id: "p_myapp_ios", kind: "project", name: "myapp-ios", path: "~/code/work/mobile/myapp-ios", status: "clean", branch: "main", ahead: 0, behind: 0, lastOpened: "2d ago" },
        { id: "p_design_kit", kind: "project", name: "design-kit", path: "~/code/work/mobile/design-kit", status: "behind", branch: "main", ahead: 0, behind: 3, lastOpened: "5d ago" },
      ] },
      { id: "g_backend", kind: "group", name: "Backend", expanded: true, children: [
        { id: "p_api", kind: "project", name: "api-server", path: "~/code/work/backend/api-server", status: "ahead", branch: "develop", ahead: 2, behind: 0, lastOpened: "1h ago" },
        { id: "p_workers", kind: "project", name: "workers", path: "~/code/work/backend/workers", status: "conflict", branch: "fix/queue", ahead: 1, behind: 2, lastOpened: "yesterday" },
      ] },
      { id: "p_infra", kind: "project", name: "infra", path: "~/code/work/infra", status: "clean", branch: "main", ahead: 0, behind: 0, lastOpened: "1w ago" },
    ] },
    { id: "g_oss", kind: "group", name: "Open source", expanded: false, children: [
      { id: "p_ripjj", kind: "project", name: "ripjj", path: "~/code/oss/ripjj", status: "clean", branch: "main", ahead: 0, behind: 0, lastOpened: "3w ago" },
      { id: "p_jj", kind: "project", name: "jj", path: "~/code/oss/jj", status: "behind", branch: "main", ahead: 0, behind: 42, lastOpened: "1mo ago" },
    ] },
    { id: "g_play", kind: "group", name: "Playground", expanded: true, children: [
      { id: "p_scratch", kind: "project", name: "scratch", path: "~/code/play/scratch", status: "dirty", branch: "main", ahead: 0, behind: 0, lastOpened: "yesterday" },
      { id: "p_missing", kind: "project", name: "old-experiment", path: "~/code/play/old-experiment", status: "missing", branch: "—", ahead: 0, behind: 0, lastOpened: "6mo ago" },
    ] },
    { id: "p_dotfiles", kind: "project", name: "dotfiles", path: "~/dotfiles", status: "clean", branch: "main", ahead: 0, behind: 0, lastOpened: "today" },
  ];

  const REVSETS = [
    { id: "default", cmd: "jj log", desc: "Default revset — your mutable changes plus trunk context" },
    { id: "all", cmd: "jj log -r 'all()'", desc: "Every visible commit, incl. immutable history and untracked remotes" },
  ];
  // jj log configurations — exactly the client's seed (revset-config.jsx); RevsetDialog.exprOf() turns the rules into the revset
  const CONFIGS = [
    { id: "c-onb", name: "Onboarding feature", op: "&", rules: [{ fn: "files", mode: "prefix", value: "lib/features/onboarding/", not: false }] },
    { id: "c-lena", name: "Lena's changes", op: "&", rules: [{ fn: "author", mode: "substring", ci: true, value: "Lena", not: false }] },
    { id: "c-fix", name: "My fixes", op: "&", rules: [{ fn: "mine", not: false }, { fn: "subject", mode: "glob", value: "fix*", not: false }] },
  ];
  const OPS = [
    { cmd: 'describe -m "wip: refactor"', when: "8 min ago" },
    { cmd: "new -A @", when: "12 min ago" },
    { cmd: "git fetch", when: "2h ago" },
  ];

  // ---- diffs for changes that only list file stats: a deterministic, plausible Dart / Markdown / YAML hunk per file ----
  const pascal = (s) => s.replace(/\.[a-z.]+$/, "").split(/[_\-]/).filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join("") || "Thing";
  const POOL = {
    dart: {
      add: ["  final {T}Repository _repo;", "  {T}State get state => _state;", "  if (_state.isLoading) return;", "  await _repo.load{T}();", "  _controller.addListener(_on{T}Changed);", "  @override", "  Widget build(BuildContext context) {", "    return {T}View(state: state);", "  }", "  void _on{T}Changed() => notifyListeners();", "  static const _kDuration = Duration(milliseconds: 240);", "  Future<void> refresh() async {", "    _state = await _repo.fetch{T}();", "  }"],
      rem: ["  final ChangeNotifier _notifier;", "  void dispose() => _notifier.dispose();", "  // TODO: migrate {T} to the typed store", "  setState(() {});", "  _notifier.notifyListeners();"],
      ctx: ["class {T} {", "  const {T}({super.key});", "}"],
    },
    md: { add: ["## {T}", "", "Every request is paginated; pass `cursor` to continue.", "| Param | Type | Default |", "| `limit` | int | 50 |", "See also: [Events](events.md)."], rem: ["TODO: write this section", "_Draft_"], ctx: ["# API reference", ""] },
    yaml: { add: ["  {t}: ^3.1.0", "  build_runner: ^2.4.9", "version: 1.1.0-rc1"], rem: ["  {t}: ^2.4.0", "version: 1.0.0"], ctx: ["dependencies:", "dev_dependencies:"] },
  };
  function seeded(str) { let h = 2166136261; for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); } return () => ((h = Math.imul(h ^ (h >>> 15), 2246822507) >>> 0) / 4294967296); }
  function genFile([status, path, a, r]) {
    const ext = path.endsWith(".md") ? "md" : /\.(ya?ml|lock)$/.test(path) ? "yaml" : "dart";
    const P = POOL[ext], T = pascal(path.split("/").pop()), rnd = seeded(path);
    const fill = (s) => s.replace(/\{T\}/g, T).replace(/\{t\}/g, T.toLowerCase());
    const pick = (arr) => fill(arr[Math.floor(rnd() * arr.length)]);
    const na = Math.min(a, 9), nr = Math.min(r, status === "D" ? 12 : 4);
    const hunks = [];
    if (status === "D") hunks.push({ oldStart: 1, newStart: 0, ctx: "", lines: Array.from({ length: nr }, () => "-" + pick(P.rem.concat(P.ctx))) });
    else if (status === "A") hunks.push({ oldStart: 0, newStart: 1, ctx: "", lines: Array.from({ length: na }, () => "+" + pick(P.add)) });
    else {
      const split = na > 4 ? 2 : 1;
      for (let k = 0; k < split; k++) {
        const ia = Math.ceil(na / split), ir = Math.ceil(nr / split);
        hunks.push({ oldStart: 10 + k * 34 + Math.floor(rnd() * 8), newStart: 10 + k * 36 + Math.floor(rnd() * 8), ctx: ext === "dart" ? "class " + T : "",
          lines: [" " + pick(P.ctx), ...Array.from({ length: ir }, () => "-" + pick(P.rem)), ...Array.from({ length: ia }, () => "+" + pick(P.add)), " " + pick(P.ctx)] });
      }
    }
    return { path, status, hunks };
  }
  let hseq = 0;
  changes.forEach((c) => {
    if (!c.files) c.files = (c.stat || []).map(genFile);
    c.files.forEach((f) => f.hunks.forEach((h) => { h.id = "h" + (++hseq); }));
    delete c.stat;
  });

  window.ZK_DATA = { me: "Ralph Stein", email: "ralph@dasralph.de", now: "2026-09-25T14:00", changes, wc: "ovknlmro", HOME_TREE, activeProjectId: "p_myapp", REVSETS, CONFIGS, OPS, opCount: 142 };
})();

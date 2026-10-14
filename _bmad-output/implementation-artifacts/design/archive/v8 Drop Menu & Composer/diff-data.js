// Per-change diffs for the inspector: files → hunks → lines. Hand-written for the stories the prototype tells
// (@ and the swipe-gestures change), generated deterministically for everything else so every card can be opened, split and moved.
(function () {
  let seq = 0;
  window.newHunkId = () => "h" + (++seq).toString(36);
  const L = (arr) => arr.map(s => ({ k: s[0] === "+" ? "+" : s[0] === "-" ? "-" : " ", s: s.slice(2) }));
  const H = (oldStart, newStart, ctx, lines) => ({ id: window.newHunkId(), oldStart, newStart, ctx, lines: L(lines) });
  const F = (path, status, hunks) => ({ path, status, hunks });

  const HAND = {
    // working copy: a skip button, its string, and a test — three things that want to be two commits
    ovknlmro: () => [
      F("lib/features/onboarding/onboarding_screen.dart", "M", [
        H(52, 52, "Widget build(BuildContext context)", [
          "        itemBuilder: (context, i) => OnboardingPage(data: pages[i]),",
          "      );",
          "    }",
          "+ ",
          "+   Widget _skip() {",
          "+     return TextButton(",
          "+       onPressed: _finish,",
          "+       child: Text(context.l10n.onboardingSkip),",
          "+     );",
          "+   }",
        ]),
        H(74, 81, "void _finish()", [
          "    void _finish() {",
          "+     Analytics.log('onboarding_finished', {'page': _page});",
          "+     Prefs.onboardingDone = true;",
          "      Navigator.of(context).pushReplacementNamed('/home');",
          "    }",
        ]),
      ]),
      F("lib/l10n/app_de.arb", "M", [
        H(18, 18, "", [
          "    \"onboardingTitle\": \"Willkommen bei MyApp\",",
          "-   \"onboardingNext\": \"Weiter\"",
          "+   \"onboardingNext\": \"Weiter\",",
          "+   \"onboardingSkip\": \"Überspringen\"",
          "  }",
        ]),
      ]),
      F("test/features/onboarding/onboarding_screen_test.dart", "A", [
        H(0, 1, "", [
          "+ import 'package:flutter_test/flutter_test.dart';",
          "+ ",
          "+ import 'package:myapp/features/onboarding/onboarding_screen.dart';",
          "+ ",
          "+ void main() {",
          "+   testWidgets('skip jumps straight to home', (tester) async {",
          "+     await tester.pumpWidget(const TestApp(child: OnboardingScreen()));",
          "+     await tester.tap(find.text('Skip'));",
          "+     await tester.pumpAndSettle();",
          "+     expect(find.byType(HomeScreen), findsOneWidget);",
          "+   });",
          "+ }",
        ]),
      ]),
    ],
    plkmnvxo: () => [
      F("lib/features/onboarding/onboarding_screen.dart", "M", [
        H(1, 1, "", [
          "  import 'package:flutter/material.dart';",
          "+ import 'package:flutter/services.dart';",
          "  ",
          "  import '../../core/analytics.dart';",
          "+ import '../../core/haptics.dart';",
          "  import 'widgets/onboarding_page.dart';",
        ]),
        H(38, 40, "class _OnboardingScreenState", [
          "    @override",
          "    Widget build(BuildContext context) {",
          "-     return PageView(",
          "-       controller: _controller,",
          "-       children: pages.map((p) => OnboardingPage(data: p)).toList(),",
          "+     return PageView.builder(",
          "+       controller: _controller,",
          "+       itemCount: pages.length,",
          "+       onPageChanged: (index) {",
          "+         Haptics.selection();",
          "+         setState(() => _page = index);",
          "+       },",
          "+       itemBuilder: (context, i) => OnboardingPage(data: pages[i]),",
          "      );",
          "    }",
        ]),
        H(61, 68, "Widget _indicator()", [
          "    Widget _indicator() {",
          "-     return PageIndicator(count: pages.length, index: _page);",
          "+     return AnimatedBuilder(",
          "+       animation: _controller,",
          "+       builder: (_, __) => PageIndicator(count: pages.length, offset: _controller.page ?? 0),",
          "+     );",
          "    }",
        ]),
      ]),
      F("lib/features/onboarding/widgets/onboarding_page.dart", "A", [
        H(0, 1, "", [
          "+ import 'package:flutter/material.dart';",
          "+ ",
          "+ import '../onboarding_data.dart';",
          "+ ",
          "+ class OnboardingPage extends StatelessWidget {",
          "+   const OnboardingPage({super.key, required this.data});",
          "+ ",
          "+   final OnboardingData data;",
          "+ ",
          "+   @override",
          "+   Widget build(BuildContext context) {",
          "+     return Column(children: [",
          "+       Expanded(child: Lottie.asset(data.animation)),",
          "+       Text(data.title, style: Theme.of(context).textTheme.headlineSmall),",
          "+       Text(data.body, textAlign: TextAlign.center),",
          "+     ]);",
          "+   }",
          "+ }",
        ]),
      ]),
      F("lib/features/onboarding/widgets/page_indicator.dart", "M", [
        H(4, 4, "class PageIndicator", [
          "  class PageIndicator extends StatelessWidget {",
          "-   const PageIndicator({super.key, required this.count, required this.index});",
          "+   const PageIndicator({super.key, required this.count, required this.offset});",
          "  ",
          "    final int count;",
          "-   final int index;",
          "+   final double offset;",
        ]),
        H(19, 19, "Widget build(BuildContext context)", [
          "      children: List.generate(count, (i) {",
          "-       final active = i == index;",
          "+       final t = (1 - (offset - i).abs()).clamp(0.0, 1.0);",
          "+       final width = 8 + 16 * t;",
          "        return AnimatedContainer(",
        ]),
      ]),
      F("lib/core/haptics.dart", "A", [
        H(0, 1, "", [
          "+ import 'package:flutter/services.dart';",
          "+ ",
          "+ /// One place for haptic vocabulary, so every screen feels the same.",
          "+ abstract final class Haptics {",
          "+   static Future<void> selection() => HapticFeedback.selectionClick();",
          "+   static Future<void> success() => HapticFeedback.mediumImpact();",
          "+ }",
        ]),
      ]),
    ],
  };

  // ---------- generated ----------
  const rng = (seed) => { let s = 7; for (const ch of seed) s = (s * 31 + ch.charCodeAt(0)) >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; };
  const POOL = {
    settings: ["settings_screen.dart", "settings_section.dart", "theme_picker.dart", "prefs_store.dart", "account_section.dart", "toggle_tile.dart", "section_header.dart", "search_index.dart"],
    onboarding: ["onboarding_flow.dart", "onboarding_data.dart", "hero_illustration.dart", "page_indicator.dart", "assets/lottie/loader.json", "onboarding_routes.dart"],
    api: ["events_api.dart", "pagination.dart", "response_middleware.dart", "cursor_cache.dart", "api_client.dart", "sync_endpoint.dart"],
    cache: ["offline_store.dart", "write_through_repository.dart", "sync_queue.dart", "conflict_banner.dart", "cache_models.freezed.dart", "offline_toggle.dart"],
    ios: ["ios/Runner/AppDelegate.swift", "lib/core/keyboard_inset.dart", "lib/core/safe_area.dart"],
    docs: ["docs/api/README.md", "docs/api/pagination.md", "docs/auth/flow.md", "docs/auth/sequence.md", "docs/index.md"],
    deps: ["pubspec.yaml", "pubspec.lock", "ios/Podfile.lock", "android/app/build.gradle"],
    l10n: ["lib/l10n/app_de.arb", "lib/l10n/app_pl.arb", "lib/l10n/app_en.arb"],
    exp: ["providers.dart", "providers.g.dart", "auth_provider.dart", "settings_provider.dart", "legacy_notifiers.dart", "build.yaml"],
    core: ["lib/main.dart", "lib/app.dart", "lib/core/router.dart", "lib/core/theme.dart", "lib/core/image_cache.dart", "lib/core/analytics.dart", "lib/ui/components/button.dart", "lib/ui/components/card.dart"],
  };
  const DART = ["final theme = Theme.of(context);", "if (!mounted) return;", "return const SizedBox.shrink();", "await repository.sync();", "final page = await api.fetch(cursor: cursor);",
    "setState(() => _loading = false);", "padding: const EdgeInsets.all(16),", "onTap: () => context.go('/settings'),", "final items = snapshot.data ?? const [];", "_controller.dispose();",
    "ref.watch(settingsProvider);", "debugPrint('cache miss for $key');", "return Text(label, style: style);", "duration: const Duration(milliseconds: 250),", "case SyncState.offline:",
    "expect(find.byType(Toggle), findsWidgets);", "final cursor = response.headers['x-next-cursor'];", "@override", "child: Column(children: children),", "throw StateError('unreachable');",
    "notifyListeners();", "final store = OfflineStore(db);", "if (value == null) return fallback;", "await tester.pumpAndSettle();", "const SectionHeader(title: 'Account'),", "},", "],", "});"];
  const POOLX = {
    md: ["## Pagination", "Use `cursor` to fetch the next page.", "| Param | Type | Default |", "|-------|------|---------|", "- `limit` — items per page (max 100)", "```dart", "```", "The token refreshes automatically.", ""],
    yaml: ["  flutter_riverpod: ^3.0.0", "  intl: ^0.19.0", "  lottie: ^3.1.2", "  freezed_annotation: ^2.4.4", "version: 1.1.0+12", "  build_runner: ^2.4.13", "  sha256: \"9b2f…\""],
    arb: ["\"settingsTitle\": \"Einstellungen\",", "\"accountSignOut\": \"Abmelden\",", "\"pluralItems\": \"{count, plural, one{# Eintrag} other{# Einträge}}\",", "\"offlineBanner\": \"Offline – Änderungen werden später synchronisiert\","],
    swift: ["override func application(_ application: UIApplication,", "  window?.rootViewController = controller", "GeneratedPluginRegistrant.register(with: self)", "NotificationCenter.default.addObserver(self,"],
    json: ["{\"v\":\"5.9.0\",\"fr\":60,\"ip\":0,\"op\":90,", "\"layers\":[{\"ty\":4,\"nm\":\"wave\"}]}"],
    gradle: ["    minSdkVersion 23", "    targetSdkVersion 34", "    implementation 'androidx.core:core-ktx:1.13.1'"],
    lock: ["  lottie:", "    version: \"3.1.2\"", "  intl:", "    version: \"0.19.0\"", "    dependency: \"direct main\""],
  };
  const CTX = ["Widget build(BuildContext context)", "class SettingsScreen", "Future<void> load()", "void dispose()", "Future<Page<Event>> fetch()", "class OfflineStore", "final routes", "void main()", "group('pagination')", "class _State"];
  const scopeOf = (c) => {
    const m = (c.subject || "").match(/^\w+\(([^)]+)\)/), s = m ? m[1] : "";
    if (/settings/.test(s) || /settings/.test(c.subject)) return "settings";
    if (/onboarding/.test(s)) return "onboarding";
    if (/cache/.test(s)) return "cache";
    if (/ios/.test(s)) return "ios";
    if (/l10n/.test(s)) return "l10n";
    if (/deps/.test(s)) return "deps";
    if (/api/.test(s)) return "api";
    if (/^docs/.test(c.subject)) return "docs";
    if (/^exp/.test(c.subject)) return "exp";
    return "core";
  };
  const full = (scope, name, test) => {
    if (name.includes("/")) return name;
    const base = scope === "exp" ? "lib/state/" : scope === "core" ? "lib/" : "lib/features/" + scope + "/";
    return test ? base.replace(/^lib\//, "test/").replace(/\.dart$/, "") + name.replace(/\.dart$/, "_test.dart") : base + name;
  };
  const ext = (p) => /\.md$/.test(p) ? "md" : /\.ya?ml$/.test(p) ? "yaml" : /\.arb$/.test(p) ? "arb" : /\.swift$/.test(p) ? "swift" : /\.json$/.test(p) ? "json" : /\.gradle$/.test(p) ? "gradle" : /\.lock$/.test(p) ? "lock" : "dart";
  const parts = (total, n, R) => {
    if (n <= 0) return [];
    const w = Array.from({ length: n }, () => 0.25 + R()), sum = w.reduce((a, b) => a + b, 0);
    const out = w.map(x => Math.floor(total * x / sum));
    let rest = total - out.reduce((a, b) => a + b, 0);
    for (let i = 0; rest > 0; i = (i + 1) % n, rest--) out[i]++;
    return out;
  };
  const line = (e, R) => { const p = e === "dart" ? DART : POOLX[e]; const s = p[Math.floor(R() * p.length)]; return e === "dart" ? " ".repeat(2 * (1 + Math.floor(R() * 3))) + s : s; };
  function genFile(path, status, a, d, R) {
    const e = ext(path);
    if (status === "A") return F(path, "A", [{ id: window.newHunkId(), oldStart: 0, newStart: 1, ctx: "", lines: Array.from({ length: a }, () => ({ k: "+", s: line(e, R) })) }]);
    if (status === "D") return F(path, "D", [{ id: window.newHunkId(), oldStart: 1, newStart: 0, ctx: "", lines: Array.from({ length: d }, () => ({ k: "-", s: line(e, R) })) }]);
    const n = Math.max(1, Math.min(4, Math.ceil((a + d) / 14)));
    const A = parts(a, n, R), D = parts(d, n, R);
    let o = 8 + Math.floor(R() * 20), nw = o;
    const hunks = A.map((ai, i) => {
      const lines = [{ k: " ", s: line(e, R) }, { k: " ", s: line(e, R) }];
      for (let j = 0; j < D[i]; j++) lines.push({ k: "-", s: line(e, R) });
      for (let j = 0; j < ai; j++) lines.push({ k: "+", s: line(e, R) });
      lines.push({ k: " ", s: line(e, R) });
      const h = { id: window.newHunkId(), oldStart: o, newStart: nw, ctx: e === "dart" ? CTX[Math.floor(R() * CTX.length)] : "", lines };
      o += D[i] + 3 + 10 + Math.floor(R() * 30); nw += ai + 3 + 10 + Math.floor(R() * 30);
      return h;
    }).filter(h => h.lines.some(l => l.k !== " "));
    return F(path, "M", hunks);
  }
  function generate(c) {
    const st = c.stats || {}, total = (st.added || 0) + (st.removed || 0);
    if (c.isRoot || !st.files || !total) return [];
    const R = rng(c.id), scope = scopeOf(c), pool = POOL[scope];
    const n = Math.min(st.files, total);
    const testy = /^test/.test(c.subject);
    const paths = [], used = new Set();
    for (let i = 0; paths.length < n; i++) {
      const name = pool[(i + Math.floor(R() * pool.length)) % pool.length];
      let p = full(scope, name, testy);
      if (used.has(p)) p = p.replace(/(\.\w+)$/, "_" + (i + 2) + "$1");
      used.add(p); paths.push(p);
    }
    const A = parts(st.added || 0, n, R), D = parts(st.removed || 0, n, R);
    return paths.map((p, i) => {
      if (A[i] + D[i] === 0) { if ((st.added || 0) >= (st.removed || 0)) A[i] = 1; else D[i] = 1; }
      const status = D[i] === 0 ? (R() < 0.45 ? "A" : "M") : A[i] === 0 && R() < 0.4 ? "D" : "M";
      return genFile(p, status, A[i], D[i], R);
    });
  }

  window.buildDiffs = (commits) => {
    const out = {};
    commits.forEach(c => { out[c.id] = HAND[c.id] ? HAND[c.id]() : generate(c); });
    return out;
  };
})();

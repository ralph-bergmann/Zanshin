---
title: 'Story 11.16 — l10n-ready: the app''s strings move into ARB files (English only)'
type: 'refactor'
created: '2026-10-31'
status: 'done'
baseline_revision: '2e3980286cea8c743b9949d750249fefa330edbc'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The story was closed without the Marionette check in the running catalogue; the rendered text is checked only by widget tests.
    evidence: |-
      Verification lists "Not done: the Marionette visual check in the catalogue". Whether the live Projects window, graph cards, splash and window titles show the same text is unchecked; a Marionette pass over the catalogue would settle it.
    location: >-
      app/widgetbook (catalogue), Projects window and graph use cases
    severity: medium (unverified)
  - summary: >-
      The native macOS strings (MainMenu.xib menu titles, no CFBundleLocalizations in Info.plist) are outside the l10n setup.
    evidence: |-
      MainMenu.xib keeps English titles such as "Preferences…"; Info.plist declares no CFBundleLocalizations. The story's scope was app/lib and packages/zanshin_ui/lib, so this predates it. Story 11.13 (the app menu) is where it closes.
    location: >-
      app/macos/Runner/Base.lproj/MainMenu.xib:35
    severity: low
    resolved: >-
      2026-11-01 — fixed (spec-11-13-menu-bar-shortcuts, commit 0d7811d): every Dart menu label is an ARB string in the PlatformMenuBar; system items keep the xib titles; CFBundleLocalizations waits for a second language.
---

<intent-contract>

## Intent

**Problem:** Every user-facing string in `app/lib` and `packages/zanshin_ui/lib` is a hard-coded English literal and there is no l10n setup, so a later translation would mean touching every widget. Ralph decided (2026-10-31, deferred-work.md "English-only app, or translated?", item I1): English only, but l10n-ready.

**Approach:** Set up Flutter's `gen-l10n` (one ARB per package that ships UI text: `app` → `AppLocalizations`, `zanshin_ui` → `ZsLocalizations`), move every user-facing string into the English ARB with a key and a description (ICU placeholders/plurals), format dates through `intl` at the app's locale, record the house rule, and add a guard test that fails on a hard-coded UI string in `app/lib`.

## Boundaries & Constraints

**Always:**
- The app shows exactly the same English text as before (labels, tooltips, captions, menus, dialogs, VoiceOver labels, splash status, window titles).
- `supportedLocales` is `[en]`; every ARB entry carries an `@key` description (`required-resource-attributes: true`); plurals and placeholders use ICU syntax.
- Generated localization code is committed and produced only by an explicit `flutter gen-l10n` run in the package directory (no `flutter: generate: true` — the project's "build never auto-regenerates" codegen rule); it passes `dart format` and `dart analyze --fatal-infos --fatal-warnings`.
- jj's own words that the UI shows verbatim stay out of the ARB and carry a trailing `// l10n-ignore: <reason>` marker: `JjIdentity.missingPhrase` (cli_util.rs), `ProjectSession.cloneDestinationNotEmpty` and the "Failed to create …" refusal (clone.rs), `root()`, `(no description set)`, the jj command lines. The product name "Zanshin" and pure punctuation/symbols (`·`, `@`, `+3`) stay literals too.
- Strings needed without a `BuildContext` (bootstrap splash status, native window titles) come from the platform-resolved `AppLocalizations` (`basicLocaleListResolution(PlatformDispatcher.instance.locales, AppLocalizations.supportedLocales)`), never a hard-coded `Locale('en')` in `lib/`.

**Never:**
- A second language, a language setting.
- Registering `AppLocalizations.localizationsDelegates` (it brings `package:flutter/material`'s `GlobalMaterialLocalizations`, the wrong type for `material_ui`'s `MaterialApp`); register only `AppLocalizations.delegate` and `ZsLocalizations.delegate`.
- Changing visible behaviour, layout or identifiers; touching `app/widgetbook/` or tests beyond the lookup of the moved strings.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Widget under the window root | `MaterialApp` with both delegates | strings resolve from the ARB | No error expected |
| Widget pumped without delegates (unit tests, catalogue) | no `AppLocalizations` in scope | `context.l10n` / `zsStrings(context)` fall back to the platform-resolved English instance | No error expected |
| Day label, other year | 2025-09-23 seen in 2026 | `Sep 23, 2025` (`DateFormat.yMMMd(localeName)`) | No error expected |
| Spoken relative date | 1 min / 3 min | `1 minute ago` / `3 minutes ago` (ICU plural) | No error expected |
| Guard, planted literal | a line `label: 'Planted'` in a scanned source | the scanner reports it with file:line | test fails |
| Guard, marked literal | `'root()', // l10n-ignore: jj's text` | not reported | No error expected |

</intent-contract>

## Code Map

- `app/pubspec.yaml`, `packages/zanshin_ui/pubspec.yaml` -- add `flutter_localizations: {sdk: flutter}` and `intl: any` (gen-l10n's generated code imports both; `any` takes flutter_localizations' pin).
- `app/l10n.yaml` (new) -- `arb-dir: lib/l10n`, `template-arb-file: app_en.arb`, `output-localization-file: app_localizations.dart`, `output-class: AppLocalizations`, `required-resource-attributes: true`, `format: true`. Same for `packages/zanshin_ui/l10n.yaml` with `zs_en.arb` → `zs_localizations.dart`, `ZsLocalizations`.
- `app/lib/l10n/` (new) -- `app_en.arb` + generated `app_localizations*.dart`; `app/lib/src/l10n/strings.dart` (new) -- `extension AppStrings on BuildContext { AppLocalizations get l10n }` with the fallback, and `AppLocalizations platformStrings()`.
- `packages/zanshin_ui/lib/l10n/` (new) -- `zs_en.arb` + generated; a package-internal `zsStrings(BuildContext)` with the same fallback; `zanshin_ui.dart` exports `ZsLocalizations`.
- `app/lib/src/features/window/zanshin_window_root.dart:101` -- `_WindowMaterialApp`: add `localizationsDelegates` + `supportedLocales`. `bootstrap/boot_failure.dart:24` -- its own `MaterialApp`, same.
- zanshin_ui strings: `controls/zs_text_field.dart:181-213,602,833` (Undo/Redo/Cut/Copy/Paste/Select all, `placeholder = 'Search'`, Clear), `zs_chip.dart:306` (`Remove $label`), `zs_confirm_dialog.dart:48` (`cancelLabel = 'Cancel'`), `zs_select.dart:66` (`Custom…`), `zs_spinner.dart:75` (value `busy`). Constructor defaults become nullable and resolve at build.
- App strings (grep `'[A-Za-z]` in UI positions): `projects/projects_window.dart` (titles, buttons, placeholders, confirm-dialog texts and `TextSpan`s 409-439, 598-614, 991-1023, nav rows, `settingsTooltip`, Identity, Dismiss, drop hint), `projects/projects_tree.dart` (statics 193-205, menu items 844-1192, More, Group name), `projects/project_capsule.dart` (Recent, All Projects…, Project Settings…, Settings…, Project), `projects/project_status_style.dart:24-31`, `projects/relative_time.dart:13-35`, `graph/graph_view.dart:175-185`, `graph/stale_notice.dart:23,93,103`, `graph/day_axis.dart:14-33`, `graph/graph_card.dart:202-324` (`graphRelativeDate`, `_spokenRelativeDate`, `graphCardLabel`), `graph/graph_card_render.dart:333-348,588,1082-1085`, `shell/top_bar.dart:71`, `shell/pinned_panel.dart:125,234`, `shell/rail.dart:41`, `bootstrap/zanshin_bootstrap.dart:207-220` (splash status), `bootstrap/splash_card_render.dart:107` (tagline), `bootstrap/boot_failure.dart:40`, `window/app_windows.dart:86` (`projectsWindowTitle`).
- Context-free sites get the strings injected: `GraphDayAxisPainter` (`graph_canvas.dart:147` passes `context.l10n`), `RenderGraphCard` gets a `strings` property like `icons` (`graph_card_render.dart:217-226`; setter `markNeedsLayout` + `markNeedsSemanticsUpdate`), `_GraphCardLeaf` passes it (`graph_card.dart:443-490`); `graphDayLabel`/`graphRelativeDate`/`graphCardLabel` take `AppLocalizations strings`.
- Tests that read the moved strings: `test/features/projects/projects_window_test.dart:323,1308-1405`, `test/features/graph/day_axis_test.dart`, `test/features/graph/graph_card_test.dart:230-396`, `window/app_windows_test.dart`, `app_window_coordinator_test.dart`, `boot_window_host_test.dart` -- switch to `AppLocalizationsEn()` lookups; expected text unchanged.
- `_bmad-output/project-context.md` (Framework-Specific / UI rules near line 595) and `_bmad-output/planning-artifacts/epics.md` Epic 10 house rules (line 8262) + Epic 11 house rules (line 12006) -- the house rule.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/{pubspec.yaml,l10n.yaml,lib/l10n/zs_en.arb}` -- set up gen-l10n, run `flutter gen-l10n` in the package, export `ZsLocalizations` and the internal `zsStrings`; move the control strings -- the package ships UI text.
- `app/{pubspec.yaml,l10n.yaml,lib/l10n/app_en.arb}`, `app/lib/src/l10n/strings.dart` -- set up gen-l10n and the access helpers; run `flutter gen-l10n` in `app/`.
- `app/lib/src/features/window/zanshin_window_root.dart`, `bootstrap/boot_failure.dart` -- register both delegates and `supportedLocales`.
- `app/lib/**` (files in the Code Map) -- replace every user-facing literal by its ARB lookup; mark jj's words and the product name `// l10n-ignore: <reason>`.
- `app/lib/src/features/graph/{day_axis,graph_card,graph_card_render,graph_canvas}.dart` -- dates through `intl` `DateFormat.MMMd`/`yMMMd` at `strings.localeName`; Today/Yesterday/now/Nm/… and the spoken plurals from the ARB; remove the `shortcut: hard-coded en-US` comment and `_months`.
- `app/test/**` -- adjust the lookups of moved strings and add `zanshin_window_root` coverage that the root registers both delegates.
- `app/test/l10n/hard_coded_strings_test.dart` (new) -- the guard: scans `app/lib/**/*.dart` (skipping `lib/l10n/` generated files, `*.g.dart`, `*.inject.dart`, `*.factory.dart`) for a string literal containing a letter in a UI position (`Text('`, `TextSpan(text: '`, `ZsMenuHeader('`, and named args `label|message|tooltip|placeholder|title|semanticLabel|hint|prompt|cancelLabel|confirmLabel: '`) not marked `// l10n-ignore`; plus a test that the scanner reports a planted literal and skips a marked one.
- `_bmad-output/project-context.md`, `_bmad-output/planning-artifacts/epics.md`, `_bmad-output/implementation-artifacts/epic-11-context.md` -- the house rule, with how to regenerate (`flutter gen-l10n` in `app/` or `packages/zanshin_ui/`) and the `// l10n-ignore` marker.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- close item I1 with a dated note pointing at this story.

**Acceptance Criteria:**
- Given the app and `zanshin_ui` sources, when `flutter test` runs in `app/` and `packages/zanshin_ui/`, then every existing test passes with unchanged expected text.
- Given `app/lib`, when the guard test runs, then it finds no unmarked hard-coded UI string; and given a planted `label: 'Planted'` line fed to its scanner, then it reports that line.
- Given the committed ARB files, when `flutter gen-l10n` runs in `app/` and in `packages/zanshin_ui/`, then `git status` shows no change.
- Given the window root, when a widget below it reads `AppLocalizations.of(context)` and `ZsLocalizations.of(context)`, then both are non-null.

## Spec Change Log

- 2026-10-31 (implementation): the "no `flutter: generate: true`" constraint cannot hold on Flutter 3.48 — `flutter gen-l10n` exits 1 without it (`gen_l10n.dart:37-45`), and with an `l10n.yaml` present the tool's build target runs the same generator (and would fail without the flag). Both pubspecs set `generate: true` with a `# WHY:`; the output is deterministic and committed, so a stale copy shows as a git diff. `intl` date data is loaded by `ensureDateFormatting()` (`app/lib/src/l10n/strings.dart`), since no window registers flutter's `GlobalMaterialLocalizations`, which would.

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 22 findings — high 0, medium 5, low 12, false 5, maybe-false 0 (the blind-hunter guard finding and edge findings 1 and 3 share one row: one root cause)
- findings:
  - `[medium]` `[patch]` (verification-gap) slotSpans dialog bodies: no test pins which path lands in which slot or the mono style — added full-body-text asserts for the Git-inside convert and enclosing sheets and a `ZsType.id` path-span assert for the Remove sheet in `projects_window_test.dart`.
  - `[medium]` `[patch]` (intent) the guard enforces fewer positions than the house rule — same root as the blind-hunter guard finding; fixed there.
  - `[false]` `[reject]` (intent) the planted-literal witness plants into the scanner, not into real code — the real-tree scan runs the same `uiLiteralLines` on every file, so a literal planted in `app/lib` is reported by the code the planted case proves.
  - `[low]` `[reject]` (intent) gen-l10n currency has no automated check — both pubspecs set `generate: true`, so every `flutter test`/`pub get` (the gate's flutter step included) regenerates `lib/l10n/` from the ARB; a stale committed copy turns into a git diff at the next gate. A separate checker would add machinery for a case the toolchain already surfaces.
  - `[false]` `[reject]` (intent) dates pinned to `en` instead of the system locale — Ralph's 2026-10-31 decision is English only with no language setting; item 3 says "driven by the app's locale", which is `en`; formatting goes through `intl` at `strings.localeName`, so a second ARB locale switches it.
  - `[false]` `[reject]` (intent) the jj-words exemption covers Dart copies of jj CLI messages — they are the CLI's text verbatim (cited clone.rs / cli_util.rs) shown to mirror the CLI; translating them would break CLI parity (Ralph 2026-10-23).
  - `[medium]` `[patch]` (blind) the guard misses `value:`, `dotLabel:`, `increasedValue:`, `decreasedValue:`, `semanticsLabel:` and same-line positional helper args; (edge) `_uiLiteral` positional gap; (edge) the shortcut comment understates the gap — one root: added the named args, a `value: 'busy'` scanner case, and a shortcut comment naming same-line positional helper literals.
  - `[low]` `[reject]` (blind) no guard over `packages/zanshin_ui/lib` — scope item 5 names `app/lib` only; the package's 16 strings are moved and its tests assert them.
  - `[low]` `[reject]` (blind) gen-l10n currency unproven — same as the intent row above.
  - `[low]` `[reject]` (blind) the fallback hides a missing delegate in production — both window roots and BootFailure are pinned by tests that the delegates resolve; an assert would break the catalogue and unit tests that rely on the fallback by design.
  - `[low]` `[patch]` (blind) BootFailure's delegate registration untested — added a test that `AppLocalizations.of` and `ZsLocalizations.of` resolve below `BootFailure`. The catalogue part is by design (fallback).
  - `[low]` `[reject]` (blind) `zsStrings` re-looks-up on every miss — the miss path runs only without a delegate (tests, catalogue) and no zanshin_ui code compares the instances by identity.
  - `[low]` `[patch]` (blind) `resizePoints` takes a pre-formatted number — now a `double` placeholder with `decimalPattern`, the value rounded to one decimal by the caller (`decimalPatternDigits` would print "300.0"); same English output up to 999 points, grouping ("1,200") above.
  - `[low]` `[reject]` (blind) `ensureDateFormatting()` loads every locale — `date_symbol_data_local` initialises synchronously and its data is linked by the import either way; limiting the call to one locale changes neither.
  - `[low]` `[reject]` (blind) `slotSpans` fails silently on a lost placeholder — only a future translation could drop a slot; asserts add branches for a case English cannot reach.
  - `[low]` `[patch]` (blind) planning artifacts: sprint-status still `backlog`, spec untracked — sprint-status set to `done` with a summary; the spec is committed with the story. The struck-through deferred-work sub-bullets are the original record, kept as written.
  - `[low]` `[reject]` (blind) nullable `placeholder`/`cancelLabel` defaults only witnessed through the fallback — the root test proves `ZsLocalizations` resolves under the delegate and the default is one `?? zsStrings(context).x` lookup; both paths return the same English instance.
  - `[low]` `[reject]` (edge) a `// l10n-ignore` inside a string literal exempts the line — needs a literal containing that marker on a UI line; not met in practice.
  - `[false]` `[reject]` (intent) "tests unchanged apart from the lookup" — the auditor confirms it holds; no defect.
  - `[false]` `[reject]` (intent) widgetbook exercises only the fallback — widgetbook is exempt (scope item 5) and the fallback is the designed path there.

### 2026-10-31 — Review pass (follow-up)
- verdicts: 22 findings — high 0, medium 1, low 17, false 3, maybe-false 1
- findings:
  - `[low]` `[reject]` (blind) VoiceOver sentences (`graphCardLabel`, bookmark/working-copy lists, project row value) are joined with `', '` in Dart — English only by Ralph's decision; reordering for a translation is that translation's work and needs new ARB keys, not a correction.
  - `[low]` `[reject]` (blind) abbreviated counts (`{n}m ago`, `{n}h`, `resizePoints`, `groupCount`'s project part) are plain `{n}`, and these placeholders lack `example` — the English abbreviations do not change with the number; a language that needs a plural adds it in its ARB. `example` is optional.
  - `[low]` `[patch]` (blind) the guard misses `TextSpan(style: …, text: '…')`, raw `r'…'` and `SelectableText('…')` — added `text` to the named args, `SelectableText` to the positional calls and an optional `r` prefix in `hard_coded_strings_test.dart`, with three scanner cases; the real-tree scan stays clean. Wrapped literals (`ZsType.caps('…')`) stay in the shortcut's "other helpers" gap.
  - `[low]` `[reject]` carried (blind) gen-l10n drift has no automated check / project-context's codegen rule — same as the logged "gen-l10n currency" rows; the "Build never auto-regenerates" section names only the FFI header and `bindings.dart`, so it does not contradict `generate: true`.
  - `[false]` `[reject]` (blind) `platformStrings()` resolution outside `Localizations` and `appVersion()` formatting the version line — no harm named: both paths resolve the same `[en]` strings, and the window title and splash run before any `Localizations` exists.
  - `[low]` `[reject]` (blind) deferred-work I1's sub-bullets read unresolved and the triage log calls them struck through — the entry's heading is struck and marked RESOLVED; the sub-bullets are the original record. The triage wording lives in this spec.
  - `[low]` `[patch]` (blind) epic-11-context.md lists 11.16 without "(done)" and still says it "can run now" — marked done and the dependency sentence updated.
  - `[maybe-false]` `[defer]` (blind) closed without the Marionette catalogue check — the suites pin the text; only a live catalogue pass settles whether the rendered UI matches. Deferred, medium (unverified), mirrored in deferred-work.md.
  - `[low]` `[defer]` (blind) native macOS strings (MainMenu.xib, no `CFBundleLocalizations`) outside the setup — predates the story, outside its `app/lib`/`zanshin_ui/lib` scope; deferred to 11.13, mirrored in deferred-work.md.
  - `[low]` `[reject]` (blind) the previous triage header's counts do not match its rows — the fix edits this spec's record only.
  - `[false]` `[reject]` (edge) a non-finite `ZsResizeEdge` value makes `(v * 10).round()` throw — the only caller (`pinned_panel.dart:123-124`) passes finite `panelWMin`/`panelMax`, and the value is clamped between them.
  - `[low]` `[patch]` (edge) guard misses `TextSpan(style:, text:)`, raw strings, `SelectableText` — same root as the blind guard row; fixed there.
  - `[low]` `[reject]` (edge) `slotSpans` would replace a U+E000+ character in a placeholder value — the values are paths, versions and names; a private-use character in them is not met in practice and a guard adds a branch.
  - `[low]` `[reject]` (edge) both pubspecs set `generate: true` against the intent — the deviation is forced by Flutter 3.48 and recorded in the Spec Change Log; the fix would edit this spec.
  - `[low]` `[reject]` (edge) 312.04 points now reads "312 points" instead of "312.0 points" — only within 0.05 of a whole number; the rounding to one decimal was the previous pass's patch and the new form is what VoiceOver users hear for whole widths anyway.
  - `[medium]` `[patch]` (verification-gap) the plain convert and init sheet bodies, now built by `slotSpans`, are never asserted — added full-body `findRichText` asserts ("~/legacy stays a Git repository; …", "~/plain becomes a jj repository, …") in `projects_window_test.dart`.
  - `[low]` `[reject]` (intent) the resize edge's VoiceOver value groups above 999 ("1,200 points") — VoiceOver speaks "1,200" and "1200" alike; recorded residual risk of the previous pass.
  - `[low]` `[patch]` (intent) the guard is a line-based heuristic, not complete — same root as the blind guard row; three more positions covered, the remaining gap stays named in the shortcut comment.
  - `[low]` `[reject]` (intent) codegen D1 vs D2 — same as the edge `generate: true` row.
  - `[false]` `[reject]` (intent) tests go beyond lookup swaps — the intent's own matrix and ACs require the delegate, fallback and guard witnesses; no defect.
  - `[low]` `[reject]` (intent) no test of a non-`en` platform locale list — with `supportedLocales: [en]`, `basicLocaleListResolution` returns `en` for any list; a test would pin Flutter's behaviour.
  - `[low]` `[reject]` carried (intent) no guard over `packages/zanshin_ui/lib` — same as the logged row: the intent names `app/lib`.

## Design Notes

The fallback in `context.l10n` keeps widget tests and the catalogue (which pump without the delegates) working with no change; in the app the root always registers the delegates, which a root test pins. Guard regex is line-based: a literal passed positionally on its own line (e.g. a confirm-dialog title argument) is not caught — `shortcut: line-based scan, upgrade to an analyzer-based check if literals slip through`.

## Verification

**Commands:**
- `flutter gen-l10n` (in `app/` and `packages/zanshin_ui/`) then `git status --short` -- expected: no diff after commit
- `flutter test` in `app/` and `packages/zanshin_ui/` -- expected: all pass
- `dart analyze --fatal-infos --fatal-warnings` in `app/` and `packages/zanshin_ui/` -- expected: clean
- `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_ui/` -- expected: exit 0

**Manual checks (if no CLI):**
- Open the catalogue's Projects window and graph use cases via Marionette: text identical to before.

## Auto Run Result

Status: done (commit `ad7abf6d1f3af0da8b3d1d40af946e2c940d461a`).

**Summary.** gen-l10n set up in `app/` (`AppLocalizations`, `lib/l10n/app_en.arb`, ~140 keys) and `packages/zanshin_ui` (`ZsLocalizations`, `lib/l10n/zs_en.arb`, 16 keys), generated code committed; every user-facing string of both `lib/` trees moved into the ARBs with descriptions, ICU plurals (spoken dates, group count) and placeholders; jj's own words (commands, `root()`, `(no description set)`, the CLI's clone/identity messages) and "Zanshin" stay literals marked `// l10n-ignore`. Dates go through `intl` (`DateFormat.MMMd`/`yMMMd` at `strings.localeName`). `context.l10n` / `zsStrings(context)` fall back to the platform-resolved strings without a delegate (tests, catalogue); `platformStrings()` serves the splash status and native window titles. Window roots and `BootFailure` register only `AppLocalizations.delegate` + `ZsLocalizations.delegate`. Guard test `app/test/l10n/hard_coded_strings_test.dart`. House rule in project-context.md, epics.md (Epic 10 "Strings", Epic 11) and epic-11-context.md.

**Files.** `app/{pubspec.yaml,l10n.yaml}`, `app/lib/l10n/*` (ARB + generated), `app/lib/src/l10n/strings.dart` (access helpers, delegates list, `slotSpans`, `ensureDateFormatting`), the projects/graph/shell/bootstrap/window feature files (lookups), `packages/zanshin_ui/{pubspec.yaml,l10n.yaml}`, `packages/zanshin_ui/lib/l10n/*`, `lib/src/zs_strings.dart`, the Zs controls with strings; tests: lookups switched to `AppLocalizationsEn()`, new `test/l10n/{hard_coded_strings,strings}_test.dart`, delegate tests for the window roots and `BootFailure`, slot-order/mono-path tests for the Projects sheets; docs: project-context.md, epics.md, epic-11-context.md, deferred-work.md (I1 resolved), sprint-status.yaml (done).

**Deviations (Spec Change Log).** `flutter: generate: true` is set in both pubspecs: Flutter 3.48's `gen-l10n` refuses to run without it; output stays deterministic and committed. `intl` date data is loaded by `ensureDateFormatting()`.

**Review.** 22 findings: 5 patched (guard positions + comment, slot-order/mono tests, BootFailure delegate test, `resizePoints` as a number placeholder, sprint-status/spec bookkeeping), 0 deferred, 17 rejected with reasons in the triage log. Patched counts: medium 2 entries (guard, slot tests), low 3. Follow-up review recommended: true — two medium entries were patched; the named unverified risk is the line-based guard (positional helper literals are still not caught).

**Verification** (targeted, gate rule of this run — no `cargo make test`):
- `cargo make --allow-private test-flutter` (app suite in the gate's env): 1096 passed, before and after the review patches.
- `flutter test` in `packages/zanshin_ui`: 425 passed.
- `dart analyze --fatal-infos --fatal-warnings` in `app/` and `packages/zanshin_ui/`: no issues.
- `dart format --output=none --set-exit-if-changed .` in both: 0 changed.
- `flutter gen-l10n` in both after staging: no diff (generated output current).
- Not done: the Marionette visual check in the catalogue (needs a running catalogue; text is asserted unchanged by the suites).

**Residual risks.** The guard is line-based (positional helper literals slip through). `initializeDateFormatting()` loads all locales' date data. Numbers ≥ 1000 in the resize-edge VoiceOver value now group ("1,200 points").

**Items.**
- I1 (English-only app, or translated?): fixed (`ad7abf6d1f3af0da8b3d1d40af946e2c940d461a`) — Ralph's decision "English only, l10n-ready" is implemented: the setup and the move are done, deferred-work.md marks the item resolved, and later UI stories keep to the recorded house rule.

### Follow-up review pass (2026-10-31)

Status: done.

**Changes.**
- `app/test/features/projects/projects_window_test.dart` — full-body asserts for the plain convert and init sheets (the two `slotSpans` bodies no test read).
- `app/test/l10n/hard_coded_strings_test.dart` — the guard also catches `text:` anywhere in a call, `SelectableText('…')` and raw `r'…'` literals; three scanner cases.
- `_bmad-output/implementation-artifacts/epic-11-context.md` — 11.16 marked done.
- `_bmad-output/implementation-artifacts/deferred-work.md` — new section "Surfaced in the follow-up review of Story 11.16" with the two deferrals.

**Review.** 22 findings: 3 entries patched (medium 1: sheet-body asserts; low 2: guard positions, epic context), 2 deferred (Marionette catalogue check, medium unverified; native macOS strings, low), 17 rejected with reasons in the triage log. Follow-up review recommended: false — no `high` was patched on this follow-up pass.

**Verification** (targeted, gate rule of this run — no `cargo make test`):
- `flutter test test/l10n/hard_coded_strings_test.dart test/features/projects/projects_window_test.dart` in `app/`: 76 passed.
- `dart analyze --fatal-infos --fatal-warnings` in `app/`: no issues.
- `dart format --output=none --set-exit-if-changed` on both edited test files: 0 changed.
- No `lib/` code changed, so `packages/zanshin_ui` and the rest of the app suite were not rerun.

**Residual risks.** Unchanged from the first pass: the guard stays line-based (positional helper literals and wrapped literals such as `ZsType.caps('…')` slip through); the live catalogue check is still open (deferred).

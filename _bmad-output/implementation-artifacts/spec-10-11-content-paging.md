---
title: 'Story 10.11 — Content paging: skeleton cards and visible-range content loads'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: '2e610927f8be49b146b8506a190afacdeb89ecb6'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A commit id the source leaves out of its page stays uncached, so its card shows the skeleton until it arrives and every later settle asks for it again.
    evidence: |-
      GraphSource.content documents "an id the source cannot read is left out"; GraphContent only caches returned entries and the card waits while the entry is null. What jj reports for an unreadable id (4.10's error contract) is only known once 10.12 wires commitContents.
    location: >-
      app/lib/src/features/graph/graph_content.dart (load / _drain)
    severity: medium
    resolved: >-
      2026-11-01 — rejected (spec-10-12-adopt-backend-layout): the real commitContents returns every requested id or throws, so no id is left out; a throw takes the failed-page path.
  - summary: >-
      A failed page is retried only by the next settle (scroll, layout, card size, resize); at rest the visible cards keep their skeleton.
    evidence: |-
      GraphContent logs a ZanshinFfiException and caches nothing; no timer retries. Matches the spec ("the next settle asks again"), but at rest no further settle follows. The retry/error look belongs with 10.12's real failure modes.
    location: >-
      app/lib/src/features/graph/graph_content.dart (_drain catch)
    severity: medium
    resolved: >-
      2026-11-01 — fixed (spec-10-12-adopt-backend-layout, commit 6b9feacb): a failed page is asked again on the next settle or the next landed layout (Reload, Cmd-R, window focus); no timer, per Ralph's refresh rule; tested.
  - summary: >-
      The peek (10.6's callout) shows an empty subject and author while its content loads, with no loading state, and still lacks the full description and commit id.
    evidence: |-
      graph_canvas.dart _peekLayer builds GraphPeek from GraphCardData.of(..., content:); GraphCommitContent has no description field. 10.6 handed "peek description / commit id / loading" to 10.11/10.12; the description and commit id come with 4.10's object half in 10.12.
    location: >-
      app/lib/src/features/graph/graph_canvas.dart (_peekLayer), graph_peek.dart
    severity: low
    resolved: >-
      2026-11-01 — fixed (spec-10-12-adopt-backend-layout, commit 6b9feacb): the peek shows the description and commit id from 4.10's object half and a loading look.
---

<intent-contract>

## Intent

**Problem:** Card content (subject, author, empty, conflict) only exists when a layout carries it inline; 4.10 splits the backend into an index-only topology and op-pinned content by commit id, so the view must page content for what is on screen, show a skeleton until it arrives, and never move a card when it does (epics.md Story 10.11 + its 2026-09-28 / 2026-10-14 / 2026-10-16 notes).

**Approach:** Add a `content(operationId, commitIds)` port to `GraphSource`, a commit-id-keyed `GraphContent` cache/loader owned by `GraphViewModel` (one page in flight, a page superseded by a newer load is dropped), a settle detector in `GraphCanvas` that loads the visible nodes plus a buffer, and a DS skeleton painted in a card's subject slot after `--delay-skeleton`. Build against fake ports with latency; 10.12 plugs in 4.10's real call.

## Boundaries & Constraints

**Always:**
- Content is cached by **commit id** (`GraphLayout.commitIdOf`, new accessor) across reloads; view facts keep coming with the geometry. `GraphCardData.of` takes the cache entry, else the layout's own `contentOf` (recordings/fixtures still carry inline content).
- A load fires only once the viewport has settled: no scroll offset change for `graphContentSettle` (100 ms), no canvas pan held, no ballistic/drag scroll on either axis. It also fires after a new layout or metrics change, once settled. Request = the nodes whose card lies in the plane window `(scroll − insets.topLeft) & viewport size` inflated by **one viewport height in y and 250 px (the cache extent) in x** (decided buffer), minus cached ids and nodes with inline content; nothing missing → no call.
- The request carries the layout's `operationId` (pinning). At most one page in flight; loads arriving meanwhile replace one queued load; when the in-flight page returns while a load is queued it is **dropped** (10.5's coalescing rule) and the queued load is computed when it starts.
- A failed page (`ZanshinFfiException`) is logged at warning and caches nothing; the next settle asks again.
- Card date: the geometry timestamp when present, else `GraphCommitContent.timestampMs` (new optional field). The view never lays out from content; geometry never depends on it.
- Skeleton (DS Skeleton, decision 16.4): a non-root card without content paints a `--skeleton` bar (9 px, `--radius-xs`) in its subject slot — detailed: the subject line, 58 % of the padded width; compact: the space after the meta items, up to 58 % — with the `--skeleton-hi` sweep every `--dur-shimmer`, shown only after `--delay-skeleton` (150 ms); content arriving sooner shows none. Under reduce motion the bar pulses with no highlight. The bar adds no semantics node. One painting routine is shared with `ZsSkeleton` (no copy of its math).
- The peek (10.6's callout) reads the same cache.

**Never:** Rust changes; exporting 4.10's types or calling `RepoHandle.commitContents` (10.12); a growing-extent stream; stack/popover content (10.17), bookmark-panel subjects (10.14), menu header/drag ghost/inspector id-only readers (10.15/10.10/10.8 — they do not exist yet); a cache size bound (100k small entries is fine for one session — mark it with a `shortcut:` comment); requests during a pan or fling.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Settle after jump | 200-node layout, viewport jumped to the middle | one `content(op, ids)` with exactly the window+buffer nodes' commit ids | — |
| Reload, same commits | new layout object, same commit ids, all cached | no `content` call | — |
| Superseded page | page A in flight, a second load queued, A completes | A's entries not cached; queued load issues its own request | — |
| Pan / fling | canvas pan held or ballistic scroll running | no `content` call until settled | — |
| Fast content | page answers within 150 ms | no skeleton ever painted | — |
| Failure | `content` throws `ZanshinFfiException` | warning logged, nothing cached, next settle retries | no rethrow |
| Inline content | layout `contentOf(n) != null` | node never requested | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_layout.dart` -- `GraphLayout` accessor contract (:174-307; add `commitIdOf`), `GraphCommitContent` (:141-166; add `timestampMs`).
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- add optional `commitIds` list; `commitIdOf` falls back to the key (recordings have no commit ids — `shortcut:` comment; real ids come with 10.12).
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphSource` (:114-127) gains `content`; `RepoGraphSource` (:616-634) takes a required `content:` function like its `layout:` until 10.12.
- `app/lib/src/features/graph/graph_view_model.dart` -- owns the new `GraphContent` (created in `init`, disposed in `dispose`), exposes `content`.
- `app/lib/src/features/graph/graph_content.dart` (new) -- `GraphContent extends ChangeNotifier`: `operator [](commitId)`, `of(layout, node)`, `load(layout, nodes)`, coalescing + drop rule.
- `app/lib/src/features/graph/graph_canvas.dart` -- new optional `content` param; settle detector on `_vertical`/`_horizontal` listeners (already wired at :144-145), `_viewport.isPanning`, `position.isScrollingNotifier`; passes `content` to `GraphCard` (`_card` :424) and the peek (`_peekLayer` :586).
- `app/lib/src/features/graph/graph_viewport_render.dart` -- `GraphViewportController` (:67-115) gains `nodesNear(double dx, double dy)` using `vertical.visibleNodes` on the plane window (cf. `layoutChildSequence` :425-434, `_unobscured` :508).
- `app/lib/src/features/graph/graph_card.dart` -- `GraphCardData.of` (:216) gets the content arg + timestamp fallback; `GraphCard` (:466) takes `content`, listens and rebuilds when its entry changes, runs the skeleton delay timer + sweep controller (ZsMotion `delaySkeleton`, `durShimmer`), passes the sweep to the leaf.
- `app/lib/src/features/graph/graph_card_render.dart` -- `_layoutLines` (:509-683) records the skeleton bar rect when content is null and not root; `paint` (:768) paints it inside the padding clip; new `skeleton` Animation property wired like `reveal` (:261-273, attach/detach :398-424); skeleton colours passed in.
- `app/lib/src/features/graph/graph_view.dart` -- pass `model.content` to `GraphCanvas` (:254).
- `packages/zanshin_ui/lib/src/controls/zs_skeleton.dart` -- extract `_SkeletonPainter.paint` body (:203-221) into public `paintZsSkeletonBar(...)`; export it from `zanshin_ui.dart`.
- `app/test/helpers/scripted_graph_source.dart` -- add `content` responder, `contentRequests`, hold support.
- `app/widgetbook/graph/fake_graph_source.dart` + `app/widgetbook/folders/graph.dart` -- the View-model demo pages content with fake latency (e.g. 400 ms) from `fakeContent` and lays out recordings without inline content.
- `app/test/features/graph/graph_ports_test.dart` -- `RepoGraphSource(...)` call sites (:68, :92, :117, :135, :170) need `content:`.
- `app/test/features/graph/graph_view_model_test.dart:976` -- `_FailingDefaults` implements `GraphSource`: add `content`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_skeleton.dart` + `zanshin_ui.dart` export -- extract `paintZsSkeletonBar(Canvas, Rect, {t, base, high, radius, motion})`; `ZsSkeleton` uses it -- one skeleton look.
- `graph_layout.dart`, `recorded_graph_layout.dart` -- `commitIdOf`, `timestampMs` -- cache key and date fallback.
- `graph_ports.dart` -- port + `RepoGraphSource(content:)` -- 10.12 swaps in the real call.
- `graph_content.dart` (new), `graph_view_model.dart` -- cache/loader owned by the model -- items 2–4.
- `graph_viewport_render.dart`, `graph_canvas.dart`, `graph_view.dart` -- settle detection, window+buffer query, wiring -- items 1–2.
- `graph_card.dart`, `graph_card_render.dart` -- cache read, date fallback, delayed skeleton bar -- items 5–6.
- test helper + widgetbook fake + existing `GraphSource` implementers -- compile and demo.
- `app/test/features/graph/graph_content_test.dart` (new) -- the I/O matrix and the witnesses below; `packages/zanshin_ui/test` -- `paintZsSkeletonBar` with motion 0 paints no gradient.

**Acceptance Criteria:**
- Given a GraphView on a 200-node layout without inline content, when the view jumps to a node and settles, then exactly one content request carries the window+buffer nodes' commit ids and the layout's operation id.
- Given a canvas pan held (or a fling running), when frames pump past `graphContentSettle`, then no content request is made; after release and settle, one is.
- Given a reload whose layout has the same commit ids, when it lands and settles, then no content request is made.
- Given content that arrives after 150 ms, when it lands, then every mounted card's rect (`GraphViewportController.cardRectOf`) is unchanged and the card's semantics label gains the subject; before it landed the card painted the skeleton bar.
- Given content within 150 ms, then the card never painted the skeleton.
- Given a mode switch to Free while a content page is held, then the new layout lands and its cards build without waiting for content.
- Given a layout timestamp is null and the content carries `timestampMs`, then the card shows that date.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 34 findings — high 0, medium 11, low 14, false 9, maybe-false 0 (verification-gap 3, blind 14, edge-case 12, intent-alignment 5)
- findings:
  - `[medium]` `[patch]` verification-gap: the peek reading the cache (and updating when a page lands) is untested — added a GraphView test: peek on a paged card shows the cached subject, and updates when a held page lands.
  - `[medium]` `[patch]` verification-gap: rescheduling a page after a new layout / card size / insets is untested — added a reload test whose layout brings new commit ids on screen and asserts a second request with exactly those ids.
  - `[medium]` `[patch]` verification-gap: the compact-card skeleton is untested — added a `detailedCards: false` variant asserting a non-null `debugSkeletonBar`.
  - `[medium]` `[patch]` blind: `_drain` catches only `ZanshinFfiException`; other throws escape the unawaited future and strand a queued load — added a severe-logged catch-all, plus a test.
  - `[low]` `[reject]` blind: a superseded page is dropped although content is commit-intrinsic — the drop is the story's own rule (epics.md 10.11 item 4, "stale pages are dropped under 10.5's coalescing rule"); a wasted read at worst.
  - `[medium]` `[defer]` blind: a failed page leaves its cards shimmering at rest — the spec's "next settle asks again" holds; the retry/error look follows 10.12's real failure modes. Deferred (mirrored in deferred-work.md).
  - `[medium]` `[patch]` blind: a viewport resize schedules no page — the canvas now reschedules on `ScrollMetricsNotification`; resize test added.
  - `[low]` `[reject]` blind: compact cards' inline items shift when the bar appears and when text lands — the card rect never moves (the witness); text arriving reflows the slot by nature; no user-visible jump beyond that.
  - `[false]` `[reject]` blind: the content timestamp reaches the card but not the day axis — by design: item 6, timestamps are layout input and the view never lays out from paged content.
  - `[low]` `[reject]` blind: `RecordedGraphLayout.commitIdOf` falls back to the key (stale after a describe) — recordings are immutable fixtures with no describe; the `shortcut:` comment names it and 10.12 supplies real commit ids.
  - `[low]` `[patch]` blind: the root's commit id is requested although the root never waits — `load` now skips `rootIndex`; test added.
  - `[false]` `[reject]` blind: `GraphViewModel.init` twice leaks a GraphContent — `init` is documented one-shot (`ViewModelBuilder`'s init), like the `late _source`.
  - `[low]` `[reject]` blind: `_windowIds` in the test mirrors the production window — `visibleNodes` is pinned by its own tests; the widget test pins the wiring (buffer, insets, op id).
  - `[low]` `[patch]` blind: `paintZsSkeletonBar`'s offset shift is untested — added a non-origin case to zs_skeleton_test.dart.
  - `[low]` `[defer]` blind: the peek has no loading state — deferred with the description/commit-id handoff to 10.12 (mirrored).
  - `[false]` `[reject]` blind: the spec is not in the diff — intentional: the spec is the edge-case layer's claims file.
  - `[low]` `[patch]` blind: `nodesNear` doc comment breaks mid-sentence — rejoined.
  - `[medium]` `[patch]` edge-case: non-FFI throw in `_drain` — same fix as the blind finding above.
  - `[medium]` `[defer]` edge-case: ids the source leaves out stay uncached and shimmer forever — what an unreadable id shows depends on 4.10's error contract, wired in 10.12. Deferred (mirrored).
  - `[low]` `[reject]` edge-case: any queued load (even all-cached) drops the in-flight page — the story's coalescing rule; the queued load re-asks the missing ids.
  - `[medium]` `[patch]` edge-case: an empty `nodesNear` result queues an empty load and drops the in-flight page — `_loadContent` now returns on an empty list.
  - `[medium]` `[patch]` edge-case: a viewport resize schedules no page — same fix as above.
  - `[medium]` `[defer]` edge-case: a failure at rest is never retried — same deferral as above.
  - `[low]` `[reject]` edge-case: cache keyed by change id for layouts without commit ids — same as the blind `commitIdOf` finding.
  - `[false]` `[reject]` edge-case: `init` twice leaks — `init` is one-shot.
  - `[false]` `[reject]` edge-case: `content` read before `init` throws — every caller inits first (`ViewModelBuilder`), the same contract as the `late _source`.
  - `[low]` `[reject]` edge-case: a ZsMotion change while the sweep repeats keeps the old period — motion tokens do not change at runtime except the reduce-motion factor, which the painter reads per frame.
  - `[low]` `[patch]` edge-case: the mode-switch witness switches to Compact, not Free — the test now starts in Compact and switches to Free while a page is held.
  - `[false]` `[reject]` edge-case: a reader expects an automatic retry — the spec states the next settle retries; covered by the deferral above.
  - `[false]` `[reject]` intent: R2 readers (stack members, popover rows, bookmark-panel subjects, menu header, drag ghost, inspector) are absent — their widgets do not exist yet; each owning story (10.17, 10.14, 10.15, 10.10, 10.8) reads the shared cache when it builds them.
  - `[low]` `[reject]` intent: one bar in the subject slot instead of every text slot — a marked Claude proposal (Design Notes): id/date come from the geometry, an author bar would collide with the date.
  - `[false]` `[reject]` intent: reduce motion should "pulse once and end" — DS Skeleton.prompt.md: "pulses instead of sweeping", and the 2026-10-16 note: "the sweep becomes one pulse"; each cycle is a pulse without a highlight, as `ZsSkeleton` does.
  - `[low]` `[reject]` intent: the region is not marked busy — Flutter's semantics has no aria-busy property; the bar adds no node and the label omits the subject until it lands.
  - `[false]` `[reject]` intent: the port is not wired to production — by the story: "10.12 plugs in 4.10's real call".

## Design Notes

Skeleton placement is a Claude proposal (DS Skeleton only specifies "text slots"): only the subject slot gets a bar — the id, date, @ badge and bookmark control come from the geometry and paint normally; an author bar would collide with the date and adds little. Settle delay 100 ms + DS 150 ms skeleton delay means a fast backend shows no skeleton at all.

Loader core (shape, not code to copy):
```dart
void load(GraphLayout layout, Iterable<int> nodes) {
  _queued = (layout: layout, nodes: nodes.toList());
  if (!_running) unawaited(_drain());
}
// _drain: while _queued != null → take it, compute missing ids, fetch; on return drop the page if _queued != null.
```

## Verification

**Commands:**
- `flutter test` in `/Users/ralph.bergmann/development/projects/privat/Zanshin/app` (graph tests: `test/features/graph`) -- expected: all pass
- `flutter test` in `packages/zanshin_ui` -- expected: all pass
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .` in `app` and `packages/zanshin_ui` -- expected: clean
- `cargo make --allow-private test-flutter` if real-worker app tests (graph_ports_test) need running -- expected: pass

**Manual checks:**
- Widgetbook Graph › View model: cards show skeletons ~150 ms after a jump, then text; nothing moves.

**Verification notes (2026-10-31, gate rule: targeted checks only):**
- `flutter test test/features/graph` (app) — 373 passed (incl. graph_ports_test, which ran outside cargo make).
- `flutter test test/widgetbook test/l10n` (app) — 325 passed (catalogue smoke test, hard-coded strings).
- `dart analyze --fatal-infos` (app, packages/zanshin_ui) — no issues.
- `dart format --set-exit-if-changed .` (app, packages/zanshin_ui) — 0 changed.
- `flutter test` (packages/zanshin_ui) — 428 passed.
- No Rust, FFI or schema change: no cargo, codegen or parity checks apply. The full gate is the story loop's.
- Not done: the Widgetbook/Marionette visual check (needs a long-running `flutter run`; left for the loop's end or Ralph).

## Auto Run Result

Status: done

**Summary.** The view side of 4.10's topology/content split: `GraphSource.content(operationId, commitIds)`; a commit-id-keyed `GraphContent` cache/loader owned by `GraphViewModel` (one page in flight, a page superseded by a queued load is dropped, failures logged); `GraphCanvas` loads the visible nodes plus a buffer (± one viewport height, ± 250 px) once the viewport settles (100 ms rest, no pan, no drag/fling; also after a new layout, reveal, card size, insets or viewport resize); cards and the peek read the cache; a DS skeleton bar paints in the subject slot after `--delay-skeleton`, sharing `paintZsSkeletonBar` with `ZsSkeleton`; the card date falls back to the content's timestamp.

**Files.**
- `packages/zanshin_ui/lib/src/controls/zs_skeleton.dart`, `zanshin_ui.dart` — public `paintZsSkeletonBar`, used by `ZsSkeleton`.
- `app/lib/src/features/graph/graph_layout.dart` — `GraphLayout.commitIdOf`, `GraphCommitContent.timestampMs`.
- `app/lib/src/features/graph/recorded_graph_layout.dart` — optional `commitIds` (key fallback, `shortcut:`).
- `app/lib/src/features/graph/graph_ports.dart` — the content port; `RepoGraphSource(content:)`.
- `app/lib/src/features/graph/graph_content.dart` (new) — cache and page loader.
- `app/lib/src/features/graph/graph_view_model.dart` — owns `content`.
- `app/lib/src/features/graph/graph_viewport_render.dart` — `GraphViewportController.nodesNear`.
- `app/lib/src/features/graph/graph_canvas.dart` — settle detection, loads, cache to cards and peek.
- `app/lib/src/features/graph/graph_card.dart`, `graph_card_render.dart` — cache read, date fallback, delayed skeleton bar.
- `app/lib/src/features/graph/graph_view.dart` — wires `model.content`.
- Tests: `app/test/features/graph/graph_content_test.dart` (new), helper/harness/fake updates, `packages/zanshin_ui/test/controls/zs_skeleton_test.dart`; catalogue: `FakeGraphSource.content` (400 ms latency), View-model demo without inline content.

**Review.** 34 findings (high 0, medium 11, low 14, false 9). Patched: 7 medium + 4 low entries (non-FFI catch-all, root skipped, resize reschedule, empty-window guard, doc comment, peek/reload/compact/Free/resize/offset witnesses). Deferred (mirrored in deferred-work.md): ids left out of a page shimmer (medium), no retry at rest after a failure (medium), peek loading look + description/commit id (low). Rejected with reasons in the triage log (drop rule is the story's, compact reflow, recordings' key fallback, mirrored test window, motion-token change, one-bar proposal, no aria-busy in Flutter, and 9 false).

**Follow-up review:** recommended `false` — no high patched; the medium patches are each pinned by a new witness. Patched counts: high 0, medium 7, low 4.

**Residual risks.** The port is not wired to production yet (10.12); recordings key the cache by change id; the Widgetbook visual check was not run.

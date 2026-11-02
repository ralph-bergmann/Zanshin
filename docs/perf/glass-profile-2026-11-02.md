# The cost of glass — profile-mode measurement, 2026-11-02

Recorded, not gated (epics.md Story 11.2 design status (a); deferred-work.md, "The cost of glass …").

## Setup

- Machine: Apple M4 Pro; the window opened on a 60 Hz external display (displays: 60, 120 (built-in ProMotion), 60 Hz).
  ~606 frames in 10 s = 60 Hz, so the 120 Hz case was not exercised.
- Flutter profile build, Impeller (Metal), window 1440 × 900, night theme.
- Scene: `FloatingShell` over `GraphView` on a synthetic 10k compact layout (`syntheticLayout(10000)`, the catalogue's
  fakes, no repo). Glass open: PLACE (project capsule), VIEW (graph controls), ACTION (reload + New change), the rail
  (two items), the inspector (a selected change). **The minimap (10.16) does not exist yet: five glass surfaces,
  not six.** The inspector shows a change without files (the fake details answer no diff).
- Scroll: programmatic, linear, 20 000 px down in 5 s, back in 5 s. Calm scrolling reacts only to pointer scrolling,
  so the islands never step aside — the glass's worst case.
- Glass off: macOS Reduce transparency through `ZsAppearanceOverride(reduceTransparency: true)` — the token-level
  solid fallback (solid fills, no `BackdropFilter`); same islands, same content.
- Harness: `app/integration_test/glass_profile.dart` (run line in its doc comment); it prints one `GLASS_PROFILE`
  JSON line and exits.

## Results (ms per frame; share of frames over 16.7 ms / 8.3 ms)

| run       | frames | build avg | p90  | p99  | max  | raster avg | p90  | p99  | max  | raster >16.7 | raster >8.3 |
|-----------|-------:|----------:|-----:|-----:|-----:|-----------:|-----:|-----:|-----:|-------------:|------------:|
| glass #1  | 602    | 0.97      | 1.88 | 2.52 | 3.42 | 5.84       | 6.26 | 6.58 | 85.6 | 0.33 %       | 0.50 %      |
| glass #2  | 606    | 1.03      | 1.97 | 2.50 | 3.67 | 5.75       | 6.25 | 6.58 | 18.1 | 0.17 %       | 0.17 %      |
| solid #1  | 606    | 1.46      | 2.32 | 2.82 | 3.84 | 2.47       | 2.95 | 3.49 | 16.8 | 0.17 %       | 0.17 %      |
| solid #2  | 606    | 1.49      | 2.31 | 2.88 | 4.29 | 2.49       | 2.93 | 3.40 | 16.2 | 0 %          | 0.17 %      |

Build never crossed 8.3 ms in any run. The over-budget raster frames are one to three per run (the 85.6 ms is a
single frame in the first run, the first after a cold build — a warm-up outlier).

## Reading

- Glass costs **~3.3 ms raster per frame** (5.8 vs 2.5 avg, p99 6.6 vs 3.4), on the raster thread only; build is
  unaffected (slightly lower with glass — noise or the solid fills' extra paint; not investigated).
- At 60 Hz the frame budget holds with ~10 ms to spare. At 120 Hz (8.3 ms) the glass p99 of 6.6 ms still fits, with
  ~1.7 ms headroom — not measured on the ProMotion display; move the window there to check.
- Variance between the two runs of a variant is under 0.1 ms on avg and p99.

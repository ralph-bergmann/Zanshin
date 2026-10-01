# Spec notes from the Dart implementation (the spec: `docs/graph-layout.md`)

## Ambiguities found (dart)

None of these changes any output on the current inputs: the Dart outputs `cmp` equal to the Rust
ones on all 48 input × mode × order files, and the 4 greedy design files match the design.

1. **`free`: does a root's own `ts_ms` count towards tmin?** §4.2 free.1 says "the least non-null
   ts", then "t(i) = tmin if `is_root`". Dart takes the literal reading: every non-null ts counts,
   a root's included. It only matters when a root carries a timestamp. The dumper writes `null`
   for the root, so no current input is affected. (Unit test: "free: tmin is the least non-null
   ts, including a root's".)
2. **Absent key vs. `null`.** §2 lists `ts_ms` ("`null` for the root") and `idx` ("`missing`
   carries `idx: null`") as fields that hold `null`, but does not say whether an absent key means
   `null`. Dart reads this literally: the key must be present, and an absent key exits with
   code 2. Rust's serde `Option<i64>` treats an absent key as `null`. Only exit codes on
   non-conforming input differ; conforming input is unaffected. Suggest adding to §2: "every
   field in the table is required, except `id`". `id` is neither required nor type-checked by
   either implementation.
3. **`utc_offset_min` range.** V4 only bounds it to ±2^53, but `off = utc_offset_min·60000`
   (§4.2 time.1) overflows int64 above about 1.5·10^11 minutes. Dart wraps silently (two's
   complement). Rust release builds wrap as well, unless overflow checks are on. Suggest a V5
   such as |utc_offset_min| ≤ 1440. There are no other intermediate overflows: in L2,
   (x − 2^k)·256 stays below 2^47, and the digest terms stay below 2^41.
4. **§6 leaves two CLI cases open.** Dart exits with code 2 for both:
   - a failure to write the output file;
   - `layout` given `--runs` / `--warmup`.

## Resolved in the stage-3 diff (2026-09-26)

All four items are now settled in docs/graph-layout.md, marked *Clarified during diff*. Items 1, 2 and 4
confirm the readings above. For item 2, Rust was changed to match Dart. Item 3 was adopted as
V4: |utc_offset_min| ≤ 1440.

The probes also found one place where Dart accepted input that Rust rejected: a leading UTF-8
byte-order mark, which the fused decoder skipped. SPEC §2 now rejects it. The fix is in
`lib/src/input.dart`. Regression tests in `test/layout_test.dart` cover the BOM, the offset
bound, `-0` read as 0, and an absent `idx`.

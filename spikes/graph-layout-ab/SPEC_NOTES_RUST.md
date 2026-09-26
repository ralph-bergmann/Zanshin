# SPEC notes — Rust implementation (`rust/`)

Notes from implementing `SPEC.md` v1 in Rust. SPEC.md itself is unchanged.

## Ambiguities found (rust)

Each item names the reading the Rust code takes (the most literal one) and whether the Dart
build agreed when probed on 2026-09-26 (`dart/build/graph_layout`, same inputs, `cmp`).
None of them occurs in the generated `inputs/`; all 48 layout outputs are byte-identical.

1. **`free` step 1, `tmin` and a root with a timestamp.** "tmin = the least non-null ts"
   does not say whether an `is_root` node's non-null ts counts, although step 1 then maps
   that node to tmin. Reading: every non-null ts counts, `is_root` included. Only matters
   when a root carries a ts (the dumper writes `null` for `root()`). Dart: same.
2. **Lower bound of `priority`.** V4 only says `priority` < 2^31; the §2 table says
   "ordering class ≥ 0". Reading: both hold, so a negative priority is invalid input
   (exit 2). Dart: same.
3. **Which JSON is accepted.** §2 says "any valid JSON (any whitespace, any key order)".
   Readings:
   - every listed field is required, except `id` (the layout never reads it);
   - unknown keys are ignored;
   - duplicate keys are valid JSON, and the last one wins, as in `JSON.parse` and
     `dart:convert` (serde's derive rejects them, so the parser retries through
     `serde_json::Value` when the typed fast path fails);
   - a non-integer number (`1.0`, `1e3`) where an integer is expected is invalid (exit 2).

   Dart: same on all four.
4. **Range of `utc_offset_min` (and extreme `ts`).** V4 bounds it only by ±2^53, so
   `off = utc_offset_min·60000` can overflow i64 in `time`. Release Rust and Dart both wrap,
   and they agree byte for byte on a probe with `utc_offset_min` = 2^53. A debug Rust build
   panics instead. Separately, a `day` bucket's `value` lies up to one day below `ts − off`,
   so a `ts` near −2^53 yields an output integer outside the ±2^53 that §1 promises.
   Suggestion for v2: V4 requires |utc_offset_min| ≤ 1440 and ts within ±(2^53 − 2 days).
5. **CLI details §6 leaves open.**
   - `--runs` is optional with default 31: the §6 grammar shows it as required, but §8.2
     calls N = 31 "the defaults";
   - `--runs` must be ≥ 1 (the median and the digest need one timed run), `--warmup` ≥ 0;
   - `--runs` / `--warmup` on `layout`, an unknown flag and a repeated flag are usage
     errors (exit 2); `--flag=value` is accepted besides `--flag value`;
   - an unreadable input or an unwritable output file also exits 2, because §6 knows only
     0 and 2.

   Dart: same exit codes, and it accepts `--flag=value` too.
6. **`bench` line fields and phase boundaries.**
   - `edges` is E, the layout edges (missing parents excluded), per the §1 notation;
   - `input` is the basename of the path;
   - the `parse` phase includes V1–V4 validation;
   - the `layering` phase includes the §4.1 graph prep, as the §4.1 heading says.

   Dart: same `nodes`, `edges`, `rows`, `lanes` and `digest` on `synth-10k` time/optimized.
7. **Budget overrun in the lane-order search.** "if spent + work > BUDGET: stop the phase"
   is read as ending the whole search at once: no later lane of that round is tried, no
   further round runs, and the current π stands.

## Resolved in the stage-3 diff (2026-09-26)

All seven items are now settled in SPEC.md, marked *Clarified during diff*. Items 1, 2 and 5–7
confirm the readings above. Item 4's suggestion was adopted as V4: |utc_offset_min| ≤ 1440. A
day `value` below −2^53 stays accepted, see §1.

Item 3 was not what the code did: serde read an absent `ts_ms` / `idx` as null, while Dart
rejected it. The probes also found three places where Rust accepted or rejected input
differently from Dart. All four are fixed in `src/input.rs`, each with a regression test:
- an absent nullable key is now rejected;
- invalid UTF-8 inside an ignored string is now rejected (serde_json skipped it unchecked);
- the integer `-0` now reads as 0 (serde_json reads it as the float −0.0);
- `utc_offset_min` is now bounded to ±1440.

# Structural diff probe (Story 5.9)

A throwaway, detached crate for Story 5.9's research: it puts **jj-lib's word marks** (what Zanshin's
inspector draws since Story 10.32) and **difftastic's structural marks** (`difft` 0.72.0) side by
side on the same hunk lines, and measures what difftastic costs and when it falls back. The report
that cites these results is
`_bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md`.

Since Story 5.9's closing run it also measures **E2**, the line pairing Zanshin builds: it compiles
`crates/zanshin-jj/src/line_pairs.rs` itself (`#[path]` in `src/main.rs`), so E2's marks and times
here are the product's code. The report's section 9 cites those results
([Results of the E2 run](#results-of-the-e2-run-2026-11-12-story-59s-closing-run)).

The crate is its own workspace (an empty `[workspace]` table and its own `Cargo.lock`), so the
Zanshin workspace, its gate and its coverage never see it. Nothing in the product uses it. Its
`analysis_options.yaml` keeps the Dart analyzer off the `.dart` fixtures in `inputs/` and `out/`.

## Method

- **difft version.** Every mode runs `difft --version` first and stops unless it reports
  `Difftastic 0.72.0`: the JSON format is unstable, and the numbers below are 0.72.0's.
- **jj marks.** jj-lib 0.47.0's `unified_diff_hunks` over the two full sides (context 3,
  `LineCompareMode::Exact`). A line's `Different` tokens are its marks, merged into runs by the rule
  of `crates/zanshin-jj/src/hunks.rs`'s `hunk_line`; context lines have none. These are the
  segments the inspector gets.
- **difft marks.** `DFT_UNSTABLE=yes difft --display json --color never <left> <right>` with every
  other `DFT_*` variable removed, so difftastic runs at its defaults. The JSON lists each side's
  novel spans per 0-based line, as byte columns of the line without its `\r` (difft strips every
  carriage return first). The probe maps the columns back to the original bytes and checks each
  span's `content` against the text; every mode prints the mismatches it found.
- **Mapping onto jj's hunk lines.** jj's line hunks stay as they are. A `Removed` line takes the
  left side's spans on its line, an `Added` line the right side's, a `Context` line none. Two
  rules are measured:
  - *first rule:* every novel span;
  - *corrected rule:* difft's code spans, but inside a novel comment or string only what jj's word
    diff marks there. difft's JSON lists every word of a changed comment or string, changed or
    not (see the `edge-multiline-token` witness): `MatchKind::is_novel()` counts difftastic's
    `UnchangedPartOfNovelItem`, and the JSON's `highlight` has no value for it.
  A file where difft falls back (its `language` field starts with `Text`) keeps jj's marks.
- **Comparison.** Per removed or added line, two views:
  - *word marks:* the marked bytes that are not whitespace — *same marks*, *difft marks fewer
    bytes* (a strict subset), *more bytes* (a strict superset), *different bytes* (neither), or
    *difft fell back*;
  - *drawn:* the bytes Story 10.32's `diffWordMarks` fills, whitespace included, after its rule
    that a line whose unmarked text holds no visible character (Unicode whitespace does not count)
    gets no strong marks.
- **Time and memory.** jj: in-process, inputs in memory. difft: the whole process (start, file
  reads, JSON) under `/usr/bin/time -l`, which also gives its peak resident set size. `limits`
  reports the median of three runs, and runs jj in a process of its own
  (`structural-diff-probe jj-marks`) to get jj's peak memory too.
- **E2 marks.** The same hunks after `line_pairs::pair_lines`: each changed block's removed and
  added lines paired by similarity, each pair word-diffed with jj-lib's `ContentDiff::by_word`, a
  line without a partner one changed run. E2's time is `pair_lines` alone, on top of jj's.
- **E2 against difft.** The same two views, with E2's marks in jj's place. The corrected mapping
  rule then takes **E2's** word marks inside a novel comment or string, not today's: each side is
  compared with difft on code tokens only, as the rule does for today. With today's marks there,
  difft's proxy would carry the very scatter E2 removes (see `d(e2)` in the `widget-test-rename`
  witness).
- **E2 against today.** Per changed line, E2's marked bytes against today's, in both views.
- **`--jobs N`** (`history`): difft runs first, over every file, on N threads; its marks are the
  same, but its times are then not reported. jj's and E2's marks and times are computed afterwards,
  in-process and one file at a time.

## Modes and rerun commands

Requirements: the repository's Rust toolchain (1.99.1), the crates in `$CARGO_HOME`'s registry
cache (jj-lib 0.47.0, serde_json, tree-sitter 0.27.1, tree-sitter-rust 0.24.2, tree-sitter-dart
0.3.0, tree-sitter-md 0.5.4), and `difft` 0.72.0 on `PATH`. From this directory:

```sh
cargo build --release --offline
./target/release/structural-diff-probe witness
./target/release/structural-diff-probe history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009
./target/release/structural-diff-probe limits
./target/release/structural-diff-probe parse-check --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009
# E2 run (Story 5.9's closing run): difft on 8 threads, so the run fits in a few minutes
./target/release/structural-diff-probe history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009 --jobs 8
```

| mode | input | output |
|---|---|---|
| `witness` | `inputs/witness/<case>/before.*` and `after.*`, plus `edge-cr-tab` built in code (carriage returns and a tab); `widget-test-rename` is Ralph's widget-test hunk, its lines unchanged inside a minimal Dart frame so difft parses it | per changed line jj's, difft's and E2's marks in `[-…-]` / `{+…+}` notation, with both comparisons |
| `history` | every `.rs` / `.dart` file modified (status `M`, no rename detection) in the newest `--commits` (default 200) non-merge commits of `--rev` that modify one; generated files skipped (by name and by generator header) | class counts in both views for today and for E2, the net change of today's gap to difft under E2 (`(today − E2) / today`: lines E2 brings to difft's marks minus lines it takes away), E2 against today, the files where E2's per-file budget left a block to jj, time per file (jj, E2, difft without `--jobs`), peak memory, per-commit sums, the fallback files, examples; one row per file in `out/history.tsv` (or `--tsv FILE`) |
| `limits` | inputs generated into `out/limits/` that trip each difft fallback, with lowered and raised limits, two conflicted files, and three inputs that fill E2's per-file budget (`e2-at-cap`, `e2-reformatted-calls`, `e2-pruned-blocks`) | difft's `language`, wall time and peak memory for difft, jj and E2, and whether E2's budget left a block to jj |
| `parse-check` | the `.rs`, `.dart`, `.md` files at `--rev` (read with `git show`), two known-bad samples, newer Dart syntax samples | ERROR / MISSING nodes per grammar, parse time |

All modes print Markdown to stdout. `out/` (generated inputs, temp files, `history.tsv`) is
git-ignored. `history` takes about 7 minutes on an otherwise idle machine (one `difft` process
per file; earlier runs under load took up to 25 minutes), with `--jobs 8` about 2.5 minutes; `limits` and
`parse-check` about a minute each. Timings vary by a few percent between runs; the classes and
fallbacks do not.

## Results (2026-11-12, Apple M4 Pro, 24 GB, macOS 27.2.1)

The blocks below are the four commands' stdout, verbatim.

### `witness`

difft: Difftastic 0.72.0

#### edge-context-novel (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.1 ms in-process · difft: language `Rust`, status `changed`, 69.6 ms wall

```text
@@ hunk 1 @@
  ctx   |fn order() {
+ jj    |{+    beta();+}
+ difft |    {+beta+}();   <- difft marks fewer bytes; drawn: difft marks more bytes
  ctx   |    alpha();
- jj    |[-    beta();-]
- difft |    [-beta-]();   <- difft marks fewer bytes; drawn: difft marks more bytes
  ctx   |    gamma();
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 14, difft 8 — difft marks less; same marks on 0 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 0 of 2.
difft marks the mapping drops: 2 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### edge-multiline-token (.rs)

jj: 1 hunk(s), 4 changed line(s), 0.0 ms in-process · difft: language `Rust`, status `changed`, 36.9 ms wall

```text
@@ hunk 1 @@
  ctx   |/* The parser reads
- jj    |   every line [-once-]. */
- difft |   every line [-once-]. */   <- same marks; drawn: same marks
- 1st   |[-   every line once. */-]   <- the first rule: difft marks more bytes
+ jj    |   every line {+twice+}. */
+ difft |   every line {+twice+}. */   <- same marks; drawn: same marks
+ 1st   |{+   every line twice. */+}   <- the first rule: difft marks more bytes
  ctx   |const HELP: &str = r"usage:
  ctx   |  probe witness
- jj    |  probe [-history-]";
- difft |  probe [-history-]";   <- same marks; drawn: same marks
- 1st   |[-  probe history"-];   <- the first rule: difft marks more bytes
+ jj    |  probe {+limits+}";
+ difft |  probe {+limits+}";   <- same marks; drawn: same marks
+ 1st   |{+  probe limits"+};   <- the first rule: difft marks more bytes
```

Marked non-whitespace bytes on changed lines: jj 22, difft 22 — both mark the same amount; same marks on 4 of 4 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 4 of 4.
difft marks the mapping drops: 6 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### edge-non-ascii (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process · difft: language `Rust`, status `changed`, 33.3 ms wall

```text
@@ hunk 1 @@
  ctx   |fn greet() -> String {
- jj    |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick([-alpha-]))
- difft |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick([-alpha-]))   <- same marks; drawn: same marks
+ jj    |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick({+beta+}))
+ difft |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick({+beta+}))   <- same marks; drawn: same marks
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 9, difft 9 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 2 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### moved-block (.rs)

jj: 2 hunk(s), 8 changed line(s), 0.0 ms in-process · difft: language `Rust`, status `changed`, 33.3 ms wall

```text
@@ hunk 1 @@
- jj    |[-fn first() -> u32 {-]
- difft |[-fn-] [-first()-] [-->-] [-u32-] [-{-]   <- same marks; drawn: same marks
- jj    |[-    1-]
- difft |    [-1-]   <- same marks; drawn: same marks
- jj    |[-}-]
- difft |[-}-]   <- same marks; drawn: same marks
- jj    |
- difft |   <- same marks; drawn: same marks
  ctx   |fn second() -> u32 {
  ctx   |    first() + 1
  ctx   |}
@@ hunk 2 @@
  ctx   |fn third() -> u32 {
  ctx   |    second() + 1
  ctx   |}
+ jj    |
+ difft |   <- same marks; drawn: same marks
+ jj    |{+fn first() -> u32 {+}
+ difft |{+fn+} {+first()+} {+->+} {+u32+} {+{+}   <- same marks; drawn: same marks
+ jj    |{+    1+}
+ difft |    {+1+}   <- same marks; drawn: same marks
+ jj    |{+}+}
+ difft |{+}+}   <- same marks; drawn: same marks
```

Marked non-whitespace bytes on changed lines: jj 34, difft 34 — both mark the same amount; same marks on 8 of 8 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 8 of 8.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### nesting (.rs)

jj: 1 hunk(s), 8 changed line(s), 0.0 ms in-process · difft: language `Rust`, status `changed`, 34.0 ms wall

```text
@@ hunk 1 @@
  ctx   |fn update(state: &mut State, event: Event) {
- jj    |    state.apply(event);
- difft |    state.apply(event);   <- same marks; drawn: same marks
- jj    |    state.save();
- difft |    state.save();   <- same marks; drawn: same marks
- jj    |    log(state.summary());
- difft |    log(state.summary());   <- same marks; drawn: same marks
+ jj    |    {+if event.is_relevant() {+}
+ difft |    {+if+} {+event.is_relevant()+} {+{+}   <- same marks; drawn: same marks
+ jj    |{+        +}state.apply(event);
+ difft |        state.apply(event);   <- same marks; drawn: difft marks fewer bytes
+ jj    |    {+    +}state.save();
+ difft |        state.save();   <- same marks; drawn: difft marks fewer bytes
+ jj    |    {+}+}
+ difft |    {+}+}   <- same marks; drawn: same marks
+ jj    |{+    +}log({+redact(+}state.summary()){+)+};
+ difft |    log({+redact(+}state.summary(){+)+});   <- different bytes; drawn: different bytes
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 31, difft 31 — both mark the same amount; same marks on 7 of 8 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 5 of 8.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### reformat (.rs)

jj: 1 hunk(s), 6 changed line(s), 0.0 ms in-process · difft: language `Rust`, status `unchanged`, 33.2 ms wall

```text
@@ hunk 1 @@
  ctx   |fn main() {
- jj    |    let result = compute(first_argument, second_argument, third_argument);
- difft |    let result = compute(first_argument, second_argument, third_argument);   <- same marks; drawn: same marks
+ jj    |    let result = compute(
+ difft |    let result = compute(   <- same marks; drawn: same marks
+ jj    |{+        +}first_argument,
+ difft |        first_argument,   <- same marks; drawn: difft marks fewer bytes
+ jj    |{+       +} second_argument,
+ difft |        second_argument,   <- same marks; drawn: difft marks fewer bytes
+ jj    |{+       +} third_argument{+,+}
+ difft |        third_argument,   <- difft marks fewer bytes; drawn: difft marks fewer bytes
+ jj    |{+    +});
+ difft |    );   <- same marks; drawn: difft marks fewer bytes
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 1, difft 0 — difft marks less; same marks on 5 of 6 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 2 of 6.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### reorder-dart (.dart)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process · difft: language `Dart`, status `changed`, 44.1 ms wall

```text
@@ hunk 1 @@
  ctx   |void main() {
- jj    |  final total = f([-a, -]b);
- difft |  final total = f([-a,-] b);   <- same marks; drawn: difft marks fewer bytes
+ jj    |  final total = f(b{+, a+});
+ difft |  final total = f(b{+,+} {+a+});   <- same marks; drawn: difft marks fewer bytes
  ctx   |  print(total);
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 4, difft 4 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 0 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### reorder-rust (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process · difft: language `Rust`, status `changed`, 31.5 ms wall

```text
@@ hunk 1 @@
  ctx   |fn main() {
- jj    |    let total = f([-a, -]b);
- difft |    let total = f([-a,-] b);   <- same marks; drawn: difft marks fewer bytes
+ jj    |    let total = f(b{+, a+});
+ difft |    let total = f(b{+,+} {+a+});   <- same marks; drawn: difft marks fewer bytes
  ctx   |    println!("{total}");
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 4, difft 4 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 0 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### stepper (.dart)

jj: 3 hunk(s), 9 changed line(s), 0.1 ms in-process · difft: language `Dart`, status `changed`, 37.9 ms wall

```text
@@ hunk 1 @@
  ctx   |
  ctx   |  @override
  ctx   |  Widget build(BuildContext context) => FilledButton(
- jj    |    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),
- difft |    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),   <- same marks; drawn: same marks
+ jj    |    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),
+ difft |    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),   <- same marks; drawn: same marks
  ctx   |  );
  ctx   |}
  ctx   |
@@ hunk 2 @@
  ctx   |
  ctx   |  @override
  ctx   |  Widget build(BuildContext context) => Row(children: [
- jj    |    Expanded(child: _Line(color: isFirst ? null : lineColor)),
- difft |    Expanded(child: _Line(color: isFirst ? null : lineColor)),   <- same marks; drawn: same marks
+ jj    |    Expanded(
+ difft |    Expanded(   <- same marks; drawn: same marks
+ jj    |{+      +}child: _Line(color: isFirst ? null : lineColor){+,+}
+ difft |      child: _Line(color: isFirst ? null : lineColor){+,+}   <- same marks; drawn: difft marks fewer bytes
+ jj    |{+    +}),
+ difft |    ),   <- same marks; drawn: difft marks fewer bytes
  ctx   |    DecoratedBox(
  ctx   |      decoration: BoxDecoration(color: lineColor),
  ctx   |      child: const SizedBox(width: 8, height: 8),
@@ hunk 3 @@
  ctx   |}
  ctx   |
  ctx   |Widget stepLabel(Widget label) => Padding(
- jj    |  padding: Spacing.[-spacing8-],
- difft |  padding: Spacing.[-spacing8-],   <- same marks; drawn: same marks
+ jj    |  {+// Small side padding.+}
+ difft |  {+// Small side padding.+}   <- same marks; drawn: same marks
+ jj    |{+  +}padding: Spacing.{+spacing2+},
+ difft |  padding: Spacing.{+spacing2+},   <- same marks; drawn: difft marks fewer bytes
  ctx   |  child: label,
  ctx   |);
```

Marked non-whitespace bytes on changed lines: jj 66, difft 66 — both mark the same amount; same marks on 9 of 9 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 6 of 9.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### edge-cr-tab (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process · difft: language `Rust`, status `changed`, 42.7 ms wall

```text
@@ hunk 1 @@
  ctx   |fn main() {
- jj    |\tlet s = "a\rb"; f([-x-]);
- difft |\tlet s = "a\rb"; f([-x-]);   <- same marks; drawn: same marks
+ jj    |\tlet s = "a\rb"; f({+y+});
+ difft |\tlet s = "a\rb"; f({+y+});   <- same marks; drawn: same marks
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 2, difft 2 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 2 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 2. Content mismatches: 0.

### `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009`

difft: Difftastic 0.72.0

#### Corpus

- Revision `5ba5f5d43b21d45c24c099092384f9d9610fe009`; 200 non-merge commits that modify a `.rs` or `.dart` file, 2026-10-23 to 2026-11-12.
- Scope: files a commit modifies (status `M`, no rename detection); added, deleted and renamed files are not diffed.
- 2706 modified `.rs` / `.dart` files: 170 generated and 0 binary skipped, 2536 diffed (Dart 1510, Rust 1026).
- difft fell back on 56 files: graph limit 56. It reported `unchanged` (no syntactic change) on 0 files.
- Rows per file: `out/history.tsv`.

#### Changed lines by class (corrected mapping; marked non-whitespace bytes)

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 53463 | 38077 | 91540 | 79.2 % |
| difft marks fewer bytes | 1660 | 1046 | 2706 | 2.3 % |
| difft marks more bytes | 740 | 471 | 1211 | 1.0 % |
| different bytes | 351 | 487 | 838 | 0.7 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

#### As Story 10.32 draws them (drawn bytes, whitespace fills included; no strong marks on a line without visible unmarked text)

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 50125 | 35358 | 85483 | 74.0 % |
| difft marks fewer bytes | 4843 | 3743 | 8586 | 7.4 % |
| difft marks more bytes | 735 | 388 | 1123 | 1.0 % |
| different bytes | 511 | 592 | 1103 | 1.0 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

#### The first mapping rule (every novel span, whole comments and strings included)

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 50244 | 33706 | 83950 | 72.7 % |
| difft marks fewer bytes | 1603 | 1022 | 2625 | 2.3 % |
| difft marks more bytes | 3959 | 4842 | 8801 | 7.6 % |
| different bytes | 408 | 511 | 919 | 0.8 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

Files where the drawn marks would change on at least one line: 1454 of 2536.

Changed lines jj marks and difft leaves without marks (difft calls them unchanged): 1233; lines difft marks and jj leaves without marks: 219.

difft marks the mapping drops (files without a fallback): 1626 on jj context lines, 882 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### Time per file

| | jj Dart | difft Dart | jj Rust | difft Rust |
|---|---:|---:|---:|---:|
| median | 0.2 ms | 63.4 ms | 0.3 ms | 60.4 ms |
| p90 | 0.6 ms | 180.4 ms | 0.8 ms | 144.0 ms |
| p99 | 1.3 ms | 1564.4 ms | 1.6 ms | 685.3 ms |
| max | 3.5 ms | 3036.4 ms | 3.0 ms | 3470.1 ms |
| sum | 410.6 ms | 214214.6 ms | 389.4 ms | 96829.8 ms |

difft over 100 ms: 506 files, over 250 ms: 154, over 1 s: 66 (of 2536). jj times are in-process, inputs in memory; difft times are the whole process (start, file reads, JSON) under `/usr/bin/time -l`.

difft peak memory per file (maximum resident set size): median 20.8 MB, p90 129.7 MB, p99 946.2 MB, max 986.0 MB.

Per commit (198 commits with a diffed file), summed over its files: jj median 2.6 ms, p90 9.6 ms, max 35.8 ms; difft median 848.4 ms, p90 4093.8 ms, max 11309.9 ms.

Slowest difft files:

- `crates/zanshin-jj/src/repo.rs@0c00652a` (292563 bytes): 3470.1 ms
- `packages/zanshin_ui/lib/src/design/zs_colors.dart@cf6cb003` (78075 bytes): 3036.4 ms
- `packages/zanshin_ui/lib/src/design/zs_colors.dart@c18e56bd` (77029 bytes): 2634.5 ms
- `packages/zanshin_core/lib/src/worker/isolate.dart@b6da7c21` (241395 bytes): 1995.6 ms
- `packages/zanshin_core/lib/src/worker/isolate.dart@5e58ec3d` (185551 bytes): 1949.6 ms

Fallback files: 56, of 13112 to 292563 bytes (right side); difft took 925.3–3470.1 ms on each, 81661.8 ms together, and peaked at 869.6–986.0 MB; 55 of the 66 files over 1 s are among them.

#### Examples (the lines where the two differ most)

##### difft marks fewer bytes

```text
app/test/app/app_window_coordinator_test.dart@fcc1b4d9:+87
  jj    |    {+windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);+}
  difft |    windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);
app/test/app/app_window_coordinator_test.dart@fcc1b4d9:-87
  jj    |[-    windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);-]
  difft |    windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);
crates/zanshin-jj/src/squash_split.rs@3ee3f297:+635
  jj    |{+    let use_move_flags = options.onto.is_some() || options.insert_after.is_some() || options.insert_before.is_some();+}
  difft |    let use_move_flags = options.onto.is_some() || options.insert_after.is_some() || options.insert_before.is_some();
packages/zanshin_core/test/graph_layout/router_test.dart@2459cc42:+224
  jj    |{+    out.add((name: name, grid: GraphGridView.fromBytes(computeGraphGrid(input, mode: mode)), parentCounts: counts));+}
  difft |    out.add((name: {+name+}, grid: GraphGridView.fromBytes(computeGraphGrid(input, mode: mode)), parentCounts: counts));
app/test/features/graph/layout_invariants_test.dart@e2284b7a:+192
  jj    |{+      points: Float64List.fromList(<double>[0, 0, 0, -50, 100, -50, 100, -100, 50, 0, 50, -50, 150, -50, 150, -100]),+}
  difft |      points: Float64List.fromList(<double>[0, 0, 0, -50, 100, -50, 100, -100, 50, 0, 50, -50, 150, -50, 150, -100]),
```

##### difft marks more bytes

```text
app/lib/src/features/graph/graph_canvas.dart@c4579635:+334
  jj    |{+        +}!identical(oldWidget.transition, transition) && transition != null && identical(transition.to, widget.layout){+;+}
  difft |        {+!identical(oldWidget.transition,+} {+transition)+} {+&&+} {+transition+} {+!=+} {+null+} {+&&+} {+identical(transition.to,+} {+widget.layout);+}
app/test/features/graph/layout_invariants_test.dart@e2284b7a:-202
  jj    |      final RouteReport sameSlot = [-check-](Int32List.fromList(<int>[0, 0]), Int32List.fromList(<int>[0, 1]));
  difft |      [-final-] [-RouteReport-] [-sameSlot-] [-=-] [-check(Int32List.fromList(<int>[0,-] [-0]),-] [-Int32List.fromList(<int>[0,-] [-1]));-]
app/lib/src/features/home/home_page.dart@0d7811d4:+100
  jj    |    case ProjectOpenFailed() || ProjectNotARepo(kind: RepoKind.pathNotFound) when windows != null:
  difft |    {+case+} {+ProjectOpenFailed()+} {+||+} {+ProjectNotARepo(kind:+} {+RepoKind.pathNotFound)+} {+when+} {+windows+} {+!=+} {+null:+}
app/lib/src/features/home/home_page.dart@0d7811d4:-99
  jj    |    [-  -]case ProjectOpenFailed() || ProjectNotARepo(kind: RepoKind.pathNotFound) when windows != null:
  difft |      [-case-] [-ProjectOpenFailed()-] [-||-] [-ProjectNotARepo(kind:-] [-RepoKind.pathNotFound)-] [-when-] [-windows-] [-!=-] [-null:-]
app/lib/src/features/home/home_page.dart@995e2040:+217
  jj    |            toastSpan({+strings+}.toastOpened(toastSlot(0)), <InlineSpan>[TextSpan(text: report.name)]),
  difft |            {+toastSpan(strings.toastOpened(toastSlot(0)),+} {+<InlineSpan>[TextSpan(text:+} {+report.name)]),+}
```

##### different bytes

```text
packages/zanshin_core/lib/src/ffi/precondition.dart@995e2040:-167
  jj    |({List<ZanshinWarning> warnings, Precondition? precondition})[- decodeCreationReport(Uint8List bytes) =>-]
  difft |[-({List<ZanshinWarning>-] [-warnings,-] [-Precondition?-] [-precondition})-] decodeCreationReport(Uint8List bytes) =>
app/lib/src/features/graph/graph_canvas.dart@c4579635:-332
  jj    |    [-if-] [-(-]!identical(oldWidget.transition, transition) && transition != null && identical(transition.to, widget.layout)) {
  difft |    if ([-!identical(oldWidget.transition,-] [-transition)-] && transition [-!=-] [-null-] [-&&-] [-identical(transition-].[-to,-] [-widget.layout)-]) {
app/lib/src/features/graph/graph_stack_card.dart@5c607633:-559
  jj    |[-        if (authorsW <-] _paragraph(TextSpan(text: [-authorsText!-].characters.first, style: meta)).width) {
  difft |        if (authorsW < [-_paragraph(TextSpan-]([-text:-] authorsText![-.characters.first,-] [-style:-] [-meta-])[-).width-]) {
app/lib/src/features/projects/worker_project_repos.dart@5d5548c0:-88
  jj    |[-      _worker.-]events.where((event) => event is OpHeadsChangedEvent[- && event.handleId == handle.handleId-]).map((_) {});
  difft |      _worker.events.where((event) => [-event-] [-is-] [-OpHeadsChangedEvent-] [-&&-] event.handleId == handle.handleId)[-.map((_)-] [-{})-];
crates/zanshin-jj/src/bookmark_ops.rs@65c3be24:-120
  jj    |        StringExpression::exact([-jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO-].as_str())
  difft |        [-StringExpression::exact-](jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO[-.as_str()-])
```

### `limits`

difft: Difftastic 0.72.0

| input | bytes before / after | difft args | difft `language` | difft wall | difft peak RSS | jj changed lines | jj in-process | jj process peak RSS |
|---|---:|---|---|---:|---:|---:|---:|---:|
| byte-limit | 1108780 / 1108780 | defaults | `Text (1.1 MiB exceeded DFT_BYTE_LIMIT)` | 80.7 ms | 63.3 MB | 2 | 8.3 ms | 17.0 MB |
|  | 1108780 / 1108780 | `--byte-limit 100000000` | `Rust` | 890.3 ms | 385.6 MB |  | |  |
| scattered-changes | 548965 / 548965 | defaults | `Rust` | 1145.5 ms | 328.1 MB | 4000 | 14.5 ms | 15.1 MB |
|  | 548965 / 548965 | `--graph-limit 300000` | `Rust` | 1119.2 ms | 321.0 MB |  | |  |
| graph-limit-statements | 548965 / 548965 | defaults | `Text (exceeded DFT_GRAPH_LIMIT)` | 1559.4 ms | 1074.3 MB | 40000 | 90.8 ms | 37.1 MB |
|  | 548965 / 548965 | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 932.8 ms | 328.4 MB |  | |  |
| graph-limit-array | 204032 / 204032 | defaults | `Text (exceeded DFT_GRAPH_LIMIT)` | 4108.3 ms | 620.2 MB | 12000 | 13.5 ms | 35.5 MB |
|  | 204032 / 204032 | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 3767.9 ms | 198.5 MB |  | |  |
|  | 204032 / 204032 | `--graph-limit 6000000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 4708.5 ms | 1094.5 MB |  | |  |
| parse-error-rust | 66 / 83 | defaults | `Text (1 Rust parse error, exceeded DFT_PARSE_ERROR_LIMIT, first at 3:8)` | 40.9 ms | 12.8 MB | 3 | 0.1 ms | 2.4 MB |
| parse-error-dart | 72 / 76 | defaults | `Text (4 Dart parse errors, exceeded DFT_PARSE_ERROR_LIMIT, first at 1:0)` | 44.6 ms | 10.7 MB | 2 | 0.1 ms | 2.4 MB |
|  | 72 / 76 | `--parse-error-limit 10` | `Dart` | 47.0 ms | 10.7 MB |  | |  |
| missing-node-rust | 27 / 26 | defaults | `Rust` | 39.4 ms | 12.7 MB | 2 | 0.0 ms | 2.4 MB |
| no-parser-markdown | 32 / 38 | defaults | `Text` | 26.2 ms | 6.0 MB | 2 | 0.0 ms | 2.4 MB |
| conflict-jj-diff-style | 91 / 323 | defaults | `Text (2 Rust parse errors, exceeded DFT_PARSE_ERROR_LIMIT, first at 2:0)` | 37.1 ms | 12.8 MB | 9 | 0.1 ms | 2.4 MB |
| conflict-git-style | 91 / 254 | defaults | `Text (1 Rust parse error, exceeded DFT_PARSE_ERROR_LIMIT, first at 2:0)` | 37.4 ms | 12.7 MB | 6 | 0.0 ms | 2.3 MB |

Median of 3 runs. Peak RSS is `/usr/bin/time -l`'s maximum resident set size; jj's is a process of its own that reads both files and computes the marks.

Over all difft runs above: span content mismatches 0, spans moved by a carriage return 0.

#### byte-limit

13,000 small Rust functions (a side over 1,000,000 bytes); one function in the middle changes.

```text
- jj    |    value.wrapping_mul(6500).rotate_left([-3-])
- build |    value.wrapping_mul(6500).rotate_left([-3-])   <- difft fell back
+ jj    |    value.wrapping_mul(6500).rotate_left({+5+})
+ build |    value.wrapping_mul(6500).rotate_left({+5+})   <- difft fell back
```

#### scattered-changes

One Rust function of 20,000 statements (under the byte limit); every 10th statement changes. Does not trip the graph limit at its default.

```text
- jj    |    values.push(0 * [-3-]);
- build |    values.push(0 * [-3-]);   <- same marks
+ jj    |    values.push(0 * {+4+});
+ build |    values.push(0 * {+4+});   <- same marks
- jj    |    values.push(10 * [-3-]);
- build |    values.push(10 * [-3-]);   <- same marks
+ jj    |    values.push(10 * {+4+});
+ build |    values.push(10 * {+4+});   <- same marks
```

#### graph-limit-statements

The same function; every statement changes.

```text
- jj    |    values.push(0 * [-3-]);
- build |    values.push(0 * [-3-]);   <- difft fell back
- jj    |    values.push(1 * [-3-]);
- build |    values.push(1 * [-3-]);   <- difft fell back
- jj    |    values.push(2 * [-3-]);
- build |    values.push(2 * [-3-]);   <- difft fell back
- jj    |    values.push(3 * [-3-]);
- build |    values.push(3 * [-3-]);   <- difft fell back
```

#### graph-limit-array

One Rust array literal of 60,000 small numbers, ten per line; every third number changes.

```text
- jj    |    [-0-], [-1-], [-2-], [-3-], [-4-], [-5-], [-6-], [-0-], [-1-], [-2-],
- build |    [-0-], [-1-], [-2-], [-3-], [-4-], [-5-], [-6-], [-0-], [-1-], [-2-],   <- difft fell back
- jj    |    [-3-], [-4-], [-5-], [-6-], [-0-], [-1-], [-2-], [-3-], [-4-], [-5-],
- build |    [-3-], [-4-], [-5-], [-6-], [-0-], [-1-], [-2-], [-3-], [-4-], [-5-],   <- difft fell back
- jj    |    [-6-], [-0-], [-1-], [-2-], [-3-], [-4-], [-5-], [-6-], [-0-], [-1-],
- build |    [-6-], [-0-], [-1-], [-2-], [-3-], [-4-], [-5-], [-6-], [-0-], [-1-],   <- difft fell back
- jj    |    [-2-], [-3-], [-4-], [-5-], [-6-], [-0-], [-1-], [-2-], [-3-], [-4-],
- build |    [-2-], [-3-], [-4-], [-5-], [-6-], [-0-], [-1-], [-2-], [-3-], [-4-],   <- difft fell back
```

#### parse-error-rust

A Rust syntax error on the right side (`let = total;`, an ERROR node).

```text
- jj    |    let total = add(1, [-2-]);
- build |    let total = add(1, [-2-]);   <- difft fell back
+ jj    |    let total = add(1, {+3+});
+ build |    let total = add(1, {+3+});   <- difft fell back
+ jj    |{+    let = total;+}
+ build |{+    let = total;+}   <- difft fell back
```

#### parse-error-dart

Newer Dart syntax difft's grammar lacks: a primary constructor (valid in the installed Dart 3.15 beta); an unrelated expression changes.

```text
- jj    |int area(Point p) => p.x * p.y;
- build |int area(Point p) => p.x * p.y;   <- difft fell back
+ jj    |int area(Point p) => p.x * p.y{+ * 2+};
+ build |int area(Point p) => p.x * p.y{+ * 2+};   <- difft fell back
```

#### missing-node-rust

A Rust syntax error that tree-sitter repairs with a MISSING `)` (`f(b, a;`): difft counts no parse error.

```text
- jj    |    f([-a, -]b[-)-];
- build |    f[-(-]a[-,-] [-b)-];   <- different bytes
+ jj    |    f(b{+, a+};
+ build |    f{+(b,+} a;   <- different bytes
```

#### no-parser-markdown

Markdown: difft has no parser for it (`--list-languages`).

```text
- jj    |Some text with [-a-] word.
- build |Some text with [-a-] word.   <- difft fell back
+ jj    |Some text with {+another+} word.
+ build |Some text with {+another+} word.   <- difft fell back
```

#### conflict-jj-diff-style

The right side holds a conflict in jj's default marker style (`diff`, as in jj's docs/conflicts.md @ v0.47.0), as Zanshin diffs a conflicted file.

```text
- jj    |    let width = 80;
- build |    let width = 80;   <- difft fell back
+ jj    |{+<<<<<<< conflict 1 of 1+}
+ build |{+<<<<<<< conflict 1 of 1+}   <- difft fell back
+ jj    |{+%%%%%%% diff from: vpxusssl 38d49363 "merge base"+}
+ build |{+%%%%%%% diff from: vpxusssl 38d49363 "merge base"+}   <- difft fell back
+ jj    |{+\\\\\\\        to: rtsqusxu 2768b0b9 "commit A"+}
+ build |{+\\\\\\\        to: rtsqusxu 2768b0b9 "commit A"+}   <- difft fell back
```

#### conflict-git-style

The same conflict in jj's `git` marker style.

```text
+ jj    |{+<<<<<<< rtsqusxu 2768b0b9 "commit A"+}
+ build |{+<<<<<<< rtsqusxu 2768b0b9 "commit A"+}   <- difft fell back
+ jj    |{+    let width = 100;+}
+ build |{+    let width = 100;+}   <- difft fell back
+ jj    |{+||||||| vpxusssl 38d49363 "merge base"+}
+ build |{+||||||| vpxusssl 38d49363 "merge base"+}   <- difft fell back
+ jj    |{+=======+}
+ build |{+=======+}   <- difft fell back
```

### `parse-check --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009`

difft: Difftastic 0.72.0

#### Repository files at `5ba5f5d43b21d45c24c099092384f9d9610fe009` (tracked, read with `git show`)

| language | files | MB | tree-sitter 0.27.1 + 5.4 grammar: files with ERROR nodes | files with only MISSING nodes | ERROR nodes | parse time sum | slowest file | difft 0.72.0 grammar: files with ERROR nodes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Rust | 281 | 9.4 | 0 | 0 | 0 | 474.0 ms | 81.0 ms | 0 of 281 |
| Dart | 628 | 9.8 | 0 | 0 | 0 | 1189.3 ms | 74.9 ms | 0 of 628 |
| Markdown | 420 | 13.7 | 0 | 0 | 0 | 3875.8 ms | 537.7 ms | no parser |

#### Positive controls (known-bad samples)

| sample | tree-sitter 0.27.1 + 5.4 grammar (ERROR / MISSING nodes) | difft 0.72.0's grammar (ERROR nodes) |
|---|---|---|
| Rust `let = ;` | error (1 / 0) | error |
| Dart `final = ;` | error (1 / 0) | error |

#### Newer Dart syntax

| sample | tree-sitter-dart 0.3.0 (ERROR / MISSING nodes) | difft 0.72.0's Dart grammar (ERROR nodes) |
|---|---|---|
| records and patterns (3.0) | ok | ok |
| switch expression (3.0) | ok | ok |
| class modifiers (3.0) | ok | ok |
| extension type (3.3) | ok | ok |
| digit separators (3.6) | ok | ok |
| wildcard variables (3.7) | ok | ok |
| null-aware elements (3.8) | ok | ok |
| dot shorthands (3.10) | ok | ok |
| primary constructor | ok | error |

## Results of the E2 run (2026-11-12, Story 5.9's closing run)

Same machine. `witness`, `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009 --jobs 8` and
`limits` again, with E2 at its final settings: similarity by tokens (each word or non-whitespace
byte of jj-lib's word diff counts 1), `MIN_SIMILARITY_PERCENT` 50, `MAX_RUN_LINES` 8, and
`MAX_PAIRING_WORK` 262,144 bytes as a per-file budget for the word diffs that score candidates.
Measured file: `crates/zanshin-jj/src/line_pairs.rs` with `git hash-object`
`15ddbd3902b9068efce3d7e4deee3a6e264183fa`; a later edit of that file detaches these figures.
`parse-check` does not touch E2 and was not rerun. Today's classes against difft reproduce the
research run exactly (4,755 word-mark and 10,812 drawn differences of 96,295 lines without a
fallback).

**How the budget was set.** The build first measured similarity in non-whitespace bytes and capped
each block alone (its one-to-one reads); the first four rows ran that way (figures from their
output; only the final runs' output is below). The spec's matrix audit then moved similarity to
tokens, so a renamed long identifier (`a.functionWizard_save` → `a.functionWizard_next`, 3 of 4
tokens kept) pairs. A review then found the per-block cap unbounded across blocks and blind to runs:
one block of one-line calls reformatted to one argument per line took 158 ms, a 24 KB file of 20
such blocks 3.15 s. The cap became a per-file budget on the bytes the scoring word diffs read.

| similarity, bounds, limit | `e2-at-cap` input | `e2-reformatted-calls` | E2 per file p99 (Dart / Rust) | E2 max |
|---|---|---:|---:|---:|
| bytes, the spec's size bound only, 1 MiB per block | 144 changed statements, numbers changed: 99 ms | — | — (not run) | — |
| bytes, size bound only, 256 KiB per block | the same input at 72 lines: 25 ms | — | 12.6 / 12.1 ms | 131.7 ms |
| bytes, size bound only, 64 KiB per block | — | — | 11.5 / 10.2 ms | 52.1 ms |
| bytes, plus the shared-token bound, 256 KiB per block | the input below (every pair shares all tokens): 18.1 ms | — | 1.6 / 1.6 ms | 6.8 ms |
| tokens, both bounds, 256 KiB per block | the input below: 17.6 ms | 3.15 s (the review) | 3.1 / 3.3 ms | 28.2 ms |
| **tokens, both bounds, 256 KiB per file (final)** | the input below: 18.0 ms | 21.2 ms | 3.0 / 3.4 ms | 15.0 ms |

A lower cap barely helped: the slow files hold ordinary blocks of a few dozen dissimilar lines, where
the size bound (`200 · min(left, right) − 50 · (left + right)`) prunes nothing, so nearly every
candidate ran a word diff. The second bound caps `kept` at the tokens the group's lines share
(words and non-word bytes, each occurrence matched once). jj-lib's word diff keeps only whole equal
words and equal single bytes, so the bound is an upper bound, and skipping never changes the
result: a run with debug assertions (`kept <= bound` on every diffed candidate) passed on all 2,536
files, with bytes and again with tokens, and its E2 counts equalled the run without assertions. The
first `e2-at-cap` input stopped being a worst case under that bound (1.6 ms), so it was replaced by
one the bound cannot prune. With the per-file budget, a search that uses all of it takes about
20 ms (18.0 and 21.2 ms above); the budget ran out in 9 of 2,536 real files, and E2's p99 is
2–3× jj's. The slowest file measured is `scattered-changes` at 23.7 ms (jj itself 16.5 ms): 2,000
small blocks that read little each, so its cost grows with the file, as jj's own diff does.

### `witness` (E2)

difft: Difftastic 0.72.0

#### edge-context-novel (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.1 ms in-process, E2 0.0 ms more · difft: language `Rust`, status `changed`, 80.4 ms wall

```text
@@ hunk 1 @@
  ctx   |fn order() {
+ jj    |{+    beta();+}
+ difft |    {+beta+}();   <- difft marks fewer bytes; drawn: difft marks more bytes
+ e2    |{+    beta();+}   <- against difft: difft marks fewer bytes; drawn: difft marks more bytes
  ctx   |    alpha();
- jj    |[-    beta();-]
- difft |    [-beta-]();   <- difft marks fewer bytes; drawn: difft marks more bytes
- e2    |[-    beta();-]   <- against difft: difft marks fewer bytes; drawn: difft marks more bytes
  ctx   |    gamma();
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 14, difft 8 — difft marks less; same marks on 0 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 0 of 2.
E2: 14 marked non-whitespace bytes; the same marks as difft on 0 of 2 changed line(s), drawn the same on 0 of 2.
difft marks the mapping drops: 2 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### edge-multiline-token (.rs)

jj: 1 hunk(s), 4 changed line(s), 0.0 ms in-process, E2 0.1 ms more · difft: language `Rust`, status `changed`, 59.3 ms wall

```text
@@ hunk 1 @@
  ctx   |/* The parser reads
- jj    |   every line [-once-]. */
- difft |   every line [-once-]. */   <- same marks; drawn: same marks
- 1st   |[-   every line once. */-]   <- the first rule: difft marks more bytes
- e2    |   every line [-once-]. */   <- against difft: same marks; drawn: same marks
+ jj    |   every line {+twice+}. */
+ difft |   every line {+twice+}. */   <- same marks; drawn: same marks
+ 1st   |{+   every line twice. */+}   <- the first rule: difft marks more bytes
+ e2    |   every line {+twice+}. */   <- against difft: same marks; drawn: same marks
  ctx   |const HELP: &str = r"usage:
  ctx   |  probe witness
- jj    |  probe [-history-]";
- difft |  probe [-history-]";   <- same marks; drawn: same marks
- 1st   |[-  probe history"-];   <- the first rule: difft marks more bytes
- e2    |  probe [-history-]";   <- against difft: same marks; drawn: same marks
+ jj    |  probe {+limits+}";
+ difft |  probe {+limits+}";   <- same marks; drawn: same marks
+ 1st   |{+  probe limits"+};   <- the first rule: difft marks more bytes
+ e2    |  probe {+limits+}";   <- against difft: same marks; drawn: same marks
```

Marked non-whitespace bytes on changed lines: jj 22, difft 22 — both mark the same amount; same marks on 4 of 4 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 4 of 4.
E2: 22 marked non-whitespace bytes; the same marks as difft on 4 of 4 changed line(s), drawn the same on 4 of 4.
difft marks the mapping drops: 6 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### edge-non-ascii (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process, E2 0.0 ms more · difft: language `Rust`, status `changed`, 42.9 ms wall

```text
@@ hunk 1 @@
  ctx   |fn greet() -> String {
- jj    |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick([-alpha-]))
- difft |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick([-alpha-]))   <- same marks; drawn: same marks
- e2    |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick([-alpha-]))   <- against difft: same marks; drawn: same marks
+ jj    |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick({+beta+}))
+ difft |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick({+beta+}))   <- same marks; drawn: same marks
+ e2    |    let grüße = "Grüße 🦀"; format!("{grüße} {}", pick({+beta+}))   <- against difft: same marks; drawn: same marks
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 9, difft 9 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 2 of 2.
E2: 9 marked non-whitespace bytes; the same marks as difft on 2 of 2 changed line(s), drawn the same on 2 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### moved-block (.rs)

jj: 2 hunk(s), 8 changed line(s), 0.0 ms in-process, E2 0.0 ms more · difft: language `Rust`, status `changed`, 43.9 ms wall

```text
@@ hunk 1 @@
- jj    |[-fn first() -> u32 {-]
- difft |[-fn-] [-first()-] [-->-] [-u32-] [-{-]   <- same marks; drawn: same marks
- e2    |[-fn first() -> u32 {-]   <- against difft: same marks; drawn: same marks
- jj    |[-    1-]
- difft |    [-1-]   <- same marks; drawn: same marks
- e2    |[-    1-]   <- against difft: same marks; drawn: same marks
- jj    |[-}-]
- difft |[-}-]   <- same marks; drawn: same marks
- e2    |[-}-]   <- against difft: same marks; drawn: same marks
- jj    |
- difft |   <- same marks; drawn: same marks
- e2    |   <- against difft: same marks; drawn: same marks
  ctx   |fn second() -> u32 {
  ctx   |    first() + 1
  ctx   |}
@@ hunk 2 @@
  ctx   |fn third() -> u32 {
  ctx   |    second() + 1
  ctx   |}
+ jj    |
+ difft |   <- same marks; drawn: same marks
+ e2    |   <- against difft: same marks; drawn: same marks
+ jj    |{+fn first() -> u32 {+}
+ difft |{+fn+} {+first()+} {+->+} {+u32+} {+{+}   <- same marks; drawn: same marks
+ e2    |{+fn first() -> u32 {+}   <- against difft: same marks; drawn: same marks
+ jj    |{+    1+}
+ difft |    {+1+}   <- same marks; drawn: same marks
+ e2    |{+    1+}   <- against difft: same marks; drawn: same marks
+ jj    |{+}+}
+ difft |{+}+}   <- same marks; drawn: same marks
+ e2    |{+}+}   <- against difft: same marks; drawn: same marks
```

Marked non-whitespace bytes on changed lines: jj 34, difft 34 — both mark the same amount; same marks on 8 of 8 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 8 of 8.
E2: 34 marked non-whitespace bytes; the same marks as difft on 8 of 8 changed line(s), drawn the same on 8 of 8.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### nesting (.rs)

jj: 1 hunk(s), 8 changed line(s), 0.0 ms in-process, E2 0.1 ms more · difft: language `Rust`, status `changed`, 43.2 ms wall

```text
@@ hunk 1 @@
  ctx   |fn update(state: &mut State, event: Event) {
- jj    |    state.apply(event);
- difft |    state.apply(event);   <- same marks; drawn: same marks
- e2    |    state.apply(event);   <- against difft: same marks; drawn: same marks
- jj    |    state.save();
- difft |    state.save();   <- same marks; drawn: same marks
- e2    |    state.save();   <- against difft: same marks; drawn: same marks
- jj    |    log(state.summary());
- difft |    log(state.summary());   <- same marks; drawn: same marks
- e2    |    log(state.summary());   <- against difft: same marks; drawn: same marks
+ jj    |    {+if event.is_relevant() {+}
+ difft |    {+if+} {+event.is_relevant()+} {+{+}   <- same marks; drawn: same marks
+ e2    |{+    if event.is_relevant() {+}   <- against difft: same marks; drawn: same marks
+ jj    |{+        +}state.apply(event);
+ difft |        state.apply(event);   <- same marks; drawn: difft marks fewer bytes
+ e2    |    {+    +}state.apply(event);   <- against difft: same marks; drawn: difft marks fewer bytes
+ jj    |    {+    +}state.save();
+ difft |        state.save();   <- same marks; drawn: difft marks fewer bytes
+ e2    |    {+    +}state.save();   <- against difft: same marks; drawn: difft marks fewer bytes
+ jj    |    {+}+}
+ difft |    {+}+}   <- same marks; drawn: same marks
+ e2    |{+    }+}   <- against difft: same marks; drawn: same marks
+ jj    |{+    +}log({+redact(+}state.summary()){+)+};
+ difft |    log({+redact(+}state.summary(){+)+});   <- different bytes; drawn: different bytes
+ e2    |    log({+redact(+}state.summary()){+)+};   <- against difft: different bytes; drawn: different bytes
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 31, difft 31 — both mark the same amount; same marks on 7 of 8 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 5 of 8.
E2: 31 marked non-whitespace bytes; the same marks as difft on 7 of 8 changed line(s), drawn the same on 5 of 8.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### reformat (.rs)

jj: 1 hunk(s), 6 changed line(s), 0.0 ms in-process, E2 0.1 ms more · difft: language `Rust`, status `unchanged`, 44.7 ms wall

```text
@@ hunk 1 @@
  ctx   |fn main() {
- jj    |    let result = compute(first_argument, second_argument, third_argument);
- difft |    let result = compute(first_argument, second_argument, third_argument);   <- same marks; drawn: same marks
- e2    |    let result = compute(first_argument, second_argument, third_argument);   <- against difft: same marks; drawn: same marks
+ jj    |    let result = compute(
+ difft |    let result = compute(   <- same marks; drawn: same marks
+ e2    |    let result = compute(   <- against difft: same marks; drawn: same marks
+ jj    |{+        +}first_argument,
+ difft |        first_argument,   <- same marks; drawn: difft marks fewer bytes
+ e2    |{+        +}first_argument,   <- against difft: same marks; drawn: difft marks fewer bytes
+ jj    |{+       +} second_argument,
+ difft |        second_argument,   <- same marks; drawn: difft marks fewer bytes
+ e2    |{+       +} second_argument,   <- against difft: same marks; drawn: difft marks fewer bytes
+ jj    |{+       +} third_argument{+,+}
+ difft |        third_argument,   <- difft marks fewer bytes; drawn: difft marks fewer bytes
+ e2    |{+       +} third_argument{+,+}   <- against difft: difft marks fewer bytes; drawn: difft marks fewer bytes
+ jj    |{+    +});
+ difft |    );   <- same marks; drawn: difft marks fewer bytes
+ e2    |{+    +});   <- against difft: same marks; drawn: difft marks fewer bytes
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 1, difft 0 — difft marks less; same marks on 5 of 6 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 2 of 6.
E2: 1 marked non-whitespace bytes; the same marks as difft on 5 of 6 changed line(s), drawn the same on 2 of 6.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### reorder-dart (.dart)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process, E2 0.0 ms more · difft: language `Dart`, status `changed`, 54.7 ms wall

```text
@@ hunk 1 @@
  ctx   |void main() {
- jj    |  final total = f([-a, -]b);
- difft |  final total = f([-a,-] b);   <- same marks; drawn: difft marks fewer bytes
- e2    |  final total = f([-a, -]b);   <- against difft: same marks; drawn: difft marks fewer bytes
+ jj    |  final total = f(b{+, a+});
+ difft |  final total = f(b{+,+} {+a+});   <- same marks; drawn: difft marks fewer bytes
+ e2    |  final total = f(b{+, a+});   <- against difft: same marks; drawn: difft marks fewer bytes
  ctx   |  print(total);
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 4, difft 4 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 0 of 2.
E2: 4 marked non-whitespace bytes; the same marks as difft on 2 of 2 changed line(s), drawn the same on 0 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### reorder-rust (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process, E2 0.0 ms more · difft: language `Rust`, status `changed`, 44.1 ms wall

```text
@@ hunk 1 @@
  ctx   |fn main() {
- jj    |    let total = f([-a, -]b);
- difft |    let total = f([-a,-] b);   <- same marks; drawn: difft marks fewer bytes
- e2    |    let total = f([-a, -]b);   <- against difft: same marks; drawn: difft marks fewer bytes
+ jj    |    let total = f(b{+, a+});
+ difft |    let total = f(b{+,+} {+a+});   <- same marks; drawn: difft marks fewer bytes
+ e2    |    let total = f(b{+, a+});   <- against difft: same marks; drawn: difft marks fewer bytes
  ctx   |    println!("{total}");
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 4, difft 4 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 0 of 2.
E2: 4 marked non-whitespace bytes; the same marks as difft on 2 of 2 changed line(s), drawn the same on 0 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### stepper (.dart)

jj: 3 hunk(s), 9 changed line(s), 0.1 ms in-process, E2 0.1 ms more · difft: language `Dart`, status `changed`, 50.0 ms wall

```text
@@ hunk 1 @@
  ctx   |
  ctx   |  @override
  ctx   |  Widget build(BuildContext context) => FilledButton(
- jj    |    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),
- difft |    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),   <- same marks; drawn: same marks
- e2    |    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),   <- against difft: same marks; drawn: same marks
+ jj    |    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),
+ difft |    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),   <- same marks; drawn: same marks
+ e2    |    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),   <- against difft: same marks; drawn: same marks
  ctx   |  );
  ctx   |}
  ctx   |
@@ hunk 2 @@
  ctx   |
  ctx   |  @override
  ctx   |  Widget build(BuildContext context) => Row(children: [
- jj    |    Expanded(child: _Line(color: isFirst ? null : lineColor)),
- difft |    Expanded(child: _Line(color: isFirst ? null : lineColor)),   <- same marks; drawn: same marks
- e2    |    Expanded(child: _Line(color: isFirst ? null : lineColor)),   <- against difft: same marks; drawn: same marks
+ jj    |    Expanded(
+ difft |    Expanded(   <- same marks; drawn: same marks
+ e2    |    Expanded(   <- against difft: same marks; drawn: same marks
+ jj    |{+      +}child: _Line(color: isFirst ? null : lineColor){+,+}
+ difft |      child: _Line(color: isFirst ? null : lineColor){+,+}   <- same marks; drawn: difft marks fewer bytes
+ e2    |{+      +}child: _Line(color: isFirst ? null : lineColor){+,+}   <- against difft: same marks; drawn: difft marks fewer bytes
+ jj    |{+    +}),
+ difft |    ),   <- same marks; drawn: difft marks fewer bytes
+ e2    |{+    +}),   <- against difft: same marks; drawn: difft marks fewer bytes
  ctx   |    DecoratedBox(
  ctx   |      decoration: BoxDecoration(color: lineColor),
  ctx   |      child: const SizedBox(width: 8, height: 8),
@@ hunk 3 @@
  ctx   |}
  ctx   |
  ctx   |Widget stepLabel(Widget label) => Padding(
- jj    |  padding: Spacing.[-spacing8-],
- difft |  padding: Spacing.[-spacing8-],   <- same marks; drawn: same marks
- e2    |  padding: Spacing.[-spacing8-],   <- against difft: same marks; drawn: same marks
+ jj    |  {+// Small side padding.+}
+ difft |  {+// Small side padding.+}   <- same marks; drawn: same marks
+ e2    |{+  // Small side padding.+}   <- against difft: same marks; drawn: same marks
+ jj    |{+  +}padding: Spacing.{+spacing2+},
+ difft |  padding: Spacing.{+spacing2+},   <- same marks; drawn: difft marks fewer bytes
+ e2    |  padding: Spacing.{+spacing2+},   <- against difft: same marks; drawn: same marks
  ctx   |  child: label,
  ctx   |);
```

Marked non-whitespace bytes on changed lines: jj 66, difft 66 — both mark the same amount; same marks on 9 of 9 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 6 of 9.
E2: 66 marked non-whitespace bytes; the same marks as difft on 9 of 9 changed line(s), drawn the same on 7 of 9.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### widget-test-rename (.dart)

jj: 1 hunk(s), 19 changed line(s), 0.1 ms in-process, E2 0.1 ms more · difft: language `Dart`, status `changed`, 52.7 ms wall

```text
@@ hunk 1 @@
  ctx   |    });
  ctx   |  }
  ctx   |
- jj    |  // [-Tablet-] [-only: the wide test font overflows-] [-the-] [-compact-] app bar[-,-] [-which-] [-holds-] [-the-] [-buttons-] on a phone[-.-]
- difft |  // [-Tablet-] [-only: the wide test font overflows-] [-the-] [-compact-] app bar[-,-] [-which-] [-holds-] [-the-] [-buttons-] on a phone[-.-]   <- same marks; drawn: same marks
- 1st   |  [-// Tablet only: the wide test font overflows the compact app bar, which holds the buttons on a phone.-]   <- the first rule: difft marks more bytes
- d(e2) |  [-// Tablet only: the wide test font overflows the compact app bar, which holds the buttons on a phone.-]   <- difft with E2's marks inside comments and strings
- e2    |[-  // Tablet only: the wide test font overflows the compact app bar, which holds the buttons on a phone.-]   <- against difft: same marks; drawn: same marks
- jj    |  [-// The-] phone [-layout-] [-is-] [-checked-] on a [-device.-]
- difft |  [-// The-] phone [-layout-] [-is-] [-checked-] on a [-device.-]   <- same marks; drawn: same marks
- 1st   |  [-// The phone layout is checked on a device.-]   <- the first rule: difft marks more bytes
- d(e2) |  [-// The phone layout is checked on a device.-]   <- difft with E2's marks inside comments and strings
- e2    |[-  // The phone layout is checked on a device.-]   <- against difft: same marks; drawn: same marks
- jj    |[-  testWidgets('shows Funktion speichern instead of Weiter on the last step-]', (tester) async {
- difft |  testWidgets([-'shows Funktion speichern instead of Weiter on the last step-]', (tester) async {   <- difft marks fewer bytes; drawn: difft marks fewer bytes
- 1st   |  testWidgets([-'shows Funktion speichern instead of Weiter on the last step'-], (tester) async {   <- the first rule: different bytes
- d(e2) |  testWidgets('shows Funktion speichern instead of Weiter on the last step', (tester) async {   <- difft with E2's marks inside comments and strings
- e2    |  testWidgets('shows Funktion speichern instead of Weiter on the last step', (tester) async {   <- against difft: same marks; drawn: same marks
+ jj    |  // {+The+} {+tablet shows the long label.+} {+The+} {+phone+} app bar{+ has little room and shows the short one.+}
+ difft |  // {+The+} {+tablet shows the long label.+} {+The+} {+phone+} app bar{+ has little room and shows the short one.+}   <- same marks; drawn: same marks
+ 1st   |  {+// The tablet shows the long label. The phone app bar has little room and shows the short one.+}   <- the first rule: difft marks more bytes
+ d(e2) |  {+// The tablet shows the long label. The phone app bar has little room and shows the short one.+}   <- difft with E2's marks inside comments and strings
+ e2    |{+  // The tablet shows the long label. The phone app bar has little room and shows the short one.+}   <- against difft: same marks; drawn: same marks
+ jj    |{+  testWidgets('shows Speichern instead of Weiter+} {+on+} {+the+} {+last+} {+step+} on a phone{+', (tester) async {+}
+ difft |  {+testWidgets('shows Speichern instead of Weiter+} {+on+} {+the+} {+last+} {+step+} on a phone{+',+} {+(tester)+} {+async+} {+{+}   <- same marks; drawn: difft marks fewer bytes
+ 1st   |  {+testWidgets('shows Speichern instead of Weiter on the last step on a phone',+} {+(tester)+} {+async+} {+{+}   <- the first rule: difft marks more bytes
+ d(e2) |  {+testWidgets('shows Speichern instead of Weiter on the last step on a phone',+} {+(tester)+} {+async+} {+{+}   <- difft with E2's marks inside comments and strings
+ e2    |{+  testWidgets('shows Speichern instead of Weiter on the last step on a phone', (tester) async {+}   <- against difft: same marks; drawn: same marks
+ jj    |  {+  await openWizard(tester, size:+} phone{+);+}
+ difft |    {+await+} {+openWizard(tester,+} {+size:+} {+phone);+}   <- difft marks more bytes; drawn: difft marks fewer bytes
+ e2    |{+    await openWizard(tester, size: phone);+}   <- against difft: same marks; drawn: same marks
+ jj    |{+    await fillGeneralStep(tester);+}
+ difft |    {+await+} {+fillGeneralStep(tester);+}   <- same marks; drawn: same marks
+ e2    |{+    await fillGeneralStep(tester);+}   <- against difft: same marks; drawn: same marks
+ jj    |
+ difft |   <- same marks; drawn: same marks
+ e2    |   <- against difft: same marks; drawn: same marks
+ jj    |{+    for (var i = 0; i < 3; i++) {+}
+ difft |    {+for+} {+(var+} {+i+} {+=+} {+0;+} {+i+} {+<+} {+3;+} {+i++)+} {+{+}   <- same marks; drawn: same marks
+ e2    |{+    for (var i = 0; i < 3; i++) {+}   <- against difft: same marks; drawn: same marks
+ jj    |{+      await tester.tap(withIdentifier(SemanticsIdentifiers.functionWizard_next));+}
+ difft |      {+await+} {+tester.tap(withIdentifier(SemanticsIdentifiers.functionWizard_next));+}   <- same marks; drawn: same marks
+ e2    |{+      await tester.tap(withIdentifier(SemanticsIdentifiers.functionWizard_next));+}   <- against difft: same marks; drawn: same marks
+ jj    |{+      await tester.pumpAndSettle();+}
+ difft |      {+await+} {+tester.pumpAndSettle();+}   <- same marks; drawn: same marks
+ e2    |{+      await tester.pumpAndSettle();+}   <- against difft: same marks; drawn: same marks
+ jj    |{+    }+}
+ difft |    {+}+}   <- same marks; drawn: same marks
+ e2    |{+    }+}   <- against difft: same marks; drawn: same marks
+ jj    |
+ difft |   <- same marks; drawn: same marks
+ e2    |   <- against difft: same marks; drawn: same marks
+ jj    |{+    expect(find.text('Speichern'), findsWidgets);+}
+ difft |    {+expect(find.text('Speichern'),+} {+findsWidgets);+}   <- same marks; drawn: same marks
+ e2    |{+    expect(find.text('Speichern'), findsWidgets);+}   <- against difft: same marks; drawn: same marks
+ jj    |{+    expect(find.text('Funktion speichern'), findsNothing);+}
+ difft |    {+expect(find.text('Funktion speichern'),+} {+findsNothing);+}   <- same marks; drawn: same marks
+ e2    |{+    expect(find.text('Funktion speichern'), findsNothing);+}   <- against difft: same marks; drawn: same marks
+ jj    |{+    expect(find.text('Weiter'), findsNothing);+}
+ difft |    {+expect(find.text('Weiter'),+} {+findsNothing);+}   <- same marks; drawn: same marks
+ e2    |{+    expect(find.text('Weiter'), findsNothing);+}   <- against difft: same marks; drawn: same marks
+ jj    |{+  });+}
+ difft |  {+});+}   <- same marks; drawn: same marks
+ e2    |{+  });+}   <- against difft: same marks; drawn: same marks
+ jj    |
+ difft |   <- same marks; drawn: same marks
+ e2    |   <- against difft: same marks; drawn: same marks
+ jj    |{+  testWidgets('shows Funktion speichern instead of Weiter on+} {+the+} {+last+} {+step+} on a {+tablet+}', (tester) async {
+ difft |  testWidgets({+'shows Funktion speichern instead of Weiter on+} {+the+} {+last+} {+step+} on a {+tablet+}', (tester) async {   <- difft marks fewer bytes; drawn: difft marks fewer bytes
+ 1st   |  testWidgets({+'shows Funktion speichern instead of Weiter on the last step+} {+on+} {+a+} {+tablet'+}, (tester) async {   <- the first rule: different bytes
+ d(e2) |  testWidgets('shows Funktion speichern instead of Weiter on the last step {+on+} {+a+} {+tablet+}', (tester) async {   <- difft with E2's marks inside comments and strings
+ e2    |  testWidgets('shows Funktion speichern instead of Weiter on the last step{+ on a tablet+}', (tester) async {   <- against difft: same marks; drawn: difft marks fewer bytes
  ctx   |    await openWizard(tester, size: tablet);
  ctx   |    await fillGeneralStep(tester);
  ctx   |  });
```

Marked non-whitespace bytes on changed lines: jj 687, difft 668 — difft marks less; same marks on 16 of 19 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 15 of 19.
E2: 609 marked non-whitespace bytes; the same marks as difft on 19 of 19 changed line(s), drawn the same on 18 of 19.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### edge-cr-tab (.rs)

jj: 1 hunk(s), 2 changed line(s), 0.0 ms in-process, E2 0.0 ms more · difft: language `Rust`, status `changed`, 43.4 ms wall

```text
@@ hunk 1 @@
  ctx   |fn main() {
- jj    |\tlet s = "a\rb"; f([-x-]);
- difft |\tlet s = "a\rb"; f([-x-]);   <- same marks; drawn: same marks
- e2    |\tlet s = "a\rb"; f([-x-]);   <- against difft: same marks; drawn: same marks
+ jj    |\tlet s = "a\rb"; f({+y+});
+ difft |\tlet s = "a\rb"; f({+y+});   <- same marks; drawn: same marks
+ e2    |\tlet s = "a\rb"; f({+y+});   <- against difft: same marks; drawn: same marks
  ctx   |}
```

Marked non-whitespace bytes on changed lines: jj 2, difft 2 — both mark the same amount; same marks on 2 of 2 changed line(s); drawn the same by 10.32 (whitespace fills counted) on 2 of 2.
E2: 2 marked non-whitespace bytes; the same marks as difft on 2 of 2 changed line(s), drawn the same on 2 of 2.
difft marks the mapping drops: 0 on jj context lines, 0 outside jj's hunks. Spans moved by a carriage return: 2. Content mismatches: 0.

### `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009 --jobs 8` (E2)

difft: Difftastic 0.72.0

#### Corpus

- Revision `5ba5f5d43b21d45c24c099092384f9d9610fe009`; 200 non-merge commits that modify a `.rs` or `.dart` file, 2026-10-23 to 2026-11-12.
- Scope: files a commit modifies (status `M`, no rename detection); added, deleted and renamed files are not diffed.
- 2706 modified `.rs` / `.dart` files: 170 generated and 0 binary skipped, 2536 diffed (Dart 1510, Rust 1026).
- difft fell back on 56 files: graph limit 56. It reported `unchanged` (no syntactic change) on 0 files.
- Rows per file: `out/history.tsv`.
- difft ran on 8 threads, so its times are not reported; jj's and E2's ran in-process, one file at a time, after difft.

#### Changed lines by class (corrected mapping; marked non-whitespace bytes)

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 53463 | 38077 | 91540 | 79.2 % |
| difft marks fewer bytes | 1660 | 1046 | 2706 | 2.3 % |
| difft marks more bytes | 740 | 471 | 1211 | 1.0 % |
| different bytes | 351 | 487 | 838 | 0.7 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

#### As Story 10.32 draws them (drawn bytes, whitespace fills included; no strong marks on a line without visible unmarked text)

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 50125 | 35358 | 85483 | 74.0 % |
| difft marks fewer bytes | 4843 | 3743 | 8586 | 7.4 % |
| difft marks more bytes | 735 | 388 | 1123 | 1.0 % |
| different bytes | 511 | 592 | 1103 | 1.0 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

#### The first mapping rule (every novel span, whole comments and strings included)

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 50244 | 33706 | 83950 | 72.7 % |
| difft marks fewer bytes | 1603 | 1022 | 2625 | 2.3 % |
| difft marks more bytes | 3959 | 4842 | 8801 | 7.6 % |
| different bytes | 408 | 511 | 919 | 0.8 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

#### E2 against difft (E2's marks in jj's place, inside comments and strings too; marked non-whitespace bytes)

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 53236 | 37911 | 91147 | 78.9 % |
| difft marks fewer bytes | 2293 | 1471 | 3764 | 3.3 % |
| difft marks more bytes | 461 | 301 | 762 | 0.7 % |
| different bytes | 224 | 398 | 622 | 0.5 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

#### E2 against difft, as Story 10.32 draws them

| class | Dart | Rust | all | share |
|---|---:|---:|---:|---:|
| same marks | 50438 | 35525 | 85963 | 74.4 % |
| difft marks fewer bytes | 4004 | 3320 | 7324 | 6.3 % |
| difft marks more bytes | 1415 | 753 | 2168 | 1.9 % |
| different bytes | 357 | 483 | 840 | 0.7 % |
| difft fell back | 16738 | 2482 | 19220 | 16.6 % |
| changed lines | 72952 | 42563 | 115515 | |

Files where the drawn marks would change on at least one line: 1454 of 2536.

Changed lines jj marks and difft leaves without marks (difft calls them unchanged): 1233; lines difft marks and jj leaves without marks: 219.

difft marks the mapping drops (files without a fallback): 1626 on jj context lines, 882 outside jj's hunks. Spans moved by a carriage return: 0. Content mismatches: 0.

#### Today's gap to difft and E2's (96295 changed lines without a difft fallback)

| | word marks | drawn |
|---|---:|---:|
| today's marks differ from difft's | 4755 (4.9 %) | 10812 (11.2 %) |
| E2's marks differ from difft's | 5148 (5.3 %) | 10332 (10.7 %) |
| today's differ, E2's match difft's | 1124 (1.2 %) | 1903 (2.0 %) |
| today's match difft's, E2's differ | 1517 (1.6 %) | 1423 (1.5 %) |
| net change of today's gap | -8.3 % | 4.4 % |

Of the 5148 lines whose E2 word marks differ from difft's, E2 marks 3189 whole (unpaired, or their pair kept none of their ink).

#### E2 against today (115515 changed lines; the class says what E2 marks compared with today)

| class | word marks | share | drawn | share |
|---|---:|---:|---:|---:|
| same marks | 106454 | 92.2 % | 106097 | 91.8 % |
| E2 marks fewer bytes | 2103 | 1.8 % | 6276 | 5.4 % |
| E2 marks more bytes | 5772 | 5.0 % | 1778 | 1.5 % |
| different bytes | 1186 | 1.0 % | 1364 | 1.2 % |

Changed blocks with removed and added lines: 6431. Files where E2's per-file budget (262144 bytes) ran out, so some block keeps today's marks: 9 of 2536 (packages/zanshin_core/lib/src/graph_layout/router.dart@e2284b7a, packages/zanshin_core/test/graph_layout/router_test.dart@e2284b7a, packages/zanshin_core/test/graph_layout/engine_test.dart@2459cc42, packages/zanshin_core/test/graph_layout/invariants.dart@2459cc42, app/test/features/graph/graph_view_model_test.dart@4d32de6a, app/lib/src/features/graph/graph_canvas.dart@1d6e63dd, app/widgetbook/folders/graph.dart@5d5548c0, crates/zanshin-jj/tests/it/select_tree.rs@b08ea227, crates/zanshin-jj/src/bookmarks.rs@a23ba389).

#### Time per file

| | jj Dart | E2 Dart | jj Rust | E2 Rust |
|---|---:|---:|---:|---:|
| median | 0.1 ms | 0.0 ms | 0.2 ms | 0.1 ms |
| p90 | 0.5 ms | 0.5 ms | 0.7 ms | 0.5 ms |
| p99 | 1.3 ms | 3.0 ms | 1.5 ms | 3.4 ms |
| max | 3.4 ms | 15.0 ms | 2.9 ms | 13.1 ms |
| sum | 354.3 ms | 366.5 ms | 346.1 ms | 272.8 ms |

jj: jj-lib's hunks and today's marks; E2: its line pairing alone, on top of jj. Both in-process, inputs in memory, one file at a time.

difft peak memory per file (maximum resident set size): median 20.8 MB, p90 129.7 MB, p99 936.0 MB, max 986.4 MB.


Fallback files: 56, of 13112 to 292563 bytes (right side); difft peaked at 858.1–986.4 MB.

#### Examples (the lines where today's marks and difft's differ most)

##### difft marks fewer bytes

```text
app/test/app/app_window_coordinator_test.dart@fcc1b4d9:+87
  jj    |    {+windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);+}
  difft |    windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);
app/test/app/app_window_coordinator_test.dart@fcc1b4d9:-87
  jj    |[-    windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);-]
  difft |    windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);
crates/zanshin-jj/src/squash_split.rs@3ee3f297:+635
  jj    |{+    let use_move_flags = options.onto.is_some() || options.insert_after.is_some() || options.insert_before.is_some();+}
  difft |    let use_move_flags = options.onto.is_some() || options.insert_after.is_some() || options.insert_before.is_some();
packages/zanshin_core/test/graph_layout/router_test.dart@2459cc42:+224
  jj    |{+    out.add((name: name, grid: GraphGridView.fromBytes(computeGraphGrid(input, mode: mode)), parentCounts: counts));+}
  difft |    out.add((name: {+name+}, grid: GraphGridView.fromBytes(computeGraphGrid(input, mode: mode)), parentCounts: counts));
app/test/features/graph/layout_invariants_test.dart@e2284b7a:+192
  jj    |{+      points: Float64List.fromList(<double>[0, 0, 0, -50, 100, -50, 100, -100, 50, 0, 50, -50, 150, -50, 150, -100]),+}
  difft |      points: Float64List.fromList(<double>[0, 0, 0, -50, 100, -50, 100, -100, 50, 0, 50, -50, 150, -50, 150, -100]),
```

##### difft marks more bytes

```text
app/lib/src/features/graph/graph_canvas.dart@c4579635:+334
  jj    |{+        +}!identical(oldWidget.transition, transition) && transition != null && identical(transition.to, widget.layout){+;+}
  difft |        {+!identical(oldWidget.transition,+} {+transition)+} {+&&+} {+transition+} {+!=+} {+null+} {+&&+} {+identical(transition.to,+} {+widget.layout);+}
app/test/features/graph/layout_invariants_test.dart@e2284b7a:-202
  jj    |      final RouteReport sameSlot = [-check-](Int32List.fromList(<int>[0, 0]), Int32List.fromList(<int>[0, 1]));
  difft |      [-final-] [-RouteReport-] [-sameSlot-] [-=-] [-check(Int32List.fromList(<int>[0,-] [-0]),-] [-Int32List.fromList(<int>[0,-] [-1]));-]
app/lib/src/features/home/home_page.dart@0d7811d4:+100
  jj    |    case ProjectOpenFailed() || ProjectNotARepo(kind: RepoKind.pathNotFound) when windows != null:
  difft |    {+case+} {+ProjectOpenFailed()+} {+||+} {+ProjectNotARepo(kind:+} {+RepoKind.pathNotFound)+} {+when+} {+windows+} {+!=+} {+null:+}
app/lib/src/features/home/home_page.dart@0d7811d4:-99
  jj    |    [-  -]case ProjectOpenFailed() || ProjectNotARepo(kind: RepoKind.pathNotFound) when windows != null:
  difft |      [-case-] [-ProjectOpenFailed()-] [-||-] [-ProjectNotARepo(kind:-] [-RepoKind.pathNotFound)-] [-when-] [-windows-] [-!=-] [-null:-]
app/lib/src/features/home/home_page.dart@995e2040:+217
  jj    |            toastSpan({+strings+}.toastOpened(toastSlot(0)), <InlineSpan>[TextSpan(text: report.name)]),
  difft |            {+toastSpan(strings.toastOpened(toastSlot(0)),+} {+<InlineSpan>[TextSpan(text:+} {+report.name)]),+}
```

##### different bytes

```text
packages/zanshin_core/lib/src/ffi/precondition.dart@995e2040:-167
  jj    |({List<ZanshinWarning> warnings, Precondition? precondition})[- decodeCreationReport(Uint8List bytes) =>-]
  difft |[-({List<ZanshinWarning>-] [-warnings,-] [-Precondition?-] [-precondition})-] decodeCreationReport(Uint8List bytes) =>
app/lib/src/features/graph/graph_canvas.dart@c4579635:-332
  jj    |    [-if-] [-(-]!identical(oldWidget.transition, transition) && transition != null && identical(transition.to, widget.layout)) {
  difft |    if ([-!identical(oldWidget.transition,-] [-transition)-] && transition [-!=-] [-null-] [-&&-] [-identical(transition-].[-to,-] [-widget.layout)-]) {
app/lib/src/features/graph/graph_stack_card.dart@5c607633:-559
  jj    |[-        if (authorsW <-] _paragraph(TextSpan(text: [-authorsText!-].characters.first, style: meta)).width) {
  difft |        if (authorsW < [-_paragraph(TextSpan-]([-text:-] authorsText![-.characters.first,-] [-style:-] [-meta-])[-).width-]) {
app/lib/src/features/projects/worker_project_repos.dart@5d5548c0:-88
  jj    |[-      _worker.-]events.where((event) => event is OpHeadsChangedEvent[- && event.handleId == handle.handleId-]).map((_) {});
  difft |      _worker.events.where((event) => [-event-] [-is-] [-OpHeadsChangedEvent-] [-&&-] event.handleId == handle.handleId)[-.map((_)-] [-{})-];
crates/zanshin-jj/src/bookmark_ops.rs@65c3be24:-120
  jj    |        StringExpression::exact([-jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO-].as_str())
  difft |        [-StringExpression::exact-](jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO[-.as_str()-])
```

#### E2 examples: where E2's marks differ from difft's and today's matched (most differing first)

`difft` is difft's marks with E2's word marks inside comments and strings.

##### difft marks fewer bytes (against E2)

```text
crates/zanshin-ffi/src/repo.rs@aeefd82f:+31
  jj    |{+   +} JJ_DESTINATION_NOT_EMPTY, JJ_DETECT_FAILED, JJ_GIT_REPO_EXISTS, JJ_GIT_WORKTREE_FAILED, JJ_IMMUTABLE,
  e2    |{+   +} JJ_DESTINATION_NOT_EMPTY, JJ_DETECT_FAILED,{+ JJ_GIT_REPO_EXISTS, JJ_GIT_WORKTREE_FAILED, JJ_IMMUTABLE,+}
  difft |    JJ_DESTINATION_NOT_EMPTY, JJ_DETECT_FAILED, JJ_GIT_REPO_EXISTS, JJ_GIT_WORKTREE_FAILED, JJ_IMMUTABLE,
crates/zanshin-ffi/src/repo.rs@aeefd82f:-31
  jj    |[-   -] JJ_GIT_REPO_EXISTS, JJ_GIT_WORKTREE_FAILED, JJ_IMMUTABLE, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_NETWORK_ERROR,
  e2    |    [-JJ_GIT_REPO_EXISTS, JJ_GIT_WORKTREE_FAILED, JJ_IMMUTABLE, -]JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_NETWORK_ERROR,
  difft |    JJ_GIT_REPO_EXISTS, JJ_GIT_WORKTREE_FAILED, JJ_IMMUTABLE, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR, JJ_NETWORK_ERROR,
app/lib/src/features/graph/graph_search_controller.dart@b6e20939:+166
  jj    |  void showDefault() {+=>+} {+show+}(GraphShownView.defaultSearch);
  e2    |{+  void showDefault() => show(GraphShownView.defaultSearch);+}
  difft |  void showDefault() {+=>+} {+show+}(GraphShownView.defaultSearch);
app/lib/src/features/graph/graph_view_model.dart@4d32de6a:+404
  jj    |  Future<GraphActionResult> run(GraphAction action) {+=> _execute(action);+}
  e2    |{+  Future<GraphActionResult> run(GraphAction action) => _execute(action);+}
  difft |  Future<GraphActionResult> run(GraphAction action) {+=>+} {+_execute(action);+}
crates/zanshin-ffi/tests/it/bookmark_ops_ffi.rs@65c3be24:+27
  jj    |{+    +}zanshin_bookmark_move, zanshin_bookmark_rename,{+ zanshin_bookmark_set, zanshin_bookmark_track,+}
  e2    |{+    zanshin_bookmark_move, zanshin_bookmark_rename, zanshin_bookmark_set, zanshin_bookmark_track,+}
  difft |    zanshin_bookmark_move, zanshin_bookmark_rename, {+zanshin_bookmark_set,+} {+zanshin_bookmark_track,+}
```

##### difft marks more bytes (against E2)

```text
app/lib/src/features/graph/graph_view.dart@8b364e7a:+459
  jj    |{+      final Offset pointer = drag.dropPoint ?? drag.pointer;+}
  e2    |      final Offset {+pointer+} = drag.dropPoint ?? drag.pointer;
  difft |      {+final+} {+Offset+} {+pointer+} {+=+} {+drag.dropPoint+} {+??+} {+drag.pointer;+}
crates/zanshin-jj/src/change.rs@0e180acb:-186
  jj    |[-        .ok_or_else(|| ChangeError::NotFound { id: id.0.clone() })?; // absent id-]
  e2    |        [-.ok_or_else-]([-||-] ChangeError::NotFound { id: id.0.clone() }[-)?; // absent id-]
  difft |        [-.ok_or_else(||-] [-ChangeError::NotFound-] [-{-] [-id:-] [-id.0.clone()-] [-})?;-] [-// absent id-]
crates/zanshin-jj/tests/it/workspace_ops.rs@024e76c8:+324
  jj    |{+    let (fx, mut repo) = two_workspaces(false, "");+}
  e2    |    let (fx, mut repo) = two_workspaces(false, "");
  difft |    {+let+} {+(fx,+} {+mut+} {+repo)+} {+=+} {+two_workspaces(false,+} ""{+);+}
app/test/features/graph/revset_configs/revset_configs_window_test.dart@4ec4b049:+507
  jj    |{+    expect(rig.state.draft.selected, 'c2');+}
  e2    |    expect(rig.state.draft.selected, '{+c2+}');
  difft |    {+expect(rig.state.draft.selected,+} '{+c2+}'{+);+}
app/lib/src/features/graph/graph_view_model.dart@4d32de6a:+407
  jj    |{+  Future<GraphActionResult> undoLast() async {+}
  e2    |  Future<GraphActionResult> {+undoLast+}() async {
  difft |  {+Future<GraphActionResult>+} {+undoLast()+} {+async+} {+{+}
```

##### different bytes (against E2)

```text
crates/zanshin-jj/src/config.rs@5e58ec3d:-1017
  jj    |    let mut config = [-load_for_workspace-]([-repo.workspace-]())?;
  e2    |    let [-mut-] [-config -]= [-load_for_workspace(-]repo.workspace()[-)?-];
  difft |    let mut config = [-load_for_workspace-]([-repo.workspace-]())?;
packages/zanshin_core/lib/src/graph_layout/stacks.dart@2459cc42:+395
  jj    |      final int newest = _newest({+stackRun[s]+});
  e2    |      final int {+newest+} = {+_newest(+}stackRun[s]{+)+};
  difft |      final int newest = _newest({+stackRun[s]+});
app/lib/src/features/home/home_page.dart@995e2040:-206
  jj    |            [-ZsColors.of(context)-],
  e2    |            ZsColors.of(context)[-,-]
  difft |            [-ZsColors.of(context)-],
crates/zanshin-ffi/src/config.rs@9629c9ef:-910
  jj    |        let row = [-envelope(&gc)-]
  e2    |        let [-row-] = envelope(&gc)
  difft |        let row = [-envelope(&gc)-]
app/lib/src/features/graph/recorded_graph_layout.dart@873274ce:-157
  jj    |      cols[i] = cell['col'][-!-] as int;
  e2    |      cols[[-i-]] = cell['col']! as int;
  difft |      cols[i] = cell['col'][-!-] as int;
```

##### Where today's marks differ from difft's and E2's match

```text
packages/zanshin_core/lib/src/ffi/precondition.dart@995e2040:-167
  jj    |({List<ZanshinWarning> warnings, Precondition? precondition})[- decodeCreationReport(Uint8List bytes) =>-]
  e2    |[-({List<ZanshinWarning> warnings, Precondition? precondition})-] decodeCreationReport(Uint8List bytes) =>
  difft |[-({List<ZanshinWarning>-] [-warnings,-] [-Precondition?-] [-precondition})-] decodeCreationReport(Uint8List bytes) =>
packages/zanshin_core/lib/src/worker/handle.dart@aeefd82f:+1481
  jj    |{+    return _worker.selectTree(_handleId, revision: revision, left: left, files: files, from: from);+}
  e2    |    return _worker.selectTree(_handleId, revision: revision, left: left, files: files{+, from: from+});
  difft |    return _worker.selectTree(_handleId, revision: revision, left: left, files: files{+,+} {+from:+} {+from+});
packages/zanshin_core/test/graph_layout/router_test.dart@cbcd7492:-488
  jj    |[-      expect([_points(g, 0).last.$1, _points(g, 1).last.$1], everyElement(isNot(_cx(0)))-]);
  e2    |      expect([_points([-g-], 0).last.$1, _points([-g-], 1).last.$1], everyElement(isNot(_cx(0))));
  difft |      expect([_points([-g-], 0).last.$1, _points([-g-], 1).last.$1], everyElement(isNot(_cx(0))));
packages/zanshin_core/lib/src/ffi/precondition.dart@995e2040:+168
  jj    |{+CreationReport decodeCreationReport(Uint8List bytes) => decodeCreationReportInternal(bytes);+}
  e2    |{+CreationReport+} decodeCreationReport(Uint8List bytes) => decodeCreationReportInternal(bytes);
  difft |{+CreationReport+} decodeCreationReport(Uint8List bytes) => decodeCreationReportInternal(bytes);
packages/zanshin_core/lib/src/worker/handle.dart@aeefd82f:-1471
  jj    |[-    return _worker.selectTree(_handleId, revision: revision, left: left, files:-] [-files-]);
  e2    |    return _worker.selectTree(_handleId, revision: revision, left: left, files: files);
  difft |    return _worker.selectTree(_handleId, revision: revision, left: left, files: files);
```

### `limits` (E2)

difft: Difftastic 0.72.0

| input | bytes before / after | difft args | difft `language` | difft wall | difft peak RSS | jj changed lines | jj in-process | E2 in-process (more) | E2 budget ran out | jj + E2 process peak RSS |
|---|---:|---|---|---:|---:|---:|---:|---:|---|---:|
| byte-limit | 1108780 / 1108780 | defaults | `Text (1.1 MiB exceeded DFT_BYTE_LIMIT)` | 79.9 ms | 63.3 MB | 2 | 9.8 ms | 0.8 ms | no | 17.3 MB |
|  | 1108780 / 1108780 | `--byte-limit 100000000` | `Rust` | 879.8 ms | 385.3 MB |  | | | |  |
| scattered-changes | 548965 / 548965 | defaults | `Rust` | 1082.5 ms | 324.8 MB | 4000 | 16.5 ms | 23.7 ms | no | 16.2 MB |
|  | 548965 / 548965 | `--graph-limit 300000` | `Rust` | 1087.9 ms | 324.4 MB |  | | | |  |
| graph-limit-statements | 548965 / 548965 | defaults | `Text (exceeded DFT_GRAPH_LIMIT)` | 1490.9 ms | 1074.4 MB | 40000 | 87.6 ms | 0.3 ms | yes | 40.8 MB |
|  | 548965 / 548965 | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 972.5 ms | 328.7 MB |  | | | |  |
| graph-limit-array | 204032 / 204032 | defaults | `Text (exceeded DFT_GRAPH_LIMIT)` | 4228.5 ms | 620.6 MB | 12000 | 12.4 ms | 0.1 ms | yes | 38.7 MB |
|  | 204032 / 204032 | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 4006.8 ms | 204.5 MB |  | | | |  |
|  | 204032 / 204032 | `--graph-limit 6000000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 4605.0 ms | 1099.0 MB |  | | | |  |
| e2-at-cap | 2142 / 2142 | defaults | `Rust` | 112.9 ms | 178.7 MB | 126 | 0.3 ms | 18.0 ms | no | 3.4 MB |
| e2-reformatted-calls | 17684 / 48484 | defaults | `Rust` | 55.8 ms | 26.2 MB | 5040 | 6.2 ms | 21.2 ms | yes | 6.2 MB |
| parse-error-rust | 66 / 83 | defaults | `Text (1 Rust parse error, exceeded DFT_PARSE_ERROR_LIMIT, first at 3:8)` | 35.8 ms | 12.8 MB | 3 | 0.0 ms | 0.0 ms | no | 2.7 MB |
| parse-error-dart | 72 / 76 | defaults | `Text (4 Dart parse errors, exceeded DFT_PARSE_ERROR_LIMIT, first at 1:0)` | 42.7 ms | 10.6 MB | 2 | 0.0 ms | 0.1 ms | no | 2.7 MB |
|  | 72 / 76 | `--parse-error-limit 10` | `Dart` | 38.4 ms | 10.7 MB |  | | | |  |
| missing-node-rust | 27 / 26 | defaults | `Rust` | 39.2 ms | 12.7 MB | 2 | 0.0 ms | 0.0 ms | no | 2.6 MB |
| no-parser-markdown | 32 / 38 | defaults | `Text` | 20.0 ms | 6.0 MB | 2 | 0.0 ms | 0.0 ms | no | 2.6 MB |
| conflict-jj-diff-style | 91 / 323 | defaults | `Text (2 Rust parse errors, exceeded DFT_PARSE_ERROR_LIMIT, first at 2:0)` | 37.0 ms | 12.9 MB | 9 | 0.1 ms | 0.1 ms | no | 2.7 MB |
| conflict-git-style | 91 / 254 | defaults | `Text (1 Rust parse error, exceeded DFT_PARSE_ERROR_LIMIT, first at 2:0)` | 38.3 ms | 12.8 MB | 6 | 0.0 ms | 0.0 ms | no | 2.4 MB |

Median of 3 runs. Peak RSS is `/usr/bin/time -l`'s maximum resident set size; jj's is a process of its own that reads both files and computes today's marks and E2's. E2's time is its line pairing alone, on top of jj's; E2's per-file budget is 262144 bytes (`MAX_PAIRING_WORK`).

Over all difft runs above: span content mismatches 0, spans moved by a carriage return 0.

`e2-at-cap`: one changed block whose one-to-one candidates fill E2's per-file budget (copies of
`values.push(first * second);` become copies of `values.push(second * first);`; every line pair
shares all its tokens, so no bound skips a pair). `e2-reformatted-calls`: 20 changed blocks of 28
one-line calls `f(a0, a1, a2, a3, a4, a5);` each, reformatted to one argument per line (a
reviewer's case, 3.15 s of pairing under the earlier per-block cap): every call line shares all its
tokens with every run of argument lines, so the runs are searched too, and the budget runs out.

The per-input details (the first four changed lines with jj's, a structural build's and E2's marks)
match the research run's above with one `e2` row added; E2's marks equal jj's on every one of them
(`e2-reformatted-calls` included) except `e2-at-cap`:

```text
- jj    |    values.push(first[- * second-]);
- build |    values.push([-first-] * [-second-]);   <- different bytes
- e2    |    values.push([-first * -]second);
```

## Re-run after the follow-up review (2026-11-12, the budget pays for the search's table)

Same machine, same three commands. The follow-up review of Story 5.9's closing run found that the
budget paid only for the word diffs that score candidates. A block whose candidates the bounds all
prune still built its whole table (the shared tokens of every one-to-one pair, then every cell of
the search) for free, so a file of many such blocks grew without limit. Now each searched block
first pays for its one-to-one candidates (`added lines · removed bytes + removed lines · added
bytes`, the same measure that decides whether a block is searched at all), then each scoring word
diff pays for its input. `MAX_PAIRING_WORK` stays 262,144 bytes. Measured file:
`crates/zanshin-jj/src/line_pairs.rs` with `git hash-object`
`21d507ba73adb17d9836ca9f668ce416090f32ca`; the old file was measured from a copy of
`15ddbd39`. `limits` gained `e2-pruned-blocks` (a reviewer's case: a word list of 300 changed
blocks of 120 one-word lines, every word replaced by an unrelated one; no candidate shares a token,
so no word diff runs), and `e2-at-cap` now fills the budget with its table and its word diffs
together (44 lines a side instead of 63).

| `line_pairs.rs` | `e2-pruned-blocks` | `e2-at-cap` (44 lines) | `e2-reformatted-calls` | files where the budget left a block to jj (`history`) | E2 per file p99 (Dart / Rust) | E2 max |
|---|---:|---:|---:|---:|---:|---:|
| `15ddbd39` (the E2 run) | 371.8 ms, budget never short | 9.9 ms | 22.6 ms | 9 of 2,536 | 3.0 / 3.4 ms | 15.0 ms |
| `21d507ba` (budget pays for the table) | 1.6 ms | 9.1 ms | 0.5 ms | 12 of 2,536 | 3.2 / 3.3 ms | 10.1 ms |

jj's own diff of `e2-pruned-blocks` takes 14.0 ms. Before the fix E2's time on it grew with the
number of blocks (26 times jj's here); now the first block pays for its table, and every later one
is too big for what is left. `e2-reformatted-calls` drops to 0.5 ms because its first block's
one-to-one candidates alone nearly fill the budget, so that search runs out at once and every block
keeps jj's marks (before, the first blocks paired). The slowest file stays `scattered-changes` at
23.5 ms (jj 15.9 ms): 2,000 small blocks that pay a little each, so its cost grows with the file,
as jj's own diff does. A search that uses the whole budget still takes about 20 ms (the earlier
`e2-reformatted-calls` figure); a table-only search costs less per byte.

`witness`: E2's marks equal the E2 run's on every case (only the timing lines differ). `history`:
today's classes are unchanged (4,755 word-mark and 10,812 drawn differences of 96,295 lines); the
three more fallback files (`layout_engine.dart@2459cc42`, `zanshin_bootstrap_test.dart@fcc1b4d9`,
`projects_tree.dart@8552a563`) keep today's marks in some block, which moves the E2 rows a little.
Its E2 parts, verbatim:

```text
#### Today's gap to difft and E2's (96295 changed lines without a difft fallback)

| | word marks | drawn |
|---|---:|---:|
| today's marks differ from difft's | 4755 (4.9 %) | 10812 (11.2 %) |
| E2's marks differ from difft's | 5150 (5.3 %) | 10325 (10.7 %) |
| today's differ, E2's match difft's | 1130 (1.2 %) | 1914 (2.0 %) |
| today's match difft's, E2's differ | 1525 (1.6 %) | 1427 (1.5 %) |
| net change of today's gap | -8.3 % | 4.5 % |

Of the 5150 lines whose E2 word marks differ from difft's, E2 marks 3199 whole (unpaired, or their pair kept none of their ink).

#### E2 against today (115515 changed lines; the class says what E2 marks compared with today)

| class | word marks | share | drawn | share |
|---|---:|---:|---:|---:|
| same marks | 106773 | 92.4 % | 106397 | 92.1 % |
| E2 marks fewer bytes | 1977 | 1.7 % | 6078 | 5.3 % |
| E2 marks more bytes | 5610 | 4.9 % | 1712 | 1.5 % |
| different bytes | 1155 | 1.0 % | 1328 | 1.1 % |

#### Time per file

| | jj Dart | E2 Dart | jj Rust | E2 Rust |
|---|---:|---:|---:|---:|
| median | 0.2 ms | 0.1 ms | 0.2 ms | 0.1 ms |
| p90 | 0.6 ms | 0.5 ms | 0.8 ms | 0.6 ms |
| p99 | 1.3 ms | 3.2 ms | 1.6 ms | 3.3 ms |
| max | 3.4 ms | 7.2 ms | 3.0 ms | 10.1 ms |
| sum | 384.9 ms | 331.0 ms | 372.9 ms | 268.8 ms |
```

`limits`, verbatim (table and notes; the per-input details match the E2 run's):

| input | bytes before / after | difft args | difft `language` | difft wall | difft peak RSS | jj changed lines | jj in-process | E2 in-process (more) | E2 budget left a block to jj | jj + E2 process peak RSS |
|---|---:|---|---|---:|---:|---:|---:|---:|---|---:|
| byte-limit | 1108780 / 1108780 | defaults | `Text (1.1 MiB exceeded DFT_BYTE_LIMIT)` | 83.1 ms | 63.3 MB | 2 | 11.2 ms | 1.0 ms | no | 17.3 MB |
|  | 1108780 / 1108780 | `--byte-limit 100000000` | `Rust` | 932.7 ms | 385.6 MB |  | | | |  |
| scattered-changes | 548965 / 548965 | defaults | `Rust` | 1131.6 ms | 328.2 MB | 4000 | 15.9 ms | 23.5 ms | no | 16.3 MB |
|  | 548965 / 548965 | `--graph-limit 300000` | `Rust` | 1150.2 ms | 328.1 MB |  | | | |  |
| graph-limit-statements | 548965 / 548965 | defaults | `Text (exceeded DFT_GRAPH_LIMIT)` | 1731.6 ms | 1074.2 MB | 40000 | 88.6 ms | 0.4 ms | yes | 40.8 MB |
|  | 548965 / 548965 | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 962.8 ms | 328.6 MB |  | | | |  |
| graph-limit-array | 204032 / 204032 | defaults | `Text (exceeded DFT_GRAPH_LIMIT)` | 4225.1 ms | 620.4 MB | 12000 | 13.0 ms | 0.1 ms | yes | 38.7 MB |
|  | 204032 / 204032 | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 4049.8 ms | 203.2 MB |  | | | |  |
|  | 204032 / 204032 | `--graph-limit 6000000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 4615.9 ms | 1094.1 MB |  | | | |  |
| e2-at-cap | 1515 / 1515 | defaults | `Rust` | 80.2 ms | 93.9 MB | 88 | 0.2 ms | 9.1 ms | no | 3.3 MB |
| e2-reformatted-calls | 17684 / 48484 | defaults | `Rust` | 60.2 ms | 26.2 MB | 5040 | 6.1 ms | 0.5 ms | yes | 6.0 MB |
| e2-pruned-blocks | 280690 / 280690 | defaults | `Text` | 1426.7 ms | 61.4 MB | 72000 | 14.0 ms | 1.6 ms | yes | 44.8 MB |
| parse-error-rust | 66 / 83 | defaults | `Text (1 Rust parse error, exceeded DFT_PARSE_ERROR_LIMIT, first at 3:8)` | 37.8 ms | 12.8 MB | 3 | 0.0 ms | 0.1 ms | no | 2.7 MB |
| parse-error-dart | 72 / 76 | defaults | `Text (4 Dart parse errors, exceeded DFT_PARSE_ERROR_LIMIT, first at 1:0)` | 48.4 ms | 10.6 MB | 2 | 0.1 ms | 0.1 ms | no | 2.7 MB |
|  | 72 / 76 | `--parse-error-limit 10` | `Dart` | 42.9 ms | 10.6 MB |  | | | |  |
| missing-node-rust | 27 / 26 | defaults | `Rust` | 38.2 ms | 12.7 MB | 2 | 0.0 ms | 0.0 ms | no | 2.6 MB |
| no-parser-markdown | 32 / 38 | defaults | `Text` | 23.9 ms | 6.0 MB | 2 | 0.0 ms | 0.0 ms | no | 2.6 MB |
| conflict-jj-diff-style | 91 / 323 | defaults | `Text (2 Rust parse errors, exceeded DFT_PARSE_ERROR_LIMIT, first at 2:0)` | 45.1 ms | 12.9 MB | 9 | 0.1 ms | 0.1 ms | no | 2.7 MB |
| conflict-git-style | 91 / 254 | defaults | `Text (1 Rust parse error, exceeded DFT_PARSE_ERROR_LIMIT, first at 2:0)` | 36.8 ms | 12.8 MB | 6 | 0.0 ms | 0.0 ms | no | 2.5 MB |

Median of 3 runs. Peak RSS is `/usr/bin/time -l`'s maximum resident set size; jj's is a process of its own that reads both files and computes today's marks and E2's. E2's time is its line pairing alone, on top of jj's; E2's per-file budget is 262144 bytes (`MAX_PAIRING_WORK`).

Over all difft runs above: span content mismatches 0, spans moved by a carriage return 0.

# Structural diff probe (Story 5.9)

A throwaway, detached crate for Story 5.9's research: it puts **jj-lib's word marks** (what Zanshin's
inspector draws since Story 10.32) and **difftastic's structural marks** (`difft` 0.72.0) side by
side on the same hunk lines, and measures what difftastic costs and when it falls back. The report
that cites these results is
`_bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md`.

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
```

| mode | input | output |
|---|---|---|
| `witness` | `inputs/witness/<case>/before.*` and `after.*`, plus `edge-cr-tab` built in code (carriage returns and a tab) | per changed line jj's and difft's marks in `[-…-]` / `{+…+}` notation, with both comparisons |
| `history` | every `.rs` / `.dart` file modified (status `M`, no rename detection) in the newest `--commits` (default 200) non-merge commits of `--rev` that modify one; generated files skipped (by name and by generator header) | class counts in both views, time and peak memory per file, per-commit sums, the fallback files, examples; one row per file in `out/history.tsv` (or `--tsv FILE`) |
| `limits` | inputs generated into `out/limits/` that trip each difft fallback, with lowered and raised limits, and two conflicted files | difft's `language`, wall time and peak memory for difft and jj |
| `parse-check` | the `.rs`, `.dart`, `.md` files at `--rev` (read with `git show`), two known-bad samples, newer Dart syntax samples | ERROR / MISSING nodes per grammar, parse time |

All modes print Markdown to stdout. `out/` (generated inputs, temp files, `history.tsv`) is
git-ignored. `history` takes about 7 minutes on an otherwise idle machine (one `difft` process
per file; earlier runs under load took up to 25 minutes), `limits` and
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

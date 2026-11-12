# Struktur-Diff der difftastic-Klasse: Bibliothek oder Programm, Kosten, Grammatiken und die Abbildung auf `HunkLine.segments`

**Datum:** 2026-11-12 · **Anlass:** Story 5.9, Punkt 1 (Recherche), unbeaufsichtigter bmad-build-auto-Lauf; Spec `_bmad-output/implementation-artifacts/spec-5-9-structural-diff-difftastic-class-research.md`
**Fragen:** (1) Lässt sich difftastic (`difft`, MIT) als Bibliothek einbinden oder nur als Programm aufrufen? Was taugen diffsitter und ein eigener Baum-Diff über tree-sitter? (2) Was kostet es auf großen Dateien, und wie greifen seine Fallbacks `DFT_BYTE_LIMIT`, `DFT_GRAPH_LIMIT` und `DFT_PARSE_ERROR_LIMIT`? (3) Welche Grammatiken braucht es, zuerst für Rust, Dart und Markdown? (4) Wie passen seine Marken auf `HunkLine.segments`?
**Methode:** Quellen in fester Version gelesen: difftastic 0.72.0 (Tag `0.72.0`: `Cargo.toml`, `src/main.rs`, `src/options.rs`, `src/display/json.rs`, `src/parse/syntax.rs`, `src/parse/tree_sitter_parser.rs`, `src/diff/shortest_path.rs`; README und CHANGELOG der installierten Homebrew-Formel), diffsitter v0.9.0, jj-lib 0.47.0 (vendored), die jj-Doku @ v0.47.0 und die zurückgenommenen Stories 5.3 / 5.4 (Commit `e8e8297f`, Spec 5.3). Gemessen mit der Wegwerf-Probe `spikes/structural-diff-probe/`: eine eigenständige Crate, offline gebaut, mit allen Befehlen und Ausgaben im README. Sie legt jj-libs Wortmarken und die Marken des installierten `difft` 0.72.0 auf dieselben Hunk-Zeilen; meldet `difft --version` etwas anderes, bricht sie ab. Eingaben: Zeugenfälle, die in den 200 neuesten Commits dieses Repos geänderten `.rs`- und `.dart`-Dateien, synthetische Eingaben für jeden Fallback und ein Parse-Test aller Dateien des Repos bei `5ba5f5d4`. Zeit als Wanduhrzeit, Speicher als Spitzen-RSS laut `/usr/bin/time -l`. Rechner: Apple M4 Pro, 24 GB, macOS 27.2.1.
**Status:** Recherche fertig. Ralph entschied am 2026-11-12 für Option E2: Zeilen paaren vor jj's Wortdiff. Gebaut und gemessen im Abschlusslauf der Story 5.9, siehe Abschnitt 9. Die Optionen A–D in Abschnitt 7 sind damit überholt.

---

**Kurz:** difftastic lässt sich nur als Programm nutzen, und seine maschinenlesbare Ausgabe ist ausdrücklich instabil. Auf den drei Zeugen der Story setzt es dieselben Wortmarken wie jj:
- Ralphs drei stepper.dart-Beispiele: dieselben Wortmarken. Nur die neue Einrückung füllt jj, difft nicht.
- `f(a, b)` → `f(b, a)`: dieselben Wortmarken. difftastic erkennt keine Verschiebungen; für es zählt die Reihenfolge immer.
- Jeder Fallback, auch eine Datei mit Konfliktmarkern: jj's Marken.

Auf den echten Diffs der letzten 200 Commits (115.515 geänderte Zeilen in geänderten `.rs`- und `.dart`-Dateien dieses Repos) fällt difftastic bei 16,6 % der Zeilen auf seinen Text-Diff zurück (Graph-Limit). Auf den übrigen Zeilen würde ein Bau bei 11,2 % andere starke Marken zeichnen als heute, gefüllte Leerzeichen mitgezählt, in 1.454 von 2.536 Dateien. Vergleicht man nur die Wortmarken ohne Leerraum, sind es 4,9 % der Zeilen. Er gewinnt bei Umformatierungen in Rust und bei der richtigen schließenden Klammer; in Dart markiert difftastic die Kommas weiter, die `dart format` ergänzt. Er verliert, wo difftastic ganze Ausdrücke als neu markiert.

Dafür kostet `difft` pro Datei im Median 60–63 ms statt 0,2–0,3 ms, und 66 der 2.536 Dateien brauchen über eine Sekunde. Sein Speicher lag auf diesen Diffs im Median bei 20,8 MB und höchstens bei 986 MB; synthetische Eingaben trieben ihn auf 1,1 GB.

**Empfehlung: Option A, lassen.** jj's Wortmarken bleiben, also das, was `jj diff --git` unterstreicht. Der Gewinn ist klein, die Kosten und Risiken sind groß. Will Ralph die ruhigeren Umformatierungen in Rust trotzdem, ist Option B der kleinste Weg: `difft` als optionales externes Programm, mit Zeitbudget und jj als Fallback.

## 1. Bibliothek oder Programm?

**Nur als Programm.**
- difftastic 0.72.0 hat kein `[lib]`, nur `[[bin]] difft` (`Cargo.toml` @ Tag `0.72.0`).
- Eine Bibliotheks-API wird seit Jahren gewünscht, es gibt sie aber bis heute nicht. Issue #12 („plan to expose api“) schloss der Autor Wilfred Hughes am 2021-07-18, es sei noch zu früh. PR #231 („Add lib.rs so difftastic can be used as a library“) ist seit 2022-04-03 offen.
- Inoffizielle Abspaltungen taugen nicht: `difftastic-lib` 0.0.2 (MIT) steht seit 2023-02-17 still; `baz-difftastic` 0.53.4 ist GPL-2.0 und damit ausgeschlossen.
- jj selbst bindet difftastic nur als externes Programm ein: `ui.diff-formatter = ["difft", "--color=always", "$left", "$right"]` (`docs/config.md` @ v0.47.0). Das ergibt Terminaltext, keine Daten.

**Die maschinenlesbare Ausgabe** ist `difft --display json`.
- Sie braucht `DFT_UNSTABLE=yes`. Ohne die Variable bricht `difft` mit dem Hinweis ab, das Format könne sich ändern (gemessen; `src/options.rs` @ 0.72.0).
- Pro Datei: `language`, `status` (`changed`, `unchanged`, `created`, `deleted`) und in `chunks` pro Zeile die neuen Spannen mit `start`, `end`, `content` und `highlight` (`src/display/json.rs` @ 0.72.0).
- Zeilen zählen ab 0. Die Spalten sind Byte-Offsets in der Zeile ohne `\r`, denn `difft` entfernt jedes `\r` vor dem Parsen (`src/main.rs`). Gemessen am Zeugen `edge-non-ascii` (`grüße` und `🦀` vor der geänderten Stelle) und an `edge-cr-tab` (ein `\r` mitten in der Zeile): 0 Abweichungen.
- Einen Fallback zeigt nur das Feld `language`: `Text (…)` mit dem Grund. Im Fallback listet das JSON jedes Token der geänderten Zeilen als neu (gemessen); diese Marken taugen nicht.
- **Kommentare und Strings:** In einem geänderten Kommentar oder String rechnet difftastic eigene Wortmarken, `NovelWord` für neue und `UnchangedPartOfNovelItem` für gleiche Wörter (`src/parse/syntax.rs`). Das JSON verliert diesen Unterschied: `MatchKind::is_novel()` zählt `UnchangedPartOfNovelItem` mit, und `highlight` hat dafür keinen Wert (`src/display/json.rs`). Deshalb listet das JSON jedes Wort eines geänderten Kommentars oder Strings als neu. Als Bibliothek (Option C) bekäme Zanshin difftastics eigene Wortmarken, auch auf Fallback-Zeilen; als Programm (Option B) nur, wenn upstream das JSON erweitert.

**Als Bibliothek ginge nur ein Fork** des MIT-Quellcodes. Hindernisse:
- tree-sitter-Version: difftastic 0.72.0 nutzt tree-sitter 0.26.10, 5.4 nutzte 0.27.1. Die Crate `tree-sitter` setzt `links = "tree-sitter"`, also passt nur eine Version in einen Build.
- Andere Grammatik-Crates: `tree-sitter-rust-orchard` 0.16.6 und `tree-sitter-dart-orchard` 0.5.0 (beide MIT), nicht die von 5.4.
- Annahmen eines Programms: jemalloc als globaler Allocator, Arbeit auf dem Hauptthread (8 MiB Stack), kein Parse-Timeout, kein Abbruch (`src/main.rs`, `src/parse/tree_sitter_parser.rs`). Im Worker-Isolate (1 MiB Stack, gemessen in Spec 5.3) bräuchte es einen eigenen Thread mit großem Stack, und einen laufenden Diff kann man dort nicht beenden.
- Pflege: difftastic erscheint alle ein bis vier Monate (CHANGELOG: 0.68 im März, 0.69 im April, 0.70 im August, 0.71 im September 2026). Ein Fork muss mitziehen.

**diffsitter** (v0.9.0, MIT, 2025-04-26) hat ein `[lib]` (`libdiffsitter`), passt aber nicht:
- keine Grammatik für Dart und Markdown (README v0.9.0);
- tree-sitter 0.25.3, also derselbe `links`-Konflikt;
- ein Myers-Diff über tree-sitter-Knoten, ohne Erkennung verschobenen Codes (`src/diff.rs` v0.9.0);
- laut README noch weit von produktionsreif entfernt, keine maschinenlesbare Ausgabe dokumentiert.

**mergiraf** (0.20.0), ein syntaxbewusster Merge-Treiber über tree-sitter mit Bibliothek, ist GPL-3.0-only und damit ausgeschlossen.

**Ein eigener Diff über tree-sitter** (mit 5.4s Grammatiken) geht in zwei Größen:
- klein (D1): die Blätter des Syntaxbaums als Tokens in jj-cores eigenem Diff, Leerraum ignoriert. jj-core bietet das an: `ContentDiff::for_tokenizer` nimmt einen eigenen Tokenizer und einen Vergleich wie `CompareBytesIgnoreAllWhitespace` (`src/diff.rs:620` und `:165` in jj-core 0.47.0). Das bringt Ruhe beim Umformatieren, sonst kaum etwas (Abschnitte 5 und 6).
- groß (D2): ein echter Baum-Diff, entweder difftastics Dijkstra-Suche nachgebaut oder ein GumTree-artiger Abgleich mit Verschiebungen. Nur der zweite könnte `f(a, b)` → `f(b, a)` als Verschiebung markieren.

## 2. Kosten und Fallbacks

### 2.1 Pro Datei, auf echten Diffs

Was der Nutzer abwartet, ist eine Datei. Der Inspector liest erst eine Zusammenfassung ohne Hunks, dann nur den Diff der fokussierten Datei (`app/lib/src/features/graph/graph_inspector.dart:281` und `:259`); die Undo Timeline ebenso (`app/lib/src/features/undo_timeline/operation_changes.dart:268-275`).

2.536 Dateien aus 198 der 200 Commits (Abschnitt 6). jj: in-process, Eingaben im Speicher. difft: der ganze Prozess mit Start, Lesen der Dateien und JSON, unter `/usr/bin/time -l`.

| | jj Dart | difft Dart | jj Rust | difft Rust |
|---|---:|---:|---:|---:|
| Median | 0,2 ms | 63,4 ms | 0,3 ms | 60,4 ms |
| p90 | 0,6 ms | 180,4 ms | 0,8 ms | 144,0 ms |
| p99 | 1,3 ms | 1.564 ms | 1,6 ms | 685 ms |
| Maximum | 3,5 ms | 3.036 ms | 3,0 ms | 3.470 ms |
| Summe | 0,4 s | 214 s | 0,4 s | 97 s |

- Über 100 ms: 506 Dateien, über 250 ms: 154, über 1 s: 66 (2,6 %). 55 der 66 sind Graph-Limit-Fallbacks.
- Speicher pro Datei (Spitzen-RSS des `difft`-Prozesses): Median 20,8 MB, p90 130 MB, p99 946 MB, höchstens 986 MB. Die 56 Fallback-Dateien lagen bei 870–986 MB: Wo `difft` am Graph-Limit aufgibt, hat es vorher fast 1 GB belegt.
- Schon ein winziger Diff kostet einen Prozess: 26–47 ms und 6–13 MB (Tabelle 2.2, kleine Eingaben).
- Nebenbei, summiert über alle Dateien eines Commits: jj im Median 2,6 ms, difft 0,85 s (p90 4,1 s, höchstens 11,3 s). Das wartet kein Nutzer ab, weil Inspector und Undo Timeline pro Datei lesen.

### 2.2 Die drei Fallbacks

Synthetische Eingaben, die jeden Fallback auslösen (Median aus drei Läufen, Spitzen-RSS laut `/usr/bin/time -l`; jj in einem eigenen Prozess):

| Eingabe | Bytes rechts | difft-Argumente | difft `language` | difft | difft RSS | jj | jj RSS |
|---|---:|---|---|---:|---:|---:|---:|
| 13.000 Rust-Funktionen, eine geändert | 1.108.780 | Standard | `Text (1.1 MiB exceeded DFT_BYTE_LIMIT)` | 81 ms | 63 MB | 8 ms | 17 MB |
| | | `--byte-limit 100000000` | `Rust` | 890 ms | 386 MB | | |
| eine Funktion, 20.000 Anweisungen, jede 10. geändert | 548.965 | Standard | `Rust` (kein Fallback) | 1.146 ms | 328 MB | 15 ms | 15 MB |
| | | `--graph-limit 300000` | `Rust` (kein Fallback) | 1.119 ms | 321 MB | | |
| dieselbe, jede Anweisung geändert | 548.965 | Standard | `Text (exceeded DFT_GRAPH_LIMIT)` | 1.559 ms | 1.074 MB | 91 ms | 37 MB |
| | | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 933 ms | 328 MB | | |
| ein Array aus 60.000 Zahlen, jede dritte geändert | 204.032 | Standard | `Text (exceeded DFT_GRAPH_LIMIT)` | 4.108 ms | 620 MB | 14 ms | 36 MB |
| | | `--graph-limit 300000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 3.768 ms | 199 MB | | |
| | | `--graph-limit 6000000` | `Text (exceeded DFT_GRAPH_LIMIT)` | 4.709 ms | 1.095 MB | | |
| Rust-Syntaxfehler `let = total;` | 83 | Standard | `Text (1 Rust parse error, …)` | 41 ms | 13 MB | 0,1 ms | 2 MB |
| Dart-Primärkonstruktor | 76 | Standard | `Text (4 Dart parse errors, …)` | 45 ms | 11 MB | 0,1 ms | 2 MB |
| | | `--parse-error-limit 10` | `Dart` | 47 ms | 11 MB | | |
| Rust `f(b, a;` (tree-sitter ergänzt ein `)`) | 26 | Standard | `Rust` (kein Fallback) | 39 ms | 13 MB | 0,0 ms | 2 MB |
| Markdown | 38 | Standard | `Text` (kein Parser) | 26 ms | 6 MB | 0,0 ms | 2 MB |
| Konflikt, jj's Stil `diff` | 323 | Standard | `Text (2 Rust parse errors, …)` | 37 ms | 13 MB | 0,1 ms | 2 MB |
| Konflikt, Stil `git` | 254 | Standard | `Text (1 Rust parse error, …)` | 37 ms | 13 MB | 0,0 ms | 2 MB |

- **`DFT_BYTE_LIMIT`** (1.000.000 Bytes je Seite) wird vor dem Parsen geprüft (`to_tree_with_limit`), der Fallback ist schnell. Mit hohem Limit vergleicht `difft` dieselbe Datei strukturell: knapp 0,9 s und 386 MB.
- **`DFT_GRAPH_LIMIT`** (3.000.000 Knoten) begrenzt die Dijkstra-Suche: Sie bricht ab, sobald sie mehr Knoten gesehen hat als das Limit (`shortest_vertex_path` in `src/diff/shortest_path.rs`). Zeit und Speicher bis zum Fallback wachsen deshalb mit dem Limit, der Speicher stärker als die Zeit: auf den beiden Eingaben bei 300.000 Knoten 0,9 s und 328 MB bzw. 3,8 s und 199 MB, bei 3.000.000 1,6 s und 1,07 GB bzw. 4,1 s und 620 MB, bei 6.000.000 (nur das Array) 4,7 s und 1,1 GB. Wie viel der Zeit die Suche selbst kostet, misst die Probe nicht: Das Array braucht auch bei 300.000 Knoten 3,8 s, und die Eingabe mit jeder 10. Anweisung blieb selbst bei 300.000 Knoten strukturell und brauchte 1,1 s. Auf echten Diffs (Abschnitt 6) traf das Limit 56 gewöhnliche Quelldateien von 13 bis 293 KB; jede kostete 0,93–3,47 s und 870–986 MB, zusammen 82 s oder gut ein Viertel der ganzen difft-Zeit.
- **`DFT_PARSE_ERROR_LIMIT`** (0): Ein einziger ERROR-Knoten reicht für den Fallback. Mit `--parse-error-limit 10` vergleicht `difft` die Dart-Datei mit Primärkonstruktor strukturell. MISSING-Knoten zählen nicht, `difft` prüft nur `is_error()` (`src/parse/tree_sitter_parser.rs`). `f(b, a;` vergleicht es deshalb strukturell, mit merkwürdigen Marken: `f[-(-]a[-,-] [-b)-]` → `f{+(b,+} a`.
- **Konfliktmarker:** Zanshin vergleicht eine Datei mit Konflikt so, wie jj sie materialisiert, also mit Markern. Mit Markern in jj's Standardstil `diff` und im Stil `git` (beide nach `docs/conflicts.md` @ v0.47.0) fällt `difft` auf Parse-Fehler zurück; es gelten jj's Marken.
- **Keine Zeitgrenze:** `difft` kennt weder Timeout noch Abbruch. Ein Bau muss den Prozess nach einem eigenen Zeitbudget beenden und jj's Marken nehmen.
- jj liegt auf allen Eingaben bei höchstens 91 ms und 37 MB.

## 3. Grammatiken

**difft bringt seine eigenen mit**, 62 Sprachen (`difft --list-languages`):
- Rust über `tree-sitter-rust-orchard` 0.16.6, Dart über `tree-sitter-dart-orchard` 0.5.0 (beide MIT).
- **Kein Markdown.** Eine `.md`-Datei ist `Text`, also bleiben dort jj's Marken.
- Das Programm ist 90.371.936 Bytes groß (Homebrew 0.72.0, nur arm64). 0.72 entfernte Verilog und F#, weil deren Parser das Programm zu groß machten (CHANGELOG).

**5.4s Setup** (zurückgenommen in `e8e8297f`): tree-sitter 0.27.1, tree-sitter-rust 0.24.2, tree-sitter-dart 0.3.0, tree-sitter-md 0.5.4, alle MIT. Gemessen in Spec 5.3:
- Die Release-cdylib wuchs von 29,8 auf 33,7 MB.
- tree-sitter 0.27 hat kein Parse-Timeout. Der Dart-Parser braucht 23 s für 131.000 Zeichen `[`.
- tree-sitter-mds Inline-Parser überläuft bei etwa 48.000 Zeichen einen 1-MiB-Stack.

**Parse-Test über das Repo** (`parse-check --rev 5ba5f5d4…`, die Dateien dieser Revision):

| Sprache | Dateien | MB | 5.4-Grammatik: Dateien mit ERROR | Parse-Zeit gesamt | langsamste Datei | difft-Grammatik: Dateien mit ERROR |
|---|---:|---:|---:|---:|---:|---:|
| Rust | 281 | 9,4 | 0 | 0,47 s | 81 ms | 0 |
| Dart | 628 | 9,8 | 0 | 1,19 s | 75 ms | 0 |
| Markdown | 420 | 13,7 | 0 | 3,88 s | 538 ms | kein Parser |

Auch MISSING-Knoten gab es keine. Positivkontrollen: Ein bekannt falsches Rust- und ein Dart-Stück (`let = ;`, `final = ;`) melden beide Grammatik-Sätze als Fehler. Ein eigener Diff müsste beide Seiten parsen: grob 0,05 ms je KB in Rust, 0,12 ms in Dart und 0,28 ms in Markdown.

**Neuere Dart-Syntax:** tree-sitter-dart 0.3.0 parst alle neun Proben ohne ERROR- oder MISSING-Knoten, von Records und Patterns (Dart 3.0) bis zu Dot-Shorthands (3.10) und Primärkonstruktoren. difftastics Dart-Grammatik scheitert nur am Primärkonstruktor (`class Point(final int x, final int y);`, 4 Parse-Fehler, also Fallback). Das installierte Dart 3.15 Beta akzeptiert ihn (`dart analyze`: keine Probleme). Das Repo nutzt ihn heute nicht.

## 4. Abbildung auf `HunkLine.segments`

**Dieselbe Leitung, kein Schema-Wechsel.** Ein Bau ersetzt nur die Segmente geänderter Zeilen; `HunkLine.segments` bleibt, wie es ist (Text, `Equal` / `Added` / `Removed`). Gerechnet wird in Rust, dort, wo beide Seiten und der Dateiname schon vorliegen (`DiffReader::file` in `crates/zanshin-jj/src/hunks.rs`).

**Die Regel** (die Startannahme der Spec, durch die Probe korrigiert in Punkt 3):
1. jj's Zeilen-Hunks bleiben die der CLI. difft entscheidet nur über die Marken in Zeilen, die jj als geändert zeigt.
2. Eine `Removed`-Zeile nimmt die Spannen der linken Seite auf ihrer Zeile, eine `Added`-Zeile die der rechten. Eine `Context`-Zeile bleibt ein `Equal`-Segment.
3. **Korrektur:** In einem neuen Kommentar oder String gilt jj's Wortmarke, denn das JSON listet dort jedes Wort als neu (Abschnitt 1; Probe `edge-multiline-token`). Die erste Regel markiert ganze Kommentare: auf echten Diffs 8.801 Zeilen „mehr“, die korrigierte nur 1.211.
4. Eine geänderte Zeile ohne Spanne wird ein `Equal`-Segment. 10.32 zeichnet sie nur mit der schwachen Zeilenfarbe.
5. Fallback, Prozessfehler oder Zeitüberschreitung: jj's Segmente bleiben unverändert. Fallback heißt: `language` beginnt mit `Text`. Das gilt auch für Dateien mit Konfliktmarkern (Abschnitt 2.2).
6. Spalten sind Byte-Offsets der Zeile ohne `\r`. Eine Zeile mit `\r` vor einer Spalte wird zurückgerechnet.
7. Leere Spannen (`start == end`, das Zeilenende eines mehrzeiligen Atoms) fallen weg.
8. Spannen auf jj-Kontextzeilen und außerhalb der Hunks fallen weg. Auf echten Diffs ohne Fallback waren das 1.626 und 882 Marken.
9. Die Segmente einer Zeile ergeben zusammen ihren Text, keines ist leer, benachbarte unterscheiden sich in der Art.

**Randfälle, jeweils an einer Probe-Eingabe** (`witness`):

| Fall | Eingabe | Ergebnis |
|---|---|---|
| Nicht-ASCII | `edge-non-ascii`: `grüße`, `🦀`, dann `alpha` → `beta` | dieselben Marken wie jj; Spalten als Bytes stimmen (0 Abweichungen) |
| Token über mehrere Zeilen | `edge-multiline-token`: Blockkommentar und Raw-String, je ein Wort geändert | erste Regel: ganze Zeilen; korrigierte Regel: nur `once`/`twice` und `history`/`limits`, wie jj |
| Spanne auf jj-Kontextzeile | `edge-context-novel`: zwei Zeilen vertauscht | jj hält `alpha();` für Kontext, difft markiert `alpha` und `beta` an ihrer Stelle; die Marken auf `alpha();` fallen weg, die neu gezeigte Zeile behält nur `beta` |
| jj ändert, difft nicht | `reformat`: ein Aufruf auf fünf Zeilen umgebrochen | difft meldet `unchanged`; jede geänderte Zeile wird ein `Equal`-Segment |
| `\r` und Tab | `edge-cr-tab`: CRLF, Tab, ein `\r` mitten im String | zwei Spannen zurückgerechnet, dann dieselben Marken wie jj |

## 5. Was ein Bau auf den Zeugen markieren würde

Probe-Ausgabe (`witness` und `limits`), nur die geänderten Zeilen; die vollen Ausgaben stehen im README der Probe. `[-…-]` ist eine entfernte, `{+…+}` eine hinzugefügte Marke. Zwei Vergleiche: die Wortmarken (markierte Zeichen ohne Leerraum) und das, was 10.32 zeichnet (gefüllte Leerzeichen mitgezählt).

**Ralphs drei stepper.dart-Beispiele: dieselben Wortmarken auf allen 9 Zeilen; gezeichnet gleich auf 6 von 9.**

```text
- jj    |    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),
- difft |    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),
+ jj    |    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),
+ difft |    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),

- jj    |    Expanded(child: _Line(color: isFirst ? null : lineColor)),
- difft |    Expanded(child: _Line(color: isFirst ? null : lineColor)),
+ jj    |    Expanded(
+ difft |    Expanded(
+ jj    |{+      +}child: _Line(color: isFirst ? null : lineColor){+,+}
+ difft |      child: _Line(color: isFirst ? null : lineColor){+,+}
+ jj    |{+    +}),
+ difft |    ),

- jj    |  padding: Spacing.[-spacing8-],
- difft |  padding: Spacing.[-spacing8-],
+ jj    |  {+// Small side padding.+}
+ difft |  {+// Small side padding.+}
+ jj    |{+  +}padding: Spacing.{+spacing2+},
+ difft |  padding: Spacing.{+spacing2+},
```

Auf drei Zeilen füllt jj die neue Einrückung, difft nicht; sonst markieren beide dasselbe. Ein Bau zeichnete diese Beispiele also wie heute, nur ohne gefüllte Einrückung. Das nachgestellte Komma, das `dart format` ergänzt, markiert auch difft.

**`f(a, b)` → `f(b, a)`, in Rust und in Dart: dieselben Wortmarken.**

```text
- jj    |    let total = f([-a, -]b);          (Rust)
- difft |    let total = f([-a,-] b);
+ jj    |    let total = f(b{+, a+});
+ difft |    let total = f(b{+,+} {+a+});
- jj    |  final total = f([-a, -]b);          (Dart)
- difft |  final total = f([-a,-] b);
+ jj    |  final total = f(b{+, a+});
+ difft |  final total = f(b{+,+} {+a+});
```

difftastic markiert keine Verschiebung, sondern wie jj ein entferntes und ein hinzugefügtes `a`; gezeichnet füllt nur jj das Leerzeichen dazwischen. Das README von 0.72.0 sagt es ausdrücklich: Die Reihenfolge zählt immer, `set(1, 2)` und `set(2, 1)` sind verschieden. Der Zeuge „markiert die Verschiebung“ ist mit difftastic nicht erreichbar.

**Jeder Fallback: jj's Marken.** Ein Bau nimmt dann jj's Segmente (`build` = was der Bau zeichnet):

```text
- jj    |    value.wrapping_mul(6500).rotate_left([-3-])          (Byte-Limit)
- build |    value.wrapping_mul(6500).rotate_left([-3-])
- jj    |    values.push(0 * [-3-]);                              (Graph-Limit)
- build |    values.push(0 * [-3-]);
+ jj    |    let total = add(1, {+3+});                           (Parse-Fehler, Rust)
+ build |    let total = add(1, {+3+});
+ jj    |int area(Point p) => p.x * p.y{+ * 2+};                (Parse-Fehler, Dart-Primärkonstruktor)
+ build |int area(Point p) => p.x * p.y{+ * 2+};
+ jj    |Some text with {+another+} word.                       (Markdown, kein Parser)
+ build |Some text with {+another+} word.
+ jj    |{+<<<<<<< conflict 1 of 1+}                            (Konfliktmarker, Stil diff)
+ build |{+<<<<<<< conflict 1 of 1+}
```

**Die übrigen Zeugen:**

```text
+ jj    |{+    +}log({+redact(+}state.summary()){+)+};          (Verschachtelung, Rust)
+ difft |    log({+redact(+}state.summary(){+)+});
+ jj    |{+fn first() -> u32 {+}                                (verschobener Block, Rust)
+ difft |{+fn+} {+first()+} {+->+} {+u32+} {+{+}
+ jj    |{+       +} third_argument{+,+}                        (nur umformatiert, Rust)
+ difft |        third_argument,
```

- **Verschachtelung** (`nesting`): Wortmarken auf 7 von 8 Zeilen gleich, gezeichnet auf 5. In `log(redact(state.summary()));` markiert difft die `)`, die zu `redact(` gehört; jj markiert die letzte. Auf zwei Zeilen füllt jj die tiefere Einrückung.
- **Verschobener Block** (`moved-block`): dieselben Marken auf allen 8 Zeilen, auch gezeichnet. Beide zeigen die Funktion als entfernt und neu.
- **Nur umformatiert** (`reformat`, Rust): difft meldet `unchanged` und markiert nichts. jj markiert die neue Einrückung und das hinzugefügte Komma; gezeichnet gleich sind nur 2 von 6 Zeilen. In Rust sind nachgestellte Kommas für difftastic seit 0.69 bedeutungslos, in Dart nicht (`stepper`, Hunk 2).

## 6. Echte Diffs: die letzten 200 Commits

**Korpus:** Revision `5ba5f5d4`, die 200 neuesten Commits ohne Merge, die eine `.rs`- oder `.dart`-Datei ändern (2026-10-23 bis 2026-11-12), nur dieses Repo. Verglichen werden nur Dateien, die ein Commit ändert (Status `M`, ohne Erkennung von Umbenennungen); neue, gelöschte und umbenannte Dateien nicht. 2.706 geänderte Dateien, davon 170 generiert (übersprungen), 2.536 verglichen (Dart 1.510, Rust 1.026) aus 198 Commits (die übrigen zwei ändern keine vergleichbare Datei), 115.515 geänderte Zeilen. Inhaltsabweichungen der Spannen: 0.

**Wortmarken pro geänderter Zeile** (korrigierte Regel; verglichen werden markierte Zeichen ohne Leerraum):

| Klasse | Dart | Rust | alle | Anteil | Anteil ohne Fallback |
|---|---:|---:|---:|---:|---:|
| dieselben Marken | 53.463 | 38.077 | 91.540 | 79,2 % | 95,1 % |
| difft markiert weniger | 1.660 | 1.046 | 2.706 | 2,3 % | 2,8 % |
| difft markiert mehr | 740 | 471 | 1.211 | 1,0 % | 1,3 % |
| andere Zeichen | 351 | 487 | 838 | 0,7 % | 0,9 % |
| difft fiel zurück | 16.738 | 2.482 | 19.220 | 16,6 % | |

**So, wie 10.32 sie zeichnet** (gefüllte Leerzeichen mitgezählt; keine starken Marken auf einer Zeile ohne sichtbaren unmarkierten Text):

| Klasse | Dart | Rust | alle | Anteil | Anteil ohne Fallback |
|---|---:|---:|---:|---:|---:|
| gleich gezeichnet | 50.125 | 35.358 | 85.483 | 74,0 % | 88,8 % |
| difft füllt weniger | 4.843 | 3.743 | 8.586 | 7,4 % | 8,9 % |
| difft füllt mehr | 735 | 388 | 1.123 | 1,0 % | 1,2 % |
| andere Zeichen | 511 | 592 | 1.103 | 1,0 % | 1,1 % |
| difft fiel zurück | 16.738 | 2.482 | 19.220 | 16,6 % | |

Das sind 11,2 % der strukturell verglichenen Zeilen, in 1.454 von 2.536 Dateien. Ohne Leerraum unterscheiden sich nur 4,9 % (Tabelle oben). Eine Zeile mit gleichen Wortmarken, die anders gezeichnet wird, unterscheidet sich nur in Leerzeichen; das sind mindestens 6,3 % der Zeilen (11,2 − 4,9), also mehr als die Hälfte der anders gezeichneten. Genau gezählt ist es nicht: Eine Zeile mit anderen Wortmarken kann gleich gezeichnet werden, wenn 10.32 auf beiden Seiten keine starken Marken zeichnet. Die Leerzeichen kommen daher, dass jj neue Einrückung und Leerzeichen zwischen geänderten Wörtern füllt; difft markiert nur Tokens.

**Fallbacks:** 56 Dateien (2,2 %), alle wegen des Graph-Limits. Sie tragen 16,6 % der geänderten Zeilen: große Änderungen fallen am ehesten zurück, also gerade dort, wo man Hilfe bräuchte.

**Was die Unterschiede sind** (Beispiele im README der Probe):
- **difft markiert weniger:** meist Zeilen, die jj als entfernt und neu zeigt, weil sich die Zeilen drumherum änderten, und die difft als unverändert oder nur eingerückt wertet. 1.233 solche Zeilen markiert difft gar nicht. Beispiel: `windows = AppWindows(…)..attach(registry);` ist für jj entfernt und neu, für difft unverändert.
- **difft markiert mehr:** difft hält einen ganzen Ausdruck für neu, wo jj ein Wort sieht. Beispiel: jj markiert in `toastSpan(strings.toastOpened(…), …)` nur `strings`, difft jedes Token der Zeile.
- **andere Zeichen:** beide markieren eine Änderung, aber an verschiedenen Stellen, oft bei Klammern und Ketten wie `.where(…)`.

## 7. Optionen

| | A: lassen | B: `difft` als Programm | C: difftastic als Bibliothek (Fork) | D: eigener Diff über tree-sitter |
|---|---|---|---|---|
| **Was es markiert** (Zeugen) | jj's Wortmarken, wie heute | stepper.dart: gleiche Wortmarken, ohne gefüllte Einrückung; `f(a, b)` → `f(b, a)`: gleiche Wortmarken; Fallbacks: jj. Besser: Umformatieren in Rust (keine Marken), die richtige Klammer. Schlechter: ganze Ausdrücke auf 1,3 % der Zeilen. Kommentare und Strings nur mit der korrigierten Regel (Abschnitt 4) | wie B, aber mit difftastics eigenen Wortmarken in Kommentaren, Strings und auf Fallback-Zeilen | D1 (Syntax-Tokens in jj-cores Diff, Leerraum ignoriert): wie jj, nur Umformatieren ruhiger. D2 (Baum-Diff): wie B; mit GumTree-artigem Abgleich auch Verschiebungen, also `f(a, b)` → `f(b, a)` |
| **CLI-Parität** | die Marken der CLI: was `jj diff --git` unterstreicht (Regel aus 5.2) | Marken, die das eingebaute Diff der CLI nicht zeigt. jj nutzt difft nur über `ui.diff-formatter`; das Einschalten könnte dieser jj-Einstellung folgen statt einer neuen App-Einstellung | Marken ohne Gegenstück in der CLI | Marken ohne Gegenstück in der CLI |
| **Aufwand** | keiner | M: Prozess mit Zeitbudget und Abbruch, temporäre Dateien, JSON lesen, Abbildung (Abschnitt 4), Einstellung, Tests | L: Fork trimmen (nur Rust und Dart, ohne jemalloc), tree-sitter angleichen, eigener Thread mit großem Stack, Pflege bei jedem Release | D1: M. D2: L bis XL (Algorithmus, eigene Grenzen) |
| **Neue Abhängigkeiten** (Lizenz) | keine | `serde_json` direkt in zanshin-jj (MIT oder Apache-2.0; steht schon als Transitive in `Cargo.lock`); zur Laufzeit `difft` (MIT; die mitgelieferten Parser laut README MIT oder Apache, nicht einzeln geprüft) | difftastic-Code (MIT), tree-sitter 0.26.x (MIT), `tree-sitter-rust-orchard` und `tree-sitter-dart-orchard` (MIT), weitere difftastic-Crates (nicht einzeln geprüft) | tree-sitter 0.27.1, tree-sitter-rust 0.24.2, tree-sitter-dart 0.3.0, tree-sitter-md 0.5.4 (alle MIT) |
| **Build und Größe** | — | B1, vom Nutzer installiert: 0. B2, im App-Bundle: +90 MB, nur arm64; ein universelles oder auf Rust und Dart gekürztes Programm: nicht gemessen | nicht gemessen; schon 5.4s drei Grammatiken brachten +3,9 MB | +3,9 MB für drei Grammatiken (Spec 5.3) |
| **Fallback** | — | `Text (…)` in `language`, Prozessfehler oder Zeitbudget: jj's Marken. `difft` nur für Sprachen mit Parser starten (nicht für Markdown usw.), sonst kostet jede solche Datei 26–47 ms für nichts. Ein kleineres `--graph-limit` (`DFT_GRAPH_LIMIT`) senkt den Speicher bis zum Fallback | wie B, aber ohne Abbruch: Das Graph-Limit läuft im App-Prozess bis zum Ende | eigene Grenzen nötig (Länge, Zeit); sonst jj |
| **Risiken** | Umformatieren bleibt laut. Abmildern lässt es sich schon heute mit `-w` / `-b` (`DiffOptions.whitespace`, Dart `RepoHandle.diff(whitespace:)`): Sie machen nur eingerückte Zeilen zu Kontext. Das ist auch die Messlatte für D1 | instabiles JSON-Format; Versionsdrift beim Nutzer; Kosten pro Datei (Median 60–63 ms, 66 Dateien über 1 s, bis 3,5 s; Speicher bis 986 MB auf echten, 1,1 GB auf synthetischen Diffs); 16,6 % der Zeilen fallen ohnehin zurück; MISSING-Knoten ergeben seltsame Marken ohne Hinweis im JSON; neue Dart-Syntax (Primärkonstruktor) → Fallback | alle Risiken von B ohne den Prozess als Schutz: Speicher bis knapp 1 GB im App-Prozess (jeder Graph-Limit-Fallback auf echten Diffs), kein Abbruch, Stack-Tiefe; Fork-Pflege | tree-sitters Worst Cases aus Spec 5.3 (23 s für 131.000 Zeichen `[` in Dart, Stack-Überlauf in Markdown); D2 erbt die Graph-Kosten |

## 8. Empfehlung und offene Entscheidungen für Ralph

**Empfehlung: A, lassen.**
- Auf den Zeugen gewinnt difftastic nichts: stepper.dart und `f(a, b)` → `f(b, a)` bekommen dieselben Wortmarken, Fallbacks bleiben bei jj.
- Auf echten Diffs zeichnete ein Bau auf 11,2 % der verglichenen Zeilen andere starke Marken; mehr als die Hälfte davon sind nur Leerzeichen, der Rest ist mal besser, mal schlechter.
- Als Programm (B) kostet `difft` pro Datei im Median etwa das 200- bis 320-fache von jj; das ist vor allem der Prozess (26–47 ms schon für eine winzige Datei). Was difftastic in-process kostet (C), misst die Probe nicht. In Ausreißern braucht `difft` Sekunden, und die meisten davon (55 der 66 Dateien über 1 s) enden ohnehin im Fallback.
- A bleibt bei den Marken der CLI. Jeder Bau hebt die Regel aus 5.2 auf, nach der die Segmente das sind, was `jj diff --git` unterstreicht.
- Ohne Bibliothek bleibt nur ein externes Programm mit instabilem Format.

**Falls doch:** B1 ist der kleinste Weg. `difft` bleibt optional (nur wenn installiert und eingeschaltet, etwa über jj's `ui.diff-formatter`), läuft nur für die angezeigte Datei und nur für Sprachen mit Parser, mit einem kleineren Graph-Limit und einem Zeitbudget von etwa 250 ms (deckt 94 % der Dateien); jj's Marken bleiben der Fallback.

**Offene Entscheidungen:**
1. Bauen oder nicht? A schließt Story 5.9 ohne Bau. Jeder Bau hebt die Regel aus 5.2 auf (Segmente = was `jj diff --git` unterstreicht).
2. Falls B: vom Nutzer installiert (B1) oder mitgeliefert (B2, +90 MB)? B2 braucht ein universelles oder zusätzlich ein x86_64-`difft`, weil `rust-toolchain.toml` für `aarch64-apple-darwin` und `x86_64-apple-darwin` baut; das Homebrew-Programm ist nur arm64. Welches Zeitbudget, welches Graph-Limit? Einschalten über jj's `ui.diff-formatter` oder eine eigene App-Einstellung? Dazu: Wie findet die App `difft`, wenn sie nicht aus einer Shell startet? Welche `difft`-Versionen nimmt sie an, wenn sich das JSON ändern kann (die Probe nimmt nur 0.72.0)? Was gilt, wenn `ui.diff-formatter` ein anderes Programm oder Terminal-Argumente wie `--color=always` nennt? Wartet die Ansicht das Zeitbudget ab, oder zeigt sie erst jj's Marken und tauscht sie danach?
3. Lizenzen: Die in `difft` mitgelieferten Parser (B2) und difftastics übrige Crates (C) sind nicht einzeln geprüft. Vor einem Bau prüfen.
4. Falls D: welche Sprachen, und welche Grenzen gegen tree-sitters Worst Cases? D2 ist die einzige Option, die Verschiebungen markieren könnte. Wie oft verschobener Code oder vertauschte Argumente in echten Diffs vorkommen, misst die Probe nicht.
5. Der Zeuge „`f(a, b)` → `f(b, a)` markiert die Verschiebung“: streichen, oder an einen Diff mit Verschiebungen (D2) binden. difftastic erfüllt ihn nicht. Ebenso der Zeuge „Ralphs `stepper.dart`-Beispiele behalten ihre Marken“: Er gilt für die Wortmarken; gezeichnet verlöre ein Bau auf 3 der 9 Zeilen die gefüllte Einrückung (Abschnitt 5).

## 9. E2: Zeilen paaren vor jj's Wortdiff (gebaut 2026-11-12)

**Entscheidung:** Ralph wählte am 2026-11-12 Option E2 (epics.md, Story 5.9, Entscheidungsnotiz). Gebaut im Abschlusslauf der Story 5.9 (`crates/zanshin-jj/src/line_pairs.rs`), gemessen mit derselben Probe. Die Probe übersetzt diese Datei selbst, misst also den Produktcode. Gemessen wurde `line_pairs.rs` mit `git hash-object` `15ddbd3902b9068efce3d7e4deee3a6e264183fa`; ändert sich die Datei, gelten die Zahlen nicht mehr ohne neuen Lauf. Alle Ausgaben stehen wörtlich im README der Probe, Abschnitt „Results of the E2 run“.

**Was E2 tut:**
- jj's Zeilen-Hunks bleiben, wie `unified_diff_hunks` sie liefert. Nur die Wortmarken eines geänderten Blocks (entfernte Zeilen, dann hinzugefügte) ändern sich.
- Die Zeilen eines Blocks werden nach Ähnlichkeit gepaart, in ihrer Reihenfolge: eine Zeile mit einer, oder eine Zeile mit bis zu 8 aufeinanderfolgenden Zeilen der anderen Seite (ein umgebrochener Aufruf, zusammengezogene Zeilen).
- Ähnlichkeit = 2 · behaltene Tokens / Tokens beider Seiten. Ein Token ist ein Wort oder ein einzelnes Nicht-Wort-Zeichen ohne Leerraum, so wie jj-libs Wortdiff zerlegt; jedes zählt 1, gleich wie lang. „Behalten“ ist, was `ContentDiff::by_word` auf der Gruppe gleich lässt. Gepaart wird nur über 50 %. Ein geänderter Bezeichner ist so eine Änderung, egal wie lang: `a.functionWizard_save,` → `a.functionWizard_next,` behält 3 von 4 Tokens je Seite (75 %) und paart.
- Jedes Paar bekommt jj-libs Wortdiff. Eine Zeile ohne Partner wird ein einziges geändertes Segment, also nur die schwache Füllung (10.32).
- Die Suche einer Datei darf höchstens `MAX_PAIRING_WORK` (262.144) Bytes durch die bewertenden Wortdiffs lesen. Ist das Budget aufgebraucht, behalten der Block und alle späteren jj's Wortmarken über den ganzen Block; ein Block, dessen 1:1-Kandidaten allein mehr lesen würden, als übrig ist, wird gar nicht erst durchsucht.

**Zeugen** (Probe `witness`, Rust-Tests in `hunks.rs`):
- Ralphs Beispiel, sein Hunk wörtlich (`widget-test-rename`; in der Probe in einen kleinen Dart-Rahmen gesetzt, damit difft ihn parst): 3 entfernte gegen 16 hinzugefügte Zeilen. Beide Kommentare sind nur schwach gefüllt. Der alte Test paart mit seinem umbenannten Gegenstück (93 %, mit dem Phone-Test wären es 86 %), also markiert dieser nur ` on a tablet`; der neue Phone-Test ist eine Folge neuer Zeilen. Heute markiert jj fast jedes Wort beider Kommentare und beider Testnamen. Gegen difft: dieselben Wortmarken auf allen 19 Zeilen (heute 16), gezeichnet gleich auf 18 (heute 15).
- stepper.dart: dieselben Wortmarken wie heute und wie difft. Der Aufruf über drei Zeilen paart als eine Gruppe aus einer und drei Zeilen und bleibt wie heute. Beim Kommentarbeispiel füllt E2 die Einrückung vor `padding:` nicht mehr; gezeichnet gleich mit difft auf 7 statt 6 der 9 Zeilen.
- Die E/A-Matrix der Spec gilt: `s.functionWizard_save` → `saveLabel`, `a.functionWizard_save` → `a.functionWizard_next` (nur der Name) und `1` → `2` sind gepaart und genau so markiert. Der erste Bau maß die Ähnlichkeit in Zeichen; damit blieb die mittlere Zeile bei 14 % ungepaart. Deshalb zählt die Ähnlichkeit Tokens.

**Echte Diffs** (dieselben 2.536 Dateien und 96.295 Zeilen ohne difft-Fallback; difft lief auf 8 Threads, seine Marken sind dieselben). Die heutigen Zahlen gegen difft reproduzieren Abschnitt 6 genau.

| | Wortmarken | gezeichnet |
|---|---:|---:|
| heute anders als difft | 4.755 (4,9 %) | 10.812 (11,2 %) |
| E2 anders als difft | 5.148 (5,3 %) | 10.332 (10,7 %) |
| heute anders, E2 gleich | 1.124 | 1.903 |
| heute gleich, E2 anders | 1.517 | 1.423 |
| Netto-Änderung der heutigen Lücke | −8,3 % | 4,4 % |

- **Methode:** Gegen E2 nimmt difft in Kommentaren und Strings E2's Wortmarken, nicht die heutigen (Abschnitt 4, Regel 3, mit E2 an jj's Stelle). Sonst trüge der Vergleichswert genau die Streuung, die E2 entfernt.
- Die Netto-Änderung ist (heute − E2) / heute: Zeilen, die E2 zu difft's Marken bringt, minus Zeilen, die es davon wegnimmt. Gezeichnet verkleinert E2 die heutige Lücke zu difft netto um 4,4 %; bei den Wortmarken liegt es netto 8,3 % weiter weg als heute. 3.189 der 5.148 abweichenden Zeilen markiert E2 ganz: Zeilen ohne Partner, die difft als unverändert oder nur teilweise geändert sieht, weil es Tokens über Zeilengrenzen hinweg zuordnet. Beispiele im README: umbrochene Listen von `JJ_*`-Codes; auf `=>` umgestellte Funktionen (`void showDefault() => show(…);`: E2 die ganze Zeile, difft nur `=>` und `show`).
- Wo E2 die Lücke schließt: Zeilen, in die jj's Blockdiff Wörter anderer Zeilen zog, etwa `return _worker.selectTree(…, files: files{+, from: from+});` statt der ganzen Zeile.

**E2 gegen heute** (alle 115.515 geänderten Zeilen): dieselben Wortmarken auf 92,2 %. E2 markiert mehr auf 5,0 % (meist ganze Zeilen ohne Partner), weniger auf 1,8 %, anders auf 1,0 %. Gezeichnet füllt E2 auf 5,4 % weniger (keine Streuung, weniger gefüllte Einrückung) und auf 1,5 % mehr.

**Kosten pro Datei** (in-process; bei E2 nur die Paarung, zusätzlich zu jj):

| | jj Dart | E2 Dart | jj Rust | E2 Rust |
|---|---:|---:|---:|---:|
| Median | 0,1 ms | 0,0 ms | 0,2 ms | 0,1 ms |
| p90 | 0,5 ms | 0,5 ms | 0,7 ms | 0,5 ms |
| p99 | 1,3 ms | 3,0 ms | 1,5 ms | 3,4 ms |
| Maximum | 3,4 ms | 15,0 ms | 2,9 ms | 13,1 ms |

- Das Budget lief in 9 von 2.536 Dateien aus; dort behalten die übrigen Blöcke jj's Wortmarken.
- `limits`: Zwei Eingaben, die das Budget ausschöpfen, brauchen 18,0 ms (ein Block, dessen Zeilenpaare alle dieselben Tokens haben) und 21,2 ms (20 Blöcke aus je 28 einzeiligen Aufrufen, auf ein Argument je Zeile umgebrochen; mit der früheren Grenze je Block 3,15 s). Die langsamste gemessene Datei ist eine andere: 20.000 Anweisungen, jede 10. geändert (2.000 kleine Blöcke, die je wenig lesen) brauchen 23,7 ms bei jj's 16,5 ms; ihre Kosten wachsen mit der Datei, wie jj's eigener Diff. Blöcke, die nicht ins Budget passen: unter 1 ms. Der ganze jj-Prozess mit E2 belegt höchstens 41 MB.
- **So wurde die Grenze gesetzt:** Der erste Bau maß die Ähnlichkeit in Zeichen und begrenzte jeden Block für sich (seine 1:1-Lesezugriffe). Mit der Schranke der Spec (`200 · min(links, rechts) − 50 · beide Seiten`) lag E2's p99 dort bei 12–13 ms, und eine kleinere Grenze half kaum (64 KiB: 10–12 ms). Die langsamen Dateien enthalten gewöhnliche Blöcke aus einigen Dutzend unähnlicher Zeilen; dort schließt diese Schranke nichts aus, fast jeder Kandidat lief durch den Wortdiff. Eine zweite Schranke begrenzt die behaltenen Tokens auf die Tokens, die die Zeilen einer Gruppe teilen (Wörter und einzelne Nicht-Wort-Zeichen, jedes Vorkommen einmal). jj-libs Wortdiff behält nur ganze gleiche Wörter und gleiche Einzelzeichen, also ist sie eine obere Schranke, und das Überspringen ändert kein Ergebnis. Geprüft auf allen 2.536 Dateien mit Debug-Assertions (`behalten ≤ Schranke`), mit Zeichen und erneut mit Tokens; die Zählungen blieben gleich. Ein Review fand dann die Grenze je Block über mehrere Blöcke hinweg unbegrenzt und blind für Läufe (eine Datei aus 20 umgebrochenen Aufrufblöcken: 3,15 s). Seitdem ist sie ein Budget je Datei auf die Bytes, die die bewertenden Wortdiffs lesen; 256 KiB halten eine Suche, die es ganz nutzt, bei etwa 20 ms.

**Offene Punkte für Ralph:**
1. E2 erfüllt die Zeugen. Auf echten Diffs verkleinert es gezeichnet die Lücke zu difft netto um 4,4 % und liegt bei den Wortmarken netto 8,3 % weiter weg als heute. Behalten, oder die Regel weiter ändern? Jede Änderung braucht einen neuen Lauf der Probe.
2. Mit `-w` / `-b` paart E2 in den Blöcken, die der Modus übrig lässt; die Wortmarken selbst ignorieren Leerraum nicht (Story 10.33 prüft das).

## Anhang: Belege

**difftastic 0.72.0** (Tag `0.72.0`, github.com/Wilfred/difftastic; installiert: `/opt/homebrew/Cellar/difftastic/0.72.0`, gebaut aus `archive/refs/tags/0.72.0.tar.gz`)
- `Cargo.toml`: kein `[lib]`, `[[bin]] difft`; tree-sitter 0.26.10; `tree-sitter-rust-orchard` 0.16.6, `tree-sitter-dart-orchard` 0.5.0; jemalloc außer auf Windows, illumos, FreeBSD.
- `src/options.rs`: `DEFAULT_BYTE_LIMIT` 1.000.000, `DEFAULT_GRAPH_LIMIT` 3.000.000, `DEFAULT_PARSE_ERROR_LIMIT` 0; JSON nur mit `DFT_UNSTABLE`; `--strip-cr` an.
- `src/main.rs`: Prüfreihenfolge gleiche Bytes → Sprache → Byte-Limit → Parse-Fehler → Graph-Limit; `\r` wird vor dem Parsen entfernt; keine Threads, kein Timeout für ein Dateipaar.
- `src/diff/shortest_path.rs`: `shortest_vertex_path` bricht ab, sobald mehr Knoten gesehen sind als das Graph-Limit (`ExceededGraphLimit`).
- `src/parse/syntax.rs`: `MatchKind` mit `NovelWord` und `UnchangedPartOfNovelItem` für geänderte Kommentare und Strings; `is_novel()` zählt beide.
- `src/parse/tree_sitter_parser.rs`: Parse-Fehler zählen nur `is_error()`; Byte-Limit vor dem Parsen; kein Timeout.
- `src/display/json.rs`: `File`, `Status`, `Line`, `Side`, `Change { start, end, content, highlight }`; nur neue Spannen (`is_novel()`); `Highlight` ohne Wert für unveränderte Wörter.
- README: Die Reihenfolge zählt immer (`set(1, 2)` gegen `set(2, 1)`); die Parser in `vendored_parsers/` stehen unter MIT oder Apache. Dass es nur ein Programm ist, belegt `Cargo.toml`, nicht das README. CHANGELOG: 0.69 nachgestellte Kommas in Rust bedeutungslos; 0.72 Verilog und F# wegen der Größe entfernt.
- Issue #12 (geschlossen 2021-07-18), PR #231 (offen seit 2022-04-03).

**Alternativen:** diffsitter v0.9.0 (`Cargo.toml`, `README.md`, `src/diff.rs`); crates.io: `difftastic-lib` 0.0.2, `baz-difftastic` 0.53.4 (GPL-2.0), `mergiraf` 0.20.0 (GPL-3.0-only), `tree-sitter-rust-orchard` 0.16.6 und `tree-sitter-dart-orchard` 0.5.0 (MIT).

**jj:** jj-lib 0.47.0 `src/diff_presentation/unified.rs` (`unified_diff_hunks`), jj-core 0.47.0 `src/diff.rs` (`ContentDiff::for_tokenizer`), `docs/config.md` @ v0.47.0 (`ui.diff-formatter`), `docs/conflicts.md` @ v0.47.0 (Marker-Stile). **Zanshin:** `crates/zanshin-jj/src/hunks.rs` (`Hunk`, `Segment`, `hunk_line`, `DiffReader::file`, `DiffOptions.whitespace`), `schemas/envelope.fbs` (`HunkLine.segments`), `app/lib/src/features/graph/inspector_diff.dart` (`diffWordMarks`), `app/lib/src/features/graph/graph_inspector.dart` (Zusammenfassung, dann eine Datei), `app/lib/src/features/undo_timeline/operation_changes.dart` (`_diffOf`), `packages/zanshin_core/lib/src/worker/handle.dart` (`diff(whitespace:)`), `app/widgetbook/folders/graph.dart` (`_DemoDetails`), `rust-toolchain.toml` (beide macOS-Ziele), Commit `e8e8297f`, Spec 5.3.

**Probe:** `spikes/structural-diff-probe/` (README: Methode, Befehle, alle Ausgaben wörtlich). Läufe vom 2026-11-12: `witness`, `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009`, `limits`, `parse-check --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009`. E2-Läufe (Abschnitt 9) vom selben Tag: `witness`, `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009 --jobs 8`, `limits`.

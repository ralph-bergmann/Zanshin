# Commit-Graph-View: Virtualisierung, Scroll-Extents, Lazy Loading

**Datum:** 2026-09-26 · **Anlass:** Konsolensession mit Ralph zum Mockup der Hauptansicht (Commit-Karten an (Zeile, Lane), Linien mit Ellbogen, Scrollen in beide Richtungen)
**Fragen:** Wie baut man die Ansicht performant ohne ListView? Ist die Virtualisierung schwer nachzubauen? Wie berechnet man die Größe für die Scrollbalken, wenn nicht alles gerendert und nicht alle Commits geladen sind?
**Methode:** Drei Agents haben die Flutter-Framework-Quellen (SDK 3.49.0-1.0.pre-96, master, 2026-09-23), jj-lib 0.44.0 (vendored) samt jj-CLI @ v0.44.0 und `zanshin-graph` gelesen und mit Datei:Zeile belegt. Ein vierter hat einen Proof-of-Concept gebaut und getestet, ein fünfter ihn adversarial reviewt. Die jj-Zahlen stammen aus Release-Benchmarks auf der 10k-Fixture.
**Folge-Stories:** 4.10–4.12 (Graph-Backend, Epic 4 wieder geöffnet) und Epic 10 (UI, Stories 10.0–10.12), siehe `epics.md` und `sprint-status.yaml`.
**Mockup:** `_bmad-output/planning-artifacts/research/commit-graph-mockup-2026-09-26.webp`
**POC im Repo:** `app/lib/main4.dart` + `app/lib/src/features/graph_poc/` + `app/test/features/graph_poc/` (Start: `flutter run -d macos -t lib/main4.dart` aus `app/`).

---

**Kurz:** Das Bauchgefühl gegen ListView stimmt, aber nicht wegen der Performance. Virtualisieren ist einfach, solange die Geometrie nur aus den Daten folgt. Dann muss man nichts messen, und die Scrollbalken stimmen exakt, bevor eine einzige Karte gebaut ist. Der eigentliche Grund gegen ListView steht in Abschnitt 2.

## 1. Warum ListView „schwer“ wirkt und ein eigener View nicht

ListView kennt ihre Gesamthöhe nicht, sie **schätzt** sie: Durchschnittshöhe der gerade gebauten Kinder mal Restanzahl (`_extrapolateMaxScrollOffset`, widgets/sliver.dart:1129).
- Deshalb springt der Scrollbalken bei unterschiedlich hohen Einträgen.
- Ohne `itemCount` ist die Höhe unendlich, und es gibt gar keinen Scrollbalken (scrollbar.dart:654).

Hier ist es einfacher, weil Zeilenhöhe und Lane-Breite fest sind:
- **Sichtbare Zeilen:** `first = floor(top / rowH)`, `last = ceil(bottom / rowH) - 1`. Das ist reine Rechnung, keine Suche.
- **Inhaltsgröße:** Höhe = Zeilenzahl × Zeilenhöhe, Breite = (größte Lane + 1) × Lane-Breite. Beides geht per `applyContentDimensions` an den Scroll-Offset.
- **Scrollbalken:** `RawScrollbar` rechnet nur mit diesen Zahlen (ScrollMetrics) und braucht keine gemessene Karte.

Die Grundregel: **Zeilenhöhe nie aus dem Layout messen**, immer aus den Daten ableiten. Also Karten mit fester Höhe und Text mit Ellipsis, wie im Mockup.
- Braucht das „Time“-Layout Tagestrenner mit eigener Höhe: kumulierte Zeilenpositionen (`Float64List rowTop[n+1]`) und binäre Suche. Bei 100k Zeilen sind das rund 800 KB.
- Die Zeit-Spalte links wird im Viewport horizontal fix gemalt, sie scrollt also nicht seitlich mit.
- „Detailed cards“ und „Card width“ sind globale Werte. Die Größen lassen sich damit sofort neu berechnen, aber die Scrollposition muss dabei an einem Commit hängen bleiben (Abschnitt 5).
- **Nachtrag (beim Schreiben der Stories aufgefallen):** Im Mockup sortiert „Time“ die Zeilen nach Zeit statt in `jj log`-Reihenfolge (`pl`, einziger Parent von `ov`, steht unter `uw`/`vt`) und packt teils zwei Commits in eine Zeile (`tn`+`kx`, `xy`+`lp`). Beides hat kein CLI-Gegenstück und wäre ein eigener Layout-Pass im Backend. Offene Designfrage in Story 10.2 (Empfehlung: `jj log`-Reihenfolge, Zeitspalte nur als Beschriftung).

## 2. Der eigentliche Grund gegen ListView: sie scrollt nur in eine Richtung

Steckt man eine vertikale in eine horizontale Scroll-Ansicht, **sperrt das macOS-Trackpad pro Geste eine Achse**. Beide Scroll-Erkenner konkurrieren um dieselbe Geste. Wer zuerst 18 px auf seiner Achse zurücklegt, bekommt die ganze Geste samt Nachschwingen (gestures/monodrag.dart:672-711). Diagonal scrollen geht dann nicht.

Flutter hat dafür seit 3.13 einen passenden Baustein: `TwoDimensionalScrollView` mit einem eigenen `RenderTwoDimensionalViewport`. Im Kern schreibt man nur `layoutChildSequence()`:
- Es muss kein volles Raster sein. Genau eine Karte pro Zeile an `ChildVicinity(xIndex: lane, yIndex: row)` ist erlaubt.
- Gebaut werden nur Zeilen im sichtbaren Bereich plus Puffer. Beim Scrollen werden vorhandene Karten wiederverwendet, nicht neu gebaut.
- `paint` darf man überschreiben: erst die Linien auf den Canvas, dann die Karten, so liegen die Linien dahinter.

**Empfehlung: Mischform.** Die Linien malt der Viewport selbst, die Karten sind Widgets, die erst beim Sichtbarwerden gebaut werden. Die Karte selbst kann eine RenderBox mit Text-Slots sein.

Eine Gegenprüfung hat „alles in einer einzigen RenderBox malen“ durchgerechnet: Das wäre nicht messbar schneller.
- Beim normalen Scrollen kosten Karten mit eigener RepaintBoundary praktisch nichts. Ihr Bild wird nur verschoben, weder neu gemalt noch neu gelayoutet.
- Nur beim Ziehen am Scrollbalken oder bei Sprüngen entstehen etwa 17 neue Karten pro Frame. Den Text müsste man dabei auch beim Selbermalen neu setzen.
- Alles selbst zu malen hieße dagegen, von Hand nachzubauen: Hover, VoiceOver, Fokus und Tastatur, Tooltips, Kontextmenüs, Rebase per Drag, Text kopieren.

Der Kern des POC (gekürzt und vereinfacht: `graph.rowCount` / `graph.laneOf(row)` stehen im POC als `graph.rows.length` / `graph.rows[row].lane`; vollständig in `app/lib/src/features/graph_poc/commit_graph_view.dart`):

```dart
@override
void layoutChildSequence() {
  final view = viewportDimension, content = contentSize(graph); // nur aus Daten
  _applyExtent(verticalOffset, math.max(0, content.height - view.height));
  _applyExtent(horizontalOffset, math.max(0, content.width - view.width));

  final scroll = Offset(horizontalOffset.pixels, verticalOffset.pixels);
  final cached = EdgeInsets.symmetric(
    horizontal: _cacheFor(view.width), vertical: _cacheFor(view.height),
  ).inflateRect(scroll & view);
  final first = math.max(0, (cached.top / rowHeight).floor());
  final last = math.min(graph.rowCount - 1, (cached.bottom / rowHeight).ceil() - 1);
  for (var row = first; row <= last; row++) {
    final lane = graph.laneOf(row);
    final rect = cardRect(row, lane);
    if (!rect.overlaps(cached)) continue; // Lane horizontal außerhalb
    final child = buildOrObtainChildFor(ChildVicinity(xIndex: lane, yIndex: row));
    if (child == null) continue;
    child.layout(BoxConstraints.tight(rect.size), parentUsesSize: true);
    parentDataOf(child).layoutOffset = rect.topLeft - scroll;
  }
}

@override
void paint(PaintingContext context, Offset offset) {
  // Eigener Clip: das Basis-paint() bricht ohne Kinder ab, _paintChildren ist privat.
  _clipLayer.layer = context.pushClipRect(needsCompositing, offset, Offset.zero & size,
      (ctx, o) {
    _paintEdges(ctx.canvas, o - _scroll); // nur sichtbare Zeilen, ein Path pro Farbe
    for (var c = firstChild; c != null; c = childAfter(c)) {
      final d = parentDataOf(c);
      if (d.isVisible) ctx.paintChild(c, o + d.paintOffset!);
    }
  }, clipBehavior: clipBehavior, oldLayer: _clipLayer.layer);
}
```

**Messwerte** (Fenster 800×600, 100 000 Zeilen):
- 13 Karten existieren gleichzeitig, nach einem Sprung zu Zeile 50 000 sind es 16.
- Die Scrollhöhe ist exakt 100 000 × 56 − 600.
- Klicks landen in der richtigen Karte.
- Die Linien sind pro Farbe gebündelt, abgeschnitten und liegen hinter den Karten.
- `flutter analyze` ist sauber, alle 7 Widget-Tests laufen durch.

## 3. „Wie groß ist das Ganze, wenn noch nicht alle Daten geladen sind?“

**Geometrie** (wo steht was) von **Inhalt** (was steht auf der Karte) trennen. Bei jj ist der Unterschied riesig (Release-Build, 10k-Fixture):

| Schritt | 10 002 Zeilen |
|---|---|
| Revset zählen (`count_estimate`, im Release-Build exakt) | ~0,1 ms |
| Topologie durchlaufen (nur Commit-Index) | ~3,3 ms |
| zusätzlich pro Zeile das Commit laden | ~1,17 s |
| `collect_lanes` heute | ~1,22 s |

Die Fixture enthält nur lose Git-Objekte, in einem gepackten Repo können die Werte anders ausfallen.

Die Lane einer Zeile hängt von allen Zeilen davor ab, Zeile k lässt sich also nicht ohne 0 bis k−1 berechnen. Daraus folgt:
1. **Geometrie komplett laden:** Lanes, Kanten und Farben für alle Zeilen in einem billigen Durchlauf, der nur den Index liest. Damit sind Höhe und Breite sofort exakt, und „Scroll to @“ ist ein einfaches Nachschlagen.
2. **Inhalt nachladen:** Beschreibung, Autor, Zeit, empty/conflict brauchen das Commit-Objekt. Die werden für die sichtbaren Zeilen plus Puffer nachgeladen, bis dahin zeigt die Karte einen Platzhalter.
   - Change-ID, Bookmarks, Tags, immutable und Präfixlängen kommen ohne Commit-Objekt aus und können schon in den ersten Durchlauf.

Wird selbst die Topologie einmal zu groß, gibt es einen Notbehelf: Eine ausgegebene Zeile ändert sich nie mehr. Die Höhe kann also mit dem Nachladen einfach wachsen, und der Scrollbalken-Daumen wird dabei kleiner. Ein Ziehen ans Ende ergibt dann aber keinen Sinn mehr. Für jj ist das selten nötig: Das Default-`revsets.log` wächst per Definition mit der veränderbaren Arbeit, nicht mit der History. Groß wird nur `all()`, wie im Mockup.

## 4. Was das für den Rust/FFI-Teil heißt

- **Metadaten werden inline geladen:** `walk_graph` lädt pro Zeile das ganze Commit (`crates/zanshin-jj/src/graph.rs:231`).
  - Das ergibt 1,2 s bei 10k Zeilen. Das weiche FR-GR-5-Budget (< 1 s) ist für `all()` damit knapp verfehlt.
  - Die ~3 ms in `benches/graph_blueprint.rs` gelten seit Story 4.8 nicht mehr.
- **Die Trennung ist strukturell einfach:** `LogMetaIndex::extract` existiert schon separat, und `Row.meta` ist schon ein `Option`. Nötig wären:
  - eine neue `extern fn` samt Tabelle für die angefragten Commit-IDs;
  - die Regel „meta fehlt genau bei synthetic-Zeilen“ zu lockern;
  - **beide Aufrufe an dieselbe Operation zu binden** (`RepoLoader::load_at`). Sonst liefern zwei Aufrufe keinen einheitlichen Repo-Zustand mehr.
  → **Story 4.10**
- **`Row` reicht für die Ellbogen im Mockup nicht ganz:** Die Doku behauptet, eine Zeile lasse sich komplett ohne ihre Nachbarn zeichnen (`crates/zanshin-graph/src/lane.rs:169`). Das stimmt für durchlaufende Linien und die untere Hälfte, aber nicht für die obere.
  - Es fehlt, welche Lanes von oben in den Knoten münden, also der Ellbogen direkt über der Parent-Karte.
  - Es fehlt auch, ob die eigene Lane von oben kommt oder ob der Commit ein Head ist.
  - Mit Blick auf eine Zeile zurück lässt sich das ableiten: `incoming(i) = (active(i-1) ∪ targetLanes(i-1)) \ active(i)`.
  - Sauberer wäre es, die Liste mitzuliefern, die `place()` ohnehin schon hat (`lane.rs:326`).
  → **Story 4.11** (Rust-Zeilenmodell), auf dem Draht dann **Story 4.12**
- **Breite:** größter Wert über `lane` **und** `target_lane`. Eine Merge-Lane kann sich schließen, ohne je einen eigenen Knoten zu tragen.
- **Dart wandelt alles sofort in Objekte um** (`packages/zanshin_core/lib/src/ffi/graph.dart:373`), und die Bytes werden zusätzlich zweimal kopiert.
  - Für 100k Zeilen besser: den FlatBuffer als Ansicht behalten, ohne Objekte zu bauen, oder die Geometrie als Typed-Arrays liefern.
  - `active_lanes` wächst mit Zeilen × Graphbreite. Segmente `(lane, startRow, endRow, kind)` wüchsen nur mit der Zahl der Kanten.
  → **Story 4.12**

## 5. Fallstricke aus POC und Gegenprüfung

Der POC im Repo enthält diese Punkte absichtlich **noch nicht**. Sie sind Akzeptanzkriterien der Epic-10-Stories.

- **Keine Scrollbalken:** `TwoDimensionalScrollView` baut keine (flutter#122348), man muss zwei selbst drumlegen. Beide Achsen melden sich auf derselben Ebene, der Filter muss also zusätzlich `metrics.axis` prüfen.
- **Keys auf Karten wirken nicht:** Der Standard-Delegate umhüllt jede Karte mit einer RepaintBoundary und übernimmt den Key nicht nach außen. Welche Karte welchen Zustand bekommt, hängt dann an der Position (lane, row).
  - Nach jedem jj-Reload springen Fokus, Hover und Auswahl deshalb auf andere Commits (gemessen: 17 von 17 Karten verlieren ihren State).
  - Abhilfe: eigener Delegate, oder `addRepaintBoundaries: false` und `RepaintBoundary(key: ValueKey(changeId), …)` ganz außen.
- **`shouldRebuild` ist beim Standard-Delegate immer `true`:** Jeder Rebuild des umgebenden Widgets (Hover, Auswahl) baut alle Karten neu (gemessen: 13 Builds pro setState, mit eigenem `shouldRebuild` 0). Abhilfe: eigener Delegate mit echtem `shouldRebuild`, Auswahl und Hover gelangen per Listenable zu den Karten.
- **Scrollposition an einem Commit verankern:** jj berechnet den Graph nach jeder Operation neu (ADR-0002). Die Pixelposition bleibt gleich, die Zeilen verschieben sich, und der Inhalt springt unter dem Nutzer weg.
  - Abhilfe: Change-ID der obersten sichtbaren Zeile plus Versatz merken und nach dem Reload mit `verticalOffset.correctBy(...)` korrigieren.
  - Dafür braucht es eine Zuordnung Change-ID → Zeile, die auch „Scroll to @“ nutzt.
- **VoiceOver** hält die vorgebauten, unsichtbaren Karten für sichtbar. Abhilfe: `describeSemanticsClip` und `describeApproximatePaintClip` überschreiben.
- **Linienfarbe:** Durchlaufende Linien nach dem `colorIdx` der Kante färben, die sie eröffnet hat, nicht nach der Lane-Nummer, denn Lanes werden wiederverwendet.
- **Horizontal:** Linien auch seitlich auf den sichtbaren Bereich beschränken. `DiagonalDragBehavior.weightedEvent` fühlt sich näher an macOS an als `free`.
- **Hit-Testing:** Das Basis-`hitTestChildren` läuft in Einfügereihenfolge, nicht in umgekehrter Malreihenfolge. Das ist egal, solange sich Karten nie überlappen. Klicks auf Linien oder Zeilenlücken treffen nichts (`hitTestSelf` ist false).
- **Deprecation:** In unserer SDK (3.49 master) ist `cacheExtent` veraltet, der Nachfolger heißt `scrollCacheExtent`.

---

## Anhang: Belege (Auswahl)

Pfade unter `flutter/packages/flutter/lib/src/`, sofern nicht anders angegeben.

**Flutter**
- ListView-Extent geschätzt: `rendering/sliver_list.dart:299-311`, `widgets/sliver.dart:1129-1143`; ohne `childCount` unendlich: `widgets/sliver.dart:1153-1156`; kein Scrollbalken bei unendlichem Extent: `widgets/scrollbar.dart:654-659`. Exakter Extent ohne Messen über `SliverChildDelegate.estimateMaxScrollOffset`: `widgets/scroll_delegate.dart:167-179`.
- macOS-Trackpad kommt als `PointerPanZoom*` an (Momentum verworfen): `engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterViewController.mm:606-626`. Achsen-Lock verschachtelter Scrollables: `gestures/monodrag.dart:672-720`, `gestures/arena.dart:226-240`, kTouchSlop 18: `gestures/constants.dart:65`. Mausrad: jedes Event scrollt genau eine Achse (`widgets/scrollable.dart:955-971`).
- 2D-API: einziger abstrakter Einstieg `layoutChildSequence` (`widgets/two_dimensional_viewport.dart:1302-1352`); sparse Kinder zulässig (`:1415-1435`); `paint` überschreibbar (`:808-859`); Basis-`paint` clippt nur bei `_hasVisualOverflow` und kehrt ohne Kinder früh zurück (`:1640-1668`); keine Scrollbalken (`widgets/scrollable.dart:2145-2148`, TODO #122348); `DiagonalDragBehavior` (`widgets/scrollable.dart:1799-1824`, `:2229-2363`). Seit Commit 0f1a95d19ee (2023-05-26), erste Stable 3.13.0.
- Scrollbalken rein aus ScrollMetrics: `widgets/scrollbar.dart:400-482`, `widgets/scroll_position.dart:641-682`.
- Keine Neuarbeit beim Scrollen: Relayout-Kurzschluss bei gleichen Constraints (`rendering/object.dart:2894-2913`), Layer-Wiederverwendung für RepaintBoundaries (`rendering/object.dart:270-292`, `rendering/layer.dart:696-716`).
- Delegate-Keys werden nicht hochgezogen (`widgets/scroll_delegate.dart:1103-1128` vs. `:559-572` beim Sliver-Delegate); Element-Wiederverwendung nach Key/Vicinity (`widgets/two_dimensional_viewport.dart:359-372`); Delegate-Setter entscheidet über Rebuild (`:665-680`); kein `describeSemanticsClip` (vgl. `rendering/viewport.dart:883`, `:935`).

**jj-lib 0.44.0 / jj CLI v0.44.0**
- `Revset::count_estimate` (`revset.rs:3423-3427`); Produktion zählt exakt über alle Positionen, nur mit Feature `testing` `(10, None)` (`default_index/revset_engine.rs:196-213`) — Achtung: `zanshin-jj`-Tests laufen mit `testing`.
- `stream_graph` ist lazy und rein indexbasiert (`default_index/revset_engine.rs:136-144`, `default_index/revset_graph_iterator.rs:339-369`); `TopoGroupedGraph` zieht Eingabe nur bei Bedarf (`graph.rs:285-332`).
- `Store::get_commit` mit 100er-LRU (`store.rs:52`, `:156-173`); Git-Backend `read_commit` (`git_backend.rs:1233-1269`).
- CLI `jj log`: `take(limit)` nach Topo-Gruppierung, `--reversed` materialisiert, pro Zeile `get_commit_async` (`cli/src/commands/log.rs:225-241`, `:275`); Default-Revset `builtin_log()` (`cli/src/config/revsets.toml`).

**Zanshin**
- Commit-Load + Meta pro Zeile: `crates/zanshin-jj/src/graph.rs:201-241` (v. a. `:231-237`); `LogMetaIndex` einmal pro Walk: `crates/zanshin-jj/src/commit_meta.rs:110-213`.
- Lane-Semantik: `place()` gibt alle Reservierungen des Knotens frei, bevor `active_lanes` geschnappt wird (`crates/zanshin-graph/src/lane.rs:258-265`, `:325-335`); erste Nicht-Missing-Kante setzt die eigene Lane fort (`:339-352`); keine Obergrenze für Lanes (`:389-396`); `LaneAssigner` nicht `Clone`, Zeile k hängt vom ganzen Präfix ab.
- FFI: ein `extern fn zanshin_graph_slice` → `collect_lanes`, alles in einem `Envelope<GraphSlice>` (`crates/zanshin-ffi/src/graph.rs:199-212`, `:264-292`; `schemas/envelope.fbs:721-819`); `debug_assert` „meta fehlt genau bei synthetic“ (`crates/zanshin-ffi/src/graph.rs:137-142`).
- Dart: Bytes kopiert (`packages/zanshin_core/lib/src/ffi/request_bytes.dart:99-106`), eager dekodiert (`packages/zanshin_core/lib/src/ffi/graph.dart:373-433`).
- Veraltete Zahlen: `crates/zanshin-jj/benches/graph_blueprint.rs:18-19` (topologie-only), als veraltet vermerkt in `_bmad-output/implementation-artifacts/epic-4-context.md:26`.

---

## Nachtrag 2026-09-26 (Nachmittag): HTML-Design und A/B-Test Rust vs. Dart

**Neues Design.** `_bmad-output/implementation-artifacts/design/JJ Desktop Client.html` (Quellen `graph-view.jsx`, `graph-data.js`, `graph.css`) ist laut Ralph „nah am finalen Design“ und ersetzt das Mockup. Die wichtigste Änderung: **mehrere Commits teilen sich eine Zeile.**
- *Compact*: Zeile = Abhängigkeitstiefe, Root unten.
- *Time*: Zeitbuckets.
- Lanes kommen aus einer eigenen gierigen Intervall-Packung, Kanten sind orthogonale Polylinien mit runden Ecken, Kreuzungs-„Hops“ und gemeinsamen Bussen.

Die Viewport-Mechanik aus Abschnitt 1–5 gilt weiter: Geometrie nur aus Daten, exakte Extents, Linien vom Viewport gemalt, Karten lazy. Es gibt aber zwei Unterschiede:
- Aus „eine Karte pro Zeile, Zeilenindex = Stream-Index“ wird „Knoten mit (Zeile, Spalte) bzw. freiem y“. Sichtbare Knoten findet man über einen nach y sortierten Index (binäre Suche).
- Die bisherigen Stories 4.11/4.12 (Landing-Lanes im `jj log`-Zeilenmodell) sind für diese View obsolet.

**Der Layout-Algorithmus des Prototyps skaliert nicht.**
- `optimizeLanes`: bis 7! Permutationen × O(E²) Kreuzungszählung.
- `blocked`: O(n²).
- `analyzeEdges`: O(E²).

Eine skalierbare, deterministische Fassung mit identischen Ergebnissen im Greedy-Modus steht in `spikes/graph-layout-ab/SPEC.md`. Sie läuft in O((n+E) log n) plus eine begrenzte Lane-Order-Suche und kennt die Modi `compact`, `time` und das neue, experimentelle `free` für zeitproportionale Abstände.

**A/B-Test** (`spikes/graph-layout-ab/README.md`): Dieselbe Spec wurde in Rust und in Dart implementiert.
- Auf 48 Kombinationen sind die Ausgaben byte-identisch; auch das Original-JS des Designs liefert auf den Design-Samples dieselben Ergebnisse.
- Rust ist etwa 3× schneller als Dart AOT. Rund die Hälfte davon ist Darts generischer Library-Sort; mit monomorphen Sorts sind es 1,2–1,9×.
- Bei realistischen Größen spielt der Unterschied keine Rolle:

| Eingabe | Laufzeit |
|---|---|
| Default-Revset | ≤ 0,25 ms |
| `all()` 10k | ≈ 2 ms |
| jj-eigene History (15,5k Commits, 16 Lanes) | 1–6 ms, unter einem Frame |

- Nur `optimized` bei 100k synthetischen Commits mit vielen Lanes überschreitet in Dart 100 ms.
- Speicher und Payload sind in beiden Varianten gleichwertig.
- Den Ausschlag gibt die Iteration. Eine Layout-Änderung in Rust kostet im Produkt ~6 s Release-Rebuild plus App-Neustart. Eine Dart-Änderung im Worker-Isolate lässt sich hot-reloaden (per VM-Probe verifiziert, am Zanshin-App selbst noch nicht gemessen).

**Empfehlung:** Layout in Dart im Worker-Isolate. Rust liefert die Topologie als FlatBuffers-Skalarvektoren. SPEC und Differential-Tools bleiben erhalten, damit ein späterer Rust-Port mechanisch bleibt. Die Entscheidung liegt bei Ralph.

**Wichtige Einschränkung für Time/Free:** Beide Modi brauchen die Committer-Zeitstempel **aller** Commits vor dem Layout. Der jj-Index hat keine Zeitstempel, also kostet das ~1,2 s bei 10k (Commit-Objekte laden, Loose-Object-Fixture). Das gilt in Rust und in Dart gleichermaßen und ist eine Produktfrage, keine Sprachfrage:
- Zeitstempel-Cache pro Commit-ID,
- Time/Free nur für kleinere Revsets,
- oder die Kosten beim ersten Laden akzeptieren.

---

## Nachtrag 2026-09-26 (Abend): Lane-Order, Zeitachse in Free, Sprünge, Minimap

Ralph hat den Wegwerf-Viewer des Spikes (`spikes/graph-layout-ab/viewer/`) auf einer Kopie eines echten Repos mit 1,4k Commits benutzt. Details stehen im Spike-README („Viewer“, „Lane order review 2026-09-26“).

**Free gefällt Ralph am besten**, vorläufig und ohne Entscheidung. Story 10.13 bleibt ein Experiment; ihr Status-Nachtrag listet, was offen ist: Default-Modus, Free-Konstanten, Busse hinter Karten, Lane-Order.

**Lane-Order.** `optimized` verschwendet Platz. Es gibt jeder ganzen Greedy-Lane eine Spalte für die gesamte History, aber Greedy belegt eine Lane nacheinander mit vielen unabhängigen Branches, und die Kostenfunktion hat keinen Breitenterm. Im echten Repo landet eine Lane, die nur 6,7 % der Zeit belegt ist, in Spalte 1, die beiden vollsten (94 % und 46 %) in Spalte 10 und 11.
- Die neue Order `compact` (SPEC §4.7, nur in Dart) tauscht Segmente zweier Spalten nur in lokalen Zeitfenstern. Ein Tausch bleibt nur, wenn Kreuzungen, horizontale Lauflänge und ein Breitenterm zusammen sinken.
- Auf `all()` des echten Repos gegenüber Greedy: 44–62 % weniger Kreuzungen, 21–28 % kürzere horizontale Läufe, im Mittel 3–14 % schmaler. `optimized` ist fast doppelt so breit.
- Kosten: ≈ 3 ms statt 0,2 ms pro Layout, ≈ 30 ms bei 10k. Ab 10k beschneidet das Budget die Suche: Auf synth-10k endet sie im Compact-Modus im ersten Durchlauf und bleibt breiter als Greedy; auf synth-100k bewegen sich nur die linken etwa zwölf Spalten.
- Nicht überall besser: Eine ~40 Pitches lange Stelle zeigt wieder das Muster aus Ralphs Screenshot, weil ein Segment unteilbar ist.
- Empfehlung: `compact` als Default, Greedy als Fallback, `optimized` streichen, aber erst, wenn Ralph es im Viewer angesehen hat (Story 4.11, Punkt 11 und offene Frage 8).

**Zeitachse in Free.** Free bekommt dieselbe Gutter-Leiste wie Time, mit einem Label pro Tag: „Today“, „Yesterday“, „Sep 24“ (mit `?lang=de` über `Intl`: „Heute“, „Gestern“, „24. Sept.“).
- Der Tag kommt aus der geklammerten Zeit T(i) = max(ts, T(Eltern)) des Layouts, nicht aus dem rohen Zeitstempel, denn nur T ist monoton in y. Mit rohen Zeitstempeln stünden bei synth-100k 418 von 2.951 Tageslabels in falscher Reihenfolge.
- Das Label sitzt auf der obersten Karte des Tages; der Tag am oberen Viewport-Rand bleibt angeheftet, bis das nächste Label ihn verdrängt.
- Vorschlag: 4.11 liefert die Tage als `day`-Buckets auch in Free (offene Frage 9 in 4.11). Das braucht datierte Nachträge zu SPEC §2, §3 und §7.3 I5, umgesetzt in `dart/` und in der Rust-Referenz vor den Goldens. Die Alternative sind sortierte (Zeile, Tag)-Paare neben dem Layout. So oder so formatiert die View nur (Story 10.2, Punkt 9). Die Sprache der Labels ist eine Designfrage (10.2 (c)).

**Sprünge (Go to commit)** wurden gemessen: 200 Sprünge zu zufälligen Knoten, auf dem echten Repo und auf synth-100k.
- Der Frame nach einem Sprung kostet unabhängig von der Distanz dasselbe: Median 3,4–3,8 ms Main-Thread, p95 5,7–6,7 ms (in einer Wiederholung bis 7,1 ms), |r(Distanz, Arbeit)| ≤ 0,08 bei Distanzen bis 5,4 M px. Der Sprung ist im ersten Frame nach dem Tastendruck sichtbar.
- Grund: Der Frame hängt nur vom Scroll-Offset ab. Eine binäre Suche findet die erste Karte, danach werden nur die sichtbaren Karten gebaut.
- Empfohlen ist deshalb ein sofortiger Sprung (`jumpTo`) statt `animateTo`: Ein animierter Scroll über 1,6 M px würde rund 2.000 Viewports an Karten bauen und verwerfen. Ob Go-to-change animiert und das Ziel auswählt, ist Designfrage 10.6 (d); Budget und Witness stehen in Story 10.6, Punkt 11.

**Minimap** (Ralphs Idee; der Viewer hat sie gebaut, um die Kosten zu messen): ein Raster des ganzen Graphen, einmal pro Layout über Differenz-Arrays und eine Präfixsumme (O(n + E + Pixel)), dazu ein Viewport-Rechteck als eigene Ebene; Klick und Ziehen springen.
- Raster: Median 1,4–3,9 ms bis 99k Knoten bei 222×1546 Gerätepixeln. Eine Wiederholung am selben Abend war etwa doppelt so langsam (Mediane bis 5,0 ms, eine synth-100k-Serie 5,7–7,9 ms).
- Scrollen mit Minimap kostet höchstens ~0,4 ms Main-Thread pro Frame mehr, innerhalb des Rauschens; kein Frame fiel aus.
- Im Produkt läuft das Raster außerhalb des UI-Isolates. Empfohlen ist ein `Isolate.run` auf App-Seite über den Layout-Arrays und den y-Werten des `VerticalLayout`: 4.11 bleibt frei von Pixeln, und der eine Worker-Isolate bleibt frei. Die Alternative, ein eigenes Worker-Kommando, bräuchte Nachträge zu 4.11, 10.5 und 10.12 (Designfrage 10.16 (f)).
- Die UI malt das Raster als `ui.Image` in einer eigenen `RepaintBoundary` und das Viewport-Rechteck als eigene Ebene. Neue Story 10.16 (Backlog, NEEDS DESIGN).

---

## Nachtrag 2026-09-27: Ralphs Entscheidungen nach dem Viewer

Ralph hat den Viewer auf dem echten Repo mit 1,4k Commits benutzt und entschieden, was das Produkt behält. Details stehen in `epics.md` (Epic 10, „Product decisions 2026-09-27“), im Spike-README („Product decisions 2026-09-27“) und in SPEC §12.

- **Layout:** Free ist der Default (das Design kennt Free nicht; sein Default ist Compact), Compact die einzige weitere Variante. Time und Time+gaps entfallen. Damit ist die Frage „feste Zeilen oder freies y“ entschieden: freies y. Folge: Das Default-Layout braucht die Zeitstempel aller Commits, deshalb wiegt offene Frage 1 von Story 4.10 (pro Aufruf laden oder cachen) schwerer.
- **Lane-Order:** `compact` ist der Default, Greedy die Alternative und der Fallback. `optimized` entfällt; im Design war es als „Min. crossings“ der Default. Die bekannten Grenzen von `compact` bleiben notiert: Auf rund 8 % der echten History (in Free) ist es breiter als Greedy, und ab etwa 10k Commits beschneidet das Budget die Suche.
- **Sprache der Labels:** Was da ist, bleibt vorerst: lokalisierbare Labels, Englisch als Default wie im Design; `?lang=de` liefert „Heute“, „Gestern“ usw. Ob die App nur Englisch bleibt oder übersetzt wird, ist offen, denn manche Begriffe klingen auf Deutsch vermutlich komisch.
- **Gewollte Abweichungen vom Design** (Entscheidungen aus dem Viewer, die Ralph behalten will):
  - Kreuzungslücken („Crossing gaps“) sind die einzige Option: immer an, kein „Plain“, kein Schalter.
  - Inhalt, der unter die Zeitleiste scrollt, wird ausgeblendet (Fade). Der Verlauf ist der der Time-Leiste im Design (GC:57); er lebt jetzt in der Tagesleiste von Free weiter.
  - Das Datum in der Zeitleiste bleibt beim Scrollen stehen („sticky“), bis das Label des nächsten Tages es verdrängt.
- **Kanten gehen oben mittig heraus** (nur notiert; der Viewer wird nicht geändert). Alle Kanten gehen schon unten mittig in die Kindkarte (Ralph ist es bei Merge-Commits aufgefallen), und Straight-Kanten und Merges verlassen die Elternkarte schon oben mittig. Nur Branch-offs verlassen sie seitlich versetzt (±0,28·W). Künftig verlassen alle Kanten die Karte oben mittig.
  - Das ändert nur die Pixelgeometrie (Story 10.4) und den Geometrietext in SPEC §4.5. Routenklassen und alle Layout-Ausgaben bleiben gleich, die Goldens auch.
  - Ein Branch-off teilt sich den Ausgang mit der First-Parent-Fortsetzung: ein T-Stück auf Bushöhe, ohne Brücke, weil der Punkt ein Endpunkt ist. Der Routen-Report nimmt den geteilten Stummel aus, wie jede Überlappung von Kanten mit gemeinsamem Knoten (etwa einen geteilten Bus).
  - Die Bookmark-Pille verdeckt keinen Ausgang mehr (Prototyp-Defekt 8). Blockierte Merges (D9) laufen weiterhin hinter Karten; das bleibt offen.
- **Story 10.13** hat damit ihr Ergebnis und wird als erledigt geführt (Claudes Einschätzung, nicht Ralphs Entscheidung); eine Flutter-Variante des Labors entsteht nur, wenn Ralph sie will.

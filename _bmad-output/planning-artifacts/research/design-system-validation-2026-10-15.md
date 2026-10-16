# Validierung: Design System nach der Controls- und Akzent-Runde

**Fortsetzung:** Runde 2 ist validiert in [`design-system-validation-round-2-2026-10-16.md`](design-system-validation-round-2-2026-10-16.md).

**Datum:** 2026-10-15 · **Gegenstand:** das neu heruntergeladene `_bmad-output/implementation-artifacts/design_system/` (uncommitted, Basis `HEAD` = `e74ced3`-Stand). Es ist die Antwort auf [`claude-design-prompt-controls-and-accents-2026-10-15.md`](claude-design-prompt-controls-and-accents-2026-10-15.md) und Ralphs fünf Folgeantworten.

**Methode:**
- Sechs Prüf-Agents mit je einer Linse, jede Linse von einem zweiten Agent adversarial nachgeprüft:
  - Prompt-Abdeckung;
  - Token-Integrität und 1:1-Umsetzbarkeit in Flutter;
  - Farbrechnung und macOS-Fakten (mit Swift-Probes auf macOS 27.0.1);
  - Komponenten-Zustände;
  - Icons;
  - Auswirkungen auf die Stories.
- In der Hauptsession:
  - alle 51 HTML-Seiten (Cards, Guidelines, UI-Kit) im Browser geladen und Konsole und Netzwerk geprüft;
  - die vier schwersten Befunde an der Quelle gegengelesen.
- **Folge-Prompt an Claude Design:** [`claude-design-prompt-ds-fixes-2026-10-15.md`](claude-design-prompt-ds-fixes-2026-10-15.md).

---

**Kurz:**
- **Claude Design hat fast alles geliefert, und das in hoher Qualität.**
  - **Prompt:** Jeder Punkt aus Teil A und Teil B ist umgesetzt, ebenso die Nebenbei-Fixes und Ralphs fünf Antworten. Viele Punkte nur mit kleinen Lücken.
  - **Zahlen:** Alle Kontrast-, ΔE- und Gamut-Angaben ließen sich nachrechnen.
  - **Tokens:** 321 Tokens lösen in allen 54 simulierten Konfigurationen ohne Lücke auf. Kein `color-mix()` und kein `oklch()` mehr außerhalb von Kommentaren, kein undefiniertes `var()`.
  - **Rendering:** 50 von 51 Seiten laufen fehlerfrei.
- **Fertig für die Umsetzung ist es trotzdem nicht.** Drei Dinge stehen noch aus:
  1. **Eine zweite Runde bei Claude Design.** Echte Fehler, keine Geschmacksfragen:
     - Die „Bewegung reduzieren“-Regel lässt den Flash verschwinden.
     - Die Ampel-Geometrie entspricht nicht macOS 26/27.
     - Unter erhöhtem Kontrast wird Hover schwächer als Ruhe.
     - Bei Gelb auf Paper ist die Progress-Füllung unsichtbar.
     - Das Modell für feldgebundene Listen widerspricht den Komponenten.
     - Dazu kommen veraltete Prompt-Texte und fehlende Tastatur-Angaben.
  2. **Ralphs Entscheidungen**, rund ein Dutzend (§3), davon vier wichtig.
  3. **Unsere Stories sind jetzt erheblich veraltet.**
     - 11.1 ist ein **Blocker**: Sie modelliert nur Night/Paper und vergleicht oklch-Werte. Sie rechnet mit Yaru als Basis und mit „Reduce motion = alles null“.
     - Etwa 60 % der `DS …:Zeile`-Zitate zeigen auf geänderte oder verschobene Zeilen.
     - Kein Story-Text kennt bisher die Control-Bibliothek, die Akzent-Familien, den erhöhten Kontrast oder die macOS-Textmarkierung.

## 1. Was nachweislich stimmt

**Tokens und Rechnung:**
- **Abdeckung:** Jeder Punkt aus Teil A1–A4, Teil B 1–7, „Nebenbei“ und Ralphs Antworten 1–5 ist umgesetzt. Die Belege stehen im Abschnitt „VERIFIED OK“ der Prüfberichte (Scratchpad).
- **Akzent-Familien:** Alle acht Familien plus Mehrfarbig haben in Night und Paper je acht feste Tokens. Gemessen:
  - Linien ≥ 3:1 auf Karte, Canvas und Lift (Minimum Paper-Orange 3.05 auf dem dunkelsten Canvas);
  - Ink auf Fill ≥ 5.35;
  - Akzent-Text auf der Karte ≥ 4.51.
  - Alle ΔE-Angaben der Readme-Tabelle lassen sich reproduzieren.
- **„Dieser Mac“:** Die Hue-Bänder sind exakte Mittelpunkte zwischen den Anker-Farbtönen. Graphit ist wirklich neutral (C = 0).
- **Textmarkierung:** Alle Messwerte stimmen. Die Swift-Probe auf macOS 27 bestätigt die Systemwerte: aqua #B3D7FF / #DCDCDC, darkAqua #3F638B / #464646.
- **Gamut:** Die vier Paper-Tokens sind jetzt sRGB-Hex und erreichen die angegebenen Kontraste (co 4.76, co-ink 4.57, co-text 7.51, conflict 5.53, warn 6.09).
- **Kontrast-Fixes:**
  - Danger-Hover ist jetzt eine Tönung, 4.72 statt 2.77.
  - Primary-Ring Paper 3.29.
  - Slider-Thumb Paper mit Kante 3.22.
- **Lade-Reihenfolge:** `styles.css` lädt fonts → colors → accents → states → typography → spacing → effects → contrast. Das löst alle Spezifitätsgleichstände richtig auf.
- **Getrennte Ebenen:** Akzent- und Kontrast-Ebene berühren disjunkte Tokens (14 und 25). Eine Matrix Theme × Akzent × Kontrast ist also nicht nötig.

**Bausteine:**
- Ein Zustandsmodell, eine Fokusregel, ein Disabled-Wert (.4), ein Gold-Primary-Rezept. Der Dialog-Eintritt ist einheitlich 220 ms. `--fl-gold` ist aufgeteilt in `--primary-action` / `--at-chrome`.
- Moon als Datenfarbe ist entkoppelt: `--status-m`, `--hunk`, `--hunk-bg`, `--remote`.
- Neue Controls, jeweils mit `.jsx`, `.d.ts`, `.prompt.md` und Card:
  - Radio, Tooltip, Spinner, ProgressBar, Skeleton;
  - Chip, Badge, Link, Disclosure, ScrollArea, ConfirmDialog, Presence.
- Zustandsmatrix, Motion-Card (14 abspielbare Animationen) und Accent-Variants-Card sind da. Die Accent-Card zeigt alle neun Fälle, Night und Paper, mit echter FileRow/DiffHunk.
- **Icons:** 59 Dateien, alle Strich 1.5, runde Enden, `currentColor`. `Icon.jsx` ist byte-identisch aus den Dateien erzeugt. Dazu ein Icon-Font-Weg (`assets/icons/font/` + `outline.js` + `glyphs.json`).

## 2. Was Claude Design noch korrigieren muss

Die vollständige, belegte Liste steht im Folge-Prompt. Die wichtigsten Punkte:

| # | Problem | Folge |
|---|---|---|
| 1 | **„Bewegung reduzieren“ ist kaputt.** `base.css:54/:60` setzt `animation-name:zs-fade!important` auf jedes `zs-`-Element. | Der Moon-Flash (`graph.css:77`) wird zu einem 2,4-s-Einblenden der ganzen Karte ab Deckkraft 0. Ein ersetzter Toast blendet ein statt aus. `--dur-toggle:0` killt auch Farbwechsel (Switch). Bewegung auf anderen Tokens läuft weiter (AtPill-Pfeil, Scroll-Thumb, •••). Die Delta-Werte liegen außerhalb von `tokens/`. |
| 2 | **Die Ampel-Geometrie stimmt nicht.** Das DS sagt „Zentren 20 px auseinander bei x 12/32/52, y 34 = native Abstände“. | Auf macOS 27 gemessen: 14-pt-Knöpfe, 23-pt-Teilung, 60 pt breiter Block. Unter unserer Toolbar liegen sie bei x 19–79, y 26. Der Zoom-Knopf überlappt die erste Insel bei x 76. `window.css` behandelt 12/32/52 als linke Kanten. Kein natives Fenster-Setup erreicht y 34. |
| 3 | **Feldgebundene Listen:** Regel 4 sagt: Fokus bleibt im Feld, Tastaturzeile = `--accent-soft`, Hover = `--fl-hover`. | SearchMenu verschiebt den Fokus ins Menü, seine Tastaturzeile ist `--fl-hover`. SearchRow nutzt `--accent-soft` auch für Hover. Story 10.21 weiß nicht, was sie bauen soll. |
| 4 | **Erhöhter Kontrast:** `--track-hover` und `--edge-hov` fehlen in `contrast.css`. | Slider-Track-Hover fällt auf 1.91 / 1.65 (Ruhe 4.04 / 3.73). Kartenrand-Hover auf Paper 1.07 gegen Ruhe. |
| 5 | **Reine Füllungen in Paper-Orange/-Gelb/-Grün:** Progress-Füllung und Badge haben keine Kante. | Gelbe Progress-Füllung gegen den Track: 1.03:1, also unsichtbar. Badge gegen die Insel: 1.44. |
| 6 | **Tastatur, VoiceOver und Reduce motion** fehlen in den meisten `.prompt.md`. Das Readme behauptet das Gegenteil. | Am kritischsten: Dialog (Esc, Initialfokus, Fokusfalle, Rückgabe) und ScrollArea. Außerdem ProjectMenu (keine Tasten, kein Blink, kein `closing`) und ProjectRow (nicht fokussierbar). |

Weitere Punkte (klein, aber vor der Umsetzung zu klären):
- **Reduce transparency** ist nur für zwei Klassen definiert. Toast, großer Primary, AtPill und Scrims behalten ihren Blur. → als Token-Delta wie `contrast.css`.
- **`aria-disabled`** („deaktiviert mit Grund“): eine generische Regel fehlt.
- **Fokus-Spezifität:** Menüzeilen bekommen trotz `outline:none` den Ring.
- **Unsichtbarer oder abgeschnittener Fokus** bei ScrollArea-Viewport, `.zs-diff-collapsed` und `.zs-proj-more`.
- **Text auf Tönungen unter 4.5:1:**
  - Rot-Night-Akzenttext auf soft 3.90 / soft-hi 3.42;
  - `--text-faint` im Tooltip 3.94 und auf fl-on/press-Zeilen.
- **Paper-Gelb-Linie** gegen den Gold-Primary: ΔE .055, nicht gemeldet.
- **RevsetDialog** nutzt noch natives `<select>`, hat keine Exit-Animation, und acht Controls haben keinen Pressed-Zustand.
- **Select:** Die Platzierungsregel steht nur als JSX-Arithmetik. Für lange Listen gibt es kein Scrollen.
- **Submenü:** keine Öffnungsverzögerung, kein Safe-Triangle, kein Flip.
- **Fehlende Kombinationen:** on+pressed bei Chip und FileRow, Segment-Hover, eine Switch-Zeile in der Tabelle.
- **Slider:** Der Fokusring ist literal und ignoriert `--focus-w`. Die Schritte für Bild↑/↓/Pos1/Ende fehlen.
- **Motion-Ausreißer:**
  - ohne Token: Toast 6,5 s, Peek 450, Skeleton 150, Typeahead 600, AtPill 320, Calm-Scrolling nur als Kit-Literale mit CSS-`ease`;
  - widersprüchlich: der indeterminierte Balken nutzt die State-Kurve statt linear;
  - falsch: `motion.html` zeichnet die Exit-Kurve falsch.
- **Literale Farben** in Komponenten (inset-Segmented, Viewed-Chip, `rsd`-Feld = `--field-bg`, Ghost-Schatten). Tote Regeln: `.zs-viewed-box`, `.zs-alert.is-warn`.
- **Veraltete Doku:**
  - Toast 38/28, SearchField 32, ProjectMenu 30, SearchPopover-Radius 12;
  - **DiffHunk/DiffView-Prompts sagen `--accent-soft`, richtig ist `--hunk-bg`.** Story 10.24 hat den Fehler schon übernommen;
  - `Icon.prompt.md` (45 Glyphen, „kein Icon-Font“, #000);
  - Kbd-Regel, AtPill 320, „1.6:1“ statt 1.23:1.
- **„Ein Menü“ ist unvollständig:** PeekCard sowie Stack-Popover und Gap-Callout im Kit nutzen das alte Material, die Labels der Elevation-Card sind vertauscht.
- **Icons:**
  - 13 Glyphen brechen die neue „1 Einheit Luft“-Regel. Am schlimmsten ist das „!“ in conflict: 0.30 Einheiten, bei 12 px also 0.225 px;
  - alert und conflict zeichnen das „!“ unterschiedlich;
  - `guidelines/brand-iconography.html:12` lädt das gelöschte `edit.svg` (**404, auch im Browser gesehen**);
  - die Legende dieser Card ist veraltet.
- **ConfirmDialog-Beispiel:** Es nutzt `jj git push --allow-backwards`. Den Schalter gibt es in jj v0.46.0 nicht, und die UI würde Operationen komponieren.
- **Kommentar-oklch** weicht von den Hex-Werten ab (Paper `--co` 2.95/255, fünf Akzent-Kommentare liegen außerhalb des Gamuts).
- **Kontrast knapp verfehlt:** Paper-`--border-strong` im Kontrastmodus erreicht 2.97 auf dem dunkelsten Canvas (Tagestrenner). Die Near-Miss-Liste ist unvollständig: Grün ≈ ahead .050, Graphit ≈ missing .051, Graphit Night ≈ text-muted .034.
- **Inaktives Fenster:** nicht spezifiziert. Welche Akzente werden grau: ausgewählte Karte, fokussierte Zeile, eingeschaltete Switches?
- **„jj fehlt oder ist zu alt“** (DS-Liste offener Punkte) gibt es bei uns nicht: Zanshin bettet jj-lib ein.

## 3. Entscheidungen für Ralph

Jeweils mit Empfehlung. Die ersten vier sind die wichtigen.

> **Stand 2026-10-15, später (Ralph):**
> - E1–E5 und E9–E12: Empfehlung übernommen.
> - **E6:** SVG ist in Ordnung (Ralph hielt einen Icon-Font für performanter, siehe die Antwort im Chat).
> - **E7 (entschieden):**
>   - Rückgängig gibt es an drei Stellen:
>     - den Undo-Knopf im Toast;
>     - ⌘Z bzw. Bearbeiten › „‹Aktion› widerrufen“, nur für Zanshins eigene letzte Operation und nur, solange sie die aktuelle ist. Der Menüeintrag nennt die Aktion, danach erscheint ein Toast „Undid … · Redo“. ⇧⌘Z wiederholt;
>     - die Undo Timeline für alles Ältere.
>   - ⌘Z geht nie weiter zurück und nie über fremde Operationen.
>   - Das ersetzt 10.23s Regel „⌘Z nur, solange der Toast sichtbar ist“. Der Menüeintrag braucht die noch offene Menüleisten-Story.
> - **E8:** Push öffnet einen **Dialog**: Bookmarks und/oder ein Change auswählen, mit `--dry-run`-Vorschau. Das ersetzt die Empfehlung „kein Nachfragen“ und 11.8 (b) und wird Teil F des Folge-Prompts.
> - **Folgen von E8:** Story 9.20 muss Push mit allen CLI-Parametern samt `--dry-run`-Plan liefern. 11.8 baut den Dialog, und der Non-goal „Pushing single bookmarks“ entfällt.

| # | Frage | Empfehlung |
|---|---|---|
| E1 | **Die Entscheidungen vom 15.10. festschreiben:** eigene Controls (kein Material-/Yaru-Look, Texteingabe aus Flutter), und bei Abweichung gilt das DS vor dem Floating-Client. Dazu die ungefragten DESIGN-REVIEW-Änderungen übernehmen: Höhen-Skala 22/26/30/36/44, Radien, ein Menü-Material, Layer, Icons. | **Ja.** Ohne Eintrag in epics.md binden 10.7 Item 8, 11.1 Item 9 und 10.15 weiter Material/Yaru. |
| E2 | **Akzent C1 + D bestätigen:** Mehrfarbig = Moon; eine benannte macOS-Farbe färbt nur die Moon-Rolle; Einstellung „Akzentfarbe: macOS folgen · Zanshin“, Standard „macOS folgen“. Das ersetzt Entscheidung (f)/(g) „Moon“ und 11.1 (c). | **Ja.** Deine Folgeantworten setzen das schon voraus. |
| E3 | **Eigene Story „Control-Bibliothek“** nach 11.1/11.2 und vor 10.7: Zustandsmodell, Fokusring, Cursor, Semantik, Reduce motion, Kontrast und Galerie. | **Ja.** Sonst baut jede Story Fokus, Bewegung und Semantik neu, und die Drift aus der Zeit vor dieser Runde kehrt zurück. |
| E4 | **Reduce motion für Flash und Puls:** statisch, wie am 30.9. entschieden, oder die DS-Absicht (nur Farbe blendet, nichts bewegt sich)? | **DS-Absicht.** macOS ersetzt bei „Bewegung reduzieren“ Bewegung durch Überblendungen, Fades sind erlaubt. Die kaputte CSS korrigiert Claude Design. |
| E5 | **Ampeln:** deine grauen Ringe (`TrafficLightOverlayView`) behalten oder die Systemknöpfe zeigen, wie das DS es will? Und die Geometrie? | **Ringe behalten**; Claude Design hält sie als bewusste Abweichung fest. **Native Positionen nicht bekämpfen.** Claude Design leitet die Spalte bzw. die erste Insel aus dem gemessenen 60-pt-Block ab. |
| E6 | **Icons (d):** SVG oder Icon-Font? Das DS liefert jetzt Konturen und Generator. | **SVG**, plus Icon-Paritätstest und Precache beim Start. Exakte Quelle, testbar im Gate, kein manueller Font-Build. |
| E7 | **⌘Z:** Das DS sagt „frühere Undos bleiben mit ⌘Z erreichbar“, App-weit. 10.23 sagt: nur solange ein Toast sichtbar ist. | **10.23 jetzt beibehalten.** App-weites Undo kommt mit einer Menüleisten-Story. Claude Design streicht die Zeile oder markiert sie als später. |
| E8 | **Push bestätigen?** Laut ConfirmDialog fragt alles, was ein Remote ändert, vorher nach. 11.8 (b) sagt: wie die CLI, kein Nachfragen. | **CLI-Regel**, kein Nachfragen. |
| E9 | **Splash-Statuszeilen** auf Englisch (DS: UI-Text ist Englisch; heute „lade Settings…“ usw.)? | **Ja, jetzt.** Kleine Änderung, als deferred-work-Eintrag oder in einer 11.x-Story. |
| E10 | **Farbe markierter Glyphen:** Das DS will alle markierten Zeichen in `--text`. Flutter malt nur den Hintergrund und hat keine Vordergrund-API (SDK geprüft). | **Abweichung festhalten:** In Textfeldern per `buildTextSpan` umfärben, in Nur-Lese-Text (Diff, IDs) vorerst nur den Hintergrund. |
| E11 | **Theme-Namen** `night`/`paper` statt `light`/`dark` (DS-Vorschlag, `light` als Alias)? | **Ja.** Kostet uns nichts, der Paritätstest hält den Selektor als Konstante. |
| E12 | **Gelb** (h 100–103 statt macOS 87) wirkt auf Paper bei Linien und Text olivgrün. | Selbst in der Accent-Variants-Card ansehen; sonst lassen. |

## 4. Was an unseren Stories zu tun ist

Noch nicht umgesetzt, wie vereinbart. Sinnvoll nach E1–E11 und Runde 2 von Claude Design:

**11.1 neu fassen (Blocker)**
- **Token-Ebene:** alle `tokens/*.css` inklusive states, accents und contrast, dazu das Reduce-motion-Delta, das Claude Design nach `tokens/` verschieben soll.
- **ThemeExtensions:** Theme × Akzent-Familie als eigene Achse; Kontrast als Delta.
- **Paritätstest:**
  - parst nach Selektor-Scope (Attribut- und `@media`-Blöcke), löst `var()`-Aliasse auf;
  - vergleicht Hex/rgba exakt, ohne oklch-Vergleich;
  - braucht einen eigenen Sync-Auslöser, denn diese Runde hat keine neue SYNC-Nummer, das DS steht weiter auf #9.
- **Werte:** Fokus und Disabled aus `states.css`; Motion: drei Kurven, Dialog 220, kein Spring, DS-Semantik für Reduce motion.
- **Item 7 (Shell)**, neue Felder:
  - `AppleAccentColor`-Identität;
  - `controlAccentColor` in aqua (nur für „Dieser Mac“);
  - `selectedTextBackgroundColor` und die unemphasized-Variante, aufgelöst im Appearance des Zanshin-Themes;
  - `increaseContrast`;
  - Key-Status des Fensters;
  - `preferredScrollerStyle`.
  - Erkennung in dieser Reihenfolge: Schlüssel vorhanden → Familie; Schlüssel fehlt und Farbe = eigener App-Akzent → Mehrfarbig; sonst Farbton-Abbildung.
- **Item 9:** Yaru-Basis streichen.
- **Item 11:** Icon-Regel neu: alle 59 aus `assets/icons/ui` kopieren, C2PA entfernen, `glyphs.json`-Aliasse, Icon-Paritätstest, gezeichnetes @ in Icon-Slots. Mono-Stile bekommen `fontFamilyFallback: ['Inter']`, denn JetBrains Mono hat weder ✓ noch ‥.

**Weitere Stories**
- **11.2:** Radius 13; Callout 160; ein Menü-Material; Dialog 220; Exits; die solide Variante greift auch bei erhöhtem Kontrast, mit dem Kontrast-Scrim.
- **11.3:** Layer-Tokens; Rail-Fokus innen; Calm-Scrolling auf DS-Tokens, sobald es sie gibt.
- **11.4:**
  - die gemessene Ampel-Geometrie (ein Witness gegen die Probe-Werte statt x 12–64);
  - das `AccentColor`-Asset / `NSAccentColorName` (#4757a1 / #5162ad);
  - das inaktive Fenster als NEEDS DESIGN.
- **11.7:** Zeile „Akzentfarbe“; das eigene Select; Tabs 36, inset 30.
- **Epic 10, Werte nachziehen:**
  - 10.6: @-Pille `--at-chrome`, Fokus `--focus-ring`;
  - 10.7: Primary-Rezept mit 16-px-Icon, Popover 13;
  - 10.15: Menüzeilen-Blink, Danger-Tönung;
  - 10.16: Tages-Pille `--at-chrome`;
  - 10.21: Listenmodell nach Runde 2;
  - 10.23: 36/26, 260/180/120, warn- und error-Ton;
  - 10.24: **Hunk-Band `--hunk-bg`, nicht `--accent-soft`**;
  - 10.26: `--accent-soft-hi` + `--accent-line`.
- **Akzentrolle oder Datenfarbe:** Die 41 Zeilen in Epic 10/11, die „moon“ oder `--accent` sagen, einzeln zuordnen.
- **Neue Story:** Control-Bibliothek (E3).
- **Zitate und Buchführung:**
  - alle `DS …:Zeile`-Zitate neu verankern (Konvention „Zitate vom 2026-10-15 beziehen sich auf den Commit mit diesem DS“);
  - die Hausregel „Design-system sync“ um DS-Runden ohne SYNC-Nummer erweitern;
  - deferred-work: erledigte Einträge markieren, neuer Abschnitt „Surfaced 2026-10-15“;
  - alles in `sprint-status.yaml` spiegeln.

**App-Code, später in den Stories**
- `ZI.arrowLeft` und `ZI.download` nutzen ausgemusterte Namen.
- 35 von 37 App-Icons weichen von der neuen Geometrie ab.
- `ZanshinIcon` fällt auf Material zurück und nimmt beliebige Größen.
- `Zanshin.ttf` stammt von vor der Neuzeichnung.

## 5. Nebenbei

- Für die Validierung habe ich in `.claude/launch.json` die Konfiguration `design-system-preview` (Port 8767, dient `design_system/` aus) ergänzt. Sie bleibt nützlich, wenn Ralph die Cards im Browser-Pane ansehen will.
- Die ausführlichen Prüfberichte samt Gegenprüfung liegen im Session-Scratchpad (`scratchpad/val/*-findings.md`). Sie sind nicht im Repo; das Wesentliche steht hier und im Folge-Prompt.

## 6. Nachtrag 2026-10-15 abends: Fenster, Werkzeuge, Workstreams, SVG

Ralph brachte vier weitere Themen ein. Jedes wurde von einem Recherche-Agenten untersucht und von einem zweiten gegengeprüft. Die Ergebnisse sind in den Runde-2-Prompt eingeflossen (Abschnitte C, D3/D4, E und G sowie Prompt 2 für den Floating Client).

**Fenster** (Windowing-API, SDK 3.50.0-0.1.pre, rev 29bfd8cbb41).
- Aus fünf Einträgen werden zwei Fenster: **Settings** (für „Settings…“, „Project Settings…“ und „Appearance, diffs and more“) und **Projects**.
- Beide sind `DialogWindowController` ohne Parent. Auf macOS heißt das: Titel, schließbar, nicht minimierbar, `FullScreenAuxiliary`.
- Was es nicht gibt oder nicht passt:
  - Ein Dialog *mit* Parent wird ein AppKit-Critical-Sheet.
  - Satellite-Fenster werfen auf macOS `UnimplementedError`.
  - Die Owner-Factories verwerfen `constraints`. Ein `shrinkWrap`-Fenster muss daher über den Konstruktor `DialogWindowControllerMacOS(constraints:)` entstehen.
- **Configurations bleibt ein Sheet**, wie ConfirmDialog und Push (Empfehlung):
  - Entscheidung (g) in 10.22 lässt die Ansicht erst bei OK wechseln. Ein modeless Fenster brächte also kaum Nutzen.
  - Es bräuchte aber eine native Fensterbindung (`addChildWindow`) und Regeln für Projektwechsel, Schließen und gelöschte Konfigurationen.
- Vorarbeiten (eigene Foundation-Story oder in 11.4):
  - Dialog-Fenster in `AppWindows`.
  - Chrome-Arten main/secondary, mit `isRestorable = false` für jedes Fenster.
  - Frame-Speicher nur mit Position.
  - `zanshin_shell` setzt die Erscheinung für alle Fenster, nicht nur für eines.
  - Menüleiste: ⌘, und ⌘W. Heute hat „Preferences…“ keine Aktion, und es gibt kein Close.
  - Ein App-Root pro Fenster, denn `WindowManager` baut jedes Fenster aus dem eigenen Kontext.
- Nebenwirkung: Jeder Fensterwechsel nimmt dem Textfeld den Fokus. Schreibvorgänge, die beim Fokusverlust auslösen (11.7), laufen also bei jedem Wechsel.
- Was sich damit erledigt: Defekt 73 („⌘, stapelt zwei Modals“) und 11.7s Regel „ein Modal zur Zeit“.

**Werkzeuge.**
- **Widgetbook 3.25.0** wird exakt gepinnt, als dev_dependency, mit eigenem Einstieg `app/widgetbook/main.dart` über `AppWindows`. Es ist der eine Katalog und ersetzt die geplanten Galerien. Seine Zustandsmatrix folgt der DS-Card.
  - 3.25.0 ist die letzte 3.x. Version 4 startet nur über `runApp`; im Runner ohne View geht das nicht.
  - Die Addons `SemanticsAddon` und `TimeDilationAddon` sind `@experimental` und lassen `--fatal-warnings` scheitern.
  - Der `appBuilder` muss die Ambient-Defaults aus 11.1 setzen. Gemessen: Sonst greift der 48-px-Monospace-Fallback.
- **Marionette 0.7.0** enthält Ralphs Multi-View-Fix; die App pinnt noch `^0.6.0`. `marionette_mcp` ist derzeit nicht installiert.
  - Eigene Controls registriert eine gemeinsame `MarionetteConfiguration(isInteractiveElement:)`.
  - Eigene Controls tragen ihren Bezeichner über `Semantics(identifier:)`.
  - Bei mehreren Fenstern wird über Key oder Text angesprochen, nie über Koordinaten.
  - Screenshots erfassen alle Views, ohne Kennzeichnung und ohne native Chrome.
- **Patrol und Patrol MCP: nicht jetzt.**
  - Auf macOS ist Patrol Alpha ohne native Automation.
  - Seine Binding behält den Fake-Windowing-Owner.
  - `patrol_mcp` zielt auf Android und iOS.
- **Das native „Auge“** bleibt die CGWindowList-Probe.

**Workstreams.**
- jj kennt weder Befehl noch Begriff. Geprüft wurden v0.46.0, `main` und `origin/main`; upstream gibt es nur die offenen Requests #7845 und #3402.
- Gemeint sind auch nicht Workspaces: Das Design hat keinerlei Workspace-Bezug. Der Eintrag stammt aus einem „Coming soon“-Platzhalter der ersten Claude-Design-Iteration.
- Er wird ersatzlos gestrichen, statt ihn „bis ein Backend existiert“ zu verstecken.
- Neu an Design-Aufgaben:
  - `name@` auf Karten. Das ist ohnehin 10.3 Frage (e); die Daten liegen in `CommitMeta.working_copies`.
  - Der Zustand `jj.stale_working_copy`. Er blockiert heute jeden Aufruf mit Snapshot, die Graph-Abfrage eingeschlossen. 10.5 kennt dafür nur „Retry“, und das hilft nicht; erst 9.23 (update-stale) hilft.
- Ein Workspaces-Abschnitt im Project-Menü ist ein neues Feature; Ralph entscheidet.

**SVG.**
- Ja, vorkompilieren, und zwar über den Asset-Transformer in der pubspec (`vector_graphics_compiler`), nicht mit eingecheckten `.vec`-Dateien. Geprüft: Alle 59 Icons kompilieren fehlerfrei, auch unter `flutter test`.
- `currentColor` wird beim Kompilieren zu Schwarz. Gefärbt wird deshalb mit `ColorFilter.mode(srcIn)`, wie `ZanshinIcon` es schon tut.
- Vorkompilieren beseitigt das leere erste Frame nicht. Das schafft erst eine `IconRegistry`, die beim Booten parallel zu den Settings geladen wird, zusammen mit einem `ZanshinIcon` als Leaf-RenderBox. Das ist die Antwort auf Ralphs Frage zu E6 (Performance).
- Gate: `parseWithoutOptimizers(xml, warningsAsErrors: true)` pro Icon unter `flutter test`. Unter `flutter test` sind Asserts an, deshalb wirft jedes nicht unterstützte Element. Dazu kommt eine kleine Attribut-Prüfung.
- An Claude Design:
  - (a) Den Font-Pfad löschen: `font/`, `outline.js`, Card-Umschalter, Readme. `glyphs.json` bleibt.
  - (b) Nicht die Illustrator-Einstellungen übernehmen, denn die SVGs entstehen nicht in Illustrator. Stattdessen deren Absicht als Dateiregeln in ICONOGRAPHY festhalten.
  - Der C2PA-Block ist ein Download-Stempel; wir entfernen ihn beim Import.
- Icons erst nach Runde 2 kopieren, denn die Runde zeichnet 13 Glyphen neu.

**Offen für Ralph:**
- Configurations: Sheet oder Fenster.
- Projects als Startfenster (Schließen beendet die App).
- ⌘,: letzter Tab oder immer General.
- Workspaces-Abschnitt im Project-Menü.
- Icon-Dateinamen: kebab-case wie das DS, oder snake_case wie 11.1 Punkt 11.
- Icon-Parität im Gate oder als Sync-Skript. Im Gate würde jeder DS-Download mit Icon-Änderungen `cargo make test` rot machen.
- Den Demo-Host aus 10.1 in Widgetbook aufgehen lassen.

**Change-ID-Lücke** (Ralph, nach dem Senden von Prompt 1):
- Die Lücke in `pl kmnvxo` ist ein CSS-Fehler. `.zs-cid` (DS `graph.css:34`) und `.gcid` (Client `graph.css:88`) setzen `gap:4px` auf einen `inline-flex`-Container, damit das ◆ Abstand bekommt. Das gilt aber auch zwischen `<b>` und dem Rest.
- jj schreibt Präfix und Rest ohne Trenner (`ShortestIdPrefix`, `cli/src/commit_templater.rs:2316-2321` @ v0.46.0). Die gezeigte Länge ist `max(Präfixlänge, n)` (`:2295-2302`). Das DS-Readme zeigt es selbst ohne Lücke (`readme.md:65`).
- **Ralph: nicht an Claude Design melden, sondern in Flutter richtig machen.** DS und Client behalten die Lücke; sie ist eine bewusste, festgehaltene Abweichung vom Export, kein Vorbild.
- Prototyp-Defekt 40 behandelt die festen 2 fetten Zeichen ohnehin als Defekt. Damit ist 10.3 Frage (c) beantwortet: jjs kürzestes eindeutiges Präfix.
- Für die Stories (10.3, 10.8 und jede Stelle mit Change-ID, auch Peek, Toast, Drag-Ghost, Menükopf, Suchzeile):
  - die ID als ein `Text.rich` mit zwei Spans, ohne Abstand dazwischen;
  - Präfixlänge aus `changeIdPrefixLength`, gezeigte Länge `max(Präfix, 5 bzw. 8)` wie `shortest(n)`;
  - nur das ◆ bekommt seinen Abstand.

**Zwischenfall:** Ein Prüf-Agent hat `flutter pub get` einmal im Repo-Wurzelverzeichnis ausgeführt, mit `PUB_CACHE` im Scratchpad. Er hat das selbst zurückgesetzt (`flutter pub get --enforce-lockfile` mit dem normalen Cache). Nachgeprüft:
- keine getrackten Änderungen;
- keine Scratchpad-Pfade in `package_config.json`, `app/macos/Flutter/ephemeral` oder `.flutter-plugins-dependencies`.

Nebeneffekt: Fehlende Pakete aus dem Lockfile liegen jetzt in `~/.pub-cache`.

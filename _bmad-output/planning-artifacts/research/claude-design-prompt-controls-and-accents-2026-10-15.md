# Prompt für Claude Design — Controls, Zustände, Mikro-Animationen, macOS-Akzentfarben

**Ziel:** das Projekt **Zanshin Design System** (`a33847c9-000b-4914-ae7f-6291f117e05f`).
**Hintergrund:** `technical-ui-controls-yaru-material-custom-and-macos-accents-research-2026-10-15.md` (selber Ordner).
**Senden:** alles unterhalb der Linie kopieren. Wird es Claude Design zu viel, Teil A und Teil B als zwei Nachrichten schicken. Der Vorspann gehört dann in beide.

---

Zanshin wird in Flutter gebaut. Wir haben entschieden, die Controls **selbst zu implementieren**, ohne Material- und ohne Yaru-Look. Grund: Switch, Checkbox, Segmented, Select und Menüs lassen sich dort nicht auf eure Maße, Bewegungen und Zustände bringen.

Das heißt: Was das Design System festlegt, bauen wir 1:1. Was es nicht festlegt, müssten wir raten. Deshalb bitte ich dich um zwei Dinge: den Control-Satz vervollständigen (Teil A) und die macOS-Akzentfarben prüfen (Teil B).

**Für beide Teile gilt:**
- Bleib beim Charakter des Systems: ruhig, dicht, macOS-nah.
  - Pfeil-Cursor überall.
  - Kein Ripple, kein Schrumpfen beim Drücken.
  - Moon für Auswahl, Fokus und Controls. Gold nur für @ und die eine Primäraktion.
  - Sentence case, keine Emoji.
- Gib alle Werte exakt an: px, Token-Namen, ms, `cubic-bezier`.
  - Flutter kann `color-mix()` nicht 1:1 übernehmen. Jede gemischte Farbe, die ein Control nutzt, bekommt deshalb einen eigenen festen Token in `tokens/`, für Night und Paper.
- Neue Komponenten sind bewusste Ergänzungen. Führe sie in `readme.md` unter „Intentional additions“ als **Control-Bibliothek**, mit einem Satz, warum der Floating-Client sie (noch) nicht zeigt.
- Bestehende Komponenten änderst du nur dort, wo du eine der unten genannten Ungereimtheiten auflöst. Halte jede solche Änderung in `readme.md` fest.
- Beginne mit einer kurzen Bestandsaufnahme und einem Plan: welche Komponenten, welche Entscheidungen. Dann baue.

## Teil A — Vollständiger Control-Satz mit allen Zuständen und Mikro-Animationen

### A1. Ein Zustandsmodell für alle Controls

Lege es einmal fest, als Tabelle und als Card. Die Zustände:

- rest, hover;
- **pressed (momentan)**: gibt es bisher nirgends, kein `:active`. Der Default-Button nutzt `--fl-on` (11 %) schon für Hover, deshalb braucht pressed einen eigenen Wert;
- focus-visible (nur Tastatur);
- selected/on, mixed;
- disabled;
- **error/invalid**, **busy/loading**, read-only.

Und vereinheitliche, was heute nebeneinander existiert:

- **Fokus:** Outline mit Abstand 2, 1, 3 und −2, ein Inset-Ring (FileRow) und ein Ring-Schatten (Felder, Titel). Lege eine Regel fest und begründe die Ausnahmen. Fokus fehlt außerdem bei Dialog-Navigation, Project-Zeilen, OptionLink und Links.
- **Disabled:** .38, .4, .35 und .5. Ein Wert und eine Regel. Gehört ein Tooltip mit dem Grund dazu?
- **„Selected“ in Listen und Navigation:** mal `--fl-on`, mal `--accent-soft`. Formuliere die Regel, z. B. Navigation gegen Auswahl.
- **Menü-Highlight:** zwei Modelle. Einmal solide Moon-Füllung mit Ink (Kontext-, Drop- und Project-Menü), einmal 7 % Fill + `--accent-soft` (Suchmenü, Vorschläge). Formuliere die Regel.
- **Bewegung:** Die Readme sagt „eine Kurve (glide)“. Die Komponenten-CSS nutzt aber CSS-`ease` für Hover, 160 ms für den Switch, 140 ms für das Suchfeld und ease-out für Kontextmenü und Scrim. Lege fest:
  - welche Kurve für Zustandswechsel gilt (hover, press, focus);
  - welche für Bewegung;
  - welche Dauern, nur als Tokens.

### A2. Die Controls

Für jedes Control: Maße, Tokens, alle Zustände aus A1, Tastaturverhalten (macOS-üblich), VoiceOver-Rolle, Mikro-Animation, Fallback bei „Bewegung reduzieren“. Night und Paper.

1. **Buttons**
   - Typen: default/quiet, ghost, danger, und neu ein gefüllter destruktiver Button für Bestätigungen.
   - **Gold-Primary sm/md/lg vereinheitlichen.** Heute gibt es ihn in vier Schreibweisen: Inset-Ring oder Border, unterschiedliche Mischungen (24/9 gegen 18/5), und Hover verstärkt mal nur den Ring, mal auch die Füllung. Pressed und disabled für Primary ergänzen.
   - Busy: Spinner im Button. Icon-only-Variante.
2. **IconButton** sm/md/lg: toggled/on, **mit Badge** (Zähler, z. B. Fetch), disabled.
3. **Switch:** hover, pressed (z. B. ein Thumb-Stretch?), disabled. Kurve festlegen.
4. **Checkbox:**
   - hover auf checked, pressed;
   - **Häkchen zeichnen** und **Morph mixed ↔ checked**;
   - das Verhältnis zur grünen „Viewed“-Checkbox (13 px, Radius 3) klären: eine Komponente oder bewusst zwei?
5. **Radio + Radiogruppe** (neu).
6. **Segmented** (default / tabs / inset / sm):
   - disabled für einzelne Segmente (der Project-Tab in Settings braucht das);
   - entscheiden: gleitender Thumb oder Überblendung wie heute.
7. **Slider:**
   - Thumb in hover, drag, focus und disabled; Track-Hover; Ticks bei Schrittweiten;
   - wie sich der Readout bei Wertänderung verhält;
   - eine Paper-Variante des Thumbs (heute in beiden Themes hart `#fff`).
8. **Textfeld, Textbereich, Mono:**
   - hover, focus, disabled, read-only, **error mit Meldungszeile**, Platzhalter;
   - die Farbe der Textauswahl;
   - das **Text-Kontextmenü** (Ausschneiden, Kopieren, Einsetzen …) im DS-Menüstil.
9. **Suchfeld mit Clear-✕** (Listen: Projects, Bookmarks).
10. **Select / Popup-Button:**
    - Trigger: heute nur natives `<select>`;
    - **offene Liste**: Häkchen, Tastatur-Highlight, deaktivierte Optionen, Trenner, ein „Custom…“-Eintrag, Typeahead;
    - Platzierung entscheiden: wie macOS die gewählte Zeile über den Trigger legen, oder als Dropdown darunter.
11. **Menüs:**
    - eine Zeile in allen Zuständen, inklusive **Aktivierungs-Blink** (macOS lässt die gewählte Zeile kurz blinken);
    - Check-Items, Submenü mit Pfeil, Abschnittsüberschrift, Spalte für Shortcut oder jj-Befehl;
    - Exit-Animation.
12. **Tooltip** (neu; heute nur HTML-`title`):
    - Verzögerung, Material, Platzierung, Ein- und Ausblenden;
    - eine Zeile für den jj-Befehl („Verbs first, jj underneath“).
13. **Fortschritt** (neu):
    - Inline-Spinner 12–16 px, auch im Button;
    - determinierter Balken, indeterminierter Balken;
    - „pending“ für Karten und Zeilen (Skeleton);
    - wann stattdessen der Nami-Loader.
14. **Chips, Tags, Badges:**
    - Filter- und Toggle-Chip: das „~“-NOT und das „Aa“ im Configurations-Dialog;
    - Add-Chip, Status-Pill, Zähler-Badge.
15. **Toasts:**
    - Erfolg + Undo (gibt es schon), Ablehnung/Warnung, Fehler + Retry;
    - Exit-Animation;
    - was passiert, wenn ein neuer Toast kommt.
16. **Dialoge:**
    - ein Bestätigungs- und Warndialog, z. B. „Push rückgängig machen?“, mit destruktivem Primär-Button;
    - Exit-Animation;
    - den Eintritt vereinheitlichen: 160 ms in der Komponente `Dialog`, 240 ms in Settings und Configurations.
17. **Listen- und Navigationszeilen:** Fokusring, Disclosure-Chevron mit Auf- und Zuklappen der Höhe.
18. **Scrollbalken:** Overlay, hover, drag.
19. **Links:** heute drei Stile, keiner mit Fokus. **Key-Caps:** Die Readme erlaubt sie nur in Prosa, das Suchfeld zeigt eine. Regel festlegen.

### A3. Mikro-Animationen

Für jede: Auslöser, Eigenschaft, Dauer-Token, Kurven-Token, Verhalten bei „Bewegung reduzieren“. Mindestens diese:

- Hover-Fade;
- Press-Feedback (ohne Schrumpfen);
- Fokusring erscheint;
- Switch-Thumb;
- Häkchen zeichnen und Strich-Morph;
- Radio-Punkt;
- Segment-Wechsel;
- Slider-Thumb;
- Menüzeilen-Highlight und Aktivierungs-Blink;
- Exits von Menü, Popover, Callout, Dialog und Toast;
- Tooltip;
- Spinner und Skeleton;
- Badge-Zähler;
- Disclosure.

Zeig sie auf einer Card, auf der man jede Animation abspielen kann.

### A4. Lieferform

- Pro Control wie bisher: `.jsx` + `.d.ts` + `.prompt.md` + Card.
- Neu: eine Übersichts-Card **„Controls — state matrix“**. Zeilen sind die Controls, Spalten die Zustände. Night und Paper lassen sich umschalten.
- Den UI-Kit dort nachziehen, wo die vereinheitlichten Regeln sichtbar werden.

## Teil B — Prüfen: macOS-Akzentfarben („Thema“-Farben)

**Die Frage:** Können wir die macOS-Akzentfarbe übernehmen (Systemeinstellungen › Erscheinungsbild › Thema › Farbe)? Das Gold müsste es dann vermutlich auch in Rot, Blau, Grün usw. geben.

Die Farben müssen nicht Apples Werte treffen. Wir kreieren eigene. Aber wer in macOS Grün gewählt hat, soll unser Grün als seines wiedererkennen.

### Was wir schon wissen (gemessen auf macOS 27)

**Auswahl und Auslesen**
- Zur Wahl stehen: Mehrfarbig (Standard) sowie Blau, Lila, Rosa, Rot, Orange, Gelb, Grün und Graphit. Auf dem iMac kommt „Dieser Mac“ dazu.
- Einen frei wählbaren Akzent gibt es nicht.
- Die App kann die Wahl genau auslesen.

**Apples Regel (HIG)**
- Bei „Mehrfarbig“ zeigt jede App ihren eigenen Akzent.
- Bei jeder anderen Wahl ersetzt die Nutzerfarbe den App-Akzent bei Buttons, Auswahl-Highlight und Seitenleisten-Icons.
- Ausgenommen sind feste Farben, die Bedeutung tragen.

**Akzentwerte (hell / dunkel) und OKLCH-Farbton**

| Wahl | hell | dunkel | Farbton |
|---|---|---|---|
| Blau | #007AFF | #007AFF | 257 |
| Lila | #953D96 | #A550A7 | 327 |
| Rosa | #F74F9E | #F74F9E | 356 |
| Rot | #E0383E | #FF5257 | 23 |
| Orange | #F7821B | #F7821B | 54 |
| Gelb | #FFC726 | #FFC600 | 87 |
| Grün | #62BA46 | #62BA46 | 139 |
| Graphit | #989898 | #8C8C8C | grau, ohne Farbton |

**Rohwerte reichen auf Paper nicht.** Auf der Paper-Karte erreichen Gelb 1.54:1, Grün 2.40:1, Orange 2.53:1 und Graphit 2.84:1. Es braucht abgestimmte Varianten.

**Die Textauswahl** ist in macOS eine eigene Einstellung („Textmarkierungsfarbe“), unabhängig vom Akzent.

### Unsere Rollen

**Gold hat drei Jobs:**
1. **@ = Arbeitskopie** (Safran, `--co*`). Das ist eine Datenfarbe, wie Grün für „hinzugefügt“.
2. **Die eine Primäraktion** (`--fl-gold`, gold getöntes Glas). Das ist genau der Button, den macOS umfärbt.
   - Dasselbe Token zeichnet aber auch den Rand der @-Pille sowie die Tages-Pille und den Verbinder der Minimap.
3. **Die Marke:** Nami, Wortmarke, Splash, der Gold-Lift des Paper-Canvas.

**Moon** (`--accent*`) ist Auswahl, Fokus, Switches, Slider, Checkboxen und Menü-Hover. Das ist die Rolle, die macOS seinem Akzent gibt.

Moon trägt aber auch Datenbedeutung:
- den Dateistatus „M“ neben A (grün) und D (rot);
- die Hunk-Header (`--accent-soft`, `--hunk`);
- den Remote-Status von Bookmarks.

### Gemessene Kollisionen

Gemessen als ΔE in OKLab; unter .06 gilt als verwechselbar.

**Wenn Gold folgt (@ und Primäraktion):**

| Wahl | Ergebnis |
|---|---|
| Blau | @ ≈ Moon (.052) |
| Grün | ≈ add (.048) |
| Rot | ≈ rem (.033 auf Paper) |
| Graphit | ≈ Text (.034) |

- Blau, Rot und Rosa erreichen bei L .78 die Chroma des Safran nicht und werden pastellig.
- App-Icon und Splash bleiben Gold, das @ wäre es nicht mehr.

**Wenn Moon folgt:**

| Wahl | Ergebnis |
|---|---|
| Blau | ist praktisch Moon (.018) |
| Lila, Rosa, Graphit | brauchbar; Lila und Rosa erst mit etwas mehr Chroma als Moon |
| Orange, Gelb | landen auf dem Gold und dem Amber von warn/conflict (.04–.065) |
| Grün | nah an add (.056 auf Paper) |
| Rot, Rosa | normales Menü-Hover und Danger-Hover werden beide rot |

**Fest kodierte Project-Statusfarben** kollidieren je nach Akzent ebenfalls: dirty #facc15, ahead #4ade80, behind #60a5fa, diverged #fb923c, syncing #a78bfa.

### Aufgaben

1. **Prüfe die Optionen und empfiehl eine, mit Begründung:**
   - **(A)** Gold folgt, mit @ und Primäraktion.
   - **(B)** Nur Moon folgt.
   - **(C1)** Mehrfarbig = Zanshin unverändert; eine benannte Wahl färbt nur die Moon-Rolle.
   - **(C2)** Wie C1, dazu folgt die Primäraktion; @ bleibt Safran.
   - **(D)** Zusätzlich eine Einstellung in Settings › General › Appearance: „Akzent: macOS folgen / Zanshin“.

   Unsere Analyse spricht für C1 oder C2 plus D. Mehrfarbig ergibt dann Zanshin wie heute; @, Marke und Splash bleiben Gold. Widersprich, wenn du es anders siehst.
2. **Teile die Tokens so, dass die Wahl sauber umsetzbar ist:**
   - `--fl-gold` in „Primäraktion“ und „@-Chrome“ aufteilen. Zum @-Chrome gehören der Rand der @-Pille sowie die Tages-Pille und der Verbinder der Minimap.
   - Die Moon-Datenbedeutungen bekommen eigene Tokens, die nicht mitwandern: Status M, Hunk-Header-Hintergrund, `--hunk`, Remote-Status.
   - Die Project-Statusfarben werden Tokens.
3. **Entwirf für jede der acht Wahlen eine Zanshin-Familie,** für Night und Paper:
   - mindestens `accent`, `-ink`, `-soft`, `-ring`;
   - für helle Töne (Gelb, Orange, Grün auf Paper) bei Bedarf getrennte Füll- und Linien-Töne;
   - falls die Primäraktion folgt, auch ihre Mischungen.

   Ziele:
   - Fills und Ringe ≥ 3:1 gegen Karte und Canvas:
     - Night: Karte #1a1f35, Canvas #12162a, Lift #2b3555;
     - Paper: Karte #fffdfa, Canvas #f0ece7.
   - Ink auf Fill ≥ 4.5:1.
   - Jeder Ton ist als die macOS-Farbe wiedererkennbar und passt zum Indigo-Canvas.
4. **Löse die Kollisionen ausdrücklich je Akzent.** Mögliche Wege: Farbton verschieben, andere L/C, Danger-Hover als Tönung statt roter Füllung.
5. **Mehrfarbig:**
   - Zeig, wie Zanshin dann aussieht (wie heute).
   - Leg fest, welche Farbe wir an macOS als App-Akzent melden, Moon oder Gold. Sie färbt bei Mehrfarbig native Menüs und Dialoge.
6. **Textauswahl:** Leg fest, ob sie der macOS-Textmarkierungsfarbe folgt oder aus dem Akzent abgeleitet wird.
7. **Card „Accent variants“:**
   - dieselben Ausschnitte für alle neun Fälle, Night und Paper nebeneinander, mit Kontrastwerten:
     - Top-Bar mit „New change“;
     - eine ausgewählte Karte neben @;
     - Switch, Checkbox, Slider;
     - ein Menü mit Hover und Danger;
     - ein Diff mit M/A/D und Hunk-Header.
   - Falls du D empfiehlst, auch die Settings-Zeile.

## Nebenbei bitte korrigieren

- **Gamut:** Vier Paper-Tokens liegen außerhalb von sRGB (und P3):
  - `--co` (oklch 58% .16 65),
  - `--co-text` (45% .14 65),
  - `--conflict` (52% .13 70),
  - `--warn` (50% .13 70),
  - dazu `--saffron-paper` und `--amber-paper` im `:root`.

  Gib sRGB-taugliche Werte an, damit Browser-Clipping und Flutter dasselbe zeigen.
- **Kontrast:** Der Danger-Hover bei Night hat nur 2.77:1 (weißer Text auf #f87171).
- **Slider-Thumb:** in beiden Themes hart `#fff` (siehe A2).
- **Veraltete Stellen:**
  - `Island.prompt.md` nennt noch `CommandField`;
  - `Popover.prompt.md` und `colors-moon.html` zeigen das alte „Time“-Layout;
  - `window.card.html` nutzt `cursor:pointer`;
  - `motion.html` nennt den Loader „2.1s loop“, die Readme 1.3 s + 0.55 s Pause.

Halte am Ende in `readme.md` fest, was du entschieden hast und was offen bleibt.

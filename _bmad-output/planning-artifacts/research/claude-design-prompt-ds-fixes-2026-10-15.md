# Prompt für Claude Design — Runde 2: Korrekturen nach der Validierung

**Ziel:** das Projekt **Zanshin Design System** (`a33847c9-000b-4914-ae7f-6291f117e05f`).
**Hintergrund:** [`design-system-validation-2026-10-15.md`](design-system-validation-2026-10-15.md).

**Vor dem Senden:** Ralph hat E1–E12 entschieden (E7: geschütztes ⌘Z für die eigene letzte Operation, alles Ältere über die Undo Timeline; E8: Push-Dialog statt Bestätigung).

Neu seit dem Abend des 2026-10-15: Fenster, Workstreams, Icon-Font und SVG-Regeln (Abschnitte C, D, E und G). Vier Punkte sind mit Claudes Empfehlung eingetragen. Wenn Ralph anders entscheidet, die genannte Stelle anpassen:

1. **jj log Configurations bleibt ein Sheet**, nur Settings und Projects werden Fenster (G3). Soll Configurations doch ein eigenes Fenster werden: G3 durch den Block „Alternative G3“ unten ersetzen und „jj log Configurations“ in F (zweiter Absatz) und G6 streichen; in Prompt 2 den Satz „jj log Configurations bleibt ein Sheet“ ebenso.
2. **Projects ist das Startfenster**, wenn kein Projekt offen ist; Schließen beendet die App (G2).
3. **⌘, öffnet den zuletzt gezeigten Settings-Tab** (macOS-HIG), nicht immer General (G1, G5).
4. **Kein Workspaces-Abschnitt im Project-Menü.** Wenn doch: den Block „Optional D5“ unten an Abschnitt D anhängen.

Prompt 1 (Design System) steht zwischen den Linien. Prompt 2 (Floating Client, Projekt „Zanshin“) steht am Ende.

> **Alternative G3** (statt G3, falls Configurations ein Fenster wird):
> 3. **jj log Configurations als eigenes Fenster** neben dem Graph, damit man beim Schreiben eines Filters im Graph nachsehen kann (Namen, Autoren, IDs). Titel plus Untertitel mit dem Projekt, auf das sich Vorschau, Zählung, `mine()` und Apply/OK beziehen. Standard 880 × 580, größenveränderbar; bitte eine Mindestgröße angeben; die Liste bleibt 240 px, der Editor wächst. Footer Cancel · Apply · OK unverändert; Esc und Schließen = Cancel. Die Ansicht wechselt weiterhin erst bei OK. Das Fenster gehört zu dem Projektfenster, aus dem es geöffnet wurde, und schließt mit ihm.

> **Optional D5** (nur wenn Ralph den Workspaces-Abschnitt will):
> 5. **Workspaces im Project-Menü**, nur wenn das Repo mehr als einen Workspace hat. Ein Abschnitt „Workspaces“ zwischen Recent und All Projects…; die feste Reihenfolge in `ProjectMenu.prompt.md:11` bitte entsprechend ergänzen. Eine Zeile zeigt Namen, Pfad (mono, Ellipse in der Mitte, voller Pfad als Tooltip) sowie Change-ID und Betreff seines `@`; der offene Workspace trägt ✓. Ein Klick öffnet dieses Verzeichnis als Projekt. Ein Workspace ohne erreichbaren Pfad ist deaktiviert und nennt den Grund. Dazu `<name>@` als Go-to-Vorschlag in der Suche.

---

Danke für die Runde, sie ist sehr gut geworden. Wir haben alles nachgeprüft:
- Jede Kontrast-, ΔE- und Gamut-Angabe lässt sich nachrechnen.
- 321 Tokens lösen in allen Konfigurationen auf, ohne ein einziges undefiniertes `var()`.
- Es gibt kein `color-mix()` und kein `oklch()` mehr.
- Die Cards und das UI-Kit laden fehlerfrei; die eine Ausnahme steht unten.

Ein paar Dinge stimmen aber noch nicht. Bei manchen widersprechen sich Readme, CSS und Komponenten; die Flutter-Umsetzung würde dort raten müssen. Bitte arbeite die Liste ab. Halte in `readme.md` fest, was du geändert hast, und nenne die Runde mit Datum („Runde 2026-10-16“ o. ä.). Zeilenangaben beziehen sich auf deinen aktuellen Stand.

## A. Echte Fehler

1. **„Bewegung reduzieren“ macht den Flash kaputt.**
   - `components/base.css:54` und `:60` setzen `animation-name:zs-fade!important` auf jedes `[class*="zs-"]`.
     - `.zs-card.is-flash` (`graph.css:77`) wird dadurch zu einem 2,4-s-Einblenden der ganzen Karte ab Deckkraft 0. `effects.css:62` sagt dagegen, der Flash ist nur Farbe und bleibt.
     - Ein ersetzter Toast (`.is-replaced`) blendet ein statt aus.
   - `--dur-toggle:0` killt auch Farbwechsel, z. B. den Switch-Track (`forms.css:25`). Die Motion-Card verspricht „colour fades“.
   - Bewegung auf anderen Tokens läuft weiter:
     - der AtPill-Pfeil dreht über `--dur-dialog` (`actions.css:51`);
     - der Scroll-Thumb wächst über `--dur-hover` mit glide (`controls.css:109`);
     - der •••-Knopf skaliert (`graph.css:82`).
   - `ui_kits/desktop/kit.css:213` schaltet unter Reduce motion alle Transitions ab, Farbe eingeschlossen.
   - **Bitte:** Reduce motion nach Eigenschaft definieren, nicht nach Animationsname.
     - Bewegung, Größe, Position, Rotation und Strich-Zeichnung → 0.
     - Farbe und Deckkraft behalten ihre Tokens.
     - Jeder Exit (closing, replaced) blendet aus.
     - Der Flash bleibt eine reine Farbblende (deine Absicht).
     - Farbwechsel nicht mehr über `--dur-toggle` timen.
     - Das Delta aus `components/base.css` nach `tokens/` verschieben (z. B. `tokens/motion.css`). Nur `tokens/*.css` werden bei uns automatisch gegen den Code geprüft.

2. **Die Ampel-Geometrie entspricht nicht macOS 26/27.**
   - `readme.md:82` sagt „centres 20px apart at x 12 / 32 / 52, centred on the top bar (y 34) — the native spacing“. `window.css:2-5` behandelt 12/32/52 aber als linke Kanten; die Zentren liegen dort bei 18/38/58.
   - Auf macOS 27.0.1 gemessen (Swift-Probe, Standardknöpfe):
     - 14 × 14 pt, 23 pt Teilung, der Block ist 60 pt breit;
     - ohne Toolbar: Zentren x 16/39/62, y 16;
     - mit der Toolbar, die unsere App nutzt: Rahmen x 19–79, Zentrum y 26.
   - Keine native Titelleisten-Konfiguration erreicht y 34; Toolbar-Elementhöhen ändern daran nichts. Der Block passt nicht in die 52-px-Spalte, und der Zoom-Knopf überlappt die erste Insel bei x 76.
   - Die 20-px-Teilung war wahrscheinlich die Geometrie vor macOS 26. Wir unterstützen macOS ab 12, also ist kein fester px-Wert „nativ“.
   - **Bitte:** die Kopfzeile aus der gemessenen Geometrie neu ableiten.
     - **Wir verschieben die nativen Knöpfe nicht.** Die erste Insel der Top-Bar beginnt erst 12 px hinter dem Block, und die Bar richtet sich an dessen Mittellinie aus. Wähle Werte, die den 12-px-Rhythmus halten, und schreibe die Regel versionsunabhängig: „Block-Ende + 12“, nicht x 76.
     - Den Widerspruch Zentren gegen Kanten in `window.css` beheben; das Mock 14 px groß zeichnen.
     - **Grau gerahmte Ampeln:** Die App blendet die Systemknöpfe in Ruhe aus und zeichnet graue Ringe (`TrafficLightOverlayView`); bei Hover erscheinen die Systemknöpfe. Das ist eine bewusste Zanshin-Entscheidung. Bitte halte sie als Abweichung fest, statt „the app shows the system's own“ (`colors.css:18`, `readme.md:205`).

3. **Feldgebundene Listen widersprechen Regel 4** (`readme.md:133`, `state-model.card.html:43`).
   - `SearchMenu.jsx:11-22` verschiebt den DOM-Fokus ins Menü (eine Listbox aus Buttons).
   - Seine Tastaturzeile ist `:focus-visible` = `--fl-hover`, also gleich Hover (`search.css:77`). `.is-on` = `--accent-soft` bedeutet dort „was der Graph zeigt“.
   - `SearchRow` setzt `highlighted` per Mausbewegung, und `--accent-soft` (`SearchPopover.jsx:37`, `.d.ts:39`) heißt dort auch „Hover“.
   - **Bitte:** ein Modell wählen und CSS, JSX und `.d.ts` angleichen. Vorschlag nach deiner eigenen Regel:
     - der Fokus bleibt im Feld (`aria-activedescendant`);
     - die Tastaturzeile ist `--accent-soft` mit Akzent-Icon;
     - Hover ist `--fl-hover`;
     - die angezeigte Variante wird durch Haken oder Tag markiert, nicht durch die Füllung.

4. **Erhöhter Kontrast: Hover wird schwächer als Ruhe.**
   - `--track-hover` und `--edge-hov` fehlen in `contrast.css`, in beiden Blöcken und in beiden `@media`-Kopien.
   - Slider-Track in Ruhe 4.04 (Night) / 3.73 (Paper), auf Hover nur 1.91 / 1.65.
   - Auf Paper ist der Kartenrand auf Hover kaum vom Ruhezustand zu unterscheiden (1.07:1). Betroffen: Karte, Bookmark-Chip, Stack, •••, Switch-Hover.
   - **Bitte** beide Tokens im Kontrastmodus kräftiger setzen als den Ruhezustand.

5. **Reine Füllungen in den hellen Paper-Familien.**
   - Orange, Gelb und Grün haben auf Paper absichtlich eine helle Füllung; die Linie trägt die 3:1.
   - Progress-Füllung (`controls.css:53`) und Badge (`controls.css:10`) haben aber keine Linie:
     - Gelbe Füllung gegen den Track: 1.03:1, unsichtbar (Grün 1.53, Orange 1.84; Rot Night 2.91);
     - Badge gegen die Insel: 1.44.
   - **Bitte** dort `--accent-line` nehmen oder eine Kante geben. Für den Slider-Fill gilt dasselbe, nur weniger dringend, weil der Thumb den Wert trägt.
   - In `readme.md:160` festhalten, welche Rollen die Füllung unter 3:1 nutzen dürfen.

6. **Tastatur, VoiceOver und Reduce motion pro Control.** `readme.md:138` sagt, sie stünden in jeder `.prompt.md`. Vollständig sind nur Checkbox, Segmented und Disclosure. Bitte je eine Zeile „Keyboard · VoiceOver · Reduce motion“ ergänzen, vor allem:
   - **Dialog/Popover:** Esc, Initialfokus, Fokusfalle, Fokus-Rückgabe, Klick auf den Scrim. `Dialog.jsx:32` sagt „Close (Esc)“ ohne Handler.
   - **ScrollArea:** Scrollen per Tastatur, Klick in den Track (Seite oder Stelle, wie macOS), horizontal, Overscroll; der Viewport-Fokus wird abgeschnitten (siehe B3).
   - **Switch, Menu** (Tasten nur im JSX-Kommentar), **Chip, Link, FileRow.**
   - **ProjectMenu:** Pfeiltasten, Typeahead, Blink und `closing` wie Menu.
   - **ProjectRow:** laut Readme jetzt mit Fokus, aber `tabIndex` und Tree-Tasten fehlen.
   - **Tooltip:** Flip und Clamp am Fensterrand.

## B. Inkonsistenzen, die wir sonst raten müssten

1. **Reduce transparency** greift nur für `.zs-glass` und `.zs-island--panel`, und das Panel behält `backdrop-filter`.
   - Toast, großer Primary, AtPill und die Scrims behalten ihren Blur; eine `prefers-reduced-transparency`-Abfrage gibt es nicht.
   - **Bitte** als Token-Delta wie `contrast.css` (solide `--fl-bg`/`--fl-bg-strong`, Blur `none`) und die Komponentenregeln streichen.
2. **„Deaktiviert mit Grund“ (`aria-disabled`)** hat nur die Deckkraft (`base.css:28-29`). Bitte eine generische Regel festlegen:
   - Hover zeigt den Tooltip, aber keine Füllung;
   - kein Press, keine Aktivierung per Zeiger oder Tastatur;
   - fokussierbar ja oder nein (VoiceOver)?
3. **Fokus:**
   - Die Basisregel `base.css:18` hat die Spezifität (0,2,1). Sie schlägt das `outline:none` der Menüzeilen mit (0,2,0) (`menus.css:14, :56`; `search.css:77`). ProjectMenu- und SearchMenu-Zeilen sowie der Menü-Container bekommen deshalb doch einen Ring.
   - Abgeschnittener oder unsichtbarer Fokus: ScrollArea-Viewport, `.zs-diff-collapsed` (`overflow:hidden`), `.zs-proj-more` (Deckkraft 0 außer bei Zeilen-Hover).
4. **Text auf Tönungen unter 4.5:1:**
   - Rot Night `--accent-text` auf soft 3.90, auf soft-hi 3.42. Betroffen: Toggle-Chip, Scope-Pille, `.zs-rsd-ci`.
   - `--text-faint` und `--text-dim`:
     - auf fl-on/press-Zeilen bis 2.93, z. B. `.zs-proj-count`, `.zs-gs-hash`, `.zs-dialog-navcount`;
     - der Tooltip-Shortcut `.zs-tip-k` 3.94.
   - Bitte die Werte anheben oder festlegen, dass auf diesen Flächen `--text-muted` gilt.
5. **Paper-Gelb:** `--accent-line` #877405 hat zum Gold-Primary nur ΔE .055.
   - Das ist nicht gemeldet; der Kollisionssatz der Card (`colors-accents.html:133`) prüft den Primary nicht.
   - Linie verschieben, oder als bewusste Ausnahme notieren und den Primary in den Satz aufnehmen.
6. **RevsetDialog** nutzt noch natives `<select>` (`RevsetDialog.jsx:134, :141`). Bitte:
   - das eigene `Select` verwenden;
   - eine Exit-Animation (`closing`) ergänzen;
   - Pressed-Stufen für `-x`, `-ib`, `-item`, `-not`, `-ci`, `-chip`, `-link`, `-empty`.
7. **Select:** Die Platzierung steht nur als JSX-Arithmetik (`Select.jsx:26-38`). Bitte in `Select.prompt.md` schreiben:
   - die gewählte Zeile liegt mittig auf dem Trigger;
   - die Text-x stimmen überein;
   - Breite = Trigger + 40, höchstens 360;
   - 8 px Clamp.
   - Dazu: lange Listen (Maximalhöhe, Scrollen), Transform-Origin von der gewählten Zeile, Drücken–Ziehen–Loslassen. Typeahead fällt bei Mono-Labels (`<code>`) aus.
8. **Submenü** öffnet sofort, ohne Safe-Triangle, immer rechts, ohne Flip und ohne Schließregel. Bitte Verzögerung, Toleranz, Flip und Schließverzögerung angeben.
9. **Fehlende Kombinationen in der Zustandstabelle:**
   - on + hover und on + pressed für neutrale Controls (Chip, FileRow);
   - Segment-Hover: die Tabelle sagt eine Füllstufe, das CSS ändert nur die Schrift;
   - SearchField: Füllung statt Kante wie bei Texteingabe; bewusst? Dann als Ausnahme nennen;
   - Scope-Pille und ✕ im GraphSearch ohne Pressed;
   - eine eigene Switch-Zeile (Ruhe 1 px `--border-strong`, Hover leiht `--edge-hov`, ein Graph-Token).
10. **Slider:**
    - Der Fokusring ist literal (3 px Kartenfarbe + 5 px) und ignoriert `--focus-w`.
    - Bild↑/↓/Pos1/Ende bleiben „native“; bitte die Schritte angeben.
    - `effects.css:52` nennt „slider value“ bei `--dur-toggle`, `Slider.jsx` sagt „kein Tween“. Was gilt bei Tastaturschritten und Klick in den Track?
11. **Motion ohne Token oder gegen die Kurven-Regel:**
    - **Werte ohne Token:**
      - Toast-Haltezeit 6,5 s;
      - „Copied“ 1200 ms;
      - Peek 450 ms;
      - Skeleton-Verzögerung ~150 ms;
      - Typeahead-Fenster 600 ms;
      - die „kurze Pause“ des DropMenu;
      - AtPill 320 ms;
      - Calm-Scrolling nur als Kit-Literale mit CSS-`ease` (`kit.css:33, :177-181`). Das braucht unsere Shell-Story als Tokens.
    - **Gegen die Kurven-Regel:**
      - indeterminierter Balken auf `--ease-state` statt `--ease-linear`;
      - der Tooltip steigt auf `--ease-state` auf;
      - der Fokusring animiert auf glide, das Readme sagt state.
    - **Benennung:** `--delay-tooltip-warm` ist das Fenster, nicht die Verzögerung.
12. **„Ein Menü“** ist unvollständig:
    - PeekCard und im Kit Stack-Popover und Gap-Callout nutzen noch `--bg-elevated` mit Radius 10 und `--shadow-popover`;
    - die Elevation-Card hat vertauschte Labels;
    - `--surface-menu` zeigt noch auf `--bg-elevated`.
    - Entweder ist der Peek bewusst ein eigenes Material (dann so benennen), oder alles auf das eine Menü-Material.

## C. Doku und Kleinigkeiten

- **Veraltete Zahlen und Tokens:**
  - Toast 38/28 → 36/26 (`Toast.d.ts:3`, `Toast.prompt.md:10`);
  - SearchField 32 → 30;
  - Segmented-Kommentar tabs/inset;
  - ProjectMenu 30 → 28;
  - SearchPopover-Radius 12 → 13;
  - AtPill 320.
  - **Wichtig: `DiffHunk.prompt.md:8` und `DiffView.prompt.md:11` sagen `--accent-soft` für den Hunk-Header, das CSS nutzt richtig `--hunk-bg`.** Genau diese Trennung sollte das DS herstellen.
  - Textmarkierung in `TextField.prompt.md:10` und `select.card.html:65`: zuerst die macOS-Markierung, `--accent-select` nur als Fallback.
  - `readme.md:164`: „1.6:1“ → 1.23:1.
  - Die Danger-Tönung wird in der Accent-Card auf `#1c2138` gemessen; Menüs stehen auf `--fl-bg-solid` + Sheen. Oben im Sheen ergibt sich 4.16.
- **Kbd:** `Kbd.prompt.md:1` („in Tooltips, Menüs“) widerspricht der Key-Cap-Regel (`readme.md:61`, `Link.prompt.md:10`).
- **Größen außerhalb der Skala:**
  - Icons: Segmented-Tabs-Icons und Spinner 13 statt 14;
  - Höhen: Dialog-Navigationseintrag 32 statt 30.
- **Literale Farben in Komponenten** → Tokens:
  - inset-Segmented `rgba(0,0,0,.2)` / `rgba(58,46,34,.07)`;
  - Viewed-Chip .02/.04;
  - `.zs-rsd-in`/`.zs-rsd-sel` = `--field-bg` als Literal;
  - `.zs-ghost-cmd`-Schatten ohne Paper-Variante;
  - Mark-Chip-Schatten.
  - Toter Code: `.zs-viewed-box`, die Keyframes `zs-rsd-fade`/`zs-rsd-in`, `.zs-alert.is-warn` ungestylt.
- **Kontrastmodus:** Paper-`--border-strong` erreicht auf dem dunkelsten Canvas-Stopp `#e8e3dd` nur 2.97, und der Tagestrenner liegt genau dort. Bitte minimal abdunkeln; Night auf dem Lift 2.99 genauso.
- **Near-Miss-Liste** (`readme.md:160`) ergänzen:
  - Grün ≈ ahead (Paper) .050;
  - Graphit ≈ missing (Paper) .051;
  - Graphit Night ≈ `--text-muted` .034, Graphit Paper ≈ `--text-dim` .037. Bitte als „bewusst wie macOS“ notieren.
- **Kommentar-oklch passt nicht zum Hex:**
  - `--co`/`--saffron-paper` #a56205 ist oklch(55.9% .124 64.7), nicht (56% .125 65);
  - fünf Kommentare in `accents.css` liegen außerhalb des sRGB-Gamuts.
  - Bitte die Kommentare aus den Hex-Werten neu schreiben.
- **`motion.html:14`** zeichnet `--ease-exit` als (.4,0,1,0) statt (.4,0,1,1); die tote `.spring`-Klasse dort entfernen.
- **Icons:**
  - Die neue Regel „1 Einheit Luft“ brechen 13 Glyphen. Am dringendsten ist das „!“ in `conflict`: Balken–Punkt 0.30 Einheiten, also 0.225 px bei 12 px auf den Karten-Flags.
  - Die übrigen: alert 0.80, sun 0.37/0.45, file-text, history, insert-after/-before, squash 0.50, duplicate, move-onto, pull 0.75, settings 0.90, calendar 0.00.
  - `alert` und `conflict` zeichnen das „!“ verschieden (Balken 3.75 gegen 3).
  - user und merge-new berühren sich: gewollt?
  - `cloud` ragt 0.01 aus dem Live-Bereich.
  - `guidelines/brand-iconography.html:12` lädt das gelöschte `edit.svg` (404). Außerdem dort veraltet: Label „18px“ (jetzt 19), in der Legende „45 files, #000“ und die Unicode-Liste. „no icon font“ stimmt nach dem nächsten Punkt wieder.
  - **Den Icon-Font brauchen wir nicht mehr.** Die App rendert die SVG-Quellen aus `assets/icons/ui/`: beim Build vorkompiliert (`vector_graphics_compiler`), zur Laufzeit in einer Farbe eingefärbt.
    - Bitte löschen: `assets/icons/font/`, `assets/icons/outline.js`, den Font-Umschalter der Card „Icons — on the grid“ (`guidelines/icons-grid.html:1`) und den FlutterIcon-Kommentar in `components/brand/Icon.jsx:4`.
    - Den Punkt „Icon font (FlutterIcon)“ (`readme.md:231`) und den Font-Eintrag der Asset-Tabelle (`readme.md:248`) durch eine Zeile ersetzen: „Die Flutter-App rendert `assets/icons/ui/*.svg`, beim Build vorkompiliert und zur Laufzeit in einer Farbe eingefärbt; es gibt keinen Icon-Font.“
    - Das ersetzt die frühere Bitte, in `readme.md:231` Figma durch `outline.js` zu korrigieren.
  - **`assets/icons/glyphs.json` bleibt**, genau im heutigen Format: Namen = Dateinamen in `ui/`, Aliase = alter Name → aktueller Name. Bitte bei jedem neuen, umbenannten oder entfernten Glyph mitpflegen; unsere App prüft ihre Icon-Liste dagegen.
  - **Dateiregeln in ICONOGRAPHY** (`readme.md:230`). Alle heutigen Dateien halten sie schon ein; neu gezeichnet werden muss nichts. Die Regeln sollen künftige Glyphen so halten, denn unser Build-Compiler verwirft stillschweigend, was er nicht kennt. Ein `<style>`-Block etwa würde jeden Strich zur schwarzen Fläche machen.
    - Wurzel genau `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">`, darin genau ein `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">`.
    - Darin nur `path`, `circle`, `rect`, `line`, `polyline`, `polygon` und `ellipse`. Flächen mit `fill="currentColor"`, dazu `stroke="none"`, wo es keine Kontur gibt.
    - Gestaltung nur über Präsentationsattribute: kein `<style>`, kein `class`, kein `style=""`.
    - Kein `id`, `transform`, `opacity`, `mask`, `clipPath`, `filter`, kein Verlauf, kein `<use>`, `<symbol>`, `<defs>`, `<image>`, `<text>`, `<title>`, `<desc>`, keine Kommentare.
    - Einzige Farbe ist `currentColor`, nie Hex: Die App färbt das ganze Glyph in einer Farbe, eine zweite Farbe ginge verloren.
    - Koordinaten mit höchstens 2 Nachkommastellen.
  - `Icon.prompt.md` ist komplett veraltet (45 Glyphen, #000, Größen). Bitte neu schreiben: die aktuelle Glyph-Zahl, `currentColor`, die sechs Größen-Tokens (xs 10 · sm 12 · md 14 · lg 16 · bar 17 · rail 19) und „kein Icon-Font, die App nutzt die SVG-Quellen“.
  - `readme.md:226`: In der Liste „nicht verwendet“ fehlen hash und chevron-left.
  - **Nur zur Info, keine Aktion:** Jede exportierte SVG trägt vom Download einen etwa 8 KB großen C2PA-Block (`<metadata>`, Content Credentials). Den entfernen wir beim Import selbst. Bitte keine weiteren Metadaten in die Icon-Dateien schreiben.
- **Zustandszeile pro Komponente:** Bitte in jedem Komponenten-`.d.ts` die Kopfzeile einheitlich mit „States: …“ führen, wie `Button.d.ts:3`. Wir bauen einen Komponenten-Katalog und leiten seine Zustandsmatrix daraus ab, statt sie zu erfinden.
- **Status-Pille:** In der Control-Bibliothek auf `Flag` und den OPEN-Marker verweisen.
- **Cursor-Regel:** Auch den I-Beam über Texteingabe und `cursor:progress` bei busy nennen.

## D. Neu zu spezifizieren

1. **Inaktives Fenster** (nicht Key-Fenster): Welche Akzente werden grau? Ausgewählte Karte, fokussierte Zeile, eingeschaltete Switches und Checkboxen, der Primary? Zeigt das Fenster noch Fokus? Bitte als Zeile in die Zustandstabelle.
   - Das wird der Normalfall: Sobald Settings oder Projects als eigenes Fenster aktiv ist (Abschnitt G), ist das Projektfenster inaktiv.
   - Bitte für das Projektfenster und für die neuen Fenster angeben.
2. **Markierte Glyphen:** Flutter malt bei Textauswahl nur den Hintergrund; eine API für die Vordergrundfarbe gibt es nicht.
   - In Textfeldern färben wir die markierten Zeichen in `--text`. In Nur-Lese-Text (Diff, IDs) bleibt vorerst nur der Hintergrund.
   - Bitte prüfe, ob das für die Standard-Markierungen lesbar genug ist, oder sag uns, wo es nicht reicht.
3. **`name@` auf Karten.** Ein jj-Repo kann mehrere Workspaces haben: eigene Verzeichnisse mit eigenem `@`, die sich ein Repo teilen (`jj workspace add/list/forget/rename/remove/update-stale`). Dann zeigt `jj log` an jedem Working-Copy-Commit `name@`, den eigenen Workspace eingeschlossen (`default@`). Mit nur einem Workspace zeigt es keine Marker, und so soll es auch bei uns sein.
   - Wie sieht `name@` auf der Karte aus, und wie verträgt es sich mit unserer goldenen `@`-Markierung?
   - Wie sehen mehrere Namen auf einer Karte aus?
4. **Zustand „Working copy is stale“.** Hat ein anderer Workspace oder die CLI das `@` dieses Workspace umgeschrieben (etwa durch ein Rebase eines Vorfahren), verweigert jj alles, was die Working Copy liest, auch `jj log`, bis `jj workspace update-stale` läuft. Bei mehreren Workspaces ist das kein Randfall.
   - Bitte einen Zustand auf Projektebene entwerfen (Graph und Kopfzeile, nicht in einem Menü, denn auch die Workspace-Liste verweigert dann).
   - Der Graph behält das letzte gültige Layout, wie bei einem Revset-Fehler.
   - Ein Satz („Working copy is stale“) und der Befehl, der es behebt: `jj workspace update-stale`. Ein Retry hilft nicht und gehört nicht hinein.
   - Später kommt eine Aktion „Update working copy“ dazu (Befehl im Tooltip, danach der übliche Ergebnis-Toast). Bitte beide Varianten zeigen: nur Hinweis, und Hinweis mit Aktion.

## E. Inhaltliche Klarstellungen

- **ConfirmDialog-Beispiel** (`ConfirmDialog.prompt.md:4-7`): `jj git push --allow-backwards` gibt es in jj v0.46.0 nicht. Rückwärtsbewegungen braucht kein Schalter. Und die UI darf keine Folge von Operationen selbst zusammenbauen.
  - `jj undo` eines Push warnt nur („Undoing a push operation often leads to conflicted bookmarks.“) und rät zu `jj redo`.
  - Bitte ein Beispiel wählen, das wirklich etwas Unumkehrbares tut, ohne erfundene Optionen. Push gehört nicht mehr hierher: Er bekommt seinen eigenen Dialog (Abschnitt F).
- **⌘Z** (`Toast.prompt.md:13`, „frühere Undos bleiben mit ⌘Z erreichbar“): Rückgängig gibt es an drei Stellen:
  - der Undo-Knopf im Toast;
  - ⌘Z bzw. Bearbeiten › „‹Aktion› widerrufen“, nur für Zanshins eigene letzte Operation und nur, solange sie noch die aktuelle ist. Der Menüeintrag nennt die Aktion; danach erscheint ein Toast „Undid … · Redo“. ⇧⌘Z wiederholt. ⌘Z geht nie weiter zurück und nie über fremde Operationen (CLI, andere Workspaces);
  - die Undo Timeline für alles Ältere, denn dort sieht man, was man zurücknimmt.
  - Bitte `Toast.prompt.md:13` entsprechend ändern. Das Menü selbst kommt mit der Menüleisten-Spezifikation (deine offene Liste).
- **„jj missing or too old“** (`readme.md:215`) gibt es bei uns nicht: Zanshin bettet jj-lib ein und braucht kein jj-Binary.
- **Theme-Namen:** Ja zu `night`/`paper`, mit `light` als Alias. Bitte umstellen; das UI-Kit setzt heute `data-theme="dark"`, das passt zu nichts.
- **„Workstreams“ gibt es in jj nicht.** Weder jj v0.46.0 noch der aktuelle jj-`main` kennt einen Befehl oder Begriff `workstream`; upstream gibt es nur offene Feature-Requests (#7845 schlägt `jj marker` vor, #3402 „Topics“). `jj workstream new` ist erfunden. Gemeint sind auch nicht jj-Workspaces: Das Design hat keinerlei Workspace-Bezug (für die siehe D3/D4).
  - Bitte den Rail-Eintrag ganz entfernen, nicht umbenennen: `ui_kits/desktop/chrome.jsx:9` und `:127`, `components/surfaces/Callout.prompt.md:1` und `:4-5`, `components/surfaces/surfaces.card.html:37`, `components/actions/actions.card.html:36`.
  - Dazu das Glyph `workstream`: `assets/icons/ui/workstream.svg`, der Eintrag in `assets/icons/glyphs.json`, `components/brand/Icon.jsx:64` und die Liste in `Icon.d.ts:5`.
  - Die Rail behält Bookmarks, Reviews und Undo Timeline. Als Callout-Beispiel bitte Bookmarks oder Undo Timeline nehmen.
- **Beispielsatz für leere Zustände** (`readme.md:55`): bitte durch einen echten ersetzen, z. B. *No bookmarks yet. Create one with `jj bookmark create <name>`.*
- **Neue Regel unter CONTENT FUNDAMENTALS:** Jeder jj-Befehl in einem UI-Text muss in jj v0.46.0 genau so existieren, mit genau diesen Optionen. Keine erfundenen Verben oder Flags (vgl. `--allow-backwards` und `jj workstream new` oben). Das folgt aus eurer eigenen Regel „Zanshin never hides what it runs“: Ein Befehl, den es nicht gibt, kann Zanshin nicht ausführen.

## F. Neu: der Push-Dialog
[claude-design-prompt-ds-round-3-2026-10-16.md](claude-design-prompt-ds-round-3-2026-10-16.md)
Push soll nicht sofort laufen, sondern einen Dialog öffnen, in dem man auswählt, was gepusht wird. Gerade für Umsteiger von Git ist ein Push ohne Vorschau gefährlich: jj arbeitet nicht branch-basiert. Ein Klick kann mehrere Bookmarks auf einmal bewegen, auch rückwärts oder seitwärts, was die Remote-Historie überschreibt; oder er tut gar nichts, weil an @ kein Bookmark hängt.

Bitte entwirf diesen Dialog auf dem 18-px-Dialog-Sheet über dem Projektfenster, wie ConfirmDialog und jj log Configurations (Settings und Projects werden eigene Fenster, siehe G). Er ist eine Oberfläche für genau die Parameter von `jj git push` (jj v0.46.0): Die UI erfindet nichts dazu und baut keine Befehlsfolgen.

- **Vorauswahl = was `jj git push` ohne Argumente tut:** getrackte Bookmarks (und Tags), die auf `remote_bookmarks(remote=<remote>)..@` zeigen. Die Menge ist über `revsets.git-push` einstellbar.
- **Bookmarks einzeln wählen:** `--bookmark <name>`, wiederholbar. Ein noch nicht getracktes Bookmark wird beim Push automatisch getrackt. Sammelwahlen: `--all` (alle), `--tracked` (alle getrackten), `--deleted` (gelöschte auf dem Remote entfernen).
- **Einen Change pushen, z. B. @:**
  - `--change <rev>` erzeugt ein Bookmark nach `templates.git_push_bookmark`, Standard `push-` + kurze Change-ID. Das ist der „zufällige“ Name, den Git-Umsteiger nicht erwarten.
  - Mit eigenem Namen: `--named <name>=<rev>`.
  - Der Dialog zeigt den erzeugten Namen vorab und lässt ihn ändern; aus dem geänderten Namen wird `--named`.
- **Remote:** `--remote`, wiederholbar und als Muster. Standard ist `git.push`, sonst `origin`.
- **Vorschau:** `--dry-run` liefert, was sich auf dem Remote ändert: neu, vorwärts, rückwärts oder seitwärts, gelöscht.
  - Rückwärts und seitwärts überschreiben die Remote-Historie (Prüfung wie bei `--force-with-lease`).
  - Bitte jede Art sichtbar unterscheiden; rückwärts/seitwärts und Löschen als Warnung.
- **Sicherheitsprüfungen:** Leere Beschreibung, private Commits und Konflikte verweigern den Push. Die CLI kennt dafür `--allow-empty-description`, `--allow-private` und `--allow-conflicts`. Zeig die Verweigerung mit Grund und die Möglichkeit, sie bewusst zu erlauben.
- **Footer:** der exakte `jj git push …`-Befehl, der laufen wird („Zanshin never hides what it runs“), Primary „Push“ (gold), Cancel.
- **Zustände:**
  - nichts zu pushen (leere Auswahl);
  - Fehler: Netzwerk, Authentifizierung, „das Remote hat sich seit dem letzten Fetch geändert — erst fetchen“;
  - läuft, mit Fortschritt.
- **Danach:** der Ergebnis-Toast wie gehabt. Das Rückgängigmachen eines Push warnt wie die CLI („Undoing a push operation often leads to conflicted bookmarks.“).

Bitte als Komponente mit Card, inklusive der Zustände in Night und Paper.

## G. Neu: Settings und Projects als eigene Fenster

Settings und Projects öffnen wir als eigene macOS-Fenster statt als Sheet im Projektfenster:
- macOS-Settings sind ein Fenster. Laut HIG zeigt der Titel den sichtbaren Bereich, der zuletzt gezeigte Bereich kehrt zurück, Minimieren und Zoomen sind ausgegraut, ⌘, öffnet es.
- Projects gehört zu keinem Projekt und dient als Startfenster.
- Sheets stapeln sich nicht mehr, etwa ⌘, über einem offenen Projects.

Technisch sind beide schließbar, nicht minimierbar und liegen auch im Vollbild über dem Projektfenster.

1. **Settings-Fenster**, eines für „Settings…“, „Project Settings…“ und „Appearance, diffs and more“.
   - Die Tabs [General | Project] sitzen als Segmented Control in der Kopfzeile. Der Fenstertitel ist der Name des Tabs; er erscheint im Fenstermenü und in Mission Control, auch wenn die Titelleiste ihn nicht zeigt.
   - Breite 620. Die Höhe folgt dem Tab, höchstens 740. Nicht größenveränderbar.
   - Kein ✕, und Esc schließt nicht. Geschlossen wird mit dem roten Knopf oder ⌘W. Änderungen gelten sofort, wie bisher.
   - „Project Settings…“ öffnet den Tab Project, „Settings…“ und „Appearance, diffs and more“ öffnen General. ⌘, öffnet den zuletzt gezeigten Tab.
   - Ohne offenes Projekt ist der Tab Project deaktiviert. Mit Projekt zeigt er Namen und Marke des Projekts.
   - Der Inhalt der Tabs bleibt, wie du ihn entworfen hast.
2. **Projects-Fenster** („All Projects…“).
   - Standard 900 × 640, größenveränderbar. Bitte eine Mindestgröße angeben.
   - Die Sidebar beginnt unter den Ampeln; der Marken-Block rutscht unter die Kopfzeile.
   - Esc leert die Suche, schließt aber nicht.
   - Startzustand „kein Projekt offen“: Projects ist das einzige Fenster der App, und Schließen beendet die App. Ein Projekt zu öffnen schließt Projects und öffnet das Projektfenster.
   - Settings aus der Sidebar öffnet das Settings-Fenster daneben.
3. **jj log Configurations bleibt ein Sheet** über dem Projektfenster, wie ConfirmDialog und Push. Es ist eine OK/Cancel-Aufgabe, und die Ansicht wechselt erst bei OK. Hier ändert sich nichts.
4. **Das Fenster-Gerüst**, für 1 und 2:
   - Kein Scrim, kein 18-px-Radius, kein `--shadow-dialog`, keine Ein- oder Ausblendung. Ecken, Schatten und Erscheinen liefert das System.
   - Kein ✕ im Inhalt; dafür gibt es den roten Knopf.
   - Die Füllung ist randlos und deckend. Bitte bestätigen, dass `--fl-sheen` über `--fl-bg-solid` gilt, oder sagen, wo Vibrancy gewünscht ist (etwa in der Projects-Sidebar).
   - Die Kopfzeile ist etwa 52 pt hoch und teilt sich die Zeile mit den Ampeln. Gemessen auf macOS 27 unter unserer Toolbar liegt der Block bei x 19–79, Zentrum y 26; es gilt die Regel aus A2, also erstes Element bei Block-Ende + 12. Bitte zeigen, wo der Titel sitzt und wie Controls in der Kopfzeile stehen.
   - Die grauen Ringe wie im Projektfenster (A2), auch für ausgegraute Knöpfe. Bei Settings ist nur Schließen aktiv, bei Projects Schließen und Zoomen.
   - Die leere Fläche der Kopfzeile zieht das Fenster.
   - Bitte als Card in Night und Paper, aktiv und inaktiv (D1).
5. **Menüleiste** (deine offene Liste, `readme.md:212`), bitte mit:
   - Zanshin › Settings… ⌘,: öffnet oder aktiviert das Settings-Fenster mit dem zuletzt gezeigten Tab und schaltet nie um. „Preferences…“ heißt jetzt „Settings…“.
   - File › Close Window ⌘W.
   - Window › Projects (optional).
   - Wo „All Projects…“ und „Edit Configurations…“ stehen und mit welchem Kürzel.
   - Edit › „Undo ‹Aktion›“ ⌘Z und „Redo“ ⇧⌘Z, wie in E beschrieben.
6. **Aufräumen:**
   - `readme.md:88` („every floating dialog … is the same 18px glass sheet“) anpassen. Das Sheet mit Scrim gilt nur noch für ConfirmDialog, Push, jj log Configurations und ähnliche kurze modale Aufgaben. `--z-dialog` und `--dur-dialog` gelten nur für diese.
   - Settings und Projects im UI-Kit (`ui_kits/desktop/dialogs.jsx`) als Fenster zeigen.

---

## Prompt 2 — für das Projekt „Zanshin“ (Floating Client)

Erst senden, wenn Prompt 1 erledigt ist. Alles unterhalb dieser Zeile kopieren.

Das Design System hat eine neue Runde bekommen (siehe dort im `readme.md`). Bitte übernimm daraus für den Floating Client:
- **„Workstreams“ entfernen**, denn das gibt es in jj nicht: Rail-Eintrag, Panel, den leeren Zustand mit `jj workstream new` und das Glyph. Fundstellen: `app-float.jsx:22` und `:124`; `app-float-search.jsx:27` und `:129`; `app-shared.jsx:11`, `:166`, `:304`, `:346`, `:994` und `:1045-1048`; `app.jsx:67` und `:348`; `icons/ui/workstream.svg`. Die Archiv-Ordner kannst du lassen.
- **Settings** (mit Project Settings und „Appearance, diffs and more“) und **All Projects** als eigene Fenster nach Abschnitt G des Design Systems. jj log Configurations bleibt ein Sheet.
- **Push** öffnet den Push-Dialog aus Abschnitt F des Design Systems, statt sofort zu pushen.
- Bitte die Übernahme in `DESIGN-SYSTEM-SYNC.md` festhalten.

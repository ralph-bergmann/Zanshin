# Validierung Runde 2 — Design System und Floating Client (2026-10-16)

**Geprüft:** die Downloads vom 2026-10-15/16, `_bmad-output/implementation-artifacts/design_system/` (Runde „2026-10-16“) und `design/` (Sync #10), gegen den Prompt [`claude-design-prompt-ds-fixes-2026-10-15.md`](claude-design-prompt-ds-fixes-2026-10-15.md).
**Vorgänger:** [`design-system-validation-2026-10-15.md`](design-system-validation-2026-10-15.md).
**Folge-Prompt:** [`claude-design-prompt-ds-round-3-2026-10-16.md`](claude-design-prompt-ds-round-3-2026-10-16.md).

## Ergebnis

Runde 2 ist gründlich umgesetzt. Von 245 geprüften Einzelpunkten sind 198 vollständig erledigt, die übrigen fast alle teilweise; die Behauptungen, die das DS mit Zahlen belegt, stimmen beim Nachrechnen. Was offen ist, fällt in drei Gruppen:

1. **Eine kleine Runde 3 an Claude Design** (20 Punkte):
   - zwei Reste aus Runde 2;
   - fünf Token-Fragen;
   - fünf Lücken im Push-Dialog gegenüber jj;
   - fünf Fenster-Regeln, die du entscheiden musst, meist Widersprüche, die unser eigener Prompt angelegt hat;
   - neu: Inspector und Panels in der Breite ziehbar, und Configurations als eigenes Fenster;
   - ein Icon.
2. **Rund 130 Kleinigkeiten, die wir in Flutter einfach richtig bauen** (Abschnitt 4). Kein Prompt nötig.
3. **Folgen für die Stories** (Abschnitt 6), sobald wir sie anfassen.

## 1. Wie geprüft

- Zwölf Prüf-Agenten, je einer pro Bereich des Prompts (Motion, Fenster, Listen, Farbe, Tokens, Tastatur/VoiceOver, Icons, Doku/Befehle, Push, Workspaces, Client, ungefragte Änderungen). Jeder Bereich hatte einen eigenen Gegenprüfer, der jeden Befund zu widerlegen versuchte, dazu ein Kritiker für Lücken zwischen den Bereichen.
- Ergebnis der Gegenprüfung: 128 Befunde bestätigt, 37 korrigiert (meist herabgestuft oder als „nur Flutter“ eingeordnet), 1 widerlegt, 21 zusätzlich gefunden.
- Laufzeit selbst geprüft: alle 54 Seiten des Design Systems und die geänderten Seiten des Clients (Floating samt `?push`, `?push=network|auth|stale`, der angedockte Client, Search Study, Graph Lines, Graph Gaps, Animation Show Case): **0 Konsolenfehler, 0 fehlende Dateien.**
- Stichproben selbst nachgeprüft: der alte Push-Dialog in der Feedback-Card (`feedback.card.html:52-53`), Tags im Standard-Push (`push.rs:90-93`, `:539` @ v0.46.0) und die Gleichheit von Inaktiv- und Kontrast-Linie auf Paper (`#867e75` in `inactive.css:15` und `contrast.css:18`).
- Prozess: Das Nutzungslimit brach 13 Agenten ab, sie liefen danach neu. Zwei Agenten liefen ohne den Sicherheits-Klassifizierer; `git status` zeigt außer meinen Recherche-Dokumenten keine Änderung im Repo.
- Die ausführlichen Berichte liegen im Session-Scratchpad (`scratchpad/r4out/`), nicht im Repo.

## 2. Was nachweislich stimmt

- **Tokens:** 351 Tokens, 2 569 `var()`-Verwendungen, 3 888 Konfigurationen (Theme × Akzent × Kontrast × Transparenz × Fenster × Motion × Vollbild): 0 undefiniert, 0 Zyklen. Kein `color-mix()`, `oklch()` oder `lab()` mehr in Werten. 34 Tokens kamen neu dazu; entfernte haben keine Restverweise. `night`/`paper` überall, `light` als Alias, kein `data-theme="dark"` mehr.
- **A1 Bewegung reduzieren:** nach Eigenschaft, das Delta liegt in `tokens/motion.css`. Farb- und Deckkraft-Übergänge behalten ihre Tokens, jeder Exit blendet aus, der Flash ist wieder eine Farbblende. Alle genannten Literale (Toast-Haltezeit, „Copied“, Peek, Skeleton, Typeahead, DropMenu, AtPill, Calm Scrolling) sind Tokens. Reste sind Kleinigkeiten (Abschnitt 4).
- **A2 Ampeln:** exakt die gemessene Geometrie (14 pt, Teilung 23, Block x 19–79, Mitte y 26), die Regel „Block-Ende + 12“, der Mock 14 px, die grauen Ringe als bewusste Abweichung festgehalten. Rechnung: erste Insel bei 91, Bar 4–48, Inhalt ab 60; im Vollbild 12/12–56/68.
- **A3, B6–B8:** Ein Modell für feldgebundene Listen (Fokus im Feld, `aria-activedescendant`). RevsetDialog mit eigenem Select, Exit und allen Pressed-Stufen. Select-Platzierung und Submenü sind dokumentiert.
- **A4/A5/B4/B5/C Farbe:** alle Behauptungen nachgerechnet. Beispiele: Kontrastmodus Hover 6.74 gegen Ruhe 4.16; Fortschritt mindestens 3.34 (Night Rot); Rot-Text Night 6.17 auf der Tönung; Paper-Gelb zum Primary ΔE .076; Danger-Tönung 4.50 oben im Sheen; die 41 oklch-Kommentare liegen höchstens 0.05 daneben; die Zahlen zur Textmarkierung (D2) stimmen.
- **A6/B2/B3/B9/B10:** `useSheetFocus` (Initialfokus, Falle, Rückgabe), ScrollArea-Tasten, Tooltip mit Flip und Clamp, `aria-disabled` als eine Regel, Fokus-Spezifität (0,2,0), Slider-Ring und -Tasten. Neun `.prompt.md` haben keine Tastaturzeile; alle sind statisch, nur Radio und Segmented nennen ihre Tasten an anderer Stelle.
- **C Icons:** Alle 13 Glyphen haben jetzt ≥ 1 Einheit Luft, das „!“ ist in `alert` und `conflict` eine Zeichnung. Lint über alle 58 Dateien: 0 Verstöße. Kompiliert mit `parseWithoutOptimizers(warningsAsErrors: true)`: 58/58. `glyphs.json` entspricht genau den Dateien, `Icon.jsx` ist Byte für Byte daraus erzeugt, Font und `outline.js` sind weg. Geändert wurden nur die angefragten Glyphen.
- **D:** `tokens/inactive.css` für das inaktive Fenster, `name@` (`AtBadge name`, `WorkspaceTag`), `StaleNotice` in zwei Varianten, kein Workspaces-Abschnitt im Project-Menü.
- **E:** Workstreams sind weg, im DS, im Bundle und im Client (nur noch in Archiv und Änderungslog). Die Regel „Every command is real“ steht in CONTENT FUNDAMENTALS; alle *neuen* Texte halten sie ein. `jj op abandon ..@-` ist gültig und wirklich unumkehrbar. Der ⌘Z-Text folgt E7, und „jj missing“ ist weg.
- **F:** `PushDialog` gibt nur echte Flags aus. Vorauswahl, `--change` mit angezeigtem Namen und `--named` sind umgesetzt, ebenso `--dry-run`-Arten mit Warnungen, die drei `--allow-*`, die Fußzeile mit dem Befehl, die Zustände und die Undo-Warnung wortgleich mit der CLI.
- **G:** Settings und Projects sind Fenster: 620 breit, Höhe bis 740; Projects 900 × 640, mindestens 680 × 440. Dazu Kopfzeile, Ringe, Startfenster, kein ✕, kein Esc-Schließen. Configurations bleibt Sheet. Die Menüleiste ist vollständig spezifiziert.
- **Prompt 2 (Client):** Workstreams weg, Settings und Projects als Fenster mit Key- und Inaktiv-Zustand, Push öffnet das Sheet, Sync #10 ist eingetragen. Der Client hat aus eigenem Antrieb die Verweigerung für den Change ergänzt; sie ist richtig. Bewusst nicht übernommen: A–D, die Menüleiste und die neue Ampel-Geometrie (A2). Für Flutter gilt das DS.

## 3. Was an Claude Design geht (Runde 3)

Die Punkte stehen ausformuliert im Folge-Prompt. Kurzfassung:

| # | Punkt | Warum es nicht in Flutter allein geht |
|---|---|---|
| A1 | Die Feedback-Card zeigt noch den alten ConfirmDialog „Undo the push to origin?“ mit dem erfundenen `jj git push --allow-backwards` und einer Befehlsfolge (`feedback.card.html:52-53`), dazu „Undo push“-Beispiele in drei weiteren Dateien | Der Katalog leitet seine Beispiele aus den Cards ab; das DS behauptet, es sei erledigt (`readme.md:249`) |
| A2 | Die Scope-Pille hat auf ihrem echten Untergrund in den meisten Familien Akzent-Text unter 4.5 (Night Blau ab 3.79, Paper Grün ab 3.93); B4 hatte genau sie genannt | Komponentenfarbe, die das DS festlegt |
| B1 | Kontrastmodus: Die Slider-Füllung verschwindet gegen den neuen opaken Track (Paper Orange 1.03:1, Night Rot 1.11:1) | Token-Werte; unser Token-Paritätstest folgt dem DS |
| B2 | Inaktives Fenster: Fortschritt und Edit-Flash werden grau, obwohl `inactive.css:7` sagt, sie bleiben; Badge, Links und Drop-Ziel sind nicht eingeordnet | Token-Struktur |
| B3 | Inaktiv × erhöhter Kontrast: Die ausgewählte Karte ist unsichtbar (Paper 1.00:1, Night 1.13:1) | Token-Werte |
| B4 | „Stale“ braucht einen eigenen Projektstatus; `--warn` ist in Night vom „dirty“-Gelb nicht zu unterscheiden (ΔE .036) | neue Farbe |
| B5 | (optional) Kollisionen unter ΔE .06, die nicht gelistet sind, z. B. Paper-Grün-Text ≈ add .049 | Token-Werte oder Doku |
| C1 | Tags fehlen im Push-Dialog, obwohl der Standard-Push, `--tracked`, `--all` und `--deleted` sie mitschicken | Entwurf fehlt; sonst zeigt der Dialog nicht, was läuft |
| C2 | Die Verweigerung für den Change aus dem Client (Sync #10) ins DS übernehmen | Das DS zeigt sonst ein `--change @`, das jj ablehnt |
| C3 | Verweigerungen ohne Allow (Autor/Committer fehlt, Bookmark in Konflikt, Remote-Tracking-Fälle) und mehrere Gründe pro Commit | Entwurf fehlt |
| C4 | Mehrere Remotes: jj klassifiziert pro Remote; `git.push` kann Liste oder Muster sein | Entwurf fehlt |
| C5 | Fehlermodell: Ablehnung pro Bookmark mit Teilerfolg, „remote rejected“, Lease-Hinweis wie jj | Entwurf fehlt |
| D1–D5 | Fenster-Regeln nach deiner Entscheidung (Abschnitt 5) | Widersprüche aus unserem Prompt und Architektur |
| D6 | Inspector (linke Kante) und angeheftete Panels links (rechte Kante) in der Breite ziehbar: Greifzone, Min/Max als Tokens, Doppelklick = Standard, Breite gemerkt (Ralph, 2026-10-16) | neue Interaktion und neue Tokens |
| D7 | jj log Configurations als eigenes Fenster: verschiebbar, größenveränderbar, über dem Projektfenster (Abschnitt 5, Punkt 6) | Architektur und Entwurf |
| E1 | `move-only.svg`: `rx="1.5"` bei 2.5 Höhe; unser Compiler klemmt das nicht und zeichnet es anders als der Browser | Datei-Inhalt (Byte-Parität) |

## 4. Was wir in Flutter selbst richtig machen (kein Prompt)

Für die Stories festgehalten; Claude Design muss dafür nichts tun.

**Stale Working Copy (10.5, 9.23, 10.3)**
- Nach „Update working copy“ gibt es **kein Undo**. `jj workspace update-stale` schreibt meist keine eigene Operation, ein Undo träfe die fremde Operation (E7). Der Toast nennt die CLI-Ausgänge: auf frischen Commit aktualisiert, war nicht stale, Recovery-Commit angelegt.
- Im Stale-Zustand verweigert jj auch alle Lesezugriffe: Inspector, Suche, Undo Timeline, Bookmarks, Push. Nur das letzte Layout und seine Karteninhalte (`commit_contents`, ohne Snapshot) bleiben. Alles andere ist nach der B2-Regel „deaktiviert mit Grund“; Lesen mit `--ignore-working-copy` bieten wir nicht an (CLI-Parität).
- Ein Projekt, das schon beim Öffnen stale ist, hat kein Layout: Der Hinweis steht dann über der leeren Fläche. Den Zustand verlässt man auch über den Checkout-Heartbeat des Watchers, denn `update-stale` im Terminal schreibt oft keine Operation.
- jj kennt drei Ursachen (stale, Geschwister-Operation, verlorene Operation); `update-stale` behebt alle drei. Den Text übernehmen wir je Ursache von jj.
- Backend: Der Graph-Draht nennt unseren eigenen Workspace-Namen nicht; `ChangeCard` braucht ihn (`ownWorkspace`). Die Namen stellen wir als jj-Symbole dar (bei Bedarf in Anführungszeichen).
- Meta-Zeile mit mehreren `name@`: Wir legen fest, was weicht (erst Tags in `+N` falten, dann Namen kürzen, dann das Datum). Die Demo-Karte des DS läuft bei 240 px etwa 35 px über.

**Befehle im UI**
- Befehle stehen in Menüs, Tooltips und im Inspector immer vollständig mit Change-ID (`jj new -A kmnvxoqp`, `jj edit kmnvxoqp`). `jj new -A` und `jj edit` ohne Argument, wie im DS, gibt es nicht.
- Kopierbare Befehle werden shell-sicher gequotet. Musterwerte (`--bookmark`, `--remote`) bekommen bei Bedarf `exact:`.
- Den Tooltip der Redo-Pille setzen wir auf `jj redo`.

**Push (9.20, 11.8)**
- Die Vorauswahl kommt aus dem Backend: `revsets.git-push` pro Remote ausgewertet, nicht `pushPlan` aus dem Client.
- Der `push-…`-Name kommt aus `templates.git_push_bookmark`. Standard sind 12 Zeichen, die Mocks zeigen 8.
- Das Namensfeld zeigt den Fehlerzustand des TextField (Name existiert, ungültig, leer); Push ist dann deaktiviert.
- Ohne Auswahl zeigt die Fußzeile nicht `jj git push`. Esc bricht während des Pushens nicht ab.
- Die Bezeichnungen der Dry-Run-Arten folgen jj; `git.sign-on-push` schreibt Commits um, das zeigen wir an.

**Undo (10.23, 9.21, 11.9)**
- Der Undo-Knopf im Toast verschwindet, sobald seine Operation nicht mehr die aktuelle ist, wie bei ⌘Z (E7).
- Nach `jj op abandon ..@-` gibt es kein Undo, denn `jj undo` stellte sonst die Root-Operation her, also ein leeres Repo. Im Bestätigungstext steht, dass auch frühere Versionen (Evolog) verloren gehen.
- Das UI-Kit geht mit ⌘Z mehrere Schritte zurück. Das ist falsch; es gilt E7.

**Farbe und Kontrast**
- Die Regel „Sekundärtext auf einer Füllung eine Stufe heller“ wenden wir überall an: GraphSearch-Hinweise, SearchField-Platzhalter, Statistik im Hunk-Kopf, Menü-Kürzel unter dem Sheen.
- Wo Doku und Tokens sich widersprechen, gelten Tokens und CSS: `ProgressBar.prompt.md` (alte Füllung) und die alte Paper-Gelb-Zeile in der Readme-Tabelle.

**Motion**
- Bei reduzierter Bewegung gilt `tokens/motion.css`, nicht die Cards: Sweeps pulsieren, Fades behalten ihre Tokens, es gibt keine 120-ms-Grenze.
- Panels, Inspector, Composer, Peek, Stack-Liste und StaleNotice bekommen den generischen Exit (Fade, gespiegelte Drift × `--motion`, `--dur-exit-lg`).
- Die Spreizung des Flash-Rings wird mit `--motion` multipliziert.

**Controls**
- Select: Lange Listen scrollen die gewählte Zeile zum Trigger. Die Liste wird auch horizontal in 8 px eingeklemmt, die Breite ist *mindestens* Trigger + 40.
- Submenü: Erreicht der Zeiger das Submenü, wird der Wechsel abgebrochen. ← schließt kein Top-Level-Menü.
- Der ScrollArea-Viewport ist nur dann ein Tab-Stopp, wenn er scrollt und selbst nichts Fokussierbares enthält.
- Ausgewählte ProjectRow: Hover bleibt `--accent-soft`, Pressed `--accent-soft-hi`.
- RevsetDialog: ↩ außerhalb der Felder = OK; Esc und Schließen = Cancel.

**Fenster**
- Projects bei Mindestgröße: Wie im Client schrumpft die Suche bis 120, Clone… und New group werden zu reinen Icons.
- Settings und Projects werden als normale Fenster geöffnet (Key und vorn, dem Vollbild-Space beigeordnet), ohne angehobenes Fenster-Level.

**Offen für die Stories, nicht eilig**
- Welches Bookmark `ProjectRow` und das Project-Menü zeigen. jj kennt kein „aktuelles Bookmark“; ein Vorschlag ist `heads(::@ & bookmarks())`. Das Wort heißt „bookmark“, nicht „branch“.
- Worauf das Change-Menü der Menüleiste wirkt: Vorschlag ist die Auswahl, ohne Auswahl `@` wie die CLI, und der Eintrag nennt das Ziel („Abandon @“). Kritisch ist das bei Abandon ⌘⌫ ohne Rückfrage.
- Go › Parent/Child verschieben nur die Auswahl. Offen ist die Regel bei mehreren Eltern oder Kindern (10.6 (c)).

## 5. Entscheidungen für Ralph

**Entschieden 2026-10-16 (Ralph):** alle Empfehlungen übernommen, auch Configurations als eigenes Fenster. Der Runde-3-Prompt ist so gesendet.

1. **⌘, an Menüzeilen.** Unser Prompt sagte „Settings… öffnet General“ (G1) *und* „⌘, öffnet den zuletzt gezeigten Tab“ (G5). Jetzt tragen Zeilen das Kürzel ⌘,, tun aber etwas anderes als ⌘,. *Empfehlung:* Jede Zeile mit ⌘, tut, was ⌘, tut (letzter Tab); nur „Project Settings…“ und „Appearance, diffs and more“ wählen einen Tab und zeigen kein Kürzel.
2. **Ein Projektfenster oder mehrere.** Das DS schreibt „one per project“, das Kit wechselt das Projekt im selben Fenster, und 11.5 schließt mehrere Fenster aus. *Empfehlung:* Ein Projektfenster, ein anderes Projekt öffnen wechselt darin. Der Project-Tab zeigt dieses Projekt. Ist kein Projekt offen, zeigt ⌘, General, auch wenn zuletzt Project offen war.
3. **⌘W auf dem Projektfenster.** Ungeklärt. *Empfehlung:* Es schließt das Projekt und zeigt das Projects-Fenster (wie JetBrains); erst das Schließen von Projects beendet die App.
4. **Klick neben ein Sheet.** Das DS lässt den Scrim-Klick abbrechen; dabei gehen ungespeicherte Configurations oder eine angepasste Push-Auswahl verloren. *Empfehlung:* wie macOS-Sheets — der Klick tut nichts, Esc und Cancel brechen ab.
5. **⌘J.** Das DS legt „Working Copy (@)“ auf ⌘J und behauptet, das kollidiere mit nichts. Laut HIG ist ⌘J aber „Scroll to a selection“. *Empfehlung:* ⌘J scrollt zur Auswahl (HIG); Claude Design schlägt für @ ein freies Kürzel vor.
6. **jj log Configurations: Sheet oder Fenster** (Ralph fragte am 2026-10-16 nach Größe und Verschieben). *Empfehlung jetzt:* eigenes Fenster. Am 2026-10-15 hatte ich noch das Sheet empfohlen. Die Gründe:
   - Gegen das Fenster sprach die Bindung an eines von mehreren Projektfenstern. Mit einem einzigen Projektfenster (Entscheidung 2) ist sie trivial.
   - Ein Sheet lässt sich größenveränderbar machen, aber nie verschieben, und es sperrt den Graph. Beim Schreiben eines Filters will man dort Autoren, Bookmark-Namen und IDs nachsehen und übernehmen.
   - Kosten: Das Fenster muss über dem Projektfenster bleiben. Flutters Satellite-Fenster fehlen auf macOS, also braucht es etwas nativen Code über das Fenster-Handle (`addChildWindow` oder schwebendes Level). Dazu kommt eine Rückfrage beim Schließen mit ungespeicherten Änderungen.
   - Die Fenster-Plumbing bauen wir für Settings und Projects ohnehin. „Die Ansicht wechselt erst bei OK“ bleibt.
   - Alternative im Prompt: Sheet mit Größengriff.

Dazu Ralphs Wunsch (keine Entscheidung offen): Inspector und angeheftete Panels werden an ihrer Kante zum Graph in der Breite ziehbar (Prompt D6).

## 6. Folgen für die Stories (wenn wir sie anfassen)

Die Stories bleiben bis dahin unverändert.

- **11.1:** Motion-Quelle ist jetzt `tokens/motion.css` (Punkt 6). Die Icon-Regel (Punkt 11) wird neu geschrieben: alle 58 Glyphen auf einmal aus dem DS, kebab-case, `glyphs.json` als Paritätsquelle, Aliase `edit→describe`, `arrow-left→chevron-left`, `download→fetch`. Neue Token-Dateien `inactive.css`, `transparency.css`, `motion.css`.
- **11.2:** Das Sheet dient nur noch ConfirmDialog, Push und Configurations; die Materialien sind fertig.
- **11.3:** Die Rail ist Bookmarks · Reviews · Undo Timeline, Workstreams entfallen. Bar 4–48, Inhalt ab 60, erste Insel bei Block-Ende + 12; im Vollbild 12/68.
- **11.4:** Geometrie aus `--tl-*`. Neues Minimum 880 × 560 (Runner und Dart-Constraint stehen heute auf 900 × 600); die Gap-Legende braucht dafür einen Breakpoint, den das DS nicht definiert. Vollbild nach DS.
- **11.5/11.6/11.7:** Projects und Settings sind Fenster, keine Sheets. Dazu die Entscheidungen 1–3 und die Fenster-Plumbing aus der Windowing-Recherche (Dialog-Fenster in `AppWindows`, Chrome-Arten, `isRestorable = false`, Erscheinung für alle Fenster, Menüleiste).
- **11.8 und 9.20:** Tags; Vorauswahl, Arten und Verweigerungen pro Remote; Verweigerungsgründe ohne Allow; Ergebnisse pro Ref (Teilerfolg, „remote rejected“); `push-`-Name per Template. 11.8 Punkt 3 (nacktes `jj git push`) entfällt.
- **9.21/11.9:** Nach `op abandon` kein Undo.
- **9.23:** Ausgänge von `update-stale` melden (frischer Commit, nicht stale, Recovery-Commit). Die Story gewinnt Priorität, weil sie der einzige Ausweg aus „stale“ ist.
- **10.3:** `name@`-Slots und eine Rangfolge in der Meta-Zeile; Designfrage (e) ist damit beantwortet.
- **10.5:** eigener Stale-Zustand (kein Retry, Kaltstart, Ausgang über den Watcher); der eigene Workspace-Name gehört auf den Draht.
- **10.6/10.19:** Unter reduzierter Bewegung bleibt der Flash eine Farbblende, nicht statisch.
- **10.22:** Mit Entscheidung 6 wird Configurations ein eigenes Fenster (Schlüssel `revset-configs`, über dem Projektfenster per nativem Child-Window oder schwebendem Level, Rahmen gemerkt, schließt mit dem Projektfenster; Esc/⌘W = Cancel mit Rückfrage bei ungespeicherten Änderungen). ↩ = OK; die Ansicht wechselt erst bei OK.
- **10.5/10.8/11.3 (Breite ziehbar):**
  - Inspector und Panel-Breite sind veränderlich; `GraphInsets` folgt live, die Karten bleiben stehen.
  - Breiten werden app-weit gemerkt, ein Doppelklick setzt auf 460 / 300 zurück.
  - Die 320-px-Regel für schmale Fenster begrenzt den Zug.
  - 10.8 „höchstens 100 % − 100 px“ wird durch die DS-Tokens ersetzt.
- **10.23:** ⌘Z und Toast-Undo nach E7, nur solange die Operation die aktuelle ist.
- **Neue Menüleisten-Story:** das DS hat sie vollständig spezifiziert (Settings… ⌘,, All Projects… ⇧⌘O, Close Window ⌘W, Undo/Redo, Edit Configurations… ⌥⌘L, Push… ⇧⌘P, ⌘N, ⌘⌫, ⌘1/⌘2), plus Entscheidung 5.
- **Werkzeuge** (aus der Recherche vom 2026-10-15): `marionette_flutter ^0.7.0`, Widgetbook 3.25.0 gepinnt.

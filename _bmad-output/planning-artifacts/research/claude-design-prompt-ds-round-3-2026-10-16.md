# Prompt für Claude Design — Runde 3

**Ziel:** das Projekt **Zanshin Design System** (`a33847c9-000b-4914-ae7f-6291f117e05f`). Den Floating Client lassen wir diesmal aus; für Flutter gilt das Design System.
**Hintergrund:** [`design-system-validation-round-2-2026-10-16.md`](design-system-validation-round-2-2026-10-16.md).

**Vor dem Senden:** Abschnitt D enthält sechs Entscheidungen. Eingetragen ist jeweils Claudes Empfehlung:

1. Jede Zeile mit ⌘, tut, was ⌘, tut.
2. Es gibt ein Projektfenster.
3. ⌘W auf dem Projektfenster zeigt danach Projects.
4. Ein Klick neben ein Sheet tut nichts.
5. ⌘J scrollt zur Auswahl.
6. jj log Configurations wird ein eigenes Fenster (D7).

Entscheidet Ralph anders, den betreffenden Punkt in D anpassen oder streichen. Bleibt Configurations ein Sheet, D7 durch den Block „Alternative D7“ unten ersetzen. D6 (Inspector und Panels in der Breite ziehbar) ist Ralphs Wunsch und keine offene Frage. Abschnitt B5 ist optional. Alles unterhalb der Linie kopieren, ohne die Alternative.

> **Alternative D7** (falls Configurations ein Sheet bleibt):
> 7. **jj log Configurations bleibt ein Sheet, aber in der Größe änderbar.** Bitte einen Griff in der unteren rechten Ecke entwerfen, dazu die Mindestgröße. Die Liste bleibt 240 px, der Editor wächst. Die Größe wird gemerkt, höchstens Fenstergröße minus Rand. Verschieben kann man ein Sheet nicht; es bleibt am Projektfenster.

---

Danke für Runde 2. Wir haben alles nachgeprüft:
- Fast alles stimmt. Über 3 888 Konfigurationen löst jedes Token auf.
- Jede nachgerechnete Zahl hält, und die 58 Icons kompilieren fehlerfrei.
- Alle 54 Seiten laden ohne Fehler.

Es bleibt eine kleine Runde. Bitte wieder in `readme.md` festhalten, mit Datum („Runde 2026-10-17“ o. ä.).

## A. Reste aus Runde 2

1. **Das alte Push-Beispiel lebt noch.** Die Feedback-Card zeigt den ConfirmDialog „Undo the push to origin?“ mit dem Befehl `jj undo` + `jj git push --bookmark main --allow-backwards` (`components/controls/feedback.card.html:52-53`).
   - Dieses Flag gibt es bei `jj git push` nicht, und die UI baut keine Befehlsfolgen.
   - Undo eines Push ist laut eurem readme ein Warn-Toast, keine Bestätigung.
   - **Bitte** durch das ConfirmDialog-Beispiel `jj op abandon ..@-` ersetzen, ebenso die „Undo push“-Beispiele in `Button.prompt.md:7`, `state-matrix.card.html:42` und `motion.card.html:61`.
   - In `readme.md:53` bitte präzisieren: Erfunden war `jj git push --allow-backwards`. `jj bookmark move … --allow-backwards` ist echt, und ihr nutzt es zu Recht beim rückwärts gezogenen Bookmark.
2. **Scope-Pille (B4).** Gemessen haben wir auf dem echten Untergrund: `--accent-soft` (`search.css:15`) über dem `--fl-hover` der Suchkapsel (`search.css:7`), darunter Bar-Glas und Canvas.
   - Dort liegt der Akzent-Text in den meisten Familien unter 4.5: Night Blau 3.79–4.43, Lila 3.73–4.36, Orange 3.81–4.45, Pink 3.97–4.64; Paper Blau 4.14–4.37, Pink 3.95–4.17, Grün 3.93–4.15.
   - Auch `accents.css:35` („5.0 bar glass“ für Night Rot) hält für die Pille nicht (ab 4.35).
   - **Bitte** das Label der aktiven Pille auf `--text` setzen, oder der Pille die Kapsel-Füllung nehmen, und die Zahl in `accents.css` korrigieren.

## B. Tokens

1. **Kontrastmodus: Die Slider-Füllung verschwindet.** Die Füllung ist jetzt `--accent-line`, der Track im Kontrastmodus opak (`contrast.css:17-18`: Night `#767e9a`, Paper `#8a8279`; Hover `#8f97b2` / `#6f675f`).
   - Gefüllter gegen leeren Teil: Paper Orange 1.03:1, Grün 1.08, Gelb 1.12; Night Rot 1.11; auf Hover bis 1.01.
   - Ohne Kontrastmodus sind es 2.3–8.5.
   - **Bitte** Track oder Füllung im Kontrast-Delta so wählen, dass beide Teile ≥ 3:1 auseinanderliegen, zum Beispiel ein dunklerer Track mit `--border-strong`-Kante.
2. **Inaktives Fenster: Was bleibt, wird trotzdem grau.** `inactive.css:7-8` und readme WINDOWS sagen, Fortschritt und Edit-Flash bleiben. Beide lesen aber Tokens, die `inactive.css:14-15` neutralisiert: die Fortschrittsfüllung `--accent-line` (`controls.css:56`) und der Flash `--accent-line` + `--accent-ring` (`graph.css:85`).
   - **Bitte** eigene Tokens, die das Inaktiv-Delta nicht anfasst, oder die Doku ändern.
   - Bitte dabei auch einordnen:
     - **Badge** (`controls.css:10`, „something to act on“);
     - **Links** (`base.css:15`; inaktiv in Night gleich `--text-muted`);
     - **Drop-Ziel** (`--ring-drop`, `.zs-card.is-drop`): Ein Drop aus dem Finder landet immer in einem Fenster, das gerade nicht Key ist.
3. **Inaktiv × erhöhter Kontrast: Die Auswahl verschwindet.** Im inaktiven Fenster trägt die ausgewählte Karte nur noch `--accent-line`.
   - Paper: `#867e75` (`inactive.css:15`) ist genau das `--border-strong` des Kontrastmodus (`contrast.css:18`), also 1.00:1 gegen jede andere Karte.
   - Night: `#8189a5` gegen `#78809c`, 1.13:1.
   - **Bitte** für diese Kombination eine Auswahl-Linie, die sich mit ≥ 3:1 vom normalen Kartenrand abhebt.
4. **„Stale“ als eigener Projektstatus.** Der Kapsel-Punkt im Stale-Zustand ist ein Inline-`var(--warn)` (`stale.card.html:24`); in `zsProjectStatus` fehlt der Status.
   - In Night liegt `--warn` (`#f7c243`) bei ΔE .036 zu `--proj-dirty` (`#facc15`). „Working copy is stale“ liest sich so wie „uncommitted changes“, den häufigsten Zustand.
   - **Bitte** ein `--proj-stale` in der Status-Palette (Kapsel, Recent, Projects-Fenster), in beiden Themes klar von dirty unterscheidbar.
5. **(Optional) Kollisionen unter ΔE .06, die nicht gelistet sind.** Der Test der Accent-Card prüft nur Fill und Line. `--accent-text`, die `--proj-*`-Status und die Textleiter fehlen. Gefunden:
   - Paper-Grün-Text `#427a03` ≈ add .049, ≈ ahead .056;
   - Paper-Orange-Text `#953c02` ≈ @-Text .057;
   - Paper-Gelb-Linie `#847e0d` ≈ proj-dirty .053;
   - Paper-Graphit ≈ `--text-faint` .038;
   - Night-Moon `#aebcec` ≈ `--text-muted` .039.

   **Bitte** verschieben oder in die Near-Miss-Liste aufnehmen und den Test der Card erweitern. Dabei bitte auch die Accent-Tabelle in `readme.md:163` auf die neue Paper-Gelb-Linie `#847e0d` bringen.

## C. Push-Dialog — was jj v0.46.0 noch anders macht

1. **Tags fehlen.** Das nackte `jj git push` schickt getrackte Tags mit, ebenso `--tracked`, `--all` und `--deleted` (`cli/src/commands/git/push.rs:90-93`, `:166-184`, `:539-553`); dazu gibt es `--tag <name>`.
   - Der Dialog listet nur Bookmarks. Bei einer Standard-Auswahl zeigt die Fußzeile `jj git push`, das Tags schickt, die nirgends stehen.
   - **Bitte** Tag-Zeilen ergänzen: mit Tag-Kennzeichen, `--tag <name>`, Art und Vorschau wie bei Bookmarks, in Vorauswahl und Sammelwahlen.
2. **Die Verweigerung für den Change.** jj prüft auch die Commits eines `--change`/`--named` und bricht dann den ganzen Push ab (`push.rs:505-511`, `:848-859`). Ein `@` ohne Beschreibung ist der Normalfall.
   - Der Floating Client hat das schon gelöst (DESIGN-SYSTEM-SYNC #10): „Refused — <id> has no description“, die Checkbox deaktiviert, ein Allow-Chip, das Flag im Befehl.
   - **Bitte** in `PushDialog` übernehmen (`change.refused` / `refusedAt`, das Flag in `PushDialog.command`, beide Push-Cards).
3. **Verweigerungen ohne Allow.** Diese Fälle kennt jj ohne Schalter:
   - „has no author and/or committer set“ (`push.rs:861-867`);
   - Bookmark lokal oder auf dem Remote in Konflikt, Hinweis `jj git fetch` (`:1165-1180`);
   - ein nicht getracktes gleichnamiges Remote-Bookmark, Hinweis `jj bookmark track` (`:1181-1184`);
   - „Refusing to create new remote bookmark“, wenn das Bookmark schon auf einem anderen Remote getrackt ist (`:1185-1192`). Dann stimmt auch der Zeilentext „not tracked yet — the push tracks it“ nicht.

   Mehrere Gründe kann jj pro Commit nennen („has no description and has conflicts“, `:880-884`). **Bitte** einen Verweigerungszustand ohne Allow-Chip: Grund plus jjs Hinweisbefehl, mehrere Gründe möglich.
4. **Mehrere Remotes.** Seit 0.46 pusht jj an mehrere Remotes in einem Aufruf und klassifiziert pro Remote (`push.rs:423-555`): Art, Vorauswahl (`remote_bookmarks(remote=…)`), Verweigerung. Ein Bookmark kann auf origin „forward“ und auf upstream „new“ sein.
   - `git.push` kann eine Liste oder ein Muster sein (`:1107-1130`). Ohne `git.push` gilt das *einzige* Remote, erst sonst origin.
   - **Bitte** festlegen, wie eine Zeile bei mehreren gewählten Remotes aussieht (Art je Remote in der Zeile, oder eine Zeile je Remote). Der Standard soll mehrere Remotes vorwählen können.
5. **Fehlermodell.** jj prüft den Lease pro Ref und pusht die übrigen trotzdem. Die Operation wird dann aufgezeichnet (also auch rückgängig machbar), und jj endet mit „Failed to push some bookmarks“ (`push.rs:600-661`). Daneben gibt es „The remote rejected the following updates“ (Rechte, Hooks).
   - jjs Hinweis nach einem Lease-Fehler: erst fetchen, dann das Bookmark dorthin setzen, wo es hin soll, dann erneut pushen. „Fetch first — then push“ stammte aus unserem Prompt und greift zu kurz: Nach dem Fetch steht das Bookmark oft in Konflikt.
   - **Bitte** einen Teilerfolg mit Ablehnung pro Bookmark entwerfen, „Remote hat abgelehnt“ als eigene Art, und den Lease-Hinweis wie jj.

## D. Fenster und Kürzel

1. **⌘, an Menüzeilen.** Die Zeilen „Settings… ⌘,“ im Project-Menü, „Appearance, diffs and more · Settings… ⌘,“ in den View options und „Settings…“ (Tooltip ⌘,) in der Projects-Sidebar öffnen General. ⌘, selbst öffnet aber den zuletzt gezeigten Tab. Auf macOS tut eine Zeile, die ein Kürzel zeigt, genau das, was das Kürzel tut. Der Widerspruch stammt aus unserem eigenen Prompt.
   - **Bitte:** Jede Zeile mit ⌘, verhält sich wie ⌘, und öffnet den zuletzt gezeigten Tab.
   - Nur „Project Settings…“ (Project) und „Appearance, diffs and more“ (General) wählen einen Tab und zeigen kein ⌘,.
   - Anpassen: `Window.prompt.md:21`, readme WINDOWS, ProjectMenu, Popover/OptionLink und das Kit.
2. **Ein Projektfenster.** readme WINDOWS schreibt „The project window (one per project)“; das liest sich wie mehrere Projektfenster. Das Kit wechselt das Projekt im selben Fenster, und so planen wir es auch.
   - **Bitte** klarstellen: Es gibt *ein* Projektfenster. Ein anderes Projekt öffnen wechselt darin, und der Project-Tab der Settings zeigt dieses Projekt.
   - Ist kein Projekt offen und war zuletzt Project der Tab, zeigt ⌘, General.
3. **⌘W auf dem Projektfenster.** Bisher offen. **Bitte:** Es schließt das Projekt und zeigt das Projects-Fenster (wie das Startfenster); erst das Schließen von Projects beendet die App. Dazu in der Menüleiste festhalten, wann „Close Window“ und die Fenster-Einträge deaktiviert sind.
4. **Klick neben ein Sheet.** Heute bricht ein Klick auf den Scrim ab (Dialog, ConfirmDialog, PushDialog, RevsetDialog). Dabei gehen ungespeicherte Configurations oder eine angepasste Push-Auswahl ohne Rückfrage verloren.
   - Ein macOS-Sheet schließt nie durch einen Klick daneben.
   - **Bitte:** Ein Klick auf den Scrim tut nichts; Esc und Cancel brechen ab. In den `.prompt.md` und im JSX angleichen (RevsetDialog entfällt, wenn es nach D7 ein Fenster wird).
5. **⌘J.** readme MENU BAR legt „Working Copy (@)“ auf ⌘J und sagt, ⌘J kollidiere mit nichts. In der HIG-Tabelle der Standardkürzel steht ⌘J aber für „Scroll to a selection“.
   - **Bitte:** ⌘J scrollt zur ausgewählten Change.
   - Für „Working Copy (@)“ schlagt bitte ein freies Kürzel vor und prüft es gegen die Standardkürzel.
6. **Inspector und Panels in der Breite ziehbar.** Heute sind beide fest: der Inspector (Commit-Details) `--inspector-w` 460, die angehefteten Panels links (Bookmarks, Undo Timeline, Reviews) `--panel-w` 300 (`tokens/spacing.css:42`). Wer lange Pfade, breite Diffs oder lange Bookmark-Namen sieht, will mehr Platz; wer den Graph sehen will, weniger.
   - **Der Inspector** wird an seiner linken Kante gezogen, **die Panels links** an ihrer rechten, also immer an der Kante zum Graph. Wie eine Seitenleiste im Finder oder in Mail.
   - **Bitte entwerfen:**
     - die Greifzone: wo sie liegt (auf der Inselkante, im 12-px-Spalt) und wie breit sie ist;
     - Hover und Ziehen: Cursor `col-resize`, und ob eine Linie oder ein Glanz die Kante zeigt;
     - Mindest- und Höchstbreite als Tokens (etwa `--inspector-w-min` / `-max`, `--panel-w-min` / `-max`); 460 und 300 bleiben die Standardwerte.
   - **Verhalten:**
     - Doppelklick auf die Kante stellt die Standardbreite wieder her.
     - Die Breite wird app-weit gemerkt.
     - Beim Ziehen folgt der Rand des Graphen live, die Karten bleiben stehen (wie beim Anheften eines Panels).
   - **Mit der Fensterbreite:** Es bleiben mindestens 320 px Graph sichtbar (unsere Regel fürs schmale Fenster). Ein Zug stoppt dort. Wird das Fenster schmaler, schrumpft das Panel erst bis zu seiner Mindestbreite, bevor es sich löst.
   - Bitte wie bei den Controls eine Zeile „Keyboard · VoiceOver · Reduce motion“: ob und wie man die Breite ohne Maus ändert, und was VoiceOver ansagt.
7. **jj log Configurations als eigenes Fenster** statt als Sheet, aus demselben `Window`-Gerüst wie Settings und Projects. Ein Sheet lässt sich weder verschieben noch neben dem Graph benutzen. Beim Schreiben eines Filters will man aber im Graph nachsehen und von dort übernehmen: Autoren, Bookmark-Namen, Change-IDs.
   - **Fenster:**
     - Titel „jj log Configurations“;
     - Standard 880 × 580, größenveränderbar, bitte eine Mindestgröße angeben;
     - die Liste bleibt 240 px, der Editor wächst;
     - Größe und Position werden gemerkt;
     - Ampeln: Schließen und Zoomen aktiv, Minimieren grau.
   - **Lage:**
     - Das Fenster bleibt über dem Projektfenster, solange Zanshin aktiv ist (wie ein Werkzeug-Panel), und lässt sich frei verschieben.
     - Es schließt mit dem Projektfenster.
     - „Edit Configurations…“ und ⌥⌘L öffnen es oder holen es nach vorn.
   - **Bezug:**
     - Vorschau-Zählung, `mine()`, Apply und OK beziehen sich auf das Projekt im Projektfenster.
     - Wechselt dort das Projekt, folgen Zählung und Vorschau; die Konfigurationen sind ohnehin global.
   - **Bedienung:**
     - Footer Cancel · Apply · OK wie bisher; die Ansicht wechselt weiter erst bei OK.
     - ↩ außerhalb der Felder = OK.
     - Esc, ⌘W und der rote Knopf = Cancel. Mit ungespeicherten Änderungen fragt das Fenster erst nach („Discard changes?“).
   - **Inaktiv:** Klickt man in den Graph, wird das Fenster inaktiv (D1 der letzten Runde).
   - **Aufräumen:** Die Liste der Sheets heißt dann nur noch ConfirmDialog und Push (readme WINDOWS und Layers, `Dialog.prompt.md`, `RevsetDialog.prompt.md`/`.d.ts`, Card und Kit). Für RevsetDialog entfallen Scrim, 18-px-Radius und Ein- und Ausblendung.

## E. Ein Icon

- `move-only.svg`: Beide Karten sind 2.5 hoch, haben aber `rx="1.5"`.
  - Browser klemmen das auf 1.25. Unser Build-Compiler (`vector_graphics_compiler`) klemmt nicht und zeichnet überlappende Enden.
  - **Bitte** `rx="1.25"` setzen und als Dateiregel ergänzen: „`rx`/`ry` höchstens die halbe kürzere Seite“.

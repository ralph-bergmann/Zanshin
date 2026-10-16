# Validierung Runde 3 — Design System (2026-10-16)

**Geprüft:** der neue Download von `_bmad-output/implementation-artifacts/design_system/`, gegen [`claude-design-prompt-ds-round-3-2026-10-16.md`](claude-design-prompt-ds-round-3-2026-10-16.md) und gegen die eigenen Entscheidungen, die Claude Design im Chat zum Gegenlesen genannt hat. Der Floating Client ist unverändert.
**Vorgänger:** [`design-system-validation-round-2-2026-10-16.md`](design-system-validation-round-2-2026-10-16.md).

## Ergebnis

Runde 3 ist gut umgesetzt, und **eine Runde 4 braucht es dafür nicht**.

- Von 86 Prüfpunkten sind 68 vollständig erledigt.
- Was offen ist, betrifft fast nur den Push-Dialog. Dort stammen drei Fehler aus *unserem* Prompt, und alle lassen sich in Backend und Flutter richtig bauen.
- Der Rest sind Doku-Reste.
- Alle Korrekturen aus Runde 2 halten (27 Stichproben, keine Regression), und es gibt keine ungefragten Änderungen.
- Laufzeit: alle 55 Seiten und das UI-Kit samt `?push` ohne Konsolenfehler und ohne fehlende Dateien.

Nächster Schritt: die Stories anpassen (Runde-2-Bericht § 6, ergänzt um § 6 hier).

## 1. Wie geprüft

- Sechs Prüf-Agenten, je mit eigenem Gegenprüfer, für Reste und Icon, Tokens/Farbe, Push, Fenster, Breite ziehen, Regression; dazu ein Kritiker für Lücken. Gegenprüfung: 39 Befunde bestätigt, 12 korrigiert, 1 widerlegt, 8 zusätzlich gefunden.
- Selbst nachgeprüft:
  - die Push-Hinweise und die Verweigerungslogik in `cli/src/commands/git/push.rs` @ v0.46.0;
  - die Laufzeit aller Seiten in einem frischen Browser-Tab, mit einem Test-Fehler als Probe, dass die Konsole mitschreibt.
- Einschränkung: Runde 2 liegt nicht in git, deshalb ging kein zeilengenauer Vergleich. Die Regression wurde gegen die Belege aus Runde 2 geprüft (333 zitierte Textstellen; jede verschwundene gehört zu einem Prompt-Punkt).

## 2. Was stimmt

- **A1** Das alte Push-Undo-Beispiel ist überall weg; jetzt steht dort „Clear the operation history?“ mit `jj op abandon ..@-`, korrekt beschrieben. Die Regel „Every command is real“ benennt das erfundene Flag genau.
- **A2** Das Label der aktiven Scope-Pille ist `--text`: nachgerechnet ab 6.39 (Night Gelb) statt „7.8+“, aber überall ≥ 4.5. Das Icon behält den Akzent mit ≥ 3.6:1.
- **B1** Kontrastmodus: Gefüllter und leerer Slider-Teil liegen jetzt in jeder Familie ≥ 3:1 auseinander.
- **B3** Inaktiv × Kontrast: Die Auswahl-Linie in Textfarbe hält 3.23 / 3.83:1.
- **E** `move-only` hat `rx 1.25`. Alle 58 Icons halten die Dateiregeln, auch die neue `rx`/`ry`-Regel, und kompilieren 58/58.
- **C1/C2/C4/C5** Push hat jetzt Tag-Zeilen, die Change-Verweigerung, mehrere Remotes mit einer Zeile je Remote und einen Teilerfolg mit „pushed / moved on / rejected“.
- **D1–D5** ⌘,-Zeilen, ein Projektfenster, ⌘W → Projects, Klick neben ein Sheet tut nichts, ⌘J/⇧⌘J. Alles in readme, Komponenten und Kit.
- **D6** `ResizeEdge` mit Tokens: Inspector 380–720, Panels 240–440, Greifzone 10 px, dazu Doppelklick-Reset, Cursor, Tastatur und VoiceOver.
- **D7** jj log Configurations ist ein Fenster; Sheets sind nur noch ConfirmDialog und Push.
- **Regression:**
  - Token-Resolver über alle Konfigurationen: 0 undefiniert.
  - Unverändert halten: Ampel-Geometrie, Motion-Delta, Listenmodell, Fokusregeln, Icons, `glyphs.json`.
  - Keine Workstreams, kein `data-theme="dark"`.

## 3. Claude Designs eigene Entscheidungen

| Punkt | Urteil | Begründung |
|---|---|---|
| D5 ⇧⌘J für Working Copy (@) | ✓ | In der HIG-Tabelle steht nur ⌘J („Scroll to a selection“). ⇧⌘J als Shift-Ergänzung folgt der HIG-Regel. Systemweit ist es frei; Xcodes ⇧⌘J heißt sinngemäß „zeig, wo das Aktuelle ist“. Offen bleibt nur, ob ⇧⌘J @ auch auswählt (Vorschlag in § 5). |
| B4 `--proj-stale` Cyan | ✓ | ΔE-Minimum hält (Night .109 zu Blau, Paper .085 zu behind). Der Punkt hat überall ≥ 4.6:1. Die zitierten Werte „dirty .30 / .25“ sind in Wahrheit .274 / .225, nur Kommentar. |
| B5 Paper-Grün `#3d5e06`, -Orange `#a03001` | ✓ | Verschieben war besser als eine Near-Miss-Liste: Text steht neben Datenfarben. Kontrast ≥ 5.8:1 in jedem Kontext. |
| B2 `--accent-live-*`, Badge grau | ✓ | Die Kopien gibt es in allen Familien und Themes, kein Delta fasst sie an. Fortschritt, Flash, Drop-Ziel und Links lesen sie. Die Badge-Zahl hält 5.5 / 5.8:1, ein grauer Zähler wie in macOS-Sidebars. |
| D6 Breiten, Greifzone, Reihenfolge | ✓ mit Einwand | Zahlen und Geometrie stimmen (3 px auf der Insel, 7 im Spalt). Aber „das Panel löst sich und schwebt über dem Graph“ bricht die 320-px-Regel (§ 4.3). |
| C3 Hinweisbefehle | ✗ zwei von vier | Lokaler Konflikt: jj sagt `jj bookmark list` / `jj bookmark set`, nicht `jj git fetch`; der Fehler stammt aus unserem Prompt. „Refusing to create new remote bookmark“: jj nennt `jj bookmark track <name>@<remote>`. Richtig sind der Remote-Konflikt (`jj git fetch`), das nicht getrackte Remote-Bookmark (`jj bookmark track …`) und „no author“ ohne Befehl. Für Tags hat jj eigene Texte. |
| D3 im Kit | ✓ | Nur eine Vereinfachung im Kit; der readme-Text ist eindeutig. Das Kit nicht als Vorbild für den Lebenszyklus nehmen. |

## 4. Was nicht stimmt

**4.1 Push: jj bricht nicht immer den ganzen Push ab.**
- Das DS baut seine Logik auf „jj verweigert den *ganzen* Push, solange eine verweigerte Ref drin ist“. Daraus folgt bei ihm: Der nackte Befehl und die Sammel-Flags werden dann nie geschrieben, der Dialog listet stattdessen jede Ref einzeln.
- Laut `push.rs` gilt das nur für ausdrücklich genannte Refs: `--bookmark`, `--tag`, `--change`, `--named` (`:454`, `:479`, `:501`, `:507-511`).
- Das nackte `jj git push` und `--all`/`--tracked`/`--deleted` melden den Grund als Warnung, überspringen die Ref und pushen den Rest (`:528-536`, `:680-707`). Bei mehreren Remotes ändert der Umweg des DS sogar, *was* gesendet wird.
- Dazu kommt: Das nackte `jj git push` weist jedes lokale Bookmark im Revset ab, das auf diesem Remote nicht getrackt ist, auch ein frisch angelegtes, und überspringt es (`:518-521`).
- *Auslöser:* Unser Prompt (C2) sagte „bricht dann den ganzen Push ab“ für `--change`/`--named`; das DS hat es verallgemeinert.
- *Lösung in Backend und Flutter (keine Runde 4):*
  - Die Vorauswahl bleibt `jj git push`.
  - Verweigerte Refs stehen dort als „wird übersprungen“ mit jjs Grund und Hinweis.
  - Nur bei Handauswahl ist eine verweigerte Zeile nicht ankreuzbar.
  - Der Dry-Run (9.20) liefert das Ergebnis je Modus und je Remote.

**4.2 Push-Hinweise.** Siehe § 3, C3. In Flutter zeigen wir jjs Text und Hinweis wortgleich, so wie das Backend sie durchreicht (9.20), getrennt nach Bookmark und Tag. Damit ist das DS-Mapping egal.

**4.3 Breite ziehen: „Lösen“ bricht die 320-px-Regel.**
- Im Floating Client schweben ohnehin alle Inseln über dem Graph. Ein „gelöstes“ Panel deckt deshalb weiter 252 px ab; bei 880 px bleiben 148 px Graph sichtbar.
- Außerdem nennt das DS die Regel nur für ein schmaler werdendes Fenster. Häufiger greift sie, wenn der Inspector bei einer Auswahl aufgeht.
- *Lösung in Flutter:* wie Seitenleisten in macOS (`NSSplitViewItem`, „collapse from window resize“), Details in § 5.

**4.4 Configurations: Mindestbreite 680 ist zu klein.** Bei 680 bleiben dem Wertfeld der Filterzeile 42 px Spalte; nach Innenabstand und „Aa“-Knopf ist die Textfläche −4 px breit. Für 120 px Text braucht es etwa 804 px. *Lösung:* mindestens 820 × 460.

**4.5 Configurations mit ungespeicherten Änderungen, wenn das Projekt schließt.** Das DS sagt nur „schließt mit dem Projektfenster“. *Lösung:* siehe § 5.

**4.6 Doku-Reste (Flutter folgt CSS und Tokens):**
- `GraphSearch.prompt.md` beschreibt die Pille noch mit Akzentfarbe.
- `StaleNotice.prompt.md` nennt noch `--warn`.
- `Icon.prompt.md` fehlt die `rx`-Regel.
- Die Surfaces-Card zeigt ⌘, noch an „Appearance, diffs and more“, die Settings-Card noch als 18-px-Sheet.
- Die Window-Doku nennt teils nur zwei Fenster.
- readme:183 führt noch die alten `--track-hover`-Werte, das readme spricht von „8 Tokens je Akzentfamilie“ (jetzt 11), und `--delay-resize` fehlt in der Motion-Liste.
- Im Kit schließt ⌘W das Projekt auch bei offenem Push-Sheet.
- Das Referenz-JSX vergisst bei einem erlaubten Grund im Standard-Set das `--allow-*`-Flag; die Doku ist dort richtig.
- „The push is recorded, so Undo works“ gilt nur, wenn mindestens eine Ref gepusht wurde.

## 5. Vorschläge für die Stories (kannst du kippen)

1. **Push:** wie in § 4.1. Die Vorauswahl ist das nackte `jj git push`, Überspringen wird mit jjs Grund angezeigt, und blockiert wird nur bei Handauswahl.
2. **Panel ohne Platz:**
   - Reicht der Platz nicht, auch wenn beide Inseln auf Minimum sind, wird das angeheftete Panel **eingeklappt**. Der Pin bleibt, der Rail-Knopf bleibt aktiv, und das Panel kommt mit seiner gemerkten Breite zurück, sobald Platz ist.
   - Die Regel greift bei jeder Änderung: Fenstergröße, Inspector öffnet, Panel anheften.
   - Ein Rail-Klick ohne Platz zeigt das Panel vorübergehend als Flyout der Rail.
   - Gespeichert wird die Breite, die der Nutzer gezogen hat, nicht die automatisch geschrumpfte.
3. **Configurations:** mindestens 820 × 460.
4. **Configurations ungespeichert, wenn das Projekt schließt oder die App beendet wird:** Zuerst kommt das Configurations-Fenster nach vorn und fragt „Discard changes?“, wie ein ungesichertes Dokument.
5. **⇧⌘J** scrollt nur zu @, wie ein Klick auf die @-Pille; die Auswahl bleibt.
6. **VoiceOver an der Kante:** Flutter kennt keine „splitter“-Rolle. Die Kante wird ein einstellbarer Wert („Inspector width, 460 points“, ± 10 per Pfeil).

## 6. Folgen für die Stories (ergänzt § 6 im Runde-2-Bericht)

- **9.20:**
  - Push-Semantik je Modus: überspringen mit Warnung oder abbrechen.
  - Klassifikation und Commit-Prüfung je Remote.
  - jjs Text und Hinweis je Ref (Bookmark/Tag) wortgleich; Tags in Vorauswahl und Sammelwahl.
  - Ob die Operation aufgezeichnet wurde: nur wenn etwas exportiert wurde.
  - Welche Remotes vor einem Netzwerkfehler schon gesendet wurden.
- **11.8:** Vorauswahl, Fußzeilen-Befehl und Sperre nach § 5.1; `--allow-*` auch im Standard-Set.
- **10.22:**
  - Configurations ist ein eigenes Fenster (Schlüssel `revset-configs`), mindestens 820 × 460, mit nativem Level „schwebt, solange Zanshin aktiv ist“.
  - Ungespeicherte Änderungen werden beim Schließen des Projekts und beim Beenden abgefangen.
  - Ein eigener FocusScope pro Fenster; „Klick auf den Scrim verwirft“ entfällt.
- **10.5/10.8/11.3:**
  - Breiten-Tokens, Einklapp-Regel nach § 5.2, `GraphInsets` live.
  - Persistenz der Nutzerbreite.
  - Semantik als einstellbarer Wert.
  - Einseitige Resize-Cursor: Flutter hat sie, AppKit empfiehlt inzwischen `columnResizeCursor(directions:)`.
- **10.6:** ⌘J = zur Auswahl scrollen, ⇧⌘J = zu @ scrollen.
- **11.1:**
  - 11 Tokens je Akzentfamilie (`--accent-live-*`) und `--proj-stale`.
  - Die Token-Extraktion muss `:is()`-Selektoren in `inactive.css` auflösen.
  - Der Icon-Lint prüft `rx`/`ry` ≤ halbe kürzere Seite.
  - `dsSyncedThrough` bleibt 9, bis das DS #10 einträgt.
- **11.5/11.7 und Menüleisten-Story:** ein Projektfenster, ⌘W → Projects, ⌘,-Zeilen, Ausgrauregeln (Close Window bei offenem Sheet, Minimize/Zoom).

## 7. Änderungsprotokoll: Vorschlag für weitere Runden

**Warum man im readme nichts erkennt:**
- Claude Design schreibt Änderungen direkt in den Spezifikationstext („New this round“, „Round 2026-10-17:“, „(was …)“, „gave …“, an über 20 Stellen in readme und Token-Kommentaren). Dazu kommen vier Rundenabschnitte mit drei verschiedenen Namen.
- Die Datumsangaben „2026-10-16“ und „2026-10-17“ hat Claude Design wörtlich aus *unseren* Prompts übernommen („Runde 2026-10-17 o. ä.“). Das war mein Fehler.
- Wir committen die Downloads nicht. Für git ist alles seit `e74ced3` eine einzige Änderung, und Runden 1–3 lassen sich nicht mehr trennen.

**Vorschlag:**
1. **Jeden Download sofort committen,** nur das Export-Verzeichnis, als eigenen Commit („design-system: Claude Design R4“). Dann zeigt `git diff` zeilengenau, was eine Runde geändert hat, unabhängig vom readme. Der jetzige Stand wäre die Basis.
2. **Im DS, als erster Punkt der nächsten Runde** (falls es eine gibt), wie der `DESIGN-SYSTEM-SYNC.md` des Clients, der gut funktioniert: readme = nur der Ist-Zustand, dazu ein Abschnitt OPEN; die Historie kommt in `CHANGELOG.md`. Baustein zum Einfügen:

   > **Änderungsprotokoll.** Bitte nimm die Historie aus der Spezifikation heraus. `readme.md` beschreibt nur noch den aktuellen Stand: kein „New this round“, „Round …“, „(was …)“, „now …“ oder „gave …“ mehr im Text, auch nicht in den Token-Kommentaren (Begründungen, warum etwas so ist, dürfen bleiben). „Still open“ wird ein eigener Abschnitt OPEN. Alle Runden kommen in eine neue Datei `CHANGELOG.md`, neueste oben, im Format von `DESIGN-SYSTEM-SYNC.md`: `## R<n> · <Lieferdatum> · <Titel>`, darunter je Punkt `**<Prompt-ID>** was · warum · Dateien` mit alten und neuen Werten. Bitte die vorhandenen Abschnitte übertragen: DESIGN REVIEW und THIS ROUND (2026-10-15) = R1, „RUNDE 2026-10-16“ = R2, „RUNDE 2026-10-17“ = R3, jeweils mit dem echten Lieferdatum (R2 und R3 kamen am 2026-10-15 bzw. 2026-10-16). Im Sync-Abschnitt bitte #10 nachtragen („Synced through #10“). Das Datum einer Runde ist immer das Lieferdatum, nie ein Datum aus unserem Prompt.
3. **Unsere Prompts** nummerieren die Runden (R4 …) und nennen kein Datum.

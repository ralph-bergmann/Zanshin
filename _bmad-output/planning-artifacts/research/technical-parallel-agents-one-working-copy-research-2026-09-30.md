# Parallele AI-Agents in einem Arbeitsverzeichnis: GitButler vs. jj

**Datum:** 2026-09-30 · **Anlass:** Konsolensession mit Ralph zum GitButler-Video [„Agentic Git with GitButler: Parallel branches with multiple agents.“](https://www.youtube.com/watch?v=pXPTPr91Xew) (Scott Chacon, veröffentlicht 2026-09-29)
**Fragen:** Wie arbeiten dort drei Agents (2× Claude Code, 1× Cursor) gleichzeitig im selben Verzeichnis und erzeugen am Ende getrennte, teils gestapelte Branches, ohne Worktrees? Kann jj das auch? Im Video heißt es sinngemäß (0:13), GitButler könne das, Git und Jujutsu nicht.
**Methode:** Video-Transkript, GitButler-Doku und GitButler-Quellcode gelesen (Agent-Skill `crates/but/skill/`, Lock `crates/but-ctx/src/access.rs`). jj-lib 0.44.0 (vendored) und die jj-CLI @ v0.44.0 gelesen und mit Datei:Zeile belegt. Experimente mit jj 0.45.1 in Wegwerf-Repos; alle Skripte stehen in Anhang A, damit man die Messungen nachspielen kann. jj-Issues upstream durchsucht.
**Status:** Nur eine Notiz, damit wir später wissen, wie es gehen könnte. Keine Story, keine Entscheidung. Offen ist, ob das eher ein Zanshin-Feature oder ein PR an jj wird (Abschnitt 9). Nachträge vom selben Tag in Abschnitt 10; die Idee einer Zanshin-CLI ist bewusst vertagt (Gründe am Ende von 10.2). Eine Kurzrecherche zur Nachfrage steht in 10.3.

---

**Kurz:** GitButler löst das nicht mit Git-Bordmitteln, sondern mit einer eigenen Schicht darüber:
- Der Arbeitsstand ist ein Merge-Commit aus allen Branches.
- Änderungen werden erst beim Commit einem Branch zugeordnet, bis hinunter zu einzelnen Hunks.
- Baut eine Änderung auf einem anderen Branch auf, erzwingt GitButler das Stapeln.
- Ein prozessübergreifendes Lock serialisiert alle Schreibzugriffe.
- Ein Skill bringt den Agents das alles bei.

jj kennt dasselbe Modell als Community-Workflow „Megamerge“, und der funktioniert heute schon. Es fehlen drei Werkzeuge:
- Ein Lock über den ganzen Befehl. Ohne ihn entstehen bei parallelen jj-Aufrufen divergente Kopien, gemessen 1458 nach sechs Runden.
- Eine nicht-interaktive Hunk-Auswahl. Per `--tool`-Skript nachrüstbar, upstream offen als #8218.
- Eine Abhängigkeitssperre.

Mit einem kleinen Lock-Wrapper und einem kleinen Diff-Editor-Skript lief in den Tests alles sauber.

## 1. Was im Video passiert

- **Setup (ab 1:19):** `but agent setup` erkennt die installierten Agent-Harnesses und installiert den GitButler-Skill global oder pro Projekt, auf Wunsch mit Vorgaben zur Arbeitsweise.
- **Aufgaben:** Drei Agents arbeiten in derselben Demo-App (einem GitHub-Klon) im selben Verzeichnis: Dark Mode (Claude Code), eine farbige Statusleiste auf der Stats-Seite (Cursor), ein Markdown-Renderer plus README-Anzeige (Claude Code, als gestapelter Branch).
- **Arbeitsweise:** Die Agents prüfen mit `but diff` und `but show`, wohin ein Hunk gehört und ob er ihnen gehört (etwa 5:51). Sie committen selbst, meist am Ende ihres Turns. Das ist nicht deterministisch; einen Agent musste Scott anstoßen.
- **Ergebnis (ab 7:26):** Zwei Stapel mit je zwei Branches: Markdown-Renderer → README-Anzeige und Dark Mode → Stats-Seite. Den zweiten Stapel hat der Agent selbst angelegt, weil die Stats-Seite auf dem Dark Mode aufbaute (etwa 8:02). Die beiden Stapel sind voneinander unabhängig, ihre PRs lassen sich in beliebiger Reihenfolge mergen.

GitButler nannte das Feature früher „virtual branches“, heute „parallel branches“. Es sind echte Git-Branches.

## 2. Wie GitButler das technisch macht

### 2.1 Der Arbeitsstand ist ein Merge-Commit aller Branches

GitButler pflegt einen Branch `gitbutler/workspace`. Er zeigt auf einen Merge-Commit, dessen Eltern die Spitzen aller aktiven („applied“) Branches sind.
- HEAD zeigt auf diesen Commit, der Index entspricht der Vereinigung aller committeten Stände.
- Das Arbeitsverzeichnis enthält also immer alle Branches zusammen plus die noch nicht committeten Änderungen. Kein Agent checkt je einen Branch aus.
- Ein direktes `git commit` würde auf dem Merge-Commit landen. GitButler blockiert es deshalb mit einem `pre-commit`-Hook.

### 2.2 Zuordnung erst beim Commit, bis auf Hunk-Ebene

`but diff` und `but status` vergeben Kurz-IDs für Dateien (`uvw`), Hunks (`uvw:2e4`), Commits und Branches. Ein Agent committet genau die IDs, die er für seine hält, direkt auf einen benannten Branch: `but commit -b <branch> -m "…" <id> <id>`. Gibt es den Branch noch nicht, wird er angelegt; danach baut GitButler den Workspace-Merge neu.
- Welche Hunks einem Agent gehören, entscheidet er selbst aus seinem Kontext. Die Doku nennt das Routing ausdrücklich die Aufgabe des Agents.
- Grenze: Liegen eigene und fremde Änderungen im selben Diff-Hunk, lässt sich das per ID nicht trennen.
- Laut trigger.dev gibt es auch eine Hook-Integration, die Änderungen automatisch einer Session zuordnet. trigger.dev nutzt bewusst den Skill-Weg, weil eine Session oft Änderungen für mehrere Branches produziert.

### 2.3 Abhängigkeiten erzwingen Stapeln

GitButler verfolgt, welche offenen Änderungen auf welchen Commits aufbauen, also Zeilen ändern, die ein Commit eingeführt hat. Eine abhängige Änderung darf nur in den Stapel, der diesen Commit enthält.
- Sonst scheitert `but commit` atomar, nennt Branch und Commit der Abhängigkeit und schlägt den Befehl zum Stapeln vor (`but move <branch> --above <abhängigkeit>` bzw. `but branch new <name> --above <abhängigkeit>`).
- So kam im Video das Stapeln zustande.
- Darauf beruht auch das Versprechen, dass unabhängige Branches garantiert sauber mergen: Sie existieren im Arbeitsverzeichnis ja schon gemeinsam.

### 2.4 Ein Skill bringt es den Agents bei

`but agent setup` installiert eine SKILL.md für Codex, Claude Code, Cursor, GitHub Copilot, Windsurf/Devin, OpenCode und generische Agent Skills. Im GitButler-Repo liegt sie unter `crates/but/skill/`, dazu `references/` mit Konzepten, Beispielen und Befehlsreferenz. Die Kernregeln, zusammengefasst:
- Keine Git-Schreibbefehle (`add`, `commit`, `checkout`, `rebase`, `stash`, `merge`, `cherry-pick`), immer `but`. Lesendes Git ist erlaubt.
- IDs immer aus der aktuellen Ausgabe kopieren, nie erfinden.
- Sind mehrere Stapel aktiv, ist ein Ziel-Branch Pflicht.
- Immer `-m` mitgeben, damit kein Editor aufgeht.
- Dazu Rezepte für Amend, Split, Squash, Umsortieren, Stapeln, Konfliktauflösung und PRs.

### 2.5 Ein Lock serialisiert alle Schreibzugriffe

Schreibende Operationen holen `exclusive_worktree_access()`, lesende `shared_worktree_access()` (`crates/but-ctx/src/access.rs`).
- Das ist ein prozessübergreifendes Read/Write-Lock. Es bevorzugt Schreiber, damit sie nicht verhungern.
- Es gilt für die ganze Operation.
- Parallele `but`-Aufrufe mehrerer Agents laufen dadurch nacheinander ab.

### 2.6 Grenzen laut GitButler selbst

- **Keine Laufzeit-Isolation.** Die Agents teilen Dateisystem, installierte Abhängigkeiten, generierte Dateien und App-Zustand. Ein kaputter Zwischenstand eines Agents bricht den Build aller.
- **Dieselbe Datei ist riskant.** Fassen zwei Sessions dieselbe Datei an, sollen die Agents das vor dem Commit ansprechen. trigger.dev berichtet von Races und gegenseitiger Störung in überlappenden Bereichen.
- **Der Vorteil gegenüber Worktrees** laut trigger.dev: keine zweite Datenbank, keine doppelten `node_modules` (bei ihnen etwa 9,8 GB für zwei Worktrees) und ein einziger Dev-Server mit Hot Reload.

## 3. „GitButler setzt doch auch auf Git“

Stimmt, aber nur als Speicher. Commits, Trees und Refs sind normales Git, die Branches sind echte Git-Branches. Git selbst kann das nicht: Pro Worktree gibt es genau ein HEAD und einen Index, und `git commit` landet immer auf HEAD. Alles aus Abschnitt 2 ist GitButlers eigene Schicht.

Bei jj ist es genauso: Git als Speicher-Backend, ein eigenes Modell obendrauf. Die Frage ist also nur, ob jjs Modell das hergibt.

## 4. Das jj-Gegenstück: Megamerge

In der jj-Community heißt das Muster Megamerge (siehe Steve Klabnik und Chris Krycho in den Quellen):
- Man baut einen lokalen Merge aller aktiven Branches und legt darüber einen leeren WIP-Commit als `@`.
- Änderungen verteilt man per `jj squash --into` oder `jj absorb` zurück in die Branches.
- Gepusht werden nur die Branches, nie der Megamerge.

| GitButler | jj (getestet mit 0.45.1) |
|---|---|
| `gitbutler/workspace` | `jj new A B C -m megamerge`, darüber `jj new` (leerer WIP-Commit ohne Beschreibung als `@`) |
| offene Änderungen | `@` |
| `but commit -b X <datei-ids>` | `jj squash --into X -u <pfade>` |
| `but commit -b X <hunk-ids>` | `jj squash --into X -u --tool pick <pfad>` (Abschnitt 5.5) |
| neuer paralleler Branch | `jj new --no-edit -A main -B <megamerge> -m X`, danach Bookmark auf die ausgegebene Change-ID |
| Branch Y auf X stapeln | `jj new --no-edit -A X -m Y` (fügt Y zwischen X und Megamerge ein), danach Bookmark |
| automatische Zuordnung | `jj absorb` (per Blame in den nächsten veränderbaren Vorfahren, der diese Zeilen geändert hat) |
| Abhängigkeitssperre | keine; jj legt im Ziel einen Konflikt ab und meldet das (Abschnitt 5.3) |
| `but undo`, Oplog | `jj undo`, `jj op log` |
| PR | `jj git push -b X` |
| Lock | keins; nachrüsten per Wrapper (Abschnitt 8.1) |

Praktisch ist ein Alias für den Megamerge: `revset-aliases.mm = 'description(exact:"megamerge\n")'`.

## 5. Experimente (jj 0.45.1, Wegwerf-Repos)

### 5.1 Der Grundablauf funktioniert

Aufbau: drei Bookmarks ab `main`, ein Megamerge, darüber ein WIP-`@`. Drei „Agents“ ändern je eine Datei, und jeder schiebt seine Datei mit `jj squash --into <bookmark> <datei>` in seinen Branch.

Ergebnis:
- drei unabhängige Branches, jeder mit nur seiner Datei;
- Megamerge und `@` rebaset jj automatisch;
- `@` ist danach leer.

### 5.2 `jj absorb` findet den richtigen Branch selbst

Eine Änderung an einer Zeile, die der Dark-Mode-Branch eingeführt hat, verschiebt `jj absorb` selbstständig dorthin. Neue Zeilen und Dateien, die noch kein Branch angefasst hat, bleiben in `@`.

### 5.3 Abhängigkeit: Konflikt statt Ablehnung

Der „Stats-Agent“ ändert eine Dark-Mode-Zeile und squasht sie in den unabhängigen Branch `stats`.
- jj lehnt nicht ab, sondern hinterlegt in `stats` einen Konflikt und meldet ihn („New conflicts appeared in 1 commits“; `jj resolve --list -r stats` zeigt die Datei).
- Nach `jj undo`, Stapeln (`jj new --no-edit -A dark-mode`, Bookmark) und Squash in den gestapelten Branch ist alles sauber.

jj verhindert es also nicht vorher wie GitButler, macht es aber sofort sichtbar.

### 5.4 Editor-Falle

Wird `@` durch den Squash leer und haben Quelle und Ziel beide eine Beschreibung, will jj die Beschreibungen zusammenführen und öffnet `$EDITOR`. Der Agent bricht dann ab („Failed to edit description“).

Abhilfe: immer `-u` (`--use-destination-message`) und `@` ohne Beschreibung lassen.

### 5.5 Hunk-genaues Zuordnen per `--tool` funktioniert

Zwei Agents ändern verschiedene Stellen derselben Datei (Zeile 3 und 37, also zwei Hunks).
- Das Diff-Editor-Skript `pick.sh` (Anhang A.2) setzt `$right` auf `$left` zurück und spielt nur den gewählten Hunk als Patch ein.
- Aufruf: `jj squash --into agent-a -u --tool pick shared.txt`, danach dasselbe für `agent-b`.
- Ergebnis: Jeder Branch enthält genau seinen Hunk, `@` ist leer.

Diesen Weg schlägt auch yuja in #8218 vor, und das Community-Tool `jj-hunk` nutzt dieselbe Schnittstelle (Abschnitt 7).

### 5.6 Parallelität: hier liegt der Haken

Jeweils 6 Runden, pro Runde 3 gleichzeitige `jj squash --into bN -u fileN`:

| Szenario | Fehler | „reconcile“-Ops | divergente Commits | Inhalte korrekt |
|---|---|---|---|---|
| ohne Lock | keine | 6 | **1458** | ja |
| nur die Squashes gelockt | keine | 0 | 0 | ja |
| Squashes gelockt, dazu eine ungelockte `jj diff`-Schleife | keine | 0 | 0 | ja |
| wie vorher, aber ein 4. „Agent“ editiert laufend weiter | keine | 18 | **19** | ja |
| alle jj-Aufrufe gelockt (mkdir-Lock), Edits laufen weiter | keine | 0 | 0 | ja |
| alle jj-Aufrufe über `jj-agent` (flock), Edits laufen weiter | keine | 0 | 0 | ja |
| ungelocktes Skript, aber `jj` per PATH-Shim (Anhang A.3) | keine | 0 | 0 | ja |

Was das heißt:
- **jj verliert keine Daten und meldet keinen Fehler.** Die divergenten Kopien sind inhaltsgleich und ließen sich aufräumen.
- **Aber sie vervielfachen sich mit jeder Runde.** Sie verstopfen `jj log` und machen den Megamerge per Change-ID mehrdeutig.
- **Auch Lesebefehle müssen unter das Lock.** `jj diff`, `jj status` und `jj log` snapshotten das Arbeitsverzeichnis und schreiben dabei `@` um. Alternative: `--ignore-working-copy`, dann sehen sie aber einen veralteten Stand.

## 6. Warum jj divergiert (Code @ v0.44.0)

1. **Das Working-Copy-Lock gilt nur für den Snapshot.** `snapshot_working_copy` holt es (`cli/src/cli_util.rs:2073`), committet bei Änderungen die Operation „snapshot working copy“ (:2180) und gibt es mit `locked_ws.finish` wieder frei (:2225).
2. **Die eigentliche Transaktion läuft ohne Lock.** Der Squash arbeitet auf dem Stand, den der Prozess geladen hat, und wird in `finish_transaction` committet (:2300–2361).
3. **Der Checkout lockt neu, prüft aber nur den Baum.** `Workspace::check_out` (jj-lib `src/workspace.rs:456–482`) vergleicht nur, ob der Baum auf der Platte noch dem erwarteten entspricht (`ConcurrentCheckout`, :467–471). Ein Squash innerhalb des Megamerge ändert den Inhalt des Arbeitsverzeichnisses aber nicht, die Änderung wandert nur von `@` in einen Vorfahren. Der Baum bleibt gleich, der Check schlägt nie an, und kein Befehl meldet einen Fehler.
4. **Beim nächsten Laden werden die Operationen zusammengeführt.** Drei Prozesse haben drei Operationen auf derselben Basis committet, und alle schreiben `@` und den Megamerge um. `load_at_head` führt die Operationsköpfe zusammen („reconcile divergent operations“, jj-lib `src/repo.rs:706–729`).
   - Die Branch-Commits wurden je nur einmal umgeschrieben und bleiben sauber.
   - `@` und der Megamerge haben drei Nachfolger und sind damit divergent.
   - In der nächsten Runde vervielfacht sich das.
5. **Präzedenzfall für ein längeres Lock.** Einige CLI-Befehle halten das Working-Copy-Lock schon über den ganzen Befehl: `jj file track/untrack`, `jj sparse`, `jj workspace add/rename` und `jj op abandon`. Sie nutzen `WorkspaceCommandHelper::start_working_copy_mutation` (`cli/src/cli_util.rs:1497–1507`), das bei geändertem Baum mit „Concurrent working copy operation. Try again.“ abbricht. Umschreibende Befehle wie `squash`, `absorb` oder `rebase` tun das nicht.
6. **Nicht verwechseln:** Der Race-Fix aus jj 0.36 (#6830, parallele Befehle in colocated Repos) betrifft Snapshot-Rennen, nicht dieses Muster. Gemessen wurde mit 0.45.1.

## 7. Was jj fehlt, und der Stand upstream (Suche am 2026-09-30)

| Lücke | Heute machbar | Upstream |
|---|---|---|
| Lock über den ganzen Befehl | `jj-agent`-Wrapper oder PATH-Shim (Anhang A.3), und zwar für alle jj-Aufrufe | keine passende Issue gefunden (Suche nach concurrent, divergent, lock), wäre also neu |
| Hunk-Auswahl ohne TUI | `--tool`-Skript (5.5) oder `jj-hunk` | #8218, offen seit 2025-12 |
| Abhängigkeitssperre | nach jedem Squash `jj log -r 'conflicts() & mutable()'` prüfen, bei neuem Konflikt `jj undo` und stapeln | nichts gefunden |
| Agent-Skill | selbst schreiben (Anhang B) | – |

Zur Hunk-Auswahl im Detail:
- **#8218 „FR: Programmatically selecting hunks“** (offen): Vorgeschlagen sind Zeilenbereiche (`--lines datei:10-25`), Hunk-IDs aus einer JSON-Ausgabe, ein Patch über stdin und eine JSON-Auswahl. yuja (Maintainer) verweist auf `--tool` mit einem Auswahl-Skript und hält Zeilenbereiche auch anderswo für nützlich.
- **#9814 „FR: Agent-friendly interfaces for split/squash/diffedit/restore“** wurde am 2026-07-15 als Duplikat von #8218 geschlossen. yuja sieht Agents nicht anders als Programme, die Hunks auswählen.
- **`jj-hunk`** (laulauland, Rust, zuletzt aktualisiert 2026-09-17): Auswahl per Hunkset-Abfrage oder per JSON/YAML mit Hunk-IDs, für `split`, `commit` und `squash`. Es nutzt die Diff-Tool-Schnittstelle von jj. `jj-hunk squash` schiebt nur in den Parent. Für einen Megamerge-Branch bräuchte es also zwei Schritte: `jj-hunk split`, dann `jj squash --from … --into X` (ungetestet).

## 8. Wie man es mit jj bauen könnte

### 8.1 Stufe 0: ohne neuen Code, sofort nutzbar

1. **Megamerge einmal pro Repo aufsetzen** (Anhang A.1).
2. **Jeden jj-Aufruf der Agents serialisieren.** Am bequemsten per PATH-Shim (Anhang A.3): Ein Verzeichnis mit einer Datei `jj`, die den echten jj unter einem `flock` aufruft, kommt vorne in den `PATH` der Agent-Sessions. Die Agents tippen weiter `jj`.
   - Die Lock-Datei gehört nach `.jj/`, weil jj dort nichts snapshottet. Im Arbeitsverzeichnis würde sie selbst zur Änderung.
   - `flock(2)` gibt der Kernel frei, wenn der Prozess endet. Nach einem Absturz bleibt also kein Lock hängen.
3. **Agent-Regeln als Skill** (Entwurf in Anhang B). Das Wichtigste: Agents dürfen `@` nie verschieben. Ein `jj new` oder `jj edit` auf „ihren“ Branch würde das Arbeitsverzeichnis aller Agents umschalten. Das ist das Gegenstück zum `git checkout`-Verbot bei GitButler.
4. **Hunks:** `pick.sh` + `hunk.py` (Anhang A.2) oder `jj-hunk`.

### 8.2 Stufe 1: Zanshin als Koordinator

- **Gleiches Lock-Protokoll.** Zanshin arbeitet über jj-lib im eigenen Prozess und ist aus Sicht der Agents ein weiterer paralleler Schreiber. Damit GUI und Agents sich nicht gegenseitig Divergenz erzeugen, müsste Zanshin dasselbe Lock (`.jj/agent.lock`) respektieren.
  - Seit Story 9.26 (implicit snapshot + colocated git import) snapshottet Zanshin implizit wie die CLI.
  - Das entspricht Zeile 4 der Messung in 5.6: Ein Leser snapshottet, während jemand anderes editiert und squasht.
  - Mit Zanshin selbst ist das nicht getestet, sollte aber genauso auftreten, sobald Agents im selben Arbeitsverzeichnis laufen.
- **Spannung zu FR-MCP-9.** Die PRD legt dort fest: GUI und MCP-Server auf demselben Repo gleichen sich über den Filesystem-Watcher ab, ausdrücklich ohne Locking-Choreografie. Die Messung zeigt, dass das bei gleichzeitigem Umschreiben desselben Commits zu Divergenz führt. Ein Koordinator-Feature würde FR-MCP-9 berühren.
- **Bausteine sind vorhanden.** Story 9.22 hat `mutate::lock_working_copy` und `mutate::commit_with_locked_wc` gebracht: eine Transaktion unter gehaltenem Working-Copy-Lock, wie bei `jj file track`. Das ist dieselbe Idee im Kleinen.
- **Oberfläche:**
  - Lanes als Eltern des Megamerge.
  - Hunks per Drag & Drop in eine Lane ziehen, was einem `jj squash --into` mit Hunk-Auswahl entspricht.
  - Vor dem Ablegen ein Abhängigkeitshinweis per Blame wie bei `absorb` („diese Zeilen stammen aus Branch X, stapeln?“), danach eine Konfliktwarnung.
  - Die Graph-Ansicht aus Epic 10 zeigt den Megamerge ohnehin.
- **Kanal zu den Agents.** Einfachster Weg: Die Agents benutzen weiter die jj-CLI mit Lock (Stufe 0), und Zanshin spielt nur mit. Alternativ ein Zanshin-eigener Kanal mit Hunk-IDs und Abhängigkeitsprüfung; das hängt an der offenen MCP-Entscheidung.
- **CLI-Parität.** Alles lässt sich aus vorhandenen jj-Verben zusammensetzen (`new -A/-B`, `squash --into`, `absorb`, `bookmark`, `undo`). Das passt zur Regel, das beobachtbare CLI-Verhalten nachzubilden. Das Lock dagegen ist eine Zanshin-/Agent-Konvention, kein jj-Verhalten.

### 8.3 Stufe 2: PRs an jj

Kandidaten, grob nach Erfolgsaussicht:
1. **Hunk-Auswahl (#8218).** Die Nachfrage ist belegt, Maintainer sind beteiligt, mehrere Designs liegen auf dem Tisch. Ein Beitrag nützt allen jj-Nutzern und über jj-lib auch Zanshin. *(Einschränkung: siehe Nachtrag 10.1.)* Vorher im Issue oder auf Discord klären, welche Variante gewünscht ist; Zeilenbereiche wirkten bei yuja am anschlussfähigsten.
2. **Serialisierung.** Zwei denkbare Formen:
   - als Opt-in das Working-Copy-Lock über den ganzen schreibenden Befehl halten, wie es `jj file track` schon tut (Abschnitt 6, Punkt 5);
   - die Transaktion auf dem neuen Kopf wiederholen, wenn `@` inzwischen von einer anderen Operation umgeschrieben wurde, statt Divergenz zu erzeugen.

   Das ist schwieriger, weil jj bewusst auf lock-freie Nebenläufigkeit über das Op-Log setzt. Erst als Issue mit den Messwerten aus 5.6 und dem Skript aus Anhang A.4 vorschlagen.
3. **Konflikt-Sperre für `squash`/`absorb`.** Etwa ein Flag, das abbricht, statt einen neuen Konflikt abzulegen. Das wäre klein, läuft aber gegen jjs Grundsatz, dass Konflikte Daten sind. Ausgang offen.

## 9. Entscheidungshilfe: Zanshin oder PR an jj? (offen)

Kriterien:
- **Wer profitiert?** Ein PR an jj nützt allen jj-Nutzern und Zanshin gleich mit. Ein Zanshin-Feature nützt nur Zanshin-Nutzern, bringt dafür die Oberfläche (Lanes, Drag & Drop, Hinweise).
- **Modell oder Werkzeug?** Das Modell hat jj schon. Die fehlenden Bausteine ganz unten (Hunk-Auswahl, Serialisierung) gehören eher nach jj, Bedienung und Koordination eher nach Zanshin. *(Für Zanshins eigene Oberfläche liegt die Hunk-Auswahl ohnehin bei Zanshin, siehe 10.1.)*
- **Abhängigkeiten:** die offene MCP-Entscheidung, FR-MCP-9 und die CLI-Paritätsregel.
- **Aufwand und Risiko:** Stufe 0 kostet fast nichts und zeigt, ob der Workflow im Alltag trägt.

Denkbare Reihenfolge (nur ein Vorschlag): Stufe 0 ausprobieren, bei Bedarf #8218 upstream voranbringen, danach Zanshin als Koordinator mit Oberfläche.

## 10. Nachträge

### 10.1 Zanshin selbst braucht #8218 nicht

*Rückfrage von Ralph am 2026-09-30: Geht in Zanshin ohne #8218 überhaupt `split`, oder das, was `jj squash --interactive` auf der Konsole macht?*

Ja, das geht. #8218 betrifft nur die Kommandozeile von jj, also Programme, die das `jj`-Binary aufrufen (Agents im Terminal, Skripte). Zanshin ruft die CLI nicht auf, sondern jj-lib direkt.

- **So arbeitet `-i` in der CLI:** Erst liefert ein Diff-Editor die Auswahl, und die endet als Baum. Das erledigt der eingebaute Editor im CLI-Crate (`cli/src/merge_tools/builtin.rs` @ v0.44.0: `apply_diff_builtin` :404, `apply_changes` :466). Dann verschiebt jj-lib diesen Baum: `rewrite::squash_commits` nimmt `CommitWithSelection` mit dem ausgewählten Baum (jj-lib `src/rewrite.rs:1259` und `:1320`).
- **Den ersten Schritt ersetzt Zanshin durch die eigene Diff-Ansicht.** So steht es schon in ADR-0003: Interaktive Verben bekommen einen von der GUI gebauten `TreeId`, und `SelectedTree` ersetzt den interaktiven `DiffSelector` der CLI. project-context.md führt das als Regel.
- **Im Code vorbereitet:** `SelectedTree::from_tree_id` (`crates/zanshin-jj/src/op_support.rs:430`) ist getestet, hat aber noch keinen Aufrufer. Die ersten Aufrufer bringen Story 9.15 (`squash`, `split` für Teile von Dateien) und 9.17 (`commit`, `resolve`, `diffedit`). Die Hunks für die Diff-Ansicht liefert Epic 5 (5.1, 5.8). Alles davon ist im Backlog.
- **Was fehlt, liegt auf Zanshin-Seite: der Schritt „Auswahl → Baum“.** Die GUI kann selbst keine jj-Bäume schreiben. Das Backend nimmt die Auswahl (Hunks oder Zeilen pro Datei), wendet sie auf die Elternversion an, schreibt Dateien und Baum (`MergedTreeBuilder`) und gibt den `TreeId` zurück. Alternativ nimmt das Verb die Auswahl direkt.
  - Vorbild ist `apply_diff_builtin`. Es liegt im CLI-Crate und wird deshalb portiert wie andere Teile von `cli_util`.
  - Sonderfälle wie in der CLI: Binärdateien, Executable-Bit, neue und gelöschte Dateien, Konflikte.
  - Die genaue Form der Übergabe führt ADR-0003 noch als offene Frage.
- **Folge für diese Notiz:** Abschnitt 8.3 (1.) gilt nur für Tools, die die jj-CLI benutzen. Zanshin profitiert höchstens indirekt, falls #8218 als wiederverwendbare Funktion in jj-lib umgesetzt wird.
- **Folge für das Agent-Thema:** Die Hunk-Auswahl, die Agents auf der Kommandozeile fehlt, baut Zanshin für die eigene Diff-Ansicht ohnehin. Derselbe Baustein wäre das Zuordnen einzelner Hunks in Stufe 1 (8.2) und in 10.2.

### 10.2 Option: eine Zanshin-CLI wie `but`

*Rückfrage von Ralph am 2026-09-30: Könnte man eine Zanshin-CLI bauen, mit der mehrere Agents im selben Verzeichnis arbeiten wie im Video mit `but`?*

Technisch ja. Das wäre GitButlers Architektur mit jj als Unterbau.
- **GitButler ist genau so gebaut:** Die Desktop-App (`crates/gitbutler-tauri`) und die `but`-CLI (`crates/but`) hängen beide an denselben Kern-Crates `but-api` und `but-ctx`.
- **Zanshin hat dieselbe Form:** `zanshin-jj` ist der Kern mit typisierten Verben (ADR-0003). Darauf sitzen `zanshin-ffi` für die Flutter-App und `zanshin-mcp` (bisher ein Stub). Eine CLI wäre ein weiterer Konsument derselben Verben, im Sinn von ADR-0003 Punkt 3.

Was die CLI gegenüber `jj` mitbringen müsste, entlang der Lücken aus Abschnitt 7:

| `but` im Video | Zanshin-CLI | Baustein in Zanshin |
|---|---|---|
| Lock pro Operation | jeder Aufruf nimmt ein Repo-Lock, das auch die GUI nimmt | Vorlage: 9.22 (`lock_working_copy`, `commit_with_locked_wc`); prozessübergreifend ist neu |
| Kurz-IDs für Dateien und Hunks | `zanshin diff` mit Kurz-IDs, z. B. ein kurzer Hash über Pfad und Hunk-Inhalt | Hunks aus Epic 5 (5.1); stabile IDs sind neu |
| `but commit -b X <ids>` | `zanshin squash --into X <ids>` | „Auswahl → Baum“ aus 10.1 + Story 9.15 |
| Abhängigkeitssperre | vor dem Squash prüfen, ob die Zeilen aus einem anderen Branch stammen; dann ablehnen und Stapeln vorschlagen | `file annotate` aus Story 9.4 (`FileAnnotator`) |
| Branch anlegen, stapeln | Megamerge-Befehle wie `jj new -A/-B` und `bookmark` | `Repo::new_change` (bisher nur mit Eltern) und `bookmark create` gibt es; `-A/-B` fehlt noch als Verb, die Einfüge-Logik `compute_commit_location` liegt aber schon in `op_support.rs:199` |
| `but agent setup` | installiert einen Skill (Entwurf in Anhang B) | neu |

Die teuersten Teile (Hunks, „Auswahl → Baum“, `squash`) braucht die GUI für 9.15, 9.17 und Epic 5 ohnehin. Neu für die CLI wären Lock-Protokoll, stabile IDs, Abhängigkeitsprüfung, Megamerge-Befehle, Skill und Verteilung.

Zu klären, bevor man das baut:
- **FR-MCP-9:** Ein gemeinsames Lock von CLI und GUI ist genau die „Locking-Choreografie“, die FR-MCP-9 ausschließt. Das müsste neu entschieden werden.
- **Nebeneinander mit der jj-CLI:** jj hat keine Hooks. GitButler blockiert `git commit` per `pre-commit`-Hook, Zanshin kann schreibende `jj`-Aufrufe dagegen nicht blockieren. Schutz gäbe es nur per Skill-Regel oder PATH-Shim (8.1).
- **Agent-Schnittstelle:** Eine CLI mit Skill wäre eine Alternative zum MCP-Server. Die MCP-Entscheidung ist offen.
- **Umfang:** Die Verben darunter bleiben CLI-Parität. Hunk-IDs, Abhängigkeitssperre und Lock sind Zanshin-eigene Zusätze, also eine neue Produktfläche und eher ein eigenes Epic.
- **Verteilung:** ein Rust-Binary im App-Bundle, das die App auf Wunsch in den `PATH` verlinkt, ähnlich wie GitButler die CLI separat installieren lässt.

Was dafür spricht:
- Das Ergebnis bleibt reines jj. Megamerge, Branches und Bookmarks sind normale jj-Objekte; `jj log` zeigt alles, und wer nur die jj-CLI benutzt, kann weiterarbeiten.
- Die Zanshin-GUI könnte die Lanes live zeigen, während die Agents arbeiten, über den Filesystem-Watcher aus FR-MCP-9.
- Stufe 0 (8.1) zeigt vorher ohne Code, ob der Workflow im Alltag trägt.

**Stand (Ralph, 2026-09-30): bewusst noch nicht entschieden.** Zwei Gründe:
- Es ist noch unklar, ob das ein Feature ist, das jeder braucht.
- Es gibt genug andere Stories, die zuerst umgesetzt werden wollen.

Deshalb gibt es dazu keine Story.

### 10.3 Kurzrecherche: Wollen AI-Nutzer das überhaupt?

*Rückfrage von Ralph am 2026-09-30, vor dem Commit: Ist das ein Feature, das sich AI-Nutzer wünschen, oder eher „Guck mal, was GitButler kann“? Er selbst hatte bisher nicht das Bedürfnis, Claude an mehreren Stories gleichzeitig arbeiten zu lassen.*

Man muss zwei Dinge trennen.

**Parallele Agents überhaupt: verbreitet, aber eher etwas für Power-User.**
- **Die großen Tools haben es fest eingebaut, isoliert per Worktree.** Die Claude-Code-Desktop-App legt für jede Session automatisch einen Worktree an, die CLI hat `--worktree`. Cursor 3 lässt im Agents Window bis zu acht Agents parallel in Worktrees laufen. Dazu gibt es eine eigene Tool-Kategorie (Conductor, Claude Squad, Superset, Nimbalyst u. a.).
- **Die tatsächliche Nutzung ist verhaltener.** Stack Overflow Pulse Survey (April 2026, 1.100 Befragte): 69 % arbeiten mit einem einzelnen Agent, 17 % mit mehreren spezialisierten, 16 % mit mehreren koordinierten. 68 % bevorzugen berechenbare Ein-Agent-Setups. Wer mehrere Agents nutzt, tut das allerdings häufiger täglich (85 % bzw. 77 % gegenüber 54 %).
- **Erfahrungsberichte sind sich weitgehend einig:** Der Engpass ist der Mensch, der prüfen und zwischen Kontexten wechseln muss. Praktikabel sind etwa 2 bis 5 parallele Sessions.
  - Gut geht es mit unabhängigen, klar beschriebenen Aufgaben. Simon Willison nennt Recherche, Prototypen, Code verstehen und kleine Wartung.
  - Schlecht geht es bei Architekturentscheidungen und in gemeinsam genutzten Hotspot-Dateien.
  - The Pragmatic Engineer (Oktober 2025) sieht einen aufkommenden Trend, vor allem bei erfahrenen Engineers, die ohnehin gut zwischen Kontexten wechseln.
- **Stimmungsbild aus einem Ask-HN-Thread** (nur 15 Kommentare): Etwa sechs berichten von Erfolg, meist mit Worktrees. Etwa vier sehen wenig Nutzen, vor allem wegen des Kontextwechsels.

**Gleiches Verzeichnis ohne Worktrees: eine Nische, die vor allem GitButler vorantreibt.**
- Fast alle Tools isolieren per Worktree. Die Variante ohne Worktree propagieren vor allem GitButler selbst (Doku, Blog, Video) und einzelne Nutzer wie trigger.dev.
- Der Grund dafür ist echt, aber speziell: ein gemeinsamer Dev-Server, eine gemeinsame Datenbank, einmal `node_modules`. Im Ask-HN-Thread verzichtet genau einer aus diesem Grund auf Worktrees.

**jj-Bezug:** Die jj-Community bildet das gängige Muster auf jj-Workspaces ab. Mehrere Plugins und Skills lenken Claude Codes Worktree-Funktion auf `jj workspace` um (claude-jj-worktree, jj-workspace-skill), dazu gibt es Blogposts. Für den Megamerge-Weg gibt es vereinzelte Agent-Skills; in dieser Kurzrecherche war die Workspace-Variante häufiger zu finden.

**Einordnung:**
- Der Bedarf, Agents mehrere Aufgaben gleichzeitig erledigen zu lassen, ist echt, aber eine Praxis von Power-Usern. Die Mehrheit arbeitet mit einem Agent, so wie Ralph bisher. Das passt zu Grund (a) in 10.2.
- Die konkrete Variante aus dem Video (ein Verzeichnis, keine Worktrees) ist vor allem GitButlers Alleinstellungsmerkmal.
- Falls Zanshin hier je etwas anbietet, wäre die verbreitetere Form die Isolation per jj-Workspace, etwa alle Workspaces und ihre `@` gut sichtbar im Graphen. Das ist eine Beobachtung, keine Empfehlung.

Quellen zu 10.3:
- [Stack Overflow: Agents on a leash](https://stackoverflow.blog/2026/05/27/agents-on-a-leash-agentic-ai-remains-mostly-monitored-at-work/) (Pulse Survey April 2026)
- [Claude Code Docs: Run parallel sessions with worktrees](https://code.claude.com/docs/en/worktrees), [Cursor Docs: Worktrees](https://cursor.com/docs/configuration/worktrees)
- [Simon Willison: Embracing the parallel coding agent lifestyle](https://simonw.substack.com/p/embracing-the-parallel-coding-agent) (2025-10-06), [The Pragmatic Engineer: New trend: programming by kicking off parallel AI agents](https://blog.pragmaticengineer.com/new-trend-programming-by-kicking-off-parallel-ai-agents/) (2025-10-30)
- [Ask HN: Is it actually possible to run multiple coding sessions in parallel?](https://news.ycombinator.com/item?id=47573483), [DEV: I Ran 10+ AI Coding Agents in Parallel. The Bottleneck Wasn't the AI.](https://dev.to/kikakkz/i-ran-10-ai-coding-agents-in-parallel-the-bottleneck-wasnt-the-ai-12e3)
- [GitButler: Managing Multiple Claude Code Sessions Without Worktrees](https://blog.gitbutler.com/parallel-claude-code), [trigger.dev](https://trigger.dev/blog/parallel-agents-gitbutler)
- jj: [claude-jj-worktree](https://github.com/jasagiri/claude-jj-worktree), [jj-workspace-skill](https://github.com/antstanley/jj-workspace-skill), [Parallel Claude Code with Jujutsu](https://slavakurilyak.com/posts/parallel-claude-code-with-jujutsu)

---

## Anhang A: Skripte

Alle Tests liefen mit einer isolierten jj-Konfiguration, damit weder die globale Identität noch Signing greifen:

```toml
# jjconfig.toml, aktiviert per  export JJ_CONFIG=/pfad/zu/jjconfig.toml
[user]
name = "Demo"
email = "demo@example.com"
[ui]
paginate = "never"
color = "never"
[signing]
behavior = "drop"
```

### A.1 Megamerge einrichten und benutzen

```bash
# Einmal pro Repo; Branch-Namen nach Bedarf
jj new main -m dark-mode && jj bookmark create dark-mode -r @
jj new main -m stats     && jj bookmark create stats -r @
jj new main -m markdown  && jj bookmark create markdown -r @
jj new dark-mode stats markdown -m megamerge   # lokaler Merge, nie pushen
jj new                                         # leerer WIP-Commit ohne Beschreibung = @

# Zuordnen (mm = Alias aus Abschnitt 4)
jj squash --into dark-mode -u src/theme.css    # ganze Dateien
jj absorb                                      # Zeilen, die ein Branch schon geändert hat
jj new --no-edit -A main -B mm -m new-feature  # neuer paralleler Branch
jj new --no-edit -A dark-mode -m stats-ui      # auf dark-mode stapeln
jj bookmark create new-feature -r <change-id aus der Ausgabe>
jj log -r 'conflicts() & mutable()'            # nach jedem Squash: neuer Konflikt? -> jj undo, stapeln
jj git push -b dark-mode                       # nur Branches pushen, nie den Megamerge
```

### A.2 Hunk-Auswahl per `--tool`

`pick.sh`: ein Diff-Editor, der genau die Hunks aus `$AGENT_PATCH` auswählt. Er braucht `rsync` und `patch`, beide sind auf macOS vorhanden.

```bash
#!/bin/bash
# jj diff editor for agents: select exactly the hunks in $AGENT_PATCH, nothing else.
# jj calls it with the before/after snapshots ($left, $right) and takes $right as the selection.
set -eu
left="$1"; right="$2"
rsync -a --delete --exclude JJ-INSTRUCTIONS "$left/" "$right/"   # select nothing ...
if [ -s "${AGENT_PATCH:-}" ]; then
  patch -p1 -s -d "$right" < "$AGENT_PATCH"                        # ... then add the chosen hunks
fi
```

`hunk.py`: schneidet einen Hunk (per Index) einer Datei aus `jj diff --git` als eigenständigen Patch aus.

```python
#!/usr/bin/env python3
"""Print hunk <index> of <path> from a `jj diff --git` stream on stdin as a standalone patch."""
import sys

path, index = sys.argv[1], int(sys.argv[2])
blocks, cur = [], []
for line in sys.stdin.read().splitlines(keepends=True):
    if line.startswith("diff --git ") and cur:
        blocks.append(cur)
        cur = []
    cur.append(line)
if cur:
    blocks.append(cur)

for block in blocks:
    if block[0].rstrip("\n").endswith(" b/" + path):
        header, hunks = [], []
        for line in block:
            if line.startswith("@@"):
                hunks.append([line])
            elif hunks:
                hunks[-1].append(line)
            else:
                header.append(line)
        sys.stdout.write("".join(header) + "".join(hunks[index]))
        break
```

Konfiguration und Aufruf:

```toml
[merge-tools.pick]
program = "/pfad/zu/pick.sh"
edit-args = ["$left", "$right"]
```

```bash
jj diff --git shared.txt | python3 hunk.py shared.txt 0 > /tmp/mein-hunk.patch
AGENT_PATCH=/tmp/mein-hunk.patch jj squash --into agent-a -u --tool pick shared.txt
# Hunk-Indizes verschieben sich nach jedem Squash -> Diff jedes Mal neu lesen
```

Getestetes Demo-Skript (zwei Agents, zwei Hunks in einer Datei):

```bash
#!/bin/bash
# Two agents edit DIFFERENT hunks of the SAME file; each routes only its hunk into its branch.
set -u
SCRATCH="$(cd "$(dirname "$0")" && pwd)"
export JJ_CONFIG="$SCRATCH/jjconfig.toml"
TOOL=(--config "merge-tools.pick.program=\"$SCRATCH/pick.sh\"" --config 'merge-tools.pick.edit-args=["$left", "$right"]')
LOG_T='change_id.shortest(4) ++ " " ++ description.first_line() ++ if(bookmarks, " [" ++ bookmarks ++ "]") ++ if(conflict, " (CONFLICT)") ++ if(current_working_copy, " <- @") ++ "\n"'

rm -rf "$SCRATCH/hunks"; mkdir "$SCRATCH/hunks"; cd "$SCRATCH/hunks" || exit 1
jj git init . >/dev/null 2>&1
seq -f 'line %g' 1 40 > shared.txt
jj commit -m "base" >/dev/null 2>&1
jj bookmark create main -r @- >/dev/null 2>&1
for b in agent-a agent-b; do
  jj new main -m "$b" >/dev/null 2>&1
  jj bookmark create "$b" -r @ >/dev/null 2>&1
done
jj new agent-a agent-b -m "megamerge" >/dev/null 2>&1
jj new >/dev/null 2>&1

sed -i '' 's/^line 3$/line 3 (agent A)/' shared.txt
sed -i '' 's/^line 37$/line 37 (agent B)/' shared.txt
echo "=== @ before routing (two hunks, one file) ==="; jj diff --git 2>&1

jj diff --git shared.txt | python3 "$SCRATCH/hunk.py" shared.txt 0 > "$SCRATCH/hunkA.patch"
AGENT_PATCH="$SCRATCH/hunkA.patch" jj squash "${TOOL[@]}" --into agent-a -u --tool pick shared.txt 2>&1 | sed 's/^/  A: /'
jj diff --git shared.txt | python3 "$SCRATCH/hunk.py" shared.txt 0 > "$SCRATCH/hunkB.patch"
AGENT_PATCH="$SCRATCH/hunkB.patch" jj squash "${TOOL[@]}" --into agent-b -u --tool pick shared.txt 2>&1 | sed 's/^/  B: /'

echo "=== graph ==="; jj log -r 'main::' -T "$LOG_T" 2>&1
for b in agent-a agent-b; do echo "=== diff of $b ==="; jj diff --git -r "$b" 2>&1; done
echo "=== @ after routing ==="; jj diff --summary 2>&1; echo "(end)"
```

### A.3 Lock: Wrapper und PATH-Shim

`jj-agent`: expliziter Wrapper (Agents rufen `jj-agent <args>` statt `jj <args>` auf).

```bash
#!/bin/bash
# Serialize EVERY jj call in this repo (read commands snapshot the working copy too).
# flock(2) is released by the kernel when the process ends, so a crashed jj never leaves a stale lock.
lock="$(jj root --ignore-working-copy)/.jj/agent.lock" || exit 1
exec perl -MFcntl=:flock -e '
  open(my $fh, ">>", shift) or die "jj-agent: $!\n";
  flock($fh, LOCK_EX) or die "jj-agent: $!\n";
  system(@ARGV);
  exit($? == -1 ? 127 : ($? & 127) ? 128 + ($? & 127) : $? >> 8);
' "$lock" jj "$@"
```

PATH-Shim `<agent-bin>/jj`: Agents tippen normal `jj`. Getestet, Exit-Codes werden durchgereicht.

```bash
#!/bin/bash
# PATH shim: put this directory FIRST in the agents' PATH, then every `jj` an agent types is serialized.
REAL_JJ=/opt/homebrew/bin/jj   # absolute path (`command -v jj` without the shim), else the shim calls itself
root="$("$REAL_JJ" root --ignore-working-copy 2>/dev/null)" || exec "$REAL_JJ" "$@"   # outside a repo: no lock
exec perl -MFcntl=:flock -e '
  open(my $fh, ">>", shift) or die "jj shim: $!\n";
  flock($fh, LOCK_EX) or die "jj shim: $!\n";
  system(@ARGV);
  exit($? == -1 ? 127 : ($? & 127) ? 128 + ($? & 127) : $? >> 8);
' "$root/.jj/agent.lock" "$REAL_JJ" "$@"
```

### A.4 Parallelitätstests

Minimale Reproduktion der Divergenz, ohne Lock. Das wäre auch die Grundlage für eine Upstream-Issue. Aufruf: `bash concurrency-demo.sh 6`.

```bash
#!/bin/bash
# Concurrency demo: three "agents" route their changes out of the shared @ at the same time.
set -u
SCRATCH="$(cd "$(dirname "$0")" && pwd)"
export JJ_CONFIG="$SCRATCH/jjconfig.toml"
ROUNDS="${1:-5}"

LOG_T='change_id.shortest(4) ++ " " ++ description.first_line() ++ if(bookmarks, " [" ++ bookmarks ++ "]") ++ if(conflict, " (CONFLICT)") ++ if(divergent, " (DIVERGENT)") ++ if(current_working_copy, " <- @") ++ "\n"'

rm -rf "$SCRATCH/conc"; mkdir "$SCRATCH/conc"; cd "$SCRATCH/conc" || exit 1
jj git init . >/dev/null 2>&1
printf 'base\n' > base.txt
jj commit -m "base" >/dev/null 2>&1
jj bookmark create main -r @- >/dev/null 2>&1
for b in b1 b2 b3; do
  jj new main -m "$b" >/dev/null 2>&1
  jj bookmark create "$b" -r @ >/dev/null 2>&1
done
jj new b1 b2 b3 -m "megamerge" >/dev/null 2>&1
jj new >/dev/null 2>&1   # WIP commit without description

for round in $(seq 1 "$ROUNDS"); do
  for i in 1 2 3; do echo "round $round" >> "file$i.txt"; done
  for i in 1 2 3; do
    jj squash --into "b$i" -u "file$i.txt" > "$SCRATCH/conc-out$i.log" 2>&1 &
  done
  wait
  errs=""
  for i in 1 2 3; do
    if grep -q -i -E "error|stale|concurrent" "$SCRATCH/conc-out$i.log"; then
      errs="$errs agent$i: $(grep -i -E 'error|stale|concurrent' "$SCRATCH/conc-out$i.log" | head -1);"
    fi
  done
  wcdiff=$(jj diff --summary 2>&1 | tr '\n' ' ')
  echo "round $round | errors:${errs:- none} | @ left: ${wcdiff:-clean}"
done

echo
echo "=== graph after $ROUNDS rounds ==="
jj log -r 'main::' -T "$LOG_T" 2>&1
echo "=== divergent / conflicted commits ==="
jj log --no-graph -r 'divergent() | conflicts()' -T "$LOG_T" 2>&1; echo "(end)"
echo "=== file contents per branch ==="
for i in 1 2 3; do
  echo "--- b$i:file$i.txt"; jj file show -r "b$i" "file$i.txt" 2>&1 | tr '\n' ' '; echo
done
echo "=== last operations ==="
jj op log --no-graph -n 12 -T 'id.short() ++ " " ++ description ++ "\n"' 2>&1
```

Die Varianten mit Lock. Aufruf: `bash locked-demo.sh 6 <MODE>`, optional mit `LOCKER=wrapper` (nutzt `jj-agent` aus A.3 statt des mkdir-Locks). Den PATH-Shim testet man, indem man `concurrency-demo.sh` mit `PATH="<agent-bin>:$PATH"` startet.

```bash
#!/bin/bash
# Same as concurrency-demo.sh, but the "agents'" jj calls go through a mutex.
# MODE=writes-only              : only the squashes are locked, nothing else runs
# MODE=reads-unlocked           : squashes locked, plus an unlocked `jj diff` loop (agents inspecting)
# MODE=reads-and-edits-unlocked : as above, plus a 4th "agent" that keeps editing file4.txt
# MODE=all-locked-with-edits    : the `jj diff` loop is locked too, edits keep running
# LOCKER=wrapper                : use ./jj-agent (flock) instead of the mkdir lock
set -u
SCRATCH="$(cd "$(dirname "$0")" && pwd)"
export JJ_CONFIG="$SCRATCH/jjconfig.toml"
ROUNDS="${1:-6}"
MODE="${2:-writes-only}"
LOCKDIR="$SCRATCH/jj-agent.lock"
rm -rf "$LOCKDIR"

jjlocked() {
  if [ "${LOCKER:-mkdir}" = "wrapper" ]; then "$SCRATCH/jj-agent" "$@"; return $?; fi
  until mkdir "$LOCKDIR" 2>/dev/null; do sleep 0.02; done
  jj "$@"; local rc=$?
  rmdir "$LOCKDIR"
  return $rc
}

rm -rf "$SCRATCH/locked"; mkdir "$SCRATCH/locked"; cd "$SCRATCH/locked" || exit 1
jj git init . >/dev/null 2>&1
printf 'base\n' > base.txt
jj commit -m "base" >/dev/null 2>&1
jj bookmark create main -r @- >/dev/null 2>&1
for b in b1 b2 b3; do
  jj new main -m "$b" >/dev/null 2>&1
  jj bookmark create "$b" -r @ >/dev/null 2>&1
done
jj new b1 b2 b3 -m "megamerge" >/dev/null 2>&1
jj new >/dev/null 2>&1

reader_pid=""
if [ "$MODE" = "reads-unlocked" ] || [ "$MODE" = "reads-and-edits-unlocked" ]; then
  ( while true; do jj diff --summary >/dev/null 2>&1; done ) &
  reader_pid=$!
fi
if [ "$MODE" = "all-locked-with-edits" ]; then
  ( while true; do jjlocked diff --summary >/dev/null 2>&1; sleep 0.01; done ) &
  reader_pid=$!
fi
editor_pid=""
if [ "$MODE" = "reads-and-edits-unlocked" ] || [ "$MODE" = "all-locked-with-edits" ]; then
  ( n=0; while true; do n=$((n+1)); echo "edit $n" >> file4.txt; sleep 0.01; done ) &
  editor_pid=$!
fi

for round in $(seq 1 "$ROUNDS"); do
  for i in 1 2 3; do echo "round $round" >> "file$i.txt"; done
  for i in 1 2 3; do
    jjlocked squash --into "b$i" -u "file$i.txt" > "$SCRATCH/locked-out$i.log" 2>&1 &
  done
  wait $(jobs -p | grep -v -E "^(${reader_pid:-none}|${editor_pid:-none})$")
done
[ -n "$editor_pid" ] && kill "$editor_pid" 2>/dev/null && wait "$editor_pid" 2>/dev/null
[ -n "$reader_pid" ] && kill "$reader_pid" 2>/dev/null && wait "$reader_pid" 2>/dev/null

echo "MODE=$MODE ROUNDS=$ROUNDS"
echo "divergent commits: $(jj log --no-graph -r 'divergent()' -T 'commit_id ++ "\n"' 2>/dev/null | wc -l | tr -d ' ')"
echo "reconcile ops:     $(jj op log --no-graph -T 'description ++ "\n"' 2>/dev/null | grep -c 'reconcile divergent')"
echo "@ left:            $(jj diff --summary 2>&1 | tr '\n' ' ')"
for i in 1 2 3; do
  echo "b$i:file$i.txt -> $(jj file show -r "b$i" "file$i.txt" 2>&1 | tr '\n' ' ')"
done
```

## Anhang B: Entwurf für Agent-Regeln (Skill-Skizze, ungetestet)

- Du teilst das Arbeitsverzeichnis mit anderen Agents. `@` ist der gemeinsame Arbeitsbereich über dem Megamerge (`mm`).
- `jj` ist in deinem `PATH` ein Shim, der alle Aufrufe serialisiert. Umgehe ihn nie, auch nicht für Lesebefehle.
- **Verschiebe `@` nie:** kein `jj new` ohne `--no-edit`, kein `jj edit`, `jj prev` oder `jj next`, kein `jj commit` (das nähme die Arbeit aller mit).
- **Verwirf nie fremde Arbeit:** kein `jj restore` oder `jj abandon` auf `@` ohne Pfade, kein `jj squash` ohne Pfade.
- **Dein Branch:** Bookmark `<name>`. Ist er neu: `jj new --no-edit -A main -B mm -m <name>`, dann Bookmark auf die ausgegebene Change-ID. Baut deine Arbeit auf einem anderen Branch auf: `jj new --no-edit -A <anderer-branch> -m <name>`.
- **Zuordnen:** `jj squash --into <dein-bookmark> -u <deine-pfade>`. Teilst du eine Datei mit anderen, nur deine Hunks per `--tool pick` (A.2).
- **Danach prüfen:** `jj log -r 'conflicts() & mutable()'`. Bei einem neuen Konflikt: `jj undo`, stapeln, neu zuordnen.
- **Beschreibung:** `jj describe -r <dein-bookmark> -m "…"`. Den Megamerge nie beschreiben und nie pushen.
- **Push:** `jj git push -b <dein-bookmark>`.
- **Kein schreibendes `git`** (colocated Repo).

## Quellen

- Video: [Agentic Git with GitButler: Parallel branches with multiple agents.](https://www.youtube.com/watch?v=pXPTPr91Xew) (GitButler, 2026-09-29)
- GitButler-Doku: [Parallel agents](https://docs.gitbutler.com/ai-agents/parallel-agents), [Getting started](https://docs.gitbutler.com/ai-agents/getting-started), [Workspace Branch](https://docs.gitbutler.com/workspace-branch), [Parallel Branches](https://docs.gitbutler.com/features/branch-management/virtual-branches)
- GitButler-Quellcode: [Agent-Skill `crates/but/skill/SKILL.md`](https://github.com/gitbutlerapp/gitbutler/blob/HEAD/crates/but/skill/SKILL.md), [`references/concepts.md`](https://github.com/gitbutlerapp/gitbutler/blob/HEAD/crates/but/skill/references/concepts.md), [Lock `crates/but-ctx/src/access.rs`](https://github.com/gitbutlerapp/gitbutler/blob/HEAD/crates/but-ctx/src/access.rs); gemeinsamer Kern von App und CLI: `crates/gitbutler-tauri/Cargo.toml` und `crates/but/Cargo.toml` hängen beide an `but-api` und `but-ctx`
- Erfahrungsbericht: [trigger.dev, „We ditched worktrees for Claude Code“](https://trigger.dev/blog/parallel-agents-gitbutler) (2026-04-16)
- Megamerge in jj: [Steve Klabnik, Working on all of your branches simultaneously](https://steveklabnik.github.io/jujutsu-tutorial/advanced/simultaneous-edits.html), [Chris Krycho, Jujutsu Megamerges and jj absorb](https://v5.chriskrycho.com/journal/jujutsu-megamerges-and-jj-absorb/)
- jj-Issues: [#8218 Programmatically selecting hunks](https://github.com/jj-vcs/jj/issues/8218), [#9814 Agent-friendly interfaces](https://github.com/jj-vcs/jj/issues/9814), [#6830 Race-Fix colocated (0.36)](https://github.com/jj-vcs/jj/issues/6830)
- Community-Tool: [laulauland/jj-hunk](https://github.com/laulauland/jj-hunk)
- jj-Code @ v0.44.0: `cli/src/cli_util.rs` (`snapshot_working_copy` 2058–2231, `finish_transaction` 2300ff., `start_working_copy_mutation` 1497–1507), jj-lib `src/workspace.rs:456–482`, `src/repo.rs:706–729`; CHANGELOG (0.36: #6830, 0.44: `jj absorb -i/--tool`); für 10.1: `cli/src/merge_tools/builtin.rs` (`apply_diff_builtin` 404, `apply_changes` 466), jj-lib `src/rewrite.rs` (`CommitWithSelection` 1259, `squash_commits` 1320)
- Zanshin: PRD FR-MCP-9; sprint-status 9-22 (`lock_working_copy`, `commit_with_locked_wc`), 9-26 (implicit snapshot + colocated git import); ADR-0003 (Punkte 3 und 4, offene Frage zum Interactive-verb contract); `crates/zanshin-jj/src/op_support.rs` (`compute_commit_location` 199, `SelectedTree::from_tree_id` 430); epics.md Stories 9.15, 9.17 und Epic 5

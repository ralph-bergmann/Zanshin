# Architektur-Review: Dart/Flutter-Code — DI, Boot, Kopplung

Datum: 2026-11-07 · Scope: `app/lib`, `packages/*/lib`; Tests nur, soweit sie die Verdrahtung zeigen.
Nicht geprüft: Rust, Interna des Graph-Features (28 k Zeilen, nur an seinen Grenzen), Performance-Messungen.

## Kurzfassung

Dein Gefühl stimmt. inject.dart ist eingebaut, aber nicht die Composition Root: Der Graph liefert Factories und
Singletons, verdrahtet wird danach von Hand — in `main()`, `_startApp`, `appWindowCoordinator` und in den
Projekt-Hosts unter `home/`. `MainComponent` dient dabei als Service Locator: alle acht Getter existieren nur, damit
`main.dart` Objekte herausholen und selbst zusammenstecken kann.

Die Ursachen sind wenige:

1. Zwei Objekte, die vor dem Graph existieren müssen (`AppWindows`, der Worker), kommen nicht auf dem Weg in den
   Graph, den `SettingsModule(store:)` vormacht. Der Worker nimmt einen Sonderweg (`@asynchronous` + `Completer` +
   `Future<ZanshinWorker>` durch zwei Klassen), `AppWindows` ist gar nicht im Graph.
2. Ein Zyklus Coordinator → Fensterinhalte → `AppMenuModel` → Coordinator, „gelöst" mit `attach()` und Settern nach
   der Konstruktion. Er entsteht nur, weil `AppMenuModel` zugleich Menü und Ablage für den aktuellen Graph, den
   Projects-Key und `openUrl` ist.
3. Ein app-weiter Seiteneffekt (Theme auf die native Fenster-Chrome spiegeln) lebt in einem fensterbezogenen
   ViewModel — daher die zweite, von Hand gebaute `ZanshinAppViewModel`-Instanz.

Der Plan (§6) hat vier Phasen plus zwei optionale; keine ändert sichtbares Verhalten. Ergebnis: eine Component mit
einem Getter (`ZanshinApplication get application`), `main.dart` mit ca. 40 statt 251 Zeilen, keine Verdrahtung per
Setter oder `attach()`, Tests über eine Test-Component statt nachgebauter Factories.

## 1. Was gut ist und bleibt

- Paketschnitt: `zanshin_core` ist Flutter-frei und mit `dart test` testbar; die Shell ist ein föderiertes Plugin;
  die Settings sind ein eigenes Paket.
- „Resolve before the graph" für asynchrone Ressourcen (`SettingsModule(store:)`) — das richtige inject.dart-Muster
  für einen synchronen Graph.
- Assisted Injection für Widgets mit Laufzeitparametern (`HomePage`, `ZanshinWindowRoot`, `ProjectsWindow`,
  `ZanshinApp`) und `ViewModelFactory` für fensterbezogene ViewModels — idiomatisch.
- Die Splash-Logik (`ZanshinBootSequence`) ist von der Fensterschicht getrennt (`BootWindowHost`) und mit Fake-Time
  getestet (24 Tests).
- `AppWindowCoordinator` serialisiert Fensterübergänge (`_serial`) und ist über Builder-Closures gut testbar
  (22 Tests).

## 2. DI-Befunde

### 2.1 `MainComponent` als Service Locator

`main.dart:214–251`: acht Getter (`zanshinAppFactory`, `worker`, `projectSession`, `projectsWindowFactory`,
`zanshinWindowRootFactory`, `appMenu`, `settings`, `projectsEnvironment`). Jeder wird in `main.dart:144–203`
gelesen, um etwas von Hand zu bauen oder nachträglich zu verdrahten. Nach Lehrbuch (und wie in deinen Projekten)
liefert die Component genau einen Einstiegspunkt; alles darunter kommt per Konstruktor.

### 2.2 Vier Composition Roots

| Ort | Was dort verdrahtet wird |
|---|---|
| `main()`, `main.dart:88–97` | `AppWindows`, zwei `ValueNotifier` (Icons, Menü), Boot-Sequenz mit vier Callbacks |
| `_startApp`, `main.dart:130–153` | Component, Worker-`Completer`, `projectSession.mayLeave = …`, `bindWindowZoom`, `appMenu.attach(…)`, `menu.value = …` |
| `appWindowCoordinator`, `main.dart:164–204` | Coordinator mit vier Builder-Closures (eine mit `late`-Selbstreferenz), `SettingsWindow` und `RevsetConfigsWindow` von Hand, zweites `ZanshinAppViewModel` |
| Projekt-Hosts, `project_graph_host.dart:131–230`, `home_page.dart:249–374` | pro Repository ca. 15 Objekte (Graph-VM, Suche, Preferences, Inspector, Sync, Ports, Bookmarks, Undo Timeline) |

Die vierte ist berechtigt (Laufzeit-Scope pro Repository, siehe §5). Die ersten drei gehören in den Graph.

### 2.3 Verdrahtung nach der Konstruktion

- `AppMenuModel.attach(windows, actions, settings)` (`app_menu.dart:134`) — obwohl `SettingsStore` im Graph ist;
  `windows` und `actions` fehlen nur, weil sie nicht im Graph sind.
- `ProjectSession.mayLeave = windows.mayClose` (`main.dart:146`; öffentliches, mutables Feld
  `project_session.dart:163`).
- `AppMenuModel.openUrl`: öffentliches, mutables Funktionsfeld als Test-Naht (`app_menu.dart:127`).
- `Completer<ZanshinWorker>` → `ProjectsModule(worker: worker.future)` → `worker.complete(await component.worker)`
  (`main.dart:136–144`): Der Graph wird über ein Versprechen gebaut, das `main` danach selbst einlöst.

### 2.4 `ZanshinAppViewModel` doppelt

Pro Fenster über `ViewModelFactory` (richtig) und einmal von Hand in `main.dart:167` — nur damit `SettingsWindow`
`setThemeMode` aufrufen kann. Diese Instanz wird nie `init()`-et und nie `dispose()`-t; sie hängt für die
Lebensdauer der App einen Listener an den Store.

Ursache: `setThemeMode`/`_mirrorWindowAppearance` ist ein app-weiter Seiteneffekt in einem fensterbezogenen VM.
Zusätzlich ruft jedes neue Fenster in `init()` erneut `setWindowAppearance` auf (`zanshin_app_view_model.dart:95`),
obwohl das Plugin die letzte Wahl ohnehin auf später erzeugte Fenster anwendet (`ZanshinShellPlugin.swift:96`).

Lösung: ein `@singleton WindowAppearanceSync` hört auf `settings.appearance.themeMode` und spiegelt. Das VM behält
nur abgeleiteten Fensterzustand; `SettingsWindow` schreibt nur noch die Einstellung.

### 2.5 Warum `SettingsStore` nicht injiziert wird

Er ist im Graph (`SettingsModule(store:)`), und dass er vorher geladen wird, ist richtig. Verteilt wird er aber
großteils von Hand:

- `appMenu.attach(…, settings)` und `bindWindowZoom(settings, …)` (`main.dart:149–150`);
- `RevsetConfigsWindow(settings: component.settings)`, `SettingsWindow(store: component.settings)`,
  `ZanshinAppViewModel(component.settings)` (`main.dart:167–198`);
- durch ein ViewModel getunnelt: `FloatingShellViewModel.settings` (`floating_shell_view_model.dart:41`) gibt es nur,
  damit `HomePage` den Store an `ProjectGraphHost` und `_UndoTimelineHost` weiterreicht (`home_page.dart:91, 100`).

Per Konstruktor injiziert wird er nur in `ProjectRegistry`, `FloatingShellViewModel` und `ZanshinAppViewModel`.

### 2.6 Worker: Sonderweg statt Vorab-Auflösung

`WorkerModule` (`zanshin_core`) ist `@asynchronous`. Damit `ProjectSession` und Co. nicht asynchron werden, reicht
`ProjectsModule` ein `Future<ZanshinWorker>` durch, und `WorkerProjectRepos` und `DesktopProjectsEnvironment` müssen
intern darauf warten. Das widerspricht dem Muster, das du für die Settings gewählt hast (resolve before the graph).
Der Kommentar in `worker_module.dart:9–11` („create becomes async") ist veraltet.

Wichtig für den Umbau: Der Worker muss weiterhin nach `adoptShellEnvironment` starten. `tracing_init.rs:78, 152`
liest Log-Filter, Log-Verzeichnis und `HOME` aus der Umgebung; ein früherer Start würde Variablen aus der Login-Shell
verpassen. Die Reihenfolge bleibt also wie heute, nur liegt der Start vor `create()`.

### 2.7 ProvisionListener als Exit-Hook

`WorkerLifecycleModule` registriert den `AppLifecycleListener` (⌘Q → Close-Guards → `worker.close`) als Nebeneffekt
der Provisionierung (`worker_lifecycle_module.dart:28–31, 63–70`). Das funktioniert, ist aber schwer zu finden: Wer
den Quit-Ablauf sucht, findet ihn nicht über den Boot. Mit vorab gestartetem Worker feuert der Listener ohnehin
nicht mehr; ein expliziter `AppExitHandler` hakt sich beim App-Start ein.

### 2.8 Tote oder irreführende DI

- `IconModule`: Das `IconRegistry`-Binding wird angelegt, aber von keinem Binding konsumiert (`main.inject.dart:103`
  — `iconRegistry$Provider` geht nirgends hinein). Die Icons erreichen die Fenster über den `ValueNotifier` im Host.
- `@inject` auf `GraphViewModel` (`graph_view_model.dart:187`): nie über den Graph aufgelöst, überall
  `GraphViewModel()..init(…)`.
- `ZanshinFfiModule` (`zanshin_version.dart:10`): an keiner Component installiert; nur Tests rufen
  `ZanshinFfiModule().zanshinFfiVersion()` direkt.
- Eigene Klassen per `@provides` statt `@inject` (`ProjectRegistry` in `ProjectsModule`). Kleinigkeit: `@inject`
  für eigene Klassen, Module für Interfaces und Fremdtypen.

### 2.9 Tests bauen generierten Code nach

`zanshin_app_test.dart:41–107`, `home_page_test.dart` und `zanshin_window_root_test.dart` implementieren
`HomePageFactory`, `ZanshinWindowRootFactory`, `Provider<T>` und `ViewModelFactory` von Hand nach.
`zanshin_app_test.dart` importiert `main.dart`, und vier Tests prüfen, ob `appWindowCoordinator()` richtig von Hand
verdrahtet.
Beides folgt aus 2.1 und 2.2: Verdrahtet der Graph, garantiert der Build die Typen, und Tests nehmen eine
Test-Component mit Test-Modul (Skill `inject_annotation-write-tests`).

## 3. Boot-Prozess

### Ist: 14 Funktionsübergaben in 5 Dateien

```
main()                                                         main.dart
 ├ icons = ValueNotifier, menu = ValueNotifier, windows = AppWindows()
 └ ZanshinBootSequence(host: ZanshinWindowHost(windows, icons, menu),
 │    openSettings ①, adoptShellEnvironment ②, loadIcons ③ (schreibt icons.value), startApp ④).run()
 │   ├ Timer(250 ms) → host.openSplash → runWidget(Wurzel mit Builder für menu und icons)
 │   └ _load: ① ‖ ② ‖ ③ → ④ _startApp(settings, icons, windows, menu)
 │        ├ Completer worker; MainComponent.create(…, ProjectsModule(worker.future),
 │        │                                      WorkerLifecycleModule(mayQuit: windows.mayClose ⑤))
 │        ├ worker.complete(await component.worker) → ProvisionListener → AppLifecycleListener ⑥
 │        ├ projectSession.mayLeave = windows.mayClose ⑦
 │        ├ appWindowCoordinator(component, windows) → AppWindowCoordinator(buildProject ⑧,
 │        │     buildProjects ⑨ (onOpened ⑩, onSettings ⑪ → late coordinator), buildRevsetConfigs ⑫, buildSettings ⑬)
 │        ├ bindWindowZoom(settings, windows); appMenu.attach(windows, coordinator, settings); menu.value = appMenu
 │        └ coordinator.start() → BootFirstWindow(content, kind, onShown ⑭)
 └ _openMainWhenDue → host.openMain/openProjects → dismissSplash → onShown ⑭ → coordinator._shown → Reopen …
```

Wesentlich (bleibt): das Splash-Rennen (250 ms / 3 s), das erste Fenster muss in `runWidget`, die Fehlerseite, das
Reopen erst nach dem ersten Fenster. Zufällig (fällt weg): vier Schritt-Callbacks in die Sequenz, der
Icons-Seiteneffekt, das Durchreichen von `menu` und `windows`, der `Completer`, die Setter, die
`late`-Selbstreferenz.

### Soll

```dart
Future<void> main() async {
  await runZonedGuarded(() async {
    _initBindingAndLogging(); // heute main.dart:48–81, unverändert
    final windows = AppWindows();
    final host = ZanshinWindowHost(windows: windows); // besitzt den Menü-Notifier selbst
    await ZanshinBootSequence(host: host).run((progress) async {
      final BootValues boot = await loadBootValues(progress); // Settings ‖ Shell-Env ‖ Icons, danach Worker
      final ZanshinApplication app = AppComponent.create(bootModule: BootModule(boot, windows)).application;
      host.menu = app.menu;
      return app.start(); // Zoom, Exit-Handler, Theme-Sync, coordinator.start()
    });
  }, _logZoneError);
}
```

- `ZanshinBootSequence.run` nimmt eine einzige Boot-Funktion. `progress` meldet die Statuszeilen und das gespeicherte
  Theme für die Fehlerseite (heute `_persistedMode` über den Settings-Callback).
- `loadBootValues` ist eine gewöhnliche async-Funktion; heute ist sie über `_load` und drei Lambdas verteilt.
- `ZanshinApplication.start()` listet die Start-Schritte an einer Stelle, statt sie in `_startApp` zwischen
  Graph-Aufbau und Settern zu verteilen.
- `IconRegistryScope` wandert in `ZanshinWindowRoot` (Registry injiziert). Damit entfallen `icons`-Notifier und
  Seiteneffekt, und das Binding hat einen echten Konsumenten. Vorher prüfen: Der Splash greift nicht auf
  `IconRegistryScope` zu; ob `BootFailure` Icons braucht, ist offen.

Performance: Der Umbau macht den Boot nicht schneller. Der kritische Pfad bleibt max(Settings, Login-Shell ca.
210 ms, Icons) plus Worker-Start, und der Worker kann wegen 2.6 nicht früher starten. Sichtbar teuer ist nur die
3-Sekunden-Mindestanzeige, wenn der Boot 250 ms überschreitet — ein eigenes, offenes Thema.

## 4. Projektstruktur und Kopplung

### Pakete

```
app              → zanshin_core, zanshin_settings, zanshin_shell, zanshin_ui
zanshin_ui       → zanshin_settings (AccentSource), zanshin_shell (ShellTheme, ScrollerStyle, WindowDragArea)
zanshin_settings → material_ui (ThemeMode)
zanshin_shell    → zanshin_shell_platform_interface, zanshin_shell_macos
```

Zwei kleine Schichtverletzungen: Das Design-System kennt das Persistenzmodell (`zs_appearance.dart:6`), und das
Settings-Modell kennt die UI-Bibliothek. Sauber wäre: `zanshin_ui` bekommt einen eigenen Akzent-Typ, die App mappt;
die Settings speichern einen eigenen Theme-Enum. Niedrige Priorität, es tut heute nicht weh.

### `app/lib/src/features` ist kein Modulschnitt

Import-Zyklen zwischen Feature-Ordnern: shell ↔ graph, shell ↔ home, shell ↔ bootstrap, shell ↔ projects,
window ↔ bootstrap, window ↔ app, window ↔ settings, graph ↔ settings, graph ↔ undo_timeline.

Fast alle haben zwei Ursachen. Erstens liegt das Menü (`shell/app_menu.dart`, oberste Ebene: es greift auf Graph,
Projekte, Sync und Fenster zu) im selben Ordner wie die kleinen Shell-Bausteine, die der Graph benutzt
(`calm_controller`, `shell_scope`, `shell_toast`) — daher shell ↔ graph, shell ↔ projects, shell ↔ home. Zweitens
liegen ein paar Symbole im falschen Ordner:

| Symbol | Liegt in | Gebraucht von | Gehört nach |
|---|---|---|---|
| `GraphMenuBinding` + `graph`-Notifier | `shell/app_menu.dart` | home, settings, graph/revset_configs | `graph/` als `@singleton ActiveGraph` |
| `jjDocumentationUrl`, `_openInBrowser` | `shell/app_menu.dart` | graph/revset_configs | injizierbares `OpenUrl` |
| `mainWindowTitle` | `bootstrap/boot_window_host.dart` | shell, home, window | `window/app_windows.dart` (neben `mainWindowKey`) |
| `openRecentProject` | `home/home_page.dart` | shell/app_menu | `projects/` |
| `BootFirstWindow`, `BootWindowKind` | `bootstrap/` | window/app_window_coordinator | `window/` |
| `ZanshinAppViewModel` | `features/app/` | window/zanshin_window_root | `window/` |

`AppMenuModel` (771 Zeilen) ist der Knoten: Es importiert 6 Feature-Ordner und wird aus 4 importiert. Nach dem
Herausziehen von `ActiveGraph` und `OpenUrl` hängt außer der App-Wurzel nichts mehr daran.

`app`, `bootstrap`, `window` und das Menü sind keine Features, sondern der Rahmen der App. Vorschlag: unter
`lib/src/app/` zusammenführen, mit der Regel „Features importieren aus `src/app/` nur `AppWindowActions` und die
Fenster-Konstanten". Das löst auch window ↔ settings (der Coordinator zieht mit um). Optional prüft ein kleiner Test
die Regel. Übrig bleiben graph ↔ settings (`immutable_reasons.dart` → `settings/immutable_heads.dart`) und
graph ↔ undo_timeline (`UndoTimelineActions`) — je ein Import, durch Verschieben des Helfers bzw. Interfaces nach
`graph/` lösbar.

`graph/` ist mit 50 Dateien und 28 k Zeilen fast die halbe App, an den Rändern aber sauber (kleine Shell-Bausteine,
`ProjectRepo`, `AppWindowActions`). Einziger Ausreißer ist `revset_configs_window.dart` → `app_menu.dart`. Ein
eigenes Paket wäre später möglich, ist aber kein Ziel dieses Plans.

### Kleinere Inkonsistenzen

- `ProjectsWindow` bekommt `onSettings` und `onIdentitySettings` als Callbacks, obwohl der Coordinator jeden Inhalt
  in `AppWindowActionsScope` legt und `HomePage` genau darüber Settings öffnet (`home_page.dart:140–147`). Mit dem
  Scope entfallen beide Callbacks und die `late`-Selbstreferenz in `main.dart:165`.
- `AppMenuModel.projectsKey` ist ein `GlobalKey<ProjectsWindowState>` im Model, damit Edit › Find in den
  Widget-State greifen kann. Besser: ein kleines injiziertes Fokus-Objekt (z. B. `ProjectsSearchFocus` mit
  `FocusNode`), das Fenster und Menü teilen.
- Globaler Zustand als versteckte Abhängigkeit: `ZsSheet.openViews` (statisch) und `ZanshinShell` (statische Fassade
  über `ZanshinShellPlatform.instance`). Für ein Flutter-Plugin üblich; niedrige Priorität.

## 5. Subkomponenten

inject.dart 1.2 kann `@Subcomponent` und `@subcomponentFactory` mit Wert-Parametern (wie Daggers `@BindsInstance`);
`@singleton` gilt dann pro Subkomponente.

**Sinnvoller Kandidat: der Projekt-Scope** (Lebensdauer = ein offenes Repository). Heute verwalten drei Widgets
denselben Lebenszyklus je für sich: `ProjectGraphHost` (`_Graph`), `_BookmarksHost` und `_UndoTimelineHost` —
dreimal „auf die Session hören, Repo vergleichen, Altes entsorgen, Neues bauen, `setState`".

- Schritt 1, ohne DI: ein `ProjectScope`-Objekt besitzt alle Objekte pro Repository und wird einmal pro
  Repo-Wechsel gebaut und entsorgt. Ein Host statt drei.
- Schritt 2, optional: `@Subcomponent([ProjectModule]) abstract class ProjectComponent { ProjectScope get scope; }`
  mit `@subcomponentFactory create(ProjectRepo repo, @projectRoot String root, ShellToasts toasts)`. Gewinn: die
  Konstruktion wird generiert und beim Build geprüft. Grenzen: inject.dart entsorgt nichts (die `dispose()`-Reihenfolge
  bleibt Handarbeit), und `GraphViewModel`/`GraphPreferences` nutzen Zwei-Phasen-`init()`, mit rund 60 Stellen
  `GraphViewModel()` in den Tests. Dafür bräuchte das Graph-Feature Konstruktor-Injection.

**Nicht empfohlen:** eine Subkomponente pro Fenster. Die fensterbezogenen Objekte (`ZanshinAppViewModel`,
`FloatingShellViewModel`) bekommen über `ViewModelFactory` schon je Fenster eine Instanz.

## 6. Refactoring-Plan

Jede Phase ist einzeln lieferbar und ändert kein sichtbares Verhalten. Gate: `cargo make test`. Ab Phase 2 zusätzlich
die laufende App per Marionette prüfen: schneller Boot, Boot mit Splash, Fehlerseite, ⌘Q mit „Discard changes?",
Projektwechsel mit Guard.

### Phase 0 — Aufräumen (klein, kein Risiko)

1. `@inject` von `GraphViewModel` entfernen.
2. `ZanshinFfiModule` → Top-Level-Funktion `zanshinFfiVersion()`; `zanshin_version_test.dart` und
   `native_asset_smoke_test.dart` anpassen.
3. `HomePage` bekommt `SettingsStore` injiziert; `FloatingShellViewModel.settings` entfällt.
4. `AppMenuModel` bekommt `SettingsStore` über den Konstruktor; `attach()` nimmt nur noch `windows` und `actions`.

### Phase 1 — Kopplung entflechten (klein bis mittel, nur Verschiebungen)

1. `ActiveGraph` (`ValueNotifier<GraphMenuBinding?>` samt `GraphMenuBinding`) nach `graph/`, `@inject @singleton`.
   Konsumenten: `ProjectGraphHost`, `AppMenuModel`, `SettingsWindow`, `RevsetConfigsWindow`. `HomePage` braucht
   `AppMenuModel` dann nicht mehr.
2. `OpenUrl` (typedef + Provider in einem Modul) statt des Felds `AppMenuModel.openUrl`; `jjDocumentationUrl` dazu.
3. `mainWindowTitle` → `window/app_windows.dart`; `openRecentProject` → `projects/`; `BootFirstWindow` und
   `BootWindowKind` → `window/`; `ZanshinAppViewModel` → `window/`.
4. `ProjectsWindow` öffnet Settings über `AppWindowActionsScope`; `onSettings` und `onIdentitySettings` entfallen.
5. `projectsKey` → `ProjectsSearchFocus`, injiziert in `ProjectsWindow` und `AppMenuModel`.
6. `app/`, `bootstrap/`, `window/` und `shell/app_menu.dart` unter `lib/src/app/` zusammenführen; die beiden
   Einzel-Importe graph → settings und graph → undo_timeline umdrehen.

Ergebnis: keine Import-Zyklen mehr zwischen Feature-Ordnern; der Zyklus Coordinator → Inhalte → Menü →
Coordinator ist aufgelöst.

### Phase 2 — Der Graph verdrahtet alles (mittel)

1. `BootModule(BootValues boot, AppWindows windows)` liefert `SettingsStore`, `IconRegistry`, `ZanshinWorker` und
   `AppWindows`. Es ersetzt `SettingsModule`, `IconModule`, `WorkerModule`, `WorkerLifecycleModule` und den
   `Completer`; `WorkerModule` in `zanshin_core` wird damit unbenutzt und kann weg. `WorkerProjectRepos` und `DesktopProjectsEnvironment` nehmen `ZanshinWorker` statt
   `Future<ZanshinWorker>` (rund 14 Teststellen: `Future.value(worker)` → `worker`).
2. `ProjectsModule`: `ProjectRepos` → `WorkerProjectRepos` als eigenes Binding (in Tests per Modul überschreibbar);
   `ProjectSession(…, mayLeave: windows.mayClose)` im Provider statt per Setter; `ProjectRegistry` per
   `@inject @singleton`.
3. `SettingsWindow` und `RevsetConfigsWindow` per `@assistedInject` (assisted: `state` bzw. nur `key`).
4. `AppModule` mit `@provides @singleton AppWindowCoordinator`: derselbe Code wie heute `appWindowCoordinator()`, aber
   im Graph und mit injizierten Factories. Die 22 Coordinator-Tests (Builder-Closures) bleiben unverändert. Dazu das
   Binding `AppWindowActions` → Coordinator.
5. `AppMenuModel(tracker, session, windows, actions, settings, activeGraph, projectsFocus, openUrl)`; `attach()`
   entfällt.
6. `WindowAppearanceSync` (`@singleton`, hört auf den Store) ersetzt `setThemeMode`/`_mirrorWindowAppearance` im VM
   und die zweite VM-Instanz.
7. `AppExitHandler(windows, worker)` ersetzt den ProvisionListener.
8. `ZanshinApplication` (`@inject @singleton`) hält Coordinator und Menü; `start()` ruft in dieser Reihenfolge
   `bindWindowZoom`, Exit-Handler, Theme-Sync und `coordinator.start()`.
9. `AppComponent` mit einem einzigen Getter: `ZanshinApplication get application;`.
10. Tests: eine Test-Component (`@Component([BootModule, ProjectsModule, AppModule, TestModule])`) statt der
    nachgebauten Factories in `zanshin_app_test`, `home_page_test` und `zanshin_window_root_test`. Die Tests
    „main.dart's coordinator builds …" werden zu Graph-Tests oder entfallen.

### Phase 3 — Boot linear (mittel)

1. `ZanshinBootSequence.run(Future<BootFirstWindow> Function(BootProgress) boot)`; die 24 Sequenz-Tests mechanisch
   anpassen.
2. `loadBootValues(progress)` als eine async-Funktion: Settings ‖ Shell-Env ‖ Icons, danach der Worker.
3. Der Host besitzt den Menü-Notifier; `IconRegistryScope` sitzt in `ZanshinWindowRoot` mit injizierter Registry;
   der `icons`-Notifier entfällt.
4. `main.dart` auf die Soll-Skizze aus §3 bringen.

### Phase 4 — Projekt-Scope (optional, groß)

Schritt 1 aus §5 (ein `ProjectScope`, ein Host). Schritt 2 (Subkomponente) nur, wenn der Scope weiter wächst.

### Phase 5 — Paketgrenzen (optional, mittel)

`zanshin_ui` ohne `zanshin_settings`; `zanshin_settings` ohne `material_ui`.

## 7. Offene Entscheidungen

1. Ein `BootModule` für alle vorab geladenen Werte — oder weiter ein Modul pro Paket im Stil von
   `SettingsModule(store:)` (dann `WorkerModule(worker:)` in `zanshin_core`)? Empfehlung: `BootModule`, damit es genau
   eine Stelle gibt, an der vorab geladene Werte in den Graph kommen.
2. Phase 4 jetzt mitnehmen oder später?
3. Laut CLAUDE.md entsteht UI-Code nur innerhalb einer Story. Vorschlag: eine Story für Phasen 0–1, eine für
   Phasen 2–3; Phasen 4 und 5 separat oder gar nicht.

**Stand 2026-11-07:** Ralph hat die Stories freigegeben — 11.24 (Phasen 0–1) und 11.25 (Phasen 2–3; Frage 1 ist
dort Design-Frage (a)) in `epics.md` und `sprint-status.yaml`. Phasen 4 und 5 stehen als Vorschläge in
`deferred-work.md` („Surfaced 2026-11-07 in the Dart architecture review").

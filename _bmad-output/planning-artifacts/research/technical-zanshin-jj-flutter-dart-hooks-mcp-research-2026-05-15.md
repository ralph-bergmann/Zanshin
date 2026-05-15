---
stepsCompleted: [1, 2, 3, 4, 5, 6]
inputDocuments: []
workflowType: 'research'
lastStep: 1
research_type: 'technical'
research_topic: 'Zanshin – Flutter macOS GUI Client for JJ VCS with Dart Hooks & MCP Server'
research_goals: 'Project scaffolding strategy for integrating JJ (Rust) via Dart Hooks into a Flutter macOS app; MCP Server SDK comparison (dart_mcp vs rust-sdk); extensibility for future Rust crates'
user_name: 'Ralph'
date: '2026-05-15'
web_research_enabled: true
source_verification: true
---

# Research Report: technical

**Date:** 2026-05-15
**Author:** Ralph
**Research Type:** technical

---

## Executive Summary

Zanshin ist ein Flutter Desktop GUI Client für JJ VCS auf macOS, mit eingebettetem MCP Server für AI-Assistenten. Die zentrale technische Herausforderung: JJ (Rust) sauber in den Flutter/Dart-Stack einbetten, ohne sich an versionsempfindliche Abstraktionsschichten zu binden.

**Maturity-Anspruch:** Production-ready von Tag eins. Es gibt keine MVP-Stufe mit nachgelagerter Härtung — alle Entscheidungen (Bibliotheks-Auswahl, Fehlerbehandlung, Watcher-Architektur, Codesigning) sind so getroffen, dass der erste Code-Stand direkt distribuierbar ist. Scope-Eingrenzungen in diesem Dokument (z.B. "Flutter-UI ist nicht Teil") sind reine Verantwortungs-Abgrenzungen, keine Qualitäts-Kompromisse.

Die Recherche kommt zu folgender Architekturempfehlung: **Dart Hooks (`native_toolchain_rust`)** auf der Build-Seite, **`cbindgen` + `ffigen`** für die FFI-Bindings — ohne `flutter_rust_bridge`. Die Rust-Seite verwendet ein **Aggregator-Crate-Pattern**: Ein einzelner `zanshin-ffi`-Crate (cdylib) re-exportiert die `extern "C"`-API aller internen Crates (`zanshin-jj`, später weitere); Dart Hooks "sehen" nur diesen einen Crate, intern bleibt die Cargo-Workspace-Struktur modular. Der **MCP Server läuft als separates Rust-Binary** (mit `rmcp`), das mit der macOS-App gebündelt wird und denselben `zanshin-jj`-Crate als Library nutzt. **Async wird durch einen Long-Running Worker-Isolate** mit `Isolate.spawn` + Ports erreicht (nicht `Isolate.run` pro Call, da das bei häufigen FFI-Aufrufen Spawn-Overhead aufaddieren würde).

### Key Technical Findings

1. **Dart Hooks sind seit Dart 3.10 production-ready** und können Rust-Code automatisch kompilieren und ins Flutter-Bundle einbinden. Aktueller Stack: Flutter 3.41.9, Dart 3.11.5, Rust 1.95.0.

2. **jj-lib (v0.41.0) ist explizit für externe GUI-Nutzung gedacht**, hat aber keine Stabilitätsgarantien (pre-1.0). Referenz-Implementation [JayJay](https://github.com/hewigovens/jayjay) zeigt erfolgreichen Einsatz mit einem Adapter-Crate-Pattern.

3. **rmcp (v1.7.0) als separates Rust-Binary** — produktionsreif (3.4k Stars, Sampling/Subscriptions/etc.), mit der macOS-App gebündelt und vom MCP-Host (Claude Desktop o.ä.) via stdio gestartet. Teilt sich den `zanshin-jj`-Crate mit dem Flutter-Frontend.

4. **flutter_rust_bridge ist nicht empfehlenswert für dieses Projekt** — Ralph hat negative Erfahrung mit dem Version-Churn-Aufwand. Der `cbindgen`+`ffigen`-Weg ist langfristig wartungsärmer und entkoppelt.

5. **Aggregator-Crate-Pattern + Cargo Workspace** — interne Crates bleiben modular, aber Dart Hooks bauen nur den einen `zanshin-ffi`-Crate (cdylib), der alle internen `extern "C"`-APIs re-exportiert.

6. **Build-Orchestrierung mit `cargo-make`** — alle Build-Schritte (Flutter, Cargo, Bundle-Assembly, Codesign) deklarativ in `Makefile.toml`. Keine versteckte Logik in Xcode-XML. Aufruf: `cargo make build`.

7. **Change-Detection per zweistufiger Watcher-Architektur (komplett in Rust):**
   - **Working-Tree-Änderungen** (externe File-Edits): jj's eingebauter fsmonitor mit Watchman als System-Dependency. Watchman wird per `brew install watchman` (bzw. apt/dnf/Chocolatey) installiert. Zanshin prüft beim Repo-Öffnen Installation und [Config](https://docs.jj-vcs.dev/latest/config/#watchman) und führt durch das Setup. Watchman triggert automatische jj-Snapshots → `op_heads` ändert sich.
   - **`.jj/`-State-Änderungen** (UI-Refresh): `notify-rs` in `zanshin-ffi` beobachtet `.jj/repo/op_heads/heads/` + `.jj/repo/working_copy/checkout` (Empfehlung jj-Maintainer in [#6646](https://github.com/jj-vcs/jj/discussions/6646)) und ruft via `extern "C"`-Callback in den Dart-Worker-Isolate.
   - **Kein IPC** zwischen MCP-Server und Flutter-App nötig — die Filesystem-Mutation ist der Notification-Kanal für alle Quellen (MCP, CLI, andere GUIs, externe Editoren).

8. **Asynchrone Rust→Dart-Signale durchweg via `NativeCallable.listener`** — FFI-Callback-Infrastruktur wird einheitlich verwendet für FS-Watcher-Events UND Progress-Notifications (lang laufende `jj_fetch`/`jj_push`/Diff-Operationen). Eine konsistente Pattern für alle asynchronen Rust→Dart-Signale.

9. **Diff-Rendering der "Delta-Klasse"** — eigener `zanshin-diff`-Crate mit `imara-diff` (Histogram-Algorithmus) für Word-Level-Diff innerhalb geänderter Zeilen, plus `tree-sitter-highlight` für Syntax-Färbung. jj-lib liefert Line-Level-Hunks; `zanshin-diff` reichert sie an. AST-strukturelle Diffs (difftastic-Klasse) bewusst zurückgestellt: kein nutzbares Library-API, bekannte UX-Risiken, Sprachgrammatik-Komplexität.

10. **Commit-Graph-Visualisierung mit Lane-Assignment** — eigener `zanshin-graph`-Crate auf Basis von jj-lib's `default_index` und `dag_walk` (kein direktes `gix-commitgraph`, weil jj's Index Working-Copy-Commits enthält). Algorithmus inspiriert von pvigier's "straight branches"-Ansatz (GitKraken/SourceTree-Stil). Voll-Lane-Cache beim Repo-Open, inkrementelles Update bei op_heads-Change, O(1)-Scrolling. Output: strukturiertes JSON → Flutter Custom-Painter.

### Strategische Empfehlungen

1. **Direkte jj-lib-Integration (kein CLI-Scraping)** — strukturierte Daten kritisch für MCP-Tools und FFI-Wrapper
2. **`zanshin-jj` Adapter-Crate als Anti-Corruption-Layer** — schützt vor pre-1.0 jj-lib-API-Änderungen; wird von Flutter-App UND MCP-Binary geteilt
3. **MCP Server als separates Rust-Binary mit `rmcp`** — produktionsreife API, eigenständig testbar, sauber getrennt von der GUI
4. **Aggregator-Crate (`zanshin-ffi`)** als einziger cdylib-Crate — interne Workspace-Struktur bleibt modular, Dart Hooks bleiben simpel
5. **Sync FFI + Long-Running Worker-Isolate** (manuelles `Isolate.spawn` + Ports) — Worker hält FFI-Handles und empfängt Commands via Port; vermeidet Spawn-Overhead bei häufigen Calls. `Isolate.run` nur für wirklich einmalige Aufgaben (z.B. JSON-Parsing großer Strings)
6. **Generierten Code (ffigen-Output) committen, nicht bei jedem Build neu erzeugen** — reproduzierbare Builds, lesbare Diffs

7. **`cargo-make` als Build-Orchestrator** — alle Schritte (flutter build, cargo build, Bundle-Assembly, Codesign) als deklarative Tasks; kein Build-Code in Xcode versteckt

8. **Filesystem-Watcher statt IPC** — `notify-rs` in `zanshin-ffi` beobachtet `.jj/repo/op_heads/heads/` und ruft Dart-Callbacks; MCP-Server bleibt stateless. Keine Notifications, keine Subscription-Logik, keine Locking-Probleme — die Filesystem-Mutation IST der Notification-Kanal

9. **Watchman als System-Dependency** für reaktive Erkennung externer File-Edits — installiert per `brew/apt/dnf install watchman`. Beim Repo-Öffnen prüft Zanshin Installation und jj-fsmonitor-Konfiguration; Setup-Dialog mit Link auf [jj-Doku](https://docs.jj-vcs.dev/latest/config/#watchman) falls fehlend

10. **Einheitliches FFI-Callback-Pattern** für alle async Rust→Dart-Signale via `NativeCallable.listener` (FS-Watcher + Progress-Notifications für lang laufende Operationen)

11. **Diff-Rendering in separatem `zanshin-diff`-Crate** — `imara-diff` für Word-Level + `tree-sitter-highlight` für Syntax-Färbung. Strukturierte JSON-Daten an UI; AST-Diff-Modus später ohne Architektur-Änderung nachrüstbar

12. **Commit-Graph-Visualisierung in separatem `zanshin-graph`-Crate** — Lane-Assignment-Algorithmus auf jj-lib's `default_index` aufgesetzt; voll-Cache beim Repo-Open für schnelles Random-Scrolling. Kein `gix-commitgraph` — jj's eigener Index enthält auch Working-Copy-Commits und ist konsistent mit allen anderen jj-Pfaden

---

## Inhaltsverzeichnis

1. [Technical Research Scope Confirmation](#technical-research-scope-confirmation)
2. [Technology Stack Analysis](#technology-stack-analysis)
   - Programming Languages (Dart/Flutter, Rust)
   - Development Frameworks (Dart Hooks, native_toolchain_rust, ffigen, cbindgen)
   - JJ-Lib: Die Rust-Kernbibliothek
   - Referenz-Implementierung: JayJay
   - MCP Server SDK-Vergleich (dart_mcp vs. rmcp)
   - Development Tools und Build System
3. [Integration Patterns Analysis](#integration-patterns-analysis)
   - Dart ↔ Rust FFI-Kommunikationsmuster (Worker-Isolate + Ports)
   - Dart Hooks Build-Integration (Aggregator-Crate-Pattern)
   - MCP-Protokoll-Integration (rmcp als separates Binary)
   - Filesystem-Watching (notify-rs + Watchman + FFI-Callbacks)
   - Datenformate und Kommunikationsstandards (C-ABI, JSON, NativeCallable)
4. [Architectural Patterns and Design](#architectural-patterns-and-design)
   - System-Architektur: Schichtenmodell
   - Design-Entscheidung: jj-lib direkt vs. CLI-Scraping
   - Erweiterbarkeit: Cargo Workspace Architektur (5 initiale Crates)
   - Deployment und Build-Architektur (macOS)
5. [Implementation Approaches and Technology Adoption](#implementation-approaches-and-technology-adoption)
   - Konkrete Projektstruktur
   - Umsetzungsschritte (Flutter-Init, Cargo Workspace, FFI, MCP, Build-Orchestrierung)
   - Build-Output: Bundle-Struktur
   - Diff-Rendering: Word-Level mit Syntax-Highlighting (imara-diff + tree-sitter-highlight)
   - Commit-Graph-Visualisierung: Lane-Assignment (zanshin-graph)
   - Testing-Strategie
   - Risikobewertung
6. [Research Methodology and Sources](#research-methodology-and-sources)
7. [Conclusion](#conclusion)

---

## Research Overview

Diese Recherche wurde am 2026-05-15 durchgeführt, basierend auf offiziellen Quellen (dart.dev, pub.dev, crates.io, GitHub-Repositories, JJ-Dokumentation). Versionsstand wurde vom Nutzer verifiziert: Flutter 3.41.9, Dart 3.11.5, Rust 1.95.0. Confidence-Level ist hoch für alle Toolchain-Komponenten (offizielle Pakete), mittel für jj-lib-Stabilitätsfragen (pre-1.0, keine API-Garantien).

Untersuchte Quellen umfassen:
- Dart Hooks Dokumentation und Dart 3.10 Release-Announcement
- pub.dev-Pakete: `native_toolchain_rust`, `ffigen`, `dart_mcp` (evaluiert/verworfen), `watcher` (evaluiert/verworfen)
- crates.io: `jj-lib`, `rmcp`, `imara-diff`, `notify-rs`, `cargo-make`
- GitHub-Repos: `jj-vcs/jj`, `modelcontextprotocol/rust-sdk`, `hewigovens/jayjay`, `notify-rs/notify`, `facebook/watchman`, `pascalkuthe/imara-diff`
- JJ-Architekturdokumentation (docs.jj-vcs.dev) inkl. Working-Copy, Operation-Log, fsmonitor
- Community-Tools-Liste (JJ-Dokumentation)
- jj-vcs/jj#6646 (GUI watcher recommendations vom jj-Maintainer)

---

## Technical Research Scope Confirmation

**Research Topic:** Zanshin – Flutter macOS GUI Client for JJ VCS with Dart Hooks & MCP Server
**Research Goals:** Project scaffolding strategy for integrating JJ (Rust) via Dart Hooks into a Flutter macOS app; MCP Server SDK comparison (dart_mcp vs rust-sdk); extensibility for future Rust crates

**Technical Research Scope:**

- Architecture Analysis - Flutter macOS Desktop, FFI/Hooks bridge to Rust, MCP integration
- Implementation Approaches - Dart Hooks build system, Rust Cargo integration, Dart/Rust FFI
- Technology Stack - Flutter (current stable), Dart Hooks (new!), JJ Rust lib, dart_mcp vs rust-sdk
- Integration Patterns - Dart↔Rust communication, MCP protocol binding
- Performance Considerations - extensibility for future Rust crates

**Research Methodology:**

- Current web data with rigorous source verification
- Multi-source validation for critical technical claims
- Confidence level framework for uncertain information
- Comprehensive technical coverage with architecture-specific insights

**Scope Confirmed:** 2026-05-15

---

## Technology Stack Analysis

### Programming Languages

**Dart / Flutter**
Die UI-Schicht ist Flutter. Für Zanshin gepinnt: **Flutter 3.41.9 / Dart 3.11.5** (vom Nutzer bestätigt, Stand Mai 2026). Dart Build Hooks sind seit Dart 3.10 als stable markiert, somit in 3.11.5 produktionsreif. Flutter macOS Desktop ist vollständig unterstützt. Kein FVM oder Version-Manager — systemweite Installation.
_Source: [Dart Hooks Documentation](https://dart.dev/tools/hooks), [Announcing Dart 3.10](https://dart.dev/blog/announcing-dart-3-10)_

**Rust**
Rust ist die Implementierungssprache von JJ (Jujutsu). Für Zanshin gepinnt: **Rust 1.95.0** (vom Nutzer bestätigt, Stand Mai 2026). `jj-lib` ist der Core-Crate der JJ-VCS-Bibliothek und aktuell auf Version **v0.41.0** (7. Mai 2026). `rustup` managed die Toolchain direkt; `rust-toolchain.toml` pinnt die Version pro Projekt.
_Source: [jj-vcs GitHub](https://github.com/jj-vcs/jj), [jj-lib crates.io](https://crates.io/crates/jj-lib)_

---

### Development Frameworks and Libraries

#### Dart Hooks (Dart Build System Integration)

**Status: Production-ready seit Dart 3.10**

Dart Hooks ermöglichen es, native Code (C, Rust, Swift) während des Build-Prozesses automatisch zu kompilieren und in das Dart-Paket einzubündeln. Die Hooks liegen im `hook/`-Verzeichnis des Pakets und erhalten ein `BuildInput`-Objekt mit Ziel-OS/Architektur-Informationen.

Wichtige Eigenschaften:
- Hooks laufen in Abhängigkeitsreihenfolge, aber parallel zur Dart-Kompilierung
- Hermetische Umgebung: nur erlaubte Umgebungsvariablen (PATH, HOME, Compiler-Pfade) sind zugänglich
- Zyklische Abhängigkeiten zwischen Hook-Paketen nicht unterstützt
- Build-Hooks können Assets nur für ihr eigenes Paket ausgeben

_Source: [Dart Hooks Documentation](https://dart.dev/tools/hooks)_

#### native_toolchain_rust — Rust-Support für Dart Hooks

**Version: 1.0.4** (veröffentlicht 17 Tage vor Recherche)
**Publisher:** gsconrad.com (Community, MIT-Lizenz)

Das Paket ergänzt Dart Hooks um Rust-Unterstützung. Eine minimale `hook/build.dart` instanziiert `RustBuilder` mit dem `assetName`-Parameter. Der Build-Prozess erwartet:
- `Cargo.toml` mit `crate-type = ["staticlib"]` oder `cdylib`
- `rust-toolchain.toml` mit einer gepinnten Rust-Version (keine generischen Channels wie `stable`)

**Einschränkung Multi-Crate:** Die Dokumentation fokussiert auf Single-Crate-Workflows. Explizite Multi-Crate-Unterstützung ist nicht dokumentiert, aber durch Cargo-Workspace-Konfiguration erreichbar.

_Source: [native_toolchain_rust on pub.dev](https://pub.dev/packages/native_toolchain_rust)_

#### ffigen — Offizielle Dart-FFI-Binding-Generierung

**Version: 20.1.1** (Stand Mai 2026)
**Publisher:** tools.dart.dev (offizielles Dart-Team-Paket)
**Status:** Produktionsreif

`ffigen` ist der offizielle Dart-Code-Generator für FFI-Bindings. Er nutzt LibClang, um C-Header zu parsen und daraus typsichere Dart-FFI-Bindings zu erzeugen. Direkt aus der offiziellen Beschreibung: "This bindings generator can be used to call C code or code in another language that compiles to C modules that follow the C calling convention."

Workflow:
1. Konfiguration via Dart-Script mit `FfiGenerator`-Klasse (Header-Pfade, Filter-Regeln)
2. Generierung parst Header via LibClang und gibt Dart-Bindings aus

`ffigen` ist explizit für die Integration mit dem modernen Dart-Native-Workflow ausgelegt (zusammen mit `package:hooks`, `code_assets`, `native_toolchain_c`).

**Einschränkung:** Parst nur C-Header (kein C++).

_Source: [ffigen on pub.dev](https://pub.dev/packages/ffigen)_

---

#### cbindgen — C-Header-Generierung aus Rust (Bridge zu ffigen)

`cbindgen` ist ein Rust-Tool, das aus Rust-Quellcode automatisch C-Header generiert. Damit entsteht die saubere Brücke:

```
Rust (#[no_mangle] extern "C")
   ↓ cbindgen
C Header (.h)
   ↓ ffigen
Dart FFI Bindings (.dart)
```

Konfiguriert über `cbindgen.toml`. Lässt sich als Cargo-Build-Dependency einrichten, sodass der Header bei jedem Rust-Build automatisch aktualisiert wird.

**Warum nicht flutter_rust_bridge:** flutter_rust_bridge generiert direkt Dart-Bindings aus Rust-Code (eigenes Wire-Format), bringt aber bei jedem Update von Rust- *oder* der Bridge selbst Migrationsaufwand mit sich. Der Weg über C-Header (cbindgen → ffigen) nutzt etablierte FFI-Standards: die C-ABI ist seit Jahrzehnten stabil. Updates der einzelnen Tools brechen die Kette nicht, weil das C-Header das gemeinsame Interface ist.

_Source: [cbindgen on rust-ffi-guide](https://github.com/Michael-F-Bryan/rust-ffi-guide/blob/master/book/cbindgen.md)_

---

### JJ-Lib: Die Rust-Kernbibliothek

**Version: 0.41.0** (7. Mai 2026)
**Stabilität: Pre-1.0, keine Stabilitätsgarantien für die öffentliche API**

`jj-lib` ist explizit dafür ausgelegt, von GUIs und TUIs genutzt zu werden — das JJ-Architekturdokument hält fest: "The library crate is currently only used by the CLI crate, but it is meant to also be usable from a GUI or TUI, or in a server serving requests from multiple users."

Wichtige Eigenschaften:
- Die Bibliothek interagiert *nicht* direkt mit Terminal oder Benutzerumgebung — das ist Aufgabe der CLI
- Liest keine Config aus Home-Verzeichnissen oder user-spezifischen Umgebungsvariablen
- Keine offiziellen FFI-Bindings zu anderen Sprachen — reines Rust

Architektur-Kernkomponenten:
- `Backend`-Trait: Abstraktions-Interface für Storage (Git-Backend als einziges produktionsreifes Backend)
- `Store`: Wraps Backend, cached Commits/Trees
- `ReadonlyRepo` / `MutableRepo`: Repository-State zu einem bestimmten Zeitpunkt
- `Transaction`: Atomare Änderungen am Repository-State
- `Workspace`: Kombiniert Repo und Working Copy
- Revset-Evaluation: Multi-Stage-Pipeline für Revision-Ausdrücke

**API-Einschränkung:** Das Architekturdokument gibt offen zu: "A lot of thought has gone into making the library crate's API easy to use, but not much has gone into 'details' such as which collection types are used, or which symbols are exposed in the API."

_Source: [JJ Architecture](https://docs.jj-vcs.dev/latest/technical/architecture/), [jj-lib crates.io](https://crates.io/crates/jj-lib)_

---

### Referenz-Implementierung: JayJay (macOS JJ GUI)

Das Projekt [JayJay](https://github.com/hewigovens/jayjay) ist das bisher einzige öffentlich bekannte native macOS GUI für JJ. Seine Architektur liefert wertvolle Erkenntnisse für Zanshin:

- **Kein CLI-Scraping** — JayJay wrapped `jj-lib` direkt in Rust
- **Cargo Workspace** mit mehreren Crates:
  - `jayjay-core` — Rust-Abstraktion über jj-lib
  - `jayjay-uniffi` — UniFFI-Layer für Swift FFI-Bindings
  - `jj-diff` — Standalone Diff-Engine ohne jj-lib-Dependency (separat publiziert)
- **FFI-Strategie:** UniFFI (Rust→Swift), nicht Dart Hooks

Für Zanshin (Flutter statt SwiftUI) ist der gleiche Rust-Core-Ansatz anzuwenden, aber mit `cbindgen` + `ffigen` über Standard-C-ABI statt UniFFI als FFI-Bridge.

_Source: [JayJay GitHub](https://github.com/hewigovens/jayjay)_

---

### MCP Server SDK-Vergleich

#### dart_mcp (Pub.dev)

**Version: 0.5.1** (veröffentlicht 16 Tage vor Recherche)
**Publisher:** labs.dart.dev (offizielles Dart-Team-Experiment)
**Status: Experimentell — API wird sich noch ändern**

Unterstützte MCP-Funktionen:
- ✅ Tools, Resources, Prompts
- ✅ Logging, Ping, Progress
- ✅ stdio-Transport
- ✅ Protokoll-Versionen: 2024-11-05 / 2025-03-26 / 2025-06-18 / 2025-11-25
- ❌ Streamable HTTP (noch nicht implementiert)
- ❌ Cancellation (offenes GitHub-Issue)
- ❌ Pagination (in Arbeit)
- ❌ Authorization (explizit nicht unterstützt — nur für lokale MCP-Nutzung ausgelegt)
- ❌ Batch-Request-Erstellung

Architektur: Mixin-basiert — für jede MCP-Capability gibt es ein entsprechendes Mixin (`ToolsSupport`, `ResourcesSupport`, etc.). Aufgebaut auf `json_rpc_2`, `stream_channel`.

_Source: [dart_mcp on pub.dev](https://pub.dev/packages/dart_mcp)_

---

#### rmcp — Offizielles Rust MCP SDK

**Version: rmcp v1.7.0** (13. Mai 2026)
**Status: Produktionsreif** — 3.400 GitHub Stars, 518 Forks
**Crate:** `rmcp` auf crates.io

Unterstützte MCP-Funktionen:
- ✅ Tools (mit `#[tool]`-Makros, JSON Schema via `schemars`)
- ✅ Resources (URI-basiert, Subscription-Support)
- ✅ Prompts
- ✅ Sampling (Server-initiierte LLM-Aufrufe)
- ✅ Logging, Completions, Tasks
- ✅ Roots, Notifications, Subscriptions
- ✅ stdio-Transport
- Async-Runtime: **tokio** (Pflicht)
- Output: Einzelne statische Binary, keine Runtime-Dependencies

Produktionsnutzer: goose, apollo-mcp-server, containerd-mcp-server.

_Source: [rust-sdk GitHub](https://github.com/modelcontextprotocol/rust-sdk), [rmcp docs.rs](https://docs.rs/rmcp)_

---

#### Direktvergleich dart_mcp vs. rmcp

| Kriterium | dart_mcp (v0.5.1) | rmcp (v1.7.0) |
|---|---|---|
| Stabilität | Experimentell | Produktionsreif |
| MCP-Features | Tools, Resources, Prompts (Kern) | Vollständig inkl. Sampling, Tasks, Subscriptions |
| stdio | ✅ | ✅ |
| HTTP/SSE | ❌ | Erweitert möglich |
| Authorization | ❌ | — |
| Sprache | Dart (im Flutter-Prozess) | Rust (separater Prozess oder FFI) |
| Deployment | Eingebettet in Flutter-App | Standalone Binary oder Rust-FFI |
| Dev-Komfort für Ralph | ✅ Dart bekannt | ⚠️ Rust weniger bekannt |
| Reifegrad API | API ändert sich noch | v1.x stabil (Migration Guide vorhanden) |

**Empfehlung für Zanshin: `rmcp` als separates Rust-Binary**

Die finale Entscheidung fällt zugunsten von `rmcp`. Begründung:

1. **Produktionsreife:** rmcp v1.7.0 ist stabil und wird in Production eingesetzt (goose, apollo-mcp-server, containerd-mcp-server). dart_mcp v0.5.1 ist experimentell und die API ändert sich noch.

2. **Vollständiger MCP-Feature-Set:** rmcp implementiert das gesamte MCP-Protokoll inklusive Sampling, Subscriptions, Tasks, Completions und Roots; dart_mcp fehlen mehrere davon. Wir bauen auf einer vollständigen, produktionsreifen API ohne Feature-Lücken.

3. **Direkter jj-lib-Zugriff:** Der MCP-Server nutzt `zanshin-jj` direkt als Rust-Crate, ohne FFI-Layer dazwischen. Performanter und debugbarer als der Umweg über Dart.

4. **Saubere Trennung:** Flutter-App = GUI; `zanshin-mcp` = MCP-Server. Beide sind unabhängig entwickel- und testbar. MCP-Server lässt sich ohne Flutter-Setup mit `cargo run -p zanshin-mcp` starten — wichtig für CI und schnelle Iteration.

5. **MCP-Server-Pattern ist von Natur aus Subprocess-basiert:** Die meisten MCP-Hosts (Claude Desktop, Cursor) spawnen den MCP-Server ohnehin als Subprocess via stdio. Eine separate Binary ist also der natürlichere Architekturansatz, nicht der unnatürliche.

6. **Single Binary, keine Runtime-Dependencies:** rmcp kompiliert zu einer statischen Binary — wird einfach mit der macOS-App in `Contents/MacOS/zanshin-mcp` gebündelt.

**Trade-off:** Mehr Rust-Code im Projekt — aber durch Cargo Workspace organisiert und mit klarer Verantwortung. Ralph's Dart/Flutter-Fokus bleibt auf der GUI; die Rust-Seite ist durch den `zanshin-jj`-Crate für beide Konsumenten (Flutter-FFI und MCP-Binary) bereits notwendig.

---

### Development Tools und Build System

**Flutter macOS Desktop**
- Flutter Desktop für macOS ist produktionsreif und voll unterstützt
- Kein FVM oder Version-Manager nötig — systemweites Flutter reicht
- `flutter build macos` für Release-Builds

**Cargo Workspace**
Für die Rust-Seite nutzen wir einen Cargo Workspace im Projekt-Root. Das ermöglicht:
- Mehrere Rust-Crates in einem Workspace mit klarer Verantwortungstrennung
- Geteilte Dependencies über `[workspace.dependencies]`
- Ein gemeinsames `target/`-Verzeichnis (schnellere Builds, einheitliche Feature-Auflösung)

Die finale Workspace-Struktur (siehe ausführliche Projektstruktur weiter unten) hat fünf initiale Crates: `zanshin-jj`, `zanshin-diff`, `zanshin-graph`, `zanshin-ffi`, `zanshin-mcp`.

_Source: [native_toolchain_rust on pub.dev](https://pub.dev/packages/native_toolchain_rust), [ffigen on pub.dev](https://pub.dev/packages/ffigen), [Cargo Workspaces](https://doc.rust-lang.org/book/ch14-03-cargo-workspaces.html)_

---

## Integration Patterns Analysis

### Dart ↔ Rust: FFI-Kommunikationsmuster (ohne flutter_rust_bridge)

Der gewählte Weg: **cbindgen + ffigen** über C-Header — schlanker und weniger version-empfindlich als flutter_rust_bridge, weil die drei Tools voneinander entkoppelt sind und die C-ABI als stabile Boundary dient.

**Bindings-Toolchain:**
```
Rust (#[no_mangle] extern "C" in zanshin-ffi)
   ↓ cargo build + cbindgen (in build.rs)
C Header (zanshin_ffi.h)
   ↓ dart run tool/ffigen.dart
Dart FFI Bindings (lib/src/native/bindings.g.dart)
   ↓ hand-geschriebene Dart-Facade
Application Layer (jj_facade.dart)
```

Der generierte Dart-Code wird ins Repo committed (reproduzierbare Builds, lesbare Diffs). Neu generiert wird nur, wenn sich die `extern "C"`-API ändert.

**Rust-Seite (`extern "C"`-API in `zanshin-ffi`):**
Jede aus Dart aufrufbare Funktion wird als `#[no_mangle] pub extern "C"` im `zanshin-ffi`-Crate exponiert. Dieser Aggregator-Crate ruft intern Funktionen aus `zanshin-jj` (und später weiteren internen Crates) auf. Komplexe Rust-Typen werden auf C-kompatible Repräsentationen abgebildet — Opaque-Pointer für Handles, primitive Werte für einfache Daten, JSON-kodierte Strings für komplexe Strukturen (Commits, Diffs).

**Geschätzter Umfang:** ~30–45 `extern "C"`-Funktionen für einen vollwertigen GUI-Client. cbindgen+ffigen erzeugt daraus die mechanischen Dart-Bindings automatisch.

**Memory Management:** Wenn Rust allokierten Speicher zurückgibt (z.B. Strings, Vecs), muss eine korrespondierende `free_xyz`-Funktion exportiert werden, die Dart nach Nutzung aufruft. Pattern: Jedes `*mut T` aus Rust hat eine `extern "C" fn free_T(ptr: *mut T)`.

**Async-Strategie (kritisch für UI-Responsiveness):**

Da `dart:ffi`-Aufrufe synchron sind und jj-lib-Operationen (Clone, Fetch, große Diffs) blockieren können, ist Isolate-basierte Ausführung Pflicht. Zwei Patterns stehen zur Auswahl:

**Option A: `Isolate.run` pro Aufruf (NICHT empfohlen für FFI-Calls)**
- Jeder FFI-Call spawnt einen frischen Isolate, der nach dem Call zerstört wird
- Spawn-Overhead: 2-4 MB Memory + Spawn-Time (zehntel ms bis ms, in Edge-Cases Sekunden)
- Daten zwischen Isolates werden **kopiert**, nicht geteilt
- Bei häufigen Calls (dutzende pro User-Session) spürbare Latenz und Memory-Churn
- Vom Dart-Team explizit als ungeeignet für "repeatedly running the same computation" markiert

**Option B: Long-Running Worker Isolate mit Ports (empfohlen)**

Ein dedizierter Worker-Isolate, der einmal beim App-Start gespawnt wird und für die gesamte App-Lifetime aktiv bleibt:

```
┌─────────────────────────────────────────┐
│  Main Isolate (UI Thread)                │
│  - Flutter Widgets, State-Mgmt           │
│  - sendPort.send({op: 'jj_log', ...})    │
│  - listens auf ReceivePort für Results   │
└──────────────┬──────────────────────────┘
               │ SendPort / ReceivePort
               │ (Message-Passing, kein Spawn-Overhead)
               ▼
┌─────────────────────────────────────────┐
│  jj Worker Isolate (long-lived)          │
│  - hält Repository-Handle (FFI-Pointer)  │
│  - empfängt Commands via Port            │
│  - ruft zanshin-ffi.dylib auf (sync)     │
│  - sendet Results via SendPort zurück    │
│  - leitet Rust→Dart Progress-Callbacks   │
│    (NativeCallable.listener) weiter      │
└──────────────┬──────────────────────────┘
               │ dart:ffi (sync calls)
               ▼
       zanshin-ffi.dylib
              ↓
        zanshin-jj → jj-lib
```

**Vorteile:**
- Spawn-Overhead nur einmal beim App-Start
- Subsequent calls: nur Message-Passing-Overhead (Mikrosekunden)
- FFI-Handles (Repo-Pointer, etc.) bleiben im Worker — kein Re-Open pro Call
- NativeCallable-Listener leben im Worker, leiten Rust-Callbacks an Main weiter

**Implementations-Optionen:**

| Variante | Pro | Contra |
|---|---|---|
| **Manuell `Isolate.spawn` + Ports** | Keine Dependency, voller Kontrolle, einfaches Mental-Modell | Etwas Boilerplate für Setup und Message-Routing |
| `isolate_manager` v6.3.2 (~18k downloads) | Worker-Pool, Type-Safety, Queue, Web-Support | Externe Dependency, Web/WASM-Features irrelevant für uns, Overengineered für einen einzigen Worker |

**Entscheidung: Manuell `Isolate.spawn` + Ports.** Wir brauchen nur einen einzigen Worker (jj-Repo ist single-threaded sinnvoll), die Patterns sind in der Dart-Doku gut dokumentiert, keine zusätzliche Dependency.

`Isolate.run` bleibt nützlich für wirklich einmalige Operationen (z.B. JSON-Parsing eines großen Diff-Strings), aber **nicht als Default für FFI-Calls**.

_Source: [Dart Isolates Documentation](https://dart.dev/language/isolates), [Flutter Concurrency and Isolates](https://docs.flutter.dev/perf/isolates), [Better isolate management with Isolate.run() (Dart Blog)](https://dart.dev/blog/better-isolate-management-with-isolate-run), [isolate_manager on pub.dev](https://pub.dev/packages/isolate_manager)_

_Source: [Dart FFI Documentation](https://dart.dev/interop/c-interop), [Using Dart FFI to access native libraries](https://blog.logrocket.com/dart-ffi-native-libraries-flutter/)_

---

### Dart Hooks Build-Integration: Aggregator-Crate-Pattern

Die Integration von `native_toolchain_rust` in Dart Hooks funktioniert über eine `hook/build.dart`-Datei. Für Zanshin gilt der **Aggregator-Crate-Pattern**: Dart Hooks kompilieren **genau einen** Crate (`zanshin-ffi`), der intern alle anderen Workspace-Crates aufruft. Damit bleibt der Hook auch bei zukünftigen Workspace-Erweiterungen unverändert.

**Dart-Hook-Seite (`hook/build.dart`):**

```dart
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await RustBuilder(
      assetName: 'src/native/bindings.g.dart',
    ).run(input: input, output: output);
  });
}
```

Genau ein `RustBuilder` — zeigt auf `zanshin-ffi`. Der Workspace selbst kann beliebig wachsen, ohne dass der Hook angepasst werden muss.

**Cargo-Workspace-Seite (`rust/Cargo.toml`):**
Workspace-Root mit `[workspace]`-Sektion definiert alle Member-Crates. Alle teilen sich `target/` und `Cargo.lock`. `zanshin-ffi` ist als einziger Member ein `cdylib` (kompiliert zur `.dylib`); alle anderen sind plain `lib`-Crates und werden über Cargo-Dependencies in `zanshin-ffi` und/oder `zanshin-mcp` referenziert.

Erweiterbarkeit für zukünftige Rust-Crates (z.B. `zanshin-crypto`):
1. Neuen Crate im `rust/`-Verzeichnis anlegen (`crate-type = ["lib"]`)
2. In `rust/Cargo.toml` unter `[workspace] members` eintragen
3. In `zanshin-ffi/Cargo.toml` als Dependency hinzufügen
4. In `zanshin-ffi/src/lib.rs` neue `extern "C"`-Funktionen exponieren, die in den neuen Crate delegieren
5. `cargo build` aktualisiert den C-Header automatisch (cbindgen via build.rs), dann einmal `dart run tool/ffigen.dart`

**Hook-Datei wird dabei nicht angefasst.**

**Einschränkung:** `native_toolchain_rust` erwartet `rust-toolchain.toml` mit gepinnter Version (kein `stable` Channel). Bei einem Workspace gilt diese Datei global für alle Member-Crates.

_Source: [native_toolchain_rust on pub.dev](https://pub.dev/packages/native_toolchain_rust), [Cargo Workspaces](https://doc.rust-lang.org/book/ch14-03-cargo-workspaces.html)_

---

### MCP-Protokoll: Integration als separates Rust-Binary

**MCP Stdio-Transport (lokales Modell)**

MCP nutzt JSON-RPC 2.0 über stdio: Der MCP-Host (Claude Desktop, Cursor o.ä.) startet `zanshin-mcp` als Subprocess und kommuniziert über stdin/stdout. `rmcp` implementiert dieses Transport-Protokoll nativ.

Die drei MCP-Primitives für Zanshin:
- **Tools:** Ausführbare Operationen (z.B. `jj_log`, `jj_diff`, `jj_commit`, `jj_new`, `jj_status`) — in rmcp über `#[tool]`-Makros annotiert
- **Resources:** Datenzugriff (z.B. Repository-Status, Commit-Graph als strukturierte Daten) — URI-basiert mit Subscription-Support
- **Prompts:** Wiederverwendbare Templates (z.B. Commit-Message-Vorschläge, Diff-Zusammenfassungen)

Integrationsarchitektur:
```
AI Host (Claude Desktop, Cursor, etc.)
    ↓ JSON-RPC over stdio (Subprocess-Spawn)
zanshin-mcp Binary (Rust + rmcp + tokio)
    ↓ direkter Rust function call
zanshin-jj (Anti-Corruption-Layer)
    ↓ Rust API call
jj-lib
```

Vorteile dieser Architektur:
- Keine FFI-Boundary für den MCP-Pfad (höhere Performance, einfacheres Debugging)
- MCP-Server-Logik in Rust testbar ohne Flutter-Setup (`cargo test -p zanshin-mcp`)
- Eigenständige Wiederverwendung möglich (z.B. zanshin-mcp ohne Zanshin-GUI nutzen)

_Source: [MCP Architecture](https://modelcontextprotocol.io/docs/learn/architecture), [rmcp on docs.rs](https://docs.rs/rmcp), [MCP Transports](https://www.speakeasy.com/mcp/core-concepts/transports)_

---

### Filesystem-Watching: Change-Detection ohne IPC

**Designprinzip:** MCP-Server und Flutter-App brauchen **keinen** direkten IPC-Kanal. Jede Mutation läuft über jj-lib, jj-lib persistiert sie sofort im `.jj/`-Verzeichnis. `zanshin-ffi` beobachtet `.jj/` mit einem Filesystem-Watcher (notify-rs) und ruft Dart-Callbacks — und damit reagiert die UI auf jede Änderung, egal von welchem Prozess die Mutation kommt.

**jj's Auto-Snapshot-Verhalten (Grundlage für die Working-Tree-Strategie):**

Anders als Git macht jj bei *jedem* Befehl automatisch einen Snapshot des Working-Trees:
> "Unlike most other VCSs, Jujutsu will automatically create commits from the working-copy contents when they have changed. Most jj commands will commit the working-copy changes if they have changed."

Bedeutet konkret:
- Neue Dateien (nicht in `.gitignore`) werden **automatisch getrackt** durch `snapshot.auto-track`-Default
- Jeder jj-Befehl (auch read-only wie `jj log`, `jj status`) snapshottet zuerst
- Jeder Snapshot erzeugt eine Operation → `op_heads/heads/` ändert sich

**Konsequenz für unsere Architektur:** Wir bauen **keinen eigenen Working-Tree-Watcher** in Zanshin — diese Aufgabe übernimmt Watchman in Verbindung mit jj's fsmonitor (siehe unten). Ohne Watchman würden externe File-Edits erst sichtbar werden, wenn ein jj-Befehl läuft (App-Open, Refresh, MCP-Tool-Aufruf); mit Watchman + `register-snapshot-trigger = true` triggert Watchman selbst asynchron jj-Snapshots, sobald sich Working-Tree-Dateien ändern.

**Was wir wo beobachten:**

Bestätigt durch jj-Maintainer-Empfehlung in [jj-vcs/jj#6646](https://github.com/jj-vcs/jj/discussions/6646): beide unten genannten `.jj/`-Pfade sind zuverlässige Watcher-Targets.

| Pfad | Wann ändert sich's | Watcher-Rolle |
|---|---|---|
| `.jj/repo/op_heads/heads/` | Bei jeder *echten* Repo-Mutation (neue Operation) | **Primärer Watcher** (notify-rs) — bei Event: UI-State aus jj-lib neu laden |
| `.jj/repo/working_copy/checkout` | Bei **jeder** jj-Aktivität (auch read-only Operations) — laut martinvonz: "We update that even if the working copy doesn't change" | **Sekundärer Watcher** (notify-rs) — "jj war aktiv"-Heartbeat; macht uns gegen stale-state robuster (z.B. wenn andere GUI/CLI parallel läuft) |
| `.jj/repo/op_store/operations/` | Append-only Operation-Historie | Nicht beobachten — bei Bedarf gemeinsam mit op_heads-Update lesen |
| Working-Tree-Dateien | User-Edits außerhalb von jj | **Nicht direkt von uns beobachtet** — Watchman + jj fsmonitor triggert die jj-Snapshots; die resultierende Op-Mutation feuert dann unseren `op_heads`-Watcher |

**Externe Edits: jj's fsmonitor mit Watchman ist Voraussetzung**

Wenn ein User Dateien im Editor außerhalb von Zanshin ändert, gibt es ohne fsmonitor keinen Trigger für eine neue jj-Operation — `op_heads` und `working_copy/checkout` würden erst beim nächsten jj-Befehl feuern. Für eine reaktive UI ist das nicht akzeptabel.

**Lösung:** jj's eingebauter fsmonitor mit Watchman-Backend wird beim Repo-Öffnen verifiziert und falls nötig konfiguriert.

Setup-Check beim Repo-Öffnen (sequenziell):

1. **Ist Watchman installiert?** — z.B. via `which watchman` oder direkt über jj-lib (oder shell-out auf `jj debug watchman status`).
2. **Ist jj's fsmonitor aktiviert?** — `.jj/repo/config.toml` (oder die globale jj-Config) prüfen auf:
   ```toml
   [fsmonitor]
   backend = "watchman"

   [fsmonitor.watchman]
   register-snapshot-trigger = true
   ```
3. **Wenn beides OK:** Repo normal öffnen. Externe File-Edits triggern automatisch Watchman → jj erzeugt Snapshot → `op_heads/heads/` ändert sich → notify-rs in `zanshin-ffi` feuert FFI-Callback → Worker-Isolate → UI lädt neu.
4. **Wenn Watchman fehlt:** klare Anweisung in der UI mit Link auf [jj fsmonitor docs](https://docs.jj-vcs.dev/latest/config/#watchman) und passende Install-Befehle pro Plattform:
   - macOS: `brew install watchman`
   - Linux: `apt install watchman` / `dnf install watchman` / etc.
   - Windows: per [Chocolatey](https://chocolatey.org/) oder Build-from-Source
5. **Wenn Watchman da, aber Config fehlt:** Zanshin bietet an, die Config automatisch in `.jj/repo/config.toml` zu setzen (mit User-Bestätigung — Config-Files anfassen ist sensibel).

**Begründung gegen Bundling (gegen frühere Überlegung):**
- Facebook publiziert seit [Issue #1199](https://github.com/facebook/watchman/issues/1199) **keine macOS-Prebuilt-Binaries mehr** — wir müssten selbst aus Source bauen
- Watchman ist als **per-user Single-Daemon** designed: zwei Instanzen in unterschiedlichen Dirs **terminieren sich gegenseitig** ([Issue #558](https://github.com/facebook/watchman/issues/558)). Konflikt mit System-Watchman des Users wäre normal, nicht Edge-Case
- Bundled Binaries müssten separat codesigned werden — Apple-Notarization-Pfad mit MIT-lizenziertem Watchman ist nicht trivial
- Bekannte Socket-Pfad-Längen-Bugs bei längeren Bundle-Pfaden

**Begründung gegen ein selbstgebautes Working-Tree-Watching in Rust:**
- Würde jj-lib's Snapshot-Trigger-Logik duplizieren (`.gitignore`-Filtering, Conflict-Detection, Snapshot-Trigger-Registrierung)
- jj's Watchman-Integration handhabt diese Edge-Cases bereits korrekt
- Eine eigene Lösung wäre pure Reimplementation ohne Mehrwert

**Wichtige Abgrenzung:** Wir nutzen `notify-rs` separat (siehe nächster Abschnitt), aber **nicht zum Snapshot-Triggering** — sondern um `.jj/repo/op_heads/heads/` und `.jj/repo/working_copy/checkout` zu beobachten und Änderungen an die Flutter-App weiterzuleiten. Die zwei Watcher-Layer haben unterschiedliche Verantwortung:

| Layer | Tool | Watches | Triggert |
|---|---|---|---|
| Working-Tree-Watcher | Watchman + jj fsmonitor (System) | Project-Working-Tree-Dateien | jj-`snapshot()` → neue Op |
| State-Change-Watcher | `notify-rs` in `zanshin-ffi` | `.jj/repo/op_heads/heads/` + `working_copy/checkout` | FFI-Callback → Dart-UI-Refresh |

**Tool-Auswahl: notify-rs in Rust via FFI-Callbacks (Production-Entscheidung)**

Untersucht wurden zwei Optionen:

| Aspekt | Dart `watcher` v1.2.1 | Rust `notify` (notify-rs) — **gewählt** |
|---|---|---|
| Konsistenz / Mental-Modell | ❌ FS-Watching teilt sich auf Rust (Watchman→jj) und Dart auf | ✅ alle FS-Notifications kommen aus Rust |
| Implementation-Komplexität (Setup) | niedrig | mittel (FFI-API + `NativeCallable.listener`) |
| Plattform-Backends | FSEvents (macOS), inotify+polyfill (Linux), RDCW (Windows) | FSEvents/**kqueue** (macOS), inotify (Linux), RDCW (Windows), polling fallback |
| Reife / Adoption | Solide (~9,4M downloads, tools.dart.dev) | **Sehr hoch** (Deno, Rust-Analyzer, Cargo Watch, Zed) |
| Debouncer | basic eingebaut | `notify-debouncer-mini`/`-full` (ausgereifter) |
| Wiederverwendbarkeit FFI-Callback-Infrastruktur | — | ✅ identisches Pattern für Progress-Notifications |
| Lifecycle (Watcher an Repo gebunden) | ❌ Dart muss Repo-Open/Close mit Watcher-Start/Stop synchronisieren | ✅ Watcher kann direkt am Rust-`Repository`-Handle hängen |
| Testbarkeit | Dart-Tests | Rust-`cargo test` — schneller, deterministischer |

**Entscheidung: notify-rs in `zanshin-ffi` via FFI-Callbacks.**

Begründung:
- **Konsistenz:** Alle async Rust→Dart-Signale (Watcher-Events, Progress-Updates für lange Operationen wie fetch/push/Diff) gehen durch denselben Pattern (`NativeCallable.listener`). Kein gespaltenes Mental-Modell.
- **Wiederverwendung der FFI-Callback-Infrastruktur:** Da Progress-Notifications für lang laufende Operationen ohnehin geplant sind, brauchen wir `NativeCallable.listener` so oder so. Die Watcher-Integration kommt damit ohne Zusatzkosten.
- **Lifecycle:** Watcher wird mit `Repository::open` zusammen erzeugt und mit dem Repo-Handle gemeinsam aufgeräumt — kein doppeltes Lifecycle-Management auf Dart-Seite.
- **Bessere Debouncing-Tools** durch `notify-debouncer-mini` falls nötig.

API-Pattern:

```rust
// Rust: zanshin-ffi/src/watcher.rs

#[no_mangle]
pub extern "C" fn zanshin_watch_repo(
    repo_path: *const c_char,
    on_event: extern "C" fn(EventKind, *const c_char),
) -> *mut RepoWatcher {
    // notify-rs RecommendedWatcher hinter den Pfaden .jj/op_heads/heads
    // und .jj/working_copy/checkout aufsetzen
    // bei Event: on_event(kind, path) aufrufen
}

#[no_mangle]
pub extern "C" fn zanshin_stop_watcher(watcher: *mut RepoWatcher) { ... }
```

```dart
// Dart: lib/src/native/jj_worker.dart (im Worker Isolate)

final eventCallback = NativeCallable<Void Function(Int32, Pointer<Utf8>)>
  .listener((kindCode, pathPtr) {
    final event = WatchEvent(kindCode, pathPtr.toDartString());
    sendPortToUi.send(event);  // an Main-Isolate weiterreichen
  });

final watcher = bindings.zanshin_watch_repo(
  repoPath.toNativeUtf8(),
  eventCallback.nativeFunction,
);

// Bei Dispose: bindings.zanshin_stop_watcher(watcher); eventCallback.close();
```

**Architektur-Konsequenz:**

```
┌──────────────────────────────────────────────────────────────┐
│  Flutter App (Dart)                                           │
│                                                               │
│  Main Isolate (UI)                                            │
│   ▲                                                            │
│   │ Stream via SendPort                                        │
│   │                                                            │
│  Worker Isolate                                                │
│   - NativeCallable.listener(on_event)                          │
│   - bei Callback: SendPort.send(event) → UI                    │
└──────────────────────────────────────────────────────────────┘
              ▲
              │ FFI-Callback (NativeCallable)
              │
┌──────────────────────────────────────────────────────────────┐
│  zanshin-ffi.dylib (Rust)                                     │
│  ┌────────────────────────────────────────────────────────┐   │
│  │  notify-rs RepoWatcher                                  │   │
│  │  - watches .jj/repo/op_heads/heads/                     │   │
│  │  - watches .jj/repo/working_copy/checkout               │   │
│  │  - bei FS-Event: ruft Dart-Callback via extern "C"      │   │
│  └────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
              ▲                                ▲
              │ FS event                       │ FS event
              │                                │
┌─────────────┴────────────┐    ┌──────────────┴───────────────┐
│  Watchman + jj fsmonitor │    │  zanshin-mcp (Rust)          │
│  - User editiert Datei   │    │  - Tool call                 │
│  - Watchman triggert     │    │  - jj-lib → neue Op          │
│    jj-Snapshot           │    │                              │
│  - neue Op → op_heads    │    │  user@cli, andere GUIs, etc. │
└──────────────────────────┘    └──────────────────────────────┘
```

Die FFI-Callback-Infrastruktur (`NativeCallable.listener` im Worker-Isolate, `extern "C"` callback-Parameter im Rust-API) wird für **alle** asynchronen Rust→Dart-Signale wiederverwendet:
- FS-Watcher-Events (dieser Abschnitt)
- Progress-Updates für lang laufende Operationen (`jj_fetch`, `jj_push`, große Diffs, op-log walks)

Vorteile:
- Funktioniert für **alle** Mutations-Quellen (MCP, CLI, andere GUIs, Editoren via jj)
- Kein Inter-Process-Locking
- Saubere Lifecycle-Trennung: MCP-Server läuft nur wenn AI-Host ihn spawnt; Flutter-App eigenständig
- Plattform-übergreifend identische Logik (`notify-rs` abstrahiert OS-Backends: FSEvents/inotify/RDCW)
- Keine Notification-Subscription-Mechanik im MCP-Protokoll nötig

_Source: [notify-rs GitHub](https://github.com/notify-rs/notify), [JJ Architecture](https://docs.jj-vcs.dev/latest/technical/architecture/), [JJ Working Copy](https://docs.jj-vcs.dev/latest/working-copy/), [JJ Operation Log](https://docs.jj-vcs.dev/latest/operation-log/), [JJ fsmonitor / Watchman config](https://docs.jj-vcs.dev/latest/config/#watchman), [Watchman macOS binary issue #1199](https://github.com/facebook/watchman/issues/1199), [Watchman daemon-conflict issue #558](https://github.com/facebook/watchman/issues/558)_

---

### Datenformate und Kommunikationsstandards

**Dart ↔ Rust (intern, über C-ABI):**
- Primitive Werte werden direkt durch die C-ABI getransferiert (Int, Bool, Pointer)
- Strings: UTF-8-`*mut c_char`-Pointer von Rust, in Dart per `Pointer<Utf8>.toDartString()` gelesen, anschließend via `free_string`-Aufruf freigegeben
- Komplexe Typen (Commits, Diffs, Status-Snapshots): als **JSON-Strings** über die FFI-Grenze. Rust serialisiert via `serde_json`, Dart parst mit `jsonDecode` und mappt in idiomatische Dart-Klassen
- Opaque-Handles: `*mut RepoHandle`, `*mut WatcherHandle` etc. — als undurchsichtige Pointer, Lifetime via `Finalizer<Pointer>` auf Dart-Seite
- Asynchrone Signale: via `extern "C" fn`-Callback-Pointer (Dart-seitig `NativeCallable.listener`)

**MCP (extern):**
- JSON-RPC 2.0 über stdio
- rmcp serialisiert JSON-Schemas für Tool-Parameter automatisch aus Rust-Typen via `schemars`
- MCP-Protokoll-Versionen: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25 (von rmcp unterstützt)

_Source: [Dart FFI / C-Interop](https://dart.dev/interop/c-interop), [ffigen on pub.dev](https://pub.dev/packages/ffigen), [rmcp on docs.rs](https://docs.rs/rmcp)_

---

## Architectural Patterns and Design

### System-Architektur: Schichtenmodell für Zanshin

Aus den Referenz-Projekten (JayJay, AppFlowy, RustDesk) und den Recherche-Ergebnissen ergibt sich folgendes bewährtes Schichten-Muster für Flutter+Rust Desktop-Apps:

```
┌─────────────────────────────────┐    ┌────────────────────────────┐
│  Flutter App (Zanshin GUI)       │    │  zanshin-mcp (Rust Binary)  │
│                                  │    │                             │
│  Presentation (Flutter/Dart)     │    │  MCP Server (rmcp v1.7.0)   │
│  - Widgets, State Mgmt           │    │  - stdio transport          │
│  - macOS UI                      │    │  - Tools / Resources /      │
│                                  │    │    Prompts via #[tool]      │
│  Application (Dart)              │    │                             │
│  - Use Cases, Repositories       │    │  Spawned by MCP host        │
│  - Isolate-Scheduler für FFI     │    │  (Claude Desktop, Cursor)   │
│                                  │    │  via stdio                  │
│  FFI Binding Layer (Dart)        │    │                             │
│  - ffigen-Bindings (.g.dart)     │    │                             │
│  - dart:ffi Aufrufe              │    │                             │
└────────────┬─────────────────────┘    └─────────────┬──────────────┘
             │                                        │
             ▼                                        │
┌────────────────────────────────────┐                │
│  zanshin-ffi (Aggregator cdylib)    │                │
│  - extern "C" API für Dart          │                │
│  - cbindgen → C Header              │                │
│  - dünner Re-Export aller internen  │                │
│    Crate-Funktionen                 │                │
└────────────┬───────────────────────┘                │
             │                                         │
             ▼                                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  Cargo Workspace: Interne Rust-Crates (plain lib, kein cdylib)    │
│                                                                   │
│  zanshin-jj (jj-lib Wrapper / Anti-Corruption-Layer)              │
│   - Idiomatische Rust-API über jj-lib                             │
│   - Geteilt von zanshin-ffi UND zanshin-mcp                       │
│                                                                   │
│  # zukünftige Crates: zanshin-crypto, zanshin-net, …              │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│  jj-lib (externe Rust-Dependency, v0.41.0)                        │
│  - Backend Trait, Store, ReadonlyRepo/MutableRepo, Workspace,     │
│    Transaction, Revset-Evaluation, Git-Backend                    │
└──────────────────────────────────────────────────────────────────┘
```

**Schlüssel-Eigenschaften dieses Modells:**

- `zanshin-jj` wird von **beiden Konsumenten geteilt** (Flutter-FFI und MCP-Binary)
- `zanshin-ffi` ist der **einzige cdylib-Crate** — Dart Hooks bauen nur diesen
- `zanshin-mcp` ist eine **separate Binary** mit eigenem `main.rs`
- Interne Crates (`zanshin-jj`, zukünftige) sind **plain Rust libraries** — kein FFI-Overhead intern

Dieses Modell kombiniert **Flutter Clean Architecture** (Presentation → Application → Domain) mit dem Flutter+Rust-Pattern, wobei die Rust-Schicht die "Domain/Infrastructure"-Rolle übernimmt.

_Source: [Clean Architecture in Flutter 2026](https://dev.to/techwithsam/clean-architecture-in-flutter-2026-practical-implementation-guide-1dfb), [Flutter architectural overview](https://docs.flutter.dev/resources/architectural-overview)_

---

### Design-Entscheidung: Direkte jj-lib-Nutzung vs. CLI-Scraping

**Wichtig:** Die JJ-Community-Tools zeigen zwei Integrationsstrategien:
1. **CLI-Scraping** (GG, LazyJJ, LightJJ) — einfacher Start, aber fragil bei JJ-Updates
2. **Direkte jj-lib-Integration** (JayJay, JK Kaizen, Selvejj) — stabiler, aber mehr Aufwand

**Empfehlung für Zanshin: Direkte jj-lib-Integration** (wie JayJay), aus folgenden Gründen:
- CLI-Output-Format kann sich ändern; jj-lib-API bleibt strukturell stabiler
- MCP-Server-Tools brauchen strukturierte Daten, nicht Text-Parsing
- Für einen MCP-Server ist maschinenlesbare Ausgabe kritisch

**Risiko:** jj-lib ist pre-1.0, API kann sich ändern. Mitigierung: Eigener `zanshin-jj`-Wrapper-Crate als Adapter-Schicht zwischen jj-lib und seinen beiden Konsumenten (`zanshin-ffi` für die Flutter-App, `zanshin-mcp` für den MCP-Server). So sind Breaking Changes in jj-lib auf diesen einen Crate beschränkt.

_Source: [JJ Community Tools](https://docs.jj-vcs.dev/latest/community_tools/), [JayJay GitHub](https://github.com/hewigovens/jayjay)_

---

### Erweiterbarkeit: Cargo Workspace Architektur

Die Cargo-Workspace-Struktur ist das Schlüsselelement für zukünftige Erweiterbarkeit:

```
rust/
  Cargo.toml          ← [workspace] root
  Cargo.lock          ← shared lock file
  zanshin-jj/         ← interner Crate (plain lib, kein cdylib)
    Cargo.toml        ← crate-type = ["lib"]
    src/lib.rs        ← idiomatische Rust-API über jj-lib
  zanshin-diff/       ← Word-Level-Diff + Syntax-Highlighting
    Cargo.toml        ← crate-type = ["lib"]
    src/lib.rs        ← imara-diff + tree-sitter-highlight
  zanshin-graph/      ← DAG-Lane-Assignment für Commit-Graph-UI
    Cargo.toml        ← crate-type = ["lib"]
    src/lib.rs        ← Topo-Sort + Lane-Algorithmus + Viewport-Cache
  zanshin-ffi/        ← Aggregator-Crate (einziger cdylib)
    Cargo.toml        ← crate-type = ["cdylib", "staticlib"]
    build.rs          ← cbindgen erzeugt zanshin_ffi.h
    src/lib.rs        ← extern "C" API; ruft zanshin-jj + zanshin-diff + zanshin-graph auf
  zanshin-mcp/        ← MCP-Server-Binary
    Cargo.toml        ← [[bin]] name = "zanshin-mcp"
    src/main.rs       ← rmcp-Server, nutzt zanshin-jj
  # zukünftig:
  # zanshin-crypto/   ← z.B. Signierung (plain lib)
  # zanshin-network/  ← z.B. Remote-Operationen (plain lib)
```

Jeder neue interne Crate:
1. wird im Workspace als `[lib]` definiert
2. wird von `zanshin-ffi` (für Flutter-FFI) und/oder `zanshin-mcp` (für MCP-Server) als Dependency aufgenommen
3. seine relevanten Funktionen werden in `zanshin-ffi/src/lib.rs` als `extern "C"` re-exportiert
4. nach Rust-API-Änderung: `cargo build` aktualisiert C-Header automatisch (cbindgen in `build.rs`), dann einmal `dart run tool/ffigen.dart`, fertig

Dart Hooks bauen nur den einen `zanshin-ffi`-Crate — interne Workspace-Erweiterungen ändern den Hook-Aufruf nicht.

_Source: [Cargo Workspaces](https://doc.rust-lang.org/book/ch14-03-cargo-workspaces.html), [native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust)_

---

### Deployment und Build-Architektur (macOS)

**Build-Pipeline:**
```
cargo make build
  → flutter build macos --release
      → Dart Hooks werden ausgelöst
      → hook/build.dart: RustBuilder kompiliert rust/zanshin-ffi/
      → cbindgen erzeugt zanshin_ffi.h (via build.rs)
      → libzanshin_ffi.dylib wird ins App Bundle eingebunden
      → Dart-Bindings (bindings.g.dart) linken via dart:ffi zur .dylib
  → cargo build --release -p zanshin-mcp
      → eigenständige Binary zanshin-mcp
  → bundle-mcp Task: Binary nach Zanshin.app/Contents/MacOS/zanshin-mcp kopieren
  → codesign Task: erst zanshin-mcp signieren, dann das gesamte Bundle
```

**Voraussetzungen auf Entwicklermaschine:**
- Flutter (stable, systemweit) — keine FVM-Verwaltung
- Rust via rustup (Version laut `rust-toolchain.toml` gepinnt)
- Xcode (für macOS Build)
- `cargo install cargo-make` (einmalig)
- Watchman als Runtime-Dependency für Endbenutzer (`brew install watchman`)

**Skalierung zu anderen Plattformen:** Alle eingesetzten Tools (Flutter, native_toolchain_rust, cbindgen, ffigen, notify-rs, rmcp, Watchman) unterstützen macOS, Linux und Windows. Die Architektur enthält keine macOS-spezifischen Annahmen — Cross-Plattform-Aufweitung ist später ohne Architektur-Umbau möglich.

_Source: [Dart Hooks Documentation](https://dart.dev/tools/hooks)_

---

## Implementation Approaches and Technology Adoption

### Konkrete Projektstruktur

> **Hinweis zum Scope:** "Grundgerüst" bezeichnet hier den Umfang dieses Projekts (Architektur, Build-System, jj-/MCP-Integration ohne Flutter-UI) — nicht den Maturity-Level. Der Code wird von Anfang an production-tauglich geschrieben: vollständige Fehlerbehandlung, Test-Coverage, Memory-Safety, Codesigning. Es gibt keine "MVP-Stufe" mit nachgelagerter Härtung.

```
zanshin/                              ← Flutter-Projekt-Root
├── .gitignore                        ← BMad-Infrastruktur ausgeschlossen
├── pubspec.yaml                      ← Dart/Flutter-Deps + ffigen-Config
├── analysis_options.yaml
│
├── lib/                              ← Flutter UI (Ralph's Domäne)
│   ├── main.dart
│   ├── src/
│   │   ├── native/
│   │   │   ├── bindings.g.dart       ← von ffigen generiert (committed)
│   │   │   ├── jj_worker.dart        ← Long-Running Worker-Isolate
│   │   │   │                         ← + NativeCallable.listener für Watcher + Progress
│   │   │   └── jj_facade.dart        ← idiomatische Dart-API (Main-Isolate-seitig)
│   │   └── ui/                       ← Widgets, Screens (später)
│
├── tool/
│   └── ffigen.dart                   ← ffigen-Script (Dart, manuell aufrufen)
│
├── hook/                             ← Dart Build Hooks
│   └── build.dart                    ← RustBuilder für zanshin-ffi
│
├── Makefile.toml                     ← cargo-make Tasks (build, run, bundle)
│
├── rust/                             ← Cargo Workspace
│   ├── Cargo.toml                    ← [workspace] members = [...]
│   ├── Cargo.lock                    ← committed
│   ├── rust-toolchain.toml           ← channel = "1.95.0"
│   │
│   ├── zanshin-jj/                   ← interner lib-Crate (kein cdylib)
│   │   ├── Cargo.toml                ← crate-type = ["lib"]
│   │   └── src/lib.rs                ← idiomatische Rust-API über jj-lib
│   │
│   ├── zanshin-diff/                 ← Word-Level-Diff + Syntax-Highlighting
│   │   ├── Cargo.toml                ← deps: imara-diff, tree-sitter-highlight
│   │   └── src/lib.rs                ← line→word breakdown, structured diff output
│   │
│   ├── zanshin-graph/                ← DAG-Lane-Assignment
│   │   ├── Cargo.toml                ← deps: zanshin-jj
│   │   └── src/
│   │       ├── lib.rs                ← public API: compute_graph(commits) → Graph
│   │       ├── topo.rs               ← topological sort
│   │       ├── lanes.rs              ← lane-assignment algorithm
│   │       └── cache.rs              ← viewport-checkpoint cache (für große Repos)
│   │
│   ├── zanshin-ffi/                  ← Aggregator-Crate (cdylib für Dart)
│   │   ├── Cargo.toml                ← crate-type = ["cdylib", "staticlib"]
│   │   ├── cbindgen.toml             ← Header-Generierungs-Config
│   │   ├── build.rs                  ← cbindgen-Aufruf erzeugt header.h
│   │   ├── include/
│   │   │   └── zanshin_ffi.h         ← cbindgen-Output (committed)
│   │   └── src/
│   │       ├── lib.rs                ← extern "C" API; ruft zanshin-jj auf
│   │       └── watcher.rs            ← notify-rs RepoWatcher, ruft Dart-Callbacks
│   │
│   └── zanshin-mcp/                  ← MCP-Server-Binary
│       ├── Cargo.toml                ← [[bin]] name = "zanshin-mcp"
│       └── src/main.rs               ← rmcp Server, nutzt zanshin-jj
│       # zukünftige Crates: zanshin-crypto, zanshin-net, …
│
├── macos/                            ← Flutter macOS Runner
│   └── Runner/
│       ├── Info.plist                ← macOS App-Konfiguration
│       └── …                         ← später: zanshin-mcp ins Bundle kopieren
│
└── _bmad-output/                     ← Projekt-Artefakte (PRDs, Stories)
    └── planning-artifacts/research/
```

Klare Verantwortlichkeiten:
- `lib/` (außer `lib/src/native/`): Flutter/Dart UI (Ralph)
- `lib/src/native/bindings.g.dart`: ffigen-Output (nie hand-editieren)
- `lib/src/native/jj_facade.dart`: hand-geschriebener Dart-Wrapper über die Bindings
- `rust/zanshin-jj`: idiomatische Rust-API (geteilt von ffi und mcp)
- `rust/zanshin-ffi`: extern "C"-Adapter — der einzige cdylib
- `rust/zanshin-mcp`: separater MCP-Server-Prozess
- `hook/build.dart`: Build-Glue (einmalig eingerichtet)

---

### Umsetzungsschritte

**1. Flutter-Projekt initialisieren**
- `flutter create --platforms=macos zanshin`
- `pubspec.yaml`: Dependencies hinzufügen — `hooks`, `native_toolchain_rust`, `ffi`, `ffigen` (dev)

**2. Rust Workspace aufsetzen**
- `rust/Cargo.toml` mit `[workspace] members = ["zanshin-jj", "zanshin-ffi", "zanshin-mcp"]`
- `rust/rust-toolchain.toml` mit `channel = "1.95.0"` (Pin gemäß Ralph's Wunsch)
- Workspace-weite Shared Dependencies in `[workspace.dependencies]` definieren

**3. `zanshin-jj` Crate (idiomatische Rust-API über jj-lib)**
- `crate-type = ["lib"]` (kein cdylib — interner Crate)
- Dependency: `jj-lib = "0.41"`
- Bietet idiomatische Rust-API: `Repository::open(path)`, `repo.log()`, `repo.status()`, etc.
- Eigenes Error-Typ-System, Anti-Corruption-Layer für jj-lib-API-Drift

**4. `zanshin-ffi` Aggregator-Crate (cdylib für Dart)**
- `crate-type = ["cdylib", "staticlib"]`
- Dependencies: `zanshin-jj = { path = "../zanshin-jj" }`
- Build-Dep: `cbindgen`
- `cbindgen.toml`: Konfiguriert C-Header-Generierung (Sprache C, Include-Guards, kein C++-Namespacing)
- `build.rs`: Ruft cbindgen auf, schreibt Header nach `include/zanshin_ffi.h`
- `src/lib.rs`: Alle `extern "C"`-Funktionen — dünne Wrapper, die zanshin-jj aufrufen, Strings nach C marshallen, Errors in Result-Codes übersetzen
- Memory-Mgmt: für jeden allokierten Typ eine `free_xyz` Funktion

**5. `zanshin-mcp` Binary (Rust MCP-Server)**
- `[[bin]] name = "zanshin-mcp"` in `Cargo.toml`
- Dependencies: `zanshin-jj = { path = "../zanshin-jj" }`, `rmcp = { version = "1.7", features = ["server"] }`, `tokio`
- `src/main.rs`: tokio-Runtime, rmcp ServerHandler, stdio-Transport
- Tools wie `jj_log`, `jj_status`, `jj_diff` über `#[tool]`-Makros — delegieren an zanshin-jj
- Build-Output: `target/release/zanshin-mcp` (Binary)

**6. Dart Hook konfigurieren**
- `hook/build.dart` mit einem `RustBuilder(assetName: 'src/native/bindings.g.dart')` — zeigt auf `zanshin-ffi`
- Beim ersten `flutter run` wird zanshin-ffi kompiliert, `.dylib` ins macOS-Bundle eingebunden

**7. ffigen konfigurieren**
- `tool/ffigen.dart` mit `FfiGenerator(headers: Headers(entryPoints: [...zanshin_ffi.h]), output: ...)`
- Aufruf: `dart run tool/ffigen.dart` (manuell, nach Rust-API-Änderungen)
- Output: `lib/src/native/bindings.g.dart` (committed)

**8a. Watchman-Setup-Check beim Repo-Öffnen**

In der `Repository.open(path)`-Methode (Rust-Seite, im `zanshin-jj`-Crate):

- Prüfen ob Watchman im PATH ist
- `.jj/repo/config.toml` parsen, prüfen ob `[fsmonitor]`-Block korrekt gesetzt ist
- Status nach Dart zurückgeben (z.B. enum `FsMonitorStatus { Ready, WatchmanMissing, ConfigMissing }`)
- Dart-Seite zeigt entsprechende UI:
  - `Ready` → stiller Repo-Open
  - `WatchmanMissing` → Setup-Dialog mit Link auf [jj fsmonitor docs](https://docs.jj-vcs.dev/latest/config/#watchman) und plattformspezifischem Install-Command
  - `ConfigMissing` → "Watchman ist installiert. Soll Zanshin die fsmonitor-Config in dein Repo schreiben?" mit User-Bestätigung

**8b. Dart-Facade-Layer (`lib/src/native/jj_facade.dart`) + Worker-Isolate**
Über den auto-generierten Bindings:
- Ein **Long-Running Worker-Isolate** (`lib/src/native/jj_worker.dart`), beim App-Start via `Isolate.spawn` gestartet
- Worker hält FFI-Handles (Repository-Pointer, Watcher-Handle) für die App-Lifetime
- Main-Isolate sendet Commands über `SendPort`, Worker antwortet über `SendPort`
- Memory-Management im Worker: `Finalizer<Pointer>` für automatisches `free_xyz`
- Idiomatische Dart-Klassen (`Repository`, `Commit`) im Main-Isolate; Worker arbeitet mit Raw-Pointers
- Errors aus FFI-Result-Codes werden in Dart-Exceptions umgewandelt und über den Port serialisiert

**8c. FFI-Callback-Pattern für asynchrone Rust→Dart-Signale**

Zwei Use Cases, identischer Pattern:

1. **FS-Watcher-Events** (notify-rs in `zanshin-ffi` beobachtet `.jj/op_heads/heads/` und `.jj/working_copy/checkout`)
2. **Progress-Updates** für lang laufende Operationen (`jj_fetch`, `jj_push`, große Diffs, op-log-Walks)

Pattern in Worker-Isolate:
```dart
// Beim Repo-Open:
final watchCallback = NativeCallable<Void Function(Int32, Pointer<Utf8>)>
  .listener((kindCode, pathPtr) {
    final event = RepoWatchEvent(kind: kindCode, path: pathPtr.toDartString());
    mainSendPort.send(event);  // → Main-Isolate → UI-Refresh
  });

final watcherHandle = bindings.zanshin_watch_repo(
  repoPath.toNativeUtf8(),
  watchCallback.nativeFunction,
);

// Bei Repo-Close:
bindings.zanshin_stop_watcher(watcherHandle);
watchCallback.close();
```

Gleicher Pattern für Progress:
```dart
final progressCallback = NativeCallable<Void Function(Uint64, Uint64)>
  .listener((current, total) {
    mainSendPort.send(FetchProgress(current: current, total: total));
  });

final result = bindings.jj_fetch(repoHandle, progressCallback.nativeFunction);
progressCallback.close();
```

Wichtige Lifecycle-Regeln (NativeCallable):
- Listener muss im selben Isolate `close()`d werden, in dem `.listener()` aufgerufen wurde
- Listener bleibt aktiv solange Dart-Code darauf wartet — der Worker-Isolate ist long-lived, also passt das
- Rust darf den `extern "C" fn`-Pointer nicht aufbewahren, nachdem `close()` aufgerufen wurde — Lifecycle wird durch Watcher/Operation-Handles abgesichert

**9. Build-Orchestrierung mit cargo-make**

Build-Schritte werden NICHT in Xcode-Build-Phases versteckt, sondern explizit in `Makefile.toml` als cargo-make-Tasks definiert. Aufrufbar via `cargo make <task>`.

```toml
# Makefile.toml (Auszug)

[tasks.build]
description = "Vollständiger Release-Build inkl. MCP-Binary im Bundle"
dependencies = ["build-flutter", "build-mcp", "bundle-mcp", "codesign"]

[tasks.build-flutter]
description = "Flutter macOS App + zanshin-ffi.dylib (via Dart Hooks)"
command = "flutter"
args = ["build", "macos", "--release"]

[tasks.build-mcp]
description = "Rust MCP-Server-Binary kompilieren"
command = "cargo"
args = ["build", "--release", "-p", "zanshin-mcp"]

[tasks.bundle-mcp]
description = "zanshin-mcp Binary ins macOS App-Bundle kopieren"
dependencies = ["build-flutter", "build-mcp"]
script = '''
cp target/release/zanshin-mcp \
  build/macos/Build/Products/Release/zanshin.app/Contents/MacOS/
'''

[tasks.codesign]
description = "Helper-Binary signieren (bottom-up: erst Helper, dann Bundle)"
dependencies = ["bundle-mcp"]
script = '''
APP=build/macos/Build/Products/Release/zanshin.app
codesign --force --sign - "$APP/Contents/MacOS/zanshin-mcp"
codesign --force --sign - "$APP"
'''

[tasks.run]
description = "Entwicklung: Flutter App starten (zanshin-mcp via cargo run testen)"
command = "flutter"
args = ["run", "-d", "macos"]

[tasks.mcp]
description = "MCP-Server standalone starten (für Tests ohne Flutter)"
command = "cargo"
args = ["run", "-p", "zanshin-mcp"]

[tasks.clean]
description = "Alle Build-Artefakte löschen"
dependencies = ["clean-flutter", "clean-cargo"]

[tasks.clean-flutter]
command = "flutter"
args = ["clean"]

[tasks.clean-cargo]
command = "cargo"
args = ["clean"]
```

Installation einmalig: `cargo install cargo-make`. Aufruf danach mit `cargo make build`, `cargo make run`, `cargo make mcp` etc.

_Source: [cargo-make Documentation](https://sagiegurari.github.io/cargo-make/), [cargo-make GitHub](https://github.com/sagiegurari/cargo-make)_

---

### Build-Output: Bundle-Struktur

Nach `cargo make build` entsteht folgendes macOS App Bundle:

```
build/macos/Build/Products/Release/
└── Zanshin.app/
    └── Contents/
        ├── Info.plist                       ← Bundle-Metadaten
        ├── MacOS/
        │   ├── Zanshin                      ← Flutter-Hauptbinary (Dart-Code + Embedder)
        │   └── zanshin-mcp                  ← Rust MCP-Server (Helper-Binary, codesigned)
        ├── Frameworks/
        │   ├── libzanshin_ffi.dylib         ← FFI-Library (via Dart Hooks gebaut)
        │   ├── FlutterMacOS.framework/
        │   └── App.framework/
        └── Resources/
            ├── AppIcon.icns
            └── …
```

**Wichtige Eigenschaften:**

- **Zwei eigenständige Executables** im selben Bundle:
  - `Zanshin` ist der Flutter-App-Einstieg (UI)
  - `zanshin-mcp` ist der MCP-Server, der vom AI-Host als Subprocess via stdio gespawnt wird
- **Beide teilen das App Bundle**, aber laufen als **getrennte Prozesse** mit unterschiedlichen Lebenszyklen
- Der MCP-Host (Claude Desktop, Cursor) wird konfiguriert mit dem absoluten Pfad zur Helper-Binary:
  ```json
  {
    "mcpServers": {
      "zanshin": {
        "command": "/Applications/Zanshin.app/Contents/MacOS/zanshin-mcp"
      }
    }
  }
  ```
- `libzanshin_ffi.dylib` wird **nur** vom Flutter-Prozess geladen (über `dart:ffi`); der MCP-Server nutzt jj-lib direkt als Rust-Library (kein FFI nötig)

_Source: [Apple Developer Forums - Codesigning helper executables](https://developer.apple.com/forums/thread/655881), [Tauri macOS Application Bundle docs](https://v2.tauri.app/distribute/macos-application-bundle/), [Dart Hooks](https://dart.dev/tools/hooks), [native_toolchain_rust example](https://github.com/GregoryConrad/native_toolchain_rs/tree/main/examples/dart_only), [ffigen on pub.dev](https://pub.dev/packages/ffigen), [rmcp on docs.rs](https://docs.rs/rmcp)_

---

### Diff-Rendering: Word-Level mit Syntax-Highlighting

**Anforderung:** Mehr als grün/rot pro Zeile — wir wollen pro geänderter Zeile die geänderten *Wörter* hervorheben, plus Syntax-Färbung der Tokens. Vergleichbar mit dem, was `delta` als Pager für Git-Diffs macht.

**Diff-Intelligenz-Ebenen:**
```
Level 1 (Basis):    Line-Level Diff (von jj-lib)
                          ↓
Level 2 (Word):     Word-Level Diff innerhalb geänderter Zeilen
                          ↓
Level 3 (Syntax):   Token-Highlighting nach Sprache
                          ↓
Level 4 (AST):      Strukturelle Diffs (difftastic-Klasse) — optional/zukünftig
```

**Entscheidung: Level 2+3 (Delta-Klasse).** AST-Diff (Level 4) wird bewusst zurückgestellt, weil bekannte UX-Risiken (verwirrende Darstellung bei unkonventionellen Änderungen, Tree-sitter-Grammatik pro Sprache als Build-Dep, immature Library-Options).

**Library-Auswahl:**

| Tool | Status | Verdict |
|---|---|---|
| `difftastic` | CLI-only; `difftastic-lib` inoffiziell auf crates.io, Wartung unklar | ❌ kein nutzbares Library-API |
| `delta` (dandavison) | CLI; processed Diff-Output via stdin/stdout | ❌ kein Library-API |
| **`imara-diff`** v0.2.0 | Production-Library von Pascal Kuthe (helix-editor) | ✅ **gewählt** |
| `similar` | Verbreitete Library, langsamer | sekundärer Fallback |
| `syndiff` | Library-First, AST-Diff (difftastic-inspired) | Reserve für mögliches späteres Level-4-Backend |
| `tree-sitter-highlight` | Offizielles Tree-sitter-Modul für Syntax-Highlighting | ✅ **gewählt** (nicht für AST-Diff, nur für Token-Färbung) |

**Begründung für `imara-diff`:**
- Aktiv gewartet (v0.2.0, von Pascal Kuthe / helix-editor)
- Histogram-Algorithmus: 10–100% schneller als Myers, ca. 30× schneller als `similar` auf Kernel-Repo-Diffs
- Generisches `TokenSource`-Trait — wir können Lines, Words, oder Identifier tokenisieren
- Apache 2.0-Lizenz

**Architektur:**

```
┌─────────────────────────────────────────────────────────┐
│  zanshin-jj                                              │
│  - liefert jj-lib's structured line-level Hunks          │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│  zanshin-diff (lib)                                      │
│  ┌───────────────────────────────────────────────────┐   │
│  │  1. Jede modifizierte Zeile in Words tokenisieren  │   │
│  │  2. imara-diff (Histogram) auf Word-Sequenzen      │   │
│  │  3. Edit-Operationen pro Word → Segments           │   │
│  └───────────────────────────────────────────────────┘   │
│  ┌───────────────────────────────────────────────────┐   │
│  │  4. tree-sitter-highlight pro Zeile (nach File-   │   │
│  │     Extension) → Highlight-Class pro Token         │   │
│  └───────────────────────────────────────────────────┘   │
│  Output: strukturierte Diff-Daten                        │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│  zanshin-ffi                                             │
│  - serialisiert Diff-Daten als JSON (serde_json)         │
│  - FFI-Boundary → Dart                                   │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│  Flutter UI                                              │
│  - parst JSON in Diff-Modell                             │
│  - rendert Hunks → Lines → Segments mit Farben           │
└─────────────────────────────────────────────────────────┘
```

**Daten-Modell (JSON-Output):**

```json
{
  "file_path": "src/main.rs",
  "language": "rust",
  "hunks": [
    {
      "old_range": [10, 12],
      "new_range": [10, 13],
      "lines": [
        {
          "kind": "equal",
          "segments": [
            { "kind": "equal", "text": "function calculateTotal(items) {", "highlight": "keyword.function ..." }
          ]
        },
        {
          "kind": "removed",
          "segments": [
            { "kind": "equal",   "text": "  return items.reduce((sum, x) => sum + x.price" },
            { "kind": "removed", "text": ", 0" }
          ]
        },
        {
          "kind": "added",
          "segments": [
            { "kind": "equal", "text": "  return items.reduce((sum, x) => sum + x.price" },
            { "kind": "added", "text": " * x.qty, 0" }
          ]
        }
      ]
    }
  ]
}
```

**Erweiterbarkeit zu Level 4 später:**
Da `zanshin-diff` ein eigener Crate ist, lässt sich später ein AST-Diff-Modus als Alternative implementieren (z.B. via `syndiff` oder eigener Tree-sitter-basierter Diff-Logik). Der `zanshin-ffi`-API kann ein optionales `mode: "word" | "ast"` Parameter bekommen — keine Änderung an Architektur oder anderen Crates nötig.

_Source: [imara-diff on docs.rs](https://docs.rs/imara-diff/), [imara-diff GitHub](https://github.com/pascalkuthe/imara-diff), [tree-sitter-highlight](https://docs.rs/tree-sitter-highlight/), [difftastic](https://github.com/Wilfred/difftastic) (als Inspiration, nicht als Library)_

---

### Commit-Graph-Visualisierung: Lane-Assignment

**Anforderung:** Schnelles Scrollen durch die Commit-Historie inklusive korrekt gezeichneter "bunter Linien" zwischen Commits (DAG-Visualisierung), auch bei Random-Jumps zu beliebigen Commits.

**jj-lib liefert die DAG-Primitives, NICHT die Lane-Logik:**

| jj-lib-Modul | Aufgabe |
|---|---|
| `default_index` | On-disk Commit-Index (jj's Äquivalent zu Git's commit-graph file). Schnelle Random-Lookups, Topo-Order, Parent-Iteration |
| `index` (Trait) | Pluggable Interface — eigene Index-Implementationen via `Index::evaluate_revset()` möglich |
| `dag_walk` / `dag_walk_async` | Generische DAG-Algorithmen: Ancestor-Queries, Heads, Common-Base |
| `revset` | Revision-Set-Sprache, kompiliert gegen den Index |

**Warum nicht `gix-commitgraph`:**
- jj nutzt `gitoxide` intern, kapselt es aber hinter dem Backend-Trait
- jj's StackedTable-Index ist explizit für **lock-free concurrency** und das jj-Operation-Model entworfen — enthält auch Working-Copy-Commits (`@`-Commit + Auto-Snapshots), die in Git's commit-graph file NICHT stehen
- Direktes Bypass würde diese Information verlieren und Konsistenz-Risiken einführen

**Was fehlt: Lane-Assignment-Algorithmus**

Die UI-Frage "in welcher Spalte wird welcher Commit gezeichnet, wo verlaufen die Linien dazwischen?" liefert jj-lib nicht — das ist ein eigener UI-Algorithmus. Aus der Recherche ([pvigier 2019](https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html)) bestätigt:

> Computing the topological sort requires traversing the DAG. The "forbidden indices" calculation depends on all commits between a merge child and parent. The active branches list must track all currently open branches.

→ Der Algorithmus ist **nicht stateless**: Eine isolierte Zeile lässt sich nicht rendern, ohne den Active-Branches-State zu kennen. Aber: **deterministisch** (gleicher Input → gleicher Output), also cachebar.

**Architektur (`zanshin-graph`-Crate):**

```
┌─────────────────────────────────────────────────────────┐
│  Beim Repo-Open oder bei op_heads-Change:                │
│                                                          │
│  jj-lib's default_index                                  │
│       → Iterator<(CommitId, Vec<ParentId>)>              │
│       in topologischer Order                             │
│            │                                             │
│            ▼                                             │
│  zanshin-graph::compute_graph()                          │
│       1. Topo-Sort (jj liefert bereits sortiert)         │
│       2. Lane-Assignment (Algorithmus à la GitKraken/    │
│          SourceTree: "straight branches", möglichst      │
│          gerade Linien)                                  │
│       3. Edge-Routing (welche Lane → welche Lane         │
│          zwischen Row n und n+1)                         │
│       4. Color-Index pro Branch (für UI-Theme-Palette)   │
│            │                                             │
│            ▼                                             │
│  Vec<Row> (flach, indexbar) → in Cache                   │
└─────────────────────────────────────────────────────────┘
                       │
                       │ JSON via zanshin-ffi
                       ▼
┌─────────────────────────────────────────────────────────┐
│  Flutter Custom-Painter                                  │
│  - ListView.builder mit virtual scrolling                │
│  - Pro Row: zeichne Commit-Dot bei (lane × W, row × H)   │
│  - Zeichne edges_below als Linien zur nächsten Row       │
│  - Farben aus theme-palette[color_idx]                   │
└─────────────────────────────────────────────────────────┘
```

**Output-Format (JSON):**

```json
{
  "rows": [
    {
      "commit_id": "abc123def456",
      "lane": 0,
      "max_lane_in_row": 2,
      "edges_below": [
        { "from_lane": 0, "to_lane": 0, "type": "vertical" },
        { "from_lane": 1, "to_lane": 1, "type": "vertical" }
      ],
      "is_merge": false,
      "color_idx": 1
    },
    {
      "commit_id": "xyz789...",
      "lane": 1,
      "max_lane_in_row": 2,
      "edges_below": [
        { "from_lane": 1, "to_lane": 0, "type": "merge" }
      ],
      "is_merge": true,
      "color_idx": 2
    }
  ]
}
```

**Performance-Strategie:**

- **Initiale Berechnung beim Repo-Open:** O(n) für n Commits. Auch bei 100k Commits im Millisekunden- bis niedrigen Sekunden-Bereich
- **Update bei neuer Operation (`op_heads`-Change):** Inkrementell — neue Commits an den Heads anfügen, Lanes lokal anpassen. Bei Rebases kann größere Neuberechnung nötig sein, aber begrenzt auf den geänderten Sub-Graph
- **Random-Scrolling:** O(1) — Flutter rendert direkt aus dem Vec<Row>-Cache
- **Für extrem große Repos (>1M Commits):** Optional Checkpoint-Caching alle N Commits, lokale Lane-Expansion beim Jump

**Algorithmus-Wahl:**

Inspiration aus mehreren bekannten Implementierungen:
- [pvigier "straight branches"](https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html) — gut dokumentiert, fokus auf gerade Linien (GitKraken/SourceTree-Stil)
- [`indigane/git-graph-drawing`](https://github.com/indigane/git-graph-drawing) — Sammlung verschiedener Algorithmen mit Side-by-Side-Vergleich
- `gitk` / `git-log --graph` — klassische Referenz, dichter aber weniger ästhetisch

Wir bauen den Algorithmus selbst (ca. 200-500 Zeilen Rust). Eine externe Library ist nicht nötig und würde uns nur einschränken (Theme-Integration, jj-spezifische Anforderungen wie Working-Copy-Commit-Highlighting).

**Erweiterbarkeit:**
- `zanshin-graph` ist als eigener Crate strukturiert, sodass alternative Layout-Algorithmen (z.B. gitk-Stil oder eigener Hybrid) bei Bedarf ohne Architektur-Eingriff als parallele Implementierung neben dem Default-Algorithmus existieren können
- Filter-Integration (Revset-Queries): `compute_graph()` arbeitet auf einer beliebigen Commit-Sequenz — die volle History ebenso wie eine Revset-Subset

_Source: [jj-lib `default_index`](https://docs.rs/jj-lib/latest/jj_lib/default_index/), [jj-lib `dag_walk`](https://docs.rs/jj-lib/latest/jj_lib/dag_walk/), [Commit Graph Drawing Algorithms - pvigier](https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html), [indigane/git-graph-drawing](https://github.com/indigane/git-graph-drawing)_

---

### Testing-Strategie

Drei Test-Ebenen:

**Rust Unit-Tests** (in `zanshin-jj/src/`)
- Standard `#[cfg(test)] mod tests` mit `cargo test`
- Testen die Rust-Logik isoliert (vor FFI-Boundary)
- jj-lib-Operationen können auf temporäre Repos in `tempdir()` arbeiten

**Dart Unit-Tests** (in `test/`)
- Testen den Dart-Facade-Layer
- Brauchen ein gebautes `.dylib` → erfordert vorherigen Build
- Memory-Leaks via `dart:ffi` Sentinels prüfbar

**Rust MCP-Tests** (`cargo test -p zanshin-mcp`)
- Unit-Tests für Tool-Implementierungen direkt auf der rmcp-Server-Struktur
- Integration-Tests mit `cargo run -p zanshin-mcp` als Subprocess
- E2E-Tests: zanshin-mcp Binary spawnen, JSON-RPC-Requests via stdio senden, Antworten verifizieren
- Läuft ohne Flutter-UI (wichtig für CI)

---

### Risikobewertung

| Risiko | Wahrscheinlichkeit | Mitigation |
|---|---|---|
| jj-lib API ändert sich (pre-1.0) | Hoch | `zanshin-jj`-Crate als Anti-Corruption-Layer; bei jj-lib-Update nur dieser Crate anzupassen — sowohl `zanshin-ffi` als auch `zanshin-mcp` bleiben unverändert |
| rmcp Breaking Changes zwischen Major-Versionen | Niedrig | rmcp v1.x ist stabil mit Migration Guide; API-Surface in `zanshin-mcp` klein halten |
| Dart Hooks Breaking Changes | Niedrig | Seit Dart 3.10 stable; Pin Dart-Version |
| Memory-Leaks an FFI-Boundary | Mittel | `Finalizer<Pointer>`-Pattern in Dart-Facade; AddressSanitizer in Rust-Tests |
| macOS-Codesign/Notarization für .dylib und zanshin-mcp | Niedrig (lokal), Mittel (Distribution) | Flutter-Build kümmert sich um Bundle-Signing; für Distribution Apple Developer Account nötig; zanshin-mcp braucht ggf. eigenes Signing |
| Performance bei großen Repos | Mittel | Isolate-basierte FFI-Aufrufe; ggf. Streaming-API für Log/Diff |
| cbindgen + ffigen produzieren inkonsistente Bindings | Niedrig | Beide Tools sind reif; Output wird committed, sodass Inkonsistenzen im Review sichtbar werden |

_Source: [JJ Architecture](https://docs.jj-vcs.dev/latest/technical/architecture/), [rmcp on docs.rs](https://docs.rs/rmcp)_

---

## Research Methodology and Sources

### Methodik

Alle Aussagen wurden gegen Live-Quellen (Stand 2026-05-15) verifiziert. Versionsangaben aus Blog-Artikeln wurden gegen offizielle Releases gegengeprüft; der Nutzer hat die Toolchain-Versionen (Flutter 3.41.9, Dart 3.11.5, Rust 1.95.0) bestätigt. Confidence-Level:

- **Hoch:** Offizielle Pakete (ffigen, native_toolchain_rust, rmcp, jj-lib, imara-diff, notify-rs, watchman, cargo-make), Architektur-Dokumentation
- **Mittel:** jj-lib-API-Stabilität (pre-1.0, keine Garantien)
- **Niedrig:** Aggregator-Crate-Pattern mit `native_toolchain_rust` (dokumentiert konform, aber kein öffentliches Referenz-Beispiel für exakt dieses Pattern); Lane-Assignment-Performance bei sehr großen Repos (>1M Commits, Checkpoint-Caching geplant aber nicht profiled)

### Quellenverzeichnis

**Offizielle Toolchain-Dokumentation:**
- [Dart Hooks Documentation](https://dart.dev/tools/hooks)
- [Announcing Dart 3.10](https://dart.dev/blog/announcing-dart-3-10)
- [Dart FFI / C-Interop](https://dart.dev/interop/c-interop)
- [Dart Isolates Documentation](https://dart.dev/language/isolates)
- [Flutter Concurrency and Isolates](https://docs.flutter.dev/perf/isolates)
- [Better isolate management with Isolate.run() (Dart Blog)](https://dart.dev/blog/better-isolate-management-with-isolate-run)
- [Flutter Architectural Overview](https://docs.flutter.dev/resources/architectural-overview)

**Pub.dev Pakete:**
- [native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust) (v1.0.4) — **gewählt**
- [ffigen](https://pub.dev/packages/ffigen) (v20.1.1) — **gewählt**
- [dart_mcp](https://pub.dev/packages/dart_mcp) (v0.5.1) — *evaluiert, verworfen zugunsten rmcp als separates Rust-Binary*
- [watcher](https://pub.dev/packages/watcher) (v1.2.1) — *evaluiert, verworfen zugunsten notify-rs in zanshin-ffi (Konsistenz mit FFI-Callback-Pattern)*

**JJ VCS:**
- [jj-vcs GitHub Repository](https://github.com/jj-vcs/jj)
- [jj-lib on crates.io](https://crates.io/crates/jj-lib) (v0.41.0)
- [JJ Architecture Documentation](https://docs.jj-vcs.dev/latest/technical/architecture/)
- [JJ Working Copy Documentation](https://docs.jj-vcs.dev/latest/working-copy/)
- [JJ Operation Log Documentation](https://docs.jj-vcs.dev/latest/operation-log/)
- [JJ Community Tools](https://docs.jj-vcs.dev/latest/community_tools/)
- [jj-vcs/jj#6646: GUI watcher recommendations](https://github.com/jj-vcs/jj/discussions/6646)
- [JayJay (Reference macOS GUI)](https://github.com/hewigovens/jayjay)

**Diff-Rendering:**
- [imara-diff on docs.rs](https://docs.rs/imara-diff/) (v0.2.0) — **gewählt** für Word-Level-Diff
- [imara-diff GitHub](https://github.com/pascalkuthe/imara-diff)
- [tree-sitter-highlight docs](https://docs.rs/tree-sitter-highlight/) — **gewählt** für Syntax-Färbung
- [similar (mitsuhiko) on GitHub](https://github.com/mitsuhiko/similar) — *evaluiert, langsamer als imara-diff*
- [syndiff](https://docs.rs/syndiff/) — *evaluiert, Reserve für späteren AST-Diff-Modus*
- [difftastic](https://github.com/Wilfred/difftastic) — *Inspiration; CLI-only, keine Library-API*
- [delta (dandavison)](https://github.com/dandavison/delta) — *Inspiration für Word-Diff + Syntax-Highlight UX; CLI-only*

**Commit-Graph-Rendering:**
- [jj-lib default_index module](https://docs.rs/jj-lib/latest/jj_lib/default_index/) — **gewählt** als DAG-Quelle
- [jj-lib dag_walk module](https://docs.rs/jj-lib/latest/jj_lib/dag_walk/) — DAG-Algorithmen
- [Commit Graph Drawing Algorithms - pvigier blog](https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html) — Algorithmus-Referenz
- [indigane/git-graph-drawing](https://github.com/indigane/git-graph-drawing) — Sammlung verschiedener Implementierungen
- [gix-commitgraph on crates.io](https://crates.io/crates/gix-commitgraph) — *evaluiert, nicht gewählt (würde Working-Copy-Commits verlieren)*

**Filesystem-Watching:**
- [notify-rs on GitHub](https://github.com/notify-rs/notify) (v2.1.0) — **gewählt** für `zanshin-ffi`-Watcher
- [Dart watcher package on pub.dev](https://pub.dev/packages/watcher) (v1.2.1) — *evaluiert, verworfen zugunsten Architektur-Konsistenz mit Rust-seitigen FFI-Callbacks*
- [Watchman official site](https://facebook.github.io/watchman/)
- [JJ fsmonitor/Watchman config docs](https://docs.jj-vcs.dev/latest/config/#watchman)
- [Watchman macOS binaries discontinued (#1199)](https://github.com/facebook/watchman/issues/1199)
- [Watchman per-user-daemon conflict (#558)](https://github.com/facebook/watchman/issues/558)
- [Dart `NativeCallable` documentation](https://api.dart.dev/dart-ffi/NativeCallable-class.html)

**MCP-Protokoll:**
- [MCP Architecture Overview](https://modelcontextprotocol.io/docs/learn/architecture)
- [modelcontextprotocol/rust-sdk (rmcp)](https://github.com/modelcontextprotocol/rust-sdk) (v1.7.0)
- [rmcp on docs.rs](https://docs.rs/rmcp)
- [MCP Transports](https://www.speakeasy.com/mcp/core-concepts/transports)

**Rust Toolchain:**
- [Cargo Workspaces](https://doc.rust-lang.org/book/ch14-03-cargo-workspaces.html)
- [native_toolchain_rs GitHub](https://github.com/GregoryConrad/native_toolchain_rs)
- [cbindgen Documentation](https://github.com/Michael-F-Bryan/rust-ffi-guide/blob/master/book/cbindgen.md)

**Build-Orchestrierung:**
- [cargo-make Documentation](https://sagiegurari.github.io/cargo-make/)
- [cargo-make GitHub](https://github.com/sagiegurari/cargo-make)
- [Apple Developer - Codesigning helper executables](https://developer.apple.com/forums/thread/655881)
- [Tauri macOS Application Bundle docs](https://v2.tauri.app/distribute/macos-application-bundle/)

### Bekannte Recherche-Lücken

- **rmcp Server-Code-Beispiele:** Offizielle Doku auf docs.rs ist vorhanden; konkrete Tool-Registration-Patterns sind in den [rust-sdk examples](https://github.com/modelcontextprotocol/rust-sdk) bei der Implementierung direkt zu konsultieren
- **jj-lib API-Examples:** Keine kuratierte Liste von "wie wrappe ich jj-lib in einem GUI" — Vorgehen muss aus JayJay (`jayjay-core`) abgeleitet werden
- **macOS-Codesign-/Notarization-Konfiguration für die Distribution:** Die Recherche fokussierte auf Build-System und Architektur — die konkreten Apple-Developer-ID-Konfiguration, Notarization-Workflows und Entitlements sind ein separates Distribution-Thema, das vor dem ersten Release adressiert werden muss (zusätzliche Tasks in `Makefile.toml`, Apple-Developer-Account, ggf. Entitlements für zanshin-mcp)
- **Aggregator-Crate + native_toolchain_rust:** Es ist plausibel und dokumentiert-konform, aber kein konkretes Public-Beispiel für genau dieses Pattern verifiziert
- **Lane-Assignment-Performance bei sehr großen Repos:** Algorithmus-Klasse ist bekannt und bewährt (GitKraken, SourceTree), aber konkrete Performance-Charakteristik für Repos jenseits ~100k Commits in Zanshin's spezifischer Implementierung muss noch profiled werden — Checkpoint-Caching ist designed, aber nicht implementiert
- **NativeCallable.listener Lifecycle bei Hot-Reload:** Während der Flutter-Entwicklung können Worker-Isolates und NativeCallables durch Hot-Reload in unklare Zustände kommen; konkrete Failure-Modes sind nicht im Detail untersucht

---

## Conclusion

Die Recherche zeigt einen klaren, gut begründeten Weg für Zanshin:

**Build-Stack:** `native_toolchain_rust` + `cbindgen` + `ffigen` — drei offizielle, voneinander unabhängige Tools, verbunden über die stabile C-ABI. Kein flutter_rust_bridge.

**Rust-Architektur:** Cargo Workspace mit fünf initialen Crates:
- `zanshin-jj` — idiomatische Rust-API über jj-lib (Anti-Corruption-Layer)
- `zanshin-diff` — Word-Level-Diff + Syntax-Highlighting (imara-diff + tree-sitter-highlight)
- `zanshin-graph` — DAG-Lane-Assignment für Commit-Graph-Visualisierung
- `zanshin-ffi` — Aggregator-cdylib mit `extern "C"`-API für Dart Hooks
- `zanshin-mcp` — separate Binary mit rmcp MCP-Server

Interne Crates teilen `zanshin-jj` als Library-Dependency. Erweiterung um zusätzliche Rust-Crates ist transparent: neu im Workspace eintragen, aus `zanshin-ffi`/`zanshin-mcp` aufrufen — keine Build-System-Änderungen nötig.

**MCP-Integration:** `rmcp` als separates Rust-Binary, mit der macOS-App gebündelt. Produktionsreif, vollständiger Feature-Set, direkter jj-lib-Zugriff ohne Dart-Umweg, eigenständig testbar.

**Async-Strategie:** Sync FFI über einen Long-Running Worker-Isolate (manuelles `Isolate.spawn` + Ports). Vermeidet Spawn-Overhead bei häufigen Calls, hält FFI-Handles persistent. Keine Async-Codegen-Magie nötig.

**Build-Orchestrierung:** `cargo-make` mit `Makefile.toml` — alle Build-Tasks (Flutter, Cargo, Bundle-Assembly, Codesign) als deklarative TOML-Tasks. Keine Build-Logik in Xcode-XML versteckt; alles transparent im Repo.

**Change-Detection:** Zweistufige Watcher-Architektur, vollständig in Rust. (1) Watchman als System-Dependency triggert jj-Auto-Snapshots bei Working-Tree-Änderungen (Setup-Check beim Repo-Öffnen, Anleitung mit Link auf [jj-Doku](https://docs.jj-vcs.dev/latest/config/#watchman)). (2) `notify-rs` in `zanshin-ffi` beobachtet `.jj/repo/op_heads/heads/` und ruft Dart-UI via `NativeCallable.listener` Callback. Gleiche FFI-Callback-Infrastruktur wird für Progress-Notifications langer Operationen wiederverwendet. Kein IPC zwischen MCP-Server und Flutter-App nötig.

**Risiko-Bewusstsein:** jj-lib ist pre-1.0. Der `zanshin-jj`-Adapter-Crate schützt die beiden Konsumenten (`zanshin-ffi`, `zanshin-mcp`) vor API-Drift.

Die Architektur ist vollständig spezifiziert und kann jetzt production-ready implementiert werden — entweder als nächster Schritt durch konkrete Stories/Tasks (BMad-Workflow: `bmad-create-prd` → `bmad-create-architecture` → `bmad-create-epics-and-stories`) oder durch direkte Implementierung. Es gibt keine "MVP-Phase" mit nachgelagerter Härtung: vollständige Fehlerbehandlung, Test-Coverage, Memory-Safety und Codesigning sind von Anfang an Teil jeder Story.

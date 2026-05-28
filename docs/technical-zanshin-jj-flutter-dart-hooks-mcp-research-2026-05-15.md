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

Die Recherche kommt zu folgender Architekturempfehlung: **Dart Hooks (`native_toolchain_rust`)** auf der Build-Seite, **`cbindgen` + `ffigen`** für die FFI-Bindings — ohne `flutter_rust_bridge`. Die Rust-Seite verwendet ein **Aggregator-Crate-Pattern**: Ein einzelner `zanshin-ffi`-Crate (cdylib) re-exportiert die `extern "C"`-API aller internen Crates (`zanshin-jj`, später weitere); Dart Hooks "sehen" nur diesen einen Crate, intern bleibt die Cargo-Workspace-Struktur modular. Der **MCP Server läuft als separates Rust-Binary** (mit `rmcp`), das mit der macOS-App gebündelt wird und denselben `zanshin-jj`-Crate als Library nutzt. **Async wird durch Dart Isolates** (`Isolate.run`) erreicht, nicht durch FFI-Codegen.

### Key Technical Findings

1. **Dart Hooks sind seit Dart 3.10 production-ready** und können Rust-Code automatisch kompilieren und ins Flutter-Bundle einbinden. Aktueller Stack: Flutter 3.41.9, Dart 3.11.5, Rust 1.95.0.

2. **jj-lib (v0.41.0) ist explizit für externe GUI-Nutzung gedacht**, hat aber keine Stabilitätsgarantien (pre-1.0). Referenz-Implementation [JayJay](https://github.com/hewigovens/jayjay) zeigt erfolgreichen Einsatz mit einem Adapter-Crate-Pattern.

3. **rmcp (v1.7.0) als separates Rust-Binary** — produktionsreif (3.4k Stars, Sampling/Subscriptions/etc.), mit der macOS-App gebündelt und vom MCP-Host (Claude Desktop o.ä.) via stdio gestartet. Teilt sich den `zanshin-jj`-Crate mit dem Flutter-Frontend.

4. **flutter_rust_bridge ist nicht empfehlenswert für dieses Projekt** — Ralph hat negative Erfahrung mit dem Version-Churn-Aufwand. Der `cbindgen`+`ffigen`-Weg ist langfristig wartungsärmer und entkoppelt.

5. **Aggregator-Crate-Pattern + Cargo Workspace** — interne Crates bleiben modular, aber Dart Hooks bauen nur den einen `zanshin-ffi`-Crate (cdylib), der alle internen `extern "C"`-APIs re-exportiert.

6. **Build-Orchestrierung mit `cargo-make`** — alle Build-Schritte (Flutter, Cargo, Bundle-Assembly, Codesign) deklarativ in `Makefile.toml`. Keine versteckte Logik in Xcode-XML. Aufruf: `cargo make build`.

7. **Change-Detection per Filesystem-Watcher (Dart `watcher`)** — kein IPC zwischen MCP-Server und Flutter-App nötig. Flutter beobachtet zwei jj-Pfade (Empfehlung des jj-Maintainers in [#6646](https://github.com/jj-vcs/jj/discussions/6646)): `.jj/repo/op_heads/heads/` als primärer Trigger für State-Mutationen, `.jj/repo/working_copy/checkout` als sekundärer Heartbeat. Cross-platform (macOS/Linux/Windows) durch Plattform-Abstraktion im `watcher`-Paket.

### Strategische Empfehlungen

1. **Direkte jj-lib-Integration (kein CLI-Scraping)** — strukturierte Daten kritisch für MCP-Tools und FFI-Wrapper
2. **`zanshin-jj` Adapter-Crate als Anti-Corruption-Layer** — schützt vor pre-1.0 jj-lib-API-Änderungen; wird von Flutter-App UND MCP-Binary geteilt
3. **MCP Server als separates Rust-Binary mit `rmcp`** — produktionsreife API, eigenständig testbar, sauber getrennt von der GUI
4. **Aggregator-Crate (`zanshin-ffi`)** als einziger cdylib-Crate — interne Workspace-Struktur bleibt modular, Dart Hooks bleiben simpel
5. **Sync FFI + `Isolate.run`** statt Async-Codegen-Magie — einfacher, transparenter, weniger Abhängigkeiten
6. **Generierten Code (ffigen-Output) committen, nicht bei jedem Build neu erzeugen** — reproduzierbare Builds, lesbare Diffs

7. **`cargo-make` als Build-Orchestrator** — alle Schritte (flutter build, cargo build, Bundle-Assembly, Codesign) als deklarative Tasks; kein Build-Code in Xcode versteckt

8. **Filesystem-Watcher statt IPC** — Flutter beobachtet `.jj/repo/op_heads/heads/` via `watcher`-Paket; MCP-Server bleibt stateless. Keine Notifications, keine Subscription-Logik, keine Locking-Probleme — die Filesystem-Mutation IST der Notification-Kanal

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
   - Dart ↔ Rust FFI-Kommunikationsmuster
   - Dart Hooks Build-Integration
   - MCP-Protokoll-Integration
   - Datenformate und Kommunikationsstandards
4. [Architectural Patterns and Design](#architectural-patterns-and-design)
   - System-Architektur: Schichtenmodell
   - Design-Entscheidung: jj-lib direkt vs. CLI-Scraping
   - Erweiterbarkeit: Cargo Workspace Architektur
   - Deployment und Build-Architektur (macOS)
5. [Implementation Approaches and Technology Adoption](#implementation-approaches-and-technology-adoption)
   - Konkrete Projektstruktur (Grundgerüst)
   - Umsetzungsschritte für das Grundgerüst
   - Testing-Strategie
   - Risikobewertung
6. [Research Methodology and Sources](#research-methodology-and-sources)

---

## Research Overview

Diese Recherche wurde am 2026-05-15 durchgeführt, basierend auf offiziellen Quellen (dart.dev, pub.dev, crates.io, GitHub-Repositories, JJ-Dokumentation). Versionsstand wurde vom Nutzer verifiziert: Flutter 3.41.9, Dart 3.11.5, Rust 1.95.0. Confidence-Level ist hoch für alle Toolchain-Komponenten (offizielle Pakete), mittel für jj-lib-Stabilitätsfragen (pre-1.0, keine API-Garantien).

Untersuchte Quellen umfassen:
- Dart Hooks Dokumentation und Dart 3.10 Release-Announcement
- pub.dev-Pakete: `dart_mcp`, `native_toolchain_rust`, `ffigen`
- crates.io: `jj-lib`, `rmcp`
- GitHub-Repos: `jj-vcs/jj`, `modelcontextprotocol/rust-sdk`, `hewigovens/jayjay`
- JJ-Architekturdokumentation (docs.jj-vcs.dev)
- Community-Tools-Liste (JJ-Dokumentation)

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

<!-- Content will be appended sequentially through research workflow steps -->

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

Für Zanshin (Flutter statt SwiftUI) ist der gleiche Rust-Core-Ansatz anzuwenden, aber mit `flutter_rust_bridge` statt UniFFI als FFI-Bridge.

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

2. **Vollständiger MCP-Feature-Set:** Sampling, Subscriptions, Tasks, Completions und Roots sind in rmcp implementiert; dart_mcp fehlen mehrere davon. Auch wenn der Initial-MVP nur Tools+Resources braucht — zukünftige Erweiterungen sind ohne Stack-Wechsel möglich.

3. **Direkter jj-lib-Zugriff:** Der MCP-Server nutzt `zanshin-jj` direkt als Rust-Crate, ohne FFI-Layer dazwischen. Performanter und debugbarer als der Umweg über Dart.

4. **Saubere Trennung:** Flutter-App = GUI; `zanshin-mcp` = MCP-Server. Beide sind unabhängig entwickel- und testbar. MCP-Server lässt sich ohne Flutter-Setup mit `cargo run -p zanshin-mcp` starten — wichtig für CI und schnelle Iteration.

5. **MCP-Server-Pattern ist von Natur aus Subprocess-basiert:** Die meisten MCP-Hosts (Claude Desktop, Cursor) spawnen den MCP-Server ohnehin als Subprocess via stdio. Eine separate Binary ist also der natürlichere Architekturansatz, nicht der unnatürliche.

6. **Single Binary, keine Runtime-Dependencies:** rmcp kompiliert zu einer statischen Binary — wird einfach mit der macOS-App in `Contents/MacOS/zanshin-mcp` gebündelt.

**Trade-off:** Mehr Rust-Code im Projekt — aber durch Cargo Workspace organisiert und mit klarer Verantwortung. Ralph's Dart/Flutter-Fokus bleibt auf der GUI; die Rust-Seite ist durch den `zanshin-jj`-Crate für beide Konsumenten (Flutter-FFI und MCP-Binary) bereits notwendig.

---

### Development Tools und Build System

**Flutter macOS Desktop**
- Vollständig unterstützt seit Flutter 2.x
- Kein FVM oder Version-Manager nötig — systemweites Flutter reicht
- `flutter build macos` für Release-Builds

**Cargo Workspace**
Für die Rust-Seite empfiehlt sich ein Cargo Workspace im Dart-Paket-Root. Das ermöglicht:
- Mehrere Rust-Crates in einem Workspace (jj-lib-Wrapper + zukünftige Crates)
- Geteilte Dependencies über `[workspace.dependencies]`
- Ein gemeinsames `target/`-Verzeichnis (schnellere Builds)

Struktur für Erweiterbarkeit:
```
rust/                        ← Cargo Workspace root
  Cargo.toml                 ← [workspace] definition
  Cargo.lock
  zanshin-jj/                ← jj-lib wrapper crate
    Cargo.toml
    src/lib.rs
  # future-crate/            ← zukünftige Rust-Crates hier
rust-toolchain.toml          ← gepinnte Rust-Version (für native_toolchain_rust)
hook/build.dart              ← Dart Hook für Rust-Build
```

_Source: [native_toolchain_rust on pub.dev](https://pub.dev/packages/native_toolchain_rust), [flutter_rust_bridge on pub.dev](https://pub.dev/packages/flutter_rust_bridge)_

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

Da `dart:ffi`-Aufrufe synchron sind und jj-lib-Operationen (Clone, Fetch, große Diffs) blockieren können, ist Isolate-basierte Ausführung Pflicht:

```
Flutter UI (Dart Main Isolate)
    ↓ Isolate.run(() => sync FFI call)
Worker Isolate (Dart)
    ↓ synchroner dart:ffi-Call
.dylib (zanshin-jj)
    ↓ Rust API call
jj-lib
    ↑ result
.dylib
    ↑ Rückgabewert
Worker Isolate
    ↑ Future completes
Flutter UI
```

**Alternative für Progress-Updates:** `dart:ffi`'s `NativeCallable.listener` erlaubt Rust→Dart-Callbacks (z.B. für Fortschritts-Notifications bei langen Operationen). Komplexer einzurichten, aber für Use Cases wie Fetch-Progress oder Streaming-Logs sinnvoll.

_Source: [Dart FFI Documentation](https://dart.dev/interop/c-interop), [Using Dart FFI to access native libraries](https://blog.logrocket.com/dart-ffi-native-libraries-flutter/)_

---

### Dart Hooks Build-Integration: Cargo Workspace Pattern

Die Integration von `native_toolchain_rust` in Dart Hooks funktioniert über eine `hook/build.dart`-Datei. Für Zanshin mit einem Cargo-Workspace (ein Root, mehrere Crates) gilt folgendes Muster:

**Dart-Hook-Seite (`hook/build.dart`):**
Der `RustBuilder` aus `native_toolchain_rust` wird für jeden Crate im Workspace einzeln instanziiert. Konkretes Muster:

```dart
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await RustBuilder(
      assetName: 'src/zanshin_jj_bindings.g.dart',
    ).run(input: input, output: output);
    // Weitere RustBuilder für zusätzliche Crates hier ergänzen
  });
}
```

Der Hook kann mehrere Builder aufrufen — Feature für zukünftige Rust-Crates.

**Cargo-Workspace-Seite (`rust/Cargo.toml`):**
Ein Workspace-Root mit `[workspace]`-Sektion definiert alle Member-Crates. Alle Crates teilen sich ein `target/`-Verzeichnis und eine `Cargo.lock`. Neue Crates werden lediglich zur `members`-Liste hinzugefügt — der Dart-Hook erbt diese Struktur automatisch.

Erweiterbarkeit für zukünftige Rust-Crates:
1. Neuen Crate im `rust/`-Verzeichnis anlegen
2. In `rust/Cargo.toml` unter `[workspace] members` eintragen
3. In `hook/build.dart` einen weiteren `RustBuilder` für den neuen Crate hinzufügen

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

_Source: [MCP Architecture](https://modelcontextprotocol.io/docs/learn/architecture), [dart_mcp on pub.dev](https://pub.dev/packages/dart_mcp), [MCP Transports](https://www.speakeasy.com/mcp/core-concepts/transports)_

---

### Filesystem-Watching: Change-Detection ohne IPC

**Designprinzip:** MCP-Server und Flutter-App brauchen **keinen** direkten IPC-Kanal. Jede Mutation läuft über jj-lib, jj-lib persistiert sie sofort im `.jj/`-Verzeichnis. Die Flutter-App beobachtet `.jj/` mit einem Filesystem-Watcher — und merkt damit automatisch jede Änderung, egal von welchem Prozess.

**jj's Auto-Snapshot-Verhalten (entscheidend für die Strategie):**

Anders als Git macht jj bei *jedem* Befehl automatisch einen Snapshot des Working-Trees:
> "Unlike most other VCSs, Jujutsu will automatically create commits from the working-copy contents when they have changed. Most jj commands will commit the working-copy changes if they have changed."

Bedeutet konkret:
- Neue Dateien (nicht in `.gitignore`) werden **automatisch getrackt** durch `snapshot.auto-track`-Default
- Jeder jj-Befehl (auch read-only wie `jj log`, `jj status`) snapshottet zuerst
- Jeder Snapshot erzeugt eine Operation → `op_heads/heads/` ändert sich

**Konsequenz für unsere Architektur:** Wir brauchen **keinen Working-Tree-Watcher**. Externe File-Edits werden automatisch sichtbar, sobald *irgendein* jj-Befehl läuft — und das passiert ohnehin:
- Beim App-Open: Zanshin ruft `jj_status`/`jj_log` → Snapshot → op_heads update
- Beim Refresh: derselbe Flow
- Bei jedem MCP-Tool-Aufruf: jj-lib snapshottet → op_heads update

**Was wir wo beobachten:**

Bestätigt durch jj-Maintainer-Empfehlung in [jj-vcs/jj#6646](https://github.com/jj-vcs/jj/discussions/6646): beide unten genannten `.jj/`-Pfade sind zuverlässige Watcher-Targets.

| Pfad | Wann ändert sich's | Watcher-Rolle |
|---|---|---|
| `.jj/repo/op_heads/heads/` | Bei jeder *echten* Repo-Mutation (neue Operation) | **Primärer Watcher** — bei Event: UI-State aus jj-lib neu laden |
| `.jj/repo/working_copy/checkout` | Bei **jeder** jj-Aktivität (auch read-only Operations) — laut martinvonz: "We update that even if the working copy doesn't change" | **Sekundärer Watcher** — "jj war aktiv"-Heartbeat; macht uns gegen stale-state robuster (z.B. wenn andere GUI/CLI parallel läuft) |
| `.jj/repo/op_store/operations/` | Append-only Operation-Historie | Nicht beobachten — bei Bedarf gemeinsam mit op_heads-Update lesen |
| Working-Tree-Dateien | User-Edits außerhalb von jj | **Kein Watcher nötig** — wird durch jj's Auto-Snapshot abgedeckt, sobald die App den nächsten jj-Befehl absetzt (App-Open, Refresh, Focus) |

**Wichtige Klarstellung zu externen Edits:** Wenn der User eine Datei im Editor ändert und KEIN jj-Befehl läuft, feuert weder `op_heads` noch `working_copy/checkout`. Die externe Änderung wird erst sichtbar, wenn die Flutter-App den nächsten jj-Befehl absetzt — dann snapshottet jj automatisch und `op_heads` (sowie `working_copy/checkout`) ändern sich. Für MVP-UX reicht das, weil jj-Befehle bei App-Open, Refresh-Button und Window-Focus ausgelöst werden. Für eine wirklich reaktive Erkennung externer Edits müsste jj's eingebauter `fsmonitor` aktiviert werden (Watchman oder jj's native Implementation) — das ist eine spätere Optimierungs-Option.

**Tool-Auswahl: Dart `watcher` vs. Rust `notify` via FFI**

Untersucht wurden zwei Optionen:

| Aspekt | Dart `watcher` v1.2.1 | Rust `notify` (notify-rs) |
|---|---|---|
| Implementation-Komplexität | **Niedrig** (Stream-API in Dart) | Hoch (FFI-Callbacks via `NativeCallable.listener`, manuelles Threading-Lifecycle) |
| Reife / Adoption | Solide (~9,4M downloads, tools.dart.dev) | **Sehr hoch** (Deno, Rust-Analyzer, Cargo Watch, Zed) |
| Plattform-Backends | FSEvents (macOS), inotify+polyfill (Linux), RDCW (Windows) | FSEvents/**kqueue** (macOS), inotify (Linux), RDCW (Windows), **polling fallback** |
| Linux rekursiv | Polyfilled (langsam für große Trees) | Polyfilled (gleiche Limitation, inotify-bedingt) |
| Debouncer | Eingebaut, basic | `notify-debouncer-mini`/`-full` (ausgereifter) |
| Integration | Pure Dart, GC-managed | Rust→Dart-Callback, manuelles Lifecycle-Mgmt |
| Crash-Resistenz | Dart-Isolate isoliert | FFI-Crash crasht die Flutter-App |

**Entscheidung: Dart `watcher`.**

Begründung:
- Der Watcher wird **nur von der Flutter-App** gebraucht (nicht vom MCP-Server, der stateless ist). Es gibt keinen Grund, ihn über FFI in Rust zu implementieren.
- Vorteile von notify-rs (kqueue-Option, Polling-Fallback) treffen unseren Use Case nicht — wir beobachten ein einziges, winziges Verzeichnis (`op_heads/heads/`).
- FFI-Callback-Setup (`NativeCallable.listener`) ist nicht trivial und bringt für diesen Anwendungsfall keinen Mehrwert.
- Dart `watcher` integriert sich direkt in den Flutter State-Management-Flow ohne FFI-Boundary.

API-Pattern (Dart, zwei parallele Watcher):
```dart
// Primärer Watcher: echte State-Mutationen
final opHeads = DirectoryWatcher('.jj/repo/op_heads/heads');
opHeads.events.listen((event) {
  // Repo-State hat sich geändert → vollständigen UI-Refresh triggern
});

// Sekundärer Watcher: jj-Aktivitäts-Heartbeat
final checkout = FileWatcher('.jj/repo/working_copy/checkout');
checkout.events.listen((event) {
  // jj war aktiv (auch ohne State-Change) — Hinweis dass parallel jj-Aktivität läuft
  // → optional: leichtgewichtigen Status-Reload triggern
});
```

**Architektur-Konsequenz:**

```
┌──────────────────────────────────────────────────────────────┐
│  Flutter App (Dart)                                           │
│                                                               │
│  ┌────────────────┐    ┌─────────────────────────────────┐   │
│  │  watcher       │───▶│ "op_heads changed!" → reload UI │   │
│  │  package       │    └─────────────────────────────────┘   │
│  └────────────────┘                                          │
│  Watches: .jj/repo/op_heads/heads/                            │
└──────────────────────────────────────────────────────────────┘
              ▲                                ▲
              │ FS event                       │ FS event
              │                                │
┌─────────────┴────────────┐    ┌──────────────┴───────────────┐
│  zanshin-mcp (Rust)      │    │  user@cli, andere GUIs, etc. │
│  - Tool call             │    │                              │
│  - jj-lib → neue Op      │    │                              │
└──────────────────────────┘    └──────────────────────────────┘
```

Vorteile:
- Funktioniert für **alle** Mutations-Quellen (MCP, CLI, andere GUIs, Editoren via jj)
- Kein Inter-Process-Locking
- Saubere Lifecycle-Trennung: MCP-Server läuft nur wenn AI-Host ihn spawnt; Flutter-App eigenständig
- Plattform-übergreifend identische Logik (Dart `watcher` abstrahiert OS-Backends)
- Keine Notification-Subscription-Mechanik im MCP-Protokoll nötig

**Working-Copy-Detection (vereinfacht durch jj's Auto-Snapshot):**

Da jj bei jedem Befehl automatisch einen Working-Copy-Snapshot macht, ist die Strategie minimal:

- **MVP:** Bei UI-Events (App-Open, Refresh-Button, Window-Focus) ruft Zanshin einfach `jj_status` o.ä. auf. jj-lib snapshottet automatisch → op_heads ändert sich → unser FS-Watcher feuert → UI lädt neu. Keine separate Mechanik nötig.
- **Optional später:** jj's eingebauten `fsmonitor` aktivieren (Watchman oder jj's eigene Implementation). Für große Repos performanter; ohne fsmonitor scannt jj bei jedem Snapshot den Working-Tree.

**NICHT empfohlen:** Eigenes Working-Tree-Watching in Dart oder Rust. Würde die Snapshot-Logik duplizieren und Edge-Cases (`.gitignore`, Conflicts, externe Tools) selbst lösen müssen — Dinge, die jj-lib bereits korrekt handhabt.

_Source: [watcher on pub.dev](https://pub.dev/packages/watcher), [notify-rs GitHub](https://github.com/notify-rs/notify), [JJ Architecture](https://docs.jj-vcs.dev/latest/technical/architecture/), [JJ Working Copy](https://docs.jj-vcs.dev/latest/working-copy/), [JJ Operation Log](https://docs.jj-vcs.dev/latest/operation-log/)_

---

### Datenformate und Kommunikationsstandards

**Dart ↔ Rust (intern):**
- `flutter_rust_bridge` serialisiert Daten automatisch via eigenes Wire-Format (kein manuelles JSON nötig)
- Komplexe Typen (Structs, Enums, Vecs) werden direkt gemapped
- Für jj-lib-Datenstrukturen (Commits, Trees, Diffs) werden Dart-Wrapper-Klassen auto-generiert

**MCP (extern):**
- JSON-RPC 2.0 über stdio
- MCP-Protokoll-Versionen: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25
- `dart_mcp` v0.5.1 unterstützt alle vier Versionen mit per-version capability gating

_Source: [dart_mcp on pub.dev](https://pub.dev/packages/dart_mcp), [flutter_rust_bridge on pub.dev](https://pub.dev/packages/flutter_rust_bridge)_

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
  zanshin-jj/         ← jj-lib adapter (MVP)
    Cargo.toml        ← crate-type = ["staticlib", "cdylib"]
    src/lib.rs        ← flutter_rust_bridge API surface
  # zukünftig:
  # zanshin-crypto/   ← z.B. Signierung
  # zanshin-network/  ← z.B. Remote-Operationen
```

Jeder neue Crate:
1. wird im Workspace definiert
2. erhält einen eigenen `RustBuilder`-Eintrag in `hook/build.dart`
3. bekommt auto-generierte Dart-Bindings durch `flutter_rust_bridge_codegen`

_Source: [Cargo Workspaces](https://doc.rust-lang.org/book/ch14-03-cargo-workspaces.html), [native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust)_

---

### Deployment und Build-Architektur (macOS)

**Build-Pipeline:**
```
flutter build macos
  → Dart Hooks werden ausgelöst
  → hook/build.dart: RustBuilder kompiliert rust/zanshin-jj/
  → .dylib wird in macOS App Bundle eingebunden
  → flutter_rust_bridge Bindings linken zur .dylib
  → Flutter App Bundle (.app) ist self-contained
```

**Voraussetzungen auf Entwicklermaschine:**
- Flutter (stable, systemweit)
- Rust via rustup (stable, gepinnte Version via rust-toolchain.toml)
- Xcode (für macOS Build)
- Kein zusätzliches Build-System nötig (kein CMake, kein Makefile)

**Skalierung zu anderen Plattformen:** Da nur macOS getestet werden kann, sollte die Architektur keine macOS-spezifischen Annahmen treffen — flutter_rust_bridge und native_toolchain_rust unterstützen prinzipiell auch Linux und Windows.

_Source: [Dart Hooks Documentation](https://dart.dev/tools/hooks)_

---

## Implementation Approaches and Technology Adoption

### Konkrete Projektstruktur (Grundgerüst)

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
│   │   │   └── jj_facade.dart        ← idiomatische Dart-API
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
│   ├── zanshin-ffi/                  ← Aggregator-Crate (cdylib für Dart)
│   │   ├── Cargo.toml                ← crate-type = ["cdylib", "staticlib"]
│   │   ├── cbindgen.toml             ← Header-Generierungs-Config
│   │   ├── build.rs                  ← cbindgen-Aufruf erzeugt header.h
│   │   ├── include/
│   │   │   └── zanshin_ffi.h         ← cbindgen-Output (committed)
│   │   └── src/lib.rs                ← extern "C" API; ruft zanshin-jj auf
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

### Umsetzungsschritte für das Grundgerüst

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

**8. Dart-Facade-Layer (`lib/src/native/jj_facade.dart`)**
Über den auto-generierten Bindings ein hand-geschriebener Dart-Wrapper, der:
- Memory-Management kapselt (`Finalizer<Pointer>` für automatisches `free_xyz`)
- Sync FFI-Calls in `Isolate.run(() => ...)` wrappt → liefert `Future<T>`
- Idiomatische Dart-Klassen (`Repository`, `Commit`) statt rohe `Pointer`s exponiert
- Errors aus Result-Codes in Dart-Exceptions umwandelt

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

_Source: [Apple Developer Forums - Codesigning helper executables](https://developer.apple.com/forums/thread/655881), [Tauri macOS Application Bundle docs](https://v2.tauri.app/distribute/macos-application-bundle/)_

_Source: [Dart Hooks](https://dart.dev/tools/hooks), [native_toolchain_rust example](https://github.com/GregoryConrad/native_toolchain_rs/tree/main/examples/dart_only), [ffigen on pub.dev](https://pub.dev/packages/ffigen), [rmcp on docs.rs](https://docs.rs/rmcp)_

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

**MCP-Protokoll-Tests**
- E2E-Tests: dart_mcp-Server als Subprocess starten, JSON-RPC-Requests senden, Antworten verifizieren
- Kann als Dart-CLI-Tool ohne Flutter-UI laufen (wichtig für CI)

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

_Source: [JJ Architecture](https://docs.jj-vcs.dev/latest/technical/architecture/), [dart_mcp on pub.dev](https://pub.dev/packages/dart_mcp)_

---

## Research Methodology and Sources

### Methodik

Alle Aussagen wurden gegen Live-Quellen (Stand 2026-05-15) verifiziert. Versionsangaben aus Blog-Artikeln wurden gegen offizielle Releases gegengeprüft; der Nutzer hat die Toolchain-Versionen (Flutter 3.41.9, Dart 3.11.5, Rust 1.95.0) bestätigt. Confidence-Level:

- **Hoch:** Offizielle Pakete (dart_mcp, ffigen, native_toolchain_rust, rmcp, jj-lib), Architektur-Dokumentation
- **Mittel:** jj-lib-API-Stabilität (pre-1.0, keine Garantien), dart_mcp-Reife (experimental)
- **Niedrig:** Multi-Crate-Workspace-Support in native_toolchain_rust (Dokumentation fokussiert auf Single-Crate; Workspace-Pattern empirisch ableitbar, aber nicht offiziell dokumentiert)

### Quellenverzeichnis

**Offizielle Toolchain-Dokumentation:**
- [Dart Hooks Documentation](https://dart.dev/tools/hooks)
- [Announcing Dart 3.10](https://dart.dev/blog/announcing-dart-3-10)
- [Dart FFI / C-Interop](https://dart.dev/interop/c-interop)
- [Flutter Architectural Overview](https://docs.flutter.dev/resources/architectural-overview)

**Pub.dev Pakete:**
- [dart_mcp](https://pub.dev/packages/dart_mcp) (v0.5.1)
- [native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust) (v1.0.4)
- [ffigen](https://pub.dev/packages/ffigen) (v20.1.1)
- [watcher](https://pub.dev/packages/watcher) (v1.2.1)

**JJ VCS:**
- [jj-vcs GitHub Repository](https://github.com/jj-vcs/jj)
- [jj-lib on crates.io](https://crates.io/crates/jj-lib) (v0.41.0)
- [JJ Architecture Documentation](https://docs.jj-vcs.dev/latest/technical/architecture/)
- [JJ Working Copy Documentation](https://docs.jj-vcs.dev/latest/working-copy/)
- [JJ Operation Log Documentation](https://docs.jj-vcs.dev/latest/operation-log/)
- [JJ Community Tools](https://docs.jj-vcs.dev/latest/community_tools/)
- [jj-vcs/jj#6646: GUI watcher recommendations](https://github.com/jj-vcs/jj/discussions/6646)
- [JayJay (Reference macOS GUI)](https://github.com/hewigovens/jayjay)

**Filesystem-Watching:**
- [Dart watcher package on pub.dev](https://pub.dev/packages/watcher) (v1.2.1)
- [notify-rs on GitHub](https://github.com/notify-rs/notify) (v2.1.0)

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
- **macOS-spezifische Codesign-/Notarization-Schritte für distributed Apps:** Nicht im Scope dieser Recherche (Grundgerüst, lokale Entwicklung); für signierte Distribution Apple Developer Account und ggf. eigene Notarization-Tasks im Makefile.toml nötig
- **Aggregator-Crate + native_toolchain_rust:** Es ist plausibel und dokumentiert-konform, aber kein konkretes Public-Beispiel für genau dieses Pattern verifiziert

---

## Conclusion

Die Recherche zeigt einen klaren, gut begründeten Weg für Zanshin:

**Build-Stack:** `native_toolchain_rust` + `cbindgen` + `ffigen` — drei offizielle, voneinander unabhängige Tools, verbunden über die stabile C-ABI. Kein flutter_rust_bridge.

**Rust-Architektur:** Cargo Workspace mit drei initialen Crates:
- `zanshin-jj` — idiomatische Rust-API über jj-lib (Anti-Corruption-Layer)
- `zanshin-ffi` — Aggregator-cdylib mit `extern "C"`-API für Dart Hooks
- `zanshin-mcp` — separate Binary mit rmcp MCP-Server

Interne Crates teilen `zanshin-jj` als Library-Dependency. Erweiterung um zusätzliche Rust-Crates ist transparent: neu im Workspace eintragen, aus `zanshin-ffi`/`zanshin-mcp` aufrufen — keine Build-System-Änderungen nötig.

**MCP-Integration:** `rmcp` als separates Rust-Binary, mit der macOS-App gebündelt. Produktionsreif, vollständiger Feature-Set, direkter jj-lib-Zugriff ohne Dart-Umweg, eigenständig testbar.

**Async-Strategie:** Sync FFI über `Isolate.run` — keine Async-Codegen-Magie, transparente Kontrolle über den Threading-Lifecycle.

**Build-Orchestrierung:** `cargo-make` mit `Makefile.toml` — alle Build-Tasks (Flutter, Cargo, Bundle-Assembly, Codesign) als deklarative TOML-Tasks. Keine Build-Logik in Xcode-XML versteckt; alles transparent im Repo.

**Change-Detection:** Filesystem-Watcher in Dart auf `.jj/repo/op_heads/heads/` via `watcher`-Paket. Kein IPC zwischen Flutter-App und MCP-Server nötig — die Filesystem-Mutation ist der Notification-Kanal. Funktioniert plattformübergreifend (FSEvents/inotify/ReadDirectoryChangesW transparent abstrahiert).

**Risiko-Bewusstsein:** jj-lib ist pre-1.0. Der `zanshin-jj`-Adapter-Crate schützt die beiden Konsumenten (`zanshin-ffi`, `zanshin-mcp`) vor API-Drift.

Das Grundgerüst kann jetzt umgesetzt werden — entweder als nächster Schritt durch konkrete Stories/Tasks (BMad workflow: `bmad-create-prd` → `bmad-create-architecture` → `bmad-create-epics-and-stories`) oder durch direkte Implementierung.

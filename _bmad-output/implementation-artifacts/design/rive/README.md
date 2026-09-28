> **Hinweis:** Die Bewegung wurde inzwischen geaendert (ein Durchlauf + Pause, Berge uebereinander)
> und liegt als fertige **Lottie-Datei** in `../lottie/` — damit brauchst du Rive nicht.
> Die Anleitung unten beschreibt noch die alte Version mit unterschiedlich schnell wandernden Wellen.

# Nami · Indigo — Wellen-Animation in Rive

Ziel: die drei Linien wandern als Meereswellen endlos nach links, unterschiedlich schnell.
Das Prinzip ist absichtlich simpel — **keine Vertex-Animation nötig**, nur je eine X-Translation.

## Dateien
- `Nami Indigo Waves.svg` — Import-Art. Jede Welle ist ein eigener, **768 px breiter** Sinus-Pfad
  in einer eigenen Gruppe (`Wave-Top`, `Wave-Mid`, `Wave-Bottom`), plus `Background`.
  Alle Wellenlängen teilen 256 — deshalb ist eine Verschiebung um **genau −256 px** ein nahtloser Loop.
- `nami_wave.dart` — dieselbe Animation als Flutter `CustomPainter`, falls du Rive überspringen willst.

## Schritte im Rive-Editor (ca. 5 Min)
1. Neues File → Artboard **256 × 256**.
2. `Nami Indigo Waves.svg` per Drag & Drop importieren. Artboard-Größe auf 256×256 lassen.
3. Auf dem Artboard **Clipping** setzen: Rect 256×256, Corner Radius 58, als Clip für die drei Wellen-Gruppen
   (der Import bringt das Clip-Rect bereits mit; sonst `Background`-Rect als Clipping Source wählen).
4. Neue **Timeline** anlegen, Name `waves`, Loop-Mode **Loop**.
5. Pro Welle zwei Keys auf **X (Translation)** der Gruppe:

   | Gruppe        | Key @ 0s | Key @ Ende | Dauer  | Interpolation |
   |---------------|----------|-----------|--------|---------------|
   | Wave-Top      | X = 0    | X = −256  | 3.6 s  | Linear        |
   | Wave-Mid      | X = 0    | X = −256  | 5.0 s  | Linear        |
   | Wave-Bottom   | X = 0    | X = −256  | 7.0 s  | Linear        |

   Wichtig: **Linear**, nicht Ease — sonst stockt der Loop am Übergang.
   Verschiedene Timeline-Längen pro Welle: entweder drei Animationen, die im State Machine
   parallel laufen, oder eine 36-s-Timeline (kleinstes gemeinsames Vielfaches ≈ 126 s → praktikabler:
   je Welle eine eigene Animation, alle im State Machine gleichzeitig aktiv).
6. Optional das „Heben und Senken": zusätzlich **Y (Translation)** je Gruppe, ±0.6 / ±0.8 / ±1.1 px,
   Ease In-Out, Dauer 7 s, Loop **Ping-Pong**.
7. State Machine `Idle` anlegen, alle Wellen-Animationen als gleichzeitig laufende Layer.
8. Export → **Runtime (.riv)**.

## Einbinden in Flutter
```yaml
dependencies:
  rive: ^0.13.0
flutter:
  assets:
    - assets/nami_indigo.riv
```
```dart
RiveAnimation.asset(
  'assets/nami_indigo.riv',
  stateMachines: ['Idle'],
  fit: BoxFit.contain,
)
```

## Live-Vorlage
`../Nami Indigo Animated.html` zeigt die Animation mit Reglern für Amplitude, Tempo,
Wellenlänge und Hub — die Werte-Tabelle dort entspricht 1:1 den Rive-Werten oben.

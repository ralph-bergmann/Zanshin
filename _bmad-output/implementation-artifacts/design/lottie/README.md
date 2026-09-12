# Nami · Indigo — Ladeanimation (Lottie) · FINAL

Animiert werden die exakten Pfade des App-Logos aus `../Zanshin App Icon.html`
(quadratische Bezier-Kurven, inkl. Knick am rechten Auslauf) — nur vertikal versetzt,
die Silhouette bleibt also erhalten. Ein Schwung laeuft von links nach rechts durch und hebt
die Linien dort an, wo er vorbeikommt; danach kurze Pause. Im Ruhezustand steht Pixel fuer
Pixel das statische Logo.

## Finale Werte
| Parameter | Wert |
|---|---|
| Hub (`lift`) | 20.5 Design-Einheiten (Basis 256) |
| Breite des Schwungs (`spread`, σ der Gauss-Kurve) | 40 |
| Durchlauf | 1.30 s |
| Pause | 0.55 s |
| Gesamtlaenge | 1.85 s → 56 Frames @ 30 fps |
| Artboard | 256 × 256 |

Bewegungsgleichung pro Punkt (x, y) des Logo-Pfads, waehrend des Durchlaufs mit Fortschritt p ∈ [0,1]:

```
ease = 0.5 - 0.5 * cos(p * π)          // easeInOutSine
cx   = (22 - 40*1.7) + ease * ((234 + 40*1.7) - (22 - 40*1.7))
u    = (x - cx) / 40
y'   = y - 20.5 * exp(-u²)
```

Waehrend der Pause gilt `y' = y` (statisches Logo).

## Dateien
| Datei | Inhalt |
|---|---|
| `nami_loader.json` | Wellen + Indigo-Hintergrund mit 58 px Radius — das komplette Icon |
| `nami_loader_transparent.json` | nur die drei Wellen, transparent — fuer eigene Hintergruende |
| `nami_loader_pulse.json` | Variante: die ganze Wellenform atmet gleichzeitig auf und ab |

Alle Pfade sind Frame fuer Frame gebacken (31 Vertices pro Linie, 57 Keyframes) —
laeuft in lottie-web, lottie-android/iOS und im Flutter-Package identisch, nahtloser Loop.
Layer-Reihenfolge: `Wave Top`, `Wave Mid`, `Wave Bottom`, `Background`.

## Flutter

```yaml
dependencies:
  lottie: ^3.1.2
flutter:
  assets:
    - assets/lottie/nami_loader.json
```

```dart
Lottie.asset(
  'assets/lottie/nami_loader.json',
  width: 96,
  height: 96,
  repeat: true,
)
```

Nur waehrend eines Ladevorgangs animieren:

```dart
Lottie.asset(
  'assets/lottie/nami_loader.json',
  controller: _controller, // AnimationController(vsync: this)
  onLoaded: (c) => _controller..duration = c.duration..repeat(),
)
```

## Ohne Asset
`../rive/nami_wave.dart` enthaelt dieselbe Animation als `CustomPainter`
(`NamiIndigoIcon(size: 96)`), Defaults identisch zu den finalen Werten oben.

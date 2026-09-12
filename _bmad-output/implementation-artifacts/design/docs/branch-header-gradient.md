# Branch-Header — Lane-Gradient (Logik + Dart)

## Problem
Ein pauschaler Weiß-Overlay (`white 20 % → transparent → schwarz 22 %`) über der Lane-Farbe
funktioniert nur bei dunklen, mittel gesättigten Farben (Grün, Lila). Bei einer bereits hellen,
stark gesättigten Basis (Blau `#3B82F6`, L ≈ 0.60) entsättigt das Weiß die obere linke Ecke —
sie wirkt milchig und „fremd" gegenüber der Grundfarbe.

## Regel
Beide Gradient-Stops werden **aus der Lane-Farbe abgeleitet**, nicht mit Weiß/Schwarz überlagert.
Der Hue bleibt konstant, nur L und S werden verschoben — und der Hub skaliert mit der Helligkeit:

| Stop | Formel | Wirkung |
|---|---|---|
| Highlight (oben links) | `L + 0.17 · (1 − L)^1.25`, `S · (0.90 + 0.14 · L)` | helle Basis → kaum Lift, dunkle Basis → deutlicher Lift; Sättigung bleibt, kein Neon |
| Basis (52 %) | Lane-Farbe unverändert | Identität der Lane |
| Shadow (unten rechts) | `L − (0.09 + 0.07 · L)`, `S · 1.04` | helle Basis → etwas mehr Tiefe, damit die Kante trägt |

Richtung: `158deg` — parallel zum Fenster-Canvas (`165deg`), leicht versetzt, damit Header und
Hintergrund nicht als ein Verlauf zusammenfallen.

Kosten: ein `LinearGradient` pro Header, statisch, `const`-fähig sobald die Lane-Farbe fix ist.

## Beispielwerte

| Lane | Basis | Highlight | Shadow |
|---|---|---|---|
| main | `#3B82F6` | `hsl(217 92.3% 64.4%)` | `hsl(217 94.4% 46.8%)` |
| develop | `#22C55E` | `hsl(142 71.6% 52.7%)` | `hsl(142 74.9% 34.1%)` |
| feature | `#A855F7` | `hsl(271 92.6% 71.6%)` | `hsl(271 94.9% 53.8%)` |

## Dart

```dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Highlight-/Shadow-Stop aus der Lane-Farbe ableiten.
/// Hue bleibt, L/S werden helligkeitsabhängig verschoben.
class LaneShade {
  final Color hi, base, lo;
  const LaneShade(this.hi, this.base, this.lo);

  factory LaneShade.of(Color base) {
    final hsl = HSLColor.fromColor(base);
    final l = hsl.lightness, s = hsl.saturation;

    final lift = 0.17 * math.pow(1 - l, 1.25).toDouble();
    final hi = hsl
        .withLightness((l + lift).clamp(0.0, 1.0))
        .withSaturation((s * (0.90 + 0.14 * l)).clamp(0.0, 1.0))
        .toColor();

    final drop = 0.09 + 0.07 * l;
    final lo = hsl
        .withLightness((l - drop).clamp(0.0, 1.0))
        .withSaturation((s * 1.04).clamp(0.0, 1.0))
        .toColor();

    return LaneShade(hi, base, lo);
  }

  /// 158°, passend zum Fenster-Canvas (165°).
  LinearGradient get gradient => LinearGradient(
        begin: const Alignment(-1, -1.15),
        end: const Alignment(1, 1.15),
        colors: [hi, base, lo],
        stops: const [0.0, 0.52, 1.0],
      );
}
```

Verwendung:

```dart
DecoratedBox(
  decoration: BoxDecoration(
    gradient: LaneShade.of(lane.color).gradient,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
  ),
  child: header,
)
```

`LaneShade.of` einmal pro Lane berechnen (Farbe ändert sich nur beim Umbenennen/Neuzuweisen der
Lane) und im Lane-Model cachen — dann bleibt der Header-Layer repaint-frei.

## Web-Fallback
`styles.css` liest `--branch-hi` / `--branch-lo` (von `laneShade()` in `app.jsx` gesetzt).
Fehlen sie, greift `color-mix(in oklch, var(--branch-color) 88%, white)` — hue-treu, aber ohne
Helligkeits-Skalierung.

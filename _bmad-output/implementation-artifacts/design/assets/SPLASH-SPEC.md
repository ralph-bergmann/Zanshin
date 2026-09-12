# Zanshin Splash Screen — Spezifikation für den Dart-Nachbau

Fazit vorweg: **Der Nachbau in Dart lohnt sich.** Alles außer dem Grain-Overlay ist mit
`Container`-Dekorationen, `Gradient`-Klassen und einem `CustomPainter` mit ca. 25 Zeilen
Pfad-Code darstellbar. Nur zwei Teile würde ich als Asset lassen bzw. weglassen:

| Teil | Empfehlung |
|---|---|
| Hintergrund-Verläufe | Dart (`Stack` aus `DecoratedBox`) — einfach |
| Wellen-Ornament | Dart (`CustomPainter`, quadratische Beziers) — einfach |
| Wortmarke ZANSHIN | Dart (`CustomPainter`, Strichpfade) — mittel, Pfaddaten unten |
| Kanji 残心 | echtes `Text`-Widget mit *Shippori Mincho* — nicht als Pfad nachbauen |
| Grain / Rauschen | weglassen oder als 128×128-PNG-Tile (`ImageShader`) — in Dart nicht sinnvoll berechenbar |

---

## 1. Maße

Karte 560 × 320 px, Radius 14 px. Alle folgenden Koordinaten beziehen sich auf dieses Rechteck.
Die Karte skaliert linear — bei 2× einfach alle Werte verdoppeln.

| Element | Position |
|---|---|
| Innenabstand oben/seitlich | 34 / 36 px |
| Lock-up (Kanji + Wortmarke) | horizontal zentriert, Versalhöhe-Baseline y = 141 |
| Kanji im Lock-up | 44 px, Shippori Mincho 500, letterSpacing 1.8 |
| Abstand Kanji → Wortmarke | 20 px |
| Wortmarke | Versalhöhe 38 px |
| Tagline | 14 px unter dem Lock-up, 11.5 px, w500, letterSpacing 1.96 (0.17em), uppercase |
| Trennlinie Fußzeile | y = 253, `#FFFFFF` @ 8 % |
| Version | x = 36, Baseline y = 276, JetBrains Mono 12 px |
| Statuszeile | rechtsbündig x = 524, 11.5 px |
| Ladeleiste | unterer Rand, Höhe 2 px |

## 2. Farben

```dart
const indigoTop    = Color(0xFF1D2540);
const indigoMid    = Color(0xFF131831);
const indigoBottom = Color(0xFF10142A);
const lift         = Color(0xFF6078B2); // kühles Aufhellen oben links
const warm         = Color(0xFFDCA85B); // warmes Gold unten rechts
const shade        = Color(0xFF090B16); // Abdunklung unten
const goldLight    = Color(0xFFFFF6E4);
const gold         = Color(0xFFF4CF80);
const goldMid      = Color(0xFFDCA85B);
const goldDeep     = Color(0xFFB58346);
const goldDark     = Color(0xFFD9A755);
const textVersion  = Color(0xFFE7DCC4);
const textDim      = Color(0xFF8792B4);
const textStatus   = Color(0xFF98A3C2);
const textTag      = Color(0xFFA9B3D0);
```

Der Splash ist bewusst **immer dunkel** — er wird nicht zwischen Day/Night umgeschaltet.
Die Karte bringt ihren eigenen Grund mit und steht auf hellem wie dunklem Desktop.

## 3. Hintergrund — vier gestapelte Verläufe

Reihenfolge von hinten nach vorne. Alle im selben `Stack`, jeweils volle Kartenfläche,
gemeinsam mit `ClipRRect(borderRadius: 14)` beschnitten.

**1 — Grundverlauf (linear, 160°)**
```dart
LinearGradient(
  begin: Alignment(-0.86, -1), end: Alignment(0.86, 1),
  colors: [indigoTop, indigoMid, indigoBottom], stops: [0, .72, 1])
```

**2 — kühles Aufhellen oben links (radial, elliptisch)**
Zentrum bei 8 % / 0 % der Kartenfläche, Radien 90 % Breite / 120 % Höhe.
```dart
RadialGradient(center: Alignment(-0.84, -1), radius: 1.0,
  colors: [lift.withOpacity(.34), lift.withOpacity(0)], stops: [0, .58])
```

**3 — warmes Gold unten rechts (radial)**
Zentrum 100 % / 100 %, Radien 70 % / 90 %.
```dart
RadialGradient(center: Alignment(1, 1), radius: 0.9,
  colors: [warm.withOpacity(.20), warm.withOpacity(0)], stops: [0, .60])
```

**4 — Abdunklung des Fußes (radial, Zentrum unterhalb der Karte)**
Zentrum 50 % / 118 %, Radien 120 % / 80 %.
```dart
RadialGradient(center: Alignment(0, 1.36), radius: 1.0,
  colors: [shade.withOpacity(.85), shade.withOpacity(0)], stops: [0, .65])
```

**Optional 5 — Conic-Sheen** (im HTML vorhanden, kaum sichtbar, kann entfallen):
`SweepGradient(center: Alignment(.56,-.64), startAngle: 200°)` mit Weiß bei 7 %, 0 %, 4 %, 0 %.

**Rahmen und Schatten**
```dart
border: Border.all(color: gold.withOpacity(.10)),        // innen liegend
boxShadow: [
  BoxShadow(color: Color(0x0A0E1E).withOpacity(.65), blurRadius: 60, offset: Offset(0,24), spreadRadius: -16),
  BoxShadow(color: Color(0x0A0E1E).withOpacity(.50), blurRadius: 14, offset: Offset(0,4),  spreadRadius: -4),
]
```
Dazu eine 1-px-Lichtkante oben innen (`#FFFFFF` @ 10 %) — in Dart am einfachsten als
zusätzlicher 1-px-Container mit `LinearGradient` von Weiß 10 % nach transparent über 2 px Höhe.

## 4. Wellen — die Basisform

Die drei Wellen sind identisch mit dem App-Icon (Koordinatensystem 256 × 256).
Es sind reine quadratische Beziers; `T` ist die Spiegelung des vorigen Kontrollpunkts.

```
Welle 1 (hell,   Strich 9,  #F4CF80): M 28  92  Q 72 60,  116 92  T 196 92  Q 218 84, 228 90
Welle 2 (mittel, Strich 11, #DCA85B): M 24 134  Q 76 100, 132 134 T 212 134 Q 226 130, 234 134
Welle 3 (tief,   Strich 13, #B58346): M 22 178  Q 88 138, 154 178 T 234 178
```

Ausgeschriebene Kontrollpunkte der `T`-Segmente (für `quadraticBezierTo`):

| Welle | Segment | Kontrollpunkt | Endpunkt |
|---|---|---|---|
| 1 | 2 | (160, 124) | (196, 92) |
| 2 | 2 | (188, 168) | (212, 134) |
| 3 | 2 | (220, 218) | (234, 178) |

In Dart:
```dart
final p = Path()..moveTo(28, 92)
  ..quadraticBezierTo(72, 60, 116, 92)
  ..quadraticBezierTo(160, 124, 196, 92)
  ..quadraticBezierTo(218, 84, 228, 90);
```
Strich immer `StrokeCap.round`, `StrokeJoin.round`, `PaintingStyle.stroke`.

### Verwendung als Hintergrund-Ornament

Im Splash liegen dieselben drei Pfade groß, ruhig und stark transparent im Grund:

* Ausschnitt des Icon-Koordinatensystems: `x 14…242`, `y 76…192` (228 × 116 Einheiten)
* skaliert auf **124 % der Kartenbreite** (Faktor 3.045), Ursprung bei `(-56, 18)` der Karte
* Gruppendeckkraft **5 %**, Farbe durchgehend `#F4CF80`
* Strichstärken auf 62 % reduziert: 5.58 / 6.82 / 8.06
* Einzeldeckkraft je Linie: 0.95 / 0.77 / 0.59

### Animation (nur falls du sie zurückholen willst)

Die im Icon verwendete Wellenbewegung ist in `lottie/README.md` dokumentiert:
Ein Gauß-Buckel wandert über die Kurve und hebt sie lokal an,
`y -= h · exp(-((x - cx)/σ)²)` mit `h = 20.5`, `σ = 40`, Durchlauf 1.3 s, Pause 0.55 s.
Im aktuellen Splash ist sie **aus** — das Ornament steht still.

## 5. Wortmarke ZANSHIN

Nachzeichnung des SKEBULA-Stils: eine monolineare geometrische Sans mit konstanter
Strichstärke, spitzem A **ohne Querbalken** und weiter Sperrung. Kein Font — reine Strichpfade.

Koordinatensystem: **Versalhöhe 100 Einheiten**, y = 0 oben, y = 100 Grundlinie.
Sperrung (`track`) 32 Einheiten, Gesamtbreite damit **562 Einheiten**.
Strichstärke im Splash: **2.8 px** bei 38 px Versalhöhe → 7.37 Einheiten.
Enden `StrokeCap.butt`, Ecken `StrokeJoin.miter`.

Glyphen einzeln (Ursprung jeweils links oben, `w` = Vorschub ohne Sperrung):

| Glyphe | w | Konstruktion |
|---|---|---|
| Z | 62 | `M 0 0 L 62 0 L 0 100 L 62 100` |
| A | 64 | `M 0 100 L 32 0 L 64 100` (kein Querbalken) |
| N | 62 | `M 0 100 L 0 0 L 62 100 L 62 0` |
| S | 58 | zwei Halbellipsen, rx 27 / ry 22: `M 55 19 A 27 22 0 1 0 29 50 A 27 22 0 1 1 3 81` |
| H | 62 | `M 0 0 L 0 100`, `M 62 0 L 62 100`, `M 0 50 L 62 50` |
| I | 0 | `M 0 0 L 0 100` |

Vollständiger Pfad von „ZANSHIN" bei track 32 (direkt in Dart übertragbar):

```
M 0 0 L 62 0 L 0 100 L 62 100
M 94 100 L 126 0 L 158 100
M 190 100 L 190 0 L 252 100 L 252 0
M 339 19 A 27 22 0 1 0 313 50 A 27 22 0 1 1 287 81
M 374 0 L 374 100  M 436 0 L 436 100  M 374 50 L 436 50
M 468 0 L 468 100
M 500 100 L 500 0 L 562 100 L 562 0
```

**Zu den Bögen im S:** Dart kennt kein SVG-`A`. Ersatz über `arcTo` mit expliziten Rechtecken —
der obere Bogen läuft von (339,19) nach (313,50) gegen den Uhrzeigersinn, der untere von
(313,50) nach (287,81) im Uhrzeigersinn, beide mit Radien 27 × 22. Alternativ, und in der
Praxis einfacher: das S mit zwei kubischen Beziers annähern, der Unterschied ist bei 2.8 px
Strichstärke nicht sichtbar.

**Farbverlauf der Wortmarke** (`shader` auf dem Paint):
```dart
LinearGradient(begin: Alignment.topLeft, end: Alignment(-0.2, 1),
  colors: [goldLight, gold, goldDark])   // 0 / 50 / 100 %
```
Auf hellem Grund stattdessen einfarbig `#26304D`, auf reinem Schwarz `#F2F3F7`.

## 6. Kanji 残心

*Shippori Mincho*, Gewicht 500, 44 px, Farbe `#F4CF80`, letterSpacing 1.8.
Als `Text`-Widget setzen — die Glyphen nachzuzeichnen wäre unverhältnismäßig.

Das Wasserzeichen rechts ist dasselbe Zeichenpaar, **vertikal** gesetzt (zwei `Text`-Widgets
untereinander, kein `writing-mode` nötig): 118 px, Gewicht 600, `#F4CF80` bei **4 % Deckkraft**,
Mitte bei x = 497, Grundlinien y = 128 und y = 246. Es darf unten angeschnitten werden.

## 7. Ladeleiste und Statuspunkt

* Schiene: volle Breite, 2 px, `#FFFFFF` @ 7 %, sitzt bündig am unteren Kartenrand.
* Läufer: 38 % der Breite (213 px), Verlauf horizontal
  `transparent → #F4CF80 → #DCA85B → transparent` (Stops 0 / .35 / .7 / 1).
* Bewegung: von `left: -40 %` nach `left: 100 %`, Dauer **2.1 s**, Endlosschleife,
  Kurve `Cubic(0.65, 0.05, 0.35, 0.95)`.
* Statuspunkt: 6 px Kreis `#F4CF80` mit 3 px Ring `#F4CF80` @ 16 %,
  Deckkraft pulsiert 0.35 → 1 → 0.35 über **1.85 s**, `Curves.easeInOut`.
* Statustexte wechseln alle 2.1 s durch:
  „Repository wird geladen…", „Index wird aufgebaut…", „Operation-Log wird gelesen…",
  „Arbeitskopie wird geprüft…".

## 8. Typografie

| Rolle | Familie | Größe / Gewicht | Farbe |
|---|---|---|---|
| Wortmarke (Alternative zur Zeichnung) | Inter | 48 px / 500, letterSpacing −0.025em | Verlauf gold |
| Kanji | Shippori Mincho | 44 px / 500 | `#F4CF80` |
| Tagline | Inter | 11.5 px / 500, letterSpacing 0.17em, uppercase | `#A9B3D0` |
| Version | JetBrains Mono | 12 px / 400 | `#E7DCC4`, Build-Teil `#8792B4` |
| Status | Inter | 11.5 px / 400 | `#98A3C2` |

## 9. Gelieferte SVGs

| Datei | Inhalt |
|---|---|
| `assets/zanshin-splash.svg` | komplette Karte, 560 × 320, Texte als `<text>` |
| `assets/zanshin-splash-bg.svg` | nur der Hintergrund inkl. Rahmen |
| `assets/zanshin-wordmark-gold.svg` | Wortmarke, Goldverlauf |
| `assets/zanshin-wordmark-ink.svg` | Wortmarke für helle Gründe (`#26304D`) |
| `assets/zanshin-wordmark-white.svg` | Wortmarke Weiß |
| `assets/zanshin-waves.svg` | die drei Wellen in Originalfarben, ohne Grund |
| `assets/zanshin-wave-ornament.svg` | Wellen als Ornament (dünnere Striche, gestaffelte Deckkraft) |
| `icons/zanshin-icon-04-nami-indigo.svg` | App-Icon mit Grund, 256 × 256, Radius 58 |

Die Wortmarken-SVGs enthalten **keine Textelemente** — sie sind reine Pfade und
rendern in `flutter_svg` ohne Font-Abhängigkeit. `zanshin-splash.svg` dagegen enthält
Text und braucht Inter, JetBrains Mono und Shippori Mincho; es ist als Referenz gedacht,
nicht als Produktionsasset.

# UI-Controls: Yaru, Material oder eigene Bibliothek – und die macOS-Akzentfarben

**Datum:** 2026-10-15 · **Anlass:** Konsolensession mit Ralph. Claude Design sagt, die UI sei komplett custom (kein Material für Buttons usw.).
**Fragen:**
- Können wir (a) Yaru mit unserem Theming nutzen, (b) Material mit eigenem Theming, oder (c) sollten oder müssen wir eine eigene UI-Bibliothek bauen?
- Wie lässt sich das Design System um alle Standard-Controls mit allen Zuständen und Mikro-Animationen ergänzen?
- Können wir die macOS-Akzentfarben nutzen, und muss es das Gold dann auch in Rot, Blau, Grün usw. geben?

**Methode:**
- Fünf Agents haben parallel untersucht:
  - das Design System und den Floating-Client (`design_system/`, `design/`, Stand `e74ced3`, DS synced through #9);
  - Ralphs Yaru-Fork (`../yaru.dart`);
  - `material_ui` (1.4.0 und 1.7.0 aus dem Pub-Cache, 1.5.0 per Tag auf GitHub);
  - die Widgets-Schicht des Flutter-SDK (3.47.7 stable und master `29bfd8cbb41`);
  - die macOS-Akzentfarben, mit einem Swift-Probe-Programm auf Ralphs Mac (macOS 27.0.1).
- Je ein fünfter Agent hat die tragenden Aussagen jedes Berichts adversarial nachgeprüft.
- Die drei wichtigsten Befunde wurden in der Hauptsession noch einmal an der Quelle gegengelesen: Switch- und Checkbox-Geometrie in Material und Yaru, die Segmentform von `SegmentedButton` und `AppleAccentColor`.
- Belege stehen als `Datei:Zeile`. Abkürzungen:
  - **DS** = `_bmad-output/implementation-artifacts/design_system/`
  - **MU** = `~/.pub-cache/hosted/pub.dev/material_ui-1.7.0/lib/src/`
  - **YA** = `../yaru.dart/lib/src/`
  - **SDK** = `~/development/sdks/flutter/packages/flutter/lib/src/`

**Prompt für Claude Design:** [`claude-design-prompt-controls-and-accents-2026-10-15.md`](claude-design-prompt-controls-and-accents-2026-10-15.md), im selben Ordner.

---

**Kurz:**
- **(c), aber nicht von Grund auf.** Die Controls, die das DS definiert, lassen sich weder mit Yaru noch mit Material über Theming erreichen. Das gilt für Switch, Checkbox, Segmented, Menü-Panel und Select. Das liegt nicht an Farben, sondern an fest einkompilierter Geometrie, Bewegung und Zustandslogik. Wir müssen also eigene Controls bauen.
- **Das ist kleiner, als es klingt.** Flutter hat die Verhaltens-Bausteine inzwischen in die Widgets-Schicht verlegt: `ToggleableStateMixin`, `RawRadio`/`RadioGroup`, `RawMenuAnchor`, `RawTooltip`, `RawScrollbar`, `FocusableActionDetector`, `WidgetStatesController`. Materials eigene Switch, Checkbox, Radio, Tooltip und Menüs sind nur eine Haut darüber. Eine Zanshin-Haut steht auf derselben Ebene.
- **Texteingabe übernehmen wir aus Flutter** (TextField oder CupertinoTextField ohne Dekoration). IME, Undo, Auswahl und das macOS-Kontextmenü selbst zu bauen lohnt nicht.
- **Yaru fliegt als Abhängigkeit raus**, sobald 11.1 ein eigenes Theme hat. Als Ideenquelle bleibt es gut. Der Look, den Ralph an Yaru mag (flach, keine Ripples, gemalte Toggles), ist ohnehin die Sprache des DS.
- **Akzentfarben: ja, aber nicht das Gold.** Das Gold hat drei Jobs:
  - @ ist eine Datenfarbe, wie Grün für „hinzugefügt“, und bleibt fest;
  - die Marke (Nami, Wortmarke, Splash) bleibt fest;
  - nur die eine Primäraktion ist genau der Button, den macOS umfärbt.

  Die Rolle, die macOS seinem Akzent gibt (Auswahl, Fokus, Controls), ist bei uns **Moon**. Empfehlung:
  - „Mehrfarbig“ (der macOS-Standard) heißt „jede App ihr eigener Akzent“, also Zanshin unverändert;
  - jede benannte Wahl bekommt eine **eigene, abgestimmte Zanshin-Familie** für die Moon-Rolle, in Night und Paper.

  Ob die Primäraktion mitgeht, soll Claude Design prüfen. Beide Varianten sind vertretbar. Die Kollisionen mit add/rem, warn/conflict und dem @ sind messbar und müssen je Akzent gelöst werden (§6).

---

## 1. Ausgangslage

**Was das DS verlangt** (DS `readme.md:96-100`, `components/forms/forms.css`, `components/actions/actions.css`):
- **Maße:** kleine, dichte Controls. Switch 30×18 mit 12-px-Thumb, Checkbox 15 px (Radius 4.5, Rand 1.5), Segmente 18/22/24/28 px mit 2 px Track-Padding und 2 px Lücke, Menüzeilen 28–30 px, Felder 30–36 px, Schrift 12.5 px.
- **Zustände:** Hover = 7 % Fill, an/offen = 11 %, kein Schrumpfen, kein Ripple. Fokus = 2-px-Moon-Outline mit Abstand 2. Disabled = 38 %. Pfeil-Cursor überall.
- **Bewegung:** Kurve „glide“ `cubic-bezier(.32,.72,0,1)`, Hover 120 ms. Die Komponenten-CSS nutzt für Zustandswechsel allerdings CSS-`ease`, nicht glide (§5).

**Was die App heute macht.**
- Die Startseite ist Yarus Testseite (`app/lib/src/features/app/zanshin_app.dart`). `createYaruDarkTheme`/`createYaruLightTheme` bekommen den macOS-Akzent roh als `primaryColor` (`:111-118`), ohne `fontFamily`, also Ubuntu.
- Ralphs Mac steht auf Orange, also ist die Testseite orange (#F7821B).

**Was die Stories sagen. Sie widersprechen sich:**
- 10.7 Item 8: „Controls come from `package:material_ui` with Yaru styling“ (`epics.md:9085`).
- Die Notiz vom 14.10. zur selben Story: Segmented, Switch und Slider folgen dem DS (`:9042`). Item 8 nimmt sie aber nicht ausdrücklich zurück.
- 11.1 Item 9: „The Yaru builder stays the Material baseline“ (`:11032`). Ein Witness erwartet „a hovered Material button, checkbox and switch“ (`:11073`).
- 11.1 Non-goal: Jedes Control baut „the first story that needs it“ (`:11053`). Keine Story besitzt also einen gemeinsamen Control-Satz.

## 2. Option (a): Yaru

**Was Yaru ist.** Yaru ist zweierlei:
1. **Ein `ThemeData`-Builder über Material.** `createYaruTheme` = `ThemeData.from` + `copyWith` vieler Komponenten-Themes (YA `themes/common_themes.dart:686-805`). Für Material-Widgets erbt Yaru also jede Grenze aus §3.
2. **Eigene, gemalte Toggles.** `YaruCheckbox`, `YaruRadio` und `YaruSwitch` auf `YaruTogglable` (YA `widgets/yaru_togglable.dart`). Farben und Cursor lassen sich über ThemeExtensions setzen. Alles andere ist eine private Konstante:
   - Switch `Size(48, 26)` (YA `widgets/yaru_switch.dart:11`), DS: 30×18;
   - Checkbox und Radio 20 px mit 2 px Rand (YA `widgets/yaru_checkbox.dart:8-14`, `yaru_radio.dart:8-12`), DS: 15 px / 1.5;
   - Dauern 150/100/200 ms mit `easeInQuad`, `easeIn` und `fastOutSlowIn` (`yaru_togglable.dart:8-10, 98-126`);
   - beim Drücken und bei **jeder** Wertänderung schrumpft das Control um 2 px (`:13, :218-230, :423-444`; DS: „no shrink“);
   - Hover und Fokus sind ein Kreis mit 20 px Radius, kein Fill und keine Outline (`:11, :296-297, :407-421`);
   - der Standard-Cursor ist `click` (`:253-257`).

**Was Yaru gar nicht hat:** Segmented-Control (`YaruSegmentedEntry` ist eine Datums-Eingabe), eigenen Slider, Glas oder Blur (kein `BackdropFilter` in `lib/`), getönte Glas-Buttons, DS-artige Menüs. `YaruSearchField` hat keinen Fokuszustand (`yaru_search_field.dart:137-149`).

**Was Yaru über Material hinaus wirklich beiträgt:** `NoSplash`, ein paar Radien und Dichten, ein Ubuntu-`ColorScheme`. 11.1 überschreibt Schrift, Farben, Cursor und Hover sowieso. Yaru setzt kein einziges `mouseCursor` und kein `segmentedButtonTheme`.

**Was Yaru kostet:**
- **Der Fork.** Der Fork ist ein mechanischer Import-Tausch (181 Zeilen `flutter/material.dart` → `material_ui`; ein gepushter jj-Commit, Bookmark `material_ui`). Upstream hat aber am 2026-10-05 ein **echtes 11.0.0** veröffentlicht, ohne `material_ui`. Unsere lokale „11.0.0“ kollidiert damit, und der Fork liegt 10 Commits zurück.
- **Fremdlasten in der macOS-App:** `dbus`, `gsettings`, `gtk`, `yaru_window` → `window_manager` + `screen_retriever_macos`, zwei **native Plugins** im Runner registriert (`app/macos/Flutter/GeneratedPluginRegistrant.swift:9-10`). Dazu die Fonts Ubuntu, UbuntuMono und YaruIcons im Bundle.
- **Lizenz:** MPL-2.0 (dateibezogenes Copyleft). Zanshin ist MIT. Yaru-Dateien zu kopieren bindet sie an MPL. Die Ideen nachzubauen nicht.
- **Ein Design-Fork:** Yaru zum Control-Satz des DS zu machen hieße, Konstanten in Upstream-Dateien dauerhaft umzuschreiben. Das ist ein Fork, der bei jedem Upstream-Update kollidiert.

**Urteil:** Yaru eignet sich nicht als Control-Bibliothek. Als Material-Basis taugt es höchstens kurz, bis 11.1 ein eigenes Theme hat. Als **Ideenquelle** lohnt es, nachgebaut statt kopiert:
- das Zustandsmodell (`WidgetStatesController` zwischen Label und Indikator, `FocusableActionDetector`, Fokus-Highlight nur bei Tastatur);
- die animierte Häkchen-Zeichnung und der Morph Häkchen ↔ Strich (`yaru_checkbox.dart:276-366`);
- Drag-to-toggle beim Switch;
- das RenderBox-Label-Layout mit Slots (`yaru_toggle_button_layout.dart`);
- die Abbildung „Akzent-Name → kuratierte Variante“ (`settings/inherited_theme.dart:223-235`);
- die Trennung von zwei Akzenten: `elevatedButtonColor` neben `primary`. Yarus Standard-Theme ist Orange für Controls und Grün für die Primäraktion. Das ist genau die DS-Aufteilung Moon/Gold.

## 3. Option (b): Material (`material_ui`) mit eigenem Theming

**Was `material_ui` ist.** Die aus dem Framework ausgelagerte Material-Bibliothek, eigenständig versioniert. Lokal 1.4.0 und 1.7.0, gelockt ist 1.5.0. Sie zieht Richtung M3 Expressive, das bleibt aber opt-in. Die Verhaltens-Primitive sind in die Widgets-Schicht gewandert. Material nutzt sie selbst:
- Checkbox und Switch auf `ToggleableStateMixin`;
- Radio auf `RawRadio`;
- MenuAnchor auf `RawMenuAnchor`;
- Tooltip auf `RawTooltip`;
- Scrollbar auf `RawScrollbar`.

**Passung je Control** (adversarial geprüft):

| DS-Control | Material + Theme | Grund |
|---|---|---|
| Button quiet / ghost / danger, Gold-Primary sm/md | **geht**, mit `backgroundBuilder` | Der Hover-Overlay ist fest 50 ms linear (MU `ink_well.dart` `getFadeDurationForType`). Die Hintergrundfarbe wird nicht animiert, nur Elevation und Shape. Mit `overlayColor` transparent und einem Builder, der selbst animiert, gehen 120 ms glide. |
| Primary lg (Glas + Insel-Schatten) | Wrapper | Builder-Ausgabe wird geclippt, außer die Instanz setzt `clipBehavior: Clip.none`. Das geht nicht über das Theme. |
| IconButton 28/36/40, `is-on` | geht | ButtonStyleButton. `isSelected` → `selected`. |
| **Segmented** (default / tabs / inset / sm) | **nein** | `segmentStyleFor` erzwingt `RoundedRectangleBorder()` (eckig) und verwirft `minimumSize`, `fixedSize`, `side` und die Builder (MU `segmented_button.dart:548-572`). Gleich breite Segmente, aneinanderstoßend, mit Trennlinien. |
| **Switch** 30×18 | **nein** | `SwitchThemeData` hat weder Größe noch Dauer. M3 ist fest 52×32, Thumb 16/28, 300 ms `easeOutBack` (MU `switch.dart:2351-2369, :775`). `Switch.adaptive` ist 51×31 bei 140 ms. |
| **Checkbox** 15 px | nur per Skalierungs-Hack | `static const double width = 18.0` (MU `checkbox.dart:410`), Häkchen-Strich 2 px. Randbreite und Radius lassen sich über `side`/`shape` theme-n. |
| Radio | geht, falls das DS ~16 px wählt | Außenradius fest 8. Sonst `RawRadio`. |
| Slider | **geht** | Eigene `thumbShape`, `trackShape` und `overlayShape`. `padding` für Dichte. Cursor-Override nötig. |
| Textfeld, Suchfeld | geht | `InputDecorationTheme` + eigener `InputBorder` für den Ring. Rahmen-Übergang fest 167 ms `fastOutSlowIn`, Hover 15 ms (kleine Abweichung). |
| **Select** | **nein** | `DropdownButton`-Zeilen ≥ 48 px (assert). `DropdownMenu` hat den Hand-Cursor fest einkodiert, ohne Parameter. |
| Menüzeilen | geht | `MenuItemButton` + `MenuButtonThemeData`; 28 px über `minimumSize`. |
| **Menü-Panel** | **nein** | `MenuStyle` kennt weder Dekoration, Sheen, CSS-Schatten noch Blur. Öffnen: M3 mit 500/150 ms oder gar nicht (`animated` = false). |
| Tooltip, Scrollbar | geht | Dekoration, Textstil, Dauern bzw. `ScrollbarThemeData`. |
| Fokusring 2 px, Abstand 2 | Wrapper oder eigener `OutlinedBorder` | Material zeigt Fokus als Fill-Overlay, nicht als Outline. |

**Kosten:**
- etwa 25 Komponenten-Themes, dazu viele `WidgetStateProperty`-Resolver;
- ein eigener `InputBorder`, zwei bis drei `SliderComponentShape`s, ein Fokus-Border;
- trotzdem Wrapper für Variante × Größe;
- dauerhafter Kampf gegen Defaults: 50-ms-Overlay, harter Farbwechsel, 167-ms-Feldübergang, Dichte-Rechnung (`VisualDensity.compact` zieht auf macOS 8 px von Mindestgrößen ab);
- bei jedem `material_ui`-Update wieder prüfen.

**Urteil:** Material taugt als **Verhaltens-Unterbau für ein paar schwere Controls** (Textfeld, Scrollbar, eventuell Slider und Tooltip), nicht als Design-Sprache. Segmented, Switch, Checkbox, Select und Menü-Panel müssen in jedem Fall selbst gebaut werden.

## 4. Option (c): eigene Control-Bibliothek

**Was das konkret heißt.** Zanshin-Controls („Zs…“) auf den Widgets-Primitiven, gemalt als `RenderBox` mit Text-Slots (Hausregel „Visuals“, Muster `splash_card_render.dart`). `MaterialApp` bleibt Host für Navigator, Overlay, Lokalisierungen und `ThemeExtension`.

| Control | Unterbau |
|---|---|
| Zustandskern (hover / pressed / focus-visible / disabled, Fokusring, Cursor, Semantik, Reduce motion) | `FocusableActionDetector` + `WidgetStatesController` + `MouseRegion` + `Semantics`. Einen `WidgetStateMixin` gibt es nur in Material; etwa 40 Zeilen selbst. |
| Button, IconButton, Gold-Primary | der Kern + Slot-RenderBox |
| Switch, Checkbox | `ToggleableStateMixin` + `ToggleablePainter`. Dauer und Kurve lassen sich setzen (`positionController`), Tristate ist eingebaut. Die Semantik `toggled`/`checked`/`mixed` ergänzen wir selbst. |
| Segmented (alle Varianten), Radio | `RadioGroup` + `RawRadio`: Pfeiltasten, Space, Fokusgruppe und macOS-Semantik inklusive |
| Slider | kein Primitiv: Gesten + `Shortcuts` + `Semantics(slider)` + RenderBox |
| Menüs, Select-Liste, Popover | `RawMenuAnchor` (Overlay, Klick außerhalb, Esc, Pfeiltasten). Fokus und Semantik besorgen wir selbst. |
| Tooltip | `RawTooltip` (Hover-Verzögerung, `animationStyle`) |
| Textfeld | `TextField(decoration: null)` aus `material_ui` oder `CupertinoTextField` aus `cupertino_ui`, in einem selbst gemalten Well. Nicht auf blankem `EditableText` aufbauen: Gesten, Auswahl-Overlay, Toolbar und Barrierefreiheit wären sehr viel Arbeit. |
| Scrollbar, Dialog | `RawScrollbar` / `RawDialogRoute` |

**Plattform-Fakten, die dafür sprechen** (geprüft in Engine und SDK):
- **VoiceOver auf macOS liest Rollen nur aus Semantik-Flags** (button, checkBox, switch, radioButton, slider, textField …). `SemanticsRole` (menu, tab, tooltip …) wertet die macOS-Brücke nicht aus (`engine/.../common/accessibility_bridge.cc:313-360`). Eigene Controls mit den richtigen Flags sind also gleichwertig zu Material.
- **Fokus-Highlight:** Auf macOS ist der Highlight-Modus immer „traditional“. Maus oder Trackpad schalten ihn nicht um. Ein Control, das beim Klick keinen Fokus nimmt, verhält sich deshalb wie `:focus-visible`. `ToggleableStateMixin` und Materials Buttons tun das schon so.
- **Reduce motion meldet die macOS-Engine nie.** Das ist bekannt, 11.1 Item 7 löst es.

**Aufwand:** Fast jeder DS-Control wird von Epic 10/11 gebraucht:
- 10.7: Segmented, Switch, Slider, Popover, Gold-Primary;
- 10.15: Menü;
- 10.21/10.22: Suchfeld, Dialog, Selects;
- 10.25/10.26: Tristate-Checkbox;
- 11.7: Tabs, Selects, Felder.

Der Großteil der Arbeit steckt also ohnehin in den Stories. Der echte Mehraufwand gegenüber gethemtem Material ist im Wesentlichen ein **gemeinsamer Interaktionskern** (Schätzung des Agents: 4–6 Tage) und das Verhalten von Slider, Select und Menü. Gethemtes Material hätte dafür dauerhafte Kosten (§3).

**Tests:** Es gibt keine Goldens (Hausregel). Stattdessen der `paints`-Matcher, `matchesSemantics`, `meetsGuideline`, `debugDeviceActiveCursor`, `sendKeyEvent` und `MediaQuery(disableAnimations:)`. Ralph prüft die Optik in einer Galerie-Seite, wie 11.2 sie plant.

## 5. Empfehlung und Folgen für die Stories

**Empfehlung:**
1. **Eigener Control-Satz** auf den Widgets-Primitiven. Textbearbeitung aus Flutter, Material nur für Scrollbar und eventuell Tooltip, kein Material- oder Yaru-Widget für sichtbare DS-Controls.
2. **Yaru als Abhängigkeit entfernen**, sobald 11.1 ein eigenes token-basiertes `ThemeData` hat (spätestens in 11.10). Bis dahin besser als git-Dependency auf das Bookmark `material_ui` statt als Pfad, mit einer anderen Versionsnummer.
3. **Zuerst den Interaktionskern als eigene Story**, nach 11.1/11.2 und vor 10.7. Sonst löst jede Story Fokus, Bewegung und Semantik neu. Die Drift sieht man im DS schon: vier Disabled-Werte und fünf Fokus-Behandlungen.

**Story-Änderungen, die daraus folgen.** Nicht umgesetzt; das ist Ralphs Entscheidung:
- **11.1**
  - Item 9: „Yaru builder stays the Material baseline“ wird zu einem eigenen, token-basierten `ThemeData`, nur noch für restliche Material-Teile.
  - Item 8: Die Prämisse „Material shows a pointing hand on desktop“ stimmt nur teilweise. Die meisten Material-Controls nutzen `adaptiveClickable`, und das ist auf dem Desktop der Pfeil. Die Hand bleibt nur bei Switch, Slider, TabBar, ListTile, DataTable und BottomNavigationBar. `DropdownMenu` hat sie fest einkodiert. Yarus Toggles defaulten auf `click`.
  - Witness `:11073` (Material-Button, -Checkbox, -Switch) auf die eigenen Controls umstellen.
  - Item 1 behauptet „All [oklch values] lie inside the sRGB gamut“ (`:10997`). Das ist **falsch**, siehe §7.
  - Designfrage (c) wird dreiwertig: macOS-Akzent roh / Moon / Zanshin-Familie je macOS-Akzent (§6).
- **10.7**
  - Item 8: „material_ui with Yaru styling“ ausdrücklich als überholt markieren.
- **Neue Story:** der Control-Kern (Zustandsmodell, Fokusring, Cursor, Semantik, Reduce motion, Galerie). Danach baut jede Story ihre Controls darauf.
- **zanshin_shell:** die Akzent-Identität mitsenden (§6.4).
- Wie immer: neue oder geänderte Stories auch in `sprint-status.yaml` spiegeln.

## 6. macOS-Akzentfarben

### 6.1 Was macOS anbietet und wie man es liest

- **Auswahl** (gemessen auf macOS 27.0.1): Mehrfarbig plus Blau, Lila, Rosa, Rot, Orange, Gelb, Grün, Graphit, auf dem iMac zusätzlich „Dieser Mac“. Einen frei wählbaren Akzent gibt es nicht.
  - In macOS 26/27 heißt der Abschnitt „Thema“, die Zeile „Farbe“.
  - Die **Textmarkierungsfarbe** ist eine eigene Einstellung. Auf Ralphs Mac ist der Akzent Orange und die Markierung Blau.
- **Apples Regel** (HIG, Color › macOS): Bei „Mehrfarbig“ zeigt jede App ihren eigenen Akzent. Jede andere Wahl ersetzt ihn bei „buttons, selection highlighting, and sidebar icons“. Ausgenommen sind feste Farben, die Bedeutung tragen. Apples eigene Apps behalten ihre Farbe nur bei Mehrfarbig (Notizen gelb, Musik rot).
- **Auslesen:** `NSColor.controlAccentColor` liefert bei Mehrfarbig die App-Farbe aus `NSAccentColorName`. Zanshin deklariert keine, also kommt Blau (#007AFF), und **Mehrfarbig ist auf der Dart-Seite nicht von Blau zu unterscheiden.**
  - Eindeutig ist der Schlüssel `AppleAccentColor`: fehlt = Mehrfarbig, −1 Graphit, 0 Rot, 1 Orange, 2 Gelb, 3 Grün, 4 Blau, 5 Lila, 6 Rosa.
  - Ralphs Mac: `defaults read -g AppleAccentColor` = 1, also Orange.
  - „Fehlt = Mehrfarbig“ ist dokumentiert, ließ sich aber nicht nachstellen, ohne die Systemeinstellung zu ändern.
- **Gemessene Akzentwerte** (`controlAccentColor`, hell / dunkel). Das ist **nicht** die `systemColor`-Palette: Orange ist #F7821B, `systemOrange` dagegen #FF8D28.

| Wahl | hell | dunkel | OKLCH-Farbton |
|---|---|---|---|
| Blau | #007AFF | #007AFF | 257 |
| Lila | #953D96 | #A550A7 | 327 |
| Rosa | #F74F9E | #F74F9E | 356 |
| Rot | #E0383E | #FF5257 | 23–24 |
| Orange | #F7821B | #F7821B | 54 |
| Gelb | #FFC726 | #FFC600 | 87 |
| Grün | #62BA46 | #62BA46 | 139 |
| Graphit | #989898 | #8C8C8C | – (grau) |

- **Rohwerte reichen nicht.** Auf der Paper-Karte (#fffdfa) erreichen Gelb 1.54:1, Grün 2.40:1, Orange 2.53:1 und Graphit 2.84:1. Das ist unter 3:1 für UI-Elemente. Nötig sind abgestimmte Varianten.

### 6.2 Zanshins zwei Akzentrollen

**Gold**
- `--co*` (Safran, @): @-Badge, -Rand, -Welle, -Kante, -Flag, Composer-Punkt, Minimap-Knoten. Das ist eine **Datenfarbe**. Sie markiert die Arbeitskopie, so wie Grün „hinzugefügt“ markiert.
- `--fl-gold`: die eine Primäraktion. Dasselbe Token zeichnet aber auch den Rand der @-Pille und die Tages-Pille und den Verbinder der Minimap (`actions.css:28`; `float.css:41, :44`). Auf Night ist es dieselbe Farbe wie die Nami-Welle (#dca85b).
- Marke: Nami, Wortmarke, Splash, der Gold-Lift des Paper-Canvas (`colors.css:59`).

**Moon**
- Controls und Auswahl (`--accent*`): Switch, Slider, Checkbox, jeder Fokusring, Feld-Fokus, Menü-Hover (solide Füllung), Karten-Auswahl, Drop und Flash.
- Moon trägt aber auch **Datenbedeutung**: Dateistatus „M“ neben A (grün) und D (rot) (`content.css:7-9`), Hunk-Header (`--accent-soft` + `--hunk`), Remote-Status von Bookmarks (`graph.css:53`).

Die macOS-Akzentrolle (Controls, Auswahl, Fokus) entspricht also **Moon**. Dazu kommt der Default-Button, also unsere Gold-Primäraktion. Das @ ist dagegen eine Bedeutungsfarbe, und die nimmt Apple ausdrücklich aus.

### 6.3 Optionen und Kollisionen

Gemessen als ΔE in OKLab. Faustregel: unter .06 verwechselbar, .06–.10 nah.

**(A) Gold mit @ und Primäraktion folgt.** Kollidiert hart:

| Wahl | Kollision |
|---|---|
| Blau | @ ≈ Moon (.052) |
| Grün | ≈ add (.048) |
| Rot | ≈ rem (.079 Night, .033 Paper) |
| Graphit | ≈ Textleiter (.034) |

Außerdem:
- Blau, Rot und Rosa erreichen bei L .78 die Chroma des Safran nicht und werden pastellig.
- Icon und Splash bleiben Gold, das @ wäre es nicht mehr.
- Das komplementäre Paar Gold auf Indigo, der Kern der Stimmung, geht verloren.

**(B) Nur Moon folgt.**

| Wahl | Ergebnis |
|---|---|
| Blau | ist praktisch Moon (.018) |
| Lila, Rosa | sauber, aber erst bei etwas höherer Chroma als Moon |
| Orange, Gelb | landen auf Gold und dem Amber von warn/conflict (.04–.065) |
| Grün | nah an add (.056 Paper) |
| Rot, Rosa | normales Menü-Hover (Akzent-Füllung) und Danger-Hover (rote Füllung) werden beide rot |
| Graphit | nah an der Textleiter, nimmt macOS aber selbst so hin |

**(C1) Mehrfarbig = Zanshin unverändert; eine benannte Wahl färbt nur die Moon-Rolle,** mit abgestimmten Zanshin-Familien. @, Marke und die Datenbedeutungen bleiben fest.

**(C2) wie C1, dazu folgt die Primäraktion.** Das entspricht Apples Regel (Buttons folgen) und Ralphs Gedanken „Gold auch in Rot, Blau, Grün“, aber nur für den Button. Bei Orange und Gelb gleicht die Primäraktion dann dem @. Das ist allerdings schon heute so: Gold-Primary und Safran-@ sind eine Familie.

**(D) zusätzlich eine Einstellung** „Akzent: macOS folgen / Zanshin“ unter Settings › General › Appearance. Passt zu Ralphs Linie „Entscheidungen anbieten statt bevormunden“.

**Empfehlung:** **C1 oder C2, plus D.**
- Mehrfarbig, der macOS-Standard, ergibt Zanshin wie entworfen.
- Wer bewusst eine Farbe gewählt hat, bekommt „unser“ Blau, Grün … in den Controls.
- @, Marke und Splash bleiben Gold.
- Die Wahl zwischen C1 und C2 und die Familien selbst entwirft Claude Design (Prompt Teil B).

### 6.4 Was technisch nötig wird (für eine spätere Story)

- **zanshin_shell**
  - zusätzlich die Akzent-Identität senden (`AppleAccentColor`, nil = Mehrfarbig). Hue-Klassifikation nur als Fallback, z. B. für „Dieser Mac“.
  - den Akzent unter dem **Fenster**-Appearance auflösen, nicht unter `NSApp.effectiveAppearance` (`ZanshinShellPlugin.swift:92-111` gegen `:141-151`). Erzwingt Zanshin Paper auf einem dunklen System, kommt heute die dunkle Variante an.
  - eventuell die Textmarkierungsfarbe mitsenden (`selectedTextBackgroundColor`), damit die Textauswahl der Systemwahl folgt.
- **Runner:** ein `AccentColor`-Farbset deklarieren (`NSAccentColorName`, Moon oder Gold). Dann färben native Menüs und Dialoge bei Mehrfarbig in Zanshins Farbe.
- **Token-Schicht (11.1):** die Akzent-Familien als statische Tokens je Wahl und Theme. Keine Laufzeit-Mischung, so bleibt der DS-Paritätstest einfach. Dazu `lerp` über die `ThemeExtension`, damit ein Wechsel weich ist.

## 7. Lücken und Ungereimtheiten im DS (Grundlage für Teil A des Prompts)

**Zustände, die fehlen:**
- **Pressed** (momentan) gibt es nirgends, kein `:active`. Der Default-Button nutzt die 11 % schon für Hover.
- **Disabled** fehlt bei Switch, Segmented/Tabs, Slider, Select, Feldern und IconButton.
- **Error/invalid** und **busy/loading** fehlen ganz.
- **Hover** fehlt bei Switch und Slider.
- Es gibt kein Häkchen-Zeichnen, keinen gleitenden Segment-Thumb, keine Exit-Animationen und kein Menüzeilen-Feedback.

**Fehlende Komponenten,** jeweils mit Bedarf aus den Stories:

| Komponente | Bedarf |
|---|---|
| Tooltip | das DS nutzt nur HTML-`title` |
| Fortschritt, Spinner, Pending | Fetch, Clone, Action-Runner, Skeleton-Karten |
| Select-Popup | bisher nur natives `<select>` |
| Fehlerzustand + Fehlerzeile | Settings, Revset-Fehler |
| Toast-Varianten | Ablehnung, Warnung, Fehler + Retry |
| Badge am IconButton | Fetch |
| Bestätigungsdialog | Push rückgängig, Konvertierung |
| Suchfeld mit ✕ | 11.6 |
| Radio | – |
| Scrollbalken | – |
| Menü-Extras | Submenü, Check-Items, Abschnitte |

**Ungereimtheiten:**
- Das Gold-Primary ist auf vier Arten geschrieben: Inset-Ring oder Border, unterschiedliche Mischungen, Hover nur Ring oder auch Füllung.
- Disabled kommt als .38, .4, .35 und .5 vor.
- Fokus erscheint mit Abstand 2, 1, 3, −2, als Inset-Ring und als Ring-Schatten.
- Ausgewählte Listenzeilen nutzen mal `--fl-on`, mal `--accent-soft`.
- Menü-Highlight gibt es in zwei Modellen: solide Moon-Füllung oder 7 % + `--accent-soft`.
- Dialog-Eintritt: 160 ms in der DS-Komponente, 240 ms im Client.
- „Eine Kurve“ laut Readme, aber die Hover laufen auf CSS-`ease`, Switch 160 ms, Suchfeld 140 ms.
- Der Slider-Thumb ist in beiden Themes hart #fff.
- Es gibt drei Link-Stile ohne Fokus.
- Veraltete Prompts: `Island.prompt.md` nennt `CommandField`; `Popover.prompt.md` und `colors-moon.html` zeigen das alte „Time“-Layout; `window.card.html` nutzt `cursor:pointer`; `motion.html` nennt einen „2.1s loop“.
- **Gamut:** Vier Paper-Tokens liegen außerhalb von sRGB **und** P3: `--co` (58% .16 65), `--co-text` (45% .14 65), `--conflict` (52% .13 70) und `--warn` (50% .13 70). Dazu kommen `--saffron-paper` und `--amber-paper` im `:root`. Browser clippen, Flutter braucht feste sRGB-Werte. 11.1 (`epics.md:10997`) behauptet das Gegenteil.
- **Kontrast:** Danger-Hover bei Night (weißer Text auf #f87171) erreicht nur 2.77:1.

## 8. Nebenbefunde

- **Der Workspace löst gerade nicht sauber auf.**
  - Das Flutter-SDK wurde am 2026-10-14 von master auf **3.47.7 stable** umgestellt (Reflog), aber `app/pubspec.yaml` verlangt `^3.48.0-1.0.pre-295` und Dart `^3.14.0-143.0.dev`.
  - Der Lock nennt `material_ui` 1.5.0, im Pub-Cache liegen nur 1.4.0 und 1.7.0.
  - Vor der nächsten UI-Story klären: SDK zurück auf master/beta oder Constraints senken, dann `pub get`.
- `packages/zanshin_shell/lib/src/window_drag_area.dart:3` importiert `package:flutter/material.dart`, gegen die Hausregel „Material nur aus `material_ui`“. Nur erwähnt, nicht geändert.
- Upstream-Yaru 11.0.0 ließe sich über `material_ui`s `MaterialUiCompatibilityBridge` auch ohne Fork einbinden. Die Brücke übernimmt aber nur ColorScheme, TextTheme, Dichte und Lokalisierung, nicht Yarus Komponenten-Themes.

## Quellen (Web)

- Apple HIG, Color: https://developer.apple.com/design/human-interface-guidelines/color
- `NSColor.controlAccentColor`: https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor
- `NSAccentColorName`: https://developer.apple.com/documentation/bundleresources/information-property-list/nsaccentcolorname
- AppleAccentColor-Werte: https://alexwlchan.net/2022/changing-the-macos-accent-colour/
- Akzent und Highlight seit Big Sur: https://512pixels.net/2020/11/big-sur-accent-highlight-colors/
- macOS-26-Darstellungsoptionen: https://9to5mac.com/2025/08/07/macos-26-tahoe-customization-options/
- Flutter, Material/Cupertino-Freeze: https://flutter.dev/blog/flutters-material-and-cupertino-code-freeze
- Migration auf `material_ui`/`cupertino_ui`: https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui
- Upstream Yaru: https://github.com/ubuntu/yaru.dart/commits/main
- libadwaita, Akzentfarben: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/styles-and-appearance.html
- macos_ui, Akzent-Diskussion: https://github.com/macosui/macos_ui/issues/486

// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The one Marionette configuration, shared by the app (`lib/main.dart`) and the catalogue
/// (`widgetbook/main.dart`) (Story 11.11).
///
/// Marionette's built-in recognition (Material buttons and fields, gesture detectors, `Text`) stays:
/// [MarionetteConfiguration.isInteractiveElement] and [MarionetteConfiguration.extractText] are consulted only after
/// it. On top of it every Zs control — a widget implementing [ZsControl] — is interactive, and reports its accessible
/// name as its text ([zsControlLabel]), so an agent matches an icon button by what VoiceOver reads. Agents match by
/// `identifier` or text, never by coordinates.
final zanshinMarionetteConfiguration = MarionetteConfiguration(
  isInteractiveElement: (element) => element.widget is ZsControl,
  extractText: zsControlLabel,
);

/// The accessible name of the Zs control at [element]: the label of the first `Semantics` below it that sets one
/// (its control core's, or its field's); null for an element that is no Zs control or names nothing.
///
/// The search stops at a Zs control nested inside (the switch of an option row, the buttons of a popover or a scroll
/// area): a container that reported their names would match an agent's text first and take the tap at its own
/// centre. A `ZsTooltip` is passed through: it is part of the control it wraps.
String? zsControlLabel(Element element) {
  if (element.widget is! ZsControl) {
    return null;
  }
  String? label;
  void visit(Element child) {
    if (label != null || (child.widget is ZsControl && child.widget is! ZsTooltip)) {
      return;
    }
    if (child.widget case Semantics(:final SemanticsProperties properties) when properties.label?.isNotEmpty ?? false) {
      label = properties.label;
      return;
    }
    child.visitChildren(visit);
  }

  element.visitChildren(visit);
  return label;
}

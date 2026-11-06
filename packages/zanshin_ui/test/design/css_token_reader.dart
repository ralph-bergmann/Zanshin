// SPDX-License-Identifier: MIT

/// Reads the design system's token CSS for the DS parity test (Story 11.1 item 12).
///
/// The model: comments are stripped, rules are split (inside `@media` blocks too) and only `--*` declarations are
/// kept. A selector list is a list of alternatives; each maps to conditions on the one root element every attribute
/// sits on (DS tokens/accents.css:6, tokens/inactive.css:12): `:root` is none, `[data-accent]` is any named family,
/// `:is(a, b)` is flattened (its specificity is its largest argument's). An alternative with a descendant combinator
/// never matches on one element and is skipped, and so is a `light` alternative, which duplicates paper. An
/// appearance resolves by cascading the matching rules by specificity (the number of simple selectors), then the
/// import order of DS styles.css, then the position; then `var()` is resolved against that map and `calc()`
/// evaluated. `@media (prefers-…)` rules are not applied: each must equal its attribute twin
/// ([CssTokenSheet.mediaDrift]).
library;

import 'dart:io';

import 'dart:ui' show Color;

import 'package:flutter/animation.dart' show Curves;
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_values.dart';

/// The design system, relative to `packages/zanshin_ui/`, where `flutter test` runs.
const dsRoot = '../../_bmad-output/implementation-artifacts/design_system';

/// The attribute each `@media (prefers-…)` feature mirrors.
const _mediaFeatures = <String, (String, String)>{
  'prefers-reduced-motion:reduce': ('motion', 'reduce'),
  'prefers-reduced-transparency:reduce': ('transparency', 'reduce'),
  'prefers-contrast:more': ('contrast', 'more'),
};

/// The `data-*` attributes the token files key on, by condition name.
const _attributes = <String, String>{
  'data-theme': 'theme',
  'data-accent': 'accent',
  'data-contrast': 'contrast',
  'data-transparency': 'transparency',
  'data-window': 'window',
  'data-motion': 'motion',
  'data-fullscreen': 'fullscreen',
  'data-density': 'density',
};

/// One `--name: value` declaration.
class CssDeclaration {
  CssDeclaration(this.name, this.value, this.line, this.index);

  /// The custom property, `--…`.
  final String name;

  /// The raw value as written.
  final String value;

  /// Its line in the file.
  final int line;

  /// Its position in the rule.
  final int index;
}

/// One alternative of a selector list: the attribute conditions it needs and its specificity.
class CssAlternative {
  CssAlternative(this.conditions, this.specificity);

  /// Condition name → required value; a null value means "any value" (`[data-accent]`).
  final Map<String, String?> conditions;

  /// The number of simple selectors.
  final int specificity;

  /// A canonical form of [conditions], for comparing selector lists.
  String get key => (conditions.entries.map((e) => '${e.key}=${e.value}').toList()..sort()).join('&');
}

/// One rule with at least one custom property.
class CssRule {
  CssRule({
    required this.file,
    required this.fileIndex,
    required this.line,
    required this.alternatives,
    required this.declarations,
    required this.media,
  });

  /// The token file, e.g. `tokens/colors.css`.
  final String file;

  /// The file's position in DS styles.css's import order.
  final int fileIndex;

  /// The selector's line.
  final int line;

  /// The alternatives that can match; empty when none can.
  final List<CssAlternative> alternatives;

  /// The custom properties it declares.
  final List<CssDeclaration> declarations;

  /// The `@media` feature it sits in (`prefers-contrast:more`), or null.
  final String? media;
}

/// The parsed token files.
class CssTokenSheet {
  CssTokenSheet._(this.rules);

  /// Parses [files] (name → text) in import order.
  factory CssTokenSheet.parse(Map<String, String> files) {
    final rules = <CssRule>[];
    var index = 0;
    for (final MapEntry<String, String>(key: file, value: text) in files.entries) {
      rules.addAll(_parseFile(file, index++, text));
    }
    return CssTokenSheet._(rules);
  }

  /// The rules in import order.
  final List<CssRule> rules;

  /// The token files of the DS at [root], in the import order of its styles.css.
  static Map<String, String> readFiles([String root = dsRoot]) {
    final String styles = File('$root/styles.css').readAsStringSync();
    return <String, String>{
      for (final RegExpMatch match in RegExp(r'@import "(tokens/[^"]+)"').allMatches(styles))
        match.group(1)!: File('$root/${match.group(1)}').readAsStringSync(),
    };
  }

  /// Every custom property [appearance] resolves to, as raw text after `var()` and `calc()`.
  Map<String, String> resolveRaw(ZsAppearance appearance) {
    final best = <String, (List<int>, CssDeclaration)>{};
    for (final CssRule rule in rules) {
      if (rule.media != null) {
        continue;
      }
      int? specificity;
      for (final CssAlternative alternative in rule.alternatives) {
        if (_matches(alternative.conditions, appearance) &&
            (specificity == null || alternative.specificity > specificity)) {
          specificity = alternative.specificity;
        }
      }
      if (specificity == null) {
        continue;
      }
      for (final CssDeclaration declaration in rule.declarations) {
        final rank = <int>[specificity, rule.fileIndex, declaration.line, declaration.index];
        final (List<int>, CssDeclaration)? current = best[declaration.name];
        if (current == null || _compare(rank, current.$1) > 0) {
          best[declaration.name] = (rank, declaration);
        }
      }
    }
    final resolved = <String, String>{};
    String resolve(String name, List<String> stack) {
      if (resolved[name] case final String value) {
        return value;
      }
      if (stack.contains(name)) {
        throw FormatException('var() cycle through $name');
      }
      final (List<int>, CssDeclaration)? entry = best[name];
      if (entry == null) {
        throw FormatException('var($name) is not declared');
      }
      final String value = _evaluateCalc(
        entry.$2.value.replaceAllMapped(RegExp(r'var\((--[\w-]+)\)'), (m) => resolve(m.group(1)!, [...stack, name])),
      );
      if (value.contains('var(')) {
        throw FormatException('unsupported var() in $name: $value');
      }
      return resolved[name] = value;
    }

    for (final String name in best.keys) {
      resolve(name, const <String>[]);
    }
    return resolved;
  }

  /// Every custom property [appearance] resolves to, parsed into the token layer's types ([parseCssValue]).
  Map<String, Object?> resolve(ZsAppearance appearance) => <String, Object?>{
    for (final MapEntry<String, String>(:key, :value) in resolveRaw(appearance).entries) key: parseCssValue(key, value),
  };

  /// The `@media (prefers-…)` copies that differ from their attribute twins, one message per token.
  ///
  /// A media rule's twin is the attribute rule whose alternatives equal the media rule's with the feature's
  /// attribute added (`:root` → `[data-transparency="reduce"]`); every declaration must match by name and value.
  List<String> mediaDrift() {
    final drift = <String>[];
    for (final CssRule rule in rules) {
      final String? media = rule.media;
      if (media == null) {
        continue;
      }
      final (String, String)? feature = _mediaFeatures[media];
      if (feature == null) {
        drift.add('${rule.file}:${rule.line}: unknown @media feature $media');
        continue;
      }
      final twinKey = <String>{
        for (final CssAlternative alternative in rule.alternatives)
          CssAlternative(<String, String?>{...alternative.conditions, feature.$1: feature.$2}, 0).key,
      };
      CssRule? twin;
      for (final CssRule candidate in rules) {
        if (candidate.media == null &&
            candidate.alternatives.map((a) => a.key).toSet().containsAll(twinKey) &&
            twinKey.containsAll(candidate.alternatives.map((a) => a.key))) {
          twin = candidate;
        }
      }
      final Map<String, String> copy = _declarations(rule);
      final Map<String, String> original = twin == null ? const <String, String>{} : _declarations(twin);
      for (final name in <String>{...copy.keys, ...original.keys}) {
        if (copy[name] != original[name]) {
          drift.add(
            '$name (${rule.file}:${rule.line}, @media $media): the @media copy says ${copy[name] ?? 'nothing'}, '
            'its attribute twin ${original[name] ?? 'nothing'}',
          );
        }
      }
    }
    return drift;
  }

  static Map<String, String> _declarations(CssRule rule) => <String, String>{
    for (final CssDeclaration declaration in rule.declarations)
      declaration.name: declaration.value.replaceAll(RegExp(r'\s+'), ''),
  };

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return a[i].compareTo(b[i]);
      }
    }
    return 0;
  }

  static bool _matches(Map<String, String?> conditions, ZsAppearance appearance) {
    for (final MapEntry<String, String?>(key: name, :value) in conditions.entries) {
      final bool holds = switch (name) {
        'theme' => value == appearance.theme.name,
        'accent' =>
          appearance.family != ZsAccentFamily.multicolor && (value == null || value == appearance.family.name),
        'contrast' => appearance.increasedContrast && value == 'more',
        'transparency' => appearance.reduceTransparency && value == 'reduce',
        'window' => appearance.inactive && value == 'inactive',
        'motion' => appearance.reduceMotion && value == 'reduce',
        'fullscreen' => appearance.fullScreen,
        'density' => appearance.density.name == value,
        _ => throw FormatException('unknown condition $name'),
      };
      if (!holds) {
        return false;
      }
    }
    return true;
  }
}

/// [text] with every comment replaced by spaces, so line numbers stay.
String _stripComments(String text) => text.replaceAllMapped(
  RegExp(r'/\*.*?\*/', dotAll: true),
  (m) => m.group(0)!.replaceAll(RegExp(r'[^\n]'), ' '),
);

/// Splits [text] at [separator] outside parentheses and brackets.
List<String> _splitTop(String text, String separator) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final String c = text[i];
    if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      depth--;
    } else if (c == separator && depth == 0) {
      parts.add(text.substring(start, i));
      start = i + 1;
    }
  }
  return parts..add(text.substring(start));
}

int _lineOf(String text, int offset) => '\n'.allMatches(text.substring(0, offset)).length + 1;

int _closing(String text, int open, String openChar, String closeChar) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == openChar) {
      depth++;
    } else if (text[i] == closeChar) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  throw FormatException('unbalanced $openChar at $open');
}

List<CssRule> _parseFile(String file, int fileIndex, String raw) {
  final String text = _stripComments(raw);
  final rules = <CssRule>[];
  void parseBlock(int start, int end, String? media) {
    var i = start;
    while (i < end) {
      while (i < end && text[i].trim().isEmpty) {
        i++;
      }
      if (i >= end) {
        return;
      }
      if (text.startsWith('@media', i)) {
        final int open = text.indexOf('{', i);
        final int close = _closing(text, open, '{', '}');
        final String feature = text.substring(i + 6, open).replaceAll(RegExp(r'[\s()]'), '');
        parseBlock(open + 1, close, feature);
        i = close + 1;
        continue;
      }
      final int open = text.indexOf('{', i);
      final int close = text.indexOf('}', open);
      final String selector = text.substring(i, open).trim();
      final String body = text.substring(open + 1, close);
      final declarations = <CssDeclaration>[];
      int offset = open + 1;
      for (final String part in _splitTop(body, ';')) {
        final String trimmed = part.trim();
        if (trimmed.startsWith('--')) {
          final int colon = trimmed.indexOf(':');
          declarations.add(
            CssDeclaration(
              trimmed.substring(0, colon).trim(),
              trimmed.substring(colon + 1).trim(),
              _lineOf(text, offset + part.indexOf('--')),
              declarations.length,
            ),
          );
        }
        offset += part.length + 1;
      }
      if (declarations.isNotEmpty) {
        rules.add(
          CssRule(
            file: file,
            fileIndex: fileIndex,
            line: _lineOf(text, i),
            alternatives: <CssAlternative>[
              for (final String alternative in _splitTop(selector, ',')) ..._parseCompound(alternative),
            ],
            declarations: declarations,
            media: media,
          ),
        );
      }
      i = close + 1;
    }
  }

  parseBlock(0, text.length, null);
  return rules;
}

/// The alternatives one compound selector stands for; none when it can never match one element.
List<CssAlternative> _parseCompound(String source) {
  final String text = source.trim();
  if (text.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), '').contains(RegExp(r'\s'))) {
    return const <CssAlternative>[];
  }
  var alternatives = <(Map<String, String?>, int)>[(<String, String?>{}, 0)];
  var i = 0;
  while (i < text.length) {
    if (text.startsWith(':root', i)) {
      alternatives = [for (final (c, s) in alternatives) (c, s + 1)];
      i += 5;
    } else if (text[i] == '[') {
      final int close = text.indexOf(']', i);
      final String body = text.substring(i + 1, close);
      final int eq = body.indexOf('=');
      final String attribute = eq < 0 ? body : body.substring(0, eq);
      final String? value = eq < 0 ? null : body.substring(eq + 1).replaceAll('"', '').replaceAll("'", '');
      final String? condition = _attributes[attribute];
      if (condition == null) {
        throw FormatException('unsupported attribute $attribute in "$source"');
      }
      alternatives = [
        for (final (c, s) in alternatives) (<String, String?>{...c, condition: value}, s + 1),
      ];
      i = close + 1;
    } else if (text.startsWith(':is(', i)) {
      final int close = _closing(text, i + 3, '(', ')');
      final List<List<CssAlternative>> arguments = [
        for (final String argument in _splitTop(text.substring(i + 4, close), ',')) _parseCompound(argument),
      ];
      var argumentSpecificity = 0;
      for (final argument in arguments) {
        for (final alternative in argument) {
          if (alternative.specificity > argumentSpecificity) {
            argumentSpecificity = alternative.specificity;
          }
        }
      }
      alternatives = [
        for (final (c, s) in alternatives)
          for (final List<CssAlternative> argument in arguments)
            for (final CssAlternative alternative in argument)
              (<String, String?>{...c, ...alternative.conditions}, s + argumentSpecificity),
      ];
      i = close + 1;
    } else {
      throw FormatException('unsupported selector "${text.substring(i)}" in "$source"');
    }
  }
  return <CssAlternative>[
    for (final (c, s) in alternatives)
      if (c['theme'] != 'light') CssAlternative(c, s),
  ];
}

/// Evaluates every `calc()` in [value] (+, −, ×, / over px lengths and plain numbers) to `<n>px`.
String _evaluateCalc(String value) {
  if (!value.startsWith('calc(')) {
    return value;
  }
  final List<String> tokens = RegExp(r'-?[\d.]+(px)?|[-+*/()]')
      .allMatches(value.substring(4))
      .map((m) => m.group(0)!)
      .toList();
  var position = 0;
  double expression() {
    double term() {
      double factor() {
        final String token = tokens[position++];
        if (token == '(') {
          final double inner = expression();
          position++; // ')'
          return inner;
        }
        return double.parse(token.replaceAll('px', ''));
      }

      double result = factor();
      while (position < tokens.length && (tokens[position] == '*' || tokens[position] == '/')) {
        final String operator = tokens[position++];
        final double right = factor();
        result = operator == '*' ? result * right : result / right;
      }
      return result;
    }

    double result = term();
    while (position < tokens.length && (tokens[position] == '+' || tokens[position] == '-')) {
      final String operator = tokens[position++];
      final double right = term();
      result = operator == '+' ? result + right : result - right;
    }
    return result;
  }

  final double result = expression();
  return '${result == result.roundToDouble() ? result.toInt() : result}px';
}

/// [value] of the token [name] as the token layer represents it: a [Color], a [ZsShadowStack], a gradient, a
/// [ZsGlassFilter] (`none` → null), a [Duration], a curve (a cubic as its four values, `linear` as [Curves.linear]),
/// a length or em value as a double, a percentage as its number, a plain number as an int or a double, a font
/// stack as its names joined by `, `, and a type role as `(weight, size, line height, stack)`.
Object? parseCssValue(String name, String value) {
  final String v = value.trim();
  if (name.startsWith('--font-')) {
    return _stack(v);
  }
  if (name.startsWith('--type-')) {
    final RegExpMatch? m = RegExp(r'^(\d+)\s+([\d.]+)px/([\d.]+)\s+(.+)$').firstMatch(v);
    if (m == null) {
      throw FormatException('unparsed type role $name: $v');
    }
    return (int.parse(m.group(1)!), double.parse(m.group(2)!), double.parse(m.group(3)!), _stack(m.group(4)!));
  }
  if (v == 'none') {
    return null;
  }
  if (v == 'linear') {
    return Curves.linear;
  }
  if (v.startsWith('cubic-bezier(')) {
    final List<double> c = v.substring(13, v.length - 1).split(',').map((p) => double.parse(p.trim())).toList();
    return (c[0], c[1], c[2], c[3]);
  }
  if (v.startsWith('blur(')) {
    final RegExpMatch m = RegExp(r'^blur\(([\d.]+)px\) saturate\(([\d.]+)\)$').firstMatch(v)!;
    return ZsGlassFilter(blur: double.parse(m.group(1)!), saturate: double.parse(m.group(2)!));
  }
  if (v.contains('gradient(')) {
    return _gradient(v);
  }
  if (_isColor(v)) {
    return _color(v);
  }
  if (v.contains(' ') && (v.contains('rgba(') || v.contains('#') || v.contains('transparent'))) {
    return ZsShadowStack(<ZsShadow>[for (final String part in _splitTop(v, ',')) _shadow(part)]);
  }
  final RegExpMatch? number = RegExp(r'^(-?[\d.]+)(px|ms|em|%)?$').firstMatch(v);
  if (number == null) {
    throw FormatException('unparsed value $name: $v');
  }
  final String digits = number.group(1)!;
  return switch (number.group(2)) {
    'ms' => Duration(milliseconds: int.parse(digits)),
    'px' || 'em' || '%' => double.parse(digits),
    _ => digits.contains('.') ? double.parse(digits) : int.parse(digits),
  };
}

String _stack(String value) => _splitTop(value, ',').map((f) => f.trim().replaceAll('"', '')).join(', ');

bool _isColor(String v) => v.startsWith('#') || v.startsWith('rgba(') || v == 'transparent';

Color _color(String v) {
  if (v == 'transparent') {
    return const Color.fromRGBO(0, 0, 0, 0);
  }
  if (v.startsWith('#')) {
    if (v.length != 7) {
      throw FormatException('only #rrggbb is supported: $v');
    }
    return Color(0xFF000000 | int.parse(v.substring(1), radix: 16));
  }
  final List<String> c = v.substring(5, v.length - 1).split(',').map((p) => p.trim()).toList();
  return Color.fromRGBO(int.parse(c[0]), int.parse(c[1]), int.parse(c[2]), double.parse(c[3]));
}

ZsShadow _shadow(String part) {
  List<String> tokens = _splitTop(part.trim(), ' ').where((t) => t.isNotEmpty).toList();
  final inset = tokens.first == 'inset';
  if (inset) {
    tokens = tokens.sublist(1);
  }
  final List<double> lengths = [for (final String t in tokens.sublist(0, tokens.length - 1)) _length(t)];
  while (lengths.length < 4) {
    lengths.add(0);
  }
  return ZsShadow(
    dx: lengths[0],
    dy: lengths[1],
    blur: lengths[2],
    spread: lengths[3],
    color: _color(tokens.last),
    inset: inset,
  );
}

double _length(String token) => double.parse(token.replaceAll('px', ''));

ZsGradientStop _stop(String text) {
  final String t = text.trim();
  final RegExpMatch? m = RegExp(r'^(.*\S)\s+(-?[\d.]+)(px|%)$').firstMatch(t);
  if (m == null) {
    return ZsGradientStop(_color(t));
  }
  final double at = double.parse(m.group(2)!);
  return m.group(3) == 'px'
      ? ZsGradientStop(_color(m.group(1)!), px: at)
      : ZsGradientStop(_color(m.group(1)!), percent: at);
}

ZsLinearGradient _linear(String text) {
  final List<String> args = _splitTop(text.substring(16, text.length - 1), ',');
  return ZsLinearGradient(
    angle: double.parse(args.first.trim().replaceAll('deg', '')),
    stops: <ZsGradientStop>[for (final String a in args.skip(1)) _stop(a)],
  );
}

Object _gradient(String value) {
  final List<String> layers = _splitTop(value, ',').map((l) => l.trim()).toList();
  if (layers.length == 1) {
    return _linear(layers.single);
  }
  final String radial = layers.first;
  final List<String> args = _splitTop(radial.substring(16, radial.length - 1), ',');
  final RegExpMatch m = RegExp(r'^(-?[\d.]+)% (-?[\d.]+)% at (-?[\d.]+)% (-?[\d.]+)%$').firstMatch(args.first.trim())!;
  return ZsCanvasGradient(
    radial: ZsRadialGradient(
      width: double.parse(m.group(1)!),
      height: double.parse(m.group(2)!),
      centerX: double.parse(m.group(3)!),
      centerY: double.parse(m.group(4)!),
      stops: <ZsGradientStop>[for (final String a in args.skip(1)) _stop(a)],
    ),
    linear: _linear(layers[1]),
  );
}

/// Compares the DS's resolved tokens [css] with the token layer's [app] for one appearance; every message names the
/// token, both values and [appearance].
List<String> compareTokens(Map<String, Object?> css, Map<String, Object?> app, String appearance) => <String>[
  for (final String name in <String>{...css.keys, ...app.keys})
    if (!css.containsKey(name))
      '$name [$appearance]: in the token layer (${_describe(app[name])}) but not in the DS'
    else if (!app.containsKey(name))
      '$name [$appearance]: in the DS (${_describe(css[name])}) but not in the token layer'
    else if (css[name] != app[name])
      '$name [$appearance]: the DS says ${_describe(css[name])}, the token layer ${_describe(app[name])}',
];

/// A colour as CSS writes it; anything else as itself.
String _describe(Object? value) {
  if (value is! Color) {
    return '$value';
  }
  String channel(double c) => (c * 255).round().toRadixString(16).padLeft(2, '0');
  final int r = (value.r * 255).round();
  final int g = (value.g * 255).round();
  final int b = (value.b * 255).round();
  return value.a == 1 ? '#${channel(value.r)}${channel(value.g)}${channel(value.b)}' : 'rgba($r,$g,$b,${value.a})';
}

/// A readable label for [appearance] in messages.
String appearanceLabel(ZsAppearance appearance) => <String>[
  appearance.theme.name,
  appearance.family.name,
  if (appearance.increasedContrast) 'increased contrast',
  if (appearance.reduceTransparency) 'reduce transparency',
  if (appearance.inactive) 'inactive',
  if (appearance.reduceMotion) 'reduce motion',
  if (appearance.fullScreen) 'full screen',
  if (appearance.density != ZsDensity.compact) appearance.density.name,
].join(', ');

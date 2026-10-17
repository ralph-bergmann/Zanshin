// SPDX-License-Identifier: MIT

import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:widgetbook/widgetbook.dart' show FieldCodec;
import 'package:zanshin_ui/zanshin_ui.dart';

import 'catalogue.dart';

/// The Marionette extension's name (`ext.flutter.zanshinCatalogue.open` on the VM service).
const catalogueExtensionName = 'zanshinCatalogue.open';

/// The extension's parameters besides `path`, in the Appearance addon's field names; the values are decoded by
/// [catalogueRoute].
const _appearanceParams = <String>['theme', 'accent', 'contrast', 'reduceMotion', 'reduceTransparency', 'inactive'];

const _flags = <String>{'contrast', 'reduceMotion', 'reduceTransparency', 'inactive'};

/// Registers `zanshinCatalogue.open` (debug builds only): an agent opens a use case by its path in a given
/// appearance, `path=controls/switch/state-matrix&theme=paper`, and the catalogue at [state] shows it.
void registerCatalogueExtension(ZanshinCatalogueState Function() state) => registerMarionetteExtension(
  name: catalogueExtensionName,
  description:
      'Opens a catalogue use case by its Widgetbook path (names joined by "/", spaces as "-", lower case) '
      'in an appearance.',
  inputSchema: ExtensionInputSchema(
    properties: <String, ExtensionParam>{
      'path': const ExtensionParam.string(description: 'The use case, e.g. controls/switch/state-matrix'),
      'theme': ExtensionParam.string(
        description: 'The theme',
        enumValues: <String>[for (final ZsTheme theme in ZsTheme.values) theme.name],
      ),
      'accent': ExtensionParam.string(
        description: 'The accent family',
        enumValues: <String>[for (final ZsAccentFamily family in ZsAccentFamily.values) family.name],
      ),
      for (final String flag in _flags) flag: ExtensionParam.boolean(description: 'The $flag flag'),
    },
    required: const <String>['path'],
  ),
  callback: (params) async => openInCatalogue(params, state()),
);

/// What `zanshinCatalogue.open` does: shows the route for [params] in [catalogue], or answers with invalid params
/// naming what is wrong.
MarionetteExtensionResult openInCatalogue(Map<String, String> params, ZanshinCatalogueState catalogue) {
  final String route;
  try {
    route = catalogueRoute(params, paths: catalogueUseCasePaths);
  } on FormatException catch (error) {
    return MarionetteExtensionResult.invalidParams(error.message);
  }
  catalogue.open(route);
  return MarionetteExtensionResult.success(<String, dynamic>{'route': route});
}

/// The Widgetbook route for [params] — `/?path=<path>&appearance={theme:paper,…}` — or a [FormatException] naming
/// the first parameter that is missing or not one of the allowed values ([paths] for `path`).
String catalogueRoute(Map<String, String> params, {required Set<String> paths}) {
  final String? path = params['path'];
  if (path == null || !paths.contains(path)) {
    throw FormatException('Unknown use case path "$path".');
  }
  final appearance = <String, String>{};
  for (final String name in _appearanceParams) {
    final String? value = params[name];
    if (value == null) {
      continue;
    }
    final bool valid = switch (name) {
      'theme' => ZsTheme.values.any((theme) => theme.name == value),
      'accent' => ZsAccentFamily.values.any((family) => family.name == value),
      _ => value == 'true' || value == 'false',
    };
    if (!valid) {
      throw FormatException('Invalid $name "$value".');
    }
    appearance[name] = value;
  }
  return Uri(
    path: '/',
    queryParameters: <String, String>{
      'path': path,
      if (appearance.isNotEmpty) 'appearance': FieldCodec.encodeQueryGroup(appearance),
    },
  ).toString();
}

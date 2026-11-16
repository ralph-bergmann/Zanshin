// SPDX-License-Identifier: MIT

import '../../l10n/strings.dart';

/// The characters a ref name may not hold: git's refused `~ ^ : ? * [ \`, U+0000–U+001F and U+007F (git
/// check-ref-format), plus any whitespace — stricter than git on purpose (git allows U+00A0, U+2028, …), as the Refs
/// Study does. Each is one UTF-16 unit, so replacing them keeps the length.
final _refused = RegExp(r'[\s~^:?*\[\\\x00-\x1f\x7f]');

/// [text] with any whitespace and every character git refuses in a ref name replaced by `_` (Story 10.46); the length
/// stays, so a text field's selection stays valid.
String graphCleanRefName(String text) => text.replaceAll(_refused, '_');

/// The first whole-name rule [text] breaks, or null when it is empty or valid (Story 10.46): a lone `@`; starts with
/// `/`; ends with `/`; starts with `.`; ends with `.lock`; ends with `.`; contains `..`; contains `//`; contains `@{`.
/// `@` elsewhere stays allowed.
String? graphRefNameError(AppLocalizations strings, String text) => text.isEmpty
    ? null
    : text == '@'
    ? strings.refNameAlone('@')
    : text.startsWith('/')
    ? strings.refNameStart('/')
    : text.endsWith('/')
    ? strings.refNameEnd('/')
    : text.startsWith('.')
    ? strings.refNameStart('.')
    : text.endsWith('.lock')
    ? strings.refNameEnd('.lock')
    : text.endsWith('.')
    ? strings.refNameEnd('.')
    : text.contains('..')
    ? strings.refNameContain('..')
    : text.contains('//')
    ? strings.refNameContain('//')
    : text.contains('@{')
    ? strings.refNameContain('@{')
    : null;

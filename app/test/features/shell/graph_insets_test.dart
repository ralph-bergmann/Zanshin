// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/graph_insets.dart';

void main() {
  const insets = GraphInsets(top: 60, left: 388, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 0);

  test('equal values are equal and hash alike; every field counts', () {
    expect(
      insets,
      const GraphInsets(top: 60, left: 388, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 0),
    );
    expect(
      insets.hashCode,
      const GraphInsets(top: 60, left: 388, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 0).hashCode,
    );
    for (final other in const <GraphInsets>[
      GraphInsets(top: 68, left: 388, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 0),
      GraphInsets(top: 60, left: 76, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 0),
      GraphInsets(top: 60, left: 388, right: 158, bottom: 12, inspectorWidth: 460, minimapWidth: 0),
      GraphInsets(top: 60, left: 388, right: 484, bottom: 0, inspectorWidth: 460, minimapWidth: 0),
      GraphInsets(top: 60, left: 388, right: 484, bottom: 12, inspectorWidth: 380, minimapWidth: 0),
      GraphInsets(top: 60, left: 388, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 134),
    ]) {
      expect(insets, isNot(other));
    }
  });

  test('the visible rect is the window less the insets', () {
    expect(insets.visibleRect(const Size(1440, 900)), const Rect.fromLTRB(388, 60, 956, 888));
  });

  test('toString names every field', () {
    expect(
      insets.toString(),
      'GraphInsets(top: 60.0, left: 388.0, right: 484.0, bottom: 12.0, inspectorWidth: 460.0, minimapWidth: 0.0)',
    );
  });
}

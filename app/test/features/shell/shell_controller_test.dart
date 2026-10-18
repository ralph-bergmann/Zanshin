// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/calm_controller.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/shell/shell_layout.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

Future<void> _ms(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

ShellController _controller({List<double>? panels, List<double>? inspectors}) {
  final controller = ShellController(
    onPanelWidthCommitted: panels?.add,
    onInspectorWidthCommitted: inspectors?.add,
  );
  addTearDown(controller.dispose);
  return controller;
}

/// Lays [controller] out in a [width] wide window, the inspector open unless [inspector] is false.
ShellLayout _lay(ShellController controller, double width, {bool inspector = true}) => controller.layoutFor(
  windowWidth: width,
  metrics: ZsMetrics.standard,
  inspectorOpen: inspector,
  minimapShown: false,
);

void main() {
  testWidgets('the preview opens 90 ms after entering (not at 89), switches at once and closes 200 ms after leaving', (
    tester,
  ) async {
    final ShellController shell = _controller()..railEnter('bookmarks');
    await _ms(tester, 89);
    expect(shell.previewId, isNull);
    await _ms(tester, 1);
    expect(shell.previewId, 'bookmarks');
    shell.railEnter('undo');
    expect(shell.previewId, 'undo', reason: 'an open preview switches at once');
    shell.railExit();
    await _ms(tester, 199);
    expect(shell.previewId, 'undo');
    await _ms(tester, 1);
    expect(shell.previewId, isNull);
  });

  testWidgets('entering the preview cancels its close; leaving it closes it 200 ms later', (tester) async {
    final ShellController shell = _controller()..railEnter('bookmarks');
    await _ms(tester, 90);
    shell
      ..railExit()
      ..previewEnter();
    await _ms(tester, 300);
    expect(shell.previewId, 'bookmarks');
    shell.previewExit();
    await _ms(tester, 200);
    expect(shell.previewId, isNull);
  });

  testWidgets('a click pins and closes the preview; another moves the pin; the pinned one unpins', (tester) async {
    final ShellController shell = _controller()..railEnter('bookmarks');
    await _ms(tester, 90);
    shell.activate('bookmarks');
    expect(shell.pinnedId, 'bookmarks');
    expect(shell.previewId, isNull);
    shell.railEnter('bookmarks');
    await _ms(tester, 200);
    expect(shell.previewId, isNull, reason: 'the pinned item shows no preview');
    shell.activate('undo');
    expect(shell.pinnedId, 'undo');
    expect(shell.flyoutOpen, isFalse);
    shell.activate('undo');
    expect(shell.pinnedId, isNull);
  });

  testWidgets('the pinned item entering closes an open preview at once', (tester) async {
    final ShellController shell = _controller()
      ..activate('undo')
      ..railEnter('bookmarks');
    await _ms(tester, 90);
    shell.railEnter('undo');
    expect(shell.previewId, isNull);
  });

  testWidgets('without room a click pins the item collapsed and shows the flyout; Esc and the outside keep the pin', (
    tester,
  ) async {
    final ShellController shell = _controller()..activate('undo');
    expect(_lay(shell, 1000).collapsed, isTrue);
    shell.activate('bookmarks');
    expect(shell.pinnedId, 'bookmarks');
    expect(shell.flyoutOpen, isTrue);
    final ShellLayout layout = _lay(shell, 1000);
    expect(layout.collapsed, isTrue);
    expect(layout.insets.left, 76, reason: 'the flyout changes no inset');
    expect(shell.handleEscape(), isTrue);
    expect(shell.flyoutOpen, isFalse);
    expect(shell.pinnedId, 'bookmarks');
    shell.activate('bookmarks');
    expect(shell.flyoutOpen, isTrue, reason: 'a click on the collapsed pin shows the flyout');
    shell.closeFlyout();
    expect(shell.pinnedId, 'bookmarks');
    shell
      ..activate('bookmarks')
      ..activate('bookmarks');
    expect(shell.flyoutOpen, isFalse);
    expect(shell.pinnedId, isNull, reason: 'a click while the flyout shows closes it and unpins');
    expect(shell.collapsed, isFalse, reason: 'unpinning clears the collapse');
  });

  testWidgets('a pin from nothing in a window without room shows the flyout; widening shows the panel instead', (
    tester,
  ) async {
    final ShellController shell = _controller();
    _lay(shell, 1000);
    shell.activate('bookmarks');
    expect(shell.flyoutOpen, isTrue);
    expect(_lay(shell, 1000).collapsed, isTrue);
    expect(_lay(shell, 1200).collapsed, isFalse);
    expect(shell.flyoutOpen, isFalse);
    expect(shell.pinnedId, 'bookmarks');
  });

  testWidgets('Esc closes the preview first, then the flyout, and is not handled with neither open', (tester) async {
    final ShellController shell = _controller();
    _lay(shell, 1000);
    shell
      ..activate('bookmarks')
      ..railEnter('undo');
    await _ms(tester, 90);
    expect(shell.previewId, 'undo');
    expect(shell.handleEscape(), isTrue);
    expect(shell.previewId, isNull);
    expect(shell.flyoutOpen, isTrue);
    expect(shell.handleEscape(), isTrue);
    expect(shell.flyoutOpen, isFalse);
    expect(shell.handleEscape(), isFalse);
  });

  testWidgets('an inactive window opens no preview, and turning inactive closes an open one', (tester) async {
    final ShellController shell = _controller()
      ..inactive = true
      ..railEnter('bookmarks');
    await _ms(tester, 200);
    expect(shell.previewId, isNull);
    shell
      ..inactive = false
      ..railEnter('bookmarks');
    await _ms(tester, 90);
    expect(shell.previewId, 'bookmarks');
    shell.inactive = true;
    expect(shell.previewId, isNull);
    expect(shell.inactive, isTrue);
  });

  testWidgets('an open preview and an open flyout hold calm', (tester) async {
    final ShellController shell = _controller()..railEnter('bookmarks');
    await _ms(tester, 90);
    shell.reportUserScroll(100);
    expect(shell.calm.value.calm, isFalse);
    shell.closePreview();
    _lay(shell, 1000);
    shell
      ..activate('undo')
      ..reportUserScroll(100);
    expect(shell.flyoutOpen, isTrue);
    expect(shell.calm.value.calm, isFalse);
    shell
      ..closeFlyout()
      ..reportUserScroll(31);
    expect(shell.calm.value.calm, isTrue);
    await _ms(tester, 650);
  });

  testWidgets('a calm phase cancels a pending preview, and no preview opens while it runs', (tester) async {
    final ShellController shell = _controller()..railEnter('bookmarks');
    await _ms(tester, 50);
    shell.reportUserScroll(31);
    await _ms(tester, 100);
    expect(shell.previewId, isNull);
    shell.railEnter('undo');
    await _ms(tester, 100);
    expect(shell.previewId, isNull);
    await _ms(tester, 650);
  });

  testWidgets('an edge drag and an item drag block previews and calm until they end', (tester) async {
    final ShellController shell = _controller()..edgeDragStarted();
    expect(shell.edgeDragging, isTrue);
    shell
      ..railEnter('bookmarks')
      ..reportUserScroll(100);
    await _ms(tester, 100);
    expect(shell.previewId, isNull);
    expect(shell.calm.value.calm, isFalse);
    shell.edgeDragEnded();
    expect(shell.edgeDragging, isFalse);

    final CalmHold drag = shell.startItemDrag();
    expect(shell.itemDragging, isTrue);
    shell.reportUserScroll(100);
    expect(shell.calm.value.calm, isFalse);
    drag
      ..release()
      ..release();
    expect(shell.itemDragging, isFalse);
    final CalmHold menu = shell.openSurface();
    shell.reportUserScroll(100);
    expect(shell.calm.value.calm, isFalse);
    menu.release();
    shell.reportUserScroll(31);
    expect(shell.calm.value.calm, isTrue);
    await _ms(tester, 650);
  });

  test('widths change live and are reported once per commit; Hide controls reaches the calm controller', () {
    final panels = <double>[];
    final inspectors = <double>[];
    final ShellController shell = _controller(panels: panels, inspectors: inspectors);
    var notified = 0;
    shell
      ..addListener(() => notified++)
      ..panelWidth = 320
      ..inspectorWidth = 500;
    expect(notified, 2);
    expect(panels, isEmpty);
    shell
      ..commitPanelWidth(330)
      ..commitInspectorWidth(510);
    expect(panels, <double>[330]);
    expect(inspectors, <double>[510]);
    expect(shell.panelWidth, 330);
    shell.hideControls = false;
    expect(shell.calm.hideControls, isFalse);
    expect(shell.hideControls, isFalse);
  });

  test('unpin with nothing pinned does nothing', () {
    final ShellController shell = _controller();
    var notified = 0;
    shell
      ..addListener(() => notified++)
      ..unpin()
      ..closeFlyout();
    expect(notified, 0);
  });
}

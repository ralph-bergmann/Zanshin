// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';

import '../home/home_page.dart';
import '../window/app_windows.dart' show mainWindowKey;
import '../window/zanshin_window_root.dart';

part 'zanshin_app.factory.dart';

/// The project window's content (Story 11.12): [HomePage] under the window root every app window uses,
/// [ZanshinWindowRoot], keyed `window:main`.
class ZanshinApp extends StatelessWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    required this._rootFactory,
    @assisted super.key,
  });

  final HomePageFactory _homePageFactory;
  final ZanshinWindowRootFactory _rootFactory;

  @override
  Widget build(BuildContext context) => _rootFactory.create(windowKey: mainWindowKey, child: _homePageFactory.create());
}

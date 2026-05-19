// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:inject_annotation/inject_annotation.dart';

import '../home/home_page.dart';

part 'zanshin_app.factory.dart';

@immutable
class ZanshinApp extends StatelessWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    @assisted super.key,
  });

  final HomePageFactory _homePageFactory;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: _homePageFactory.create(),
  );
}

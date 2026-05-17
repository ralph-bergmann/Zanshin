// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../home/home_page.dart';

@immutable
class ZanshinApp extends StatelessWidget {
  const ZanshinApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: HomePage(),
  );
}

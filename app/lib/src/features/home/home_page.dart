// SPDX-License-Identifier: Apache-2.0

import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../../ffi/zanshin_version.dart';

@immutable
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    String label;
    try {
      label = zanshinFfiVersion();
    } catch (e, st) {
      developer.log(
        'zanshinFfiVersion() failed: $e',
        stackTrace: st,
        name: 'zanshin',
      );
      label = '(version unavailable)';
    }
    return Scaffold(body: Center(child: Text(label)));
  }
}

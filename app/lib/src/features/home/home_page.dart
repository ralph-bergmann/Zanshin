// SPDX-License-Identifier: Apache-2.0

import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:inject_annotation/inject_annotation.dart';

import '../../ffi/zanshin_version.dart';

part 'home_page.factory.dart';

@immutable
class HomePage extends StatelessWidget {
  @assistedInject
  HomePage({
    @assisted super.key,
    required this.zanshinFfiVersion,
  });

  ZanshinFfiVersion zanshinFfiVersion;

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

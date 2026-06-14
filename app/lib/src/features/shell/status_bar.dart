// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import '../../shared/theme/zanshin_colors.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({
    required this.currentBranch,
    required this.openColumns,
    super.key,
  });

  final String currentBranch;
  final int openColumns;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    return Container(
      height: 25,
      decoration: BoxDecoration(
        color: zc.bgWindow,
        border: Border(top: BorderSide(color: zc.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          _StatusItem(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Text(
                  '@',
                  style: TextStyle(color: zc.textPrimary, fontWeight: FontWeight.bold, fontSize: 11),
                ),
                Text(currentBranch, style: TextStyle(color: zc.textMuted, fontSize: 11)),
              ],
            ),
          ),
          _StatusItem(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 5,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(color: Color(0xFF4ade80), shape: BoxShape.circle),
                ),
                Text('repo clean', style: TextStyle(color: zc.textMuted, fontSize: 11)),
              ],
            ),
          ),
          _StatusItem(
            child: Text('142 ops', style: TextStyle(color: zc.textMuted, fontSize: 11)),
          ),
          _StatusItem(
            child: Text(
              '$openColumns column${openColumns == 1 ? '' : 's'} open',
              style: TextStyle(color: zc.textMuted, fontSize: 11),
            ),
          ),
          const Spacer(),
          _StatusItem(
            child: Text('jj 0.24.0', style: TextStyle(color: zc.textDim, fontSize: 11)),
          ),
          _StatusItem(
            child: Text('flutter 3.44.0', style: TextStyle(color: zc.textDim, fontSize: 11)),
          ),
          _StatusKbd(label: '⌘K', text: 'palette', zc: zc),
        ],
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  const _StatusItem({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 14),
    child: child,
  );
}

class _StatusKbd extends StatelessWidget {
  const _StatusKbd({required this.label, required this.text, required this.zc});
  final String label;
  final String text;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: zc.bgCard2,
          border: Border.all(color: zc.border),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 10, color: zc.textMuted, fontFamily: 'monospace'),
        ),
      ),
      Text(text, style: TextStyle(fontSize: 11, color: zc.textDim)),
    ],
  );
}

// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// One commit card. The viewport sizes it tightly; the delegate wraps it in a
/// RepaintBoundary, so each card is its own layer.
class CommitCard extends StatelessWidget {
  const CommitCard({required this.row, required this.color, required this.onTap, super.key});

  final int row;
  final Color color;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => onTap(row),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: const Color(0xFF23252B),
        border: Border.all(color: color, width: 1.5),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Text(
        'commit #$row',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFE8E8E8), fontSize: 13),
      ),
    ),
  );
}

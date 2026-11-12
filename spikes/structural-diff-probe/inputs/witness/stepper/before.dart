// Ralph's three stepper.dart examples (Story 10.32's `_DemoDetails`), embedded in one synthetic file.
import 'package:flutter/widgets.dart';

class StepperButton extends StatelessWidget {
  const StepperButton({super.key, required this.isLastStep, required this.s});

  final bool isLastStep;
  final Strings s;

  @override
  Widget build(BuildContext context) => FilledButton(
    child: Text(isLastStep ? s.functionWizard_save : s.functionWizard_next),
  );
}

class StepperLine extends StatelessWidget {
  const StepperLine({super.key, required this.isFirst, required this.lineColor});

  final bool isFirst;
  final Color lineColor;

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: _Line(color: isFirst ? null : lineColor)),
    DecoratedBox(
      decoration: BoxDecoration(color: lineColor),
      child: const SizedBox(width: 8, height: 8),
    ),
  ]);
}

class _Line extends StatelessWidget {
  const _Line({required this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) => ColoredBox(color: color ?? const Color(0x00000000));
}

Widget stepLabel(Widget label) => Padding(
  padding: Spacing.spacing8,
  child: label,
);

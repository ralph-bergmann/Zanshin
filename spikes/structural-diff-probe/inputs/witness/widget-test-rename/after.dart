// Ralph's widget-test example (epics.md, Story 5.9's decision note), framed so difft parses it.
void main() {
  void prepare() {
    run(() {
    });
  }

  // The tablet shows the long label. The phone app bar has little room and shows the short one.
  testWidgets('shows Speichern instead of Weiter on the last step on a phone', (tester) async {
    await openWizard(tester, size: phone);
    await fillGeneralStep(tester);

    for (var i = 0; i < 3; i++) {
      await tester.tap(withIdentifier(SemanticsIdentifiers.functionWizard_next));
      await tester.pumpAndSettle();
    }

    expect(find.text('Speichern'), findsWidgets);
    expect(find.text('Funktion speichern'), findsNothing);
    expect(find.text('Weiter'), findsNothing);
  });

  testWidgets('shows Funktion speichern instead of Weiter on the last step on a tablet', (tester) async {
    await openWizard(tester, size: tablet);
    await fillGeneralStep(tester);
  });
}

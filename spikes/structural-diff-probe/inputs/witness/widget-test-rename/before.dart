// Ralph's widget-test example (epics.md, Story 5.9's decision note), framed so difft parses it.
void main() {
  void prepare() {
    run(() {
    });
  }

  // Tablet only: the wide test font overflows the compact app bar, which holds the buttons on a phone.
  // The phone layout is checked on a device.
  testWidgets('shows Funktion speichern instead of Weiter on the last step', (tester) async {
    await openWizard(tester, size: tablet);
    await fillGeneralStep(tester);
  });
}

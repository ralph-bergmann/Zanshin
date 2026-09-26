// A minimal test harness: the package has no dependencies beyond the SDK (SPEC §10),
// so no package:test. Run with `dart run test/layout_test.dart`; exit code 1 on failure.
import 'dart:io';

int _passed = 0;
int _failed = 0;

void test(String name, void Function() body) {
  try {
    body();
    _passed++;
  } on Object catch (e, st) {
    _failed++;
    stderr.writeln('FAIL  $name\n  $e\n${st.toString().split('\n').take(6).join('\n')}');
  }
}

void expectEq(Object? actual, Object? expected, [String what = '']) {
  if (!_equal(actual, expected)) {
    throw StateError('${what.isEmpty ? '' : '$what: '}expected $expected, got $actual');
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void expectThrows<T extends Object>(void Function() body, [String what = '']) {
  try {
    body();
  } on T {
    return;
  }
  throw StateError('${what.isEmpty ? '' : '$what: '}expected a $T');
}

void finish() {
  stdout.writeln('$_passed passed, $_failed failed');
  if (_failed > 0) exitCode = 1;
}

bool _equal(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equal(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

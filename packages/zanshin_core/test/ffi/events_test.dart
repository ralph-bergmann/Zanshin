// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeEventEnvelope] using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s — no real cdylib required.
//
// A real-cdylib coverage seam test for `zanshin_events_register`/`unregister`
// (the extern-fn attribution trap — cargo-llvm-cov does not credit a
// no_mangle extern fn called only from cargo tests) also lives here, mirroring
// `zanshin_version_test.dart`'s split of decode-contract vs. seam coverage.
// The worker E2E round-trip (test/worker/events_test.dart) exercises the full
// producer chain (dispatch thread → sink → NativeCallable → decode) end to end.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bindings.dart' as bindings;
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/events.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('decodeEventEnvelope decode contract', () {
    test('throws ffi.unknown on non-event payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeEventEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes WatcherEventKind.OpHeadsChanged with paths', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WatcherEvent,
        data: fbs.WatcherEventObjectBuilder(
          repoHandle: 42,
          kind: fbs.WatcherEventKind.OpHeadsChanged,
          paths: ['.jj/repo/op_heads/heads/abc'],
        ),
      ).toBytes();

      final ZanshinRawEvent event = decodeEventEnvelope(bytes);
      expect(event, isA<RawOpHeadsChangedEvent>());
      final raw = event as RawOpHeadsChangedEvent;
      expect(raw.repoHandle, 42);
      expect(raw.paths, ['.jj/repo/op_heads/heads/abc']);
    });

    test('decodes WatcherEventKind.WorkingCopyHeartbeat with paths', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WatcherEvent,
        data: fbs.WatcherEventObjectBuilder(
          repoHandle: 7,
          kind: fbs.WatcherEventKind.WorkingCopyHeartbeat,
          paths: ['.jj/working_copy/checkout'],
        ),
      ).toBytes();

      final ZanshinRawEvent event = decodeEventEnvelope(bytes);
      expect(event, isA<RawWorkingCopyHeartbeatEvent>());
      final raw = event as RawWorkingCopyHeartbeatEvent;
      expect(raw.repoHandle, 7);
      expect(raw.paths, ['.jj/working_copy/checkout']);
    });

    test('decodes WatcherEventKind.WatchError with message, no paths (null-for-absence)', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WatcherEvent,
        data: fbs.WatcherEventObjectBuilder(
          repoHandle: 9,
          kind: fbs.WatcherEventKind.WatchError,
          message: 'boom',
        ),
      ).toBytes();

      final ZanshinRawEvent event = decodeEventEnvelope(bytes);
      expect(event, isA<RawWatchErrorEvent>());
      final raw = event as RawWatchErrorEvent;
      expect(raw.repoHandle, 9);
      expect(raw.message, 'boom');
    });

    test('decodes Progress payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Progress,
        data: fbs.ProgressObjectBuilder(repoHandle: 5, operation: 'fetch', progress: 0.5, message: 'halfway'),
      ).toBytes();

      final ZanshinRawEvent event = decodeEventEnvelope(bytes);
      expect(event, isA<RawProgressEvent>());
      final raw = event as RawProgressEvent;
      expect(raw.repoHandle, 5);
      expect(raw.operation, 'fetch');
      expect(raw.progress, 0.5);
      expect(raw.message, 'halfway');
    });

    test('missing paths on OpHeadsChanged decodes to an empty list, not null', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WatcherEvent,
        data: fbs.WatcherEventObjectBuilder(
          repoHandle: 1,
          kind: fbs.WatcherEventKind.OpHeadsChanged,
          // paths omitted → null on wire.
        ),
      ).toBytes();

      final raw = decodeEventEnvelope(bytes) as RawOpHeadsChangedEvent;
      expect(raw.paths, isEmpty);
    });
  });

  group('zanshin_events_register/unregister FFI seam (real cdylib)', () {
    test('register then unregister round-trips through the cdylib without throwing', () {
      final callable = ffi.NativeCallable<ffi.Void Function(ffi.Pointer<bindings.ZanshinBuf>)>.listener(
        (ffi.Pointer<bindings.ZanshinBuf> token) {},
      );
      try {
        bindings.zanshin_events_register(callable.nativeFunction);
        bindings.zanshin_events_unregister();
      } finally {
        callable.close();
      }
    });
  });
}

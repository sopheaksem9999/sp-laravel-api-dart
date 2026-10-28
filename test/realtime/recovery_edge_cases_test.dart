import 'dart:async';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/scripted_transport.dart';
import '../support/until.dart';

SpRealtime _client(
  ScriptedTransport transport, {
  Dio? dio,
  Duration subscribeTimeout = const Duration(seconds: 10),
  Duration subscribeBackoff = const Duration(milliseconds: 5),
  int subscribeAttempts = 3,
  void Function(String channel, Object error)? onSubscribeFailed,
}) => SpRealtime(
  apiBaseUrl: Uri.parse('https://example.com/api/v1'),
  driver: Driver.reverb(host: 'ws.example.com', port: 8080, appKey: 'k'),
  tokenProvider: () async => 'token',
  transport: transport,
  dio: dio ?? Dio(),
  reconnectDelay: const Duration(milliseconds: 5),
  subscribeTimeout: subscribeTimeout,
  subscribeBackoff: subscribeBackoff,
  subscribeAttempts: subscribeAttempts,
  onSubscribeFailed: onSubscribeFailed,
);

/// A real elapsed wait: only for deliberate negative windows, or to let an
/// internal timer (not observable from the test) run out.
Future<void> _tick([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test(
    'concurrent subscribers share the first auth failure without a second auth call (M1)',
    () async {
      var authCalls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              authCalls++;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 403,
                    data: {'message': 'denied'},
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );
      final t = ScriptedTransport();
      final rt = _client(t, dio: dio);
      await rt.connect();

      final a = rt.subscribe('private-orders.1', onEvent: (_) {});
      final b = rt.subscribe('private-orders.1', onEvent: (_) {});
      Object? errorA;
      Object? errorB;
      try {
        await a;
      } catch (e) {
        errorA = e;
      }
      try {
        await b;
      } catch (e) {
        errorB = e;
      }

      expect(errorA, isA<SpApiError>());
      expect(identical(errorA, errorB), isTrue);
      expect(authCalls, 1);
      expect(t.framesSent('pusher:subscribe'), 0);
      await rt.dispose();
    },
  );

  test(
    'a rejoin confirmed late, during its backoff, sends no more frames (M3)',
    () async {
      final failures = <String>[];
      final t = ScriptedTransport();
      final rt = _client(
        t,
        subscribeTimeout: const Duration(milliseconds: 100),
        subscribeBackoff: const Duration(milliseconds: 500),
        onSubscribeFailed: (channel, _) => failures.add(channel),
      );
      await rt.connect();
      await rt.subscribe('public-orders', onEvent: (_) {});

      t.autoConfirm = false;
      t.drop();
      await until(() => t.framesSent('pusher:subscribe', 'public-orders') == 2);
      // The 100 ms rejoin timeout is internal: let it run out, so the attempt
      // is in its 500 ms backoff.
      await _tick(150);
      t.confirm('public-orders'); // the late confirmation

      await _tick(600); // negative window: past the backoff, no more frames
      expect(t.framesSent('pusher:subscribe', 'public-orders'), 2);
      expect(failures, isEmpty);
      await rt.dispose();
    },
  );

  test(
    'a throwing onSubscribeFailed neither stops onRecovered nor escapes (M4)',
    () async {
      final events = <String>[];
      final uncaught = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final t = ScriptedTransport();
          final rt = _client(
            t,
            subscribeTimeout: const Duration(milliseconds: 20),
            onSubscribeFailed: (channel, _) {
              events.add('failed:$channel');
              throw StateError('app callback bug');
            },
          );
          rt.onRecovered(() async => events.add('recovered'));
          await rt.connect();
          await rt.subscribe('public-orders', onEvent: (_) {});

          t.autoConfirm = false;
          t.drop();
          await until(() => events.length >= 2);
          await rt.dispose();
        } finally {
          done.complete();
        }
      }, (error, _) => uncaught.add(error));
      await done.future;

      expect(uncaught, isEmpty);
      expect(events, ['recovered', 'failed:public-orders']);
    },
  );

  test(
    'unsubscribing the last unconfirmed channel during recovery completes it (M5)',
    () async {
      final t = ScriptedTransport();
      final rt = _client(t, subscribeTimeout: const Duration(seconds: 5));
      var recovered = 0;
      rt.onRecovered(() async => recovered++);
      await rt.connect();
      await rt.subscribe('public-a', onEvent: (_) {});
      final unsubB = await rt.subscribe('public-b', onEvent: (_) {});

      t.autoConfirm = false;
      t.drop();
      await until(
        () =>
            t.framesSent('pusher:subscribe', 'public-a') == 2 &&
            t.framesSent('pusher:subscribe', 'public-b') == 2,
      );
      t.confirm('public-a');
      await _tick(20); // negative window: must not complete early
      expect(recovered, 0); // still waiting for public-b

      unsubB();
      await until(() => recovered == 1);
      expect(recovered, 1);
      await rt.dispose();
    },
  );

  test(
    'a timed-out subscriber that was the last on a rejoining channel completes recovery (M5)',
    () async {
      final t = ScriptedTransport();
      final rt = _client(
        t,
        subscribeTimeout: const Duration(milliseconds: 100),
        subscribeBackoff: const Duration(milliseconds: 500),
      );
      var recovered = 0;
      rt.onRecovered(() async => recovered++);
      await rt.connect();
      await rt.subscribe('public-a', onEvent: (_) {});
      final unsubB1 = await rt.subscribe('public-b', onEvent: (_) {});

      t.autoConfirm = false;
      t.drop();
      await until(
        () =>
            t.framesSent('pusher:subscribe', 'public-a') == 2 &&
            t.framesSent('pusher:subscribe', 'public-b') == 2,
      ); // rejoin frames sent
      t.confirm('public-a');
      final b2 = rt.subscribe('public-b', onEvent: (_) {});
      unsubB1(); // b2 is now the only subscriber of public-b
      await expectLater(
        b2,
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.timeout,
          ),
        ),
      );
      await until(() => recovered == 1); // while still in the rejoin backoff
      expect(recovered, 1);
      await rt.dispose();
    },
  );
}

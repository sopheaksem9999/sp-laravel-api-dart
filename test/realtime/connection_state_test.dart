import 'dart:async';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/scripted_transport.dart';

SpRealtime _client(
  ScriptedTransport transport, {
  Duration reconnectDelay = const Duration(minutes: 10),
  Duration activityTimeout = const Duration(seconds: 120),
  Duration pongTimeout = const Duration(seconds: 30),
}) => SpRealtime(
  apiBaseUrl: Uri.parse('https://example.com/api/v1'),
  driver: Driver.reverb(host: 'ws.example.com', port: 8080, appKey: 'k'),
  tokenProvider: () async => 'token',
  transport: transport,
  dio: Dio(),
  reconnectDelay: reconnectDelay,
  activityTimeout: activityTimeout,
  pongTimeout: pongTimeout,
);

Future<void> _tick([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Runs [body] in a guarded zone and returns the errors nobody handled.
Future<List<Object>> _uncaughtErrors(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await body();
    } finally {
      done.complete();
    }
  }, (error, _) => errors.add(error));
  await done.future;
  await _tick();
  return errors;
}

void main() {
  group('failed connect', () {
    test('a later connect() tries again instead of returning the failure', () async {
      final t = ScriptedTransport()..failConnects = 1;
      final rt = _client(t);

      await expectLater(rt.connect(), throwsA(isA<StateError>()));
      await rt.connect().timeout(const Duration(seconds: 1));

      expect(t.connectCount, 2);
      expect(rt.isConnected, isTrue);
      await rt.dispose();
    });

    test('a transport that throws synchronously does not stick', () async {
      final t = ScriptedTransport()
        ..failConnects = 1
        ..failSynchronously = true;
      final rt = _client(t);

      await expectLater(rt.connect(), throwsA(isA<StateError>()));
      await rt.connect().timeout(const Duration(seconds: 1));

      expect(rt.isConnected, isTrue);
      await rt.dispose();
    });

    test('a failed connect schedules a reconnect', () async {
      final t = ScriptedTransport()..failConnects = 1;
      final rt = _client(t, reconnectDelay: const Duration(milliseconds: 5));

      await expectLater(rt.connect(), throwsA(isA<StateError>()));
      await _tick(100);

      expect(t.connectCount, 2);
      expect(rt.isConnected, isTrue);
      await rt.dispose();
    });

    test(
      'online and resume events retry a failed connect without uncaught errors',
      () async {
        final t = ScriptedTransport();
        final rt = _client(t);
        await rt.connect();

        final errors = await _uncaughtErrors(() async {
          // Offline drop: no reconnect is scheduled.
          rt.onNetworkChanged(false);
          t.drop();
          await _tick();
          t.failConnects = 1;
          rt.onNetworkChanged(true); // fails
          await _tick();
          rt.onNetworkChanged(true); // retries and connects
          await _tick();
        });
        expect(errors, isEmpty);
        expect(t.connectCount, 3);
        expect(rt.isConnected, isTrue);

        final resumeErrors = await _uncaughtErrors(() async {
          t.failConnects = 1;
          t.drop();
          await _tick();
          rt.onAppResumed(); // fails
          await _tick();
          rt.onAppResumed(); // retries and connects
          await _tick();
        });
        expect(resumeErrors, isEmpty);
        expect(t.connectCount, 5);
        expect(rt.isConnected, isTrue);
        await rt.dispose();
      },
    );

    test('repeated connect failures back off instead of spinning', () async {
      final t = ScriptedTransport()..failConnects = 1000;
      final rt = _client(t, reconnectDelay: const Duration(milliseconds: 10));

      await expectLater(rt.connect(), throwsA(isA<StateError>()));
      await _tick(400);

      // Without backoff this would be about 40 attempts.
      expect(t.connectCount, inInclusiveRange(3, 8));
      await rt.dispose();
      final after = t.connectCount;
      await _tick(200);
      expect(t.connectCount, after);
    });

    test(
      'a socket closed before connection_established fails connect and retries',
      () async {
        final t = ScriptedTransport()..autoEstablish = false;
        final rt = _client(t, reconnectDelay: const Duration(milliseconds: 5));
        var disconnects = 0;
        rt.onDisconnected(() => disconnects++);

        final first = rt.connect();
        await _tick();
        t.autoEstablish = true;
        t.drop();

        await expectLater(
          first.timeout(const Duration(seconds: 1)),
          throwsA(
            isA<SpApiError>().having(
              (e) => e.code,
              'code',
              SpApiErrorCode.network,
            ),
          ),
        );
        await _tick(100);
        expect(rt.isConnected, isTrue);
        expect(t.connectCount, 2);
        // Never connected, so nothing was lost.
        expect(disconnects, 0);
        await rt.dispose();
      },
    );

    test(
      'disconnect() while connecting fails the pending connect and stays down',
      () async {
        final t = ScriptedTransport()..autoEstablish = false;
        final rt = _client(t, reconnectDelay: const Duration(milliseconds: 5));

        final pending = rt.connect();
        await _tick();
        final failed = expectLater(
          pending.timeout(const Duration(seconds: 1)),
          throwsA(isA<SpApiError>()),
        );
        await rt.disconnect();
        await failed;

        t.establish(); // late handshake of the abandoned attempt
        await _tick(100);
        expect(rt.isConnected, isFalse);
        expect(t.connectCount, 1);
        await rt.dispose();
      },
    );

    test('dispose() while connecting fails the pending connect', () async {
      final t = ScriptedTransport()..autoEstablish = false;
      final rt = _client(t);

      final pending = rt.connect();
      await _tick();
      final failed = expectLater(
        pending.timeout(const Duration(seconds: 1)),
        throwsA(isA<SpApiError>()),
      );
      await rt.dispose();
      await failed;
    });
  });
}

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/scripted_transport.dart';
import '../support/until.dart';

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

// `_tick` is for yielding to already-scheduled microtasks and for deliberate
// negative windows (asserting something does NOT happen). Anything that waits
// for a timer (reconnect delay, activity or pong timeout) uses `until`.

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
    test(
      'a later connect() tries again instead of returning the failure',
      () async {
        final t = ScriptedTransport()..failConnects = 1;
        final rt = _client(t);

        await expectLater(rt.connect(), throwsA(isA<StateError>()));
        await rt.connect().timeout(const Duration(seconds: 1));

        expect(t.connectCount, 2);
        expect(rt.isConnected, isTrue);
        await rt.dispose();
      },
    );

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
      await until(() => t.connectCount == 2 && rt.isConnected);

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
      // Rate window (deliberate): backoff must keep the count far below the
      // ~40 attempts a spin loop would make in 400 ms. Wait for the lower
      // bound first so a loaded machine delays the test instead of failing it.
      await until(() => t.connectCount >= 3);
      await _tick(400);

      // Without backoff this would be about 40 attempts.
      expect(t.connectCount, inInclusiveRange(3, 8));
      await rt.dispose();
      final after = t.connectCount;
      await _tick(200); // negative window: nothing connects after dispose
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
        await until(() => rt.isConnected && t.connectCount == 2);
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
        await _tick(100); // negative window: it must not revive the client
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

  group('lifecycle and network events', () {
    test(
      'a fresh client is not connected by an online or resume event',
      () async {
        final t = ScriptedTransport();
        final rt = _client(t, reconnectDelay: const Duration(milliseconds: 5));

        rt.onNetworkChanged(true);
        rt.onAppResumed(forceStale: true);
        await _tick(50); // negative window: neither event may connect

        expect(t.connectCount, 0);
        expect(rt.isConnected, isFalse);
        await rt.dispose();
      },
    );

    test(
      'after disconnect() resume and online events do not reconnect',
      () async {
        final t = ScriptedTransport();
        final rt = _client(t, reconnectDelay: const Duration(milliseconds: 5));
        await rt.subscribe('public-orders', onEvent: (_) {});
        await rt.disconnect();

        rt.onAppPaused();
        rt.onAppResumed();
        rt.onAppResumed(forceStale: true);
        rt.onNetworkChanged(false);
        rt.onNetworkChanged(true);
        await _tick(50); // negative window: none of these may reconnect

        expect(t.connectCount, 1);
        expect(rt.isConnected, isFalse);
        expect(t.framesSent('pusher:subscribe'), 1);

        // An explicit connect() still works and rejoins.
        await rt.connect();
        await until(() => t.framesSent('pusher:subscribe') == 2);
        expect(t.framesSent('pusher:subscribe'), 2);
        await rt.dispose();
      },
    );

    test(
      'after dispose() resume and online events neither throw nor connect',
      () async {
        final t = ScriptedTransport();
        final rt = _client(t, reconnectDelay: const Duration(milliseconds: 5));
        await rt.connect();
        rt.onNetworkChanged(false);
        t.drop();
        await _tick();
        await rt.dispose();

        expect(() => rt.onNetworkChanged(true), returnsNormally);
        expect(() => rt.onAppResumed(forceStale: true), returnsNormally);
        await _tick(50); // negative window: neither event may connect
        expect(t.connectCount, 1);
      },
    );

    test(
      'a client whose connect failed while offline connects when back online',
      () async {
        final t = ScriptedTransport()..failConnects = 1;
        final rt = _client(t, reconnectDelay: const Duration(milliseconds: 5));
        rt.onNetworkChanged(false);
        await expectLater(rt.connect(), throwsA(isA<StateError>()));
        await _tick(50); // negative window: offline, so no retry may happen
        expect(t.connectCount, 1); // offline: no retry scheduled

        rt.onNetworkChanged(true);
        await until(() => t.connectCount == 2 && rt.isConnected);
        expect(t.connectCount, 2);
        expect(rt.isConnected, isTrue);
        await rt.dispose();
      },
    );
  });

  group('dead socket', () {
    test('a pong timeout drops the connection once and reconnects', () async {
      // Pins the RealtimeTransport contract: close() emits no onDone.
      final t = ScriptedTransport()..answerPings = false;
      final rt = _client(
        t,
        reconnectDelay: const Duration(milliseconds: 5),
        activityTimeout: const Duration(milliseconds: 20),
        pongTimeout: const Duration(milliseconds: 20),
      );
      var disconnects = 0;
      rt.onDisconnected(() {
        disconnects++;
        t.answerPings = true; // the next socket is alive
      });
      await rt.connect();

      await until(() => disconnects >= 1 && rt.isConnected);
      // negative window: no second drop. 100 ms is longer than the 20 ms
      // activity timeout plus the 20 ms pong timeout, so the new socket is
      // pinged (and answers) at least once inside it.
      await _tick(100);
      expect(disconnects, 1);
      expect(t.closeCount, 1);
      expect(t.connectCount, 2);
      expect(rt.isConnected, isTrue);
      await rt.dispose();
    });

    test('onDisconnected fires once per connection', () async {
      final t = ScriptedTransport();
      final rt = _client(t);
      var disconnects = 0;
      rt.onDisconnected(() => disconnects++);
      await rt.connect();

      t.drop(); // the server closes the socket
      await _tick();
      await rt.disconnect();
      await rt.disconnect();
      expect(disconnects, 1);
      await rt.dispose();
    });

    test('a resume while a ping is unanswered reconnects at once', () async {
      final t = ScriptedTransport()..answerPings = false;
      final rt = _client(
        t,
        activityTimeout: const Duration(milliseconds: 20),
        pongTimeout: const Duration(minutes: 10),
      );
      var disconnects = 0;
      rt.onDisconnected(() => disconnects++);
      await rt.connect();
      await until(() => !rt.isHealthy); // the ping went unanswered
      expect(rt.isHealthy, isFalse);

      t.answerPings = true;
      rt.onAppResumed();
      await until(() => t.connectCount == 2 && rt.isConnected);
      expect(disconnects, 1);
      expect(t.connectCount, 2);
      expect(rt.isConnected, isTrue);
      await rt.dispose();
    });

    test('a stale resume pings at once and replaces a dead socket', () async {
      final t = ScriptedTransport()..answerPings = false;
      final rt = _client(
        t,
        reconnectDelay: const Duration(milliseconds: 5),
        // short, so the negative window below covers a ping on the new socket
        activityTimeout: const Duration(milliseconds: 20),
        pongTimeout: const Duration(milliseconds: 20),
      );
      var disconnects = 0;
      rt.onDisconnected(() {
        disconnects++;
        t.answerPings = true;
      });
      await rt.connect();

      rt.onAppPaused();
      rt.onAppResumed(forceStale: true);
      expect(t.framesSent('pusher:ping'), 1);
      await until(() => disconnects >= 1 && rt.isConnected);
      // negative window: no second drop. 100 ms is longer than the 20 ms
      // activity timeout plus the 20 ms pong timeout.
      await _tick(100);
      expect(disconnects, 1);
      expect(t.connectCount, 2);
      expect(rt.isConnected, isTrue);
      await rt.dispose();
    });

    test('a stale resume keeps a live socket', () async {
      final t = ScriptedTransport();
      final rt = _client(t, pongTimeout: const Duration(milliseconds: 20));
      await rt.connect();

      rt.onAppPaused();
      rt.onAppResumed(forceStale: true);
      expect(t.framesSent('pusher:ping'), 1);
      // Negative window, longer than the 20 ms pong timeout: the answered
      // ping must not drop the socket.
      await _tick(100);
      expect(t.connectCount, 1);
      expect(rt.isHealthy, isTrue);
      await rt.dispose();
    });

    test(
      'a connection made after a drop with a ping in flight is healthy',
      () async {
        final t = ScriptedTransport()..answerPings = false;
        final rt = _client(
          t,
          reconnectDelay: const Duration(milliseconds: 5),
          activityTimeout: const Duration(milliseconds: 200),
          pongTimeout: const Duration(minutes: 10),
        );
        await rt.connect();
        await until(() => !rt.isHealthy); // ping sent, no pong
        expect(rt.isHealthy, isFalse);

        t.answerPings = true;
        t.drop();
        await until(() => t.connectCount == 2 && rt.isHealthy);
        expect(t.connectCount, 2);
        expect(rt.isHealthy, isTrue);
        await rt.dispose();
      },
    );
  });
}

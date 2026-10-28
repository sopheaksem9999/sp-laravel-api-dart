import 'dart:async';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/fake_pusher_server.dart';
import '../support/until.dart';

void main() {
  group('SpRealtime.subscribe confirmation', () {
    late FakePusherServer server;
    late SpRealtime client;
    late List<(String, Object)> failures;

    /// A real elapsed wait, only for asserting that something does NOT happen
    /// within a short window after its precondition was awaited with `until`.
    Future<void> window([int ms = 50]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    /// Kills the current socket and waits for the client to be connected on a
    /// new one.
    Future<void> killAndReconnect() async {
      final old = client.socketId!;
      server.simulateSocketDeath(old);
      await until(() => client.isConnected && client.socketId != old);
    }

    SpRealtime build({
      Duration subscribeTimeout = const Duration(seconds: 10),
      int subscribeAttempts = 3,
    }) {
      return SpRealtime(
        apiBaseUrl: server.httpUri,
        driver: Driver.custom(
          host: '127.0.0.1',
          port: server.port,
          appKey: 'testappkey',
          useTls: false,
        ),
        tokenProvider: () async => 'mock-jwt-token',
        dio: Dio(),
        subscribeTimeout: subscribeTimeout,
        subscribeAttempts: subscribeAttempts,
        subscribeBackoff: const Duration(milliseconds: 10),
        onSubscribeFailed: (channel, error) => failures.add((channel, error)),
      );
    }

    setUp(() async {
      server = FakePusherServer();
      await server.start();
      failures = [];
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test('subscribe completes only after subscription_succeeded', () async {
      client = build();
      server.withholdConfirmations = true;
      await client.connect();

      var done = false;
      final future = client.subscribe('private-orders.1', onEvent: (_) {}).then(
        (u) {
          done = true;
          return u;
        },
      );
      await until(() => server.subscribeRequests.isNotEmpty);
      expect(server.subscribeRequests, ['private-orders.1']);
      await window(); // frame received, confirmation withheld: still pending
      expect(done, isFalse);

      server.releaseWithheld();
      await future;
      expect(done, isTrue);
    });

    test('timeout throws SpApiError(timeout) and leaves no intent', () async {
      client = build(subscribeTimeout: const Duration(milliseconds: 150));
      server.withholdConfirmations = true;
      await client.connect();

      await expectLater(
        client.subscribe('private-orders.1', onEvent: (_) {}),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.timeout,
          ),
        ),
      );

      // Reconnect: no subscribe frame may be sent for the abandoned channel.
      server.withholdConfirmations = false;
      server.subscribeRequests.clear();
      await killAndReconnect();
      await until(() => server.unsubscribeRequests.isNotEmpty);
      await window(100); // no subscribe frame may follow the reconnect
      expect(client.isConnected, isTrue);
      expect(server.subscribeRequests, isEmpty);
      expect(server.unsubscribeRequests, ['private-orders.1']);
    });

    test('auth failure leaves no registered intent', () async {
      client = build();
      server.authFailureStatus = 500;
      await client.connect();

      await expectLater(
        client.subscribe('private-orders.1', onEvent: (_) {}),
        throwsA(isA<SpApiError>()),
      );

      server.authFailureStatus = null;
      await killAndReconnect();
      await window(100); // no rejoin (auth or frame) may follow the reconnect
      expect(client.isConnected, isTrue);
      expect(server.subscribeRequests, isEmpty);
      expect(server.authRequests, 1);
    });

    test(
      'two concurrent subscribers on a pending channel both complete',
      () async {
        client = build();
        server.withholdConfirmations = true;
        await client.connect();

        final a = client.subscribe('private-orders.1', onEvent: (_) {});
        final b = client.subscribe('private-orders.1', onEvent: (_) {});
        await until(() => server.subscribeRequests.isNotEmpty);
        await window(); // a second subscriber must not send a second frame
        expect(server.subscribeRequests, ['private-orders.1']);

        server.releaseWithheld();
        await Future.wait([a, b]);
        expect(server.subscribeRequests, ['private-orders.1']);
      },
    );

    test(
      'a second subscribe to a confirmed channel sends no new frame',
      () async {
        client = build();
        await client.connect();
        await client.subscribe('private-orders.1', onEvent: (_) {});
        final authBefore = server.authRequests;

        await client.subscribe('private-orders.1', onEvent: (_) {});
        await window(); // no frame or auth request may follow
        expect(server.subscribeRequests, ['private-orders.1']);
        expect(server.authRequests, authBefore);
      },
    );

    test(
      'an event broadcast right after subscribe returns reaches the handler',
      () async {
        client = build();
        await client.connect();
        final events = <RecordEvent>[];
        await client.subscribe('private-orders.1', onEvent: events.add);

        server.broadcast('private-orders.1', 'orders.created', {
          'action': 'created',
          'table': 'orders',
          'record': {'id': '7'},
        });
        await until(() => events.isNotEmpty);
        expect(events, hasLength(1));
        expect(events.single.record['id'], '7');
      },
    );

    test(
      'a failed rejoin is retried up to subscribeAttempts and onSubscribeFailed fires once',
      () async {
        client = build();
        var recovered = 0;
        client.onRecovered(() async => recovered++);
        await client.connect();
        await client.subscribe('private-orders.1', onEvent: (_) {});
        expect(server.authRequests, 1);

        server.authFailureStatus = 500;
        server.simulateSocketDeath(client.socketId!);
        await until(() => failures.isNotEmpty && recovered == 1);

        expect(client.isConnected, isTrue);
        expect(server.authRequests, 1 + 3);
        expect(failures, hasLength(1));
        expect(failures.single.$1, 'private-orders.1');
        expect(failures.single.$2, isA<SpApiError>());

        // No further retries after giving up.
        await window(150); // backoff is 10 ms: a further retry would show here
        expect(server.authRequests, 1 + 3);
        expect(failures, hasLength(1));
        // A given-up channel does not block recovery forever.
        expect(recovered, 1);
      },
    );

    test('unsubscribe while a rejoin is pending does not hang', () async {
      client = build();
      await client.connect();
      final unsubA = await client.subscribe(
        'private-orders.1',
        onEvent: (_) {},
      );

      server.withholdConfirmations = true;
      await killAndReconnect();
      await until(() => server.subscribeRequests.length == 2); // rejoin frame

      // Connected, so subscribe registers its intent synchronously.
      final b = client.subscribe('private-orders.1', onEvent: (_) {});
      unsubA();
      server.releaseWithheld();
      await b.timeout(const Duration(seconds: 2));
      expect(server.unsubscribeRequests, isEmpty);
    });

    test(
      'a reconnect while subscribe is pending resolves it via rejoin',
      () async {
        client = build();
        server.withholdConfirmations = true;
        await client.connect();

        final future = client.subscribe('private-orders.1', onEvent: (_) {});
        await until(() => server.subscribeRequests.isNotEmpty);
        await killAndReconnect();
        // The rejoin frame on the new socket is withheld too.
        await until(() => server.subscribeRequests.length == 2);
        server.withholdConfirmations = false;
        server.releaseWithheld();
        await future.timeout(const Duration(seconds: 2));
        expect(client.isConnected, isTrue);
      },
    );

    test(
      'a late confirmation after a timeout does not mark the channel confirmed',
      () async {
        client = build(subscribeTimeout: const Duration(milliseconds: 100));
        server.withholdConfirmations = true;
        await client.connect();

        await expectLater(
          client.subscribe('private-orders.1', onEvent: (_) {}),
          throwsA(isA<SpApiError>()),
        );
        await until(() => server.subscribeRequests.isNotEmpty);
        server.releaseWithheld(); // late confirmation of the abandoned frame
        await window(); // let the late confirmation reach the client

        var done = false;
        final again = client
            .subscribe('private-orders.1', onEvent: (_) {})
            .then((u) {
              done = true;
              return u;
            });
        await until(() => server.subscribeRequests.length == 2);
        expect(server.subscribeRequests, [
          'private-orders.1',
          'private-orders.1',
        ]);
        await window(); // frame received, confirmation withheld: still pending
        expect(done, isFalse);

        server.releaseWithheld();
        await again;
        expect(done, isTrue);
      },
    );

    test(
      'a rejoin whose confirmation is withheld is retried, reported once and does not block recovery',
      () async {
        client = build(subscribeTimeout: const Duration(milliseconds: 100));
        var recovered = 0;
        client.onRecovered(() async => recovered++);
        await client.connect();
        await client.subscribe('private-orders.1', onEvent: (_) {});
        expect(server.subscribeRequests, hasLength(1));

        server.withholdConfirmations = true;
        server.simulateSocketDeath(client.socketId!);
        await until(() => failures.isNotEmpty && recovered == 1);

        expect(server.subscribeRequests, hasLength(1 + 3));
        expect(failures, hasLength(1));
        expect(failures.single.$1, 'private-orders.1');
        expect(failures.single.$2, isA<SpApiError>());
        expect(recovered, 1);

        await window(150); // timeout 100 ms: a further retry would show here
        expect(server.subscribeRequests, hasLength(1 + 3));
        expect(failures, hasLength(1));

        // No stale pending: a later subscribe sends a real frame and works.
        server.withholdConfirmations = false;
        await client
            .subscribe('private-orders.1', onEvent: (_) {})
            .timeout(const Duration(seconds: 2));
        expect(server.subscribeRequests, hasLength(1 + 3 + 1));
      },
    );
  });
}

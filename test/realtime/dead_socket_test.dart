import 'dart:async';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/fake_pusher_server.dart';

/// Dead-socket detection with the production [WebSocketTransport], whose
/// close() does not emit onDone.
void main() {
  group('dead socket with WebSocketTransport', () {
    late FakePusherServer server;
    late SpRealtime client;
    late int disconnects;

    SpRealtime build({required Duration activityTimeout}) {
      final rt = SpRealtime(
        apiBaseUrl: server.httpUri,
        driver: Driver.custom(
          host: '127.0.0.1',
          port: server.port,
          appKey: 'testappkey',
          useTls: false,
        ),
        tokenProvider: () async => 'mock-jwt-token',
        dio: Dio(),
        activityTimeout: activityTimeout,
        pongTimeout: const Duration(milliseconds: 50),
        reconnectDelay: const Duration(milliseconds: 10),
      );
      rt.onDisconnected(() {
        disconnects++;
        server.answerPings = true; // the next socket is alive
      });
      return rt;
    }

    Future<void> waitFor(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    setUp(() async {
      server = FakePusherServer();
      await server.start();
      server.answerPings = false;
      disconnects = 0;
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test('a pong timeout fires onDisconnected once and reconnects', () async {
      client = build(activityTimeout: const Duration(milliseconds: 50));
      await client.connect();
      final first = client.socketId;

      await waitFor(() => client.isConnected && client.socketId != first);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(disconnects, 1);
      expect(server.connectionCount, 2);
      expect(client.isConnected, isTrue);
      expect(client.socketId, isNot(first));
      expect(client.isHealthy, isTrue);
    });

    test('a stale resume on a dead socket reconnects', () async {
      client = build(activityTimeout: const Duration(minutes: 10));
      await client.connect();
      final first = client.socketId;

      client.onAppPaused();
      client.onAppResumed(forceStale: true);
      await waitFor(() => client.isConnected && client.socketId != first);

      expect(disconnects, 1);
      expect(server.connectionCount, 2);
      expect(client.socketId, isNot(first));
    });
  });
}

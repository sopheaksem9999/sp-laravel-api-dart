import 'dart:async';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/fake_pusher_server.dart';

void main() {
  group('FakePusherServer Integration', () {
    late FakePusherServer server;
    late SpRealtime client;

    setUp(() async {
      server = FakePusherServer();
      await server.start();
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test(
      'full lifecycle: connect, auth subscribe, broadcast event, and auto-reconnect on socket drop',
      () async {
        final driver = Driver.custom(
          host: '127.0.0.1',
          port: server.port,
          appKey: 'testappkey',
          useTls: false,
        );

        final eventsReceived = <RecordEvent>[];
        final recoveredCompleter = Completer<void>();

        client = SpRealtime(
          apiBaseUrl: server.httpUri,
          driver: driver,
          tokenProvider: () async => 'mock-jwt-token',
          dio: Dio(),
        );

        client.onRecovered(() async {
          if (!recoveredCompleter.isCompleted) {
            recoveredCompleter.complete();
          }
        });

        // 1. Connect
        await client.connect();
        expect(client.isConnected, isTrue);
        expect(client.socketId, isNotNull);
        final initialSocketId = client.socketId!;

        // 2. Subscribe to private tenant channel
        final unsubscribe = await client.subscribe(
          'private-tenant.10',
          onEvent: (event) {
            eventsReceived.add(event);
          },
        );

        // Give server time to process subscription frame
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 3. Server broadcasts an event
        server.broadcast('private-tenant.10', 'invoices.created', {
          'action': 'created',
          'table': 'invoices',
          'record': {'id': '101', 'amount': 250},
        });

        // Wait for client to receive event
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(eventsReceived.length, equals(1));
        expect(eventsReceived.first.table, equals('invoices'));
        expect(eventsReceived.first.action, equals(RecordAction.created));
        expect(eventsReceived.first.record['id'], equals('101'));
        expect(eventsReceived.first.record['amount'], equals(250));

        // 4. Simulate socket death (server abruptly drops socket)
        server.simulateSocketDeath(initialSocketId);

        // Wait for client to auto-reconnect, re-establish, and fire onRecovered
        await recoveredCompleter.future.timeout(const Duration(seconds: 5));
        expect(client.isConnected, isTrue);
        expect(client.socketId, isNot(equals(initialSocketId)));

        // 5. Broadcast second event on reconnected socket
        server.broadcast('private-tenant.10', 'invoices.updated', {
          'action': 'updated',
          'table': 'invoices',
          'id': '101',
          'record': {'id': '101', 'amount': 300},
        });

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(eventsReceived.length, equals(2));
        expect(eventsReceived.last.action, equals(RecordAction.updated));
        expect(eventsReceived.last.record['amount'], equals(300));

        unsubscribe();
      },
    );

    test(
      'multi-subscriber isolation and unsubscription over real socket',
      () async {
        final driver = Driver.custom(
          host: '127.0.0.1',
          port: server.port,
          appKey: 'testappkey',
          useTls: false,
        );

        final listA = <RecordEvent>[];
        final listB = <RecordEvent>[];

        client = SpRealtime(
          apiBaseUrl: server.httpUri,
          driver: driver,
          tokenProvider: () async => 'mock-jwt-token',
        );

        await client.connect();

        final unsubA = await client.subscribe(
          'private-tenant.20',
          onEvent: (e) => listA.add(e),
        );

        final unsubB = await client.subscribe(
          'private-tenant.20',
          onEvent: (e) => listB.add(e),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));

        server.broadcast('private-tenant.20', 'users.created', {
          'action': 'created',
          'table': 'users',
          'record': {'id': '1', 'name': 'Alice'},
        });

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(listA.length, equals(1));
        expect(listB.length, equals(1));

        // Unsubscribe A
        unsubA();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        server.broadcast('private-tenant.20', 'users.updated', {
          'action': 'updated',
          'table': 'users',
          'record': {'id': '1', 'name': 'Alice Updated'},
        });

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(listA.length, equals(1)); // Did not receive second event
        expect(listB.length, equals(2)); // Still receives events

        unsubB();
      },
    );

    test('manual disconnect stops auto-reconnect', () async {
      final driver = Driver.custom(
        host: '127.0.0.1',
        port: server.port,
        appKey: 'testappkey',
        useTls: false,
      );

      client = SpRealtime(
        apiBaseUrl: server.httpUri,
        driver: driver,
        tokenProvider: () async => 'mock-jwt-token',
      );

      await client.connect();
      expect(client.isConnected, isTrue);

      await client.disconnect();
      expect(client.isConnected, isFalse);

      // Wait past reconnect delay
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(client.isConnected, isFalse);
    });
  });
}

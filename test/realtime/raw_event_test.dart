import 'dart:async';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/fake_pusher_server.dart';
import '../support/until.dart';

void main() {
  group('RecordEvent.fromJson', () {
    test('missing action maps to unknown', () {
      final e = RecordEvent.fromJson({
        'table': 'orders',
        'record': {'id': 1},
      });
      expect(e.action, equals(RecordAction.unknown));
      expect(e.isRecord, isTrue);
    });

    test('existing five actions map as before', () {
      const expected = {
        'created': RecordAction.created,
        'updated': RecordAction.updated,
        'deleted': RecordAction.deleted,
        'restored': RecordAction.restored,
        'upserted': RecordAction.upserted,
      };
      expected.forEach((name, action) {
        final e = RecordEvent.fromJson({
          'table': 'orders',
          'action': name,
          'record': {'id': 1},
        });
        expect(e.action, equals(action), reason: name);
      });
    });

    test('record as a list does not throw and isRecord is false', () {
      final e = RecordEvent.fromJson({
        'table': 'orders',
        'action': 'updated',
        'record': [1, 2],
      });
      expect(e.isRecord, isFalse);
      expect(e.record, isEmpty);
    });

    test('non-string table gives isRecord false and does not throw', () {
      final e = RecordEvent.fromJson({
        'table': 42,
        'record': {'id': 1},
      });
      expect(e.isRecord, isFalse);
    });

    test('eventName defaults to empty and is settable', () {
      expect(RecordEvent.fromJson({}).eventName, equals(''));
      expect(
        RecordEvent.fromJson({}, eventName: 'x.y').eventName,
        equals('x.y'),
      );
    });
  });

  group('SpRealtime raw events', () {
    late FakePusherServer server;
    late SpRealtime client;
    late List<RecordEvent> events;

    setUp(() async {
      server = FakePusherServer();
      await server.start();
      client = SpRealtime(
        apiBaseUrl: server.httpUri,
        driver: Driver.custom(
          host: '127.0.0.1',
          port: server.port,
          appKey: 'testappkey',
          useTls: false,
        ),
        tokenProvider: () async => 'mock-jwt-token',
        dio: Dio(),
      );
      events = [];
      await client.connect();
      // subscribe returns only after the server confirmed the subscription.
      await client.subscribe('private-tenant.10', onEvent: events.add);
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    Future<void> eventsReceived(int count) =>
        until(() => events.length >= count);

    test(
      'order.updated exposes eventName and raw exactly as broadcast',
      () async {
        final payload = {
          'table': 'orders',
          'action': 'updated',
          'record': {'id': '5'},
          'extra': 'kept',
        };
        server.broadcast('private-tenant.10', 'order.updated', payload);
        await eventsReceived(1);
        expect(events, hasLength(1));
        expect(events.single.eventName, equals('order.updated'));
        expect(events.single.raw, equals(payload));
      },
    );

    test('courier_location.updated reaches handler as non-record', () async {
      server.broadcast('private-tenant.10', 'courier_location.updated', {
        'courier_id': 7,
        'lat': 11.5,
        'lng': 104.9,
      });
      await eventsReceived(1);
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.isRecord, isFalse);
      expect(e.action, equals(RecordAction.unknown));
      expect(e.eventName, equals('courier_location.updated'));
      expect(e.raw, equals({'courier_id': 7, 'lat': 11.5, 'lng': 104.9}));
    });

    test('record event on the same channel is still populated', () async {
      server.broadcast('private-tenant.10', 'courier_location.updated', {
        'courier_id': 7,
      });
      server.broadcast('private-tenant.10', 'orders.created', {
        'table': 'orders',
        'action': 'created',
        'record': {'id': '9'},
      });
      await eventsReceived(2);
      expect(events, hasLength(2));
      final e = events.last;
      expect(e.isRecord, isTrue);
      expect(e.table, equals('orders'));
      expect(e.action, equals(RecordAction.created));
      expect(e.record['id'], equals('9'));
    });
  });
}

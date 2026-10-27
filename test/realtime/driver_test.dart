import 'package:sp_laravel_api/realtime.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  group('Driver Presets & URI Generation', () {
    test('reverb preset builds wss URI with port and appKey', () {
      final driver = Driver.reverb(
        host: 'ws.example.com',
        port: 8080,
        appKey: 'reverb_key_123',
        useTls: true,
      );

      final uri = driver.toUri();
      expect(uri.scheme, equals('wss'));
      expect(uri.host, equals('ws.example.com'));
      expect(uri.port, equals(8080));
      expect(uri.path, equals('/app/reverb_key_123'));
      expect(uri.queryParameters['protocol'], equals('7'));
      expect(uri.queryParameters['client'], equals('sp_laravel_api'));
      expect(uri.queryParameters['version'], equals(packageVersion));
      expect(uri.queryParameters['flash'], equals('false'));
    });

    test('pusher preset resolves cluster host ws-<cluster>.pusher.com', () {
      final driver = Driver.pusher(
        appKey: 'pusher_app_key',
        cluster: 'ap1',
        useTls: true,
      );

      final uri = driver.toUri();
      expect(uri.scheme, equals('wss'));
      expect(uri.host, equals('ws-ap1.pusher.com'));
      expect(uri.port, equals(443));
      expect(uri.path, equals('/app/pusher_app_key'));
    });

    test('soketi preset allows unencrypted ws protocol', () {
      final driver = Driver.soketi(
        host: '127.0.0.1',
        port: 6001,
        appKey: 'soketi_key',
        useTls: false,
      );

      final uri = driver.toUri();
      expect(uri.scheme, equals('ws'));
      expect(uri.host, equals('127.0.0.1'));
      expect(uri.port, equals(6001));
      expect(uri.path, equals('/app/soketi_key'));
    });

    test('ably preset connects to realtime-pusher.ably.io', () {
      final driver = Driver.ably(appKey: 'ably_app_key', useTls: true);

      final uri = driver.toUri();
      expect(uri.scheme, equals('wss'));
      expect(uri.host, equals('realtime-pusher.ably.io'));
      expect(uri.port, equals(443));
      expect(uri.path, equals('/app/ably_app_key'));
    });

    test('custom preset allows arbitrary host, port, path, and TLS', () {
      final driver = Driver.custom(
        host: 'my-custom-broadcaster.net',
        port: 9000,
        appKey: 'custom_key',
        path: '/websocket',
        useTls: false,
      );

      final uri = driver.toUri();
      expect(uri.scheme, equals('ws'));
      expect(uri.host, equals('my-custom-broadcaster.net'));
      expect(uri.port, equals(9000));
      expect(uri.path, equals('/websocket/custom_key'));
    });
  });

  group('RecordEvent', () {
    test('parses RecordMutated payload with actions', () {
      final json = {
        'table': 'videos',
        'action': 'created',
        'record': {'id': 1, 'title': 'Test Video'},
        'tenant_id': 'tenant_99',
        'timestamp': '2026-10-27T12:00:00.000Z',
      };

      final event = RecordEvent.fromJson(json);
      expect(event.table, equals('videos'));
      expect(event.action, equals(RecordAction.created));
      expect(event.record['title'], equals('Test Video'));
      expect(event.tenantId, equals('tenant_99'));
      expect(event.timestamp, equals(DateTime.utc(2026, 10, 27, 12)));
    });

    test('parses batched upserted action', () {
      final json = {
        'table': 'invoices',
        'action': 'upserted',
        'record': {
          'count': 5,
          'match_on': ['id'],
          'keys': [1, 2, 3, 4, 5],
        },
        'tenant_id': null,
        'timestamp': '2026-10-27T12:00:00.000Z',
      };

      final event = RecordEvent.fromJson(json);
      expect(event.action, equals(RecordAction.upserted));
      expect(event.record['count'], equals(5));
      expect(event.tenantId, isNull);
    });
  });
}

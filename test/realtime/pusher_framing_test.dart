import 'dart:convert';
import 'package:sp_laravel_api/src/realtime/pusher_framing.dart';
import 'package:test/test.dart';

void main() {
  group('PusherFrame Parsing and Serialization', () {
    test('parses double-encoded JSON string data', () {
      final raw = jsonEncode({
        'event': 'pusher:connection_established',
        'data': jsonEncode({
          'socket_id': '12345.67890',
          'activity_timeout': 120,
        }),
      });

      final frame = PusherFrame.parse(raw);
      expect(frame.event, equals('pusher:connection_established'));
      expect(frame.channel, isNull);
      expect(frame.data, isA<Map<String, dynamic>>());
      expect(frame.data['socket_id'], equals('12345.67890'));
      expect(frame.data['activity_timeout'], equals(120));
    });

    test('parses pre-decoded map data', () {
      final raw = jsonEncode({
        'event': 'videos.created',
        'channel': 'private-tenant.42',
        'data': {'id': 100, 'title': 'New Video'},
      });

      final frame = PusherFrame.parse(raw);
      expect(frame.event, equals('videos.created'));
      expect(frame.channel, equals('private-tenant.42'));
      expect(frame.data['id'], equals(100));
      expect(frame.data['title'], equals('New Video'));
    });

    test('serializes pusher:subscribe frame with auth', () {
      final frame = PusherFrame.subscribe(
        channel: 'private-tenant.42',
        auth: 'key123:sig456',
      );

      final jsonString = frame.toJsonString();
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      expect(decoded['event'], equals('pusher:subscribe'));
      final data = decoded['data'] as Map<String, dynamic>;
      expect(data['channel'], equals('private-tenant.42'));
      expect(data['auth'], equals('key123:sig456'));
    });

    test('serializes pusher:ping and pusher:pong', () {
      final ping = PusherFrame.ping();
      expect(ping.event, equals('pusher:ping'));
      final pingJson = jsonDecode(ping.toJsonString()) as Map<String, dynamic>;
      expect(pingJson['event'], equals('pusher:ping'));

      final pong = PusherFrame.pong();
      expect(pong.event, equals('pusher:pong'));
      final pongJson = jsonDecode(pong.toJsonString()) as Map<String, dynamic>;
      expect(pongJson['event'], equals('pusher:pong'));
    });
  });

  group('Pusher Close Code Classification', () {
    test('4000-4099 are fatal and do not reconnect', () {
      expect(classifyPusherCloseCode(4000), equals(PusherCloseAction.fatal));
      expect(classifyPusherCloseCode(4004), equals(PusherCloseAction.fatal));
      expect(classifyPusherCloseCode(4099), equals(PusherCloseAction.fatal));
    });

    test('4100-4199 reconnect after backoff delay', () {
      expect(
        classifyPusherCloseCode(4100),
        equals(PusherCloseAction.reconnectDelayed),
      );
      expect(
        classifyPusherCloseCode(4199),
        equals(PusherCloseAction.reconnectDelayed),
      );
    });

    test('4200-4299 reconnect immediately', () {
      expect(
        classifyPusherCloseCode(4200),
        equals(PusherCloseAction.reconnectImmediate),
      );
      expect(
        classifyPusherCloseCode(4299),
        equals(PusherCloseAction.reconnectImmediate),
      );
    });

    test('standard and unknown close codes reconnect after delay', () {
      expect(
        classifyPusherCloseCode(1006),
        equals(PusherCloseAction.reconnectDelayed),
      );
      expect(
        classifyPusherCloseCode(null),
        equals(PusherCloseAction.reconnectDelayed),
      );
      expect(
        classifyPusherCloseCode(1000),
        equals(PusherCloseAction.closedNormally),
      );
    });
  });
}

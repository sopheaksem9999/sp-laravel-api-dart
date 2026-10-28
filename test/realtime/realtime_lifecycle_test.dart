import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/realtime.dart';
import 'package:test/test.dart';

import '../support/until.dart';

class MockTransport implements RealtimeTransport {
  final _incomingController = StreamController<String>.broadcast();
  final _doneController = StreamController<void>.broadcast();
  int connectCount = 0;
  bool isConnected = false;

  @override
  Stream<String> get incoming => _incomingController.stream;

  @override
  Stream<void> get onDone => _doneController.stream;

  @override
  Future<void> connect(Uri uri) async {
    connectCount++;
    isConnected = true;
    Future.microtask(() {
      _incomingController.add(
        jsonEncode({
          'event': 'pusher:connection_established',
          'data': {
            'socket_id': 'socket_test_lifecycle',
            'activity_timeout': 120,
          },
        }),
      );
    });
  }

  @override
  void send(String data) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    // Like WebSocketTransport: an app-initiated close emits no onDone.
    isConnected = false;
  }

  void simulateDisconnect() {
    isConnected = false;
    _doneController.add(null);
  }
}

void main() {
  group('Realtime Lifecycle & Network', () {
    test(
      'onNetworkChanged(false) pauses reconnect; onNetworkChanged(true) reconnects',
      () async {
        final transport = MockTransport();
        final dio = Dio();

        final rt = SpRealtime(
          apiBaseUrl: Uri.parse('https://example.com/api/v1'),
          driver: Driver.reverb(
            host: 'ws.example.com',
            port: 8080,
            appKey: 'k1',
          ),
          tokenProvider: () async => 'token',
          transport: transport,
          dio: dio,
        );

        await rt.connect();
        expect(rt.isConnected, isTrue);

        // Go offline
        rt.onNetworkChanged(false);
        transport.simulateDisconnect();
        await Future<void>.delayed(Duration.zero);
        expect(rt.isConnected, isFalse);

        // Reconnect should NOT happen while offline
        expect(transport.connectCount, equals(1));

        // Go back online -> triggers reconnect
        rt.onNetworkChanged(true);
        await until(() => transport.connectCount == 2 && rt.isConnected);

        expect(transport.connectCount, equals(2));
        expect(rt.isConnected, isTrue);
      },
    );

    test(
      'onAppResumed after long pause runs health check and repairs socket',
      () async {
        final transport = MockTransport();
        final dio = Dio();

        final rt = SpRealtime(
          apiBaseUrl: Uri.parse('https://example.com/api/v1'),
          driver: Driver.reverb(
            host: 'ws.example.com',
            port: 8080,
            appKey: 'k1',
          ),
          tokenProvider: () async => 'token',
          transport: transport,
          dio: dio,
        );

        await rt.connect();
        expect(transport.connectCount, equals(1));

        // Simulate app paused for 40 seconds (exceeding 30s stale threshold)
        rt.onAppPaused();
        // Drop connection while suspended
        transport.simulateDisconnect();
        await Future<void>.delayed(Duration.zero);

        // App resumed
        rt.onAppResumed(forceStale: true);
        await until(() => transport.connectCount == 2 && rt.isConnected);

        expect(transport.connectCount, equals(2));
        expect(rt.isConnected, isTrue);
      },
    );

    test('short pause with healthy socket does not reconnect', () async {
      final transport = MockTransport();
      final dio = Dio();

      final rt = SpRealtime(
        apiBaseUrl: Uri.parse('https://example.com/api/v1'),
        driver: Driver.reverb(host: 'ws.example.com', port: 8080, appKey: 'k1'),
        tokenProvider: () async => 'token',
        transport: transport,
        dio: dio,
      );

      await rt.connect();
      expect(transport.connectCount, equals(1));

      // Short pause
      rt.onAppPaused();
      rt.onAppResumed(forceStale: false);
      // Negative window: a healthy socket must not be replaced.
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // Socket remained intact, no new connect call
      expect(transport.connectCount, equals(1));
    });
  });
}

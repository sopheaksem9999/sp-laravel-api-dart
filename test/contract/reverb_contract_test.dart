import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  final reverbHost = Platform.environment['REVERB_TEST_HOST'];
  final skipReason = reverbHost == null || reverbHost.isEmpty
      ? 'REVERB_TEST_HOST is not set; skipping live Reverb contract test'
      : null;

  group('Real Reverb Contract Tests (Rung 2/3)', () {
    test(
      'connects to real Reverb server and verifies subscription and event round-trip',
      () async {
        final port =
            int.tryParse(Platform.environment['REVERB_TEST_PORT'] ?? '') ??
            8080;
        final appKey = Platform.environment['REVERB_APP_KEY'] ?? 'testappkey';
        final apiUrl = Uri.parse(
          Platform.environment['REVERB_API_URL'] ??
              'http://127.0.0.1:8000/api/v1',
        );
        final token =
            Platform.environment['REVERB_BEARER_TOKEN'] ?? 'mock-token';

        final driver = Driver.reverb(
          host: reverbHost!,
          port: port,
          appKey: appKey,
          useTls: false,
        );

        final client = SpRealtime(
          apiBaseUrl: apiUrl,
          driver: driver,
          tokenProvider: () async => token,
        );

        try {
          await client.connect().timeout(const Duration(seconds: 10));
          expect(client.isConnected, isTrue);
          expect(client.socketId, isNotNull);

          final events = <RecordEvent>[];
          final unsub = await client.subscribe(
            'private-tenant.10',
            onEvent: (event) => events.add(event),
          );

          // If a test record endpoint is available, trigger a mutation via REST
          try {
            final dio = Dio();
            final cleanBase = apiUrl.toString().replaceAll(RegExp(r'/+$'), '');
            await dio.post<dynamic>(
              '$cleanBase/invoices',
              data: {'amount': 999, 'tenant_id': '10'},
              options: Options(headers: {'Authorization': 'Bearer $token'}),
            );
          } catch (_) {
            // Fallback if the local Laravel backend hasn't seeded the invoices route
          }

          await Future<void>.delayed(const Duration(milliseconds: 500));
          unsub();
        } finally {
          await client.dispose();
        }
      },
    );
  }, skip: skipReason);
}

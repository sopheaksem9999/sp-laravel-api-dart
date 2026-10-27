import 'dart:async';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';

/// Kill switch feature flags for gradual rollout in client applications.
const bool useNewApiClient = bool.fromEnvironment(
  'USE_SP_API_CLIENT',
  defaultValue: true,
);

const bool useNewRealtimeClient = bool.fromEnvironment(
  'USE_SP_REALTIME_CLIENT',
  defaultValue: true,
);

/// Simple model for demonstrative typed table access.
class Invoice {
  final int id;
  final String number;
  final num total;

  const Invoice({required this.id, required this.number, required this.total});

  factory Invoice.fromJson(Map<String, dynamic> json) => Invoice(
    id: (json['id'] as num).toInt(),
    number: json['number']?.toString() ?? '',
    total: json['total'] as num? ?? 0,
  );
}

Future<void> main() async {
  // 1. Create REST client configured with ApiAuth seam
  final api = SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    tenant: TenantConfig(header: 'X-Tenant-ID', value: () => '42'),
    auth: ApiAuth(
      headers: () async => {'Authorization': 'Bearer sample_access_token'},
      handleUnauthorized: () async => false,
    ),
    dio: Dio(),
  );

  // 2. Query table records with filters and sorting
  final invoicesTable = api.table('invoices', fromJson: Invoice.fromJson);
  print('Configured table: ${invoicesTable.name}');

  // 3. Create Realtime client connecting to Laravel Reverb
  final rt = SpRealtime(
    apiBaseUrl: Uri.parse('https://api.example.com/api/v1'),
    driver: Driver.reverb(
      host: 'ws.example.com',
      port: 443,
      appKey: 'app-key-123',
      useTls: true,
    ),
    tokenProvider: () async => 'sample_access_token',
    dio: Dio(),
  );

  rt.onRecovered(() async {
    print('Connection recovered: invalidating UI caches');
  });

  rt.onDisconnected(() {
    print('Connection disconnected');
  });

  print('Realtime client initialized: connected=${rt.isConnected}');
  await rt.dispose();
}

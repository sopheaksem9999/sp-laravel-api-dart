# sp_laravel_api

Typed REST client and multi-broadcaster realtime client for the SP Laravel backend packages (`sp-laravel-api`).

## Features

- **Typed Table Gateway:** Record CRUD (`list`, `get`, `create`, `update`, `remove`) with cursor and offset pagination.
- **Strict Query Builder:** Fluent filter operators, composite AND/OR groups, relationship embedding, and deterministic query serialization.
- **REST Modules:**
  - `BulkModule`: Chunked bulk insert, update, upsert, and delete operations (automatic 1000-record chunking).
  - `AttachmentsModule`: Upload management via signed URLs or direct multipart file uploads.
  - `AuditModule`: Audit log inspection, activity timelines, and statistics.
  - `PermissionsModule`: User roles, permissions, and direct grant/revoke operations.
- **Multi-Broadcaster Realtime:** Native Pusher protocol framing over `web_socket_channel` supporting Laravel Reverb, Pusher Channels, Soketi, and Ably.
- **Intent Recovery & Reconnection:** Automatically recovers subscribed channels and private channel authorization after network disconnects or backend redeploys.
- **Typegen CLI:** Generates immutable Dart data models directly from OpenAPI 3.x specifications.
- **Decoupled Auth:** Pluggable auth via the lightweight `ApiAuth` seam (seamlessly links with `sp_jwt_auth` without mutual package coupling).
- **Pure Dart & Cross-Platform:** Zero Flutter SDK dependencies; fully compatible with Flutter (iOS, Android, web, desktop) and Dart server/CLI applications.

## Installation

Add `sp_laravel_api` to your `pubspec.yaml`:

```yaml
dependencies:
  sp_laravel_api:
    git:
      url: https://github.com/sopheaksem9999/sp-laravel-api-dart.git
      ref: v0.1.0-beta.1
```

## Quick Start

```dart
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';

final api = SpApi(
  baseUrl: Uri.parse('https://api.example.com/api/v1'),
  tenant: TenantConfig(header: 'X-Tenant-ID', value: () => '42'),
  auth: ApiAuth(
    headers: () async => {'Authorization': 'Bearer <token>'},
    handleUnauthorized: () async => false,
  ),
  dio: Dio(),
);

final invoices = api.table('invoices', fromJson: Invoice.fromJson);
final page = await invoices.list(
  select: 'id,number,total,status',
  where: [
    Filter.eq('status', 'paid'),
    Filter.gte('total', 100),
  ],
  sort: Sort('created_at', Order.desc),
  perPage: 25,
);

for (final invoice in page.items) {
  print('Invoice: ${invoice.number}');
}
```

## Realtime Broadcasting

```dart
final rt = SpRealtime(
  apiBaseUrl: Uri.parse('https://api.example.com/api/v1'),
  driver: Driver.reverb(
    host: 'ws.example.com',
    port: 443,
    appKey: 'app-key-123',
    useTls: true,
  ),
  tokenProvider: () async => 'jwt-token',
);

await rt.connect();

final unsubscribe = await rt.subscribe(
  'private-tenant.42',
  events: {'invoices.created', 'invoices.updated'},
  onEvent: (event) {
    print('Event received: ${event.table}.${event.action.name}');
    print('Record payload: ${event.record}');
  },
);

// When done:
unsubscribe();
```

## Typegen CLI

Generate immutable Dart model classes from an OpenAPI 3.x specification:

```bash
dart run sp_laravel_api:typegen --file path/to/openapi.json --out lib/src/models
```

## Verification Status

- **Rung 1 (In-Process Fake Pusher Server):** Verified in automated integration tests (`test/realtime/fake_pusher_integration_test.dart`) exercising real TCP/WebSocket handshakes, private auth subscriptions, event dispatches, and socket death auto-recovery.
- **Rung 2 (Local Reverb Server Harness):** Contract test suite (`test/contract/reverb_contract_test.dart`) executable against local Laravel Reverb via `contract/reverb-harness/run-harness.sh --dart`.
- **Rung 3 (Diagnostic Probe Tool):** CLI probe tool (`tool/reverb_probe.dart`) for probing and validating live Reverb or Soketi instances.
- **Automated Tests:** 77 tests passing (unit, REST modules, realtime, typegen, wire characterization).
- **Public-Repo Hygiene:** Zero forbidden internal names; automated secret scanning with Gitleaks.

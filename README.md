# sp_laravel_api

Typed REST client and multi-broadcaster realtime client for the SP Laravel backend packages (`sp-laravel-api`).

## Features

- **Typed Table Gateway:** Record CRUD (`list`, `get`, `create`, `update`, `remove`) with cursor and offset pagination.
- **Strict Query Builder:** Fluent filters, composite and/or groups, relationship embedding, and deterministic query serialization.
- **Multi-Broadcaster Realtime:** Built-in Pusher-protocol framing over `web_socket_channel` supporting Laravel Reverb, Pusher Channels, Soketi, and Ably.
- **Intent Recovery & Reconnection:** Automatically recovers subscribed channels and private channel authorization after network disconnects or backend redeploys.
- **Cross-Platform:** Pure Dart core libraries compatible with Android, iOS, web, macOS, Windows, Linux, and Wasm.
- **Decoupled Auth:** Seamless integration with `sp_jwt_auth` via the lightweight `ApiAuth` seam.

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
  baseUrl: Uri.parse('https://api.example.com'),
  tenant: TenantConfig(header: 'X-Tenant-ID', value: () => '42'),
);

final invoices = api.table('invoices', fromJson: Invoice.fromJson);
final page = await invoices.list(
  select: 'id,ref_number,total',
  where: [Filter.eq('status', 'paid')],
  sort: Sort('created_at', Order.desc),
  perPage: 20,
);
```

## Realtime Broadcasting

```dart
import 'package:sp_laravel_api/realtime.dart';

final rt = SpRealtime(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  driver: Driver.reverb(host: 'ws.example.com', port: 443, appKey: 'app-key', useTls: true),
  tokenProvider: () async => 'jwt-token',
);

await rt.connect();
final cancel = await rt.subscribe('private-tenant.42', events: {'invoices.created'}, onEvent: (event) {
  print('Invoice created: ${event.record}');
});
```

## Verification Status

- **Fake Backend & Fake Pusher:** Verified in CI.
- **Reverb Contract Ladder:** Local Reverb harness verified.

# sp_laravel_api

Typed Dart & Flutter client service for the [`sopheak/sp-laravel-api`](https://packagist.org/packages/sopheak/sp-laravel-api) Laravel backend package.

> [!IMPORTANT]
> **Client Service Compatibility Notice:**  
> `sp_laravel_api` is a client-side library and **works only with** backends running [`sopheak/sp-laravel-api`](https://packagist.org/packages/sopheak/sp-laravel-api). It provides strongly-typed Table Gateway CRUD operations, deterministic query serialization, REST modules (bulk, attachments, audit, permissions), and multi-broadcaster realtime event subscriptions (Laravel Reverb, Pusher, Soketi).

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
  sp_laravel_api: ^0.1.0
```

Or install from git:

```yaml
dependencies:
  sp_laravel_api:
    git:
      url: https://github.com/sopheaksem9999/sp-laravel-api-dart.git
      ref: v0.1.0
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

## Pairing with sp_jwt_auth

Hand the auth object's two functions to `ApiAuth`. `SpApi` then adds the bearer header and, on a 401, calls `handleUnauthorized` once and retries.

```dart
final api = SpApi(
  baseUrl: Uri.parse('https://api.example.com/api/v1'),
  auth: ApiAuth(
    headers: auth.headers,
    handleUnauthorized: auth.handleUnauthorized,
  ),
);
```

> [!WARNING]
> Do not also call `attach(dio)` on the same `Dio`. `attach(dio)` installs a second refreshing interceptor, so a 401 would be handled twice. Use either `ApiAuth` with `headers`/`handleUnauthorized`, or `attach(dio)`, never both. See the Flutter mobile section of the [`sp_jwt_auth` README](https://github.com/sopheaksem9999/sp-jwt-auth-dart#flutter-mobile).

## RPC calls

`rpc` calls `{rpcPrefix}/{name}` (prefix defaults to `rpc`). It sends `POST` when a `body` is given and `GET` otherwise; `method`, `query` and Dio `options` override that. A `{data: ...}` envelope is unwrapped before `fromJson` runs. Covered by [`test/core/sp_api_test.dart`](test/core/sp_api_test.dart) and [`test/core/table_gateway_options_test.dart`](test/core/table_gateway_options_test.dart).

```dart
// POST rpc/invoices/send with a JSON body.
final sent = await api.rpc<Map<String, dynamic>>(
  'invoices/send',
  body: {'invoice_id': 7},
);

// GET rpc/reports/summary?year=2026, mapped into a typed value.
final total = await api.rpc<int>(
  'reports/summary',
  query: {'year': 2026},
  fromJson: (data) => (data as Map<String, dynamic>)['total'] as int,
);
```

## Errors: SpApiError

Every failure is an `SpApiError`. Tests: [`test/core/api_errors_test.dart`](test/core/api_errors_test.dart) and [`test/core/api_transport_error_test.dart`](test/core/api_transport_error_test.dart).

| Field | Meaning |
| --- | --- |
| `status` | HTTP status; `0` for transport failures (no response). |
| `code` | `SpApiErrorCode`: `unauthenticated`, `forbidden`, `notFound`, `validation`, `tenantRequired`, `moduleDisabled`, `notConfigured`, `unencodableValue`, `rateLimited`, `server`, `network`, `timeout`, `unknown`. |
| `errorCode` | Backend numeric code (for example `10002`). On a `200` `success: false` envelope, `code` is mapped from it: `10002` unauthenticated, `10008` forbidden, `10009` notFound, `10004` validation, `10010` server; anything else is `unknown`. |
| `fieldErrors` | `Map<String, List<String>>` of per-field validation messages. |
| `requestId` | Backend request id, for support tickets. |
| `retryAfter` | Seconds to wait: the `Retry-After` header, then body `retry_after`, then `errors.retry_after_seconds`. |
| `isTransport` / `isHttp` | `isTransport` is true for `network` and `timeout` failures (`status == 0`, no response); local errors such as a missing `select` also have `status == 0` but are not transport failures. `isHttp` is `status > 0`. |
| `cause` / `stackTrace` | The originating `DioException` for transport failures. `toString()` never prints the cause. |

```dart
try {
  await api.table('invoices', fromJson: Invoice.fromJson).create({
    'number': '',
  });
} on SpApiError catch (e) {
  if (e.isTransport) {
    print('Network failure: ${e.cause}');
  } else if (e.code == SpApiErrorCode.validation) {
    print(e.fieldErrors['number']);
  } else if (e.retryAfter != null) {
    print('Retry in ${e.retryAfter} seconds');
  }
  print('Request id for support: ${e.requestId}');
}
```

### Envelope behaviour (`success: false`)

A response with status below 400 whose JSON body is a map with `success: false` is raised as `SpApiError` (its `status` stays the HTTP status, for example 200). `error_code` `10002` on such a response goes through `ApiAuth.handleUnauthorized()` and is retried once, like a 401. Bytes and non-map bodies are unaffected. This is on by default; to restore the 0.1.0 behaviour, set `treatSuccessFalseAsError: false`. Tests: [`test/core/api_envelope_test.dart`](test/core/api_envelope_test.dart).

```dart
final api = SpApi(
  baseUrl: Uri.parse('https://api.example.com/api/v1'),
  treatSuccessFalseAsError: false,
);
```

## Pagination

`list` supports cursor and offset modes. Tests: [`test/core/cursor_test.dart`](test/core/cursor_test.dart) and [`test/core/table_gateway_test.dart`](test/core/table_gateway_test.dart).

- **Cursor:** pass `cursor`, optionally `direction` (`next` or `prev`) and `cursorColumn`; they are sent as `cursor=`, `direction=` and `cursor_column=`. An empty cursor is sent as `cursor=` (first page); `null` sends none. `nextCursor` is `meta['next_cursor']` whenever the backend provides it, whatever the item count, and `null` otherwise; the backend sends it on every non-empty page, so the end of the data is an empty page. Sending no `cursor` means offset mode, which never returns a `nextCursor`, so start a cursor loop with `cursor: ''` (`iterate`, `fetchFirst` and `cursorPagination().firstPage()` do this for you).
- **Offset:** pass `page` (and `total: true` for a count). Offset mode never yields a `nextCursor`.

```dart
// Cursor pagination.
var page = await invoices.list(select: 'id,number', perPage: 50, cursor: '');
while (true) {
  for (final invoice in page.items) {
    print(invoice.number);
  }
  final next = page.nextCursor;
  if (next == null) break;
  page = await invoices.list(select: 'id,number', perPage: 50, cursor: next);
}

// Offset pagination.
final second = await invoices.list(
  select: 'id,number',
  page: 2,
  perPage: 50,
  total: true,
);
print(second.total);
```

## The select rule

Reads must say which columns they want. Omitting `select` throws `SpApiError` (`unencodableValue`) with a message that names the opt-out `requireSelect: false`. Relations are embedded in the `select` string: `rel(*)` for all columns of a relation, `rel(col,child(...))` for nested ones. Tests: [`test/core/query_serializer_test.dart`](test/core/query_serializer_test.dart).

```dart
// Columns and relations.
await invoices.list(select: 'id,number,customer(*)');
await invoices.list(select: 'id,number,lines(id,qty,product(id,name))');

// Explicit opt-out.
await invoices.list(select: Select.all);
await invoices.list(requireSelect: false);
```

## Upsert availability

`TableGateway.upsert` posts to `{table}/upsert?match_on=...`. Many backends disable it: a `404` (or `405` on some hosts) typically means upsert is disabled, so fall back to `update`/`create`. A `404` surfaces as `SpApiErrorCode.notFound` ([`test/core/api_errors_test.dart`](test/core/api_errors_test.dart)); per-request options are forwarded ([`test/core/table_gateway_options_test.dart`](test/core/table_gateway_options_test.dart)).

```dart
try {
  await invoices.upsert({'number': 'INV-1'}, matchOn: ['number']);
} on SpApiError catch (e) {
  if (e.status == 404 || e.status == 405) {
    print('upsert is disabled on this backend');
  } else {
    rethrow;
  }
}
```

## Retries

Retries are off by default. Configure `RetryConfig` on `SpApi` and only `GET`/`HEAD` are retried (statuses 408, 429, 502, 503, 504 and connection errors, with exponential backoff, jitter and `Retry-After`). Pass `retry: true` per request to retry a non-idempotent call, or `retry: false` to skip. Tests: [`test/core/api_retry_test.dart`](test/core/api_retry_test.dart).

```dart
final api = SpApi(
  baseUrl: Uri.parse('https://api.example.com/api/v1'),
  retry: const RetryConfig(maxAttempts: 3),
);
```

```dart
await api.request('POST', 'invoices', data: {'number': 'INV-2'}, retry: true);
await api.request('GET', 'invoices', retry: false);
```

## Per-request options

Every `TableGateway` method (`list`, `get`, `create`, `update`, `patch`, `remove`, `restore`, `upsert`) accepts Dio `Options` and a `CancelToken`. Per-request headers win over tenant and auth headers. Tests: [`test/core/table_gateway_options_test.dart`](test/core/table_gateway_options_test.dart).

```dart
final cancel = CancelToken();
final page = await invoices.list(
  select: 'id,number',
  options: Options(headers: {'X-Request-Source': 'mobile'}),
  cancelToken: cancel,
);
// Later, e.g. when the screen closes: cancel.cancel();
```

## Attachments

`upload` sends one multipart POST (`bytes` or `filePath`, `visibility` defaults to `private`); `link`/`unlink` attach a file to a record; `viewBytes` fetches protected content with your auth headers. Tests: [`test/modules/attachments_upload_test.dart`](test/modules/attachments_upload_test.dart).

```dart
final bytes = Uint8List.fromList([1, 2, 3]);
final file = await attachments.upload(bytes: bytes, filename: 'scan.pdf');
await attachments.link('invoices', 7, file['id'].toString());
final content = await attachments.viewBytes(file['id'].toString());
await attachments.unlink('invoices', 7, file['id'].toString());
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

`subscribe` completes only after the server confirms the channel (`pusher_internal:subscription_succeeded`), so reading current state right after it returns cannot miss an event. It throws `SpApiError` with code `timeout` when no confirmation arrives within `subscribeTimeout` (default 10 seconds), or the channel authorization error; in both cases no subscription is left registered, so a later reconnect does not rejoin it. A second `subscribe` to a confirmed channel returns at once with no new frame, and concurrent subscribers on a pending channel share one confirmation.

A custom `RealtimeTransport` implementation or test fake must deliver `pusher_internal:subscription_succeeded` for each `pusher:subscribe` it receives, as a real server does, or `subscribe` times out.

Known limitation: the Pusher protocol has no correlation id, so a very late confirmation (more than `subscribeTimeout`) of an abandoned subscribe frame can complete a new `subscribe` to the same channel early.

After a reconnect, a channel whose re-subscribe fails is retried with exponential backoff (`subscribeBackoff`, default 300 ms, doubling, capped at 5 s) up to `subscribeAttempts` (default 3) times. The final failure is reported once through `onSubscribeFailed(channel, error)` and the client stops retrying that channel until the next reconnect. Tests: [`test/realtime/subscribe_confirmation_test.dart`](test/realtime/subscribe_confirmation_test.dart).

Pass `subscribeTimeout`, `subscribeAttempts`, `subscribeBackoff` and `onSubscribeFailed` to the `SpRealtime` constructor to tune this.

### Non-record events

`RecordEvent` exposes `eventName`, `raw` (the full payload) and `isRecord` (true only for a string `table` plus a map `record`). A missing or unknown `action` maps to `RecordAction.unknown`. Tests: [`test/realtime/raw_event_test.dart`](test/realtime/raw_event_test.dart).

```dart
await rt.subscribe(
  'private-tenant.42',
  events: {'invoices.updated', 'courier_location.updated'},
  onEvent: (event) {
    if (event.isRecord) {
      print('${event.table}: ${event.action.name}');
    } else {
      print('${event.eventName}: ${event.raw}');
    }
  },
);
```

### Realtime recovery

After a socket death the client reconnects, re-authorizes private channels and re-subscribes. Hook your app in with `onDisconnected`, `onRecovered` (refetch what you missed), `onAppPaused`/`onAppResumed` and `onNetworkChanged`. Tests: [`test/realtime/realtime_lifecycle_test.dart`](test/realtime/realtime_lifecycle_test.dart) and [`test/realtime/fake_pusher_integration_test.dart`](test/realtime/fake_pusher_integration_test.dart).

```dart
rt.onDisconnected(() => print('socket lost'));
rt.onRecovered(() async {
  // Channels are re-authorized and re-subscribed; refetch missed data.
});

// Wire these to your app lifecycle and connectivity plugin.
rt.onAppPaused();
rt.onAppResumed();
rt.onNetworkChanged(true);
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
- **Automated Tests:** unit, REST modules, realtime, typegen, wire characterization and README checks (`dart test`).
- **Public-Repo Hygiene:** Zero forbidden internal names; automated secret scanning with Gitleaks.

# Changelog

## Unreleased

- `RecordEvent` now exposes `eventName` (the broadcast event name), `raw` (the full payload as broadcast) and `isRecord` (true only when the payload has a string `table` and a map `record`). Non-record events such as `courier_location.updated` are delivered to the `subscribe` handler with all fields in `raw`. A non-map `record` no longer yields surprises: it gives an empty `record` and `isRecord == false`.
- **Behaviour change:** added `RecordAction.unknown`. A payload with a missing or unrecognised `action` now maps to `unknown` instead of `created`. Exhaustive `switch` statements over `RecordAction` need a new case.

- `TableGateway.list/get/create/update/patch/remove/restore/upsert` accept optional `Options? options` and `CancelToken? cancelToken`, forwarded to `SpApi.request` (per-request headers win over tenant/auth headers). Existing calls are unchanged.
- `SpApi.rpc` accepts optional `query` (query parameters), `method` (override; default stays POST with a body, GET otherwise) and `options` (Dio `Options` merged into the request).
- **BREAKING (behaviour change):** `SpApi.request` now throws `SpApiError` (status stays the HTTP status, e.g. 200) when a response with status < 400 has a JSON map body with `success: false`. Error code 10002 on such a response is routed through `ApiAuth.handleUnauthorized()` and retried once, like a 401. Bytes responses and non-map bodies are unaffected. Opt out with `SpApi(treatSuccessFalseAsError: false)` to restore the 0.1.0 behaviour.
- `SpApiError.retryAfter` now also reads `errors.retry_after_seconds` (first element, int or numeric string; zero or negative ignored) as a last fallback after the `Retry-After` header and body `retry_after`. The value remains in `fieldErrors`.
- `SpApiError` now carries the transport `cause` and `stackTrace` (the originating `DioException`) for status 0 failures, plus `isTransport` / `isHttp` getters. `toString()` never prints the cause.

## 0.1.0 (2026-10-27)

- First stable release of `sp_laravel_api` for Dart and Flutter.
- Added configurable `RetryConfig` with exponential backoff, full jitter, and `Retry-After` header parsing for transient HTTP errors.
- Added remote OpenAPI schema resolution (`--url`, `--schema`, `--header`, `--token`, `--tenant`) to typegen CLI.
- Added `Sort.reversed()` and cursor pagination boundary helpers (`fetchFirst`, `fetchLast`, `fetchNext`, `fetchPrev`, `cursorPagination`) on `TableGateway`.

## 0.1.0-beta.2 (2026-10-27)

- Verified automated GitHub Actions OIDC publishing pipeline to pub.dev.
- Enhanced CI hygiene tooling with default fallback checks.

## 0.1.0-beta.1 (2026-10-27)

- Initial beta release of `sp_laravel_api` for Dart and Flutter.
- Typed `TableGateway` with cursor and offset pagination.
- Query builder serializing filters, relationships, and sorting.
- Multi-broadcaster realtime engine for Laravel Reverb, Pusher, Soketi, and Ably.
- Cross-platform support for VM, web, and Wasm.

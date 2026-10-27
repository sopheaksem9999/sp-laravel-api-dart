# Changelog

## Unreleased

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

# Changelog

## Unreleased

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

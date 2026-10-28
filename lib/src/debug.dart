import 'package:dio/dio.dart';

const String _debugHeader = 'X-Debug';

/// Per-request opt-in asking the SERVER for diagnostics.
///
/// Sends `X-Debug: 1`, so the backend adds lazy-loading diagnostics to
/// responses and debug details to errors. It logs nothing on the client; for
/// client-side logging see [SpLog]. Keep it off in production builds.
///
/// ```dart
/// table.list(select: 'id', options: SpDebug.on());
/// ```
///
/// To combine with other per-request options use [merge].
class SpDebug {
  SpDebug._();

  /// Options carrying the `X-Debug: 1` header.
  static Options on() => Options(headers: {_debugHeader: '1'});

  /// Returns [base] (or fresh options) with `X-Debug: 1` added, keeping every
  /// other option, including its other headers and `extra` entries. An
  /// `X-Debug` header already in [base] is replaced.
  static Options merge(Options? base) => (base ?? Options()).copyWith(
    headers: {...?base?.headers, _debugHeader: '1'},
  );
}

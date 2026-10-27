import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'api_auth.dart';
import 'errors.dart';
import 'table_gateway.dart';

/// Configuration policy for automatic retries on transient errors.
class RetryConfig {
  /// Maximum number of retry attempts. Defaults to 0 (retries disabled).
  final int maxAttempts;

  /// HTTP status codes that should trigger an automatic retry.
  final Set<int> statusCodes;

  /// Whether transport/network connection errors and timeouts should trigger a retry.
  final bool retryOnConnectionError;

  /// Initial backoff delay before the first retry.
  final Duration initialBackoff;

  /// Maximum cap for exponential backoff delay.
  final Duration maxBackoff;

  /// Whether to add pseudo-random jitter to the backoff delay to prevent thundering herds.
  final bool jitter;

  const RetryConfig({
    this.maxAttempts = 0,
    this.statusCodes = const {408, 429, 502, 503, 504},
    this.retryOnConnectionError = true,
    this.initialBackoff = const Duration(milliseconds: 300),
    this.maxBackoff = const Duration(seconds: 5),
    this.jitter = true,
  });

  /// Creates a copy of this [RetryConfig] with the given fields replaced.
  RetryConfig copyWith({
    int? maxAttempts,
    Set<int>? statusCodes,
    bool? retryOnConnectionError,
    Duration? initialBackoff,
    Duration? maxBackoff,
    bool? jitter,
  }) {
    return RetryConfig(
      maxAttempts: maxAttempts ?? this.maxAttempts,
      statusCodes: statusCodes ?? this.statusCodes,
      retryOnConnectionError:
          retryOnConnectionError ?? this.retryOnConnectionError,
      initialBackoff: initialBackoff ?? this.initialBackoff,
      maxBackoff: maxBackoff ?? this.maxBackoff,
      jitter: jitter ?? this.jitter,
    );
  }
}

/// Central HTTP and RPC client for the SP Laravel backend.
class SpApi {
  /// Base API endpoint URL (e.g. `https://example.com/api/v1`).
  final Uri baseUrl;

  /// Authentication contract for header resolution and 401 refresh handling.
  final ApiAuth? auth;

  /// Optional multi-tenancy configuration.
  final TenantConfig? tenant;

  /// RPC endpoint prefix. Defaults to `'rpc'`.
  final String rpcPrefix;

  /// Automatic retry configuration for transient failures. Disabled by default.
  final RetryConfig? retry;

  /// Whether a response with status < 400 whose JSON body is a map with
  /// `success == false` is raised as [SpApiError]. Defaults to `true`.
  /// Set to `false` to restore the 0.1.0 behaviour (response returned as is).
  final bool treatSuccessFalseAsError;

  /// The underlying [Dio] HTTP client instance.
  final Dio dio;

  /// Creates a new [SpApi] instance.
  SpApi({
    required this.baseUrl,
    this.auth,
    this.tenant,
    this.rpcPrefix = 'rpc',
    this.retry,
    this.treatSuccessFalseAsError = true,
    Dio? dio,
  }) : dio = dio ?? Dio();

  /// Creates a typed [TableGateway] targeting table [name].
  TableGateway<T> table<T>(
    String name, {
    required T Function(Map<String, dynamic>) fromJson,
  }) => TableGateway<T>(api: this, name: name, fromJson: fromJson);

  /// Executes an RPC call to `{rpcPrefix}/{name}`.
  Future<T> rpc<T>(
    String name, {
    Map<String, dynamic>? body,
    T Function(dynamic)? fromJson,
  }) async {
    final cleanPrefix = rpcPrefix.replaceAll(RegExp(r'^/+|/+$'), '');
    final cleanName = name.replaceAll(RegExp(r'^/+'), '');
    final path = cleanPrefix.isEmpty ? cleanName : '$cleanPrefix/$cleanName';

    final res = await request(body != null ? 'POST' : 'GET', path, data: body);

    final raw = res.data;
    dynamic payload = raw;
    if (raw is Map<String, dynamic> && raw.containsKey('data')) {
      payload = raw['data'];
    }

    if (fromJson != null) {
      return fromJson(payload);
    }
    return payload as T;
  }

  /// Fetches raw bytes (e.g. for protected file downloads).
  Future<List<int>> getBytes(String path) async {
    final res = await request(
      'GET',
      path,
      options: Options(responseType: ResponseType.bytes),
    );
    if (res.data is List<int>) {
      return res.data as List<int>;
    }
    return List<int>.from(res.data as Iterable<dynamic>);
  }

  /// Core request executor with auth headers and automatic retry handling.
  Future<Response<dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Options? options,
    CancelToken? cancelToken,
    Object? retry,
  }) async {
    final cleanBase = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final cleanPath = path.replaceAll(RegExp(r'^/+'), '');
    final fullUrl = '$cleanBase/$cleanPath';

    final upperMethod = method.toUpperCase();
    final isIdempotent = upperMethod == 'GET' || upperMethod == 'HEAD';

    final RetryConfig effectiveConfig;
    final bool retryEnabled;

    if (retry == false) {
      retryEnabled = false;
      effectiveConfig = const RetryConfig();
    } else if (retry is RetryConfig) {
      retryEnabled = retry.maxAttempts > 0;
      effectiveConfig = retry;
    } else if (retry == true) {
      effectiveConfig = this.retry ?? const RetryConfig(maxAttempts: 3);
      retryEnabled = effectiveConfig.maxAttempts > 0;
    } else {
      // retry is null (default)
      effectiveConfig = this.retry ?? const RetryConfig();
      retryEnabled = isIdempotent && effectiveConfig.maxAttempts > 0;
    }

    int retryCount = 0;
    bool authRefreshed = false;

    for (;;) {
      if (cancelToken != null && cancelToken.isCancelled) {
        throw DioException(
          requestOptions: RequestOptions(path: fullUrl),
          type: DioExceptionType.cancel,
          message: 'Request was cancelled',
        );
      }

      final reqHeaders = <String, dynamic>{'Accept': 'application/json'};

      if (tenant != null) {
        final tVal = tenant!.value();
        if (tVal != null && tVal.isNotEmpty) {
          reqHeaders[tenant!.header] = tVal;
        }
      }

      if (auth != null) {
        final authHeaders = await auth!.headers();
        reqHeaders.addAll(authHeaders);
      }

      if (options?.headers != null) {
        reqHeaders.addAll(options!.headers!);
      }

      final reqOptions = (options ?? Options()).copyWith(
        method: method,
        headers: reqHeaders,
      );

      try {
        final res = await dio.request<dynamic>(
          fullUrl,
          data: data,
          queryParameters: queryParameters,
          options: reqOptions,
          cancelToken: cancelToken,
        );

        if ((res.statusCode ?? 200) >= 400) {
          final isTransientStatus = effectiveConfig.statusCodes.contains(
            res.statusCode,
          );
          if (retryEnabled &&
              retryCount < effectiveConfig.maxAttempts &&
              isTransientStatus) {
            retryCount++;
            final retryAfter = _parseRetryAfter(res.headers);
            final delay = _calculateBackoff(
              retryCount - 1,
              effectiveConfig,
              retryAfter,
            );
            await _delayWithCancel(delay, cancelToken, fullUrl);
            continue;
          }
          throw SpApiError.fromResponse(res, tenantHeader: tenant?.header);
        }

        if (treatSuccessFalseAsError &&
            reqOptions.responseType != ResponseType.bytes &&
            res.data is Map &&
            (res.data as Map)['success'] == false) {
          final envelopeError = SpApiError.fromResponse(
            res,
            tenantHeader: tenant?.header,
          );
          if (envelopeError.errorCode == 10002 &&
              auth != null &&
              !authRefreshed) {
            authRefreshed = true;
            final recovered = await auth!.handleUnauthorized();
            if (recovered) {
              continue;
            }
          }
          throw envelopeError;
        }

        return res;
      } on DioException catch (dioErr) {
        if (dioErr.type == DioExceptionType.cancel ||
            (cancelToken != null && cancelToken.isCancelled)) {
          rethrow;
        }

        final res = dioErr.response;
        if (res != null &&
            res.statusCode == 401 &&
            !authRefreshed &&
            auth != null) {
          authRefreshed = true;
          final recovered = await auth!.handleUnauthorized();
          if (recovered) {
            continue;
          }
        }

        final isTransientStatus =
            res != null && effectiveConfig.statusCodes.contains(res.statusCode);
        final isTransientConnection =
            res == null &&
            effectiveConfig.retryOnConnectionError &&
            dioErr.type != DioExceptionType.cancel &&
            dioErr.type != DioExceptionType.badCertificate;

        if (retryEnabled &&
            retryCount < effectiveConfig.maxAttempts &&
            (isTransientStatus || isTransientConnection)) {
          retryCount++;
          final retryAfter = res != null ? _parseRetryAfter(res.headers) : null;
          final delay = _calculateBackoff(
            retryCount - 1,
            effectiveConfig,
            retryAfter,
          );
          await _delayWithCancel(delay, cancelToken, fullUrl);
          continue;
        }

        if (res != null) {
          throw SpApiError.fromResponse(res, tenantHeader: tenant?.header);
        }

        final code =
            dioErr.type == DioExceptionType.connectionTimeout ||
                dioErr.type == DioExceptionType.receiveTimeout ||
                dioErr.type == DioExceptionType.sendTimeout
            ? SpApiErrorCode.timeout
            : SpApiErrorCode.network;

        throw SpApiError(
          status: 0,
          code: code,
          message: dioErr.message ?? 'HTTP transport failed',
          cause: dioErr,
          stackTrace: dioErr.stackTrace,
        );
      }
    }
  }

  Duration? _parseRetryAfter(Headers? headers) {
    if (headers == null) return null;
    final val = headers.value('retry-after');
    if (val == null) return null;
    final trimmed = val.trim();
    final seconds = int.tryParse(trimmed);
    if (seconds != null) {
      return Duration(seconds: seconds);
    }
    final date = DateTime.tryParse(trimmed);
    if (date != null) {
      final diff = date.difference(DateTime.now());
      return diff > Duration.zero ? diff : Duration.zero;
    }
    return null;
  }

  Duration _calculateBackoff(
    int attempt,
    RetryConfig config,
    Duration? retryAfter,
  ) {
    if (retryAfter != null && retryAfter > Duration.zero) {
      return retryAfter <= config.maxBackoff ? retryAfter : config.maxBackoff;
    }

    final shift = attempt >= 30 ? 30 : attempt;
    final factor = 1 << shift;
    var ms = config.initialBackoff.inMilliseconds * factor;
    if (ms > config.maxBackoff.inMilliseconds) {
      ms = config.maxBackoff.inMilliseconds;
    }

    if (config.jitter && ms > 0) {
      final min = (ms * 0.5).round();
      final delta = ms - min;
      final randomMs = min + (delta > 0 ? math.Random().nextInt(delta + 1) : 0);
      return Duration(milliseconds: randomMs);
    }

    return Duration(milliseconds: ms);
  }

  Future<void> _delayWithCancel(
    Duration duration,
    CancelToken? cancelToken,
    String path,
  ) async {
    if (cancelToken != null && cancelToken.isCancelled) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.cancel,
        message: 'Request was cancelled',
      );
    }
    if (duration <= Duration.zero) return;

    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel
            .then((dioErr) {
              timer.cancel();
              if (!completer.isCompleted) {
                completer.completeError(dioErr);
              }
            })
            .catchError((dynamic err) {
              timer.cancel();
              if (!completer.isCompleted) {
                completer.completeError(err as Object);
              }
            }),
      );
    }

    await completer.future;
  }
}

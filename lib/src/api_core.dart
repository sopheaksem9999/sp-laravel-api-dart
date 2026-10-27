import 'package:dio/dio.dart';
import 'api_auth.dart';
import 'errors.dart';
import 'table_gateway.dart';

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

  /// The underlying [Dio] HTTP client instance.
  final Dio dio;

  /// Creates a new [SpApi] instance.
  SpApi({
    required this.baseUrl,
    this.auth,
    this.tenant,
    this.rpcPrefix = 'rpc',
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

  /// Core request executor with auth headers and single-retry 401 handling.
  Future<Response<dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final cleanBase = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final cleanPath = path.replaceAll(RegExp(r'^/+'), '');
    final fullUrl = '$cleanBase/$cleanPath';

    for (int attempt = 0; ; attempt++) {
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
          throw SpApiError.fromResponse(res, tenantHeader: tenant?.header);
        }

        return res;
      } on DioException catch (dioErr) {
        final res = dioErr.response;
        if (res != null &&
            res.statusCode == 401 &&
            attempt == 0 &&
            auth != null) {
          final recovered = await auth!.handleUnauthorized();
          if (recovered) {
            continue;
          }
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
        );
      }
    }
  }
}

import 'package:dio/dio.dart';

/// Error codes matching the SP Laravel API taxonomy.
enum SpApiErrorCode {
  unauthenticated,
  forbidden,
  notFound,
  validation,
  tenantRequired,
  moduleDisabled,
  notConfigured,
  unencodableValue,
  rateLimited,
  server,
  network,
  timeout,
  unknown,
}

/// Standard error exception thrown by `sp_laravel_api` operations.
class SpApiError implements Exception {
  /// HTTP status code (e.g. 401, 403, 404, 422, 429, 500).
  final int status;

  /// High-level classified error code.
  final SpApiErrorCode code;

  /// Backend internal error code (e.g. 10002, 10004, 10010).
  final int? errorCode;

  /// Normalized field validation errors mapping field name to error list.
  final Map<String, List<String>> fieldErrors;

  /// Unique request trace identifier.
  final String? requestId;

  /// Number of seconds before retrying rate-limited requests.
  final int? retryAfter;

  /// Human-readable error message.
  final String message;

  /// Raw response body.
  final dynamic body;

  /// Whether the request failed because a tenant identifier was missing.
  final bool tenantRequired;

  /// Creates a new [SpApiError].
  const SpApiError({
    required this.status,
    required this.code,
    required this.message,
    this.errorCode,
    this.fieldErrors = const {},
    this.requestId,
    this.retryAfter,
    this.body,
    this.tenantRequired = false,
  });

  /// Factory constructing [SpApiError] from a Dio [Response].
  factory SpApiError.fromResponse(
    Response<dynamic> response, {
    String? tenantHeader,
  }) {
    final status = response.statusCode ?? 500;
    final data = response.data;
    final headers = response.headers;

    String? reqId = headers['X-Request-Id']?.firstOrNull;
    int? retrySec;
    final retryHeader = headers['Retry-After']?.firstOrNull;
    if (retryHeader != null) {
      retrySec = int.tryParse(retryHeader);
    }

    String message = '';
    int? errCode;
    final fieldErrorsMap = <String, List<String>>{};
    bool isTenantReq = false;

    if (data is Map<String, dynamic>) {
      message = (data['message'] ?? data['error'])?.toString() ?? '';
      final codeRaw = data['error_code'] ?? data['errorCode'];
      if (codeRaw is int) {
        errCode = codeRaw;
      } else if (codeRaw is String) {
        errCode = int.tryParse(codeRaw);
      }

      if (data['tenant_required'] == true || data['tenantRequired'] == true) {
        isTenantReq = true;
      }

      if (data['meta'] is Map<String, dynamic>) {
        final meta = data['meta'] as Map<String, dynamic>;
        reqId ??=
            meta['request_id']?.toString() ?? meta['requestId']?.toString();
      }

      final rawErrors = data['errors'];
      if (rawErrors is Map<String, dynamic>) {
        rawErrors.forEach((key, val) {
          if (val is List) {
            fieldErrorsMap[key] = val.map((e) => e.toString()).toList();
          } else if (val != null) {
            fieldErrorsMap[key] = [val.toString()];
          }
        });
      }

      final retryRaw = data['retry_after'] ?? data['retryAfter'];
      if (retryRaw is int) {
        retrySec ??= retryRaw;
      } else if (retryRaw is String) {
        retrySec ??= int.tryParse(retryRaw);
      }
    } else if (data is String) {
      if (!data.trim().startsWith('<')) {
        message = data.trim();
      }
    }

    if (tenantHeader != null &&
        message.toLowerCase().contains(tenantHeader.toLowerCase())) {
      isTenantReq = true;
    }
    if (message.toLowerCase().contains('tenant') &&
        (message.toLowerCase().contains('required') ||
            message.toLowerCase().contains('missing'))) {
      isTenantReq = true;
    }

    if (message.isEmpty) {
      if (status >= 500) {
        message = 'Server error (HTTP $status)';
      } else {
        message = 'Request failed with status $status';
      }
    }

    SpApiErrorCode code;
    if (isTenantReq) {
      code = SpApiErrorCode.tenantRequired;
    } else if (status == 401) {
      code = SpApiErrorCode.unauthenticated;
    } else if (status == 403) {
      code = SpApiErrorCode.forbidden;
    } else if (status == 404) {
      code = SpApiErrorCode.notFound;
    } else if (status == 422) {
      code = SpApiErrorCode.validation;
    } else if (status == 429) {
      code = SpApiErrorCode.rateLimited;
    } else if (status >= 500) {
      code = SpApiErrorCode.server;
    } else {
      code = SpApiErrorCode.unknown;
    }

    return SpApiError(
      status: status,
      code: code,
      message: message,
      errorCode: errCode,
      fieldErrors: fieldErrorsMap,
      requestId: reqId,
      retryAfter: retrySec,
      body: data,
      tenantRequired: isTenantReq,
    );
  }

  @override
  String toString() {
    final details = <String>[];
    details.add('status: $status');
    if (errorCode != null) details.add('error_code: $errorCode');
    if (requestId != null) details.add('request_id: $requestId');
    if (retryAfter != null) details.add('retry_after: $retryAfter');
    if (fieldErrors.isNotEmpty) details.add('field_errors: $fieldErrors');
    return 'SpApiError(${code.name}): $message [${details.join(', ')}]';
  }
}

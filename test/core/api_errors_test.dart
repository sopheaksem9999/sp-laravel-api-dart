import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  group('SpApiError', () {
    test('maps 401 to unauthenticated', () {
      final res = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/items'),
        statusCode: 401,
        data: {'message': 'Unauthenticated.'},
      );
      final error = SpApiError.fromResponse(res);
      expect(error.status, equals(401));
      expect(error.code, equals(SpApiErrorCode.unauthenticated));
      expect(error.message, equals('Unauthenticated.'));
    });

    test('maps 403 to forbidden', () {
      final res = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/items'),
        statusCode: 403,
        data: {'message': 'This action is unauthorized.'},
      );
      final error = SpApiError.fromResponse(res);
      expect(error.status, equals(403));
      expect(error.code, equals(SpApiErrorCode.forbidden));
      expect(error.message, equals('This action is unauthorized.'));
    });

    test('maps 404 to notFound', () {
      final res = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/items/99'),
        statusCode: 404,
        data: {'message': 'Resource not found.'},
      );
      final error = SpApiError.fromResponse(res);
      expect(error.status, equals(404));
      expect(error.code, equals(SpApiErrorCode.notFound));
    });

    test('maps 422 to validation and normalizes fieldErrors map', () {
      final res = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/items'),
        statusCode: 422,
        data: {
          'message': 'The given data was invalid.',
          'error_code': 10004,
          'errors': {
            'email': ['The email field is required.'],
            'name': 'The name field is required.',
          },
          'meta': {'request_id': 'req_xyz_123'},
        },
      );
      final error = SpApiError.fromResponse(res);
      expect(error.status, equals(422));
      expect(error.code, equals(SpApiErrorCode.validation));
      expect(error.errorCode, equals(10004));
      expect(error.requestId, equals('req_xyz_123'));
      expect(
        error.fieldErrors['email'],
        equals(['The email field is required.']),
      );
      // Single string normalised to List<String>
      expect(
        error.fieldErrors['name'],
        equals(['The name field is required.']),
      );
    });

    test('normalizes empty array errors: [] into empty map', () {
      final res = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/items'),
        statusCode: 422,
        data: {'message': 'Validation failed.', 'errors': <dynamic>[]},
      );
      final error = SpApiError.fromResponse(res);
      expect(error.fieldErrors, isEmpty);
      expect(error.fieldErrors, isA<Map<String, List<String>>>());
    });

    test(
      'maps 429 to rateLimited and parses retryAfter from header or body',
      () {
        final res = Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/v1/items'),
          statusCode: 429,
          headers: Headers.fromMap({
            'Retry-After': ['120'],
            'X-Request-Id': ['req_rate_429'],
          }),
          data: {'message': 'Too Many Attempts.'},
        );
        final error = SpApiError.fromResponse(res);
        expect(error.status, equals(429));
        expect(error.code, equals(SpApiErrorCode.rateLimited));
        expect(error.retryAfter, equals(120));
        expect(error.requestId, equals('req_rate_429'));
      },
    );

    test('normalizes HTML 502 Bad Gateway body with clean fallback message', () {
      final res = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/items'),
        statusCode: 502,
        data:
            '<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center><hr><center>cloudflare</center></body></html>',
      );
      final error = SpApiError.fromResponse(res);
      expect(error.status, equals(502));
      expect(error.code, equals(SpApiErrorCode.server));
      expect(error.message, equals('Server error (HTTP 502)'));
    });

    test('detects tenantRequired from message or tenantHeader', () {
      final res = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/items'),
        statusCode: 400,
        data: {
          'message': 'Tenant header X-Tenant-ID is required.',
          'tenant_required': true,
        },
      );
      final error = SpApiError.fromResponse(res, tenantHeader: 'X-Tenant-ID');
      expect(error.tenantRequired, isTrue);
      expect(error.code, equals(SpApiErrorCode.tenantRequired));
    });

    group('retry_after_seconds in errors (L3)', () {
      SpApiError build(
        dynamic errors, {
        Map<String, List<String>>? headers,
        Map<String, dynamic> extra = const {},
      }) {
        return SpApiError.fromResponse(
          Response<dynamic>(
            requestOptions: RequestOptions(path: '/api/v1/items'),
            statusCode: 429,
            headers: headers == null ? null : Headers.fromMap(headers),
            data: {'message': 'Too Many Attempts.', 'errors': errors, ...extra},
          ),
        );
      }

      test('reads first element of errors.retry_after_seconds', () {
        final error = build({
          'retry_after_seconds': [3193],
        });
        expect(error.retryAfter, equals(3193));
      });

      test('Retry-After header wins over body sources', () {
        final error = build(
          {
            'retry_after_seconds': [3193],
          },
          headers: {
            'Retry-After': ['30'],
          },
          extra: {'retry_after': 60},
        );
        expect(error.retryAfter, equals(30));
      });

      test('body retry_after wins over errors.retry_after_seconds', () {
        final error = build(
          {
            'retry_after_seconds': [3193],
          },
          extra: {'retry_after': 60},
        );
        expect(error.retryAfter, equals(60));
      });

      test('fieldErrors still contains retry_after_seconds', () {
        final error = build({
          'retry_after_seconds': [3193],
        });
        expect(error.fieldErrors['retry_after_seconds'], equals(['3193']));
      });

      test('parses numeric string element', () {
        final error = build({
          'retry_after_seconds': ['45'],
        });
        expect(error.retryAfter, equals(45));
      });

      test('bare int value is accepted', () {
        final error = build({'retry_after_seconds': 3193});
        expect(error.retryAfter, equals(3193));
      });

      test('empty list, non-numeric and zero/negative yield null', () {
        expect(build({'retry_after_seconds': <int>[]}).retryAfter, isNull);
        expect(
          build({
            'retry_after_seconds': ['abc'],
          }).retryAfter,
          isNull,
        );
        expect(
          build({
            'retry_after_seconds': [0],
          }).retryAfter,
          isNull,
        );
        expect(
          build({
            'retry_after_seconds': [-5],
          }).retryAfter,
          isNull,
        );
      });
    });
  });
}

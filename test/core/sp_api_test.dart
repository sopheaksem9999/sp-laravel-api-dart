import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  group('SpApi Core & ApiAuth Seam', () {
    test('sends base URL, tenant header, and auth headers', () async {
      final dio = Dio();
      RequestOptions? recordedOptions;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            recordedOptions = options;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': {'status': 'ok'},
                },
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1/'),
        tenant: TenantConfig(
          header: 'X-Tenant-ID',
          value: () => 'tenant_abc_123',
        ),
        auth: ApiAuth(
          headers: () async => {'Authorization': 'Bearer test_token'},
          handleUnauthorized: () async => false,
        ),
        dio: dio,
      );

      final res = await api.rpc<Map<String, dynamic>>('auth/whoami');
      expect(res['status'], equals('ok'));

      expect(recordedOptions, isNotNull);
      expect(
        recordedOptions!.uri.toString(),
        equals('https://example.com/api/v1/rpc/auth/whoami'),
      );
      expect(recordedOptions!.headers['X-Tenant-ID'], equals('tenant_abc_123'));
      expect(
        recordedOptions!.headers['Authorization'],
        equals('Bearer test_token'),
      );
      expect(recordedOptions!.headers['Accept'], equals('application/json'));
    });

    test(
      'retries once when 401 occurs and handleUnauthorized returns true',
      () async {
        final dio = Dio();
        int callCount = 0;
        int handleUnauthorizedCalls = 0;
        String currentToken = 'stale_token';

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              callCount++;
              if (callCount == 1) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 401,
                      data: {'message': 'Unauthenticated.'},
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'success': true,
                      'data': {'refreshed': true},
                    },
                  ),
                );
              }
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          auth: ApiAuth(
            headers: () async => {'Authorization': 'Bearer $currentToken'},
            handleUnauthorized: () async {
              handleUnauthorizedCalls++;
              currentToken = 'fresh_token';
              return true;
            },
          ),
          dio: dio,
        );

        final res = await api.rpc<Map<String, dynamic>>('ping');
        expect(res['refreshed'], isTrue);
        expect(callCount, equals(2));
        expect(handleUnauthorizedCalls, equals(1));
      },
    );

    test(
      'throws SpApiError without infinite loop if retry returns 401 again',
      () async {
        final dio = Dio();
        int callCount = 0;
        int handleUnauthorizedCalls = 0;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              callCount++;
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 401,
                    data: {'message': 'Unauthenticated still.'},
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          auth: ApiAuth(
            headers: () async => {'Authorization': 'Bearer token'},
            handleUnauthorized: () async {
              handleUnauthorizedCalls++;
              return true;
            },
          ),
          dio: dio,
        );

        await expectLater(
          api.rpc<Map<String, dynamic>>('ping'),
          throwsA(
            isA<SpApiError>().having(
              (e) => e.code,
              'code',
              SpApiErrorCode.unauthenticated,
            ),
          ),
        );

        expect(callCount, equals(2));
        expect(handleUnauthorizedCalls, equals(1));
      },
    );

    test('getBytes fetches raw binary data with auth headers', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: utf8.encode('PDF_BYTES_DATA'),
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        auth: ApiAuth(
          headers: () async => {'Authorization': 'Bearer valid_token'},
          handleUnauthorized: () async => false,
        ),
        dio: dio,
      );

      final bytes = await api.getBytes('sp_attachments/rpc/123/view');
      expect(utf8.decode(bytes), equals('PDF_BYTES_DATA'));
    });
  });

  group('SpApi.rpc query, method and options', () {
    SpApi build(void Function(RequestOptions) record, {dynamic data}) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            record(options);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data:
                    data ??
                    {
                      'success': true,
                      'data': {'progress': 50},
                    },
              ),
            );
          },
        ),
      );
      return SpApi(baseUrl: Uri.parse('https://example.com/api/v1'), dio: dio);
    }

    test('query is sent as GET query parameters', () async {
      RequestOptions? rec;
      final api = build((o) => rec = o);
      await api.rpc<Map<String, dynamic>>(
        'orders/checkProgress',
        query: {'order_id': 'o1'},
      );
      expect(rec!.method, equals('GET'));
      expect(
        rec!.uri.toString(),
        equals(
          'https://example.com/api/v1/rpc/orders/checkProgress?order_id=o1',
        ),
      );
    });

    test('method POST without body sends POST', () async {
      RequestOptions? rec;
      final api = build((o) => rec = o);
      await api.rpc<Map<String, dynamic>>(
        'orders/checkProgress',
        method: 'POST',
      );
      expect(rec!.method, equals('POST'));
    });

    test('options headers are merged into the request', () async {
      RequestOptions? rec;
      final api = build((o) => rec = o);
      await api.rpc<Map<String, dynamic>>(
        'orders/checkProgress',
        options: Options(headers: {'X-Custom': 'abc'}),
      );
      expect(rec!.headers['X-Custom'], equals('abc'));
    });

    test('existing body-only call still POSTs', () async {
      RequestOptions? rec;
      final api = build((o) => rec = o);
      await api.rpc<Map<String, dynamic>>('orders/create', body: {'a': 1});
      expect(rec!.method, equals('POST'));
      expect(rec!.data, equals({'a': 1}));
      expect(rec!.queryParameters, isEmpty);
    });

    test('data envelope is still unwrapped', () async {
      final api = build((_) {});
      final res = await api.rpc<Map<String, dynamic>>(
        'orders/checkProgress',
        query: {'order_id': 'o1'},
      );
      expect(res, equals({'progress': 50}));
    });
  });
}

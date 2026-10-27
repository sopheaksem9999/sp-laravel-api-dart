import 'dart:async';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  group('SpApi Retry Policy', () {
    test('is disabled by default (0 retries)', () async {
      final dio = Dio();
      int callCount = 0;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            callCount++;
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 503,
                  data: {'message': 'Service Unavailable'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );

      await expectLater(
        api.request('GET', 'health'),
        throwsA(
          isA<SpApiError>().having((e) => e.status, 'status', equals(503)),
        ),
      );
      expect(callCount, equals(1));
    });

    test(
      'retries idempotent GET up to maxAttempts on 503 and succeeds',
      () async {
        final dio = Dio();
        int callCount = 0;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              callCount++;
              if (callCount < 3) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 503,
                      data: {'message': 'Service Unavailable'},
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'status': 'ok'},
                  ),
                );
              }
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          retry: const RetryConfig(
            maxAttempts: 2,
            initialBackoff: Duration(milliseconds: 10),
            jitter: false,
          ),
          dio: dio,
        );

        final res = await api.request('GET', 'health');
        expect(res.statusCode, equals(200));
        expect(callCount, equals(3)); // 1 initial + 2 retries
      },
    );

    test('stops retrying when maxAttempts exhausted', () async {
      final dio = Dio();
      int callCount = 0;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            callCount++;
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 502,
                  data: {'message': 'Bad Gateway'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        retry: const RetryConfig(
          maxAttempts: 2,
          initialBackoff: Duration(milliseconds: 10),
          jitter: false,
        ),
        dio: dio,
      );

      await expectLater(
        api.request('GET', 'health'),
        throwsA(
          isA<SpApiError>().having((e) => e.status, 'status', equals(502)),
        ),
      );
      expect(callCount, equals(3)); // 1 initial + 2 retries
    });

    test('does not retry non-idempotent POST by default', () async {
      final dio = Dio();
      int callCount = 0;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            callCount++;
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 503,
                  data: {'message': 'Service Unavailable'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        retry: const RetryConfig(
          maxAttempts: 3,
          initialBackoff: Duration(milliseconds: 10),
          jitter: false,
        ),
        dio: dio,
      );

      await expectLater(
        api.request('POST', 'orders', data: {'item': 'widget'}),
        throwsA(
          isA<SpApiError>().having((e) => e.status, 'status', equals(503)),
        ),
      );
      expect(callCount, equals(1));
    });

    test(
      'retries non-idempotent POST when explicitly opted in via retry: true',
      () async {
        final dio = Dio();
        int callCount = 0;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              callCount++;
              if (callCount < 2) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 503,
                      data: {'message': 'Service Unavailable'},
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'id': 123},
                  ),
                );
              }
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          retry: const RetryConfig(
            maxAttempts: 2,
            initialBackoff: Duration(milliseconds: 10),
            jitter: false,
          ),
          dio: dio,
        );

        final res = await api.request(
          'POST',
          'orders',
          data: {'item': 'widget'},
          retry: true,
        );
        expect(res.statusCode, equals(200));
        expect(callCount, equals(2));
      },
    );

    test('retries network/connection errors when enabled', () async {
      final dio = Dio();
      int callCount = 0;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            callCount++;
            if (callCount < 2) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  message: 'Connection reset by peer',
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'connected': true},
                ),
              );
            }
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        retry: const RetryConfig(
          maxAttempts: 2,
          initialBackoff: Duration(milliseconds: 10),
          jitter: false,
        ),
        dio: dio,
      );

      final res = await api.request('GET', 'ping');
      expect(res.statusCode, equals(200));
      expect(callCount, equals(2));
    });

    test('aborts backoff immediately when cancelToken is cancelled', () async {
      final dio = Dio();
      final cancelToken = CancelToken();

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 503,
                  data: {'message': 'Service Unavailable'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        retry: const RetryConfig(
          maxAttempts: 5,
          initialBackoff: Duration(seconds: 30),
          jitter: false,
        ),
        dio: dio,
      );

      final stopwatch = Stopwatch()..start();

      // Trigger cancel after 50ms while sleeping
      Timer(const Duration(milliseconds: 50), () {
        cancelToken.cancel('user cancelled retry wait');
      });

      try {
        await api.request('GET', 'health', cancelToken: cancelToken);
        fail('Should have thrown cancel exception');
      } on DioException catch (e) {
        expect(e.type, equals(DioExceptionType.cancel));
      }

      stopwatch.stop();
      // Verifies it did NOT wait the full 30 seconds
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });
  });
}

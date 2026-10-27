import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

SpApi _apiRejecting(DioException Function(RequestOptions) build) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(build(options)),
    ),
  );
  return SpApi(baseUrl: Uri.parse('https://example.com/api/v1/'), dio: dio);
}

void main() {
  group('SpApiError transport cause', () {
    test('connection timeout keeps the DioException as cause', () async {
      late DioException original;
      final api = _apiRejecting((o) {
        return original = DioException(
          requestOptions: o,
          type: DioExceptionType.connectionTimeout,
          message: 'timed out',
          stackTrace: StackTrace.current,
        );
      });
      try {
        await api.rpc<Map<String, dynamic>>('ping');
        fail('expected SpApiError');
      } on SpApiError catch (e) {
        expect(e.status, 0);
        expect(e.code, SpApiErrorCode.timeout);
        expect(e.cause, same(original));
        expect(e.stackTrace, same(original.stackTrace));
        expect(e.isTransport, isTrue);
        expect(e.isHttp, isFalse);
      }
    });

    test('connection error maps to network with cause set', () async {
      final api = _apiRejecting(
        (o) => DioException(
          requestOptions: o,
          type: DioExceptionType.connectionError,
          message: 'unreachable',
        ),
      );
      try {
        await api.rpc<Map<String, dynamic>>('ping');
        fail('expected SpApiError');
      } on SpApiError catch (e) {
        expect(e.code, SpApiErrorCode.network);
        expect(e.cause, isA<DioException>());
        expect(e.isTransport, isTrue);
      }
    });

    test('HTTP 500 has no cause and is http', () async {
      final api = _apiRejecting(
        (o) => DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: o,
            statusCode: 500,
            data: {'message': 'boom'},
          ),
        ),
      );
      try {
        await api.rpc<Map<String, dynamic>>('ping');
        fail('expected SpApiError');
      } on SpApiError catch (e) {
        expect(e.status, 500);
        expect(e.cause, isNull);
        expect(e.stackTrace, isNull);
        expect(e.isHttp, isTrue);
        expect(e.isTransport, isFalse);
      }
    });

    test('toString excludes headers, body and cause', () async {
      final api = _apiRejecting(
        (o) => DioException(
          requestOptions: o..headers['Authorization'] = 'Bearer secret',
          type: DioExceptionType.connectionError,
          message: 'unreachable',
        ),
      );
      try {
        await api.rpc<Map<String, dynamic>>('ping');
        fail('expected SpApiError');
      } on SpApiError catch (e) {
        final s = e.toString();
        expect(s, isNot(contains('secret')));
        expect(s, isNot(contains('Authorization')));
        expect(s, isNot(contains('DioException')));
      }
    });

    test('local errors with status 0 are not transport failures', () {
      const e = SpApiError(
        status: 0,
        code: SpApiErrorCode.unencodableValue,
        message: 'select is required',
      );
      expect(e.isTransport, isFalse);
      expect(e.isHttp, isFalse);
      const unknown = SpApiError(
        status: 0,
        code: SpApiErrorCode.unknown,
        message: 'unexpected response shape',
      );
      expect(unknown.isTransport, isFalse);
    });
  });
}

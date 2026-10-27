import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

/// Adapter that really drains the request body stream, so Dio's FormData
/// finalize() runs (an interceptor with handler.resolve would skip it).
class _DrainingAdapter implements HttpClientAdapter {
  final List<ResponseBody Function()> script;
  int calls = 0;
  _DrainingAdapter(this.script);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final step = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return step();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

FormData _form() => FormData.fromMap({
  'file': MultipartFile.fromBytes([1, 2, 3], filename: 'a.txt'),
});

SpApi _api(_DrainingAdapter a, {ApiAuth? auth, RetryConfig? retry}) {
  final dio = Dio()..httpClientAdapter = a;
  return SpApi(
    baseUrl: Uri.parse('https://example.com/api/v1'),
    auth: auth,
    retry: retry,
    dio: dio,
  );
}

ApiAuth _auth() =>
    ApiAuth(headers: () async => {}, handleUnauthorized: () async => true);

void main() {
  group('FormData retry', () {
    test('401 then 200 re-sends a fresh form', () async {
      final a = _DrainingAdapter([
        () => _json(401, {'message': 'expired'}),
        () => _json(200, {
          'success': true,
          'data': {'id': 1},
        }),
      ]);
      final res = await _api(
        a,
        auth: _auth(),
      ).request('POST', 'attachments', data: _form());
      expect(a.calls, 2);
      expect((res.data as Map)['data'], {'id': 1});
    });

    test('envelope 10002 then 200 re-sends a fresh form', () async {
      final a = _DrainingAdapter([
        () => _json(200, {
          'success': false,
          'error_code': 10002,
          'message': 'expired',
        }),
        () => _json(200, {
          'success': true,
          'data': {'id': 2},
        }),
      ]);
      final res = await _api(
        a,
        auth: _auth(),
      ).request('POST', 'attachments', data: _form());
      expect(a.calls, 2);
      expect((res.data as Map)['data'], {'id': 2});
    });

    test('RetryConfig retry on 503 then 200 re-sends a fresh form', () async {
      final a = _DrainingAdapter([
        () => _json(503, {'message': 'down'}),
        () => _json(200, {
          'success': true,
          'data': {'id': 3},
        }),
      ]);
      final res = await _api(
        a,
        retry: const RetryConfig(
          maxAttempts: 2,
          initialBackoff: Duration(milliseconds: 1),
          jitter: false,
        ),
      ).request('POST', 'attachments', data: _form(), retry: true);
      expect(a.calls, 2);
      expect((res.data as Map)['data'], {'id': 3});
    });
  });
}

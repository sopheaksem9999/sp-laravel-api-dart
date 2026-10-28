import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

import '../support/until.dart';

typedef _Step = void Function(RequestOptions o, RequestInterceptorHandler h);

_Step _ok(
  dynamic data, {
  int status = 200,
  Map<String, List<String>>? headers,
}) =>
    (o, h) => h.resolve(
      Response(
        requestOptions: o,
        statusCode: status,
        data: data,
        headers: Headers.fromMap(headers ?? {}),
      ),
    );

_Step _fail(int status, dynamic data, {Map<String, List<String>>? headers}) =>
    (o, h) => h.reject(
      DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: o,
          statusCode: status,
          data: data,
          headers: Headers.fromMap(headers ?? {}),
        ),
      ),
    );

class _Harness {
  final List<_Step> script;
  final List<RequestOptions> seen = [];
  final List<SpLogEntry> entries = [];
  late final Dio dio;

  _Harness(this.script) {
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          seen.add(o);
          script[seen.length <= script.length
              ? seen.length - 1
              : script.length - 1](o, h);
        },
      ),
    );
  }

  SpApi api({
    SpLogMode? mode,
    bool withLogger = true,
    void Function(SpLogEntry)? sink,
    ApiAuth? auth,
    RetryConfig? retry,
    TenantConfig? tenant,
    int maxBodyLength = 2048,
  }) => SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    dio: dio,
    auth: auth,
    retry: retry,
    tenant: tenant,
    logger: withLogger
        ? SpLogger(
            sink: sink ?? entries.add,
            mode: mode ?? SpLogMode.perRequest,
            maxBodyLength: maxBodyLength,
          )
        : null,
  );
}

const _noWait = RetryConfig(
  maxAttempts: 2,
  initialBackoff: Duration.zero,
  jitter: false,
);

void main() {
  group('request logging', () {
    test('no logger configured produces no entry', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      final api = h.api(withLogger: false);
      final res = await api.request('GET', 'invoices', options: SpLog.on());
      expect(res.data, {'ok': true});
      expect(h.entries, isEmpty);
    });

    test('perRequest mode logs only opted-in requests', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      final api = h.api();
      await api.request('GET', 'invoices');
      expect(h.entries, isEmpty);
      await api.request(
        'GET',
        'invoices',
        queryParameters: {'per_page': 25},
        options: SpLog.on(),
      );
      expect(h.entries, hasLength(1));
      final e = h.entries.single;
      expect(e.method, 'GET');
      expect(e.url, 'https://api.example.com/api/v1/invoices?per_page=25');
      expect(e.status, 200);
      expect(e.attempt, 1);
      expect(e.code, isNull);
      expect(e.requestHeaders, isNull);
      expect(e.responseHeaders, isNull);
      expect(e.requestBody, isNull);
      expect(e.responseBody, isNull);
      expect(
        e.toString(),
        matches(
          r'^GET https://api\.example\.com/api/v1/invoices\?per_page=25 -> 200 \d+ms attempt=1$',
        ),
      );
    });

    test('all mode logs every request', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      final api = h.api(mode: SpLogMode.all);
      await api.request('GET', 'invoices');
      await api.request('POST', 'orders', data: {'a': 1});
      expect(h.entries.map((e) => e.method), ['GET', 'POST']);
      expect(h.entries.every((e) => e.requestBody == null), isTrue);
    });

    test('off mode logs nothing even when a request opts in', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      final api = h.api(mode: SpLogMode.off);
      await api.request('GET', 'invoices', options: SpLog.on(bodies: true));
      expect(h.entries, isEmpty);
    });

    group('each attempt is logged with an increasing attempt number', () {
      test('401 refresh then 200', () async {
        final h = _Harness([
          _fail(401, {'message': 'expired'}),
          _ok({'ok': 1}),
        ]);
        final api = h.api(
          mode: SpLogMode.all,
          auth: ApiAuth(
            headers: () async => {},
            handleUnauthorized: () async => true,
          ),
        );
        await api.request('GET', 'invoices');
        expect(h.entries.map((e) => e.attempt), [1, 2]);
        expect(h.entries.map((e) => e.status), [401, 200]);
        expect(h.entries.first.code, SpApiErrorCode.unauthenticated);
        expect(h.entries.last.code, isNull);
      });

      test('200 success:false 10002 then 200', () async {
        final h = _Harness([
          _ok({'success': false, 'error_code': 10002, 'message': 'expired'}),
          _ok({'success': true}),
        ]);
        final api = h.api(
          mode: SpLogMode.all,
          auth: ApiAuth(
            headers: () async => {},
            handleUnauthorized: () async => true,
          ),
        );
        await api.request('GET', 'invoices');
        expect(h.entries.map((e) => e.attempt), [1, 2]);
        expect(h.entries.first.status, 200);
        expect(h.entries.first.errorCode, 10002);
        expect(h.entries.first.code, SpApiErrorCode.unauthenticated);
        expect(h.entries.last.errorCode, isNull);
      });

      test('RetryConfig 503 then 200', () async {
        final h = _Harness([
          _fail(503, {'message': 'down'}),
          _ok({'ok': 1}),
        ]);
        final api = h.api(mode: SpLogMode.all, retry: _noWait);
        await api.request('GET', 'invoices');
        expect(h.entries.map((e) => e.attempt), [1, 2]);
        expect(h.entries.map((e) => e.status), [503, 200]);
        expect(h.entries.first.code, SpApiErrorCode.server);
      });

      test(
        'a 503 returned as a response (not rejected) is logged too',
        () async {
          final h = _Harness([
            _ok({'message': 'down'}, status: 503),
            _ok({'ok': 1}),
          ]);
          final api = h.api(mode: SpLogMode.all, retry: _noWait);
          // validateStatus is bypassed by the interceptor resolve, so this goes
          // through the `>= 400` branch of the attempt loop.
          await api.request('GET', 'invoices');
          expect(h.entries.map((e) => e.attempt), [1, 2]);
          expect(h.entries.first.status, 503);
        },
      );
    });

    test('error entry carries code, errorCode and requestId', () async {
      final h = _Harness([
        _fail(
          422,
          {
            'message': 'The password is secret-pass-123',
            'error_code': 10004,
            'errors': {
              'email': ['bad'],
            },
          },
          headers: {
            'x-request-id': ['rid-42'],
          },
        ),
      ]);
      final api = h.api(mode: SpLogMode.all);
      await expectLater(
        api.request('POST', 'orders', data: {'a': 1}),
        throwsA(isA<SpApiError>()),
      );
      final e = h.entries.single;
      expect(e.status, 422);
      expect(e.code, SpApiErrorCode.validation);
      expect(e.errorCode, 10004);
      expect(e.requestId, 'rid-42');
      expect(e.toString(), contains('rid=rid-42'));
      expect(e.toString(), contains('code=validation'));
      expect(e.toString(), contains('errorCode=10004'));
      expect(e.toString(), isNot(contains('secret-pass')));
      expect(e.responseBody, isNull);
    });

    test('request id from meta.request_id on a successful response', () async {
      final h = _Harness([
        _ok({
          'data': 1,
          'meta': {'request_id': 'meta-7'},
        }),
      ]);
      await h.api(mode: SpLogMode.all).request('GET', 'invoices');
      expect(h.entries.single.requestId, 'meta-7');
    });

    test('sensitive headers are redacted', () async {
      final h = _Harness([
        _ok(
          {'ok': true},
          headers: {
            'set-cookie': ['session=abc; HttpOnly'],
            'x-csrf-token': ['csrf-1'],
            'content-type': ['application/json'],
          },
        ),
      ]);
      final api = h.api(
        auth: ApiAuth(
          headers: () async => {
            'Authorization': 'Bearer abc.def.ghi',
            'Cookie': 'session=zzz',
          },
          handleUnauthorized: () async => false,
        ),
        tenant: TenantConfig(header: 'X-Company-ID', value: () => '5'),
      );
      await api.request(
        'GET',
        'invoices',
        options: SpLog.merge(
          Options(headers: {'X-CSRF-Token': 'csrf-2', 'X-Trace': 'ok'}),
          headers: true,
        ),
      );
      final e = h.entries.single;
      final req = e.requestHeaders!;
      expect(req['Authorization'], '<redacted>');
      expect(req['Cookie'], '<redacted>');
      expect(req['X-CSRF-Token'], '<redacted>');
      expect(req['X-Company-ID'], '<redacted>');
      expect(req['X-Trace'], 'ok');
      expect(req['Accept'], 'application/json');
      final res = e.responseHeaders!;
      expect(res['set-cookie'], '<redacted>');
      expect(res['x-csrf-token'], '<redacted>');
      expect(res['content-type'], 'application/json');
      final flat = '${e.requestHeaders}${e.responseHeaders}';
      for (final secret in [
        'abc.def.ghi',
        'zzz',
        'csrf-1',
        'csrf-2',
        'session=abc',
      ]) {
        expect(flat, isNot(contains(secret)));
      }
    });

    test('a secret in the query string never reaches the entry url', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      await h
          .api(mode: SpLogMode.all)
          .request(
            'GET',
            'invoices',
            queryParameters: {
              'token': 'tok-secret',
              'page': 2,
              'user[password]': 'pw-1',
            },
          );
      final url = h.entries.single.url;
      expect(url, isNot(contains('tok-secret')));
      expect(url, isNot(contains('pw-1')));
      expect(url, contains('page=2'));
      expect(url, contains('<redacted>'));
    });

    test('bodies are logged redacted when asked for', () async {
      final h = _Harness([
        _ok({
          'user': {'name': 'Acme', 'access_token': 'resp-secret'},
        }),
      ]);
      await h.api().request(
        'POST',
        'orders',
        data: {'email': 'a@example.com', 'password': 'req-secret'},
        options: SpLog.on(bodies: true),
      );
      final e = h.entries.single;
      expect(e.requestBody, {
        'email': 'a@example.com',
        'password': '<redacted>',
      });
      expect(e.responseBody, {
        'user': {'name': 'Acme', 'access_token': '<redacted>'},
      });
    });

    test('bodies are truncated and binary bodies are not printed', () async {
      final h = _Harness([_ok('x' * 5000)]);
      final api = h.api();
      await api.request(
        'POST',
        'orders',
        data: 'y' * 3000,
        options: SpLog.on(bodies: true),
      );
      final e = h.entries.single;
      expect(e.requestBody, 'y' * 2048 + '…[truncated]');
      expect(e.responseBody, 'x' * 2048 + '…[truncated]');

      final h2 = _Harness([_ok('z' * 100)]);
      await h2
          .api(maxBodyLength: 10)
          .request(
            'POST',
            'orders',
            data: 'q' * 50,
            options: SpLog.on(bodies: true),
          );
      expect(h2.entries.single.requestBody, 'q' * 10 + '…[truncated]');

      final bin = _Harness([
        _ok(Uint8List.fromList([1, 2, 3, 4])),
      ]);
      await bin.api().request(
        'POST',
        'orders',
        data: Uint8List.fromList(List.filled(7, 9)),
        options: SpLog.on(bodies: true),
      );
      expect(bin.entries.single.requestBody, '<7 bytes>');
      expect(bin.entries.single.responseBody, '<4 bytes>');

      final form = _Harness([
        _ok({'ok': 1}),
      ]);
      await form.api().request(
        'POST',
        'attachments',
        data: FormData.fromMap({'file': 'secret-file-content'}),
        options: SpLog.on(bodies: true),
      );
      expect(form.entries.single.requestBody, '<multipart>');

      final stream = _Harness([
        _ok({'ok': 1}),
      ]);
      await stream.api().request(
        'POST',
        'orders',
        data: Stream<List<int>>.fromIterable([
          [1, 2],
        ]),
        options: SpLog.on(bodies: true),
      );
      expect(stream.entries.single.requestBody, '<stream>');
    });

    test('getBytes content is never logged as text', () async {
      final h = _Harness([
        _ok(Uint8List.fromList([1, 2, 3])),
      ]);
      await h.api(mode: SpLogMode.all).getBytes('files/1');
      final e = h.entries.single;
      expect(e.responseBody, isNull);
      expect(e.status, 200);
    });

    test('a throwing sink does not change the request result', () async {
      final ok = _Harness([
        _ok({'ok': true}),
      ]);
      var calls = 0;
      final api = ok.api(
        mode: SpLogMode.all,
        sink: (_) {
          calls++;
          throw StateError('sink broke');
        },
      );
      final res = await api.request('GET', 'invoices');
      expect(res.data, {'ok': true});
      expect(calls, 1);

      final bad = _Harness([
        _fail(404, {'message': 'nope'}),
      ]);
      await expectLater(
        bad
            .api(mode: SpLogMode.all, sink: (_) => throw StateError('x'))
            .request('GET', 'a'),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.notFound,
          ),
        ),
      );
    });

    test('a failing async sink does not produce an uncaught error', () async {
      final uncaught = <Object>[];
      var sinkRan = false;
      Object? result;
      await runZonedGuarded(() async {
        final h = _Harness([
          _ok({'ok': true}),
        ]);
        final api = h.api(
          mode: SpLogMode.all,
          sink: (_) async {
            sinkRan = true;
            throw StateError('async sink broke');
          },
        );
        result = (await api.request('GET', 'invoices')).data;
      }, (e, s) => uncaught.add(e));
      await until(() => sinkRan && result != null);
      // Let any pending microtasks (the swallowed rejection) settle.
      await Future<void>.delayed(Duration.zero);
      expect(result, {'ok': true});
      expect(uncaught, isEmpty);
    });

    test('the per-request marker is not sent as a header or query', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      await h.api().request(
        'GET',
        'invoices',
        options: SpLog.on(headers: true, bodies: true),
      );
      final o = h.seen.single;
      expect(
        o.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('sp.log')),
      );
      expect(o.headers.values.join(), isNot(contains('bodies')));
      expect(o.uri.toString(), isNot(contains('sp.log')));
      expect(o.queryParameters, isEmpty);
    });

    test('SpLog.on composes with other per-request options', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      final base = Options(headers: {'X-Trace': 'abc'}, extra: {'mine': 1});
      await h.api().request(
        'GET',
        'invoices',
        options: SpLog.merge(base, headers: true),
      );
      final o = h.seen.single;
      expect(o.headers['X-Trace'], 'abc');
      expect(o.extra['mine'], 1);
      expect(h.entries.single.requestHeaders!['X-Trace'], 'abc');

      final viaCopy = base.copyWith(
        extra: {...?base.extra, ...SpLog.on().extra!},
      );
      await h.api().request('GET', 'invoices', options: viaCopy);
      expect(h.entries, hasLength(2));
      expect(h.seen.last.headers['X-Trace'], 'abc');
    });

    test(
      'SpLog.off disables logging for one request, even in all mode',
      () async {
        final h = _Harness([
          _ok({'ok': true}),
        ]);
        final all = h.api(mode: SpLogMode.all);
        final res = await all.request('GET', 'invoices', options: SpLog.off());
        expect(res.data, {'ok': true});
        expect(h.entries, isEmpty);
        await all.request('GET', 'invoices');
        expect(h.entries, hasLength(1));

        await h.api().request('GET', 'invoices', options: SpLog.off());
        expect(h.entries, hasLength(1));
        expect(h.seen, hasLength(3));
        expect(
          h.seen.first.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('sp.log')),
        );
      },
    );

    test('SpLog.off composes with other per-request options', () async {
      final h = _Harness([
        _ok({'ok': true}),
      ]);
      final api = h.api(mode: SpLogMode.all);
      final base = Options(headers: {'X-Trace': 'abc'}, extra: {'mine': 1});
      final merged = SpLog.merge(base, off: true);
      await api.request('GET', 'invoices', options: merged);
      expect(h.seen.single.headers['X-Trace'], 'abc');
      expect(h.seen.single.extra['mine'], 1);
      expect(h.entries, isEmpty);

      // an off marker replaces an earlier on marker, and the copyWith form works too
      await api.request(
        'GET',
        'invoices',
        options: SpLog.merge(SpLog.on(bodies: true), off: true),
      );
      await api.request(
        'GET',
        'invoices',
        options: base.copyWith(extra: {...?base.extra, ...SpLog.off().extra!}),
      );
      expect(h.seen, hasLength(3));
      expect(h.entries, isEmpty);
      expect(base.extra, {'mine': 1});
    });

    test('works through TableGateway options', () async {
      final h = _Harness([
        _ok(<String, dynamic>{'data': <Object>[], 'meta': <String, dynamic>{}}),
      ]);
      final t = h.api().table<Map<String, dynamic>>(
        'invoices',
        fromJson: (j) => j,
      );
      await t.list(select: 'id', options: SpLog.on());
      expect(h.entries, hasLength(1));
      expect(h.entries.single.url, contains('/invoices'));
    });

    test('a cancelled request still produces an entry', () async {
      final token = CancelToken();
      final h = _Harness([
        (o, handler) {
          token.cancel('stop');
          handler.reject(
            DioException.requestCancelled(requestOptions: o, reason: 'stop'),
          );
        },
      ]);
      await expectLater(
        h
            .api(mode: SpLogMode.all)
            .request('GET', 'invoices', cancelToken: token),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      final e = h.entries.single;
      expect(e.status, isNull);
      expect(e.code, SpApiErrorCode.network);
      expect(e.attempt, 1);
    });

    test('a transport timeout is logged with the timeout code', () async {
      final h = _Harness([
        (o, handler) => handler.reject(
          DioException(
            requestOptions: o,
            type: DioExceptionType.connectionTimeout,
            message: 'secret-host-detail',
          ),
        ),
      ]);
      await expectLater(
        h.api(mode: SpLogMode.all).request('GET', 'invoices'),
        throwsA(isA<SpApiError>()),
      );
      final e = h.entries.single;
      expect(e.status, isNull);
      expect(e.code, SpApiErrorCode.timeout);
      expect(e.toString(), isNot(contains('secret-host-detail')));
    });

    test('the request id is sanitised', () async {
      Future<String?> rid(String raw) async {
        final h = _Harness([
          _ok(
            {'ok': 1},
            headers: {
              'x-request-id': [raw],
            },
          ),
        ]);
        await h.api(mode: SpLogMode.all).request('GET', 'a');
        return h.entries.single.requestId;
      }

      expect(await rid('abc\nFORGED line'), 'abcFORGED line');
      expect(await rid('a\u001b[31mred'), 'a[31mred');
      expect(await rid('a b c'), 'abc');
      expect(await rid('a\u0085b\u009fc\u007fd'), 'abcd');
      expect((await rid('r' * 10000))!.length, 128);
      expect(await rid('\n\r\u001b'), isNull);
      // 127 ASCII + one astral character at the cap: kept whole, no split.
      final atCap = '${'a' * 127}\u{1F600}';
      expect(await rid('${atCap}zzz'), atCap);
      final out = (await rid('${'a' * 127}\u{1F600}'))!;
      expect(out.runes.length, 128);
      expect(out.codeUnits.last, 0xde00);
    });
  });
}

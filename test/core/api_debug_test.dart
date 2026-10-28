import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

typedef _Step = void Function(RequestOptions o, RequestInterceptorHandler h);

_Step _ok(dynamic data, {int status = 200}) =>
    (o, h) =>
        h.resolve(Response(requestOptions: o, statusCode: status, data: data));

_Step _fail(int status, dynamic data) =>
    (o, h) => h.reject(
      DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: o, statusCode: status, data: data),
      ),
    );

class _Harness {
  final List<RequestOptions> seen = [];
  final List<SpLogEntry> entries = [];
  late final Dio dio;

  /// Answers with [script] in order (the last step repeats); by default every
  /// request gets a 200 success envelope.
  _Harness([List<_Step>? script]) {
    final steps =
        script ??
        [
          _ok({'success': true, 'data': <String, dynamic>{}}),
        ];
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          seen.add(o);
          steps[seen.length <= steps.length
              ? seen.length - 1
              : steps.length - 1](o, h);
        },
      ),
    );
  }

  SpApi api({
    bool? debug,
    bool logger = false,
    ApiAuth? auth,
    RetryConfig? retry,
  }) => SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    dio: dio,
    debug: debug ?? false,
    auth: auth,
    retry: retry,
    logger: logger ? SpLogger(sink: entries.add) : null,
  );
}

TableGateway<Map<String, dynamic>> _table(SpApi api) =>
    api.table<Map<String, dynamic>>('invoices', fromJson: (j) => j);

void main() {
  group('X-Debug', () {
    test('SpApi(debug: true) sends X-Debug: 1 on every request', () async {
      final h = _Harness();
      final api = h.api(debug: true);
      await _table(api).list(select: 'id');
      await api.rpc<dynamic>('ping');
      expect(h.seen, hasLength(2));
      for (final o in h.seen) {
        expect(o.headers['X-Debug'], '1');
      }
    });

    test('SpDebug.on() sends it for one request only', () async {
      final h = _Harness();
      final api = h.api();
      final t = _table(api);
      await t.list(select: 'id', options: SpDebug.on());
      await t.create({'a': 1}, options: SpDebug.on());
      await api.rpc<dynamic>('ping', options: SpDebug.on());
      await t.list(select: 'id');
      await api.rpc<dynamic>('ping');
      expect(h.seen, hasLength(5));
      for (final o in h.seen.take(3)) {
        expect(o.headers['X-Debug'], '1');
      }
      for (final o in h.seen.skip(3)) {
        expect(o.headers.containsKey('X-Debug'), isFalse);
      }
    });

    test('the default sends no X-Debug header', () async {
      final h = _Harness();
      final api = h.api();
      await _table(api).list(select: 'id');
      await api.rpc<dynamic>('ping');
      for (final o in h.seen) {
        expect(
          o.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-debug')),
        );
      }
    });

    test('an explicit per-request X-Debug header wins', () async {
      final h = _Harness();
      final api = h.api(debug: true);
      await _table(api).list(
        select: 'id',
        options: Options(headers: {'X-Debug': '0'}),
      );
      expect(h.seen.single.headers['X-Debug'], '0');
    });

    test('SpDebug.merge keeps other options', () {
      final o = SpDebug.merge(
        Options(headers: {'X-Other': 'a'}, extra: {'k': 1}),
      );
      expect(o.headers, {'X-Other': 'a', 'X-Debug': '1'});
      expect(o.extra, {'k': 1});
      expect(SpDebug.merge(null).headers, {'X-Debug': '1'});
    });

    group('a retried attempt still sends X-Debug', () {
      final refresh = ApiAuth(
        headers: () async => {},
        handleUnauthorized: () async => true,
      );
      const noWait = RetryConfig(
        maxAttempts: 2,
        initialBackoff: Duration.zero,
        jitter: false,
      );
      final scenarios = <String, (List<_Step>, ApiAuth?, RetryConfig?)>{
        '401 refresh': (
          [
            _fail(401, {'message': 'expired'}),
            _ok({'success': true, 'data': 1}),
          ],
          refresh,
          null,
        ),
        '200 success:false 10002 envelope': (
          [
            _ok({'success': false, 'error_code': 10002, 'message': 'expired'}),
            _ok({'success': true, 'data': 1}),
          ],
          refresh,
          null,
        ),
        'RetryConfig 503': (
          [
            _fail(503, {'message': 'down'}),
            _ok({'success': true, 'data': 1}),
          ],
          null,
          noWait,
        ),
      };
      for (final s in scenarios.entries) {
        test('${s.key} with SpApi(debug: true)', () async {
          final h = _Harness(s.value.$1);
          final api = h.api(debug: true, auth: s.value.$2, retry: s.value.$3);
          await api.request('GET', 'invoices');
          expect(h.seen, hasLength(2));
          for (final o in h.seen) {
            expect(o.headers['X-Debug'], '1');
          }
        });

        test('${s.key} with SpDebug.on()', () async {
          final h = _Harness(s.value.$1);
          final api = h.api(auth: s.value.$2, retry: s.value.$3);
          await api.request('GET', 'invoices', options: SpDebug.on());
          expect(h.seen, hasLength(2));
          for (final o in h.seen) {
            expect(o.headers['X-Debug'], '1');
          }
        });
      }
    });

    test('SpDebug.on() composes with SpLog.on()', () async {
      final h = _Harness();
      final api = h.api(logger: true);
      final both = SpDebug.merge(SpLog.on(headers: true));
      await _table(api).list(select: 'id', options: both);
      final both2 = SpLog.merge(SpDebug.on(), headers: true);
      await _table(api).list(select: 'id', options: both2);
      expect(h.seen, hasLength(2));
      expect(h.entries, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(h.seen[i].headers['X-Debug'], '1');
        expect(h.entries[i].requestHeaders!['X-Debug'], '1');
      }
    });
  });
}

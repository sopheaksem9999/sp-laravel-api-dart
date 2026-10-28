import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

class _Harness {
  final List<RequestOptions> seen = [];
  final List<SpLogEntry> entries = [];
  late final Dio dio;

  _Harness() {
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          seen.add(o);
          h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: {'success': true, 'data': <String, dynamic>{}},
            ),
          );
        },
      ),
    );
  }

  SpApi api({bool? debug, bool logger = false}) => SpApi(
    baseUrl: Uri.parse('https://api.example.com/api/v1'),
    dio: dio,
    debug: debug ?? false,
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

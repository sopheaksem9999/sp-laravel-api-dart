import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

class Item {
  final int id;
  Item(this.id);
  factory Item.fromJson(Map<String, dynamic> json) => Item(json['id'] as int);
}

TableGateway<Item> _gateway(
  List<RequestOptions> seen, {
  ApiAuth? auth,
  dynamic listBody,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        seen.add(options);
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: options.method == 'GET' && options.path.endsWith('/items')
                ? (listBody ??
                      {'data': <dynamic>[], 'meta': <String, dynamic>{}})
                : {
                    'success': true,
                    'data': {'id': 1},
                  },
          ),
        );
      },
    ),
  );
  final api = SpApi(
    baseUrl: Uri.parse('https://example.com/api/v1'),
    auth: auth,
    dio: dio,
  );
  return api.table('items', fromJson: Item.fromJson);
}

ApiAuth _auth() => ApiAuth(
  headers: () async => {'Authorization': 'Bearer test_token'},
  handleUnauthorized: () async => false,
);

void main() {
  group('TableGateway per-request options', () {
    test('create sends per-request headers', () async {
      final seen = <RequestOptions>[];
      final items = _gateway(seen);
      await items.create({
        'a': 1,
      }, options: Options(headers: {'X-Capabilities': 'waiting'}));
      expect(seen.single.headers['X-Capabilities'], equals('waiting'));
    });

    test('Authorization from ApiAuth is kept unless caller sets it', () async {
      final seen = <RequestOptions>[];
      final items = _gateway(seen, auth: _auth());
      await items.create({
        'a': 1,
      }, options: Options(headers: {'X-Capabilities': 'waiting'}));
      expect(seen.single.headers['Authorization'], equals('Bearer test_token'));
      expect(seen.single.headers['X-Capabilities'], equals('waiting'));

      await items.create({
        'a': 1,
      }, options: Options(headers: {'Authorization': 'Bearer override'}));
      expect(seen.last.headers['Authorization'], equals('Bearer override'));
    });

    test('list forwards options', () async {
      final seen = <RequestOptions>[];
      final items = _gateway(seen);
      await items.list(
        select: 'id',
        options: Options(headers: {'X-Trace': 'abc'}),
      );
      expect(seen.single.headers['X-Trace'], equals('abc'));
    });

    test('other methods forward options', () async {
      final seen = <RequestOptions>[];
      final items = _gateway(seen);
      final opts = Options(headers: {'X-Trace': 'abc'});
      await items.get(1, select: 'id', options: opts);
      await items.update(1, {'a': 1}, options: opts);
      await items.patch(1, {'a': 1}, options: opts);
      await items.remove(1, options: opts);
      await items.restore(1, options: opts);
      await items.upsert({'a': 1}, matchOn: ['a'], options: opts);
      expect(seen.length, equals(6));
      for (final r in seen) {
        expect(r.headers['X-Trace'], equals('abc'));
      }
    });

    test('a cancelled CancelToken cancels create', () async {
      final seen = <RequestOptions>[];
      final items = _gateway(seen);
      final token = CancelToken()..cancel('stop');
      await expectLater(
        items.create({'a': 1}, cancelToken: token),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(seen, isEmpty);
    });

    test('calls without the new arguments are unchanged', () async {
      final seen = <RequestOptions>[];
      final items = _gateway(seen, auth: _auth());
      final created = await items.create({'a': 1});
      expect(created.id, equals(1));
      expect(seen.single.headers['Authorization'], equals('Bearer test_token'));
      expect(seen.single.headers.containsKey('X-Capabilities'), isFalse);
    });
  });
}

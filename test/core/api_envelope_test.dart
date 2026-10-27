import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

class _Harness {
  final List<dynamic> script;
  int calls = 0;
  int refreshCalls = 0;
  late final Dio dio;

  _Harness(this.script) {
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final body =
              script[calls < script.length ? calls : script.length - 1];
          calls++;
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: body),
          );
        },
      ),
    );
  }

  SpApi api({
    bool withAuth = true,
    bool refreshResult = true,
    bool treat = true,
  }) => SpApi(
    baseUrl: Uri.parse('https://example.com/api/v1'),
    auth: withAuth
        ? ApiAuth(
            headers: () async => {},
            handleUnauthorized: () async {
              refreshCalls++;
              return refreshResult;
            },
          )
        : null,
    treatSuccessFalseAsError: treat,
    dio: dio,
  );
}

const _unauth = {'success': false, 'error_code': 10002, 'message': 'expired'};

void main() {
  group('success:false envelope', () {
    test('200 success:false throws SpApiError with HTTP status', () async {
      final h = _Harness([
        {'success': false, 'error_code': 5, 'message': 'x'},
      ]);
      await expectLater(
        h.api().request('GET', 'a'),
        throwsA(
          isA<SpApiError>()
              .having((e) => e.status, 'status', 200)
              .having((e) => e.errorCode, 'errorCode', 5)
              .having((e) => e.message, 'message', 'x'),
        ),
      );
    });

    test('10002 refreshes once and returns the retried result', () async {
      final h = _Harness([
        _unauth,
        {'success': true, 'data': 1},
      ]);
      final res = await h.api().request('GET', 'a');
      expect(res.data['data'], 1);
      expect(h.refreshCalls, 1);
      expect(h.calls, 2);
    });

    test('second 10002 throws without looping', () async {
      final h = _Harness([_unauth, _unauth]);
      await expectLater(
        h.api().request('GET', 'a'),
        throwsA(isA<SpApiError>().having((e) => e.errorCode, 'c', 10002)),
      );
      expect(h.refreshCalls, 1);
      expect(h.calls, 2);
    });

    test('success:true is unchanged', () async {
      final h = _Harness([
        {'success': true},
      ]);
      final res = await h.api().request('GET', 'a');
      expect(res.data['success'], true);
    });

    test('treatSuccessFalseAsError:false returns response as is', () async {
      final h = _Harness([_unauth]);
      final res = await h.api(treat: false).request('GET', 'a');
      expect(res.data['success'], false);
      expect(h.refreshCalls, 0);
    });

    test('10002 with auth == null throws immediately', () async {
      final h = _Harness([_unauth]);
      await expectLater(
        h.api(withAuth: false).request('GET', 'a'),
        throwsA(isA<SpApiError>()),
      );
      expect(h.calls, 1);
    });

    test('handleUnauthorized false throws', () async {
      final h = _Harness([_unauth]);
      await expectLater(
        h.api(refreshResult: false).request('GET', 'a'),
        throwsA(isA<SpApiError>()),
      );
      expect(h.refreshCalls, 1);
      expect(h.calls, 1);
    });

    test('bytes response returns normally', () async {
      final h = _Harness([
        [1, 2, 3],
      ]);
      expect(await h.api().getBytes('f'), [1, 2, 3]);
    });

    test('string and list bodies return normally', () async {
      final s = await _Harness(['success:false']).api().request('GET', 'a');
      expect(s.data, 'success:false');
      final l = await _Harness([
        [false],
      ]).api().request('GET', 'a');
      expect(l.data, [false]);
    });
  });
}

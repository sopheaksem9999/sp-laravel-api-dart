import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

class Item {
  final int id;
  Item(this.id);
  factory Item.fromJson(Map<String, dynamic> json) => Item(json['id'] as int);
}

/// Mimics the fake backend: cursor mode when `cursor` is present, a
/// next_cursor on every non-empty page, an empty page ends the sequence.
TableGateway<Item> _gateway(
  List<RequestOptions> seen, {
  Map<String, dynamic> Function(RequestOptions)? responder,
}) {
  final pages = <String, Map<String, dynamic>>{
    '': {
      'data': [
        {'id': 1},
        {'id': 2},
      ],
      'meta': {'next_cursor': 'c1'},
    },
    'c1': {
      'data': [
        {'id': 3},
        {'id': 4},
      ],
      'meta': {'next_cursor': 'c2'},
    },
    'c2': {
      'data': [
        {'id': 5},
      ],
      'meta': {'next_cursor': 'c3'},
    },
    'c3': {
      'data': <dynamic>[],
      'meta': {'next_cursor': null},
    },
  };
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        seen.add(options);
        final body =
            responder?.call(options) ??
            (options.queryParameters.containsKey('cursor')
                ? pages[options.queryParameters['cursor']]!
                : {
                    'data': [
                      {'id': 1},
                      {'id': 2},
                    ],
                    'meta': <String, dynamic>{},
                  });
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {'success': true, ...body},
          ),
        );
      },
    ),
  );
  final api = SpApi(baseUrl: Uri.parse('https://example.com/api/v1'), dio: dio);
  return TableGateway<Item>(api: api, name: 'items', fromJson: Item.fromJson);
}

void main() {
  group('cursor mode defaults', () {
    test(
      'iterate sends cursor= and follows next_cursor to an empty page',
      () async {
        final seen = <RequestOptions>[];
        final ids = await _gateway(
          seen,
        ).iterate(select: 'id', perPage: 2).map((i) => i.id).toList();
        expect(ids, [1, 2, 3, 4, 5]);
        expect(seen.map((o) => o.queryParameters['cursor']), [
          '',
          'c1',
          'c2',
          'c3',
        ]);
      },
    );

    test('fetchFirst sends an empty cursor', () async {
      final seen = <RequestOptions>[];
      final page = await _gateway(seen).fetchFirst(select: 'id', perPage: 2);
      expect(seen.single.queryParameters['cursor'], '');
      expect(page.nextCursor, 'c1');
    });

    test('cursorPagination().firstPage sends an empty cursor', () async {
      final seen = <RequestOptions>[];
      final page = await _gateway(
        seen,
      ).cursorPagination(select: 'id', perPage: 2).firstPage();
      expect(seen.single.queryParameters['cursor'], '');
      expect(page.nextCursor, 'c1');
    });

    test('list with a null cursor stays in offset mode', () async {
      final seen = <RequestOptions>[];
      await _gateway(seen).list(select: 'id', perPage: 2);
      expect(seen.single.queryParameters.containsKey('cursor'), isFalse);
    });
  });

  group('fetchPrev / fetchLast', () {
    test('fetchPrev sends direction=prev with the prev cursor', () async {
      final seen = <RequestOptions>[];
      final g = _gateway(
        seen,
        responder: (_) => {
          'data': [
            {'id': 1},
          ],
          'meta': {'next_cursor': 'c1', 'prev_cursor': 'p-1'},
        },
      );
      final r = await g.fetchPrev(
        const CursorPage<Item>(items: [], prevCursor: 'p0'),
        select: 'id',
      );
      expect(r, isNotNull);
      expect(seen.single.queryParameters['cursor'], 'p0');
      expect(seen.single.queryParameters['direction'], 'prev');
    });

    test('fetchLast without a sort throws unencodableValue and makes no '
        'request', () async {
      final seen = <RequestOptions>[];
      final g = _gateway(seen);
      await expectLater(
        g.fetchLast(select: 'id', perPage: 3),
        throwsA(
          isA<SpApiError>()
              .having((e) => e.code, 'code', SpApiErrorCode.unencodableValue)
              .having((e) => e.message, 'message', contains('sort')),
        ),
      );
      expect(seen, isEmpty);
    });

    test('lastPage without a sort throws and makes no request', () async {
      final seen = <RequestOptions>[];
      final pagination = _gateway(
        seen,
      ).cursorPagination(select: 'id', perPage: 2);
      await expectLater(
        pagination.lastPage(),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.unencodableValue,
          ),
        ),
      );
      expect(seen, isEmpty);
    });

    test(
      'lastPage with a sort reverses it and restores canonical order',
      () async {
        final seen = <RequestOptions>[];
        final g = _gateway(
          seen,
          responder: (_) => {
            'data': [
              {'id': 3},
              {'id': 2},
            ],
            'meta': {'next_cursor': 'c1'},
          },
        );
        final page = await g
            .cursorPagination(
              select: 'id',
              perPage: 2,
              sort: const Sort('id', Order.asc),
            )
            .lastPage();
        expect(seen.single.queryParameters['sortby'], 'id');
        expect(seen.single.queryParameters['order'], 'desc');
        expect(page.items.map((i) => i.id), [2, 3]);
      },
    );

    test('fetchLast keeps prevCursor null on a single short page', () async {
      final seen = <RequestOptions>[];
      final g = _gateway(
        seen,
        responder: (_) => {
          'data': [
            {'id': 1},
          ],
          'meta': {'next_cursor': 'c1'},
        },
      );
      final page = await g.fetchLast(
        select: 'id',
        perPage: 3,
        sort: const Sort('id', Order.asc),
      );
      expect(seen.single.queryParameters['cursor'], '');
      expect(page.prevCursor, isNull);
      expect(page.items.map((i) => i.id), [1]);
    });

    test('fetchLast keeps prevCursor on a full page', () async {
      final g = _gateway(
        [],
        responder: (_) => {
          'data': [
            {'id': 2},
            {'id': 1},
          ],
          'meta': {'next_cursor': 'c1'},
        },
      );
      final page = await g.fetchLast(
        select: 'id',
        perPage: 2,
        sort: const Sort('id', Order.asc),
      );
      expect(page.prevCursor, 'c1');
    });
  });
}

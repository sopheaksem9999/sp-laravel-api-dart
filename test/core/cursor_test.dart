import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

class Item {
  final int id;
  Item(this.id);
  factory Item.fromJson(Map<String, dynamic> json) => Item(json['id'] as int);
}

TableGateway<Item> _gateway(List<RequestOptions> seen, dynamic body) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        seen.add(options);
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: body),
        );
      },
    ),
  );
  final api = SpApi(baseUrl: Uri.parse('https://example.com/api/v1'), dio: dio);
  return TableGateway<Item>(api: api, name: 'items', fromJson: Item.fromJson);
}

dynamic _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync());

Future<CursorPage<Item>> _list(dynamic body, {int perPage = 2}) =>
    _gateway([], body).list(select: 'id', perPage: perPage, cursor: '');

void main() {
  group('list cursor parameters', () {
    test('sends exact cursor, direction, cursor_column and total', () async {
      final seen = <RequestOptions>[];
      await _gateway(seen, _fixture('cursor_page_full.json')).list(
        select: 'id',
        cursor: '',
        direction: 'next',
        cursorColumn: 'created_at',
        total: true,
        perPage: 2,
      );
      expect(seen.single.queryParameters, {
        'select': 'id',
        'cursor': '',
        'direction': 'next',
        'cursor_column': 'created_at',
        'total': 'true',
        'per_page': '2',
      });
    });

    test('omits direction and cursor_column when not given', () async {
      final seen = <RequestOptions>[];
      await _gateway(seen, _fixture('cursor_page_full.json')).list(
        select: 'id',
        cursor: 'c1.x',
      );
      expect(seen.single.queryParameters.containsKey('direction'), isFalse);
      expect(seen.single.queryParameters.containsKey('cursor_column'), isFalse);
      expect(seen.single.queryParameters['cursor'], 'c1.x');
    });
  });

  group('CursorPage next cursor', () {
    test('full page with next_cursor', () async {
      final page = await _list(_fixture('cursor_page_full.json'));
      expect(page.items, hasLength(2));
      expect(page.nextCursor, 'c1.2024-01-02.2');
      expect(page.prevCursor, isNull);
      expect(page.total, 5);
    });

    test('short page with next_cursor keeps it', () async {
      final page = await _list(_fixture('cursor_page_short.json'));
      expect(page.items, hasLength(1));
      expect(page.nextCursor, 'c1.2024-01-01.4');
      expect(page.prevCursor, 'c1.2024-01-02.4');
      expect(page.total, 5);
      expect(page.hasMore, isTrue);
    });

    test('short page without next_cursor is null', () async {
      final page = await _list({
        'data': [
          {'id': 1},
        ],
        'meta': <String, dynamic>{'total': 1},
      });
      expect(page.nextCursor, isNull);
      expect(page.total, 1);
    });

    test('full page without next_cursor is null', () async {
      final page = await _list({
        'data': [
          {'id': 1},
          {'id': 2},
        ],
        'meta': <String, dynamic>{},
      });
      expect(page.nextCursor, isNull);
    });

    test('empty page with next_cursor keeps it', () async {
      final page = await _list({
        'data': <dynamic>[],
        'meta': {'next_cursor': 'c1.z'},
      });
      expect(page.items, isEmpty);
      expect(page.nextCursor, 'c1.z');
    });

    test('empty page (fixture) has no cursor', () async {
      final page = await _list(_fixture('cursor_page_empty.json'));
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
      expect(page.total, 5);
    });

    test('camelCase nextCursor is accepted', () async {
      final page = await _list({
        'data': [
          {'id': 1},
        ],
        'meta': {'nextCursor': 'abc'},
      });
      expect(page.nextCursor, 'abc');
    });

    test('offset mode yields no cursor', () async {
      final page = await _gateway([], {
        'data': [
          {'id': 1},
          {'id': 2},
        ],
        'meta': {'next_cursor': 'zzz'},
      }).list(select: 'id', page: 1, perPage: 2);
      expect(page.nextCursor, isNull);
    });
  });
}

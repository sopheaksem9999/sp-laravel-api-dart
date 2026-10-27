import 'dart:convert';
import 'dart:io';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  group('query serializer test vectors', () {
    test('matches byte-for-byte shared test vectors', () {
      final file = File('test/vectors/query_serializer_vectors.json');
      final jsonList = jsonDecode(file.readAsStringSync()) as List<dynamic>;

      for (final entry in jsonList) {
        final name = entry['name'] as String;
        final queryData = entry['query'] as Map<String, dynamic>;
        final expected = (entry['expected'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v.toString()),
        );

        final select = queryData['select'] as String?;
        final perPage = queryData['perPage'] as int?;
        final cursor = queryData['cursor'] as String?;
        final total = queryData['total'] as bool?;

        Sort? sort;
        if (queryData['sort'] != null) {
          final s = queryData['sort'] as Map<String, dynamic>;
          final order = s['order'] == 'desc' ? Order.desc : Order.asc;
          sort = Sort(s['field'] as String, order);
        }

        final whereList = <Filter>[];
        if (queryData['where'] != null) {
          for (final w in queryData['where'] as List<dynamic>) {
            final wm = w as Map<String, dynamic>;
            final type = wm['type'] as String;
            final col = wm['col'] as String;
            switch (type) {
              case 'eq':
                whereList.add(Filter.eq(col, wm['val'] as Object));
                break;
              case 'in':
                whereList.add(
                  Filter.inList(col, (wm['vals'] as List).cast<Object>()),
                );
                break;
              case 'gte':
                whereList.add(Filter.gte(col, wm['val'] as Object));
                break;
              case 'lt':
                whereList.add(Filter.lt(col, wm['val'] as Object));
                break;
            }
          }
        }

        final orList = <Filter>[];
        if (queryData['or'] != null) {
          for (final w in queryData['or'] as List<dynamic>) {
            final wm = w as Map<String, dynamic>;
            final type = wm['type'] as String;
            final col = wm['col'] as String;
            if (type == 'eq') {
              orList.add(Filter.eq(col, wm['val'] as Object));
            } else if (type == 'lt') {
              orList.add(Filter.lt(col, wm['val'] as Object));
            }
          }
        }

        final result = serializeQuery(
          select: select,
          where: whereList,
          or: orList.isEmpty ? null : orList,
          sort: sort,
          perPage: perPage,
          cursor: cursor,
          total: total,
          requireSelect: false,
        );

        expect(result, equals(expected), reason: 'Vector failed: $name');
      }
    });
  });

  group('serializeQuery rules & operators', () {
    test('requireSelect throws unencodableValue when select is omitted', () {
      expect(
        () => serializeQuery(requireSelect: true),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.unencodableValue,
          ),
        ),
      );

      // Opt out with requireSelect: false or Select.all
      final res = serializeQuery(requireSelect: false);
      expect(res.containsKey('select'), isFalse);

      final resAll = serializeQuery(select: Select.all);
      expect(resAll['select'], equals('*'));
    });

    test('always sends per_page default 25', () {
      final res = serializeQuery(select: 'id');
      expect(res['per_page'], equals('25'));
    });

    test('handles cursor variations', () {
      expect(serializeQuery(select: 'id', cursor: null)['cursor'], isNull);
      expect(serializeQuery(select: 'id', cursor: '')['cursor'], equals('0'));
      expect(
        serializeQuery(select: 'id', cursor: 'cur_abc')['cursor'],
        equals('cur_abc'),
      );
    });

    test('handles page offset when cursor is omitted', () {
      final res = serializeQuery(select: 'id', page: 3);
      expect(res['page'], equals('3'));
      expect(res.containsKey('cursor'), isFalse);
    });

    test('quotes reserved characters properly', () {
      final res = serializeQuery(
        select: 'id',
        where: [
          Filter.eq('name', 'Acme, Inc.'),
          Filter.inList('tags', ['a', 'b,c']),
          Filter.eq('quote', 'say "hi"'),
          Filter.eq('backslash', r'a\b'),
          Filter.eq('lead', ' spaced '),
          Filter.eq('plain', 'simple'),
        ],
      );
      expect(res['name'], equals('eq."Acme, Inc."'));
      expect(res['tags'], equals('in.(a,"b,c")'));
      expect(res['quote'], equals(r'eq."say \"hi\""'));
      expect(res['backslash'], equals(r'eq."a\\b"'));
      expect(res['lead'], equals('eq." spaced "'));
      expect(res['plain'], equals('eq.simple'));
    });

    test(
      'throws unencodableValue when quoting is false and string has reserved chars',
      () {
        expect(
          () => serializeQuery(
            select: 'id',
            quoting: false,
            where: [Filter.eq('name', 'Acme, Inc.')],
          ),
          throwsA(
            isA<SpApiError>().having(
              (e) => e.code,
              'code',
              SpApiErrorCode.unencodableValue,
            ),
          ),
        );
      },
    );

    test('serializes isNull, isNotNull, empty, notEmpty', () {
      final res = serializeQuery(
        select: 'id',
        where: [
          Filter.isNull('deleted_at'),
          Filter.isNotNull('published_at'),
          Filter.empty('bio'),
          Filter.notEmpty('email'),
        ],
      );
      expect(res['deleted_at'], equals('is.null'));
      expect(res['published_at'], equals('is_not.null'));
      expect(res['bio'], equals('empty.true'));
      expect(res['email'], equals('not_empty.true'));
    });

    test('serializes between and notBetween', () {
      final res = serializeQuery(
        select: 'id',
        where: [
          Filter.between('age', 18, 65),
          Filter.notBetween('score', 0, 50),
        ],
      );
      expect(res['age'], equals('between.(18,65)'));
      expect(res['score'], equals('not_between.(0,50)'));
    });

    test(
      'serializes like, ilike, notLike, notIlike, contains, startsWith, endsWith',
      () {
        final res = serializeQuery(
          select: 'id',
          where: [
            Filter.like('code', '%ABC%'),
            Filter.ilike('name', 'john%'),
            Filter.notLike('ref', 'TMP%'),
            Filter.notIlike('sku', 'OLD%'),
            Filter.contains('title', 'beta'),
            Filter.startsWith('prefix', 'pre'),
            Filter.endsWith('suffix', 'end'),
          ],
        );
        expect(res['code'], equals('like.%ABC%'));
        expect(res['name'], equals('ilike.john%'));
        expect(res['ref'], equals('not_like.TMP%'));
        expect(res['sku'], equals('not_ilike.OLD%'));
        expect(res['title'], equals('contains.beta'));
        expect(res['prefix'], equals('starts_with.pre'));
        expect(res['suffix'], equals('ends_with.end'));
      },
    );

    test('serializes negation not(contains), not(startsWith), not(dateGt)', () {
      final res = serializeQuery(
        select: 'id',
        where: [
          Filter.not(Filter.contains('title', 'test')),
          Filter.not(Filter.startsWith('slug', 'archived')),
          Filter.not(Filter.dateGt('created_at', '2026-01-01')),
        ],
      );
      expect(res['title'], equals('not.contains.test'));
      expect(res['slug'], equals('not.starts_with.archived'));
      expect(res['created_at'], equals('not.date_gt.2026-01-01'));
    });

    test('not on non-negatable operator throws unencodableValue', () {
      expect(
        () => serializeQuery(
          select: 'id',
          where: [Filter.not(Filter.eq('status', 'active'))],
        ),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.unencodableValue,
          ),
        ),
      );
    });

    test('serializes any and all modifiers', () {
      final res = serializeQuery(
        select: 'id',
        where: [
          Filter.any('name', 'like', ['a%', 'b%']),
          Filter.all('tag', 'like', ['%x%', '%y%']),
        ],
      );
      expect(res['name'], equals('like(any).{a%,b%}'));
      expect(res['tag'], equals('like(all).{%x%,%y%}'));
    });

    test('serializes anyOf columns', () {
      final res = serializeQuery(
        select: 'id',
        where: [
          Filter.anyOf(['name', 'sku'], Filter.ilike('name', 'cola')),
        ],
      );
      expect(res['name,sku'], equals('ilike.cola'));
    });

    test('serializes raw filter splitting at first =', () {
      final res = serializeQuery(
        select: 'id',
        where: [Filter.raw('col=op.va=lue')],
      );
      expect(res['col'], equals('op.va=lue'));
    });

    test('serializes DateTime as ISO-8601 string', () {
      final dt = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final res = serializeQuery(
        select: 'id',
        where: [Filter.gte('created_at', dt)],
      );
      expect(res['created_at'], equals('gte.2026-01-02T03:04:05.000Z'));
    });

    test('rejects postgres-only operators on mysql driver', () {
      expect(
        () => serializeQuery(
          select: 'id',
          driver: 'mysql',
          where: [Filter.custom('body', 'fts', 'search term')],
        ),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.unencodableValue,
          ),
        ),
      );
    });

    test('never emits bracket keys or filter[col] or sort=-col', () {
      final res = serializeQuery(
        select: 'id',
        where: [
          Filter.gte('total', 100),
          Filter.lt('total', 500),
          Filter.eq('status', 'active'),
        ],
        or: [
          Filter.eq('role', 'admin'),
          Filter.and([Filter.eq('department', 'sales'), Filter.eq('level', 2)]),
        ],
        sort: const Sort('created_at', Order.desc),
        search: 'acme',
        total: true,
      );

      for (final key in res.keys) {
        expect(key, isNot(contains('[')));
        expect(key, isNot(startsWith('filter')));
        expect(key, isNot(startsWith('sort-')));
      }
      expect(res['and'], equals('(total.gte.100,total.lt.500)'));
      expect(
        res['or'],
        equals('(role.eq.admin,and(department.eq.sales,level.eq.2))'),
      );
      expect(res['sortby'], equals('created_at'));
      expect(res['order'], equals('desc'));
      expect(res['s'], equals('acme'));
      expect(res['total'], equals('true'));
    });
  });
}

import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  final pagingKeys = {
    'per_page',
    'page',
    'cursor',
    'direction',
    'cursor_column',
    'total',
  };

  // Each case is the arguments both serializers take.
  final cases = <String, Map<String, Object?>>{
    'where with operators': {
      'where': [Filter.eq('status', 'paid'), Filter.gte('amount', 10)],
    },
    'two operators on one column': {
      'where': [Filter.gte('amount', 10), Filter.lte('amount', 90)],
    },
    'or groups': {
      'or': [
        Filter.eq('status', 'paid'),
        Filter.and([Filter.eq('status', 'open'), Filter.gt('amount', 5)]),
      ],
    },
    'search': {'search': 'acme'},
    'select': {'select': 'id,number,customer(id,name)'},
    'distinct': {'distinct': true},
    'trashed': {'trashed': 'only'},
    'sort': {'sort': const Sort('created_at', Order.desc)},
    'everything together': {
      'select': 'id',
      'where': [Filter.eq('status', 'paid')],
      'sort': const Sort('id', Order.asc),
      'trashed': 'with',
      'distinct': true,
    },
  };

  Map<String, String> filters(Map<String, Object?> a) => serializeFilters(
    select: a['select'] as String?,
    where: (a['where'] as List<Filter>?) ?? const [],
    or: a['or'] as List<Filter>?,
    sort: a['sort'] as Sort?,
    search: a['search'] as String?,
    distinct: a['distinct'] as bool?,
    trashed: a['trashed'] as String?,
  );

  Map<String, String> query(Map<String, Object?> a) => serializeQuery(
    select: a['select'] as String?,
    where: (a['where'] as List<Filter>?) ?? const [],
    or: a['or'] as List<Filter>?,
    sort: a['sort'] as Sort?,
    search: a['search'] as String?,
    distinct: a['distinct'] as bool?,
    trashed: a['trashed'] as String?,
    requireSelect: false,
  );

  group('serializeFilters', () {
    for (final e in cases.entries) {
      test('matches serializeQuery minus the paging keys: ${e.key}', () {
        final full = query(e.value)..remove('per_page');
        expect(
          filters(e.value).entries.toList().map((x) => '${x.key}=${x.value}'),
          full.entries.toList().map((x) => '${x.key}=${x.value}'),
        );
      });
    }

    test('quotes like values: name=like."Smith, John (Jr)"', () {
      final p = serializeFilters(
        where: [Filter.like('name', 'Smith, John (Jr)')],
      );
      expect(p['name'], 'like."Smith, John (Jr)"');
    });

    test('never returns per_page, page, cursor, direction, cursor_column or '
        'total', () {
      for (final e in cases.values) {
        expect(filters(e).keys.toSet().intersection(pagingKeys), isEmpty);
      }
      expect(serializeFilters(), isEmpty);
    });

    test('does not require select', () {
      expect(serializeFilters(where: [Filter.eq('status', 'paid')]), {
        'status': 'eq.paid',
      });
    });

    test('quoting false throws for a value that needs quotes', () {
      expect(
        () => serializeFilters(
          where: [Filter.like('name', 'a,b')],
          quoting: false,
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
  });

  group('serializeQuery is unchanged', () {
    test('per_page comes after the filters and the paging keys keep their '
        'order', () {
      final p = serializeQuery(
        where: [Filter.eq('status', 'paid')],
        cursor: 'c1',
        direction: 'prev',
        cursorColumn: 'created_at',
        perPage: 7,
        total: true,
        requireSelect: false,
      );
      expect(p.keys.toList(), [
        'status',
        'cursor',
        'direction',
        'cursor_column',
        'per_page',
        'total',
      ]);
      expect(p['per_page'], '7');
    });

    test('select is still required by default', () {
      expect(() => serializeQuery(), throwsA(isA<SpApiError>()));
    });
  });
}

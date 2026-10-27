import '../errors.dart';
import 'filter.dart';
import 'sort.dart';

final _needsQuotes = RegExp(r'[,()"\\]|^\s|\s$');
final _modifierUnsafe = RegExp(r'[,{}"\\]|^\s|\s$');

const _pgOnly = {
  'fts',
  'plfts',
  'phfts',
  'wfts',
  'cs',
  'cd',
  'ov',
  'sl',
  'sr',
  'nxl',
  'nxr',
  'adj',
};

const _negatable = {'contains', 'starts_with', 'ends_with'};

bool _isNegatable(String op) =>
    _negatable.contains(op) || op.startsWith('date_');

const _likeFallback = {
  'contains': '%v%',
  'starts_with': 'v%',
  'ends_with': '%v',
};

Never _unencodable(String message) {
  throw SpApiError(
    status: 0,
    code: SpApiErrorCode.unencodableValue,
    message: message,
  );
}

String _formatValue(Object? v, bool quoting) {
  if (v == null) return 'null';
  final s = v is DateTime ? v.toUtc().toIso8601String() : v.toString();
  if (!_needsQuotes.hasMatch(s)) return s;
  if (!quoting) {
    _unencodable(
      'Value "$s" contains reserved characters and cannot be sent with quoting disabled',
    );
  }
  final escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

class _SerializedOp {
  final String column;
  final String op;
  final String wireValue;

  const _SerializedOp(this.column, this.op, this.wireValue);

  String get fullOperand => '$op.$wireValue';
  String get dotted => '$column.$op.$wireValue';
}

_SerializedOp _serializeFilter(
  Filter filter, {
  required bool quoting,
  String? driver,
  bool isNegated = false,
}) {
  if (filter is NotFilter) {
    return _serializeFilter(
      filter.inner,
      quoting: quoting,
      driver: driver,
      isNegated: true,
    );
  }

  String col = '';
  String op = '';
  String wireVal = '';

  if (filter is ColumnFilter) {
    col = filter.column;
  }

  switch (filter) {
    case EqFilter(:final value):
      op = 'eq';
      wireVal = _formatValue(value, quoting);
    case NeqFilter(:final value):
      op = 'neq';
      wireVal = _formatValue(value, quoting);
    case GtFilter(:final value):
      op = 'gt';
      wireVal = _formatValue(value, quoting);
    case GteFilter(:final value):
      op = 'gte';
      wireVal = _formatValue(value, quoting);
    case LtFilter(:final value):
      op = 'lt';
      wireVal = _formatValue(value, quoting);
    case LteFilter(:final value):
      op = 'lte';
      wireVal = _formatValue(value, quoting);
    case InListFilter(:final values):
      op = 'in';
      wireVal = '(${values.map((v) => _formatValue(v, quoting)).join(',')})';
    case NotInListFilter(:final values):
      op = 'not_in';
      wireVal = '(${values.map((v) => _formatValue(v, quoting)).join(',')})';
    case BetweenFilter(:final lower, :final upper):
      op = 'between';
      wireVal =
          '(${_formatValue(lower, quoting)},${_formatValue(upper, quoting)})';
    case NotBetweenFilter(:final lower, :final upper):
      op = 'not_between';
      wireVal =
          '(${_formatValue(lower, quoting)},${_formatValue(upper, quoting)})';
    case LikeFilter(:final value):
      op = 'like';
      wireVal = _formatValue(value, quoting);
    case IlikeFilter(:final value):
      op = 'ilike';
      wireVal = _formatValue(value, quoting);
    case NotLikeFilter(:final value):
      op = 'not_like';
      wireVal = _formatValue(value, quoting);
    case NotIlikeFilter(:final value):
      op = 'not_ilike';
      wireVal = _formatValue(value, quoting);
    case ContainsFilter(:final value):
      op = 'contains';
      wireVal = _formatValue(value, quoting);
    case StartsWithFilter(:final value):
      op = 'starts_with';
      wireVal = _formatValue(value, quoting);
    case EndsWithFilter(:final value):
      op = 'ends_with';
      wireVal = _formatValue(value, quoting);
    case IsNullFilter():
      op = 'is';
      wireVal = 'null';
    case IsNotNullFilter():
      op = 'is_not';
      wireVal = 'null';
    case EmptyFilter():
      op = 'empty';
      wireVal = 'true';
    case NotEmptyFilter():
      op = 'not_empty';
      wireVal = 'true';
    case DateEqFilter(:final value):
      op = 'date_eq';
      wireVal = _formatValue(value, quoting);
    case DateNeqFilter(:final value):
      op = 'date_neq';
      wireVal = _formatValue(value, quoting);
    case DateGtFilter(:final value):
      op = 'date_gt';
      wireVal = _formatValue(value, quoting);
    case DateGteFilter(:final value):
      op = 'date_gte';
      wireVal = _formatValue(value, quoting);
    case DateLtFilter(:final value):
      op = 'date_lt';
      wireVal = _formatValue(value, quoting);
    case DateLteFilter(:final value):
      op = 'date_lte';
      wireVal = _formatValue(value, quoting);
    case CustomOpFilter(op: final customOp, :final value):
      op = customOp;
      wireVal = _formatValue(value, quoting);
    case AnyModifierFilter(op: final modOp, :final values):
      op = '$modOp(any)';
      for (final v in values) {
        final s = v.toString();
        if (s.isEmpty || _modifierUnsafe.hasMatch(s)) {
          _unencodable('Invalid modifier item "$s"');
        }
      }
      wireVal = '{${values.map((v) => v.toString()).join(',')}}';
    case AllModifierFilter(op: final modOp, :final values):
      op = '$modOp(all)';
      for (final v in values) {
        final s = v.toString();
        if (s.isEmpty || _modifierUnsafe.hasMatch(s)) {
          _unencodable('Invalid modifier item "$s"');
        }
      }
      wireVal = '{${values.map((v) => v.toString()).join(',')}}';
    case AnyOfColumnsFilter(:final columns, :final condition):
      col = columns.join(',');
      final inner = _serializeFilter(
        condition,
        quoting: quoting,
        driver: driver,
        isNegated: isNegated,
      );
      return _SerializedOp(col, inner.op, inner.wireValue);
    case RawFilter():
      _unencodable('RawFilter cannot be processed as a standard operator');
    case NotFilter():
      _unencodable('Unreachable');
    case OrFilter():
    case AndFilter():
      _unencodable('Composite filter cannot be processed as a single operator');
  }

  if (driver == 'mysql' && _pgOnly.contains(op)) {
    _unencodable(
      'Operator "$op" is Postgres-only and not supported by the "mysql" driver',
    );
  }

  if (isNegated) {
    if (!_isNegatable(op)) {
      _unencodable(
        'Operator "$op" has no "not." form; use its negated operator (e.g. neq, not_in, not_like)',
      );
    }
    if (quoting) {
      op = 'not.$op';
    } else {
      final fallbackPattern = _likeFallback[op];
      if (fallbackPattern == null) {
        _unencodable(
          '"not.$op" needs a host >= 0.5.06 and has no fallback with quoting disabled',
        );
      }
      final rawVal = wireVal.replaceAll('"', '');
      op = 'not_like';
      wireVal = fallbackPattern.replaceAll('v', rawVal);
    }
  }

  return _SerializedOp(col, op, wireVal);
}

/// Converts query parameters into the URL parameters expected by the SP Laravel backend.
Map<String, String> serializeQuery({
  String? select,
  List<Filter> where = const [],
  List<Filter>? or,
  Sort? sort,
  String? search,
  int? perPage,
  String? cursor,
  int? page,
  bool? total,
  bool? distinct,
  String? trashed,
  bool requireSelect = true,
  bool quoting = true,
  String? driver,
}) {
  if (requireSelect && (select == null || select.isEmpty)) {
    _unencodable(
      'select is required unless explicitly opted out with requireSelect: false or Select.all',
    );
  }

  final params = <String, String>{};

  if (select != null && select.isNotEmpty) {
    params['select'] = select;
  }

  // Group conditions by column to detect multi-operator on same column
  final columnOps = <String, List<_SerializedOp>>{};
  final andDottedList = <String>[];

  for (final f in where) {
    if (f is RawFilter) {
      final idx = f.raw.indexOf('=');
      if (idx <= 0) {
        _unencodable('"raw" must be a "col=op.value" pair; got ${f.raw}');
      }
      params[f.raw.substring(0, idx)] = f.raw.substring(idx + 1);
      continue;
    }

    final serialized = _serializeFilter(f, quoting: quoting, driver: driver);
    columnOps.putIfAbsent(serialized.column, () => []).add(serialized);
  }

  for (final entry in columnOps.entries) {
    final col = entry.key;
    final ops = entry.value;
    if (ops.length == 1) {
      params[col] = ops.first.fullOperand;
    } else {
      for (final op in ops) {
        andDottedList.add(op.dotted);
      }
    }
  }

  if (andDottedList.isNotEmpty) {
    params['and'] = '(${andDottedList.join(',')})';
  }

  if (or != null && or.isNotEmpty) {
    final orParts = <String>[];
    for (final f in or) {
      if (f is AndFilter) {
        final innerDotted = f.filters.map((inner) {
          final s = _serializeFilter(inner, quoting: quoting, driver: driver);
          return s.dotted;
        }).toList();
        orParts.add('and(${innerDotted.join(',')})');
      } else {
        final s = _serializeFilter(f, quoting: quoting, driver: driver);
        orParts.add(s.dotted);
      }
    }
    params['or'] = '(${orParts.join(',')})';
  }

  if (distinct == true) {
    params['distinct'] = 'true';
  }

  if (trashed == 'with') {
    params['with_trashed'] = 'true';
  } else if (trashed == 'only') {
    params['only_trashed'] = 'true';
  }

  if (search != null && search.isNotEmpty) {
    params['s'] = search;
  }

  if (sort != null) {
    params['sortby'] = sort.field;
    params['order'] = sort.order.name;
  }

  if (cursor != null) {
    params['cursor'] = cursor.isEmpty ? '0' : cursor;
  } else if (page != null) {
    params['page'] = page.toString();
  }

  params['per_page'] = (perPage ?? 25).toString();

  if (total != null) {
    params['total'] = total.toString();
  }

  return params;
}

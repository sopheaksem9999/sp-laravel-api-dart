import 'dart:async';
import 'api_core.dart';
import 'errors.dart';
import 'pagination.dart';
import 'query/filter.dart';
import 'query/serialize.dart';
import 'query/sort.dart';

/// CRUD table gateway providing typed record operations and cursor iteration.
class TableGateway<T> {
  /// The parent [SpApi] client instance.
  final SpApi api;

  /// The target table name.
  final String name;

  /// JSON deserializer callback for row objects.
  final T Function(Map<String, dynamic>) fromJson;

  /// Creates a [TableGateway] bound to table [name].
  const TableGateway({
    required this.api,
    required this.name,
    required this.fromJson,
  });

  /// Lists records on this table matching filters and pagination parameters.
  Future<CursorPage<T>> list({
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
  }) async {
    final params = serializeQuery(
      select: select,
      where: where,
      or: or,
      sort: sort,
      search: search,
      perPage: perPage,
      cursor: cursor,
      page: page,
      total: total,
      distinct: distinct,
      trashed: trashed,
      requireSelect: requireSelect,
    );

    final res = await api.request('GET', name, queryParameters: params);

    final body = res.data;
    List<dynamic> rows = [];
    Map<String, dynamic> meta = {};

    if (body is Map<String, dynamic>) {
      if (body['data'] is List) {
        rows = body['data'] as List;
      }
      if (body['meta'] is Map<String, dynamic>) {
        meta = body['meta'] as Map<String, dynamic>;
      }
    } else if (body is List) {
      rows = body;
    }

    return CursorPage.fromResponse(
      data: rows,
      meta: meta,
      fromJson: fromJson,
      perPage: perPage ?? 25,
      offsetMode: page != null && cursor == null,
    );
  }

  /// Retrieves a single record by [id].
  Future<T> get(dynamic id, {String? select, bool requireSelect = true}) async {
    Map<String, String>? params;
    if (select != null || requireSelect) {
      params = serializeQuery(select: select, requireSelect: requireSelect);
      params.remove('per_page');
    }

    final res = await api.request('GET', '$name/$id', queryParameters: params);

    final body = res.data;
    if (body is Map<String, dynamic>) {
      if (body.containsKey('data') && body['data'] is Map<String, dynamic>) {
        return fromJson(body['data'] as Map<String, dynamic>);
      }
      return fromJson(body);
    }
    throw SpApiError(
      status: 0,
      code: SpApiErrorCode.unknown,
      message: 'Unexpected non-map record response',
      body: body,
    );
  }

  /// Inserts a new record into the table.
  Future<T> create(Map<String, dynamic> body) async {
    final res = await api.request('POST', name, data: body);

    final resData = res.data;
    if (resData is Map<String, dynamic>) {
      if (resData['data'] is Map<String, dynamic>) {
        return fromJson(resData['data'] as Map<String, dynamic>);
      }
      return fromJson(resData);
    }
    throw SpApiError(
      status: 0,
      code: SpApiErrorCode.unknown,
      message: 'Unexpected non-map record response',
      body: resData,
    );
  }

  /// Updates an existing record via PUT.
  Future<T> update(dynamic id, Map<String, dynamic> body) async {
    final res = await api.request('PUT', '$name/$id', data: body);

    final resData = res.data;
    if (resData is Map<String, dynamic>) {
      if (resData['data'] is Map<String, dynamic>) {
        return fromJson(resData['data'] as Map<String, dynamic>);
      }
      return fromJson(resData);
    }
    throw SpApiError(
      status: 0,
      code: SpApiErrorCode.unknown,
      message: 'Unexpected non-map record response',
      body: resData,
    );
  }

  /// Partially updates an existing record via PATCH.
  Future<T> patch(dynamic id, Map<String, dynamic> body) async {
    final res = await api.request('PATCH', '$name/$id', data: body);

    final resData = res.data;
    if (resData is Map<String, dynamic>) {
      if (resData['data'] is Map<String, dynamic>) {
        return fromJson(resData['data'] as Map<String, dynamic>);
      }
      return fromJson(resData);
    }
    throw SpApiError(
      status: 0,
      code: SpApiErrorCode.unknown,
      message: 'Unexpected non-map record response',
      body: resData,
    );
  }

  /// Deletes a record by [id].
  Future<bool> remove(dynamic id, {bool force = false}) async {
    final query = force ? {'force': 'true'} : null;
    await api.request('DELETE', '$name/$id', queryParameters: query);
    return true;
  }

  /// Restores a soft-deleted record by [id]. Returns count of restored rows.
  Future<int> restore(dynamic id) async {
    final res = await api.request('POST', '$name/$id/restore');
    final resData = res.data;
    if (resData is Map<String, dynamic>) {
      final inner = resData['data'];
      if (inner is Map<String, dynamic> && inner['restored'] is int) {
        return inner['restored'] as int;
      }
    }
    return 1;
  }

  /// Upserts a record using a natural key given by [matchOn].
  Future<dynamic> upsert(
    Map<String, dynamic> body, {
    required List<String> matchOn,
    bool refetch = false,
    String? select,
  }) async {
    final res = await api.request(
      'POST',
      '$name/upsert',
      queryParameters: {'match_on': matchOn.join(',')},
      data: body,
    );

    final resData = res.data;
    final row = (resData is Map<String, dynamic> && resData.containsKey('data'))
        ? resData['data']
        : resData;

    if (refetch) {
      if (row is Map<String, dynamic> && row['id'] != null) {
        return get(row['id'], select: select);
      }
      throw SpApiError(
        status: 0,
        code: SpApiErrorCode.unknown,
        message: 'upsert refetch requested but response had no id',
        body: resData,
      );
    }

    return row;
  }

  /// Yields rows across pages sequentially as an asynchronous stream.
  Stream<T> iterate({
    String? select,
    List<Filter> where = const [],
    Sort? sort,
    String? search,
    int? perPage,
    bool requireSelect = true,
  }) async* {
    String? currentCursor;

    for (;;) {
      final page = await list(
        select: select,
        where: where,
        sort: sort,
        search: search,
        perPage: perPage,
        cursor: currentCursor,
        requireSelect: requireSelect,
      );

      if (page.items.isEmpty) {
        return;
      }

      for (final item in page.items) {
        yield item;
      }

      if (page.nextCursor == null || page.nextCursor == currentCursor) {
        return;
      }

      currentCursor = page.nextCursor;
    }
  }
}

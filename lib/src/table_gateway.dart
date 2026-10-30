import 'dart:async';
import 'package:dio/dio.dart';
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
    Options? options,
    CancelToken? cancelToken,
    String? direction,
    String? cursorColumn,
  }) async {
    final params = serializeQuery(
      select: select,
      where: where,
      or: or,
      sort: sort,
      search: search,
      perPage: perPage,
      cursor: cursor,
      direction: direction,
      cursorColumn: cursorColumn,
      page: page,
      total: total,
      distinct: distinct,
      trashed: trashed,
      requireSelect: requireSelect,
    );

    final res = await api.request(
      'GET',
      name,
      queryParameters: params,
      options: options,
      cancelToken: cancelToken,
    );

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
  Future<T> get(
    dynamic id, {
    String? select,
    bool requireSelect = true,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    Map<String, String>? params;
    if (select != null || requireSelect) {
      params = serializeQuery(select: select, requireSelect: requireSelect);
      params.remove('per_page');
    }

    final res = await api.request(
      'GET',
      '$name/$id',
      queryParameters: params,
      options: options,
      cancelToken: cancelToken,
    );

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
  Future<T> create(
    Map<String, dynamic> body, {
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final res = await api.request(
      'POST',
      name,
      data: body,
      options: options,
      cancelToken: cancelToken,
    );

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
  Future<T> update(
    dynamic id,
    Map<String, dynamic> body, {
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final res = await api.request(
      'PUT',
      '$name/$id',
      data: body,
      options: options,
      cancelToken: cancelToken,
    );

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
  Future<T> patch(
    dynamic id,
    Map<String, dynamic> body, {
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final res = await api.request(
      'PATCH',
      '$name/$id',
      data: body,
      options: options,
      cancelToken: cancelToken,
    );

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
  Future<bool> remove(
    dynamic id, {
    bool force = false,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final query = force ? {'force': 'true'} : null;
    await api.request(
      'DELETE',
      '$name/$id',
      queryParameters: query,
      options: options,
      cancelToken: cancelToken,
    );
    return true;
  }

  /// Restores a soft-deleted record by [id]. Returns count of restored rows.
  Future<int> restore(
    dynamic id, {
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final res = await api.request(
      'POST',
      '$name/$id/restore',
      options: options,
      cancelToken: cancelToken,
    );
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
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final res = await api.request(
      'POST',
      '$name/upsert',
      queryParameters: {'match_on': matchOn.join(',')},
      data: body,
      options: options,
      cancelToken: cancelToken,
    );

    final resData = res.data;
    final row = (resData is Map<String, dynamic> && resData.containsKey('data'))
        ? resData['data']
        : resData;

    if (refetch) {
      if (row is Map<String, dynamic> && row['id'] != null) {
        return get(
          row['id'],
          select: select,
          options: options,
          cancelToken: cancelToken,
        );
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
    // An empty cursor selects cursor mode (page one); null would be offset mode.
    String? currentCursor = '';

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

  /// Fetches the very first cursor page of records (sends `cursor=`, cursor mode).
  Future<CursorPage<T>> fetchFirst({
    String? select,
    List<Filter> where = const [],
    List<Filter>? or,
    Sort? sort,
    String? search,
    int? perPage,
    bool? total,
    bool? distinct,
    String? trashed,
    bool requireSelect = true,
  }) => list(
    select: select,
    where: where,
    or: or,
    sort: sort,
    search: search,
    perPage: perPage,
    cursor: '',
    total: total,
    distinct: distinct,
    trashed: trashed,
    requireSelect: requireSelect,
  );

  /// Fetches the last page of records by inverting the sort direction,
  /// then restoring the returned records back to canonical order.
  ///
  /// [sort] is required: the host's default sort depends on the table
  /// (`created_at` when it has one, else the primary key), so the client
  /// cannot know which order to invert. Without one this throws
  /// `SpApiError(unencodableValue)` before any request.
  Future<CursorPage<T>> fetchLast({
    String? select,
    List<Filter> where = const [],
    List<Filter>? or,
    Sort? sort,
    String? search,
    int? perPage,
    bool? total,
    bool? distinct,
    String? trashed,
    bool requireSelect = true,
  }) async {
    if (sort == null) {
      throw const SpApiError(
        status: 0,
        code: SpApiErrorCode.unencodableValue,
        message:
            'fetchLast needs a sort: the host\'s default sort depends on the '
            'table, so the client cannot invert it',
      );
    }
    final reversedSort = sort.reversed();

    final page = await list(
      select: select,
      where: where,
      or: or,
      sort: reversedSort,
      search: search,
      perPage: perPage,
      cursor: '',
      total: total,
      distinct: distinct,
      trashed: trashed,
      requireSelect: requireSelect,
    );

    return CursorPage<T>(
      items: page.items.reversed.toList(),
      nextCursor: null,
      // A single short page has no previous page.
      prevCursor: perPage != null && page.items.length < perPage
          ? null
          : page.nextCursor,
      total: page.total,
      meta: page.meta,
    );
  }

  /// Fetches the next page of records based on [current]'s [CursorPage.nextCursor].
  /// Returns `null` if [current] has no next page.
  Future<CursorPage<T>?> fetchNext(
    CursorPage<T> current, {
    String? select,
    List<Filter> where = const [],
    List<Filter>? or,
    Sort? sort,
    String? search,
    int? perPage,
    bool? total,
    bool? distinct,
    String? trashed,
    bool requireSelect = true,
  }) async {
    final cursor = current.nextCursor;
    if (cursor == null || cursor.isEmpty) {
      return null;
    }
    return list(
      select: select,
      where: where,
      or: or,
      sort: sort,
      search: search,
      perPage: perPage,
      cursor: cursor,
      total: total,
      distinct: distinct,
      trashed: trashed,
      requireSelect: requireSelect,
    );
  }

  /// Fetches the previous page of records based on [current]'s [CursorPage.prevCursor].
  /// Returns `null` if [current] has no previous page.
  Future<CursorPage<T>?> fetchPrev(
    CursorPage<T> current, {
    String? select,
    List<Filter> where = const [],
    List<Filter>? or,
    Sort? sort,
    String? search,
    int? perPage,
    bool? total,
    bool? distinct,
    String? trashed,
    bool requireSelect = true,
  }) async {
    final cursor = current.prevCursor;
    if (cursor == null || cursor.isEmpty) {
      return null;
    }
    return list(
      select: select,
      where: where,
      or: or,
      sort: sort,
      search: search,
      perPage: perPage,
      cursor: cursor,
      direction: 'prev',
      total: total,
      distinct: distinct,
      trashed: trashed,
      requireSelect: requireSelect,
    );
  }

  /// Creates a [CursorPagination] controller preserving query parameters across pagination calls.
  CursorPagination<T> cursorPagination({
    String? select,
    List<Filter> where = const [],
    List<Filter>? or,
    Sort? sort,
    String? search,
    int? perPage,
    bool? total,
    bool? distinct,
    String? trashed,
    bool requireSelect = true,
  }) => CursorPagination<T>(
    table: this,
    select: select,
    where: where,
    or: or,
    sort: sort,
    search: search,
    perPage: perPage,
    total: total,
    distinct: distinct,
    trashed: trashed,
    requireSelect: requireSelect,
  );
}

/// Boundary controller for cursor pagination preserving filters and sort criteria.
class CursorPagination<T> {
  final TableGateway<T> table;
  final String? select;
  final List<Filter> where;
  final List<Filter>? or;
  final Sort? sort;
  final String? search;
  final int? perPage;
  final bool? total;
  final bool? distinct;
  final String? trashed;
  final bool requireSelect;

  const CursorPagination({
    required this.table,
    this.select,
    this.where = const [],
    this.or,
    this.sort,
    this.search,
    this.perPage,
    this.total,
    this.distinct,
    this.trashed,
    this.requireSelect = true,
  });

  /// Fetches the very first page of records.
  Future<CursorPage<T>> firstPage() => table.fetchFirst(
    select: select,
    where: where,
    or: or,
    sort: sort,
    search: search,
    perPage: perPage,
    total: total,
    distinct: distinct,
    trashed: trashed,
    requireSelect: requireSelect,
  );

  /// Fetches the last page of records by inverting sort direction,
  /// then reversing items back to canonical order. Needs a `sort` (see
  /// [TableGateway.fetchLast]).
  Future<CursorPage<T>> lastPage() => table.fetchLast(
    select: select,
    where: where,
    or: or,
    sort: sort,
    search: search,
    perPage: perPage,
    total: total,
    distinct: distinct,
    trashed: trashed,
    requireSelect: requireSelect,
  );

  /// Fetches the next page using [current]. Returns `null` if no next page.
  Future<CursorPage<T>?> nextPage(CursorPage<T> current) => table.fetchNext(
    current,
    select: select,
    where: where,
    or: or,
    sort: sort,
    search: search,
    perPage: perPage,
    total: total,
    distinct: distinct,
    trashed: trashed,
    requireSelect: requireSelect,
  );

  /// Fetches the previous page using [current]. Returns `null` if no previous page.
  Future<CursorPage<T>?> prevPage(CursorPage<T> current) => table.fetchPrev(
    current,
    select: select,
    where: where,
    or: or,
    sort: sort,
    search: search,
    perPage: perPage,
    total: total,
    distinct: distinct,
    trashed: trashed,
    requireSelect: requireSelect,
  );
}

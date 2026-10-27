import '../api_core.dart';
import '../errors.dart';

/// Module providing chunked bulk operations for records.
class BulkModule {
  /// The parent [SpApi] client.
  final SpApi api;

  /// Creates a [BulkModule].
  const BulkModule({required this.api});

  /// Inserts multiple records in chunks of [chunkSize] (default 1000).
  Future<List<Map<String, dynamic>>> create(
    String table,
    List<Map<String, dynamic>> rows, {
    int chunkSize = 1000,
    bool isAsync = false,
  }) async {
    return _executeChunked(
      'POST',
      '$table/bulk/create',
      rows,
      chunkSize: chunkSize,
      isAsync: isAsync,
    );
  }

  /// Updates multiple records in chunks of [chunkSize].
  Future<List<Map<String, dynamic>>> update(
    String table,
    List<Map<String, dynamic>> rows, {
    int chunkSize = 1000,
    bool isAsync = false,
  }) async {
    return _executeChunked(
      'PUT',
      '$table/bulk/update',
      rows,
      chunkSize: chunkSize,
      isAsync: isAsync,
    );
  }

  /// Deletes records by ID in chunks of [chunkSize].
  Future<bool> remove(
    String table,
    List<dynamic> ids, {
    int chunkSize = 1000,
    bool isAsync = false,
  }) async {
    final idObjects = ids.map((id) => {'id': id}).toList();
    await _executeChunked(
      'DELETE',
      '$table/bulk/delete',
      idObjects,
      chunkSize: chunkSize,
      isAsync: isAsync,
    );
    return true;
  }

  /// Restores soft-deleted records by ID in chunks of [chunkSize].
  Future<int> restore(
    String table,
    List<dynamic> ids, {
    int chunkSize = 1000,
    bool isAsync = false,
  }) async {
    final idObjects = ids.map((id) => {'id': id}).toList();
    final results = await _executeChunked(
      'POST',
      '$table/bulk/restore',
      idObjects,
      chunkSize: chunkSize,
      isAsync: isAsync,
    );
    return results.length;
  }

  /// Upserts records matching on natural keys in chunks of [chunkSize].
  Future<List<Map<String, dynamic>>> upsert(
    String table,
    List<Map<String, dynamic>> rows, {
    required List<String> matchOn,
    int chunkSize = 1000,
    bool isAsync = false,
  }) async {
    final query = <String, dynamic>{'match_on': matchOn.join(',')};
    return _executeChunked(
      'POST',
      '$table/bulk/upsert',
      rows,
      queryParameters: query,
      chunkSize: chunkSize,
      isAsync: isAsync,
    );
  }

  Future<List<Map<String, dynamic>>> _executeChunked(
    String method,
    String path,
    List<Map<String, dynamic>> items, {
    Map<String, dynamic>? queryParameters,
    required int chunkSize,
    required bool isAsync,
  }) async {
    final query = Map<String, dynamic>.from(queryParameters ?? {});
    if (isAsync) {
      query['async'] = '1';
    }

    final accumulated = <Map<String, dynamic>>[];
    final chunks = <List<Map<String, dynamic>>>[];

    for (int i = 0; i < items.length; i += chunkSize) {
      final end = (i + chunkSize < items.length) ? i + chunkSize : items.length;
      chunks.add(items.sublist(i, end));
    }

    if (chunks.isEmpty) {
      chunks.add([]);
    }

    for (final chunk in chunks) {
      final res = await api.request(
        method,
        path,
        data: chunk,
        queryParameters: query.isEmpty ? null : query,
      );

      final body = res.data;
      if (isAsync) {
        accumulated.add({'status': 'queued', 'queued': true});
        continue;
      }

      if (body is Map<String, dynamic>) {
        final data = body['data'];
        if (data is List) {
          for (final item in data) {
            if (item is Map<String, dynamic>) {
              accumulated.add(item);
            } else if (item is Map) {
              accumulated.add(Map<String, dynamic>.from(item));
            }
          }
        }
      } else if (body is List) {
        for (final item in body) {
          if (item is Map<String, dynamic>) {
            accumulated.add(item);
          } else if (item is Map) {
            accumulated.add(Map<String, dynamic>.from(item));
          }
        }
      } else {
        throw SpApiError(
          status: 0,
          code: SpApiErrorCode.unknown,
          message: 'Unexpected non-list bulk response',
          body: body,
        );
      }
    }

    return accumulated;
  }
}

/// Represents a page of records retrieved from the SP Laravel API.
class CursorPage<T> {
  /// The deserialized items on the current page.
  final List<T> items;

  /// The cursor to pass to retrieve the next page.
  ///
  /// The backend sends `next_cursor` on every non-empty page, so a non-null
  /// value does not mean more data exists: the real end is an empty page.
  /// Null when the response carries no `next_cursor` (for example offset mode).
  final String? nextCursor;

  /// The cursor to pass to retrieve the previous page.
  final String? prevCursor;

  /// The total number of items if requested via `total: true`.
  final int? total;

  /// Additional metadata returned by the API envelope.
  final Map<String, dynamic> meta;

  /// Whether a [nextCursor] is available. This is not a guarantee that another
  /// page has items: the final page after the last item is returned empty.
  bool get hasMore => nextCursor != null;

  /// Creates a [CursorPage].
  const CursorPage({
    required this.items,
    this.nextCursor,
    this.prevCursor,
    this.total,
    this.meta = const {},
  });

  /// Factory creating [CursorPage] from raw JSON envelope items and metadata.
  ///
  /// [perPage] is unused and kept only for compatibility.
  factory CursorPage.fromResponse({
    required List<dynamic> data,
    required Map<String, dynamic> meta,
    required T Function(Map<String, dynamic>) fromJson,
    required int perPage,
    bool offsetMode = false,
  }) {
    final items = <T>[];
    for (final item in data) {
      if (item is Map<String, dynamic>) {
        items.add(fromJson(item));
      } else if (item is Map) {
        items.add(fromJson(Map<String, dynamic>.from(item)));
      }
    }

    String? next;
    if (!offsetMode) {
      final nextRaw = meta['next_cursor'] ?? meta['nextCursor'];
      if (nextRaw != null) {
        next = nextRaw.toString();
      }
    }

    String? prev;
    final prevRaw = meta['prev_cursor'] ?? meta['prevCursor'];
    if (prevRaw != null) {
      prev = prevRaw.toString();
    }

    int? tot;
    final totalRaw = meta['total'];
    if (totalRaw is int) {
      tot = totalRaw;
    } else if (totalRaw is String) {
      tot = int.tryParse(totalRaw);
    }

    return CursorPage(
      items: items,
      nextCursor: next,
      prevCursor: prev,
      total: tot,
      meta: meta,
    );
  }
}

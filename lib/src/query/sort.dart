/// Sort order direction.
enum Order { asc, desc }

/// Sort specification for queries.
class Sort {
  /// Column or field name to sort by.
  final String field;

  /// Sort direction.
  final Order order;

  /// Creates a sort specification.
  const Sort(this.field, [this.order = Order.asc]);

  /// Returns a new [Sort] with the [order] inverted.
  Sort reversed() => Sort(field, order == Order.asc ? Order.desc : Order.asc);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Sort && other.field == field && other.order == order;

  @override
  int get hashCode => Object.hash(field, order);

  @override
  String toString() => 'Sort($field, ${order.name})';
}

/// Helper constant to opt-out of select requirements per call.
abstract final class Select {
  /// Select all columns.
  static const String all = '*';
}

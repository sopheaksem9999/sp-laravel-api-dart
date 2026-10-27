/// Filter condition for query building.
sealed class Filter {
  const Filter();

  /// Equal operator.
  static Filter eq(String column, Object value) => EqFilter(column, value);

  /// Not equal operator.
  static Filter neq(String column, Object value) => NeqFilter(column, value);

  /// Greater than operator.
  static Filter gt(String column, Object value) => GtFilter(column, value);

  /// Greater than or equal operator.
  static Filter gte(String column, Object value) => GteFilter(column, value);

  /// Less than operator.
  static Filter lt(String column, Object value) => LtFilter(column, value);

  /// Less than or equal operator.
  static Filter lte(String column, Object value) => LteFilter(column, value);

  /// Included in list operator.
  static Filter inList(String column, List<Object> values) =>
      InListFilter(column, values);

  /// Not included in list operator.
  static Filter notInList(String column, List<Object> values) =>
      NotInListFilter(column, values);

  /// Between lower and upper values operator.
  static Filter between(String column, Object lower, Object upper) =>
      BetweenFilter(column, lower, upper);

  /// Not between lower and upper values operator.
  static Filter notBetween(String column, Object lower, Object upper) =>
      NotBetweenFilter(column, lower, upper);

  /// Case-sensitive SQL LIKE operator.
  static Filter like(String column, Object value) => LikeFilter(column, value);

  /// Case-insensitive SQL ILIKE operator.
  static Filter ilike(String column, Object value) =>
      IlikeFilter(column, value);

  /// Negated SQL LIKE operator.
  static Filter notLike(String column, Object value) =>
      NotLikeFilter(column, value);

  /// Negated SQL ILIKE operator.
  static Filter notIlike(String column, Object value) =>
      NotIlikeFilter(column, value);

  /// Substring contains operator.
  static Filter contains(String column, Object value) =>
      ContainsFilter(column, value);

  /// Substring starts with operator.
  static Filter startsWith(String column, Object value) =>
      StartsWithFilter(column, value);

  /// Substring ends with operator.
  static Filter endsWith(String column, Object value) =>
      EndsWithFilter(column, value);

  /// IS NULL operator.
  static Filter isNull(String column) => IsNullFilter(column);

  /// IS NOT NULL operator.
  static Filter isNotNull(String column) => IsNotNullFilter(column);

  /// EMPTY operator (empty string or array).
  static Filter empty(String column) => EmptyFilter(column);

  /// NOT EMPTY operator.
  static Filter notEmpty(String column) => NotEmptyFilter(column);

  /// Date equality operator.
  static Filter dateEq(String column, Object value) =>
      DateEqFilter(column, value);

  /// Date inequality operator.
  static Filter dateNeq(String column, Object value) =>
      DateNeqFilter(column, value);

  /// Date greater than operator.
  static Filter dateGt(String column, Object value) =>
      DateGtFilter(column, value);

  /// Date greater than or equal operator.
  static Filter dateGte(String column, Object value) =>
      DateGteFilter(column, value);

  /// Date less than operator.
  static Filter dateLt(String column, Object value) =>
      DateLtFilter(column, value);

  /// Date less than or equal operator.
  static Filter dateLte(String column, Object value) =>
      DateLteFilter(column, value);

  /// Negates the inner filter (`not.`).
  static Filter not(Filter inner) => NotFilter(inner);

  /// `any` modifier across multiple values, e.g. `like(any).{a%,b%}`.
  static Filter any(String column, String op, List<Object> values) =>
      AnyModifierFilter(column, op, values);

  /// `all` modifier across multiple values, e.g. `like(all).{%a%,%b%}`.
  static Filter all(String column, String op, List<Object> values) =>
      AllModifierFilter(column, op, values);

  /// Targets multiple columns with a shared condition (`col1,col2=...`).
  static Filter anyOf(List<String> columns, Filter condition) =>
      AnyOfColumnsFilter(columns, condition);

  /// Custom operator (e.g. Postgres-only `fts`, `cs`).
  static Filter custom(String column, String op, Object value) =>
      CustomOpFilter(column, op, value);

  /// Raw wire condition string (e.g. `col=op.value`).
  static Filter raw(String raw) => RawFilter(raw);

  /// Composite OR group: `or=(cond1,cond2,...)`.
  static Filter or(List<Filter> filters) => OrFilter(filters);

  /// Composite AND group: `and=(cond1,cond2,...)`.
  static Filter and(List<Filter> filters) => AndFilter(filters);
}

/// Base class for single-column filters.
sealed class ColumnFilter extends Filter {
  /// The target column or field name.
  final String column;

  /// Creates a [ColumnFilter].
  const ColumnFilter(this.column);
}

/// Equality filter (`col=eq.val`).
class EqFilter extends ColumnFilter {
  final Object value;
  const EqFilter(super.column, this.value);
}

/// Inequality filter (`col=neq.val`).
class NeqFilter extends ColumnFilter {
  final Object value;
  const NeqFilter(super.column, this.value);
}

/// Greater than filter (`col=gt.val`).
class GtFilter extends ColumnFilter {
  final Object value;
  const GtFilter(super.column, this.value);
}

/// Greater than or equal filter (`col=gte.val`).
class GteFilter extends ColumnFilter {
  final Object value;
  const GteFilter(super.column, this.value);
}

/// Less than filter (`col=lt.val`).
class LtFilter extends ColumnFilter {
  final Object value;
  const LtFilter(super.column, this.value);
}

/// Less than or equal filter (`col=lte.val`).
class LteFilter extends ColumnFilter {
  final Object value;
  const LteFilter(super.column, this.value);
}

/// In list filter (`col=in.(val1,val2)`).
class InListFilter extends ColumnFilter {
  final List<Object> values;
  const InListFilter(super.column, this.values);
}

/// Not in list filter (`col=not_in.(val1,val2)`).
class NotInListFilter extends ColumnFilter {
  final List<Object> values;
  const NotInListFilter(super.column, this.values);
}

/// Between filter (`col=between.(low,high)`).
class BetweenFilter extends ColumnFilter {
  final Object lower;
  final Object upper;
  const BetweenFilter(super.column, this.lower, this.upper);
}

/// Not between filter (`col=not_between.(low,high)`).
class NotBetweenFilter extends ColumnFilter {
  final Object lower;
  final Object upper;
  const NotBetweenFilter(super.column, this.lower, this.upper);
}

/// LIKE filter (`col=like.val`).
class LikeFilter extends ColumnFilter {
  final Object value;
  const LikeFilter(super.column, this.value);
}

/// ILIKE filter (`col=ilike.val`).
class IlikeFilter extends ColumnFilter {
  final Object value;
  const IlikeFilter(super.column, this.value);
}

/// NOT LIKE filter (`col=not_like.val`).
class NotLikeFilter extends ColumnFilter {
  final Object value;
  const NotLikeFilter(super.column, this.value);
}

/// NOT ILIKE filter (`col=not_ilike.val`).
class NotIlikeFilter extends ColumnFilter {
  final Object value;
  const NotIlikeFilter(super.column, this.value);
}

/// Contains filter (`col=contains.val`).
class ContainsFilter extends ColumnFilter {
  final Object value;
  const ContainsFilter(super.column, this.value);
}

/// Starts with filter (`col=starts_with.val`).
class StartsWithFilter extends ColumnFilter {
  final Object value;
  const StartsWithFilter(super.column, this.value);
}

/// Ends with filter (`col=ends_with.val`).
class EndsWithFilter extends ColumnFilter {
  final Object value;
  const EndsWithFilter(super.column, this.value);
}

/// IS NULL filter (`col=is.null`).
class IsNullFilter extends ColumnFilter {
  const IsNullFilter(super.column);
}

/// IS NOT NULL filter (`col=is_not.null`).
class IsNotNullFilter extends ColumnFilter {
  const IsNotNullFilter(super.column);
}

/// Empty filter (`col=empty.true`).
class EmptyFilter extends ColumnFilter {
  const EmptyFilter(super.column);
}

/// Not empty filter (`col=not_empty.true`).
class NotEmptyFilter extends ColumnFilter {
  const NotEmptyFilter(super.column);
}

/// Date equality filter (`col=date_eq.val`).
class DateEqFilter extends ColumnFilter {
  final Object value;
  const DateEqFilter(super.column, this.value);
}

/// Date inequality filter (`col=date_neq.val`).
class DateNeqFilter extends ColumnFilter {
  final Object value;
  const DateNeqFilter(super.column, this.value);
}

/// Date GT filter (`col=date_gt.val`).
class DateGtFilter extends ColumnFilter {
  final Object value;
  const DateGtFilter(super.column, this.value);
}

/// Date GTE filter (`col=date_gte.val`).
class DateGteFilter extends ColumnFilter {
  final Object value;
  const DateGteFilter(super.column, this.value);
}

/// Date LT filter (`col=date_lt.val`).
class DateLtFilter extends ColumnFilter {
  final Object value;
  const DateLtFilter(super.column, this.value);
}

/// Date LTE filter (`col=date_lte.val`).
class DateLteFilter extends ColumnFilter {
  final Object value;
  const DateLteFilter(super.column, this.value);
}

/// Negation filter wrapper (`col=not.<op>.val`).
class NotFilter extends Filter {
  final Filter inner;
  const NotFilter(this.inner);
}

/// `any` modifier filter (`col=op(any).{v1,v2}`).
class AnyModifierFilter extends ColumnFilter {
  final String op;
  final List<Object> values;
  const AnyModifierFilter(super.column, this.op, this.values);
}

/// `all` modifier filter (`col=op(all).{v1,v2}`).
class AllModifierFilter extends ColumnFilter {
  final String op;
  final List<Object> values;
  const AllModifierFilter(super.column, this.op, this.values);
}

/// Targets multiple columns with a shared condition.
class AnyOfColumnsFilter extends Filter {
  final List<String> columns;
  final Filter condition;
  const AnyOfColumnsFilter(this.columns, this.condition);
}

/// Custom operator filter.
class CustomOpFilter extends ColumnFilter {
  final String op;
  final Object value;
  const CustomOpFilter(super.column, this.op, this.value);
}

/// Raw condition string.
class RawFilter extends Filter {
  final String raw;
  const RawFilter(this.raw);
}

/// Composite OR filter group.
class OrFilter extends Filter {
  final List<Filter> filters;
  const OrFilter(this.filters);
}

/// Composite AND filter group.
class AndFilter extends Filter {
  final List<Filter> filters;
  const AndFilter(this.filters);
}

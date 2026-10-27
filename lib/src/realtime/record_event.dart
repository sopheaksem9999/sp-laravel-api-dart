/// Action performed in a [RecordEvent].
///
/// [unknown] is used when the payload has no recognised `action`
/// (for example non-record events such as `courier_location.updated`).
enum RecordAction { created, updated, deleted, restored, upserted, unknown }

/// Broadcast event emitted when a record is mutated on the backend.
class RecordEvent {
  /// The database table name (e.g. `videos`).
  final String table;

  /// The mutation action.
  final RecordAction action;

  /// The record data payload (or batch summary for upserted).
  final Map<String, dynamic> record;

  /// The associated tenant identifier, or null if global.
  final String? tenantId;

  /// The timestamp of the mutation.
  final DateTime timestamp;

  /// The broadcast event name (e.g. `order.updated`), or empty if unknown.
  final String eventName;

  /// The full payload exactly as broadcast.
  final Map<String, dynamic> raw;

  /// Whether the payload is a record event (has a string `table` and a map
  /// `record`). False for custom events such as `courier_location.updated`.
  final bool isRecord;

  /// Creates a [RecordEvent].
  const RecordEvent({
    required this.table,
    required this.action,
    required this.record,
    this.tenantId,
    required this.timestamp,
    this.eventName = '',
    this.raw = const {},
    this.isRecord = true,
  });

  /// Factory creating [RecordEvent] from JSON payload.
  factory RecordEvent.fromJson(
    Map<String, dynamic> json, {
    String eventName = '',
  }) {
    final rawAction = json['action']?.toString() ?? '';
    RecordAction act;
    switch (rawAction) {
      case 'created':
        act = RecordAction.created;
      case 'updated':
        act = RecordAction.updated;
      case 'deleted':
        act = RecordAction.deleted;
      case 'restored':
        act = RecordAction.restored;
      case 'upserted':
        act = RecordAction.upserted;
      default:
        act = RecordAction.unknown;
    }

    DateTime ts;
    final rawTs = json['timestamp'];
    if (rawTs is String) {
      ts = DateTime.tryParse(rawTs)?.toUtc() ?? DateTime.now().toUtc();
    } else {
      ts = DateTime.now().toUtc();
    }

    final rawRecord = json['record'];
    final recordMap = rawRecord is Map<String, dynamic>
        ? rawRecord
        : (rawRecord is Map
              ? Map<String, dynamic>.from(rawRecord)
              : <String, dynamic>{});

    return RecordEvent(
      table: json['table']?.toString() ?? '',
      action: act,
      record: recordMap,
      tenantId: json['tenant_id']?.toString(),
      timestamp: ts,
      eventName: eventName,
      raw: json,
      isRecord: json['table'] is String && json['record'] is Map,
    );
  }
}

/// Normalizes a tenant channel name, handling `private-` prefixing and `global` fallback.
String normalizeTenantChannel(dynamic tenantId) {
  if (tenantId == null) {
    return 'private-tenant.global';
  }

  final s = tenantId.toString().trim();
  if (s.isEmpty || s == '0') {
    return 'private-tenant.global';
  }

  if (s.startsWith('private-')) {
    return s;
  }

  if (s.startsWith('tenant.')) {
    return 'private-$s';
  }

  return 'private-tenant.$s';
}

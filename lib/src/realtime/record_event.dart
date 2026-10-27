/// Action performed in a [RecordEvent].
enum RecordAction { created, updated, deleted, restored, upserted }

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

  /// Creates a [RecordEvent].
  const RecordEvent({
    required this.table,
    required this.action,
    required this.record,
    this.tenantId,
    required this.timestamp,
  });

  /// Factory creating [RecordEvent] from JSON payload.
  factory RecordEvent.fromJson(Map<String, dynamic> json) {
    final rawAction = json['action']?.toString() ?? 'created';
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
        act = RecordAction.created;
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

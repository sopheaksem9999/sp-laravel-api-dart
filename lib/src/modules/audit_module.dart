import '../api_core.dart';
import '../table_gateway.dart';

/// Module for reading audit logs and statistics.
class AuditModule {
  /// The parent [SpApi] client.
  final SpApi api;

  /// Creates an [AuditModule].
  const AuditModule({required this.api});

  /// Table gateway for the `sp_audit_logs` table.
  TableGateway<Map<String, dynamic>> get logs =>
      api.table('sp_audit_logs', fromJson: (m) => m);

  /// Retrieves aggregate audit statistics.
  Future<Map<String, dynamic>> stats({
    String? startDate,
    String? endDate,
    dynamic userId,
    String? entityType,
    String? event,
  }) async {
    final query = <String, dynamic>{
      if (startDate != null) 'start_date': startDate,
      if (endDate != null) 'end_date': endDate,
      if (userId != null) 'user_id': userId.toString(),
      if (entityType != null) 'entity_type': entityType,
      if (event != null) 'event': event,
    };

    final res = await api.request(
      'GET',
      'sp_audit_logs/rpc/stats',
      queryParameters: query,
    );

    final data = res.data;
    if (data is Map<String, dynamic>) {
      if (data.containsKey('data') && data['data'] is Map<String, dynamic>) {
        return data['data'] as Map<String, dynamic>;
      }
      return data;
    }
    return {};
  }

  /// Retrieves timeline history for a specific entity field.
  Future<List<Map<String, dynamic>>> fieldTimeline(
    String entityType,
    dynamic entityId,
    String field, {
    int? limit,
  }) async {
    final query = <String, dynamic>{
      'entity_type': entityType,
      'entity_id': entityId.toString(),
      'field': field,
      if (limit != null) 'limit': limit.toString(),
    };

    final res = await api.request(
      'GET',
      'sp_audit_logs/rpc/field-timeline',
      queryParameters: query,
    );

    final data = res.data;
    if (data is Map<String, dynamic> && data['data'] is List) {
      return (data['data'] as List).cast<Map<String, dynamic>>();
    } else if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }
}

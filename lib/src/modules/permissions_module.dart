import '../api_core.dart';
import '../table_gateway.dart';

/// Module for role and permission management.
class PermissionsModule {
  /// The parent [SpApi] client.
  final SpApi api;

  /// Creates a [PermissionsModule].
  const PermissionsModule({required this.api});

  /// Table gateway for the `sp_roles` table.
  TableGateway<Map<String, dynamic>> get roles =>
      api.table('sp_roles', fromJson: (m) => m);

  /// Table gateway for the `sp_permissions` table.
  TableGateway<Map<String, dynamic>> get permissions =>
      api.table('sp_permissions', fromJson: (m) => m);

  /// Assigns permissions to a role via nested write.
  Future<Map<String, dynamic>> assign(
    dynamic roleId,
    List<dynamic> permissionIds,
  ) async {
    final res = await api.request(
      'PUT',
      'sp_roles/$roleId',
      data: {'permissions': permissionIds},
    );
    final data = res.data;
    if (data is Map<String, dynamic>) {
      if (data['data'] is Map<String, dynamic>) {
        return data['data'] as Map<String, dynamic>;
      }
      return data;
    }
    return {};
  }

  /// Detaches permissions from a role via nested write with `_delete: true`.
  Future<Map<String, dynamic>> detach(
    dynamic roleId,
    List<dynamic> permissionIds,
  ) async {
    final detachList = permissionIds
        .map((id) => <String, dynamic>{'id': id, '_delete': true})
        .toList();
    final res = await api.request(
      'PUT',
      'sp_roles/$roleId',
      data: {'permissions': detachList},
    );
    final data = res.data;
    if (data is Map<String, dynamic>) {
      if (data['data'] is Map<String, dynamic>) {
        return data['data'] as Map<String, dynamic>;
      }
      return data;
    }
    return {};
  }
}

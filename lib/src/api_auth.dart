/// Supplies authentication headers and an unauthorized recovery hook.
class ApiAuth {
  /// Asynchronously resolves headers to add to outgoing requests (e.g. `Authorization`).
  final Future<Map<String, String>> Function() headers;

  /// Hook called once when a 401 Unauthorized response is received.
  ///
  /// Should return `true` if recovery/refresh was successful and the request
  /// should be retried once with fresh headers.
  final Future<bool> Function() handleUnauthorized;

  /// Creates an [ApiAuth] contract.
  const ApiAuth({required this.headers, required this.handleUnauthorized});
}

/// Tenant configuration provider.
class TenantConfig {
  /// Header name sent to identify the tenant. Defaults to `X-Tenant-ID`.
  final String header;

  /// Function returning the current tenant ID or null if unselected.
  final String? Function() value;

  /// Creates a [TenantConfig].
  const TenantConfig({this.header = 'X-Tenant-ID', required this.value});
}

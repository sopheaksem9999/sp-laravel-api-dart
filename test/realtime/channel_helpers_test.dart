import 'package:sp_laravel_api/realtime.dart';
import 'package:test/test.dart';

void main() {
  group('Channel Helpers', () {
    test('normalizeTenantChannel formats valid tenant ID', () {
      expect(normalizeTenantChannel('42'), equals('private-tenant.42'));
      expect(normalizeTenantChannel(42), equals('private-tenant.42'));
      expect(
        normalizeTenantChannel('tenant_abc'),
        equals('private-tenant.tenant_abc'),
      );
    });

    test('normalizeTenantChannel prevents double private- prefixing', () {
      expect(
        normalizeTenantChannel('private-tenant.42'),
        equals('private-tenant.42'),
      );
      expect(
        normalizeTenantChannel('private-tenant.global'),
        equals('private-tenant.global'),
      );
    });

    test('normalizeTenantChannel maps empty or 0 to global', () {
      expect(normalizeTenantChannel(null), equals('private-tenant.global'));
      expect(normalizeTenantChannel(''), equals('private-tenant.global'));
      expect(normalizeTenantChannel('   '), equals('private-tenant.global'));
      expect(normalizeTenantChannel(0), equals('private-tenant.global'));
      expect(normalizeTenantChannel('0'), equals('private-tenant.global'));
    });
  });
}

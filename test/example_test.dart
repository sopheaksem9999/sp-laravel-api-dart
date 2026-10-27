import 'package:test/test.dart';
import '../example/main.dart';

void main() {
  test('example Invoice model parses JSON cleanly', () {
    final invoice = Invoice.fromJson({
      'id': 100,
      'number': 'INV-999',
      'total': 450.5,
    });

    expect(invoice.id, equals(100));
    expect(invoice.number, equals('INV-999'));
    expect(invoice.total, equals(450.5));
    expect(useNewApiClient, isTrue);
    expect(useNewRealtimeClient, isTrue);
  });
}

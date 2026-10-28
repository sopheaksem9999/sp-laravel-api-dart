import 'package:test/test.dart';

import 'until.dart';

void main() {
  test('until returns once the condition holds', () async {
    var n = 0;
    await until(() => ++n >= 3);
    expect(n, 3);
  });

  test('until fails with the default message after the timeout', () async {
    await expectLater(
      until(() => false, timeout: const Duration(milliseconds: 20)),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'message',
          'condition not met in 0:00:00.020000',
        ),
      ),
    );
  });

  test('until names the reason in its failure message', () async {
    await expectLater(
      until(
        () => false,
        timeout: const Duration(milliseconds: 20),
        reason: 'the client reconnects',
      ),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'message',
          'condition not met in 0:00:00.020000: the client reconnects',
        ),
      ),
    );
  });
}

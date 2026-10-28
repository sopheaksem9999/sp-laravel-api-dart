import 'dart:async';

import 'package:test/test.dart';

/// Waits for [ok] to become true, polling every 5 ms.
///
/// [ok] is a synchronous condition: it is re-evaluated on every poll and must
/// not return a Future.
///
/// Use this instead of a fixed `Future.delayed` when a test needs state that
/// a pending operation produces. Fails the test after [timeout].
Future<void> until(
  bool Function() ok, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

import 'dart:async';

import 'package:test/test.dart';

/// Waits for [ok] to become true, polling every 5 ms.
///
/// [ok] is a synchronous condition: it is re-evaluated on every poll and must
/// not return a Future.
///
/// Use this instead of a fixed `Future.delayed` when a test needs state that
/// a pending operation produces. Fails the test after [timeout]; the failure
/// message names [reason] when one is given.
Future<void> until(
  bool Function() ok, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        reason == null
            ? 'condition not met in $timeout'
            : 'condition not met in $timeout: $reason',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

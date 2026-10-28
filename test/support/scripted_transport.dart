import 'dart:async';
import 'dart:convert';

import 'package:sp_laravel_api/realtime.dart';

/// A scriptable [RealtimeTransport] that behaves like [WebSocketTransport]:
/// [close] does not emit [onDone]; only a server-side drop ([drop]) does.
class ScriptedTransport implements RealtimeTransport {
  final _incoming = StreamController<String>.broadcast();
  final _done = StreamController<void>.broadcast();

  /// Every frame passed to [send], in order.
  final List<String> sent = [];

  /// Number of [connect] calls.
  int connectCount = 0;

  /// Number of [close] calls.
  int closeCount = 0;

  /// Number of upcoming [connect] calls that fail.
  int failConnects = 0;

  /// When true, a failing [connect] throws synchronously instead of
  /// returning a failed future.
  bool failSynchronously = false;

  /// When false, [connect] sends no `connection_established`; call
  /// [establish].
  bool autoEstablish = true;

  /// When true, each `pusher:subscribe` is confirmed like a real server.
  bool autoConfirm = true;

  /// When true, each `pusher:ping` is answered with a `pusher:pong`.
  bool answerPings = true;

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Stream<void> get onDone => _done.stream;

  @override
  Future<void> connect(Uri uri) {
    connectCount++;
    if (failConnects > 0) {
      failConnects--;
      final error = StateError('connect refused #$connectCount');
      if (failSynchronously) throw error;
      return Future<void>.error(error);
    }
    if (autoEstablish) Future.microtask(establish);
    return Future<void>.value();
  }

  /// Sends `pusher:connection_established` with socket id `<connectCount>.1`.
  void establish() => _incoming.add(
    jsonEncode({
      'event': 'pusher:connection_established',
      'data': jsonEncode({
        'socket_id': '$connectCount.1',
        'activity_timeout': 120,
      }),
    }),
  );

  @override
  void send(String data) {
    sent.add(data);
    final frame = PusherFrame.parse(data);
    if (frame.event == 'pusher:subscribe' && autoConfirm) {
      final channel = (frame.data as Map)['channel'] as String;
      Future.microtask(() => confirm(channel));
    } else if (frame.event == 'pusher:ping' && answerPings) {
      Future.microtask(
        () => _incoming.add(jsonEncode({'event': 'pusher:pong', 'data': '{}'})),
      );
    }
  }

  /// Sends `pusher_internal:subscription_succeeded` for [channel].
  void confirm(String channel) => _incoming.add(
    jsonEncode({
      'event': 'pusher_internal:subscription_succeeded',
      'channel': channel,
      'data': '{}',
    }),
  );

  /// Number of sent frames with [event] (and [channel], when given).
  int framesSent(String event, [String? channel]) => sent.where((raw) {
    final frame = PusherFrame.parse(raw);
    if (frame.event != event) return false;
    return channel == null || (frame.data as Map)['channel'] == channel;
  }).length;

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCount++;
  }

  /// Simulates the server closing the socket.
  void drop() => _done.add(null);
}

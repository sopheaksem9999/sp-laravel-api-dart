import 'dart:async';

/// Abstract transport contract for WebSocket and realtime connections.
///
/// `SpRealtime.subscribe` waits for the server's confirmation, so custom
/// implementations and test fakes must deliver
/// `pusher_internal:subscription_succeeded` on [incoming] for each
/// `pusher:subscribe` sent through [send] (a real Pusher server does), or
/// `subscribe` times out.
abstract interface class RealtimeTransport {
  /// Opens a connection to [uri].
  Future<void> connect(Uri uri);

  /// Transmits raw data frame over the wire.
  void send(String data);

  /// Stream of incoming text frames from the server.
  Stream<String> get incoming;

  /// Stream signaling that the connection has closed.
  Stream<void> get onDone;

  /// Closes the underlying connection.
  Future<void> close([int? code, String? reason]);
}

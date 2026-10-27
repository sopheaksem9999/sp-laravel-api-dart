import 'dart:async';

/// Abstract transport contract for WebSocket and realtime connections.
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

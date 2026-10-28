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

  /// Stream signaling that the server or the network closed the connection.
  ///
  /// Never emitted for a connection closed with [close].
  Stream<void> get onDone;

  /// Closes the underlying connection.
  ///
  /// Must not emit [onDone] for the connection it closes, not even later:
  /// cancel the stream subscription first, as [WebSocketTransport] does.
  /// `SpRealtime` handles the loss of a connection it closes itself and may
  /// already be connecting again; [onDone] is one shared stream, so a late
  /// event would tear down the new connection.
  Future<void> close([int? code, String? reason]);
}

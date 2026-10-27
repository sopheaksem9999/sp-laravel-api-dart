import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'transport.dart';

/// Production [RealtimeTransport] backed by `package:web_socket_channel`.
class WebSocketTransport implements RealtimeTransport {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  final _incomingController = StreamController<String>.broadcast();
  final _doneController = StreamController<void>.broadcast();

  @override
  Stream<String> get incoming => _incomingController.stream;

  @override
  Stream<void> get onDone => _doneController.stream;

  @override
  Future<void> connect(Uri uri) async {
    await close();

    final channel = WebSocketChannel.connect(uri);
    _channel = channel;

    await channel.ready;

    _subscription = channel.stream.listen(
      (dynamic message) {
        if (message is String) {
          _incomingController.add(message);
        } else if (message != null) {
          _incomingController.add(message.toString());
        }
      },
      onError: (dynamic error) {
        if (!_doneController.isClosed) {
          _doneController.add(null);
        }
      },
      onDone: () {
        if (!_doneController.isClosed) {
          _doneController.add(null);
        }
      },
      cancelOnError: false,
    );
  }

  @override
  void send(String data) {
    _channel?.sink.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    await _subscription?.cancel();
    _subscription = null;

    if (_channel != null) {
      await _channel!.sink.close(code, reason);
      _channel = null;
    }
  }

  /// Disposes this transport and closes internal stream controllers.
  Future<void> dispose() async {
    await close();
    await _incomingController.close();
    await _doneController.close();
  }
}

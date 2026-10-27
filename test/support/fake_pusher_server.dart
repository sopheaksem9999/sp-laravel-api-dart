import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// In-process fake Pusher/Reverb server for integration testing.
class FakePusherServer {
  final int _requestedPort;
  HttpServer? _server;
  int _counter = 0;

  final Map<String, WebSocket> _sockets = {};
  final Map<String, Set<String>> _socketChannels = {};

  /// Creates a [FakePusherServer] listening on [_requestedPort] (0 for ephemeral port).
  FakePusherServer({int port = 0}) : _requestedPort = port;

  /// The bound port after [start] has completed.
  int get port => _server?.port ?? _requestedPort;

  /// HTTP base URI for API and broadcasting auth requests.
  Uri get httpUri => Uri.parse('http://127.0.0.1:$port');

  /// WebSocket base URI for Pusher connections.
  Uri get wsUri => Uri.parse('ws://127.0.0.1:$port/app/testappkey');

  /// Starts listening for HTTP and WebSocket requests.
  Future<void> start() async {
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      _requestedPort,
    );
    _server!.listen(_handleRequest);
  }

  void _handleRequest(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _handleWebSocket(socket);
      return;
    }

    // Handle broadcasting auth endpoints
    if (request.uri.path.endsWith('/broadcasting/auth')) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'auth': 'testappkey:mocksignature12345678'}));
      await request.response.close();
      return;
    }

    request.response
      ..statusCode = HttpStatus.notFound
      ..write('Not Found');
    await request.response.close();
  }

  void _handleWebSocket(WebSocket socket) {
    _counter++;
    final socketId = '$_counter.${10000 + _counter}';
    _sockets[socketId] = socket;
    _socketChannels[socketId] = <String>{};

    // 1. Connection established frame
    final connFrame = jsonEncode({
      'event': 'pusher:connection_established',
      'data': jsonEncode({'socket_id': socketId, 'activity_timeout': 120}),
    });
    socket.add(connFrame);

    socket.listen(
      (dynamic rawMessage) {
        if (rawMessage is! String) return;
        try {
          final decoded = jsonDecode(rawMessage) as Map<String, dynamic>;
          final event = decoded['event'] as String?;
          final rawData = decoded['data'];

          Map<String, dynamic> data = {};
          if (rawData is Map<String, dynamic>) {
            data = rawData;
          } else if (rawData is String) {
            try {
              data = jsonDecode(rawData) as Map<String, dynamic>;
            } catch (_) {}
          }

          if (event == 'pusher:subscribe') {
            final channel = data['channel'] as String?;
            if (channel != null) {
              _socketChannels[socketId]?.add(channel);
              // Send subscription confirmation
              socket.add(
                jsonEncode({
                  'event': 'pusher_internal:subscription_succeeded',
                  'channel': channel,
                  'data': '{}',
                }),
              );
            }
          } else if (event == 'pusher:ping') {
            socket.add(jsonEncode({'event': 'pusher:pong', 'data': '{}'}));
          }
        } catch (_) {}
      },
      onError: (_) {
        _cleanupSocket(socketId);
      },
      onDone: () {
        _cleanupSocket(socketId);
      },
      cancelOnError: false,
    );
  }

  void _cleanupSocket(String socketId) {
    _sockets.remove(socketId);
    _socketChannels.remove(socketId);
  }

  /// Broadcasts an event to all sockets subscribed to [channel].
  void broadcast(String channel, String event, dynamic data) {
    final payloadData = data is String ? data : jsonEncode(data);
    final frame = jsonEncode({
      'event': event,
      'channel': channel,
      'data': payloadData,
    });

    for (final entry in _sockets.entries) {
      final sId = entry.key;
      final socket = entry.value;
      if (_socketChannels[sId]?.contains(channel) ?? false) {
        socket.add(frame);
      }
    }
  }

  /// Abruptly closes the WebSocket connection corresponding to [socketId].
  void simulateSocketDeath(String socketId) {
    final socket = _sockets.remove(socketId);
    _socketChannels.remove(socketId);
    socket?.close(WebSocketStatus.goingAway, 'Abrupt termination');
  }

  /// Stops the server and closes all active sockets.
  Future<void> stop() async {
    for (final socket in _sockets.values) {
      await socket.close(WebSocketStatus.normalClosure);
    }
    _sockets.clear();
    _socketChannels.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

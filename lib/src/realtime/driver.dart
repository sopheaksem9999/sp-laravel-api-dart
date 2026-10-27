import '../../sp_laravel_api.dart';

/// Configuration driver representing a target Laravel broadcasting server.
class Driver {
  /// The WebSocket host address (e.g. `ws.example.com` or `127.0.0.1`).
  final String host;

  /// The WebSocket port (e.g. 443, 8080, 6001).
  final int port;

  /// The Pusher/broadcaster app key.
  final String appKey;

  /// Whether to connect using TLS (`wss://`) or plaintext (`ws://`).
  final bool useTls;

  /// Path prefix for the WebSocket endpoint. Defaults to `'/app'`.
  final String path;

  /// Creates a [Driver] configuration.
  const Driver({
    required this.host,
    required this.port,
    required this.appKey,
    this.useTls = true,
    this.path = '/app',
  });

  /// Factory preset for Laravel Reverb servers.
  factory Driver.reverb({
    required String host,
    required int port,
    required String appKey,
    bool useTls = true,
  }) => Driver(
    host: host,
    port: port,
    appKey: appKey,
    useTls: useTls,
    path: '/app',
  );

  /// Factory preset for hosted Pusher Channels (`ws-<cluster>.pusher.com:443`).
  factory Driver.pusher({
    required String appKey,
    required String cluster,
    bool useTls = true,
  }) => Driver(
    host: 'ws-$cluster.pusher.com',
    port: 443,
    appKey: appKey,
    useTls: useTls,
    path: '/app',
  );

  /// Factory preset for Soketi servers.
  factory Driver.soketi({
    required String host,
    required int port,
    required String appKey,
    bool useTls = false,
  }) => Driver(
    host: host,
    port: port,
    appKey: appKey,
    useTls: useTls,
    path: '/app',
  );

  /// Factory preset for Ably Pusher-compatible endpoints (`realtime-pusher.ably.io:443`).
  factory Driver.ably({required String appKey, bool useTls = true}) => Driver(
    host: 'realtime-pusher.ably.io',
    port: 443,
    appKey: appKey,
    useTls: useTls,
    path: '/app',
  );

  /// Custom driver configuration for self-hosted or proxy setups.
  factory Driver.custom({
    required String host,
    required int port,
    required String appKey,
    String path = '/app',
    bool useTls = true,
  }) => Driver(
    host: host,
    port: port,
    appKey: appKey,
    useTls: useTls,
    path: path,
  );

  /// Generates the Pusher protocol connection URI including query parameters.
  Uri toUri() {
    final scheme = useTls ? 'wss' : 'ws';
    final cleanPath = path.replaceAll(RegExp(r'^/+|/+$'), '');
    final uriPath = cleanPath.isEmpty ? '/$appKey' : '/$cleanPath/$appKey';

    return Uri(
      scheme: scheme,
      host: host,
      port: port,
      path: uriPath,
      queryParameters: {
        'protocol': '7',
        'client': 'sp_laravel_api',
        'version': packageVersion,
        'flash': 'false',
      },
    );
  }
}

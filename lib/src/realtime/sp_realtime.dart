import 'dart:async';
import 'package:dio/dio.dart';
import '../api_auth.dart';
import '../errors.dart';
import 'driver.dart';
import 'pusher_framing.dart';
import 'record_event.dart';
import 'transport.dart';
import 'websocket_transport.dart';

class _SubscriptionIntent {
  final int id;
  final String channel;
  final Set<String>? events;
  final void Function(RecordEvent) onEvent;

  _SubscriptionIntent({
    required this.id,
    required this.channel,
    this.events,
    required this.onEvent,
  });
}

/// Realtime client connecting to Laravel broadcasting services via the Pusher protocol.
class SpRealtime {
  /// Base API endpoint for broadcasting authentication (e.g. `https://example.com/api/v1`).
  final Uri apiBaseUrl;

  /// Target broadcasting server configuration.
  final Driver driver;

  /// Function providing the current bearer token for channel authentication.
  final Future<String> Function() tokenProvider;

  /// Optional auth seam hook for refreshing tokens on 401 responses.
  final ApiAuth? auth;

  /// The underlying transport connection.
  final RealtimeTransport _transport;

  /// The Dio instance used for `/broadcasting/auth`.
  final Dio dio;

  /// Inactivity interval after which a `pusher:ping` is transmitted.
  final Duration activityTimeout;

  /// Timeout after sending ping before connection is assumed dead.
  final Duration pongTimeout;

  /// Delay before automatically attempting to reconnect after an unexpected disconnect.
  final Duration reconnectDelay;

  String? _socketId;
  Future<void>? _connectingFuture;
  StreamSubscription<String>? _incomingSub;
  StreamSubscription<void>? _doneSub;

  int _nextSubId = 0;
  final Map<String, List<_SubscriptionIntent>> _intents = {};
  final Set<String> _confirmedChannels = {};

  final List<void Function()> _disconnectCallbacks = [];
  final List<Future<void> Function()> _recoveryCallbacks = [];

  Timer? _activityTimer;
  Timer? _pongTimer;
  Timer? _reconnectTimer;
  bool _isDisposed = false;
  bool _reconnecting = false;
  bool _manualDisconnect = false;
  DateTime? _pausedAt;
  bool _isOffline = false;

  /// Signals that the application or page has paused or moved to the background.
  void onAppPaused() {
    _pausedAt = DateTime.now();
  }

  /// Signals that the application or page has resumed to the foreground.
  ///
  /// Runs a health check and triggers immediate reconnect if stale or disconnected.
  void onAppResumed({bool? forceStale}) {
    final now = DateTime.now();
    final wasStale =
        forceStale ??
        (_pausedAt != null &&
            now.difference(_pausedAt!) > const Duration(seconds: 30));
    _pausedAt = null;

    if (!isConnected || wasStale || !isHealthy) {
      if (!_isOffline) {
        connect();
      }
    }
  }

  /// Signals network connectivity transitions.
  ///
  /// When [online] is false, suspends reconnect attempts to conserve resources.
  /// When [online] is true, triggers an immediate reconnect attempt if disconnected.
  void onNetworkChanged(bool online) {
    _isOffline = !online;
    if (online) {
      if (!isConnected) {
        connect();
      }
    }
  }

  /// Creates a new [SpRealtime] instance.
  SpRealtime({
    required this.apiBaseUrl,
    required this.driver,
    required this.tokenProvider,
    this.auth,
    RealtimeTransport? transport,
    Dio? dio,
    this.activityTimeout = const Duration(seconds: 120),
    this.pongTimeout = const Duration(seconds: 30),
    this.reconnectDelay = const Duration(milliseconds: 100),
  }) : _transport = transport ?? WebSocketTransport(),
       dio = dio ?? Dio();

  /// Whether the WebSocket connection is open and handshake is complete.
  bool get isConnected => _socketId != null;

  /// Current Pusher socket ID assigned by the server, or null if disconnected.
  String? get socketId => _socketId;

  /// Whether the connection is connected and keepalive health check is passing.
  bool get isHealthy => isConnected && _pongTimer == null;

  /// Establishes the realtime connection, returning only once handshake is complete.
  Future<void> connect() {
    if (_isDisposed) {
      throw StateError('Cannot connect a disposed SpRealtime client.');
    }
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    if (isConnected) {
      return Future.value();
    }
    if (_connectingFuture != null) {
      return _connectingFuture!;
    }

    final completer = Completer<void>();
    _connectingFuture = completer.future;

    _setupListeners(completer);
    _transport.connect(driver.toUri()).catchError((Object err) {
      if (!completer.isCompleted) {
        completer.completeError(err);
      }
    });

    return _connectingFuture!;
  }

  void _setupListeners(Completer<void> connectCompleter) {
    _incomingSub?.cancel();
    _doneSub?.cancel();

    _incomingSub = _transport.incoming.listen((raw) {
      _resetActivityTimer();
      _handleIncomingMessage(raw, connectCompleter);
    });

    _doneSub = _transport.onDone.listen((_) {
      _handleDisconnect();
    });
  }

  void _handleIncomingMessage(String raw, Completer<void> connectCompleter) {
    final frame = PusherFrame.parse(raw);

    switch (frame.event) {
      case 'pusher:connection_established':
        final data = frame.data;
        if (data is Map<String, dynamic>) {
          _socketId = data['socket_id']?.toString();
        } else if (data is Map) {
          _socketId = data['socket_id']?.toString();
        }

        _resetActivityTimer();
        if (!connectCompleter.isCompleted) {
          connectCompleter.complete();
        }
        _connectingFuture = null;

        // Rejoin existing channel intents if reconnecting
        if (_intents.isNotEmpty) {
          _rejoinChannels();
        }

      case 'pusher:ping':
        _transport.send(PusherFrame.pong().toJsonString());

      case 'pusher:pong':
        _pongTimer?.cancel();
        _pongTimer = null;

      case 'pusher_internal:subscription_succeeded':
        if (frame.channel != null) {
          _confirmedChannels.add(frame.channel!);
          _checkRecoveryComplete();
        }

      case 'pusher:error':
      // Handle error frames gracefully

      default:
        // Broadcasted record events: {table}.{action}
        _dispatchBroadcastEvent(frame);
    }
  }

  void _dispatchBroadcastEvent(PusherFrame frame) {
    final channel = frame.channel;
    if (channel == null) return;

    final listeners = _intents[channel];
    if (listeners == null || listeners.isEmpty) return;

    RecordEvent event;
    if (frame.data is Map<String, dynamic>) {
      event = RecordEvent.fromJson(frame.data as Map<String, dynamic>);
    } else if (frame.data is Map) {
      event = RecordEvent.fromJson(
        Map<String, dynamic>.from(frame.data as Map),
      );
    } else {
      // Parse table and action from event name
      final parts = frame.event.split('.');
      final table = parts.isNotEmpty ? parts.first : '';
      event = RecordEvent(
        table: table,
        action: RecordAction.created,
        record: {},
        timestamp: DateTime.now().toUtc(),
      );
    }

    for (final intent in List.of(listeners)) {
      if (intent.events == null || intent.events!.contains(frame.event)) {
        intent.onEvent(event);
      }
    }
  }

  void _handleDisconnect() {
    _socketId = null;
    _confirmedChannels.clear();
    _connectingFuture = null;
    _activityTimer?.cancel();
    _pongTimer?.cancel();

    for (final callback in List.of(_disconnectCallbacks)) {
      callback();
    }

    if (!_isDisposed && !_isOffline && !_manualDisconnect) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(reconnectDelay, () {
        if (!_isDisposed && !_isOffline && !isConnected) {
          connect().catchError((_) {});
        }
      });
    }
  }

  Future<void> _rejoinChannels() async {
    _reconnecting = true;
    final channels = List.of(_intents.keys);

    for (final channel in channels) {
      if (_intents[channel]?.isNotEmpty ?? false) {
        try {
          await _sendSubscribe(channel);
        } catch (_) {
          // Bounded retry will be picked up by health check
        }
      }
    }
  }

  void _checkRecoveryComplete() {
    if (!_reconnecting) return;

    final neededChannels = _intents.keys
        .where((c) => _intents[c]?.isNotEmpty ?? false)
        .toSet();
    if (_confirmedChannels.containsAll(neededChannels)) {
      _reconnecting = false;
      for (final callback in List.of(_recoveryCallbacks)) {
        callback();
      }
    }
  }

  /// Subscribes to [channel] and listens for incoming record events.
  ///
  /// Returns an unsubscribe cancellation callback function.
  Future<void Function()> subscribe(
    String channel, {
    Set<String>? events,
    required void Function(RecordEvent event) onEvent,
  }) async {
    if (!isConnected) {
      await connect();
    }

    final id = ++_nextSubId;
    final intent = _SubscriptionIntent(
      id: id,
      channel: channel,
      events: events,
      onEvent: onEvent,
    );

    final isFirstForChannel =
        !_intents.containsKey(channel) || _intents[channel]!.isEmpty;
    _intents.putIfAbsent(channel, () => []).add(intent);

    if (isFirstForChannel) {
      await _sendSubscribe(channel);
    }

    return () => _unsubscribe(channel, id);
  }

  Future<void> _sendSubscribe(String channel) async {
    String? authSignature;

    if (channel.startsWith('private-') || channel.startsWith('presence-')) {
      authSignature = await _authorizeChannel(channel);
    }

    final frame = PusherFrame.subscribe(channel: channel, auth: authSignature);
    _transport.send(frame.toJsonString());
  }

  Future<String> _authorizeChannel(String channel) async {
    final cleanBase = apiBaseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final authUrl = '$cleanBase/broadcasting/auth';

    for (int attempt = 0; ; attempt++) {
      final token = await tokenProvider();
      final headers = <String, dynamic>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      };

      try {
        final res = await dio.post<dynamic>(
          authUrl,
          data: {'channel_name': channel, 'socket_id': _socketId ?? ''},
          options: Options(headers: headers),
        );

        final data = res.data;
        if (data is Map<String, dynamic> && data['auth'] != null) {
          return data['auth'].toString();
        }
        throw SpApiError(
          status: 0,
          code: SpApiErrorCode.unknown,
          message: 'Invalid /broadcasting/auth response',
          body: data,
        );
      } on DioException catch (dioErr) {
        final res = dioErr.response;
        if (res?.statusCode == 401 && attempt == 0 && auth != null) {
          final refreshed = await auth!.handleUnauthorized();
          if (refreshed) {
            continue;
          }
        }
        if (res != null) {
          throw SpApiError.fromResponse(res);
        }
        throw SpApiError(
          status: 0,
          code: SpApiErrorCode.network,
          message: dioErr.message ?? 'Channel authorization network failure',
        );
      }
    }
  }

  void _unsubscribe(String channel, int intentId) {
    final list = _intents[channel];
    if (list == null) return;

    list.removeWhere((i) => i.id == intentId);
    if (list.isEmpty) {
      _intents.remove(channel);
      _confirmedChannels.remove(channel);
      if (isConnected) {
        final frame = PusherFrame.unsubscribe(channel: channel);
        _transport.send(frame.toJsonString());
      }
    }
  }

  void _resetActivityTimer() {
    _activityTimer?.cancel();
    _activityTimer = Timer(activityTimeout, _sendPing);
  }

  void _sendPing() {
    if (!isConnected) return;
    _transport.send(PusherFrame.ping().toJsonString());
    _pongTimer?.cancel();
    _pongTimer = Timer(pongTimeout, () {
      // Socket died silently: missing pong
      _transport.close(4200, 'Ping timeout');
    });
  }

  /// Registers a callback notified when the connection drops.
  void onDisconnected(void Function() callback) {
    _disconnectCallbacks.add(callback);
  }

  /// Registers a callback called once when connection recovers and all channels re-authorized.
  void onRecovered(Future<void> Function() callback) {
    _recoveryCallbacks.add(callback);
  }

  /// Manually disconnects from the broadcasting server and stops auto-reconnect.
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _transport.close();
    _handleDisconnect();
  }

  /// Closes the connection and releases all resources.
  Future<void> dispose() async {
    _isDisposed = true;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _activityTimer?.cancel();
    _pongTimer?.cancel();
    await _incomingSub?.cancel();
    await _doneSub?.cancel();
    await _transport.close();
    _intents.clear();
    _confirmedChannels.clear();
    _disconnectCallbacks.clear();
    _recoveryCallbacks.clear();
  }
}

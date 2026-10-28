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

  /// Maximum time [subscribe] waits for `pusher_internal:subscription_succeeded`.
  final Duration subscribeTimeout;

  /// Maximum number of attempts to re-subscribe a channel after a reconnect.
  final int subscribeAttempts;

  /// Initial delay between re-subscribe attempts (doubles, capped at 5 s).
  final Duration subscribeBackoff;

  /// Called once when a channel could not be re-subscribed after a reconnect
  /// despite [subscribeAttempts] attempts.
  final void Function(String channel, Object error)? onSubscribeFailed;

  String? _socketId;

  /// The connect attempt in flight (before `connection_established`), or null.
  Completer<void>? _connectAttempt;

  /// Consecutive failed connect attempts; reset once a connection is
  /// established. Drives the reconnect backoff.
  int _connectFailures = 0;
  StreamSubscription<String>? _incomingSub;
  StreamSubscription<void>? _doneSub;

  int _nextSubId = 0;
  final Map<String, List<_SubscriptionIntent>> _intents = {};
  final Set<String> _confirmedChannels = {};
  final Map<String, Completer<void>> _pendingSubscribes = {};
  final Set<String> _failedRejoins = {};
  int _connectionEpoch = 0;

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
        _reconnectNow();
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
        _reconnectNow();
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
    this.subscribeTimeout = const Duration(seconds: 10),
    this.subscribeAttempts = 3,
    this.subscribeBackoff = const Duration(milliseconds: 300),
    this.onSubscribeFailed,
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
    _reconnectTimer = null;
    if (isConnected) {
      return Future.value();
    }
    final inFlight = _connectAttempt;
    if (inFlight != null) {
      return inFlight.future;
    }

    final attempt = Completer<void>();
    _connectAttempt = attempt;

    _setupListeners(attempt);
    // Future.sync: a transport that throws synchronously is a failed attempt
    // too, not a stuck one.
    Future.sync(() => _transport.connect(driver.toUri())).catchError(
      (Object error, StackTrace stack) => _connectFailed(attempt, error, stack),
    );

    return attempt.future;
  }

  /// Ends [attempt] with [error] and schedules a retry. Ignored when the
  /// attempt was already ended (disconnect, dispose or an early close).
  void _connectFailed(
    Completer<void> attempt,
    Object error, [
    StackTrace? stack,
  ]) {
    if (!identical(_connectAttempt, attempt)) return;
    _connectAttempt = null;
    _connectFailures++;
    attempt.completeError(error, stack);
    _scheduleReconnect();
  }

  /// Connects from an internal trigger (timer, resume, online event). The
  /// error is handled here: a failed attempt schedules its own retry.
  void _reconnectNow() {
    connect().ignore();
  }

  /// Schedules a reconnect after [reconnectDelay], doubled per consecutive
  /// failed attempt up to 5 s (or [reconnectDelay] when it is longer),
  /// unless the client is offline, manually disconnected or disposed.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_isDisposed || _isOffline || _manualDisconnect) return;
    _reconnectTimer = Timer(_nextReconnectDelay(), () {
      _reconnectTimer = null;
      if (!_isDisposed && !_isOffline && !_manualDisconnect && !isConnected) {
        _reconnectNow();
      }
    });
  }

  Duration _nextReconnectDelay() {
    const ceiling = Duration(seconds: 5);
    final cap = reconnectDelay > ceiling ? reconnectDelay : ceiling;
    var delay = reconnectDelay;
    for (var i = 0; i < _connectFailures && delay < cap; i++) {
      delay *= 2;
    }
    return delay > cap ? cap : delay;
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
        // A handshake for an attempt already ended by disconnect(), dispose()
        // or an early close must not bring the connection back.
        if (!identical(_connectAttempt, connectCompleter)) return;
        final data = frame.data;
        if (data is Map<String, dynamic>) {
          _socketId = data['socket_id']?.toString();
        } else if (data is Map) {
          _socketId = data['socket_id']?.toString();
        }

        _connectAttempt = null;
        _connectFailures = 0;
        _connectionEpoch++;
        _resetActivityTimer();
        connectCompleter.complete();

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
          final channel = frame.channel!;
          // A confirmation for a channel nobody is subscribed to (an abandoned
          // attempt arriving late) must not mark it confirmed.
          if (_intents[channel]?.isNotEmpty ?? false) {
            _confirmedChannels.add(channel);
          }
          _failedRejoins.remove(channel);
          final pending = _pendingSubscribes.remove(channel);
          if (pending != null && !pending.isCompleted) pending.complete();
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
      event = RecordEvent.fromJson(
        frame.data as Map<String, dynamic>,
        eventName: frame.event,
      );
    } else if (frame.data is Map) {
      event = RecordEvent.fromJson(
        Map<String, dynamic>.from(frame.data as Map),
        eventName: frame.event,
      );
    } else {
      // Parse table and action from event name
      final parts = frame.event.split('.');
      final table = parts.isNotEmpty ? parts.first : '';
      event = RecordEvent(
        table: table,
        action: RecordAction.unknown,
        record: {},
        timestamp: DateTime.now().toUtc(),
        eventName: frame.event,
        raw: const {},
        isRecord: false,
      );
    }

    for (final intent in List.of(listeners)) {
      if (intent.events == null || intent.events!.contains(frame.event)) {
        intent.onEvent(event);
      }
    }
  }

  void _handleDisconnect() {
    final wasConnected = _socketId != null;
    final attempt = _connectAttempt;
    _socketId = null;
    _connectAttempt = null;
    _connectionEpoch++;
    _confirmedChannels.clear();
    _failedRejoins.clear();
    _activityTimer?.cancel();
    _pongTimer?.cancel();

    if (attempt != null) {
      // Closed before `connection_established`: the attempt failed.
      _connectFailures++;
      attempt.completeError(
        const SpApiError(
          status: 0,
          code: SpApiErrorCode.network,
          message: 'Realtime connection closed before it was established',
        ),
      );
    }

    // Only an established connection can be lost.
    if (wasConnected) {
      for (final callback in List.of(_disconnectCallbacks)) {
        callback();
      }
    }

    _scheduleReconnect();
  }

  Completer<void> _pendingFor(String channel) {
    return _pendingSubscribes.putIfAbsent(channel, () {
      final completer = Completer<void>();
      // Waiters observe the future; do not report an unobserved error.
      completer.future.ignore();
      return completer;
    });
  }

  void _failPending(String channel, Object error, [StackTrace? stack]) {
    final pending = _pendingSubscribes.remove(channel);
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, stack);
    }
  }

  Future<void> _rejoinChannels() async {
    _reconnecting = true;
    final epoch = _connectionEpoch;
    final channels = _intents.keys
        .where((c) => _intents[c]?.isNotEmpty ?? false)
        .toList();
    // Registered before the first await so a subscriber arriving during the
    // rejoin awaits this confirmation instead of sending a second frame.
    for (final channel in channels) {
      _pendingFor(channel);
    }
    await Future.wait(channels.map((c) => _rejoinChannel(c, epoch)));
  }

  bool _rejoinStale(String channel, int epoch) =>
      _isDisposed ||
      epoch != _connectionEpoch ||
      !isConnected ||
      !(_intents[channel]?.isNotEmpty ?? false);

  Future<void> _rejoinChannel(String channel, int epoch) async {
    final attempts = subscribeAttempts < 1 ? 1 : subscribeAttempts;
    var delay = subscribeBackoff;
    for (var attempt = 1; ; attempt++) {
      try {
        final pending = _pendingFor(channel);
        await _sendSubscribe(channel);
        // Each attempt is bounded: no confirmation in time is a failed attempt.
        try {
          await pending.future.timeout(subscribeTimeout);
        } on TimeoutException {
          throw SpApiError(
            status: 0,
            code: SpApiErrorCode.timeout,
            message:
                'Timed out after ${subscribeTimeout.inMilliseconds} ms waiting '
                'for re-subscription confirmation of "$channel"',
          );
        }
        return;
      } catch (error, stack) {
        if (_rejoinStale(channel, epoch)) return;
        if (attempt >= attempts) {
          _failedRejoins.add(channel);
          _failPending(channel, error, stack);
          onSubscribeFailed?.call(channel, error);
          _checkRecoveryComplete();
          return;
        }
        await Future<void>.delayed(delay);
        delay = delay * 2;
        if (delay > const Duration(seconds: 5)) {
          delay = const Duration(seconds: 5);
        }
        if (_rejoinStale(channel, epoch)) return;
      }
    }
  }

  void _checkRecoveryComplete() {
    if (!_reconnecting) return;

    final neededChannels = _intents.keys
        .where((c) => _intents[c]?.isNotEmpty ?? false)
        .where((c) => !_failedRejoins.contains(c))
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
  /// Completes only after the server confirms the subscription with
  /// `pusher_internal:subscription_succeeded`. Throws [SpApiError] with code
  /// `timeout` when no confirmation arrives within [subscribeTimeout], or the
  /// channel authorization error; in both cases no subscription intent is
  /// left registered. Returns an unsubscribe cancellation callback function.
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

    // Register before sending so an event delivered right after the
    // confirmation is not lost.
    _intents.putIfAbsent(channel, () => []).add(intent);

    if (_confirmedChannels.contains(channel)) {
      return () => _unsubscribe(channel, id);
    }

    Completer<void>? pending = _pendingSubscribes[channel];
    if (pending == null) {
      pending = _pendingFor(channel);
      final owned = pending;
      try {
        await _sendSubscribe(channel);
      } catch (error, stack) {
        if (identical(_pendingSubscribes[channel], owned)) {
          _pendingSubscribes.remove(channel);
        }
        if (!owned.isCompleted) owned.completeError(error, stack);
        _abandon(channel, id, sendUnsubscribe: false);
        rethrow;
      }
    }

    try {
      await pending.future.timeout(subscribeTimeout);
    } on TimeoutException {
      _abandon(channel, id, sendUnsubscribe: true);
      throw SpApiError(
        status: 0,
        code: SpApiErrorCode.timeout,
        message:
            'Timed out after ${subscribeTimeout.inMilliseconds} ms waiting for '
            'subscription confirmation of "$channel"',
      );
    } catch (_) {
      _abandon(channel, id, sendUnsubscribe: false);
      rethrow;
    }
    return () => _unsubscribe(channel, id);
  }

  /// Removes the intent [id] after a failed subscribe. When it was the last
  /// intent of the channel, also drops the pending completer and the channel.
  void _abandon(String channel, int id, {required bool sendUnsubscribe}) {
    final list = _intents[channel];
    if (list == null) return;
    list.removeWhere((i) => i.id == id);
    if (list.isNotEmpty) return;
    _intents.remove(channel);
    _confirmedChannels.remove(channel);
    _failedRejoins.remove(channel);
    _pendingSubscribes.remove(channel);
    if (sendUnsubscribe && isConnected) {
      _transport.send(PusherFrame.unsubscribe(channel: channel).toJsonString());
    }
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
        final code =
            dioErr.type == DioExceptionType.connectionTimeout ||
                dioErr.type == DioExceptionType.receiveTimeout ||
                dioErr.type == DioExceptionType.sendTimeout
            ? SpApiErrorCode.timeout
            : SpApiErrorCode.network;
        throw SpApiError(
          status: 0,
          code: code,
          message: dioErr.message ?? 'Channel authorization network failure',
          cause: dioErr,
          stackTrace: dioErr.stackTrace,
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
      _failedRejoins.remove(channel);
      _failPending(
        channel,
        const SpApiError(
          status: 0,
          code: SpApiErrorCode.unknown,
          message: 'Subscription cancelled before it was confirmed',
        ),
      );
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
    _reconnectTimer = null;
    _connectFailures = 0;
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
    final attempt = _connectAttempt;
    _connectAttempt = null;
    attempt?.completeError(
      const SpApiError(
        status: 0,
        code: SpApiErrorCode.network,
        message: 'Realtime client disposed',
      ),
    );
    await _incomingSub?.cancel();
    await _doneSub?.cancel();
    await _transport.close();
    for (final channel in List.of(_pendingSubscribes.keys)) {
      _failPending(
        channel,
        const SpApiError(
          status: 0,
          code: SpApiErrorCode.network,
          message: 'Realtime client disposed',
        ),
      );
    }
    _intents.clear();
    _confirmedChannels.clear();
    _disconnectCallbacks.clear();
    _recoveryCallbacks.clear();
  }
}

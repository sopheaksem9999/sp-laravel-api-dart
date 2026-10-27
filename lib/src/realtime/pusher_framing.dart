import 'dart:convert';

/// Action to take based on a Pusher WebSocket close code.
enum PusherCloseAction {
  /// Unrecoverable application error (4000-4099). Do not reconnect.
  fatal,

  /// Reconnect after backoff delay (4100-4199 or unexpected disconnect).
  reconnectDelayed,

  /// Reconnect immediately without backoff delay (4200-4299).
  reconnectImmediate,

  /// Clean graceful closure (1000).
  closedNormally,
}

/// Classifies a WebSocket close code into a [PusherCloseAction].
PusherCloseAction classifyPusherCloseCode(int? code) {
  if (code == 1000) {
    return PusherCloseAction.closedNormally;
  }
  if (code != null) {
    if (code >= 4000 && code <= 4099) {
      return PusherCloseAction.fatal;
    }
    if (code >= 4100 && code <= 4199) {
      return PusherCloseAction.reconnectDelayed;
    }
    if (code >= 4200 && code <= 4299) {
      return PusherCloseAction.reconnectImmediate;
    }
  }
  return PusherCloseAction.reconnectDelayed;
}

/// A Pusher wire protocol message frame.
class PusherFrame {
  /// Event identifier (e.g. `pusher:subscribe`, `pusher:connection_established`).
  final String event;

  /// Channel name if this frame targets or originated from a channel.
  final String? channel;

  /// Frame data payload (pre-parsed JSON or raw string).
  final dynamic data;

  /// Creates a [PusherFrame].
  const PusherFrame({required this.event, this.channel, this.data});

  /// Factory parsing a raw wire JSON string into a [PusherFrame].
  ///
  /// Automatically unwraps double-encoded JSON string data payloads.
  factory PusherFrame.parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return PusherFrame(event: '', data: decoded);
    }

    final event = decoded['event']?.toString() ?? '';
    final channel = decoded['channel']?.toString();
    final rawData = decoded['data'];

    dynamic parsedData = rawData;
    if (rawData is String && rawData.isNotEmpty) {
      try {
        final inner = jsonDecode(rawData);
        if (inner is Map || inner is List) {
          parsedData = inner;
        }
      } catch (_) {
        // Keep string verbatim
      }
    }

    return PusherFrame(event: event, channel: channel, data: parsedData);
  }

  /// Factory creating a `pusher:subscribe` frame.
  factory PusherFrame.subscribe({required String channel, String? auth}) =>
      PusherFrame(
        event: 'pusher:subscribe',
        data: {'channel': channel, if (auth != null) 'auth': auth},
      );

  /// Factory creating a `pusher:unsubscribe` frame.
  factory PusherFrame.unsubscribe({required String channel}) =>
      PusherFrame(event: 'pusher:unsubscribe', data: {'channel': channel});

  /// Factory creating a client `pusher:ping` frame.
  factory PusherFrame.ping() =>
      const PusherFrame(event: 'pusher:ping', data: <String, dynamic>{});

  /// Factory creating a client `pusher:pong` response frame.
  factory PusherFrame.pong() =>
      const PusherFrame(event: 'pusher:pong', data: <String, dynamic>{});

  /// Converts this frame to a JSON string for wire transmission.
  String toJsonString() {
    final map = <String, dynamic>{
      'event': event,
      if (channel != null) 'channel': channel,
      'data': data ?? <String, dynamic>{},
    };
    return jsonEncode(map);
  }
}

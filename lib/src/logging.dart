import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'errors.dart';

const String _redacted = '<redacted>';
const int _defaultMaxBody = 2048;
const String _truncMarker = '…[truncated]';
const int _maxIdRunes = 128;
const String _extraKey = 'sp.log';

/// Which requests a [SpLogger] reports.
enum SpLogMode {
  /// Nothing is logged, even for requests that opt in with [SpLog.on].
  off,

  /// Only requests carrying the [SpLog.on] marker are logged (default).
  perRequest,

  /// Every request is logged.
  all,
}

/// Optional, redacted request logging for [SpApi].
///
/// The package never prints anything itself: every attempt produces one
/// [SpLogEntry] handed to [sink]. The sink runs inline, on the request path,
/// so keep it quick. A sink that throws, or returns a failing `Future`, is
/// ignored and never changes the request result.
///
/// Redaction is built in and cannot be switched off. Only the documented keys
/// and header-name patterns are redacted: plain-text and stringified-nested
/// bodies are not scanned, and URL paths and fragments are logged verbatim.
/// The sink may still receive personal data.
class SpLogger {
  /// Receives one entry per HTTP attempt.
  final void Function(SpLogEntry entry) sink;

  /// Which requests are logged. Defaults to [SpLogMode.perRequest].
  final SpLogMode mode;

  /// Longest body kept in an entry, in UTF-16 code units. Defaults to 2048.
  final int maxBodyLength;

  /// Creates a logger delivering entries to [sink].
  const SpLogger({
    required this.sink,
    this.mode = SpLogMode.perRequest,
    this.maxBodyLength = _defaultMaxBody,
  });
}

/// One HTTP attempt, as reported to a [SpLogger] sink.
class SpLogEntry {
  /// Upper-case HTTP method.
  final String method;

  /// Request URL with sensitive query values and credentials redacted.
  final String url;

  /// HTTP status, or `null` when no response was received.
  final int? status;

  /// Time the attempt took.
  final Duration duration;

  /// Sanitised request id from the response, if any.
  final String? requestId;

  /// 1-based attempt number within one `SpApi.request` call.
  final int attempt;

  /// Classified failure, `null` for a successful attempt.
  final SpApiErrorCode? code;

  /// Backend error code (for example 10002), if the response carried one.
  final int? errorCode;

  /// Redacted request headers; only when requested with `SpLog.on(headers: true)`.
  final Map<String, String>? requestHeaders;

  /// Redacted response headers; only when requested.
  final Map<String, String>? responseHeaders;

  /// Redacted, truncated request body; only when requested with `bodies: true`.
  final Object? requestBody;

  /// Redacted, truncated response body; only when requested with `bodies: true`.
  final Object? responseBody;

  /// Creates an entry.
  const SpLogEntry({
    required this.method,
    required this.url,
    required this.status,
    required this.duration,
    required this.requestId,
    required this.attempt,
    this.code,
    this.errorCode,
    this.requestHeaders,
    this.responseHeaders,
    this.requestBody,
    this.responseBody,
  });

  @override
  String toString() {
    final b = StringBuffer('$method $url -> ${status ?? 'no response'} ')
      ..write('${duration.inMilliseconds}ms');
    if (requestId != null) b.write(' rid=$requestId');
    b.write(' attempt=$attempt');
    if (code != null) b.write(' code=${code!.name}');
    if (errorCode != null) b.write(' errorCode=$errorCode');
    return b.toString();
  }
}

/// Per-request logging opt-in, carried in `Options.extra` (never sent as a
/// header or query parameter).
///
/// ```dart
/// table.list(select: 'id', options: SpLog.on(bodies: true));
/// ```
///
/// To combine with other per-request options use [merge], or
/// `options.copyWith(extra: {...?options.extra, ...SpLog.on().extra!})`.
class SpLog {
  SpLog._();

  /// Options marking a request for logging; [headers] and [bodies] add the
  /// redacted headers and bodies to the entry.
  static Options on({bool headers = false, bool bodies = false}) =>
      Options(extra: {_extraKey: _marker(headers, bodies)});

  /// Returns [base] (or fresh options) with the logging marker added, keeping
  /// every other option, including its headers and other `extra` entries.
  static Options merge(
    Options? base, {
    bool headers = false,
    bool bodies = false,
  }) => (base ?? Options()).copyWith(
    extra: {...?base?.extra, _extraKey: _marker(headers, bodies)},
  );

  static Map<String, bool> _marker(bool headers, bool bodies) => {
    'headers': headers,
    'bodies': bodies,
  };
}

// ---------------------------------------------------------------------------
// Redaction (pure functions)
// ---------------------------------------------------------------------------

const _sensitiveKeys = {
  'password',
  'secret',
  'code',
  'otp',
  'jwt',
  'token',
  'apikey',
  'accesstoken',
  'refreshtoken',
};
final _sensitiveSuffix = RegExp(r'(token|secret|password|apikey)$');
const _sensitiveHeaders = {
  'authorization',
  'cookie',
  'set-cookie',
  'x-csrf-token',
};
final _sensitiveHeaderRe = RegExp(
  r'auth|token|key|secret|cookie|session|csrf|xsrf|password|credential',
  caseSensitive: false,
);
const _urlHeaders = {
  'location',
  'content-location',
  'referer',
  'referrer',
  'origin',
};

/// Whether a body or query key is sensitive: lower-cased with `-` and `_`
/// removed it equals a listed key, ends with token/secret/password/apikey, or
/// starts with password.
bool isSensitiveKey(String key) {
  final n = key.toLowerCase().replaceAll(RegExp(r'[-_]'), '');
  return _sensitiveKeys.contains(n) ||
      _sensitiveSuffix.hasMatch(n) ||
      n.startsWith('password');
}

/// Redacts header values by name (case-insensitive), the [tenantHeader] and
/// URL-valued headers. Names keep the case they were given.
Map<String, String> redactHeaders(
  Map<String, dynamic> headers, {
  String? tenantHeader,
}) {
  final tenant = tenantHeader?.toLowerCase();
  final out = <String, String>{};
  headers.forEach((k, v) {
    final n = k.toLowerCase();
    final value = v is Iterable ? v.join(', ') : '$v';
    out[k] =
        _sensitiveHeaders.contains(n) ||
            n == tenant ||
            _sensitiveHeaderRe.hasMatch(n)
        ? _redacted
        : _urlHeaders.contains(n)
        ? redactUrl(value)
        : value;
  });
  return out;
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

bool _isSensitiveQueryKey(String rawKey) {
  final key = _decode(rawKey);
  return isSensitiveKey(key) ||
      key
          .split(RegExp(r'[\[\]]'))
          .any((s) => s.isNotEmpty && isSensitiveKey(s));
}

String _redactQuery(String qs) => qs
    .split('&')
    .map((part) {
      final i = part.indexOf('=');
      return i > 0 && _isSensitiveQueryKey(part.substring(0, i))
          ? '${part.substring(0, i)}=$_redacted'
          : part;
    })
    .join('&');

/// Redacts sensitive query values and credentials in the authority; the path
/// and fragment are kept verbatim.
String redactUrl(String url) {
  final hash = url.indexOf('#');
  final frag = hash < 0 ? '' : url.substring(hash);
  final rest = hash < 0 ? url : url.substring(0, hash);
  final q = rest.indexOf('?');
  final head = (q < 0 ? rest : rest.substring(0, q)).replaceFirstMapped(
    RegExp(r'^([a-z][a-z0-9+.-]*://)[^/?#@]*@', caseSensitive: false),
    (m) => '${m[1]}$_redacted@',
  );
  return q < 0
      ? '$head$frag'
      : '$head?${_redactQuery(rest.substring(q + 1))}$frag';
}

String _truncate(String s, int max) {
  if (s.length <= max) return s;
  var cut = max;
  final last = s.codeUnitAt(cut - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut--;
  return s.substring(0, cut) + _truncMarker;
}

Object? _walk(Object? v) {
  if (v is List) return v.map(_walk).toList();
  if (v is Map) {
    return <String, Object?>{
      for (final e in v.entries)
        '${e.key}': isSensitiveKey('${e.key}') ? _redacted : _walk(e.value),
    };
  }
  return v;
}

String _redactString(String s) {
  final t = s.trimLeft();
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      return jsonEncode(_walk(jsonDecode(s)));
    } catch (_) {
      // not JSON: fall through
    }
  }
  return RegExp(r'^[^\s=&]+=[^\s&]*(&[^\s=&]+=[^\s&]*)*$').hasMatch(s)
      ? _redactQuery(s)
      : s;
}

/// Redacts and bounds a body for a log entry.
///
/// Strings holding JSON are parsed, redacted and re-serialised; url-encoded
/// strings have sensitive values replaced; other strings are only truncated.
/// Maps and lists come back as redacted copies unless their JSON exceeds
/// [max], in which case a truncated string. `Uint8List`/`List<int>` become
/// `<N bytes>`, `FormData` `<multipart>`, streams `<stream>`; none is read.
Object? redactBody(Object? v, {int max = _defaultMaxBody}) {
  if (v is Uint8List) return '<${v.lengthInBytes} bytes>';
  if (v is List<int>) return '<${v.length} bytes>';
  if (v is FormData) return '<multipart>';
  if (v is Stream || v is ResponseBody) return '<stream>';
  if (v is String) return _truncate(_redactString(v), max);
  final r = _walk(v);
  if (r is Map || r is List) {
    final s = jsonEncode(r);
    if (s.length > max) return _truncate(s, max);
  }
  return r;
}

/// Cleans a server-controlled request id: strips C0/DEL/C1 control characters
/// and U+2028/U+2029, caps at 128 code points (never splitting a surrogate
/// pair); `null` when nothing is left.
String? sanitiseRequestId(Object? v) {
  if (v is! String) return null;
  final cleaned = v.replaceAll(
    RegExp('[\u0000-\u001f\u007f-\u009f\u2028\u2029]'),
    '',
  );
  final s = String.fromCharCodes(cleaned.runes.take(_maxIdRunes)).trim();
  return s.isEmpty ? null : s;
}

/// Calls [sink] inline. A throw, or a `Future` the sink returns that fails,
/// is swallowed so the request is never affected.
void deliver(void Function(SpLogEntry) sink, SpLogEntry entry) {
  try {
    final result = (sink as dynamic)(entry);
    if (result is Future) {
      result.then<void>((_) {}, onError: (Object _) {});
    }
  } catch (_) {
    // the sink is the caller's; it must not change the request result
  }
}

// ---------------------------------------------------------------------------
// Per-request session used by SpApi.request
// ---------------------------------------------------------------------------

/// Decides whether this request is logged and returns its emitter; `null`
/// when it is not. Never throws.
SpLogSession? startLog(
  SpLogger logger, {
  required String method,
  required String url,
  required Options? options,
  required Object? body,
  required String? tenantHeader,
}) {
  try {
    final mode = logger.mode;
    final marker = options?.extra?[_extraKey];
    final opted = marker != null;
    if (mode == SpLogMode.off || (mode == SpLogMode.perRequest && !opted)) {
      return null;
    }
    final m = marker is Map ? marker : const <Object?, Object?>{};
    return SpLogSession._(
      logger.sink,
      logger.maxBodyLength >= 1 ? logger.maxBodyLength : _defaultMaxBody,
      method,
      url,
      m['headers'] == true,
      m['bodies'] == true,
      body,
      tenantHeader,
    );
  } catch (_) {
    return null;
  }
}

/// Builds and delivers the entries of one `SpApi.request` call.
class SpLogSession {
  final void Function(SpLogEntry) _sink;
  final int _max;
  final String _method;
  final String _url;
  final bool _headers;
  final bool _bodies;
  final Object? _body;
  final String? _tenantHeader;
  int _attempt = 0;

  SpLogSession._(
    this._sink,
    this._max,
    this._method,
    this._url,
    this._headers,
    this._bodies,
    this._body,
    this._tenantHeader,
  );

  /// Reports one finished attempt. Never throws.
  ///
  /// [res] is the response if one was received, [ro] the Dio request options
  /// of the attempt (for the final URL and sent headers), [err] the
  /// classified error when the attempt failed, [failureCode] the code for a
  /// transport failure (no response).
  void finish(
    Stopwatch sw, {
    Response<dynamic>? res,
    RequestOptions? ro,
    SpApiError? err,
    SpApiErrorCode? failureCode,
  }) {
    _attempt++;
    try {
      var error = err;
      if (error == null && res != null && (res.statusCode ?? 200) >= 400) {
        try {
          error = SpApiError.fromResponse(res, tenantHeader: _tenantHeader);
        } catch (_) {}
      }
      String? rid;
      if (error != null) {
        rid = error.requestId;
      } else if (res != null) {
        final data = res.data;
        final meta = data is Map ? data['meta'] : null;
        final fromMeta = meta is Map ? meta['request_id'] : null;
        rid =
            (fromMeta is String && fromMeta.isNotEmpty ? fromMeta : null) ??
            res.headers.value('x-request-id');
      }
      final url = redactUrl(ro != null ? ro.uri.toString() : _url);
      Map<String, String>? reqHeaders;
      Map<String, String>? resHeaders;
      Object? reqBody;
      Object? resBody;
      if (_headers) {
        if (ro != null) {
          reqHeaders = redactHeaders(ro.headers, tenantHeader: _tenantHeader);
        }
        if (res != null) {
          resHeaders = redactHeaders(
            res.headers.map,
            tenantHeader: _tenantHeader,
          );
        }
      }
      if (_bodies) {
        if (_body != null) {
          reqBody = _safely(() => redactBody(_body, max: _max));
        }
        if (res != null && res.data != null) {
          resBody = _safely(() => redactBody(res.data, max: _max));
        }
      }
      final entry = SpLogEntry(
        method: _method,
        url: url,
        status: res?.statusCode,
        duration: sw.elapsed,
        requestId: sanitiseRequestId(rid),
        attempt: _attempt,
        code: error?.code ?? failureCode,
        errorCode: error?.errorCode,
        requestHeaders: reqHeaders,
        responseHeaders: resHeaders,
        requestBody: reqBody,
        responseBody: resBody,
      );
      deliver(_sink, entry);
    } catch (_) {
      // a logging bug must never change the request result
    }
  }
}

Object? _safely(Object? Function() f) {
  try {
    return f();
  } catch (_) {
    return '<unavailable>';
  }
}

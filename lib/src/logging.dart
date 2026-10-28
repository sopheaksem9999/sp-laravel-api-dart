import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'errors.dart';

const String _redacted = '<redacted>';
const int _defaultMaxBody = 2048;
const String _truncMarker = '…[truncated]';
const int _maxIdRunes = 128;

/// Deepest nesting of lists/maps a body may have; a deeper body is logged as
/// `<unavailable>` as a whole.
const int _maxDepth = 100;
const String _unavailable = '<unavailable>';

/// What a body value that is not plain data (class instance, model with
/// `toJson`, `Set`, other `Iterable`, `Uri`, `DateTime`) becomes.
const String _object = '<object>';

/// A query or fragment value holding a URL is redacted as a URL, at most this
/// many levels deep.
const int _maxUrlDepth = 2;
final _nestedUrl = RegExp(r'^https?://', caseSensitive: false);
const String _extraKey = 'sp.log';

/// Which requests a [SpLogger] reports.
enum SpLogMode {
  /// Nothing is logged, even for requests that opt in with [SpLog.on].
  off,

  /// Only requests carrying the [SpLog.on] marker are logged (default).
  perRequest,

  /// Every request is logged, except those marked with [SpLog.off].
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
/// bodies are not scanned, and URL paths are logged verbatim (fragment
/// `key=value` pairs are redacted like the query). The sink may still receive
/// personal data.
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

  /// Request URL with sensitive query and fragment values, filter groups
  /// naming a sensitive column and credentials redacted.
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
/// [off] keeps one request out of the log, even in [SpLogMode.all] (the
/// equivalent of `log: false` in the JS client):
///
/// ```dart
/// api.request('GET', 'health', options: SpLog.off());
/// ```
///
/// To combine with other per-request options use [merge] (`off: true` for
/// the off marker), or
/// `options.copyWith(extra: {...?options.extra, ...SpLog.on().extra!})`.
class SpLog {
  SpLog._();

  /// Options marking a request for logging; [headers] and [bodies] add the
  /// redacted headers and bodies to the entry.
  static Options on({bool headers = false, bool bodies = false}) =>
      Options(extra: {_extraKey: _marker(headers, bodies)});

  /// Options keeping a request out of the log in every [SpLogMode],
  /// [SpLogMode.all] included.
  static Options off() => Options(extra: {_extraKey: false});

  /// Returns [base] (or fresh options) with the logging marker added, keeping
  /// every other option, including its headers and other `extra` entries.
  /// With [off] the marker is the [SpLog.off] one ([headers] and [bodies] are
  /// then ignored); either marker replaces one already in [base].
  static Options merge(
    Options? base, {
    bool headers = false,
    bool bodies = false,
    bool off = false,
  }) => (base ?? Options()).copyWith(
    extra: {...?base?.extra, _extraKey: off ? false : _marker(headers, bodies)},
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
  'pin',
  'pwd',
  'pass',
  'sig',
  'authorization',
  'cookie',
};
// `credential` is singular on purpose: a `credentials` key holding an object
// is walked, not redacted whole.
final _sensitiveSuffix = RegExp(
  r'(tokens?|secrets?|passwords?|passwd|passphrase|passcode|apikeys?|privatekey|secretkey|clientkey|signingkey|encryptionkey|signature|credential|otp|(otp|verification|auth|mfa|reset|recovery|backup)codes?)$',
);
const _sensitiveHeaders = {
  'authorization',
  'cookie',
  'set-cookie',
  'x-csrf-token',
};
final _sensitiveHeaderRe = RegExp(
  r'auth|token|key|secret|cookie|session|csrf|xsrf|password|credential|signature|pass|otp|jwt|bearer',
  caseSensitive: false,
);
const _urlHeaders = {
  'location',
  'content-location',
  'referer',
  'referrer',
  'origin',
};
// `[^<>]`, not `[^>]`: with many `<` and no `>` the latter rescans to the end
// from every `<` (quadratic).
final _linkUrl = RegExp(r'<([^<>]*)>');
final _refreshUrl = RegExp(r'url\s*=\s*', caseSensitive: false);

/// A PostgREST-style filter group (`or=(...)`, `not.and=(...)`).
final _groupKey = RegExp(r'^(not\.)?(and|or)$');

/// Operator words of the SP API filter syntax (the host's
/// `FilterOperatorCatalog`) and the `not.` prefix. In a filter group item
/// `path.op.value` the dotted segments before the first of these are the
/// column path (`sessions.token`).
const _operators = {
  'not', 'is', 'is_not', 'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', //
  'not_in', 'between', 'not_between', 'like', 'ilike', 'not_like',
  'not_ilike', 'contains', 'starts_with', 'not_starts_with', 'ends_with',
  'not_ends_with', 'regex', 'not_regex', 'match', 'not_match', 'imatch',
  'not_imatch', 'date_eq', 'date_neq', 'date_gt', 'date_gte', 'date_lt',
  'date_lte', 'empty', 'not_empty', 'fts', 'not_fts', 'plfts', 'not_plfts',
  'phfts', 'not_phfts', 'wfts', 'not_wfts', 'cs', 'not_cs', 'cd', 'not_cd',
  'ov', 'not_ov', 'sl', 'not_sl', 'sr', 'not_sr', 'nxl', 'not_nxl', 'nxr',
  'not_nxr', 'adj', 'not_adj',
};

/// The column of an embed filter inside `select` (`rel(cols,col=op.value)`):
/// the text before `=` after the start, a `(` or a `,`.
final _embedColumn = RegExp(r'(?:^|[(,])([^(),=]*)=');
final _keyParts = RegExp(r'[\[\],.]');
final _groupItems = RegExp(r'[(),]');
final _dashOrUnderscore = RegExp(r'[-_]');

/// Whether a body or query key is sensitive. The key is lower-cased with `-`
/// and `_` removed; it is sensitive when it equals a listed key (password,
/// secret, code, otp, jwt, token, apikey, accesstoken, refreshtoken, pin,
/// pwd, pass, sig, authorization, cookie), matches the sensitive suffix
/// (token(s), secret(s), password(s), passwd, passphrase, passcode, apikey(s),
/// privatekey, secretkey, clientkey, signingkey, encryptionkey, signature,
/// credential, otp, or code(s) after otp/verification/auth/mfa/reset/
/// recovery/backup), or starts with password.
bool isSensitiveKey(String key) {
  final n = key.toLowerCase().replaceAll(_dashOrUnderscore, '');
  return _sensitiveKeys.contains(n) ||
      _sensitiveSuffix.hasMatch(n) ||
      n.startsWith('password');
}

/// `Link` holds URLs in `<...>`; `Refresh` holds one after `url=` (or is
/// one); the other URL-valued headers are a URL.
String _redactHeaderValue(String n, String v) {
  if (_urlHeaders.contains(n)) return redactUrl(v);
  if (n == 'link') {
    return v.replaceAllMapped(_linkUrl, (m) => '<${redactUrl(m[1]!)}>');
  }
  if (n == 'refresh') {
    final m = _refreshUrl.firstMatch(v);
    return m == null
        ? redactUrl(v)
        : v.substring(0, m.end) + redactUrl(v.substring(m.end));
  }
  return v;
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
        : _redactHeaderValue(n, value);
  });
  return out;
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  final l = c | 0x20;
  return l >= 0x61 && l <= 0x66 ? l - 0x57 : -1;
}

/// The byte of a `%XX` escape at [i], or -1.
int _escapedByte(String s, int i) {
  if (i + 2 >= s.length || s.codeUnitAt(i) != 0x25) return -1;
  final h = _hexValue(s.codeUnitAt(i + 1));
  final l = _hexValue(s.codeUnitAt(i + 2));
  return h < 0 || l < 0 ? -1 : h * 16 + l;
}

/// Tolerant percent-decoding, identical in JS and Dart: every `%XX` run
/// forming valid UTF-8 is decoded (as `decodeURIComponent` does); an invalid
/// or truncated sequence and raw non-ASCII text are kept as they are, and the
/// rest of the text is still decoded. Linear: each escape is looked at most
/// four times. (`Uri.decodeComponent` throws on raw non-ASCII, which made the
/// whole text fall back to raw.)
String _decode(String s) {
  if (!s.contains('%')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final b = _escapedByte(s, i);
    if (b < 0) {
      final next = s.indexOf('%', i + 1);
      final end = next < 0 ? s.length : next;
      out.write(s.substring(i, end));
      i = end;
      continue;
    }
    if (b < 0x80) {
      out.writeCharCode(b);
      i += 3;
      continue;
    }
    // UTF-8 lead byte: sequence length and the allowed range of the second
    // byte (no overlongs, no surrogates).
    var len = 0;
    var lo = 0x80;
    var hi = 0xbf;
    if (b >= 0xc2 && b <= 0xdf) {
      len = 2;
    } else if (b >= 0xe0 && b <= 0xef) {
      len = 3;
      if (b == 0xe0) {
        lo = 0xa0;
      } else if (b == 0xed) {
        hi = 0x9f;
      }
    } else if (b >= 0xf0 && b <= 0xf4) {
      len = 4;
      if (b == 0xf0) {
        lo = 0x90;
      } else if (b == 0xf4) {
        hi = 0x8f;
      }
    }
    var cp = len == 2 ? b & 0x1f : (len == 3 ? b & 0x0f : b & 0x07);
    var ok = len > 0;
    for (var k = 1; ok && k < len; k++) {
      final c = _escapedByte(s, i + 3 * k);
      if (c < (k == 1 ? lo : 0x80) || c > (k == 1 ? hi : 0xbf)) {
        ok = false;
      } else {
        cp = (cp << 6) | (c & 0x3f);
      }
    }
    if (ok) {
      out.writeCharCode(cp);
      i += 3 * len;
    } else {
      out.write(s.substring(i, i + 3));
      i += 3;
    }
  }
  return out.toString();
}

/// The ECMAScript `\s` class (also Dart's) as code units: TAB to CR, space,
/// U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000,
/// U+FEFF. A test checks it against `RegExp(r'\s')` for every BMP code unit.
bool isSpace(int c) =>
    (c >= 0x09 && c <= 0x0d) ||
    c == 0x20 ||
    c == 0xa0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200a) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202f ||
    c == 0x205f ||
    c == 0x3000 ||
    c == 0xfeff;

/// Removes leading and trailing `\s` characters with two linear scans (a
/// `\s+$` regular expression is quadratic on inner runs of spaces).
String _strip(String s) {
  var a = 0;
  var b = s.length;
  while (a < b && isSpace(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && isSpace(s.codeUnitAt(b - 1))) {
    b--;
  }
  return a == 0 && b == s.length ? s : s.substring(a, b);
}

/// Whether any (trimmed) segment of a column path (`sessions.pin`) is a
/// sensitive key.
bool _isSensitivePath(Iterable<String> segments) =>
    segments.map(_strip).any((s) => s.isNotEmpty && isSensitiveKey(s));

/// A query key is sensitive when it is, or when any part of it split on `[`,
/// `]`, `,` or `.` is: a bracket segment (`user[password]`), an
/// `AnyOfColumnsFilter` column (`api_token,email`) or a relation path segment
/// (`sessions.pin`).
bool _isSensitiveQueryKey(String rawKey) {
  final key = _decode(rawKey);
  return isSensitiveKey(key) || _isSensitivePath(key.split(_keyParts));
}

/// One item of a filter group (`path.op.value`): the dotted segments before
/// the first operator word are the column path, so `sessions.token.eq.x`
/// tests `sessions` and `token` while `status.eq.token` tests only `status`.
/// An item without a dot (a list value, a logic word) is not a condition; one
/// without an operator word is tested whole.
bool _isSensitiveCondition(String item) {
  if (!item.contains('.')) return false;
  final segments = item.split('.').map(_strip).toList();
  final op = segments.indexWhere(_operators.contains);
  return _isSensitivePath(op < 0 ? segments : segments.sublist(0, op));
}

/// A value that embeds a condition on a sensitive column, at any nesting
/// depth: a filter group (`or`, `and`, `not.or`, `not.and`: `path.op.value`
/// items) or a `select` with an embed filter (`rel(cols,path=op.value)`).
bool _isSensitiveEmbedded(String rawKey, String rawValue) {
  final key = _decode(rawKey);
  if (_groupKey.hasMatch(key)) {
    return _decode(rawValue).split(_groupItems).any(_isSensitiveCondition);
  }
  if (key == 'select') {
    return _embedColumn
        .allMatches(_decode(rawValue))
        .any((m) => _isSensitivePath(m[1]!.split('.')));
  }
  return false;
}

/// Applied to a query string and to a fragment: `key=value` parts with a
/// sensitive key, or a value embedding a condition on a sensitive column,
/// lose their value.
String _redactQuery(String qs, int depth) => qs
    .split('&')
    .map((part) {
      final i = part.indexOf('=');
      if (i <= 0) return part;
      final k = part.substring(0, i);
      final v = part.substring(i + 1);
      if (_isSensitiveQueryKey(k) || _isSensitiveEmbedded(k, v)) {
        return '$k=$_redacted';
      }
      if (depth < _maxUrlDepth) {
        // A value holding a URL (a redirect target) is redacted as a URL;
        // kept as it was when nothing changes.
        final url = _decode(v);
        if (_nestedUrl.hasMatch(url)) {
          final r = _redactUrlAt(url, depth + 1);
          if (r != url) return '$k=$r';
        }
      }
      return part;
    })
    .join('&');

/// Redacts sensitive query and fragment values (nested URLs too) and
/// credentials in the authority; the path is kept verbatim.
String redactUrl(String url) => _redactUrlAt(url, 0);

String _redactUrlAt(String url, int depth) {
  final hash = url.indexOf('#');
  final frag = hash < 0
      ? ''
      : '#${_redactQuery(url.substring(hash + 1), depth)}';
  final rest = hash < 0 ? url : url.substring(0, hash);
  final q = rest.indexOf('?');
  final head = (q < 0 ? rest : rest.substring(0, q)).replaceFirstMapped(
    RegExp(r'^([a-z][a-z0-9+.-]*://)[^/?#]*@', caseSensitive: false),
    (m) => '${m[1]}$_redacted@',
  );
  return q < 0
      ? '$head$frag'
      : '$head?${_redactQuery(rest.substring(q + 1), depth)}$frag';
}

String _truncate(String s, int max) {
  if (s.length <= max) return s;
  var cut = max;
  final last = s.codeUnitAt(cut - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut--;
  return s.substring(0, cut) + _truncMarker;
}

/// Thrown by [_walk] past [_maxDepth] nested lists/maps; [redactBody] then
/// returns `<unavailable>`.
class _TooDeep {
  const _TooDeep();
}

/// Only plain data is walked: maps, lists, strings, numbers, booleans and
/// null. Any other object becomes `<object>`, never itself (its `toJson` or
/// `toString` could show a secret).
Object? _walk(Object? v, int depth) {
  if (v == null || v is String || v is num || v is bool) return v;
  if (v is TypedData) return _object;
  if (v is List) {
    if (depth >= _maxDepth) throw const _TooDeep();
    return [for (final x in v) _walk(x, depth + 1)];
  }
  if (v is Map) {
    if (depth >= _maxDepth) throw const _TooDeep();
    return <String, Object?>{
      for (final e in v.entries)
        '${e.key}': isSensitiveKey('${e.key}')
            ? _redacted
            : _walk(e.value, depth + 1),
    };
  }
  return _object;
}

String _redactString(String s) {
  // JSON parsers reject a leading BOM or NBSP, so the text is stripped of
  // `\s` characters (U+FEFF, U+00A0 included).
  final t = _strip(s);
  if (t.startsWith('{') || t.startsWith('[')) {
    // Only a parse failure means "not JSON"; a body too deep to walk must not
    // fall through and be echoed.
    Object? parsed;
    var isJson = true;
    try {
      parsed = jsonDecode(t);
    } on FormatException {
      isJson = false;
    }
    if (isJson) return jsonEncode(_walk(parsed, 0));
  }
  return RegExp(r'^[^\s=&]+=[^\s&]*(&[^\s=&]+=[^\s&]*)*$').hasMatch(s)
      ? _redactQuery(s, 0)
      : s;
}

/// Redacts and bounds a body for a log entry.
///
/// Strings holding JSON are parsed, redacted and re-serialised; url-encoded
/// strings have sensitive values replaced; other strings are only truncated.
/// Maps and lists come back as redacted copies unless their JSON exceeds
/// [max], in which case a truncated string. `Uint8List`/`List<int>` become
/// `<N bytes>`, `FormData` `<multipart>`, streams `<stream>`; none is read.
/// A body nested more than 100 lists/maps deep is `<unavailable>` as a whole.
/// Linear in the size of the body.
Object? redactBody(Object? v, {int max = _defaultMaxBody}) {
  try {
    if (v is Uint8List) return '<${v.lengthInBytes} bytes>';
    if (v is List<int>) return '<${v.length} bytes>';
    if (v is FormData) return '<multipart>';
    if (v is Stream || v is ResponseBody) return '<stream>';
    if (v is String) return _truncate(_redactString(v), max);
    final r = _walk(v, 0);
    if (r is Map || r is List) {
      final s = jsonEncode(r);
      if (s.length > max) return _truncate(s, max);
    }
    return r;
  } on _TooDeep {
    return _unavailable;
  }
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
    if (marker == false) return null; // SpLog.off(): never logged
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
    return _unavailable;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../api_core.dart';
import '../errors.dart';
import 'upload_fields.dart';

/// Module for handling SP attachments, direct and multipart uploads, and URL helpers.
class AttachmentsModule {
  /// S3's minimum size of every part but the last (5 MiB).
  static const int minPartSize = 5 * 1024 * 1024;

  /// Default bytes per part for [uploadMultipart] (8 MiB).
  static const int defaultPartSize = 8 * 1024 * 1024;

  /// Most parts one multipart upload may have.
  static const int maxParts = 10000;

  /// The parent [SpApi] client.
  final SpApi api;

  /// Creates an [AttachmentsModule].
  const AttachmentsModule({required this.api});

  /// Uploads raw file bytes straight to storage through a signed URL.
  ///
  /// Needs `attachments.direct_upload.enabled` on the host. The flow is
  /// `create-upload-url`, a PUT of the bytes to the signed URL (S3 or R2; no
  /// auth or tenant header is sent there) or, on a local disk, the file posted
  /// to `complete-upload` through the API, then `complete-upload` with the
  /// upload token. [folder] is the folder id. [replaceOld], [title],
  /// [caption], [tempTimeoutMinutes] and [tempTimeoutAt] are sent on the final
  /// call with the rules of [upload]; resize options and `asTemp` are form
  /// upload only, so a temporary upload here is `visibility: 'temp_private'`
  /// or `'temp_public'`. Errors never contain the signed URL or the token.
  Future<Map<String, dynamic>> uploadDirect({
    required String filename,
    required List<int> bytes,
    String? folder,
    String? collection,
    String? visibility,
    String? recordType,
    dynamic recordId,
    String? contentType,
    bool? replaceOld,
    String? title,
    String? caption,
    int? tempTimeoutMinutes,
    Object? tempTimeoutAt,
    CancelToken? cancelToken,
  }) async {
    final fields = UploadFieldOptions(
      visibility: visibility,
      recordType: recordType,
      recordId: recordId as Object?,
      collection: collection,
      folderId: folder,
      replaceOld: replaceOld,
      title: title,
      caption: caption,
      tempTimeoutMinutes: tempTimeoutMinutes,
      tempTimeoutAt: tempTimeoutAt,
    );
    checkUploadFields(fields, UploadStrategy.direct);
    final vis = visibility ?? 'private';

    final created = await _call('create-upload-url', {
      'filename': filename,
      if (contentType != null) 'content_type': contentType,
      'visibility': vis,
      if (folder != null) 'folder_id': folder,
    }, cancelToken);
    final uploadKey = created['key'];
    final uploadToken = created['upload_token'];
    final expiresAt = created['expires_at'];
    if (uploadKey == null || uploadToken == null || expiresAt == null) {
      throw SpApiError(
        status: 0,
        code: SpApiErrorCode.unknown,
        message:
            'create-upload-url did not return key, upload_token and expires_at',
      );
    }

    final complete = <String, Object>{
      'key': uploadKey as Object,
      'upload_token': uploadToken as Object,
      'expires_at': expiresAt as Object,
      'filename': filename,
      if (contentType != null) 'content_type': contentType,
      'visibility': vis,
      if (folder != null) 'folder_id': folder,
      if (recordType != null) 'record_type': recordType,
      if (recordId != null) 'record_id': recordId.toString(),
      if (collection != null) 'collection_name': collection,
      ...sharedFields(fields),
    };

    final url = created['upload_url'];
    if (url is String && url.isNotEmpty) {
      await _storagePut(
        url,
        (created['method'] ?? 'PUT').toString(),
        created['headers'],
        bytes,
        cancelToken,
        'direct',
      );
      return _call('complete-upload', complete, cancelToken);
    }

    // Local disk: the backend answers `upload_url: null`; the file is posted
    // to `complete-upload` through the API with the token fields.
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
      for (final e in complete.entries) e.key: e.value.toString(),
    });
    final res = await api.request(
      'POST',
      _path(['complete-upload']),
      data: form,
      options: Options(contentType: 'multipart/form-data'),
      cancelToken: cancelToken,
    );
    return _unwrapMap(res.data);
  }

  /// Uploads a large file to S3 or R2 in parts.
  ///
  /// Needs `attachments.direct_upload.enabled` on the host. The flow is
  /// `create-multipart-upload`, then for every part `sign-multipart-part` and
  /// a PUT to the signed URL (no auth or tenant header; the response must carry
  /// an `ETag` header, so the bucket CORS policy must expose it on the web),
  /// then `complete-multipart-upload`. [stream] is cut into exact [partSize]
  /// parts (the last is smaller; an empty stream is one empty part), at most
  /// [concurrency] parts in flight, signed right before their PUT. On any
  /// failure the upload is aborted once (best effort) and the original error is
  /// rethrown. [partSize] is at least 5 MiB ([minPartSize]); at most
  /// [maxParts] parts. [totalBytes] is optional: with it [onProgress] gets the
  /// total, without it the final call reports `loaded == total`. [folder] is
  /// the folder id. [replaceOld], [title], [caption], [tempTimeoutMinutes] and
  /// [tempTimeoutAt] go out on the final call with the rules of [upload];
  /// resize options and `asTemp` are form upload only. Resume is not
  /// supported. Errors never contain a signed URL, the token or the key.
  Future<Map<String, dynamic>> uploadMultipart({
    required String filename,
    required Stream<List<int>> stream,
    int? totalBytes,
    String? folder,
    String? collection,
    String? visibility,
    String? recordType,
    dynamic recordId,
    String? contentType,
    int partSize = defaultPartSize,
    int concurrency = 4,
    void Function(int loaded, int? total)? onProgress,
    bool? replaceOld,
    String? title,
    String? caption,
    int? tempTimeoutMinutes,
    Object? tempTimeoutAt,
    CancelToken? cancelToken,
  }) async {
    final fields = UploadFieldOptions(
      visibility: visibility,
      recordType: recordType,
      recordId: recordId as Object?,
      collection: collection,
      folderId: folder,
      replaceOld: replaceOld,
      title: title,
      caption: caption,
      tempTimeoutMinutes: tempTimeoutMinutes,
      tempTimeoutAt: tempTimeoutAt,
    );
    checkUploadFields(fields, UploadStrategy.multipart);
    if (partSize < minPartSize) {
      throw _uploadError(
        'partSize must be at least $minPartSize bytes (5 MiB)',
      );
    }
    if (concurrency < 1) {
      throw _uploadError('concurrency must be a positive integer');
    }
    if (totalBytes != null && (totalBytes / partSize).ceil() > maxParts) {
      throw _uploadError('more than $maxParts parts; use a larger partSize');
    }
    final vis = visibility ?? 'private';

    final created = await _call('create-multipart-upload', {
      'filename': filename,
      if (contentType != null) 'content_type': contentType,
      'visibility': vis,
      if (folder != null) 'folder_id': folder,
    }, cancelToken);
    if (created['key'] == null ||
        created['upload_id'] == null ||
        created['upload_token'] == null ||
        created['expires_at'] == null) {
      throw SpApiError(
        status: 0,
        code: SpApiErrorCode.unknown,
        message:
            'create-multipart-upload did not return key, upload_id, '
            'upload_token and expires_at',
      );
    }
    // The token is bound to the key, the disk (from the visibility), the
    // tenant, the upload id and the expiry: send them identically every time.
    final tokenFields = <String, Object>{
      'key': created['key'] as Object,
      'upload_id': created['upload_id'] as Object,
      'upload_token': created['upload_token'] as Object,
      'expires_at': created['expires_at'] as Object,
    };

    final done = <int, String>{};
    final active = <Future<void>>{};
    Object? failure;
    StackTrace? failureStack;
    var loaded = 0;

    Future<void> uploadPart(_Part p) async {
      if (failure != null) return;
      final signed = await _call('sign-multipart-part', {
        ...tokenFields,
        'part_number': p.number,
        'visibility': vis,
      }, cancelToken);
      final url = signed['url'];
      if (url is! String || url.isEmpty) {
        throw SpApiError(
          status: 0,
          code: SpApiErrorCode.unknown,
          message:
              'sign-multipart-part did not return a url for part ${p.number}',
        );
      }
      final res = await _storagePut(
        url,
        'PUT',
        signed['headers'],
        p.bytes,
        cancelToken,
        'part ${p.number}',
      );
      final etag = res.headers.value('etag');
      if (etag == null || etag.isEmpty) {
        throw SpApiError(
          status: res.statusCode ?? 0,
          code: SpApiErrorCode.unknown,
          message:
              'Storage response for part ${p.number} has no ETag header; the '
              'bucket CORS policy must expose it (ExposeHeaders: ETag)',
        );
      }
      if (failure != null) return;
      done[p.number] = etag;
      loaded += p.bytes.length;
      onProgress?.call(loaded, totalBytes);
    }

    try {
      var count = 0;
      await for (final p in _cutParts(stream, partSize)) {
        if (failure != null) break;
        if (cancelToken != null && cancelToken.isCancelled) {
          throw DioException(
            requestOptions: RequestOptions(path: 'multipart-upload'),
            type: DioExceptionType.cancel,
            message: 'Request was cancelled',
          );
        }
        if (++count > maxParts) {
          throw _uploadError(
            'more than $maxParts parts; use a larger partSize',
          );
        }
        while (active.length >= concurrency) {
          await Future.any(active);
        }
        late Future<void> task;
        task = uploadPart(p)
            .catchError((Object e, StackTrace st) {
              failure ??= e;
              failureStack ??= st;
            })
            .whenComplete(() => active.remove(task));
        active.add(task);
      }
      await Future.wait(active);
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      if (totalBytes == null) onProgress?.call(loaded, loaded);

      final numbers = done.keys.toList()..sort();
      return await _call('complete-multipart-upload', {
        ...tokenFields,
        'parts': [
          for (final n in numbers) {'part_number': n, 'etag': done[n]},
        ],
        'filename': filename,
        'visibility': vis,
        if (folder != null) 'folder_id': folder,
        if (recordType != null) 'record_type': recordType,
        if (recordId != null) 'record_id': recordId.toString(),
        if (collection != null) 'collection_name': collection,
        ...sharedFields(fields),
      }, cancelToken);
    } catch (_) {
      // Best-effort cleanup; it never masks the original error.
      try {
        await _call('abort-multipart-upload', {
          ...tokenFields,
          'visibility': vis,
        }, null).timeout(const Duration(seconds: 10));
      } catch (_) {
        // ignored
      }
      rethrow;
    }
  }

  /// One JSON `POST sp_attachments/{rpcPrefix}/{fn}`; resolves the unwrapped data map.
  Future<Map<String, dynamic>> _call(
    String fn,
    Map<String, dynamic> body,
    CancelToken? cancelToken,
  ) async {
    final res = await api.request(
      'POST',
      _path([fn]),
      data: body,
      cancelToken: cancelToken,
    );
    return _unwrapMap(res.data);
  }

  Map<String, dynamic> _unwrapMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      final data = raw['data'];
      if (data is Map<String, dynamic>) return data;
      return raw;
    }
    return <String, dynamic>{};
  }

  /// Headers the backend asks the client to send to storage. Values may be
  /// lists; `Host` and `Content-Length` are set by the transport.
  Map<String, String> _storageHeaders(Object? h) {
    final out = <String, String>{};
    if (h is! Map) return out;
    h.forEach((k, v) {
      final name = k.toString();
      final lower = name.toLowerCase();
      if (lower == 'host' || lower == 'content-length') return;
      if (v is List) {
        out[name] = v.map((e) => e.toString()).join(', ');
      } else if (v != null) {
        out[name] = v.toString();
      }
    });
    return out;
  }

  /// Sends [data] to a signed storage URL with the dio client directly, so no
  /// auth, tenant or request-id header goes along. A signed URL is a
  /// credential: it never ends up in an error.
  Future<Response<dynamic>> _storagePut(
    String url,
    String method,
    Object? headers,
    List<int> data,
    CancelToken? cancelToken,
    String what,
  ) async {
    final Response<dynamic> res;
    try {
      res = await api.dio.request<dynamic>(
        url,
        data: Uint8List.fromList(data),
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: _storageHeaders(headers),
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      final timeout =
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout;
      throw SpApiError(
        status: 0,
        code: timeout ? SpApiErrorCode.timeout : SpApiErrorCode.network,
        message:
            'Storage upload ($what) failed: '
            '${timeout ? 'timeout' : 'network error'}',
      );
    }
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw SpApiError(
        status: status,
        code: status >= 500 ? SpApiErrorCode.server : SpApiErrorCode.unknown,
        message: 'Storage upload ($what) failed with status $status',
      );
    }
    return res;
  }

  /// `sp_attachments/{rpcPrefix}/...segments`, each segment URL-encoded. An
  /// empty, `.` or `..` segment throws `SpApiError(unencodableValue)`: a URL
  /// parser would normalise it into a different route (an authenticated call
  /// would then reach it), so nothing is sent.
  String _path(List<Object> segments) {
    final prefix = api.rpcPrefix.replaceAll(RegExp(r'^/+|/+$'), '');
    return [
      'sp_attachments',
      if (prefix.isNotEmpty) prefix,
      ...segments.map((s) {
        final text = s.toString();
        if (text.isEmpty || text == '.' || text == '..') {
          throw SpApiError(
            status: 0,
            code: SpApiErrorCode.unencodableValue,
            message:
                'attachments: a path segment cannot be empty, "." or ".." '
                '(got ${jsonEncode(text)})',
          );
        }
        return Uri.encodeComponent(text);
      }),
    ].join('/');
  }

  /// Uploads a file with one `multipart/form-data` POST (`rpc/upload`).
  ///
  /// Exactly one of [bytes] or [filePath] is required. Returns the attachment
  /// record. For large files use [uploadMultipart].
  ///
  /// Besides the file the route takes: [recordType] and [recordId] (link the
  /// new attachment), [collection] (link collection, `default` when omitted),
  /// [folderId], [title], [caption], [replaceOld] (replaces what is linked in
  /// the same [collection] of that record, deletes old files nothing else
  /// links to, and needs [recordType] and [recordId]), [tempTimeoutMinutes] or
  /// [tempTimeoutAt] (a `String` sent unchanged or a `DateTime` sent as UTC
  /// ISO-8601; the server drops the offset, so a UTC value is only right when
  /// the host's `app.timezone` is UTC; both only for a temporary upload) and,
  /// form upload only, [width], [height], [fit] (`crop` or `contain`),
  /// [sizeName] and [asTemp].
  ///
  /// When [visibility] is null the form sends `private`, unless [asTemp] is
  /// true (then the host picks its temporary default). Throws
  /// `SpApiError(unencodableValue)` before any request when the server would
  /// silently ignore or override an option (for example [asTemp] with a
  /// `private` visibility, a timeout without a temporary upload, [replaceOld]
  /// without a record, [sizeName] with [width]). The server's own ranges are
  /// not checked here: its 422 reports them.
  Future<Map<String, dynamic>> upload({
    List<int>? bytes,
    String? filePath,
    required String filename,
    String? visibility,
    String? recordType,
    Object? recordId,
    String? collection,
    String? folderId,
    bool? replaceOld,
    String? title,
    String? caption,
    int? tempTimeoutMinutes,
    Object? tempTimeoutAt,
    int? width,
    int? height,
    String? fit,
    String? sizeName,
    bool? asTemp,
  }) async {
    if ((bytes == null) == (filePath == null)) {
      throw ArgumentError(
        'Provide exactly one of bytes or filePath to AttachmentsModule.upload.',
      );
    }
    final fields = UploadFieldOptions(
      visibility: visibility,
      recordType: recordType,
      recordId: recordId,
      collection: collection,
      folderId: folderId,
      replaceOld: replaceOld,
      title: title,
      caption: caption,
      tempTimeoutMinutes: tempTimeoutMinutes,
      tempTimeoutAt: tempTimeoutAt,
      width: width,
      height: height,
      fit: fit,
      sizeName: sizeName,
      asTemp: asTemp,
    );
    checkUploadFields(fields, UploadStrategy.form);

    final part = bytes != null
        ? MultipartFile.fromBytes(bytes, filename: filename)
        : await MultipartFile.fromFile(filePath!, filename: filename);
    final form = FormData.fromMap({
      'file': part,
      if (visibility != null)
        'visibility': visibility
      else if (asTemp != true)
        'visibility': 'private',
      if (recordType != null) 'record_type': recordType,
      if (recordId != null) 'record_id': recordId.toString(),
      if (collection != null) 'collection_name': collection,
      for (final e in {
        ...sharedFields(fields),
        ...formOnlyFields(fields),
      }.entries)
        e.key: e.value.toString(),
    });
    final res = await api.request(
      'POST',
      _path(['upload']),
      data: form,
      options: Options(contentType: 'multipart/form-data'),
    );
    final raw = res.data;
    if (raw is Map<String, dynamic>) {
      final data = raw['data'];
      if (data is Map<String, dynamic>) return data;
      return raw;
    }
    return <String, dynamic>{};
  }

  /// Links an existing attachment to a record
  /// (`POST rpc/record/{table}/{record_id}` with `attachment_id`).
  Future<void> link(String table, Object recordId, String attachmentId) async {
    await api.request(
      'POST',
      _path(['record', table, recordId]),
      data: {'attachment_id': attachmentId},
    );
  }

  /// Removes the link between an attachment and a record
  /// (`DELETE rpc/record/{table}/{record_id}/{attachment_id}`).
  Future<void> unlink(
    String table,
    Object recordId,
    String attachmentId,
  ) async {
    await api.request(
      'DELETE',
      _path(['record', table, recordId, attachmentId]),
    );
  }

  /// Fetches the attachment bytes from `rpc/{id}/view` with the client's
  /// auth headers (for protected files that cannot be loaded from a bare URL).
  Future<Uint8List> viewBytes(String id) async =>
      api.getBytes(_path([id, 'view']));

  /// Builds a view URL for an attachment, supporting optional image dimensions and format.
  String getViewUrl(
    dynamic attachmentId, {
    int? width,
    int? height,
    String? fit,
    String? format,
  }) {
    final cleanBase = api.baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final path = _path([attachmentId as Object, 'view']);
    final queryParts = <String>[];
    if (width != null) queryParts.add('w=$width');
    if (height != null) queryParts.add('h=$height');
    if (fit != null) queryParts.add('fit=$fit');
    if (format != null) queryParts.add('format=$format');

    final qs = queryParts.isEmpty ? '' : '?${queryParts.join('&')}';
    return '$cleanBase/$path$qs';
  }

  /// Builds a download URL for an attachment.
  String getDownloadUrl(dynamic attachmentId) {
    final cleanBase = api.baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    return '$cleanBase/${_path([attachmentId as Object, 'download'])}';
  }
}

SpApiError _uploadError(String message) => SpApiError(
  status: 0,
  code: SpApiErrorCode.unencodableValue,
  message: 'attachments.uploadMultipart: $message',
);

class _Part {
  _Part(this.number, this.bytes);
  final int number;
  final Uint8List bytes;
}

/// Cuts [stream] into exact [size] parts; the last is smaller, and an empty
/// stream gives one empty part.
Stream<_Part> _cutParts(Stream<List<int>> stream, int size) async* {
  final buf = BytesBuilder(copy: false);
  var n = 0;
  await for (final chunk in stream) {
    buf.add(chunk);
    while (buf.length >= size) {
      final all = buf.takeBytes();
      yield _Part(++n, Uint8List.sublistView(all, 0, size));
      buf.add(Uint8List.sublistView(all, size));
    }
  }
  if (buf.length > 0 || n == 0) yield _Part(++n, buf.takeBytes());
}

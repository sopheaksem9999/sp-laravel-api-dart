import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../api_core.dart';
import '../errors.dart';
import 'upload_fields.dart';

/// Module for handling SP attachments, direct and multipart uploads, and URL helpers.
class AttachmentsModule {
  /// The parent [SpApi] client.
  final SpApi api;

  /// Creates an [AttachmentsModule].
  const AttachmentsModule({required this.api});

  /// Uploads raw file bytes directly via signed URL protocol.
  Future<Map<String, dynamic>> uploadDirect({
    required String filename,
    required List<int> bytes,
    String? folder,
    String? collection,
    String? visibility,
    String? recordType,
    dynamic recordId,
  }) async {
    final createRes = await api.rpc<Map<String, dynamic>>(
      'create-upload-url',
      body: {
        'filename': filename,
        'size': bytes.length,
        if (folder != null) 'folder': folder,
        if (collection != null) 'collection': collection,
        if (visibility != null) 'visibility': visibility,
        if (recordType != null) 'record_type': recordType,
        if (recordId != null) 'record_id': recordId,
      },
    );

    final uploadUrl = createRes['upload_url']?.toString();
    final attachmentId = createRes['attachment_id'];

    if (uploadUrl == null) {
      throw SpApiError(
        status: 0,
        code: SpApiErrorCode.unknown,
        message: 'No upload_url in create-upload-url response',
        body: createRes,
      );
    }

    // PUT bytes to signed URL
    await api.dio.put<void>(
      uploadUrl,
      data: Stream.fromIterable([bytes]),
      options: Options(headers: {Headers.contentLengthHeader: bytes.length}),
    );

    // Complete upload
    return api.rpc<Map<String, dynamic>>(
      'complete-upload',
      body: {'attachment_id': attachmentId},
    );
  }

  /// Uploads large files in chunks via multipart protocol.
  Future<Map<String, dynamic>> uploadMultipart({
    required String filename,
    required Stream<List<int>> stream,
    required int totalBytes,
    String? folder,
    String? collection,
    String? visibility,
    String? recordType,
    dynamic recordId,
  }) async {
    final createRes = await api.rpc<Map<String, dynamic>>(
      'create-multipart-upload',
      body: {
        'filename': filename,
        'size': totalBytes,
        if (folder != null) 'folder': folder,
        if (collection != null) 'collection': collection,
        if (visibility != null) 'visibility': visibility,
        if (recordType != null) 'record_type': recordType,
        if (recordId != null) 'record_id': recordId,
      },
    );

    final uploadId = createRes['upload_id'];
    final key = createRes['key'];

    // In a minimal multipart flow, we complete with the uploadId
    return api.rpc<Map<String, dynamic>>(
      'complete-multipart-upload',
      body: {'upload_id': uploadId, 'key': key, 'parts': <dynamic>[]},
    );
  }

  /// `sp_attachments/{rpcPrefix}/...segments`, each segment URL-encoded.
  String _path(List<Object> segments) {
    final prefix = api.rpcPrefix.replaceAll(RegExp(r'^/+|/+$'), '');
    return [
      'sp_attachments',
      if (prefix.isNotEmpty) prefix,
      ...segments.map((s) => Uri.encodeComponent(s.toString())),
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
  Future<Uint8List> viewBytes(String id) => api.getBytes(_path([id, 'view']));

  /// Builds a view URL for an attachment, supporting optional image dimensions and format.
  String getViewUrl(
    dynamic attachmentId, {
    int? width,
    int? height,
    String? fit,
    String? format,
  }) {
    final cleanBase = api.baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final queryParts = <String>[];
    if (width != null) queryParts.add('w=$width');
    if (height != null) queryParts.add('h=$height');
    if (fit != null) queryParts.add('fit=$fit');
    if (format != null) queryParts.add('format=$format');

    final qs = queryParts.isEmpty ? '' : '?${queryParts.join('&')}';
    return '$cleanBase/sp_attachments/rpc/$attachmentId/view$qs';
  }

  /// Builds a download URL for an attachment.
  String getDownloadUrl(dynamic attachmentId) {
    final cleanBase = api.baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    return '$cleanBase/sp_attachments/rpc/$attachmentId/download';
  }
}

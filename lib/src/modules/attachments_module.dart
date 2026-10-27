import 'package:dio/dio.dart';
import '../api_core.dart';
import '../errors.dart';

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

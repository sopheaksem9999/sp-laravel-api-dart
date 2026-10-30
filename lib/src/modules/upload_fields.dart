import '../errors.dart';

/// The upload paths a field can go through. Resize options and `asTemp` are
/// form-only: direct and multipart uploads send the file straight to storage.
enum UploadStrategy { form, direct, multipart }

/// The upload route's optional fields, as one value to validate and map.
class UploadFieldOptions {
  const UploadFieldOptions({
    this.visibility,
    this.recordType,
    this.recordId,
    this.collection,
    this.folderId,
    this.replaceOld,
    this.title,
    this.caption,
    this.tempTimeoutMinutes,
    this.tempTimeoutAt,
    this.width,
    this.height,
    this.fit,
    this.sizeName,
    this.asTemp,
  });

  final String? visibility;
  final String? recordType;
  final Object? recordId;
  final String? collection;
  final String? folderId;
  final bool? replaceOld;
  final String? title;
  final String? caption;
  final int? tempTimeoutMinutes;

  /// A `String` (sent unchanged) or a `DateTime` (sent as UTC ISO-8601).
  final Object? tempTimeoutAt;
  final int? width;
  final int? height;
  final String? fit;
  final String? sizeName;
  final bool? asTemp;
}

SpApiError _bad(String message) => SpApiError(
  status: 0,
  code: SpApiErrorCode.unencodableValue,
  message: 'attachments.upload: $message',
);

bool _isTemp(String? visibility) =>
    visibility == 'temp_private' || visibility == 'temp_public';

/// Throws `SpApiError(unencodableValue)` (no request is made) when the server
/// would silently ignore or override an option: resize or `asTemp` on a direct
/// upload, a timeout without a temporary upload, `replaceOld` without a record
/// and so on. Only a truthy flag counts: `replaceOld: false` and
/// `asTemp: false` are no-ops (with a `temp_*` visibility the visibility wins).
/// The server's own ranges (width and height, title length, timeout cap) are
/// left to its 422.
void checkUploadFields(UploadFieldOptions o, UploadStrategy strategy) {
  if (strategy != UploadStrategy.form) {
    final resize = {
      'width': o.width,
      'height': o.height,
      'fit': o.fit,
      'sizeName': o.sizeName,
    };
    for (final e in resize.entries) {
      if (e.value != null) {
        throw _bad(
          '${e.key} needs the form upload: the ${strategy.name} strategy sends '
          'the file straight to storage, so it cannot be resized',
        );
      }
    }
    if (o.asTemp == true) {
      throw _bad(
        'asTemp is only for the form upload; with the ${strategy.name} '
        "strategy use visibility 'temp_private' or 'temp_public'",
      );
    }
  }

  if (o.width != null && o.width! < 1) {
    throw _bad('width must be a positive integer');
  }
  if (o.height != null && o.height! < 1) {
    throw _bad('height must be a positive integer');
  }
  if (o.fit != null && o.fit != 'crop' && o.fit != 'contain') {
    throw _bad('fit must be "crop" or "contain"');
  }
  if (o.sizeName != null) {
    if (o.sizeName!.isEmpty) throw _bad('sizeName must be a non-empty string');
    if (o.width != null || o.height != null || o.fit != null) {
      throw _bad(
        "sizeName cannot be combined with width, height or fit: the host's "
        'configured size overrides them',
      );
    }
  }

  if (o.replaceOld == true && (o.recordType == null || o.recordId == null)) {
    throw _bad(
      'replaceOld needs recordType and recordId: without a record the server '
      'makes no link and ignores it',
    );
  }

  if (o.asTemp == true && o.visibility != null && !_isTemp(o.visibility)) {
    throw _bad(
      "asTemp: true contradicts visibility '${o.visibility}': the server "
      'would replace it with its temporary default',
    );
  }

  if (o.tempTimeoutMinutes != null && o.tempTimeoutMinutes! < 1) {
    throw _bad('tempTimeoutMinutes must be a positive integer');
  }
  final at = o.tempTimeoutAt;
  if (at != null) {
    final valid = at is DateTime || (at is String && at.trim().isNotEmpty);
    if (!valid) {
      throw _bad('tempTimeoutAt must be a non-empty string or a DateTime');
    }
  }
  if (o.tempTimeoutMinutes != null && at != null) {
    throw _bad(
      'tempTimeoutMinutes and tempTimeoutAt together: the server uses '
      'tempTimeoutAt and ignores the minutes',
    );
  }
  if ((o.tempTimeoutMinutes != null || at != null) &&
      !(o.asTemp == true || _isTemp(o.visibility))) {
    throw _bad(
      "a timeout only applies to a temporary upload: set asTemp: true or "
      "visibility 'temp_private' / 'temp_public'",
    );
  }
}

/// Wire fields every strategy can send (on the final call): `replace_old`
/// (only when `true`), `folder_id`, `title`, `caption` and the temp timeouts.
Map<String, Object> sharedFields(UploadFieldOptions o) {
  final at = o.tempTimeoutAt;
  return {
    if (o.replaceOld == true) 'replace_old': true,
    if (o.folderId != null) 'folder_id': o.folderId!,
    if (o.title != null) 'title': o.title!,
    if (o.caption != null) 'caption': o.caption!,
    if (o.tempTimeoutMinutes != null)
      'temp_timeout_minutes': o.tempTimeoutMinutes.toString(),
    if (at != null)
      'temp_timeout_at': at is DateTime
          ? at.toUtc().toIso8601String()
          : at.toString(),
  };
}

/// Wire fields only the form upload can send: `w`, `h`, `fit`, `size_name`
/// and `as_temp` (only when `true`).
Map<String, Object> formOnlyFields(UploadFieldOptions o) => {
  if (o.width != null) 'w': o.width.toString(),
  if (o.height != null) 'h': o.height.toString(),
  if (o.fit != null) 'fit': o.fit!,
  if (o.sizeName != null) 'size_name': o.sizeName!,
  if (o.asTemp == true) 'as_temp': true,
};

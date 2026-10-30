import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  late List<RequestOptions> seen;
  late Dio dio;
  late AttachmentsModule attachments;
  Object respondWith = {'success': true, 'data': <String, dynamic>{}};

  setUp(() {
    seen = [];
    respondWith = {'success': true, 'data': <String, dynamic>{}};
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          seen.add(options);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: respondWith,
            ),
          );
        },
      ),
    );
    final api = SpApi(
      baseUrl: Uri.parse('https://example.com/api/v1'),
      dio: dio,
      auth: ApiAuth(
        headers: () async => {'Authorization': 'Bearer tok-123'},
        handleUnauthorized: () async => false,
      ),
    );
    attachments = AttachmentsModule(api: api);
  });

  group('AttachmentsModule.upload', () {
    test('posts multipart form with file and visibility', () async {
      respondWith = {
        'success': true,
        'data': {'id': 'att_1', 'filename': 'invoice.pdf'},
      };
      final result = await attachments.upload(
        bytes: utf8.encode('PDF'),
        filename: 'invoice.pdf',
      );
      expect(result['id'], equals('att_1'));
      final req = seen.single;
      expect(req.method, equals('POST'));
      expect(req.path, endsWith('/sp_attachments/rpc/upload'));
      expect(req.data, isA<FormData>());
      final form = req.data as FormData;
      expect(
        form.fields.firstWhere((f) => f.key == 'visibility').value,
        equals('private'),
      );
      final file = form.files.single;
      expect(file.key, equals('file'));
      expect(file.value.filename, equals('invoice.pdf'));
      expect(file.value.length, equals(3));
      expect(
        req.headers['Content-Type'].toString(),
        contains('multipart/form-data'),
      );
      expect(req.headers['Authorization'], equals('Bearer tok-123'));
    });

    test('sends custom visibility', () async {
      await attachments.upload(
        bytes: [1, 2],
        filename: 'a.bin',
        visibility: 'public',
      );
      final form = seen.single.data as FormData;
      expect(
        form.fields.firstWhere((f) => f.key == 'visibility').value,
        equals('public'),
      );
    });

    test('requires exactly one of bytes or filePath', () async {
      expect(() => attachments.upload(filename: 'a.bin'), throwsArgumentError);
      expect(
        () => attachments.upload(
          filename: 'a.bin',
          bytes: [1],
          filePath: '/tmp/a.bin',
        ),
        throwsArgumentError,
      );
      expect(seen, isEmpty);
    });
  });

  group('AttachmentsModule.upload fields', () {
    Map<String, String> fieldsOf(RequestOptions r) => {
      for (final f in (r.data as FormData).fields) f.key: f.value,
    };

    test('sends w, h, fit as strings', () async {
      await attachments.upload(
        bytes: [1],
        filename: 'a.png',
        width: 512,
        height: 256,
        fit: 'crop',
        visibility: 'public',
      );
      final f = fieldsOf(seen.single);
      expect(f['w'], '512');
      expect(f['h'], '256');
      expect(f['fit'], 'crop');
      expect(f['visibility'], 'public');
    });

    test('sends sizeName as size_name and no w or h', () async {
      await attachments.upload(
        bytes: [1],
        filename: 'a.png',
        sizeName: 'thumb',
      );
      final f = fieldsOf(seen.single);
      expect(f['size_name'], 'thumb');
      expect(f.containsKey('w'), isFalse);
    });

    test('sends replace_old true with record and collection', () async {
      await attachments.upload(
        bytes: [1],
        filename: 'a.png',
        recordType: 'products',
        recordId: 7,
        collection: 'gallery',
        replaceOld: true,
      );
      final f = fieldsOf(seen.single);
      expect(f['replace_old'], 'true');
      expect(f['record_type'], 'products');
      expect(f['record_id'], '7');
      expect(f['collection_name'], 'gallery');
    });

    test('replaceOld false is not sent', () async {
      await attachments.upload(
        bytes: [1],
        filename: 'a.png',
        replaceOld: false,
      );
      expect(fieldsOf(seen.single).containsKey('replace_old'), isFalse);
    });

    test('sends title, caption and folderId as strings', () async {
      await attachments.upload(
        bytes: [1],
        filename: 'a.png',
        title: 'Logo',
        caption: 'Our logo',
        folderId: '12',
      );
      final f = fieldsOf(seen.single);
      expect(f['title'], 'Logo');
      expect(f['caption'], 'Our logo');
      expect(f['folder_id'], '12');
    });

    test('asTemp true sends as_temp and no visibility', () async {
      await attachments.upload(bytes: [1], filename: 'a.bin', asTemp: true);
      final f = fieldsOf(seen.single);
      expect(f['as_temp'], 'true');
      expect(f.containsKey('visibility'), isFalse);
    });

    test('a temp timeout goes out with visibility temp_public', () async {
      await attachments.upload(
        bytes: [1],
        filename: 'a.bin',
        visibility: 'temp_public',
        tempTimeoutMinutes: 90,
      );
      final f = fieldsOf(seen.single);
      expect(f['temp_timeout_minutes'], '90');
      expect(f['visibility'], 'temp_public');
    });

    test('tempTimeoutAt: a DateTime goes out as UTC ISO', () async {
      await attachments.upload(
        bytes: [1],
        filename: 'a.bin',
        asTemp: true,
        tempTimeoutAt: DateTime.utc(2026, 10, 30, 10),
      );
      expect(
        fieldsOf(seen.single)['temp_timeout_at'],
        '2026-10-30T10:00:00.000Z',
      );
    });

    test('a contradiction makes no request', () async {
      await expectLater(
        attachments.upload(
          bytes: [1],
          filename: 'a.bin',
          asTemp: true,
          visibility: 'private',
        ),
        throwsA(
          isA<SpApiError>().having(
            (e) => e.code,
            'code',
            SpApiErrorCode.unencodableValue,
          ),
        ),
      );
      expect(seen, isEmpty);
    });
  });

  group('AttachmentsModule.link / unlink', () {
    test('link posts attachment_id to the record path', () async {
      await attachments.link('invoices', 7, 'att_1');
      final req = seen.single;
      expect(req.method, equals('POST'));
      expect(req.path, endsWith('/sp_attachments/rpc/record/invoices/7'));
      expect(req.data, equals({'attachment_id': 'att_1'}));
    });

    test('unlink deletes the attachment under the record path', () async {
      await attachments.unlink('invoices', 7, 'att_1');
      final req = seen.single;
      expect(req.method, equals('DELETE'));
      expect(req.path, endsWith('/sp_attachments/rpc/record/invoices/7/att_1'));
    });
  });

  group('AttachmentsModule.viewBytes', () {
    test('returns bytes and sends Authorization', () async {
      respondWith = [1, 2, 3, 4];
      final bytes = await attachments.viewBytes('att_1');
      expect(bytes, equals([1, 2, 3, 4]));
      final req = seen.single;
      expect(req.method, equals('GET'));
      expect(req.path, endsWith('/sp_attachments/rpc/att_1/view'));
      expect(req.headers['Authorization'], equals('Bearer tok-123'));
    });
  });
}

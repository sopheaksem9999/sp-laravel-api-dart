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

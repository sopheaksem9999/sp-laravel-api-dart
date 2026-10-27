import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sp_laravel_api/sp_laravel_api.dart';
import 'package:test/test.dart';

void main() {
  group('BulkModule', () {
    test(
      'chunks bulk create operations into requests of chunkSize (default 1000)',
      () async {
        final dio = Dio();
        final recordedChunks = <int>[];

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.path, contains('/invoices/bulk/create'));
              expect(options.method, equals('POST'));
              final list = options.data as List;
              recordedChunks.add(list.length);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': list
                        .map((e) => {'id': 1, 'name': e['name']})
                        .toList(),
                    'meta': {'affected': list.length},
                  },
                ),
              );
            },
          ),
        );

        final api = SpApi(
          baseUrl: Uri.parse('https://example.com/api/v1'),
          dio: dio,
        );

        final bulkModule = BulkModule(api: api);
        final rows = List.generate(2500, (i) => {'name': 'row_$i'});

        final result = await bulkModule.create('invoices', rows);
        expect(result.length, equals(2500));
        expect(recordedChunks, equals([1000, 1000, 500]));
      },
    );

    test('appends async query parameter when isAsync is true', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.queryParameters['async'], equals('1'));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 202,
                data: {'status': 'queued'},
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );

      final bulkModule = BulkModule(api: api);
      final res = await bulkModule.create('invoices', [
        {'name': 'async_item'},
      ], isAsync: true);
      expect(res.first['queued'], isTrue);
    });
  });

  group('AttachmentsModule', () {
    test('constructs view and download URLs with resize parameters', () {
      final api = SpApi(baseUrl: Uri.parse('https://example.com/api/v1'));
      final attachments = AttachmentsModule(api: api);

      final viewUrl = attachments.getViewUrl(
        123,
        width: 400,
        height: 300,
        fit: 'crop',
        format: 'webp',
      );
      expect(
        viewUrl,
        equals(
          'https://example.com/api/v1/sp_attachments/rpc/123/view?w=400&h=300&fit=crop&format=webp',
        ),
      );

      final downloadUrl = attachments.getDownloadUrl(123);
      expect(
        downloadUrl,
        equals('https://example.com/api/v1/sp_attachments/rpc/123/download'),
      );
    });

    test('uploadDirect requests signed URL and completes upload', () async {
      final dio = Dio();
      int step = 0;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            step++;
            if (step == 1) {
              expect(options.path, contains('/create-upload-url'));
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': {
                      'upload_url': 'https://s3.example.com/direct-upload',
                      'attachment_id': 'att_999',
                    },
                  },
                ),
              );
            } else if (step == 2) {
              // Direct PUT to upload URL
              expect(
                options.path,
                equals('https://s3.example.com/direct-upload'),
              );
              expect(options.method, equals('PUT'));
              handler.resolve(
                Response(requestOptions: options, statusCode: 200, data: ''),
              );
            } else if (step == 3) {
              expect(options.path, contains('/complete-upload'));
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'success': true,
                    'data': {'id': 'att_999', 'filename': 'doc.pdf'},
                  },
                ),
              );
            }
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );

      final attachments = AttachmentsModule(api: api);
      final result = await attachments.uploadDirect(
        filename: 'doc.pdf',
        bytes: utf8.encode('PDF_DATA'),
        folder: 'invoices',
      );

      expect(result['id'], equals('att_999'));
      expect(step, equals(3));
    });
  });

  group('AuditModule', () {
    test('stats maps camelCase to snake_case query parameters', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, contains('/sp_audit_logs/rpc/stats'));
            expect(options.queryParameters['start_date'], equals('2026-01-01'));
            expect(options.queryParameters['end_date'], equals('2026-02-01'));
            expect(options.queryParameters['user_id'], equals('5'));
            expect(options.queryParameters['entity_type'], equals('invoices'));
            expect(options.queryParameters['event'], equals('created'));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': {
                    'total': 42,
                    'by_event': {'created': 42},
                  },
                },
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );

      final audit = AuditModule(api: api);
      final stats = await audit.stats(
        startDate: '2026-01-01',
        endDate: '2026-02-01',
        userId: 5,
        entityType: 'invoices',
        event: 'created',
      );

      expect(stats['total'], equals(42));
    });
  });

  group('PermissionsModule', () {
    test('assign and detach post nested writes', () async {
      final dio = Dio();
      int call = 0;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            call++;
            if (call == 1) {
              expect(options.path, contains('/sp_roles/3'));
              expect(
                options.data,
                equals({
                  'permissions': [1, 2],
                }),
              );
            } else {
              expect(options.path, contains('/sp_roles/3'));
              expect(
                options.data,
                equals({
                  'permissions': [
                    {'id': 1, '_delete': true},
                    {'id': 2, '_delete': true},
                  ],
                }),
              );
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': {'id': 3, 'name': 'admin'},
                },
              ),
            );
          },
        ),
      );

      final api = SpApi(
        baseUrl: Uri.parse('https://example.com/api/v1'),
        dio: dio,
      );

      final perms = PermissionsModule(api: api);
      await perms.assign(3, [1, 2]);
      await perms.detach(3, [1, 2]);

      expect(call, equals(2));
    });
  });
}
